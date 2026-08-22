import AppKit
import CoreGraphics
import Foundation

/// Paste text into the frontmost app: put it on the pasteboard, then send Cmd+V
/// as a synthetic key event (requires Accessibility permission).
enum Paste {
    // Keep live dictation available for a short recovery window, then remove it
    // only if the user has not replaced it with another clipboard value.
    private static let liveClipboardTTL: TimeInterval = 60 * 60

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Empirical settle wait (field-proven since v0.2): although the
        // pasteboard write itself is synchronous, a synthetic Cmd+V fired in
        // the same event-loop tick as the dictation hotkey-up races the
        // frontmost app's input handling - several app families (Electron,
        // terminals) drop or misorder such events. The wait is not about the
        // pasteboard; it lets the target app finish processing prior input.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            postCommandV()
        }
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // kVK_ANSI_V
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    static func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func clearIfUnchanged(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + liveClipboardTTL) {
            let pb = NSPasteboard.general
            guard pb.string(forType: .string) == text else { return }
            pb.clearContents()
        }
    }
}
