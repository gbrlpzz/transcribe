//! Engine client: streams PCM to the warm Python engine over a Unix socket
//! (protocol v1) and collects partial/final events.
//!
//! Uses raw BSD sockets directly: Zig 0.16 moved std.net behind the Io
//! vtable, and a small blocking client is simpler against the stable libc ABI.

const std = @import("std");

pub const AF_UNIX: c_int = 1;
pub const SOCK_STREAM: c_int = 1;

const sockaddr_un = extern struct {
    family: u16 = AF_UNIX,
    path: [104]u8 = [_]u8{0} ** 104,

    fn init(path: []const u8) !sockaddr_un {
        if (path.len >= 104) return error.PathTooLong;
        var a = sockaddr_un{};
        @memcpy(a.path[0..path.len], path);
        return a;
    }
};

// Namespaced so our method names (close/connect) don't shadow the C symbols.
const c = struct {
    extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    extern "c" fn connect(fd: c_int, addr: *const sockaddr_un, len: u32) c_int;
    extern "c" fn send(fd: c_int, buf: [*]const u8, n: usize, flags: c_int) isize;
    extern "c" fn recv(fd: c_int, buf: [*]u8, n: usize, flags: c_int) isize;
    extern "c" fn close(fd: c_int) c_int;
};

pub const Event = union(enum) {
    ready,
    partial: []u8, // owned by receiver's allocator
    final: struct { text: []u8, elapsed_ms: u64 },
    error_msg: []u8,
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    fd: c_int,
    // No send mutex needed: the protocol has exactly one writer thread
    // (the session owner); the reader thread only receives.

    pub fn connect(alloc: std.mem.Allocator, sock_path: []const u8) !Client {
        const fd = c.socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        const addr = try sockaddr_un.init(sock_path);
        if (c.connect(fd, &addr, @sizeOf(sockaddr_un)) != 0) return error.ConnectFailed;
        return .{ .alloc = alloc, .fd = fd };
    }

    pub fn close(self: *Client) void {
        _ = c.close(self.fd);
    }

    fn writeAll(self: *Client, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            const n = c.send(self.fd, data[sent..].ptr, data.len - sent, 0);
            if (n <= 0) return error.SendFailed;
            sent += @intCast(n);
        }
    }

    fn readAll(self: *Client, out: []u8) !void {
        var got: usize = 0;
        while (got < out.len) {
            const n = c.recv(self.fd, out[got..].ptr, out.len - got, 0);
            if (n <= 0) return error.RecvFailed;
            got += @intCast(n);
        }
    }

    /// Send one length-prefixed frame (control JSON or raw PCM).
    pub fn sendRaw(self: *Client, payload: []const u8) !void {
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(payload.len), .little);
        try self.writeAll(&header);
        try self.writeAll(payload);
    }

    /// Control frames are tiny: header + JSON in one syscall.
    pub fn sendControl(self: *Client, json_text: []const u8) !void {
        var buf: [512]u8 = undefined;
        if (json_text.len + 4 <= buf.len) {
            std.mem.writeInt(u32, buf[0..4], @intCast(json_text.len), .little);
            @memcpy(buf[4..][0..json_text.len], json_text);
            return self.writeAll(buf[0 .. 4 + json_text.len]);
        }
        return self.sendRaw(json_text);
    }

    /// Blocking read of one event. Caller frees returned slices with `alloc`.
    pub fn readEvent(self: *Client) !Event {
        var header: [4]u8 = undefined;
        try self.readAll(&header);
        const len = std.mem.readInt(u32, &header, .little);
        if (len == 0 or len > 32 * 1024 * 1024) return error.BadFrame;
        const payload = try self.alloc.alloc(u8, len);
        errdefer self.alloc.free(payload);
        try self.readAll(payload);

        // JSON control events start with '{'; anything else is unexpected PCM.
        if (payload.len == 0 or payload[0] != '{') {
            self.alloc.free(payload);
            return error.UnexpectedBinaryFrame;
        }
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, payload, .{}) catch {
            self.alloc.free(payload);
            return error.BadJson;
        };
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                self.alloc.free(payload);
                return error.BadJson;
            },
        };
        const ev = obj.get("ev") orelse {
            self.alloc.free(payload);
            return error.BadJson;
        };
        const kind = switch (ev) {
            .string => |s| s,
            else => {
                self.alloc.free(payload);
                return error.BadJson;
            },
        };

        if (std.mem.eql(u8, kind, "ready")) {
            self.alloc.free(payload);
            return .ready;
        }
        if (std.mem.eql(u8, kind, "partial")) {
            const text = obj.get("text") orelse {
                self.alloc.free(payload);
                return error.BadJson;
            };
            const copy = try self.alloc.dupe(u8, text.string);
            self.alloc.free(payload);
            return .{ .partial = copy };
        }
        if (std.mem.eql(u8, kind, "final")) {
            const text_v = obj.get("text") orelse {
                self.alloc.free(payload);
                return error.BadJson;
            };
            var elapsed: u64 = 0;
            if (obj.get("elapsed_ms")) |e| {
                if (e == .integer) elapsed = @intCast(@max(0, e.integer));
            }
            const copy = try self.alloc.dupe(u8, text_v.string);
            self.alloc.free(payload);
            return .{ .final = .{ .text = copy, .elapsed_ms = elapsed } };
        }
        if (std.mem.eql(u8, kind, "error")) {
            const msg = obj.get("msg") orelse {
                self.alloc.free(payload);
                return error.BadJson;
            };
            const copy = try self.alloc.dupe(u8, msg.string);
            self.alloc.free(payload);
            return .{ .error_msg = copy };
        }
        self.alloc.free(payload);
        return error.UnknownEvent;
    }
};

test "sockaddr init rejects long paths" {
    const long = "x" ** 110;
    try std.testing.expectError(error.PathTooLong, sockaddr_un.init(long));
}
