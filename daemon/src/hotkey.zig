//! Global hotkey: Carbon first, CoreGraphics event-tap fallback.
//!
//! Carbon is the low-overhead path. macOS may reserve control+space for input
//! source switching; in that case the listen-only HID tap observes the same
//! physical shortcut without changing it or stealing the event.

const std = @import("std");
const mac = @import("macos.zig");

pub const Hotkey = struct {
    pressed: *std.atomic.Value(bool),
    wake: *std.Io.Semaphore,
    io: *std.Io,
    using_tap: bool = false,
    using_fallback: bool = false,
    tap: ?*anyopaque = null,
    tap_source: ?*anyopaque = null,
    carbon_hotkey: mac.EventHotKeyRef = null,
    carbon_handler: mac.EventHandlerRef = null,

    fn carbonHandler(
        call_ref: mac.EventHandlerCallRef,
        event: mac.EventRef,
        userdata: ?*anyopaque,
    ) callconv(.c) mac.OSStatus {
        _ = call_ref;
        const self: *Hotkey = @ptrCast(@alignCast(userdata orelse return -1));
        if (mac.GetEventKind(event) == mac.kEventHotKeyPressed) {
            self.pressed.store(true, .release);
            self.wake.post(self.io.*);
        }
        return 0;
    }

    fn tapHandler(
        proxy: ?*anyopaque,
        event_type: u32,
        event: mac.CGEventRef,
        userdata: ?*anyopaque,
    ) callconv(.c) mac.CGEventRef {
        _ = proxy;
        const self: *Hotkey = @ptrCast(@alignCast(userdata orelse return event));
        if (event_type == mac.kCGEventKeyDown and event != null) {
            const key = mac.CGEventGetIntegerValueField(event, mac.kCGKeyboardEventKeycode);
            const repeat = mac.CGEventGetIntegerValueField(event, mac.kCGKeyboardEventAutorepeat);
            const flags = mac.CGEventGetFlags(event);
            if (repeat == 0 and key == mac.kVK_Space and (flags & mac.kCGEventFlagMaskControl) != 0) {
                self.pressed.store(true, .release);
                self.wake.post(self.io.*);
            }
        }
        return event;
    }

    pub fn install(self: *Hotkey) !void {
        if (try self.installCarbon(mac.controlKey, false)) return;
        // macOS commonly reserves control+space for input-source switching.
        // Keep the shortcut deterministic, but use a free Carbon combination
        // automatically before requiring Accessibility for an event tap.
        if (try self.installCarbon(mac.controlKey | mac.optionKey, true)) return;
        try self.installTap();
    }

    fn installCarbon(self: *Hotkey, modifiers: u32, fallback: bool) !bool {
        var types = [_]mac.EventTypeSpec{
            .{ .eventClass = mac.kEventClassKeyboard, .eventKind = mac.kEventHotKeyPressed },
        };
        const target = mac.GetApplicationEventTarget();
        if (target == null) return false;
        if (mac.InstallEventHandler(target, carbonHandler, types.len, &types, self, &self.carbon_handler) != 0)
            return false;
        const id = mac.EventHotKeyID{ .signature = fourcc("trns"), .hotKeyID = 1 };
        if (mac.RegisterEventHotKey(mac.kVK_Space, modifiers, id, target, 0, &self.carbon_hotkey) != 0) {
            if (self.carbon_handler) |handler| {
                _ = mac.RemoveEventHandler(handler);
                self.carbon_handler = null;
            }
            return false;
        }
        self.using_tap = false;
        self.using_fallback = fallback;
        return true;
    }

    fn installTap(self: *Hotkey) !void {
        const mask: u64 = @as(u64, 1) << mac.kCGEventKeyDown;
        self.tap = mac.CGEventTapCreate(
            mac.kCGSessionEventTap,
            mac.kCGHeadInsertEventTap,
            mac.kCGEventTapOptionListenOnly,
            mask,
            tapHandler,
            self,
        );
        if (self.tap == null) return error.RegisterHotKeyFailed;
        self.tap_source = mac.CFMachPortCreateRunLoopSource(
            mac.kCFAllocatorDefault, self.tap, 0,
        );
        if (self.tap_source == null) return error.InstallEventTapFailed;
        const run_loop = mac.CFRunLoopGetCurrent();
        mac.CFRunLoopAddSource(run_loop, self.tap_source, mac.kCFRunLoopCommonModes);
        self.using_tap = true;
        self.using_fallback = false;
    }
};

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}
