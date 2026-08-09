import Carbon
import Foundation

/// Global hotkey (press-and-hold) via the Carbon event API — the same mechanism
/// apps like commercial dictation software use. No accessibility permission is required to
/// register a global hotkey; it is only needed for the paste step.
final class HotKey {
    enum Action {
        case pressed
        case released
    }

    var onAction: ((Action) -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(
        signature: OSType(0x5452_5343), // "TRSC"
        id: 1
    )

    /// Register a hotkey. `modifiers` uses Carbon masks (cmdKey, optionKey, ...).
    func register(modifiers: UInt32, keyCode: UInt32) {
        unregister()

        var eventType = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            let kind = EventParamName(kEventParamDirectObject)
            var id = EventHotKeyID()
            GetEventParameter(event, kind, EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let action: Action = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .pressed : .released
            hotKey.onAction?(action)
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 2, &eventType,
                            selfPtr, &handlerRef)

        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("Transcribe: failed to register hotkey (status %d)", status)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    deinit { unregister() }

    // MARK: - Parsing "ctrl+option+space" style strings

    static func parse(_ spec: String) -> (modifiers: UInt32, keyCode: UInt32)? {
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        guard !parts.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        var keyName = ""
        for part in parts {
            switch part {
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "option", "alt": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            default: keyName = part
            }
        }
        guard let code = keyCode(for: keyName) else { return nil }
        return (modifiers, code)
    }

    private static func keyCode(for name: String) -> UInt32? {
        let special: [String: UInt32] = [
            "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53,
            "delete": 51, "backspace": 51, "up": 126, "down": 125, "left": 123,
            "right": 124, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
            "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103,
            "f12": 111, "quote": 39, "period": 47, "comma": 43, "slash": 44,
            "semicolon": 41, "equal": 24, "minus": 27, "bracketleft": 33,
            "bracketright": 30, "backslash": 42,
        ]
        if let code = special[name] { return code }
        if name.count == 1, let scalar = name.unicodeScalars.first {
            let base: UInt32
            if scalar.value >= 97 && scalar.value <= 122 { // a-z
                base = scalar.value - 97 // kVK_ANSI_A == 0
            } else if scalar.value >= 48 && scalar.value <= 57 { // 0-9
                base = scalar.value - 48 + 18 // kVK_ANSI_0 == 29, 1 == 18
            } else {
                return nil
            }
            return base
        }
        return nil
    }
}
