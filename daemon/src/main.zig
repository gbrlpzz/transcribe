//! transcribed — resident capture daemon for Transcribe.
//!
//! Zero-config by design: fixed hotkey (control+space), language always auto,
//! fixed socket path. The user never configures anything; they trigger
//! dictation and text appears. Invisible infrastructure.
//!
//! Flow: hotkey tap starts a streaming session (Core Audio -> ring -> UDS ->
//! warm engine). Second tap stops capture; the final transcript is pasted
//! natively at the cursor.

const std = @import("std");
const posix = std.posix;
const mac = @import("macos.zig");
const audio = @import("audio.zig");
const engine = @import("engine.zig");
const hotkey = @import("hotkey.zig");
const paste = @import("paste.zig");

const version = "0.5.0";
const sock_env = "TRANSCRIBE_DICTATION_SOCK";

var home_dir: []const u8 = "/tmp";
var app_io: std.Io = undefined;

// --- protocol framing helpers (shared with tests) ------------------------------

pub fn encodeControl(alloc: std.mem.Allocator, json_text: []const u8) ![]u8 {
    return frame(alloc, json_text);
}

pub fn encodePcmFrame(alloc: std.mem.Allocator, pcm: []const u8) ![]u8 {
    return frame(alloc, pcm);
}

fn frame(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    const msg = try alloc.alloc(u8, 4 + payload.len);
    std.mem.writeInt(u32, msg[0..4], @intCast(payload.len), .little);
    @memcpy(msg[4..], payload);
    return msg;
}

test "framing roundtrip sizes" {
    const alloc = std.testing.allocator;
    const start_msg = "{\"op\":\"start\"}";
    const ctl = try encodeControl(alloc, start_msg);
    defer alloc.free(ctl);
    try std.testing.expectEqual(4 + start_msg.len, ctl.len);
    try std.testing.expectEqual(start_msg.len, std.mem.readInt(u32, ctl[0..4], .little));
}

// --- CLI ------------------------------------------------------------------------

fn usage() void {
    std.debug.print(
        \\transcribed {s} — resident dictation daemon (zero-config)
        \\
        \\Usage:
        \\  transcribed run                    start the daemon (hotkey: control+space)
        \\  transcribed once [--ms N]          one timed mic session (dev)
        \\  transcribed pipe <16k-mono.wav>    stream a wav through the pipeline (dev/bench)
        \\  transcribed ping                   check the engine socket
        \\  transcribed --version
        \\
    , .{version});
}

pub fn main(init: std.process.Init) !void {
    app_io = init.io;
    if (init.environ_map.get("HOME")) |h| home_dir = h;
    if (init.environ_map.get(sock_env)) |p| sock_override = p;

    var iter = init.minimal.args.iterate();
    defer iter.deinit();
    _ = iter.next(); // skip argv[0]

    var cmd: ?[]const u8 = null;
    var args_list: std.ArrayList([]const u8) = .empty;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("transcribed {s}\n", .{version});
            return;
        } else if (cmd == null and !std.mem.startsWith(u8, arg, "-")) {
            cmd = arg;
        } else {
            try args_list.append(init.gpa, arg);
        }
    }
    const cmd_args = args_list.items;
    defer args_list.deinit(init.gpa);

    if (cmd == null) {
        usage();
        return;
    }
    if (std.mem.eql(u8, cmd.?, "ping")) {
        try pingCmd();
        return;
    }
    if (std.mem.eql(u8, cmd.?, "run")) {
        try runCmd(init.gpa);
        return;
    }
    if (std.mem.eql(u8, cmd.?, "once")) {
        try onceCmd(init.gpa, cmd_args);
        return;
    }
    if (std.mem.eql(u8, cmd.?, "pipe")) {
        try pipeCmd(init.gpa, cmd_args);
        return;
    }
    usage();
}

var sock_override: ?[]const u8 = null;

// libc time helpers (std.time moved behind Io in zig 0.16)
const timespec = extern struct { sec: isize, nsec: isize };
extern "c" fn clock_gettime(clk_id: c_int, tp: *timespec) c_int;
extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;
const CLOCK_MONOTONIC_RAW: c_int = 4;

fn nowNs() i128 {
    var ts: timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn sleepMs(ms: u64) void {
    const req = timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = nanosleep(&req, null);
}

fn sockPath(buf: []u8) ![]const u8 {
    if (sock_override) |p| return p;
    return std.fmt.bufPrint(buf, "{s}/.cache/transcribe/dictation.sock", .{home_dir});
}

fn pingCmd() !void {
    var buf: [512]u8 = undefined;
    const path = try sockPath(&buf);
    const addr = try std.Io.net.UnixAddress.init(path);
    const stream = addr.connect(app_io) catch |err| {
        std.debug.print("no engine at {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer stream.close(app_io);
    std.debug.print("engine socket alive at {s}\n", .{path});
}

fn cacheDir(buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/.cache/transcribe", .{home_dir});
}

var lock_file: ?std.Io.File = null;

fn acquireSingleInstance() !void {
    makeCacheDir();
    var dbuf: [512]u8 = undefined;
    var lbuf: [512]u8 = undefined;
    const dir_path = try cacheDir(&dbuf);
    const lock_path = try std.fmt.bufPrint(&lbuf, "{s}/transcribed.lock", .{dir_path});
    const file = try std.Io.Dir.createFileAbsolute(app_io, lock_path, .{ .truncate = false });
    const got_lock = try file.tryLock(app_io, .exclusive);
    if (!got_lock) {
        std.debug.print("transcribed already running\n", .{});
        file.close(app_io);
        return error.AlreadyRunning;
    }
    lock_file = file; // held for process lifetime; lock releases on exit
}

fn makeCacheDir() void {
    var buf: [512]u8 = undefined;
    const dir_path = cacheDir(&buf) catch return;
    std.Io.Dir.createDirAbsolute(app_io, dir_path, .default_dir) catch {};
    var hbuf: [512]u8 = undefined;
    const home_cache = std.fmt.bufPrint(&hbuf, "{s}/.cache", .{home_dir}) catch return;
    std.Io.Dir.createDirAbsolute(app_io, home_cache, .default_dir) catch {};
}

// --- dev/test commands ---------------------------------------------------------

const SessionOpts = struct {
    duration_ms: u64 = 2000,
    paste: bool = true,
    wav_path: ?[]const u8 = null,
};

fn parseSessionOpts(args: []const []const u8) !SessionOpts {
    var opts = SessionOpts{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--no-paste")) {
            opts.paste = false;
        } else if (std.mem.eql(u8, a, "--ms")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.duration_ms = std.fmt.parseInt(u64, args[i], 10) catch 2000;
        }
    }
    return opts;
}

pub const WavPcm = struct {
    buf: []u8, // whole file allocation; free this
    pcm: []const u8, // view into buf
};

/// Minimal RIFF/WAVE reader for 16 kHz mono s16le files (dev/bench paths).
fn readWavPcm(alloc: std.mem.Allocator, path: []const u8) !WavPcm {
    const data = try std.Io.Dir.cwd().readFileAlloc(app_io, path, alloc, .limited(512 * 1024 * 1024));
    errdefer alloc.free(data);
    if (data.len < 44 or !std.mem.eql(u8, data[0..4], "RIFF") or
        !std.mem.eql(u8, data[8..12], "WAVE"))
        return error.NotWav;
    var pos: usize = 12;
    while (pos + 8 <= data.len) {
        const chunk_id = data[pos .. pos + 4];
        const chunk_len = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        if (std.mem.eql(u8, chunk_id, "data")) {
            const start = pos + 8;
            const end = @min(start + chunk_len, data.len);
            return .{ .buf = data, .pcm = data[start..end] };
        }
        pos += 8 + chunk_len + (chunk_len & 1);
    }
    return error.NoDataChunk;
}

/// Run one full dictation session against the engine and print the result.
/// Used by `once` (live mic) and `pipe` (wav replay).
fn runSession(alloc: std.mem.Allocator, opts: SessionOpts) !void {
    var sock_buf: [512]u8 = undefined;
    const sock_path = try sockPath(&sock_buf);

    final_result.arrived.store(false, .release);
    var client = try engine.Client.connect(alloc, sock_path);
    defer client.close();

    try client.sendControl("{\"op\":\"start\",\"language\":\"auto\",\"session\":\"cli\"}");

    var capture: ?audio.Capture = null;
    var ring_storage: ?[]u8 = null;
    var ring: audio.Ring = undefined;
    defer if (ring_storage) |rs| std.heap.page_allocator.free(rs);

    if (opts.wav_path) |path| {
        const wav = readWavPcm(alloc, path) catch |err| {
            std.debug.print("cannot read wav {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer alloc.free(wav.buf);
        // One large frame: the server treats any non-JSON payload as raw PCM.
        try client.sendRaw(wav.pcm);
    } else {
        ring_storage = try std.heap.page_allocator.alloc(u8, 1 << 20);
        ring = audio.Ring.init(ring_storage.?);
        capture = audio.Capture.init(&ring);
        try capture.?.start();
        const deadline = nowNs() + opts.duration_ms * std.time.ns_per_ms;
        var buf: [64000]u8 = undefined; // coalesce up to ~2 s per frame
        while (nowNs() < deadline) {
            const n = ring.read(&buf);
            if (n > 0) try client.sendRaw(buf[0..n]);
            sleepMs(20);
        }
        // Drain any audio still buffered, then stop the unit.
        var drain: [64000]u8 = undefined;
        while (true) {
            const n = ring.read(&drain);
            if (n == 0) break;
            try client.sendRaw(drain[0..n]);
        }
        capture.?.stop();
        capture = null;
    }

    client.sendControl("{\"op\":\"stop\"}") catch |err| {
        std.debug.print("send stop failed: {s}\n", .{@errorName(err)});
        return err;
    };

    // Read events until final.
    var final_text: ?[]u8 = null;
    defer if (final_text) |t| alloc.free(t);
    while (true) {
        const ev = client.readEvent() catch |err| {
            std.debug.print("read event failed: {s}\n", .{@errorName(err)});
            return err;
        };
        switch (ev) {
            .ready => {},
            .partial => |text| {
                std.debug.print("… {s}\n", .{text});
                alloc.free(text);
            },
            .final => |f| {
                std.debug.print("{s} ({d} ms)\n", .{ f.text, f.elapsed_ms });
                if (opts.paste) paste.pasteText(f.text) catch |err| {
                    std.debug.print("paste failed: {s}\n", .{@errorName(err)});
                };
                final_text = f.text;
            },
            .error_msg => |msg| {
                std.debug.print("engine error: {s}\n", .{msg});
                alloc.free(msg);
                return error.EngineError;
            },
        }
        if (final_text != null) break;
    }
}

fn onceCmd(alloc: std.mem.Allocator, args: []const []const u8) !void {
    const opts = try parseSessionOpts(args);
    try runSession(alloc, opts);
}

fn pipeCmd(alloc: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0 or std.mem.startsWith(u8, args[0], "-")) {
        std.debug.print("usage: transcribed pipe <16k-mono.wav> [--no-paste]\n", .{});
        return error.Usage;
    }
    var opts = try parseSessionOpts(args[1..]);
    opts.wav_path = args[0];
    try runSession(alloc, opts);
}

// --- daemon state -----------------------------------------------------------------

const State = enum { idle, recording };

var hotkey_pressed = std.atomic.Value(bool).init(false);
var hk: hotkey.Hotkey = .{ .pressed = &hotkey_pressed };

/// Shared result slot between the event-reader thread and the worker.
/// Uses an atomic flag + polling instead of a condvar (wait granularity
/// of a few ms is irrelevant next to transcription latency).
const FinalResult = struct {
    arrived: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    text: [8192]u8 = undefined,
    text_len: usize = 0,
    elapsed_ms: u64 = 0,

    fn set(self: *FinalResult, text: []const u8, elapsed_ms: u64) void {
        self.text_len = @min(text.len, self.text.len);
        @memcpy(self.text[0..self.text_len], text[0..self.text_len]);
        self.elapsed_ms = elapsed_ms;
        self.arrived.store(true, .release);
    }

    fn wait(self: *FinalResult, timeout_ns: u64) bool {
        const deadline = nowNs() + timeout_ns;
        while (!self.arrived.load(.acquire)) {
            if (nowNs() >= deadline) return false;
            sleepMs(5);
        }
        return true;
    }
};

var final_result: FinalResult = .{};
var gpa_for_threads: ?std.mem.Allocator = null;

fn runCmd(alloc: std.mem.Allocator) !void {
    acquireSingleInstance() catch |err| switch (err) {
        error.AlreadyRunning => return,
        else => return err,
    };
    gpa_for_threads = alloc;

    var sock_buf: [512]u8 = undefined;
    const sock_path = try sockPath(&sock_buf);

    // Event reader thread: collects engine events while a session is live.
    var worker = Worker{
        .alloc = alloc,
        .sock_path = sock_path,
    };
    const t = try std.Thread.spawn(.{}, workerLoop, .{&worker});

    hk.install() catch |err| {
        std.debug.print(
            "warning: hotkey unavailable ({s}); running without trigger\n",
            .{@errorName(err)},
        );
    };

    std.debug.print("transcribed {s} ready — control+space toggles dictation\n", .{version});
    mac.RunApplicationEventLoop();
    t.join(); // unreachable in practice; RunApplicationEventLoop does not return
}

const Worker = struct {
    alloc: std.mem.Allocator,
    sock_path: []const u8,
    state: State = .idle,
    capture: ?audio.Capture = null,
    client: ?engine.Client = null,
    reader_thread: ?std.Thread = null,
    reader_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ring_storage: ?[]u8 = null,
    ring: audio.Ring = undefined,
    ring_init: bool = false,

    fn toggle(self: *Worker) void {
        switch (self.state) {
            .idle => self.startSession(),
            .recording => self.stopSession(),
        }
    }

    fn startSession(self: *Worker) void {
        self.client = engine.Client.connect(self.alloc, self.sock_path) catch {
            std.debug.print("engine not reachable at {s} — start `transcribe serve` first\n", .{self.sock_path});
            return;
        };
        const c = &self.client.?;

        c.sendControl("{\"op\":\"start\",\"language\":\"auto\",\"session\":\"daemon\"}") catch |err| {
            std.debug.print("send start failed: {s}\n", .{@errorName(err)});
            self.teardownClient();
            return;
        };

        // Wait briefly for ready so errors surface early.
        final_result.arrived.store(false, .release);
        self.reader_stop.store(false, .release);
        self.reader_thread = std.Thread.spawn(.{}, readerLoop, .{&self.client.?}) catch |err| {
            std.debug.print("reader spawn failed: {s}\n", .{@errorName(err)});
            self.teardownClient();
            return;
        };

        const ring_storage = std.heap.page_allocator.alloc(u8, 1 << 20) catch {
            self.teardownClient();
            return;
        };
        self.ring_storage = ring_storage;
        self.ring = audio.Ring.init(ring_storage);
        self.ring_init = true;
        self.capture = audio.Capture.init(&self.ring);
        g_client = &self.client.?;
        self.capture.?.start() catch |err| {
            std.debug.print("capture failed: {s} — grant microphone access\n", .{@errorName(err)});
            self.teardownClient();
            return;
        };
                self.state = .recording;
        std.debug.print("● recording\n", .{});
    }

    fn stopSession(self: *Worker) void {
        if (self.state != .recording) return;
        self.state = .idle;
        std.debug.print("■ transcribing…\n", .{});

        if (self.capture) |*cap| {
            cap.stop();
            self.capture = null;
        }

        // Drain whatever remains in the ring before telling the engine we're done.
        if (self.client) |*c| {
            drainRingInto(self, c);
            c.sendControl("{\"op\":\"stop\"}") catch {};

            // Wait for the final event from the reader thread.
            if (final_result.wait(30 * std.time.ns_per_s)) {
                const text = final_result.text[0..final_result.text_len];
                std.debug.print("→ {s} ({d} ms)\n", .{ text, final_result.elapsed_ms });
                paste.pasteText(text) catch |err| {
                    std.debug.print("paste failed: {s} — grant Accessibility\n", .{@errorName(err)});
                };
            } else {
                std.debug.print("timed out waiting for transcription\n", .{});
            }
        }

        self.reader_stop.store(true, .release);
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }
        self.teardownClient();
        if (self.ring_storage) |rs| {
            std.heap.page_allocator.free(rs);
            self.ring_storage = null;
            self.ring_init = false;
        }
        g_client = null;
    }

    fn teardownClient(self: *Worker) void {
        if (self.client) |*c| {
            c.close();
            self.client = null;
        }
    }

    fn drainRingInto(self: *Worker, c: *engine.Client) void {
        var buf: [64000]u8 = undefined; // coalesce ~2 s per frame
        while (self.ring_init) {
            const n = self.ring.read(&buf);
            if (n == 0) break;
            c.sendRaw(buf[0..n]) catch return;
        }
    }
};

var g_client: ?*engine.Client = null;

fn readerLoop(client: *engine.Client) void {
    // Read events until the connection closes or we're told to stop.
    while (!final_result.arrived.load(.acquire)) {
        const ev = client.readEvent() catch {
            if (!final_result.arrived.load(.acquire)) {
                final_result.set("", 0);
            }
            return;
        };
        switch (ev) {
            .ready => {},
            .partial => |text| {
                defer w_alloc().free(text);
                std.debug.print("… {s}\n", .{text});
            },
            .final => |f| {
                defer w_alloc().free(f.text);
                final_result.set(f.text, f.elapsed_ms);
                return;
            },
            .error_msg => |msg| {
                defer w_alloc().free(msg);
                std.debug.print("engine error: {s}\n", .{msg});
                final_result.set("", 0);
                return;
            },
        }
    }
}

fn w_alloc() std.mem.Allocator {
    return gpa_for_threads.?;
}

fn workerLoop(w: *Worker) void {
    while (true) {
        if (hotkey_pressed.swap(false, .acq_rel)) {
            w.toggle();
        }
        sleepMs(20);
    }
}
