import AppKit
import CoreGraphics
import Foundation

/// Paste text into the frontmost app: put it on the pasteboard, then send Cmd+V
/// as a synthetic key event (requires Accessibility permission).
enum Paste {
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // let the pasteboard settle before synthesizing Cmd+V
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
}
