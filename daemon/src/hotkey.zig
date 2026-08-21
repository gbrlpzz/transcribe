//! Global hotkey via Carbon RegisterEventHotKey (default: control+space).

const std = @import("std");
const mac = @import("macos.zig");

pub const Hotkey = struct {
    pressed: *std.atomic.Value(bool),

    fn handler(
        call_ref: mac.EventHandlerCallRef,
        event: mac.EventRef,
        userdata: ?*anyopaque,
    ) callconv(.c) mac.OSStatus {
        _ = call_ref;
        const self: *Hotkey = @ptrCast(@alignCast(userdata orelse return -1));
        if (mac.GetEventKind(event) == mac.kEventHotKeyPressed) {
            self.pressed.store(true, .release);
        }
        return 0;
    }

    pub fn install(self: *Hotkey) !void {
        var types = [_]mac.EventTypeSpec{
            .{ .eventClass = mac.kEventClassKeyboard, .eventKind = mac.kEventHotKeyPressed },
        };
        const target = mac.GetApplicationEventTarget();
        if (target == null) return error.NoEventTarget;
        if (mac.InstallEventHandler(target, handler, types.len, &types, self, null) != 0)
            return error.InstallHandlerFailed;

        const id = mac.EventHotKeyID{ .signature = fourcc("trns"), .hotKeyID = 1 };
        if (mac.RegisterEventHotKey(mac.kVK_Space, mac.controlKey, id, target, 0, null) != 0)
            return error.RegisterHotKeyFailed;
    }
};

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}
