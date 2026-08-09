import AppKit
import QuartzCore

/// Floating "audio pill" below the menu bar / notch while dictating.
///
/// Premium, HIG-minded transient indicator: a frosted-glass black capsule with
/// a soft shadow, a smooth live waveform while recording, spinner + label
/// while transcribing, text preview when done. Slow, gentle animations: a
/// subtle scale pop on appear and a calm fade on dismiss.
final class DictationPill: NSPanel {
    enum PillState {
        case recording
        case transcribing
        case result(String)
        case hidden
    }

    private let label = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private let waveform = WaveformView()
    private let dotsView = DotsView()
    private let container = NSView()
    private let resultStack = NSStackView()

    private static let pillWidth: CGFloat = 100
    private static let pillHeight: CGFloat = 34

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.pillWidth, height: Self.pillHeight),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        configureUI()
    }

    private func configureUI() {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.pillHeight / 2
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        contentView?.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            container.topAnchor.constraint(equalTo: contentView!.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
        ])

        // pitch-black capsule with a hairline border (per the HIG: simple,
        // high-contrast transient indicator — no failed-transparency grays)
        let black = NSView()
        black.wantsLayer = true
        black.layer?.backgroundColor = NSColor.black.cgColor
        black.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(black)
        NSLayoutConstraint.activate([
            black.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            black.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            black.topAnchor.constraint(equalTo: container.topAnchor),
            black.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            border.topAnchor.constraint(equalTo: container.topAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .white
        label.alignment = .center

        check.translatesAutoresizingMaskIntoConstraints = false
        check.image = DictationPill.symbol("checkmark.circle.fill", tint: .systemGreen)
        check.imageScaling = .scaleProportionallyDown

        resultStack.translatesAutoresizingMaskIntoConstraints = false
        resultStack.orientation = .horizontal
        resultStack.alignment = .centerY
        resultStack.spacing = 4
        resultStack.addArrangedSubview(check)
        resultStack.addArrangedSubview(label)
        resultStack.isHidden = true

        waveform.translatesAutoresizingMaskIntoConstraints = false
        dotsView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(resultStack)
        container.addSubview(waveform)
        container.addSubview(dotsView)

        NSLayoutConstraint.activate([
            resultStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            resultStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),
            check.heightAnchor.constraint(equalToConstant: 12),

            waveform.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            waveform.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 80),
            waveform.heightAnchor.constraint(equalToConstant: 20),

            dotsView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            dotsView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            dotsView.widthAnchor.constraint(equalToConstant: 29),
            dotsView.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    // MARK: - Placement

    private func positionBelowMenuBar() {
        // the screen the user is working on (where the pointer is), falling
        // back to the primary display
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.screens.first
            ?? NSScreen.main
        guard let screen else { return }
        let frame = screen.frame
        let visible = screen.visibleFrame
        // dead-center under the notch: center of the FULL screen width
        // (visibleFrame is inset by the Dock and would shift the pill sideways)
        let x = frame.midX - Self.pillWidth / 2
        // hug the menu bar: visibleFrame.maxY is its bottom edge
        let y = visible.maxY - Self.pillHeight - 5
        let rect = NSRect(x: x, y: y, width: Self.pillWidth, height: Self.pillHeight)
        NSLog("Transcribe pill frame=%@ screen=%@", NSStringFromRect(rect), NSStringFromRect(frame))
        setFrame(rect, display: false)
    }

    // MARK: - States

    func show(_ state: PillState) {
        DispatchQueue.main.async { [self] in
            positionBelowMenuBar()
            switch state {
            case .recording:
                // pure waveform, nothing else — always centered
                resultStack.isHidden = true
                waveform.isHidden = false
                stopDots()
                appear(from: 0.95)
            case .transcribing:
                // minimal pulsing dots, no text
                resultStack.isHidden = true
                waveform.isHidden = true
                startDots()
                appear(from: 1.0)
            case .result:
                // ✓ Transcribed — no truncated text preview
                stopDots()
                waveform.isHidden = true
                resultStack.isHidden = false
                label.stringValue = "Transcribed"
                appear(from: 1.0)
                hide(after: 1.8)
            case .hidden:
                dismiss()
            }
        }
    }

    func updateLevel(_ value: Float) {
        waveform.level = value
    }

    private func startDots() {
        dotsView.isHidden = false
        dotsView.start()
    }

    private func stopDots() {
        dotsView.isHidden = true
        dotsView.stop()
    }

    static func symbol(_ name: String, tint: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        // draw the glyph first, then paint the tint over its alpha (sourceAtop)
        return NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    func hide(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.alphaValue > 0 else { return }
            self.show(.hidden)
        }
    }

    // MARK: - Animations (slow + gentle)

    private func appear(from scale: CGFloat) {
        // set the starting transform now, then animate to full size (identity),
        // so the pill always ends at the same size in every state
        container.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.layer?.setAffineTransform(.identity)
            alphaValue = 1
        }
        orderFrontRegardless()
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.40
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            alphaValue = 0
            container.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.96, y: 0.96))
        }, completionHandler: { [self] in
            orderOut(nil)
            container.layer?.setAffineTransform(.identity)
            stopDots()
        })
    }
}

/// Smooth, continuous waveform: 41 thin bars with quadratic taper, phase drift
/// and gentle attack/decay so it looks calm and alive — Voice Memos style.
final class WaveformView: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    private var displayLevel: Float = 0
    private var phase: Float = 0
    private var timer: Timer?
    private let barCount = 31
    private let centerIndex = 15

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        startAnimation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        startAnimation()
    }

    deinit { timer?.invalidate() }

    private func startAnimation() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.displayLevel += (self.level - self.displayLevel) * 0.20
            self.phase += 0.16
            self.needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 80, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        let barW: CGFloat = 1.6
        let gap: CGFloat = 1.0
        let totalW = CGFloat(barCount) * (barW + gap) - gap
        let maxH = bounds.height
        var x = (bounds.width - totalW) / 2
        let env = CGFloat(displayLevel)

        // symmetric envelope: the shape is even around the center at every
        // instant (cos is symmetric), and only the overall amplitude breathes
        // with sin(phase) — the wave can never look shifted left or right
        var heights = [CGFloat](repeating: 0, count: barCount)
        for i in 0..<barCount {
            let dist = CGFloat(abs(i - centerIndex)) / CGFloat(centerIndex)
            let taper = 1.0 - dist * dist * 0.85
            let breath = 0.5 + 0.5 * CGFloat(sin(Double(phase)))
            let shape = CGFloat(cos(Double(i - centerIndex) * 0.45))
            heights[i] = maxH * taper * (0.06 + 0.94 * env * breath * (0.35 + 0.65 * shape))
        }
        var smoothed = heights
        for i in 1..<(barCount - 1) {
            smoothed[i] = (heights[i - 1] + 2 * heights[i] + heights[i + 1]) / 4
        }

        for i in 0..<barCount {
            // fully symmetric, pure white — no red accents to skew the visual
            // center of the pill relative to the notch
            NSColor.white.withAlphaComponent(0.95).setFill()
            let rect = NSRect(x: x, y: (bounds.height - smoothed[i]) / 2,
                              width: barW, height: max(smoothed[i], 2))
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
    }
}


/// Minimal processing indicator: three small white dots pulsing in sequence —
/// the standard typing/processing pattern (iMessage-style). No rotation.
final class DotsView: NSView {
    private var dotLayers: [CALayer] = []
    private let dotCount = 3
    private let diameter: CGFloat = 5
    private let gap: CGFloat = 6

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
            dot.backgroundColor = NSColor.white.cgColor
            dot.opacity = 0.25
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
            if dot.animation(forKey: "pulse") != nil { continue }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 1.0
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(i) * 0.23
            dot.add(pulse, forKey: "pulse")
        }
    }

    func stop() {
        for dot in dotLayers {
            dot.removeAnimation(forKey: "pulse")
            dot.opacity = 0.25
        }
    }
}
