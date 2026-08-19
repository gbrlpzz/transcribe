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
        case recording
        case transcribing
        case result(String)
        case empty
        case error(String)
        case cancelled
        case hidden
    }

    private static let pillHeight: CGFloat = 34
    private static let minWidth: CGFloat = 132
    // Keep transparent room around the capsule so its custom shadow is never
    // clipped by the borderless panel's rectangular backing surface.
    private static let shadowPadding: CGFloat = 18

    var onCancel: (() -> Void)?

    private var currentState: PillState = .hidden
    private var dismissWorkItem: DispatchWorkItem?

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
    private let dotsView = DotsView()
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

    // MARK: - View Configuration

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
            if self.currentState == .recording || self.currentState == .transcribing {
                self.onCancel?()
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

        NSLayoutConstraint.activate([
            visualEffect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            visualEffect.topAnchor.constraint(equalTo: container.topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // 2. Obsidian Core Overlay (pitch-black calm contrast over blur)
        darkOverlay.translatesAutoresizingMaskIntoConstraints = false
        darkOverlay.wantsLayer = true
        darkOverlay.layer?.backgroundColor = NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 0.90).cgColor
        visualEffect.addSubview(darkOverlay)

        NSLayoutConstraint.activate([
            darkOverlay.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            darkOverlay.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            darkOverlay.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            darkOverlay.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])

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
        recordingStack.translatesAutoresizingMaskIntoConstraints = false
        recordingStack.wantsLayer = true
        recordingStack.orientation = .horizontal
        recordingStack.alignment = .centerY
        recordingStack.spacing = 10
        recordingStack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        container.addSubview(recordingStack)

        recordingDot.translatesAutoresizingMaskIntoConstraints = false
        waveform.translatesAutoresizingMaskIntoConstraints = false

        recordingStack.addArrangedSubview(recordingDot)
        recordingStack.addArrangedSubview(waveform)

        NSLayoutConstraint.activate([
            recordingStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            recordingStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            recordingStack.heightAnchor.constraint(equalToConstant: Self.pillHeight),

            recordingDot.widthAnchor.constraint(equalToConstant: 8),
            recordingDot.heightAnchor.constraint(equalToConstant: 8),

            waveform.widthAnchor.constraint(equalToConstant: 82),
            waveform.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    private func configureTranscribingStack() {
        transcribingStack.translatesAutoresizingMaskIntoConstraints = false
        transcribingStack.wantsLayer = true
        transcribingStack.orientation = .horizontal
        transcribingStack.alignment = .centerY
        transcribingStack.spacing = 8
        transcribingStack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        transcribingStack.alphaValue = 0
        container.addSubview(transcribingStack)

        dotsView.translatesAutoresizingMaskIntoConstraints = false
        transcribingLabel.translatesAutoresizingMaskIntoConstraints = false
        transcribingLabel.font = .systemFont(ofSize: 11, weight: .medium)
        transcribingLabel.textColor = NSColor(white: 0.90, alpha: 1.0)
        transcribingLabel.alignment = .left

        transcribingStack.addArrangedSubview(dotsView)
        transcribingStack.addArrangedSubview(transcribingLabel)

        NSLayoutConstraint.activate([
            transcribingStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            transcribingStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            transcribingStack.heightAnchor.constraint(equalToConstant: Self.pillHeight),

            dotsView.widthAnchor.constraint(equalToConstant: 24),
            dotsView.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    private func configureStatusStack() {
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.wantsLayer = true
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 6
        statusStack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        statusStack.alphaValue = 0
        container.addSubview(statusStack)

        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.imageScaling = .scaleProportionallyDown

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.alignment = .left

        statusStack.addArrangedSubview(statusIcon)
        statusStack.addArrangedSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusStack.heightAnchor.constraint(equalToConstant: Self.pillHeight),

            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
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
        let x = round(screenFrame.midX - panelWidth / 2)

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

    func show(_ state: PillState) {
        DispatchQueue.main.async { [self] in
            dismissWorkItem?.cancel()
            dismissWorkItem = nil

            let previousState = currentState
            currentState = state

            switch state {
            case .recording:
                container.toolTip = "Click to cancel dictation (or press Esc)"
                recordingDot.startPulsing()
                waveform.start()
                dotsView.stop()
                let width = max(Self.minWidth, recordingStack.fittingSize.width + 4)
                transition(toWidth: width,
                           activeView: recordingStack,
                           inactiveViews: [transcribingStack, statusStack],
                           isNewAppearance: previousState == .hidden)

            case .transcribing:
                container.toolTip = "Click to cancel transcription (or press Esc)"
                recordingDot.stopPulsing()
                waveform.stop()
                dotsView.start()
                let width = max(Self.minWidth, transcribingStack.fittingSize.width + 4)
                transition(toWidth: width,
                           activeView: transcribingStack,
                           inactiveViews: [recordingStack, statusStack],
                           isNewAppearance: previousState == .hidden)

            case .result:
                container.toolTip = nil
                recordingDot.stopPulsing()
                waveform.stop()
                dotsView.stop()
                statusIcon.image = Self.symbol("checkmark.circle.fill", tint: .systemGreen)
                statusLabel.stringValue = "Transcribed"
                let width = max(Self.minWidth, statusStack.fittingSize.width + 4)
                transition(toWidth: width,
                           activeView: statusStack,
                           inactiveViews: [recordingStack, transcribingStack],
                           isNewAppearance: previousState == .hidden)
                scheduleDismiss(after: 1.6)

            case .empty:
                container.toolTip = nil
                recordingDot.stopPulsing()
                waveform.stop()
                dotsView.stop()
                statusIcon.image = Self.symbol("mic.slash.fill", tint: NSColor(white: 0.65, alpha: 1.0))
                statusLabel.stringValue = "Nothing Heard"
                let width = max(Self.minWidth, statusStack.fittingSize.width + 4)
                transition(toWidth: width,
                           activeView: statusStack,
                           inactiveViews: [recordingStack, transcribingStack],
                           isNewAppearance: previousState == .hidden)
                scheduleDismiss(after: 1.5)

            case .error(let msg):
                container.toolTip = nil
                recordingDot.stopPulsing()
                waveform.stop()
                dotsView.stop()
                statusIcon.image = Self.symbol("exclamationmark.circle.fill", tint: .systemOrange)
                statusLabel.stringValue = msg.isEmpty ? "Failed" : msg
                let width = max(Self.minWidth, statusStack.fittingSize.width + 4)
                transition(toWidth: width,
                           activeView: statusStack,
                           inactiveViews: [recordingStack, transcribingStack],
                           isNewAppearance: previousState == .hidden)
                scheduleDismiss(after: 2.0)

            case .cancelled:
                cancelDismiss()

            case .hidden:
                dismiss()
            }
        }
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

    private func cancelDismiss() {
        recordingDot.stopPulsing()
        waveform.stop()
        dotsView.stop()
        container.toolTip = nil

        // Swift upward glide into the notch aperture
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
            container.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.88, y: 0.88).translatedBy(x: 0, y: 8))
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.container.layer?.setAffineTransform(.identity)
            self.currentState = .hidden
        })
    }

    private func dismiss() {
        recordingDot.stopPulsing()
        waveform.stop()
        dotsView.stop()
        container.toolTip = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
            container.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.94, y: 0.94).translatedBy(x: 0, y: 4))
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.orderOut(nil)
            self.container.layer?.setAffineTransform(.identity)
            self.currentState = .hidden
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
                                  options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
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

// MARK: - Undulating Transcribing Dots

final class DotsView: NSView {
    private var dotLayers: [CALayer] = []
    private let dotCount = 3
    private let diameter: CGFloat = 4.5
    private let gap: CGFloat = 4.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        makeDots()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        makeDots()
    }

    private func makeDots() {
        for _ in 0..<dotCount {
            let dot = CALayer()
            dot.backgroundColor = NSColor(white: 0.95, alpha: 1.0).cgColor
            dot.opacity = 0.35
            layer?.addSublayer(dot)
            dotLayers.append(dot)
        }
    }

    override func layout() {
        super.layout()
        let total = CGFloat(dotCount) * diameter + CGFloat(dotCount - 1) * gap
        for (i, dot) in dotLayers.enumerated() {
            dot.cornerRadius = diameter / 2
            dot.frame = CGRect(x: (bounds.width - total) / 2 + CGFloat(i) * (diameter + gap),
                               y: (bounds.height - diameter) / 2,
                               width: diameter, height: diameter)
        }
    }

    func start() {
        for (i, dot) in dotLayers.enumerated() {
            if dot.animation(forKey: "wave") != nil { continue }

            let group = CAAnimationGroup()
            group.duration = 0.95
            group.repeatCount = .infinity
            group.autoreverses = true
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.18

            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.35
            pulse.toValue = 1.0

            let lift = CABasicAnimation(keyPath: "transform.translation.y")
            lift.fromValue = 0
            lift.toValue = -2.0

            group.animations = [pulse, lift]
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(group, forKey: "wave")
        }
    }

    func stop() {
        for dot in dotLayers {
            dot.removeAnimation(forKey: "wave")
            dot.opacity = 0.35
        }
    }
}
