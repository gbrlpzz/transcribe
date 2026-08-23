import AppKit
import QuartzCore

/// Floating stage-solid HUD anchored below the menu bar / notch while
/// dictating. The solid IS the interface: tetrahedron records, cube
/// transcribes, octahedron confirms. No capsule, no blur — a white
/// translucent precessing solid over a diffused contact shadow. Failures
/// stand the HUD down silently; alerts carry the news. Click to cancel.
final class DictationPill: NSPanel {
    enum PillState: Equatable {
        /// Live precessing tetrahedron.
        case recording
        /// Spinning cube; carries a file name when transcribing a dropped file.
        case transcribing(fileName: String?)
        /// Transient confirmation that auto-dismisses.
        case flash(Flash)
        case cancelled
        case hidden

        struct Flash: Equatable {
            enum Kind { case success, fileSuccess }
            let kind: Kind
        }
        static var success: PillState { .flash(.init(kind: .success)) }
        static var fileSuccess: PillState { .flash(.init(kind: .fileSuccess)) }
    }

    /// Edge of the solid — roughly twice the original pill mass, in the
    /// scale band of Apple's notch-adjacent HUD elements.
    private static let solidSize: CGFloat = 80
    /// Transparent margin around the solid for bloom + diffused shadow.
    private static let pad: CGFloat = 16

    var onCancel: ((PillState) -> Void)?
    var onHidden: (() -> Void)?

    private var currentState: PillState = .hidden
    private var dismissWorkItem: DispatchWorkItem?
    private var horizontalOffset: CGFloat = 0

    private let solid = DictationSolidView(frame: .zero)
    private var root: SolidHUDRoot!

    init() {
        let side = Self.solidSize + Self.pad * 2
        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The solid owns its diffused contact shadow; a rectangular window
        // shadow would draw straight edges around empty space.
        hasShadow = false
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        let r = SolidHUDRoot(frame: NSRect(x: 0, y: 0, width: side, height: side))
        r.onTap = { [weak self] in
            guard let self, let state = self.dismissableState else { return }
            self.onCancel?(state)
        }
        r.hitFrame = NSRect(x: Self.pad, y: Self.pad,
                            width: Self.solidSize, height: Self.solidSize)
        contentView = r
        root = r
        configureContent()
    }

    /// States a click may cancel (flashes dismiss on their own).
    private var dismissableState: PillState? {
        switch currentState {
        case .recording, .transcribing: return currentState
        default: return nil
        }
    }

    private func configureContent() {
        guard let root else { return }
        solid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(solid)
        let side = Self.solidSize
        NSLayoutConstraint.activate([
            solid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            solid.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 3),
            solid.widthAnchor.constraint(equalToConstant: side),
            solid.heightAnchor.constraint(equalToConstant: side),
        ])
    }

    /// Positions this HUD in the notch cluster: N visible solids distribute
    /// symmetrically around the notch center, 96 pt between solid centers.
    func setPresentation(horizontalOffset: CGFloat) {
        self.horizontalOffset = horizontalOffset
        guard currentState != .hidden else { return }
        show(currentState)
    }

    // MARK: - Placement (below notch / menu bar)

    private func targetRect() -> NSRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        guard let screen else { return nil }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let side = Self.solidSize + Self.pad * 2
        let x = round(screenFrame.midX - side / 2 + horizontalOffset)

        let topY: CGFloat
        if screen.safeAreaInsets.top > 0 {
            topY = screenFrame.maxY - screen.safeAreaInsets.top   // hardware notch
        } else {
            topY = visibleFrame.maxY                              // menu bar
        }
        // Visible solid sits seven points below the notch/menu bar anchor.
        let y = topY - Self.solidSize - 7 - Self.pad
        return NSRect(x: x, y: y, width: side, height: side)
    }

    // MARK: - State Machine

    func show(_ state: PillState) {
        DispatchQueue.main.async { [self] in
            guard !(state == .hidden && currentState == .hidden && alphaValue == 0) else { return }
            dismissWorkItem?.cancel()
            dismissWorkItem = nil

            let previousState = currentState
            currentState = state

            guard let appearance = Self.appearance(for: state) else {
                // Cancel glides away briskly; a timed-out flash eases out gently.
                glideAway(duration: state == .cancelled ? 0.20 : 0.26,
                          scale: state == .cancelled ? 0.88 : 0.94,
                          lift: state == .cancelled ? 8 : 4)
                return
            }
            apply(appearance, isNewAppearance: previousState == .hidden)
        }
    }

    private struct Appearance {
        let stage: DictationSolidView.Stage
        let tooltip: String?
        let autoDismissAfter: TimeInterval?
    }

    private static func appearance(for state: PillState) -> Appearance? {
        switch state {
        case .recording:
            return Appearance(stage: .recording,
                              tooltip: "Click to cancel dictation (or press Esc)",
                              autoDismissAfter: nil)
        case .transcribing(let fileName):
            return Appearance(stage: .transcribing,
                              tooltip: fileName.map { "Click to cancel file transcription: \($0)" }
                                  ?? "Click to cancel transcription (or press Esc)",
                              autoDismissAfter: nil)
        case .flash(let flash):
            // Settle takes 0.8 s; hold the still pose a moment after.
            let delay: TimeInterval? = [.success: 2.6, .fileSuccess: 2.6][flash.kind]
            return Appearance(stage: .success, tooltip: nil, autoDismissAfter: delay)
        case .cancelled, .hidden:
            return nil
        }
    }

    private func apply(_ appearance: Appearance, isNewAppearance: Bool) {
        root.toolTip = appearance.tooltip
        // Motion means working; stillness means done. The success octahedron
        // freezes at whatever angle the previous stage's spin left it at.
        solid.isSpinning = appearance.stage != .success
        solid.stage = appearance.stage

        guard let rect = targetRect() else { return }
        if isNewAppearance {
            setFrame(rect, display: false)
            contentView?.layoutSubtreeIfNeeded()
            root.layer?.setAffineTransform(
                CGAffineTransform(scaleX: 0.94, y: 0.94).translatedBy(x: 0, y: 6))
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                root.layer?.setAffineTransform(.identity)
                animator().alphaValue = 1.0
            }
        } else if frame != rect {
            // Screen changed under us; follow it without ceremony.
            setFrame(rect, display: true)
        }
        if let delay = appearance.autoDismissAfter {
            scheduleDismiss(after: delay)
        }
    }

    func cancel() {
        show(.cancelled)
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.alphaValue > 0 else { return }
            self.show(.hidden)
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Shared dismissal animation. A user cancel glides up quicker and tighter;
    /// a timed-out flash eases out more gently.
    private func glideAway(duration: TimeInterval, scale: CGFloat, lift: CGFloat) {
        solid.isSpinning = false
        root.toolTip = nil

        // Swift upward glide into the notch aperture
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
            root.layer?.setAffineTransform(
                CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: 0, y: lift))
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.root.layer?.setAffineTransform(.identity)
            self.currentState = .hidden
            self.onHidden?()
        })
    }

}

/// Transparent margin around the solid must stay click-through to the app
/// underneath; only the solid/glyph frame receives clicks.
final class SolidHUDRoot: NSView {
    var onTap: (() -> Void)?
    var hitFrame: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitFrame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { onTap?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
