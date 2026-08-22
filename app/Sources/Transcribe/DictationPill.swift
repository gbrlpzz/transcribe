import AppKit
import QuartzCore

/// Floating "audio pill" anchored below the menu bar / notch while dictating.
///
/// Regola-grade HUD crafted following Apple Human Interface Guidelines:
/// - Liquid Dynamic Island morphology: fluid state transitions and continuous spring resizing.
/// - Interactive Tap-to-Cancel: click or tap the HUD to discard dictation immediately.
/// - Calmed monochrome glass: dark vibrant backdrop, obsidian core, and specular hairline rim.
/// - Notch-aware positioning: dead-centered under the hardware notch or menu bar.
/// - 60 FPS live waveform: multi-band sound-reactive capsule bars with peak attack/decay ballistics
///   and subtle organic idle ripple when silent.
/// - Crisp typography: SF Pro Medium text paired with semantic SF Symbols.
final class DictationPill: NSPanel {
    enum PillState: Equatable {
        /// Live waveform with pulsing beacon.
        case recording
        /// Spinner; carries a file name when transcribing a dropped file.
        case transcribing(fileName: String?)
        /// Transient status flash that auto-dismisses.
        case flash(Flash)
        /// User-initiated cancel: quick upward glide into the notch aperture.
        case cancelled
        /// Fully hidden.
        case hidden

        struct Flash: Equatable {
            enum Kind {
                case success       // dictation transcribed
                case fileSuccess   // file job finished
                case empty         // nothing heard
                case failure       // error with message
            }

            let kind: Kind
            let message: String
        }

        // Convenience constructors preserving the historical call-site
        // vocabulary. The old result/fileResult payloads were never read by
        // show() and are gone.
        static var success: PillState { .flash(Flash(kind: .success, message: "")) }
        static var fileSuccess: PillState { .flash(Flash(kind: .fileSuccess, message: "")) }
        static var empty: PillState { .flash(Flash(kind: .empty, message: "")) }
        static func error(_ message: String) -> PillState {
            .flash(Flash(kind: .failure, message: message))
        }
    }

    private static let pillHeight: CGFloat = 34
    private static let minWidth: CGFloat = 132
    private static let mediumWidth: CGFloat = 112
    // Keep transparent room around the capsule so its custom shadow is never
    // clipped by the borderless panel's rectangular backing surface.
    private static let shadowPadding: CGFloat = 18

    var onCancel: ((PillState) -> Void)?
    var onHidden: (() -> Void)?

    private var currentState: PillState = .hidden
    private var dismissWorkItem: DispatchWorkItem?
    private var compactMode = false
    private var circleMode = false
    private var horizontalOffset: CGFloat = 0
    private var waveformWidthConstraint: NSLayoutConstraint!

    // UI hierarchy
    private let container = PillContainerView()
    private let visualEffect = NSVisualEffectView()
    private let darkOverlay = NSView()
    private let specularBorder = CALayer()
    private let topHighlight = CAGradientLayer()

    // State container stacks
    private let recordingStack = NSStackView()
    private let recordingDot = RecordingDotView()
    private let waveform = WaveformView()

    private let transcribingStack = NSStackView()
    private let activityIndicator = NSProgressIndicator()
    private let transcribingLabel = NSTextField(labelWithString: "Transcribing…")

    private let statusStack = NSStackView()
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        let initialWidth: CGFloat = 140 + (Self.shadowPadding * 2)
        let initialHeight = Self.pillHeight + (Self.shadowPadding * 2)
        super.init(contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // NSWindow.hasShadow renders the whole rectangular window frame. That
        // produces the straight-edged shadow visible around a capsule. The
        // capsule owns its own path-based shadow below instead.
        hasShadow = false
        isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        contentView = PillRootView(frame: .zero)
        acceptsMouseMovedEvents = true
        configureUI()
    }

    /// Set the HUD's role in the notch cluster. Compact live feedback sits
    /// to the left of the primary file status circle when both are active.
    func setPresentation(compact: Bool, circle: Bool = false,
                         horizontalOffset: CGFloat = 0) {
        self.compactMode = compact
        self.circleMode = circle
        self.horizontalOffset = horizontalOffset
        guard currentState != .hidden else { return }
        show(currentState)
    }

    // MARK: - View Configuration

    /// Pin all four edges of `view` to `anchor`.
    private func pinEdges(_ view: NSView, to anchor: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: anchor.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: anchor.trailingAnchor),
            view.topAnchor.constraint(equalTo: anchor.topAnchor),
            view.bottomAnchor.constraint(equalTo: anchor.bottomAnchor),
        ])
    }

    /// Shared horizontal stack setup for the three state containers.
    private func configureStack(_ stack: NSStackView, spacing: CGFloat, alpha: CGFloat = 1) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        stack.alphaValue = alpha
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: Self.pillHeight),
        ])
    }

    private func configureUI() {
        guard let root = contentView else { return }

        // Root interactive container
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.pillHeight / 2
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = false
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.38
        container.layer?.shadowRadius = 10
        container.layer?.shadowOffset = CGSize(width: 0, height: -4)
        container.onPillClick = { [weak self] in
            guard let self else { return }
            switch self.currentState {
            case .recording, .transcribing:
                self.onCancel?(self.currentState)
            case .flash, .cancelled, .hidden:
                break
            }
        }
        if let root = root as? PillRootView {
            root.interactiveView = container
        }
        root.addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                                constant: Self.shadowPadding),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                 constant: -Self.shadowPadding),
            container.topAnchor.constraint(equalTo: root.topAnchor,
                                           constant: Self.shadowPadding),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                              constant: -Self.shadowPadding),
        ])

        // 1. Apple HIG Frosted Glass Material
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.appearance = NSAppearance(named: .vibrantDark)
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = Self.pillHeight / 2
        visualEffect.layer?.cornerCurve = .continuous
        visualEffect.layer?.masksToBounds = true
        container.addSubview(visualEffect)

        pinEdges(visualEffect, to: container)

        // 2. Obsidian Core Overlay (pitch-black calm contrast over blur)
        darkOverlay.translatesAutoresizingMaskIntoConstraints = false
        darkOverlay.wantsLayer = true
        darkOverlay.layer?.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 0.90).cgColor
        visualEffect.addSubview(darkOverlay)

        pinEdges(darkOverlay, to: visualEffect)

        // 3. Specular Hairline Rim Border
        specularBorder.borderColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        specularBorder.borderWidth = 0.5
        specularBorder.cornerRadius = Self.pillHeight / 2
        specularBorder.cornerCurve = .continuous
        container.layer?.addSublayer(specularBorder)

        // 4. Subtle Top Specular Edge Highlight
        topHighlight.colors = [
            NSColor(white: 1.0, alpha: 0.20).cgColor,
            NSColor(white: 1.0, alpha: 0.0).cgColor,
        ]
        topHighlight.startPoint = CGPoint(x: 0.5, y: 1.0)
        topHighlight.endPoint = CGPoint(x: 0.5, y: 0.0)
        topHighlight.cornerRadius = Self.pillHeight / 2
        topHighlight.cornerCurve = .continuous
        visualEffect.layer?.addSublayer(topHighlight)

        // The panel itself has no shadow: its frame is intentionally larger
        // than the capsule to give this layer room to render a rounded shadow.
        // PillContainerView updates the shadow path after Auto Layout lays out
        // the capsule, so the path always follows its real bounds.

        configureRecordingStack()
        configureTranscribingStack()
        configureStatusStack()
    }

    private func configureRecordingStack() {
        configureStack(recordingStack, spacing: 10)
        recordingDot.translatesAutoresizingMaskIntoConstraints = false
        waveform.translatesAutoresizingMaskIntoConstraints = false

        recordingStack.addArrangedSubview(recordingDot)
        recordingStack.addArrangedSubview(waveform)
        waveformWidthConstraint = waveform.widthAnchor.constraint(equalToConstant: 82)

        NSLayoutConstraint.activate([
            recordingDot.widthAnchor.constraint(equalToConstant: 8),
            recordingDot.heightAnchor.constraint(equalToConstant: 8),

            waveformWidthConstraint,
            waveform.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    private func configureTranscribingStack() {
        configureStack(transcribingStack, spacing: 8, alpha: 0)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        activityIndicator.isIndeterminate = true
        activityIndicator.isDisplayedWhenStopped = false
        activityIndicator.appearance = NSAppearance(named: .vibrantDark)
        styleStatusLabel(transcribingLabel, textColor: NSColor(white: 0.90, alpha: 1.0))

        transcribingStack.addArrangedSubview(activityIndicator)
        transcribingStack.addArrangedSubview(transcribingLabel)

        NSLayoutConstraint.activate([
            activityIndicator.widthAnchor.constraint(equalToConstant: 16),
            activityIndicator.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func configureStatusStack() {
        configureStack(statusStack, spacing: 6, alpha: 0)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.imageScaling = .scaleProportionallyDown
        styleStatusLabel(statusLabel, textColor: .white)

        statusStack.addArrangedSubview(statusIcon)
        statusStack.addArrangedSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private func styleStatusLabel(_ label: NSTextField, textColor: NSColor) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = textColor
        label.alignment = .left
    }

    // MARK: - Geometry & Notch Placement

    private func targetRect(forWidth width: CGFloat) -> NSRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return nil }

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let panelWidth = width + (Self.shadowPadding * 2)
        let panelHeight = Self.pillHeight + (Self.shadowPadding * 2)
        let x = round(screenFrame.midX - panelWidth / 2 + horizontalOffset)

        let topY: CGFloat
        if screen.safeAreaInsets.top > 0 {
            // Display has a hardware notch: anchor below the notch
            topY = screenFrame.maxY - screen.safeAreaInsets.top
        } else {
            // Standard screen / external monitor: anchor below the menu bar
            topY = visibleFrame.maxY
        }

        // The visible capsule remains seven points below the notch/menu bar.
        // The panel origin is one capsule height plus the padding below that
        // anchor because AppKit's origin is the panel's bottom edge.
        let y = topY - Self.pillHeight - 7 - Self.shadowPadding
        return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }

    private func updateLayerFrames() {
        let bounds = container.bounds
        specularBorder.frame = bounds
        topHighlight.frame = CGRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
    }

    // MARK: - State Management & Liquid Transitions

    /// One row of the per-state configuration table. Everything show() does is
    /// a pure function of this struct plus the compact/circle presentation
    /// flags, so every state stays visually consistent by construction.
    private struct StateConfig {
        enum ActiveStack { case recording, transcribing, status }

        let stack: ActiveStack
        /// SF Symbol + tint for the status stack (nil for non-status states).
        let icon: (name: String, tint: NSColor)?
        let label: String
        let tooltip: String?
        /// Non-nil flashes auto-dismiss after this delay.
        let autoDismissAfter: TimeInterval?
        /// Live-dictation vocabulary: honor compactMode for insets and medium
        /// width. File jobs always render full-size insets and width.
        let liveSizing: Bool
    }

    private func config(for state: PillState) -> StateConfig? {
        switch state {
        case .recording:
            return StateConfig(stack: .recording, icon: nil, label: "",
                               tooltip: "Click to cancel dictation (or press Esc)",
                               autoDismissAfter: nil, liveSizing: true)
        case .transcribing(let fileName):
            return StateConfig(stack: .transcribing, icon: nil,
                               label: "Transcribing…",
                               tooltip: fileName.map { "Click to cancel file transcription: \($0)" }
                                   ?? "Click to cancel transcription (or press Esc)",
                               autoDismissAfter: nil, liveSizing: fileName == nil)
        case .flash(let flash):
            let icon: (name: String, tint: NSColor)
            let label: String
            switch flash.kind {
            case .success:
                icon = ("checkmark.circle.fill", .systemGreen); label = "Transcribed"
            case .fileSuccess:
                icon = ("checkmark.circle.fill", .systemGreen); label = "File transcribed"
            case .empty:
                icon = ("mic.slash.fill", NSColor(white: 0.65, alpha: 1.0)); label = "Nothing Heard"
            case .failure:
                icon = ("exclamationmark.circle.fill", .systemOrange)
                label = flash.message.isEmpty ? "Failed" : flash.message
            }
            let delay: TimeInterval? = [.success: 1.6, .fileSuccess: 1.6,
                                        .empty: 1.5, .failure: 2.0][flash.kind]
            return StateConfig(stack: .status, icon: icon, label: label, tooltip: nil,
                               autoDismissAfter: delay, liveSizing: flash.kind != .fileSuccess)
        case .cancelled, .hidden:
            return nil
        }
    }

    func show(_ state: PillState) {
        DispatchQueue.main.async { [self] in
            guard !(state == .hidden && currentState == .hidden && alphaValue == 0) else { return }
            dismissWorkItem?.cancel()
            dismissWorkItem = nil

            let previousState = currentState
            currentState = state

            guard let config = config(for: state) else {
                // Cancel glides away briskly; a timed-out flash eases out gently.
                glideAway(duration: state == .cancelled ? 0.20 : 0.26,
                          scale: state == .cancelled ? 0.88 : 0.94,
                          lift: state == .cancelled ? 8 : 4)
                return
            }
            apply(config, isNewAppearance: previousState == .hidden)
        }
    }

    private func apply(_ config: StateConfig, isNewAppearance: Bool) {
        container.toolTip = config.tooltip

        // Padded insets size the capsule around its content; collapsed insets
        // shrink a stack into the circular mode. Inactive stacks keep padded
        // values so morphs never pop.
        let edge: CGFloat = config.liveSizing && compactMode ? 12 : 16
        let padded = NSEdgeInsets(top: 0, left: edge, bottom: 0, right: edge)
        recordingStack.edgeInsets = padded
        transcribingStack.edgeInsets = circleMode && config.stack != .transcribing
            ? NSEdgeInsets() : padded
        statusStack.edgeInsets = circleMode && config.stack != .status
            ? NSEdgeInsets() : padded
        statusLabel.isHidden = circleMode
        transcribingLabel.isHidden = circleMode
        waveformWidthConstraint.constant = compactMode ? 64 : 82

        switch config.stack {
        case .recording:
            recordingDot.startPulsing()
            waveform.start()
            activityIndicator.stopAnimation(nil)
        case .transcribing:
            transcribingLabel.stringValue = config.label
            recordingDot.stopPulsing()
            waveform.stop()
            activityIndicator.startAnimation(nil)
        case .status:
            statusIcon.image = config.icon.flatMap { Self.symbol($0.name, tint: $0.tint) }
            statusLabel.stringValue = config.label
            recordingDot.stopPulsing()
            waveform.stop()
            activityIndicator.stopAnimation(nil)
        }

        let active = stacks[config.stack]!
        let width = circleMode ? Self.pillHeight
            : (config.liveSizing && compactMode ? Self.mediumWidth
                : max(Self.minWidth, active.fittingSize.width + 4))
        transition(toWidth: width,
                   activeView: active,
                   inactiveViews: stacks.values.filter { $0 !== active },
                   isNewAppearance: isNewAppearance)

        if let delay = config.autoDismissAfter {
            scheduleDismiss(after: delay)
        }
    }

    /// The three state container stacks, keyed for generic state application.
    private var stacks: [StateConfig.ActiveStack: NSView] {
        [.recording: recordingStack, .transcribing: transcribingStack, .status: statusStack]
    }

    func updateLevel(_ value: Float) {
        waveform.level = value
    }

    func cancel() {
        show(.cancelled)
    }

    private func transition(toWidth width: CGFloat,
                            activeView: NSView,
                            inactiveViews: [NSView],
                            isNewAppearance: Bool) {
        guard let rect = targetRect(forWidth: width) else { return }

        if isNewAppearance {
            setFrame(rect, display: false)
            contentView?.layoutSubtreeIfNeeded()
            updateLayerFrames()
            activeView.alphaValue = 1
            for v in inactiveViews { v.alphaValue = 0 }

            // Spring appear from notch
            container.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.94, y: 0.94).translatedBy(x: 0, y: 6))
            alphaValue = 0
            orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                container.layer?.setAffineTransform(.identity)
                animator().alphaValue = 1.0
            }
        } else {
            // Fluid morphing transition between states
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setFrame(rect, display: true)
                activeView.animator().alphaValue = 1.0
                for v in inactiveViews {
                    v.animator().alphaValue = 0.0
                }
            }, completionHandler: { [weak self] in
                self?.contentView?.layoutSubtreeIfNeeded()
                self?.updateLayerFrames()
            })
        }
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
        recordingDot.stopPulsing()
        waveform.stop()
        activityIndicator.stopAnimation(nil)
        container.toolTip = nil

        // Swift upward glide into the notch aperture
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
            container.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: 0, y: lift))
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.container.layer?.setAffineTransform(.identity)
            self.currentState = .hidden
            self.onHidden?()
        })
    }

    static func symbol(_ name: String, tint: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        return NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

// MARK: - Transparent Panel Hit Testing

/// The panel has extra transparent space for the capsule shadow. Only the
/// capsule itself should receive clicks; the shadow padding must remain
/// click-through to the app underneath.
final class PillRootView: NSView {
    weak var interactiveView: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let interactiveView, interactiveView.frame.contains(point) else {
            return nil
        }
        return interactiveView
    }
}

// MARK: - Interactive Pill Container View

final class PillContainerView: NSView {
    var onPillClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Keep the shadow capsule-shaped after every Auto Layout pass. A
        // shadowPath is important here: without it Core Animation can fall
        // back to the view's rectangular bounds.
        layer?.shadowPath = CGPath(roundedRect: bounds,
                                    cornerWidth: bounds.height / 2,
                                    cornerHeight: bounds.height / 2,
                                    transform: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        // Play subtle click spring bounce
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.setAffineTransform(CGAffineTransform(scaleX: 0.95, y: 0.95))
        }
        onPillClick?()
    }
}

// MARK: - Live Recording Beacon Dot

final class RecordingDotView: NSView {
    private let dotLayer = CALayer()
    private let haloLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupDot()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupDot()
    }

    private func setupDot() {
        // Soft glowing halo
        haloLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.3).cgColor
        haloLayer.cornerRadius = 4.0
        haloLayer.opacity = 0
        layer?.addSublayer(haloLayer)

        // Core bright red dot
        dotLayer.backgroundColor = NSColor.systemRed.cgColor
        dotLayer.cornerRadius = 3.5
        layer?.addSublayer(dotLayer)
    }

    override func layout() {
        super.layout()
        dotLayer.frame = CGRect(x: (bounds.width - 7) / 2, y: (bounds.height - 7) / 2, width: 7, height: 7)
        haloLayer.frame = bounds
    }

    func startPulsing() {
        if dotLayer.animation(forKey: "breathe") != nil { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.70
        pulse.toValue = 1.0
        pulse.duration = 0.85
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayer.add(pulse, forKey: "breathe")

        let haloPulse = CABasicAnimation(keyPath: "opacity")
        haloPulse.fromValue = 0.15
        haloPulse.toValue = 0.60
        haloPulse.duration = 0.85
        haloPulse.autoreverses = true
        haloPulse.repeatCount = .infinity
        haloPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        haloLayer.add(haloPulse, forKey: "halo")
    }

    func stopPulsing() {
        dotLayer.removeAnimation(forKey: "breathe")
        haloLayer.removeAnimation(forKey: "halo")
        dotLayer.opacity = 1.0
        haloLayer.opacity = 0.0
    }
}

// MARK: - 60 FPS Multi-Band Audio Visualizer

final class WaveformView: NSView {
    var level: Float = 0

    private var targetLevel: Float = 0
    private var smoothedLevel: Float = 0
    private var phase: Float = 0
    private var timer: Timer?

    private let barCount = 19
    private let centerIndex = 9

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        stop()
    }

    func start() {
        guard timer == nil else { return }

        // High-framerate (60 FPS) rendering loop in common runloop mode. The
        // HUD is transient, so do not spend a timer and redraw budget while it
        // is hidden.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.targetLevel = self.level

            // Organic audio ballistics: fast attack, smooth exponential decay
            if self.targetLevel > self.smoothedLevel {
                self.smoothedLevel += (self.targetLevel - self.smoothedLevel) * 0.40
            } else {
                self.smoothedLevel += (self.targetLevel - self.smoothedLevel) * 0.10
            }

            self.phase += 0.08
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        level = 0
        targetLevel = 0
        smoothedLevel = 0
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 82, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        let barW: CGFloat = 2.0
        let gap: CGFloat = 2.2
        let totalW = CGFloat(barCount) * (barW + gap) - gap
        let maxH = bounds.height - 4
        var x = (bounds.width - totalW) / 2
        let env = CGFloat(smoothedLevel)

        // Gaussian bell curve + dual traveling harmonic waves
        var heights = [CGFloat](repeating: 0, count: barCount)
        for i in 0..<barCount {
            let dist = CGFloat(abs(i - centerIndex)) / CGFloat(centerIndex)
            // Gaussian bell taper
            let taper = exp(-dist * dist * 1.8)

            // Organic idle breathing wave when silent (so it never looks frozen)
            let idleWave = CGFloat(sin(Double(phase) * 1.8 + Double(i) * 0.45)) * 1.2
            let baseHeight: CGFloat = 3.0 + idleWave * taper

            // Voice reactive wave
            let voiceWave = 0.55 + 0.45 * CGFloat(sin(Double(phase) * 3.5 + Double(i) * 0.85))
            let activeHeight = maxH * taper * env * voiceWave

            heights[i] = max(2.5, min(maxH, baseHeight + activeHeight))
        }

        // Single smoothing pass for liquid contour continuity
        var smoothed = heights
        for i in 1..<(barCount - 1) {
            smoothed[i] = (heights[i - 1] + 2 * heights[i] + heights[i + 1]) / 4
        }

        for i in 0..<barCount {
            let dist = CGFloat(abs(i - centerIndex)) / CGFloat(centerIndex)
            // Edge bars are slightly more transparent for visual depth
            let alpha = 0.96 - dist * 0.22
            NSColor.white.withAlphaComponent(alpha).setFill()

            let h = smoothed[i]
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: barW, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2)
            path.fill()

            x += barW + gap
        }
    }
}
