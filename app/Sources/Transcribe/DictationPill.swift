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
    private let waveform = WaveformView()
    private let spinner = NSProgressIndicator()
    private let container = NSView()

    private static let pillWidth: CGFloat = 204
    private static let pillHeight: CGFloat = 48

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

        // frosted-glass background with a dark tint
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tint.topAnchor.constraint(equalTo: container.topAnchor),
            tint.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center

        waveform.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        container.addSubview(label)
        container.addSubview(waveform)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 160),

            waveform.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            waveform.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 104),
            waveform.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    // MARK: - Placement

    private func positionBelowMenuBar() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - Self.pillWidth / 2
        let y = visible.maxY - Self.pillHeight - 12
        setFrame(NSRect(x: x, y: y, width: Self.pillWidth, height: Self.pillHeight),
                 display: false)
    }

    // MARK: - States

    func show(_ state: PillState) {
        DispatchQueue.main.async { [self] in
            positionBelowMenuBar()
            switch state {
            case .recording:
                waveform.isHidden = false
                label.isHidden = true
                spinner.stopAnimation(nil)
                spinner.removeFromSuperview()
                appear(scale: 0.92)
            case .transcribing:
                waveform.isHidden = true
                label.isHidden = false
                label.stringValue = "Transcribing…"
                container.addSubview(spinner)
                spinner.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    spinner.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
                    spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                ])
                spinner.startAnimation(nil)
                appear(scale: 1.0)
            case .result(let text):
                spinner.stopAnimation(nil)
                spinner.removeFromSuperview()
                waveform.isHidden = true
                label.isHidden = false
                label.stringValue = String(text.prefix(20)) + (text.count > 20 ? "…" : "")
                appear(scale: 1.0)
                hide(after: 2.4)
            case .hidden:
                dismiss()
            }
        }
    }

    func updateLevel(_ value: Float) {
        waveform.level = value
    }

    func hide(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.alphaValue > 0 else { return }
            self.show(.hidden)
        }
    }

    // MARK: - Animations (slow + gentle)

    private func appear(scale: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
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
            spinner.stopAnimation(nil)
            spinner.removeFromSuperview()
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
    private let barCount = 41
    private let centerIndex = 20

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

    override var intrinsicContentSize: NSSize { NSSize(width: 104, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let barW: CGFloat = 2.2
        let gap: CGFloat = 1.4
        let totalW = CGFloat(barCount) * (barW + gap) - gap
        let maxH = bounds.height
        var x = (bounds.width - totalW) / 2
        let env = CGFloat(displayLevel)

        // envelope per bar, then one smoothing pass for a continuous silhouette
        var heights = [CGFloat](repeating: 0, count: barCount)
        for i in 0..<barCount {
            let dist = CGFloat(abs(i - centerIndex)) / CGFloat(centerIndex)
            let taper = 1.0 - dist * dist * 0.85
            let wave = 0.5 + 0.5 * CGFloat(sin(Double(phase) + Double(i) * 0.45))
            heights[i] = maxH * taper * (0.06 + 0.94 * env * wave)
        }
        var smoothed = heights
        for i in 1..<(barCount - 1) {
            smoothed[i] = (heights[i - 1] + 2 * heights[i] + heights[i + 1]) / 4
        }

        for i in 0..<barCount {
            let hot = env > 0.75 && i >= barCount - 4
            (hot ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.95)).setFill()
            let rect = NSRect(x: x, y: (bounds.height - smoothed[i]) / 2,
                              width: barW, height: max(smoothed[i], 2))
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
    }
}
