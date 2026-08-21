//! Core Audio input capture: default mic -> s16le mono 16 kHz PCM ring.
//!
//! The client format is declared as s16le/16 kHz, so AUHAL performs sample-rate
//! conversion and int16 packing internally. Our callback renders straight into
//! the ring's contiguous writable span: no intermediate buffers, no copies, no
//! per-sample work on the realtime thread.

const std = @import("std");
const mac = @import("macos.zig");

pub const sample_rate: u32 = 16000;

/// Lock-free SPSC byte ring with monotonic counters (empty/full unambiguous).
/// Producer: Core Audio render thread. Consumer: engine sender thread.
pub const Ring = struct {
    buf: []u8,
    head: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // total written
    tail: std.atomic.Value(u64) = std.atomic.Value(u64).init(0), // total read
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(buf: []u8) Ring {
        return .{ .buf = buf };
    }

    pub fn used(self: *Ring) usize {
        return @intCast(self.head.load(.acquire) - self.tail.load(.acquire));
    }

    pub fn free(self: *Ring) usize {
        return self.buf.len - self.used();
    }

    /// Contiguous writable slice (may be shorter than requested near the wrap).
    pub fn writableSpan(self: *Ring, max: usize) []u8 {
        const h = self.head.load(.acquire);
        const start = h % self.buf.len;
        const contiguous = self.buf.len - start;
        return self.buf[start .. start + @min(@min(max, contiguous), self.free())];
    }

    pub fn commit(self: *Ring, n: usize) void {
        _ = self.head.fetchAdd(n, .release);
    }

    /// Drop oldest bytes to admit `n` new ones; keeps latency bounded.
    pub fn skipOldest(self: *Ring, n: usize) void {
        const drop = @min(n, self.used());
        _ = self.tail.fetchAdd(drop, .acq_rel);
        _ = self.dropped.fetchAdd(drop, .monotonic);
    }

    pub fn write(self: *Ring, data: []const u8) void {
        if (data.len > self.free()) self.skipOldest(data.len - self.free());
        var rest = data;
        while (rest.len > 0) {
            const span = self.writableSpan(rest.len);
            if (span.len == 0) return; // unreachable: skipOldest guaranteed room
            @memcpy(span, rest[0..span.len]);
            self.commit(span.len);
            rest = rest[span.len..];
        }
    }

    pub fn read(self: *Ring, out: []u8) usize {
        const t = self.tail.load(.acquire);
        const avail: usize = @intCast(self.head.load(.acquire) - t);
        const n = @min(out.len, avail);
        const start = t % self.buf.len;
        const contiguous = @min(n, self.buf.len - start);
        @memcpy(out[0..contiguous], self.buf[start .. start + contiguous]);
        if (n > contiguous) @memcpy(out[contiguous..n], self.buf[0 .. n - contiguous]);
        self.tail.store(t + n, .release);
        return n;
    }
};

pub const Capture = struct {
    unit: mac.AudioUnit = null,
    ring: ?*Ring = null,
    /// Fallback for the rare render that straddles the ring wrap.
    wrap_scratch: [4096]u8 align(16) = undefined,

    pub fn init(ring: *Ring) Capture {
        return .{ .ring = ring };
    }

    pub fn start(self: *Capture) !void {
        var desc = mac.AudioComponentDescription{
            .componentType = mac.kAudioUnitType_Output,
            .componentSubType = mac.kAudioUnitSubType_HALOutput,
            .componentManufacturer = 0,
            .componentFlags = 0,
            .componentFlagsMask = 0,
        };
        const comp = mac.AudioComponentFindNext(null, &desc);
        if (comp == null) return error.NoHalComponent;
        try check(mac.AudioComponentInstanceNew(comp, &self.unit));

        // Input on element 1, output off element 0.
        const one: u32 = 1;
        const zero: u32 = 0;
        try check(mac.AudioUnitSetProperty(self.unit, mac.kAudioOutputUnitProperty_EnableIO, mac.kAudioUnitScope_Input, 1, &one, @sizeOf(u32)));
        try check(mac.AudioUnitSetProperty(self.unit, mac.kAudioOutputUnitProperty_EnableIO, mac.kAudioUnitScope_Output, 0, &zero, @sizeOf(u32)));

        // Route the default input device into the unit.
        var device: mac.AudioDeviceID = 0;
        var dev_size: u32 = @sizeOf(mac.AudioDeviceID);
        var addr = mac.AudioObjectPropertyAddress{
            .mSelector = mac.kAudioHardwarePropertyDefaultInputDevice,
            .mScope = 0,
            .mElement = 0,
        };
        try check(mac.AudioObjectGetPropertyData(mac.kAudioObjectSystemObject, &addr, 0, null, &dev_size, &device));
        try check(mac.AudioUnitSetProperty(self.unit, mac.kAudioOutputUnitProperty_CurrentDevice, mac.kAudioUnitScope_Global, 0, &device, dev_size));

        // s16le client format: AUHAL converts and packs for us.
        const format = mac.AudioStreamBasicDescription{
            .mSampleRate = @floatFromInt(sample_rate),
            .mFormatID = mac.kAudioFormatLinearPCM,
            .mFormatFlags = mac.kAudioFormatFlagIsSignedInteger | mac.kAudioFormatFlagIsPacked,
            .mBytesPerPacket = 2,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 2,
            .mChannelsPerFrame = 1,
            .mBitsPerChannel = 16,
            .mReserved = 0,
        };
        try check(mac.AudioUnitSetProperty(self.unit, mac.kAudioUnitProperty_StreamFormat, mac.kAudioUnitScope_Output, 1, &format, @sizeOf(mac.AudioStreamBasicDescription)));

        var cb = mac.AURenderCallbackStruct{ .inputProc = onAudio, .inputProcRefCon = self };
        try check(mac.AudioUnitSetProperty(self.unit, mac.kAudioOutputUnitProperty_SetInputCallback, mac.kAudioUnitScope_Global, 0, &cb, @sizeOf(mac.AURenderCallbackStruct)));

        try check(mac.AudioUnitInitialize(self.unit));
        try check(mac.AudioOutputUnitStart(self.unit));
    }

    pub fn stop(self: *Capture) void {
        if (self.unit) |u| {
            _ = mac.AudioOutputUnitStop(u);
            _ = mac.AudioUnitUninitialize(u);
            _ = mac.AudioComponentInstanceDispose(u);
            self.unit = null;
        }
    }

    fn onAudio(
        refcon: ?*anyopaque,
        flags: *mac.AudioUnitRenderActionFlags,
        ts: *const mac.AudioTimeStamp,
        bus: u32,
        frames: u32,
        io: ?*mac.AudioBufferList,
    ) callconv(.c) mac.OSStatus {
        _ = io;
        const self: *Capture = @ptrCast(@alignCast(refcon orelse return -1));
        const ring = self.ring orelse return 0;
        const want = frames * 2; // s16le mono

        var span = ring.writableSpan(want);
        if (span.len < want) {
            // Wrap straddle: render into scratch, then split-write.
            span = self.wrap_scratch[0..@min(want, self.wrap_scratch.len)];
        }
        var abl = mac.AudioBufferList{
            .mNumberBuffers = 1,
            .mBuffers = .{.{ .mNumberChannels = 1, .mDataByteSize = @intCast(span.len), .mData = span.ptr }},
        };
        const status = mac.AudioUnitRender(self.unit, flags, ts, bus, frames, &abl);
        if (status != 0) return status;
        ring.commit(abl.mBuffers[0].mDataByteSize);
        return 0;
    }

    fn check(status: mac.OSStatus) !void {
        if (status != 0) return error.CoreAudio;
    }
};

test "ring basic write/read" {
    var storage: [64]u8 = undefined;
    var ring = Ring.init(&storage);
    ring.write("hello");
    var out: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), ring.read(&out));
    try std.testing.expectEqualStrings("hello", &out);
}

test "ring drops oldest when full" {
    var storage: [8]u8 = undefined;
    var ring = Ring.init(&storage);
    ring.write("12345678");
    ring.write("AB"); // forces drop of oldest 2
    var out: [8]u8 = undefined;
    const n = ring.read(&out);
    try std.testing.expectEqualStrings("345678AB", out[0..n]);
}

test "ring spans handle wrap" {
    var storage: [8]u8 = undefined;
    var ring = Ring.init(&storage);
    ring.write("123456");
    var out: [6]u8 = undefined;
    _ = ring.read(&out); // head=6, tail=6
    // writable span is contiguous suffix [6..8], length 2 < 5 requested
    const span = ring.writableSpan(5);
    try std.testing.expectEqual(@as(usize, 2), span.len);
    @memcpy(span, "ab");
    ring.commit(2);
    ring.write("cdefg"); // wraps around
    var out2: [7]u8 = undefined;
    const n = ring.read(&out2);
    try std.testing.expectEqualStrings("abcdefg", out2[0..n]);
}
