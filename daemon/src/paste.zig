//! Native paste: clipboard set via Pasteboard, Cmd+V posted via CGEvent.
//! Replaces the old pbcopy+osascript subprocess pair (~97 ms -> ~1 ms).

const std = @import("std");
const mac = @import("macos.zig");

pub fn copyText(text: []const u8) !void {
    const name = mac.CFStringCreateWithCString(
        mac.kCFAllocatorDefault,
        mac.kPasteboardClipboard,
        mac.kCFStringEncodingUTF8,
    );
    var pb: mac.PasteboardRef = null;
    try check(mac.PasteboardCreate(name, &pb));
    defer mac.CFRelease(pb);

    try check(mac.PasteboardClear(pb));
    const uttype = mac.CFStringCreateWithCString(
        mac.kCFAllocatorDefault,
        mac.kUTTypeUTF8PlainText,
        mac.kCFStringEncodingUTF8,
    );
    const data = mac.CFDataCreate(mac.kCFAllocatorDefault, text.ptr, @intCast(text.len));
    // Item ID 1 is the conventional single-item identifier.
    try check(mac.PasteboardPutItemFlavor(pb, 1, uttype, data, 0));
}

/// Posts Cmd+V to the frontmost app. Requires Accessibility permission.
pub fn pasteCommandV() !void {
    const v: u16 = @intCast(mac.kVK_ANSI_V);
    const down = mac.CGEventCreateKeyboardEvent(null, v, true);
    if (down == null) return error.EventCreateFailed;
    mac.CGEventSetFlags(down, mac.kCGEventFlagMaskCommand);
    mac.CGEventPost(mac.kCGHIDEventTap, down);
    mac.CFRelease(down);

    const up = mac.CGEventCreateKeyboardEvent(null, v, false);
    if (up == null) return error.EventCreateFailed;
    mac.CGEventSetFlags(up, mac.kCGEventFlagMaskCommand);
    mac.CGEventPost(mac.kCGHIDEventTap, up);
    mac.CFRelease(up);
}

const timespec = extern struct { sec: isize, nsec: isize };
extern "c" fn nanosleep(req: *const timespec, rem: ?*timespec) c_int;

pub fn pasteText(text: []const u8) !void {
    try copyText(text);
    // Small delay so the frontmost app observes the pasteboard change.
    const req = timespec{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
    _ = nanosleep(&req, null);
    try pasteCommandV();
}

fn check(status: mac.OSStatus) !void {
    if (status != 0) return error.MacOS;
}
