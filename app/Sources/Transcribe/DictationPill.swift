import AppKit

/// Floating "audio pill" below the menu bar / notch while dictating.
///
/// HIG-minded transient indicator: compact (190×44), non-interactive, solid
/// black capsule with a soft shadow, centered live waveform while recording,
/// spinner + "Transcribing…" while processing, text preview when done, then it
/// fades away on its own. Small enough to never block what you are typing into.
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

    private static let pillWidth: CGFloat = 190
    private static let pillHeight: CGFloat = 44

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
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        container.layer?.cornerRadius = Self.pillHeight / 2
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView?.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            container.topAnchor.constraint(equalTo: contentView!.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
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
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 150),

            waveform.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            waveform.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            waveform.widthAnchor.constraint(equalToConstant: 92),
            waveform.heightAnchor.constraint(equalToConstant: 22),
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
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    alphaValue = 1
                }
                orderFrontRegardless()
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
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    alphaValue = 1
                }
                orderFrontRegardless()
            case .result(let text):
                spinner.stopAnimation(nil)
                spinner.removeFromSuperview()
                waveform.isHidden = true
                label.isHidden = false
                label.stringValue = String(text.prefix(20)) + (text.count > 20 ? "…" : "")
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    alphaValue = 1
                }
                orderFrontRegardless()
                hide(after: 1.6)
            case .hidden:
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.12
                    alphaValue = 0
                }, completionHandler: { [self] in
                    orderOut(nil)
                    spinner.stopAnimation(nil)
                    spinner.removeFromSuperview()
                })
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
}

/// Centered live waveform: smooth attack/decay on the mic level plus a gentle
/// phase drift so the bars look alive even in silence (Voice Memos style).
final class WaveformView: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    private var displayLevel: Float = 0
    private var phase: Float = 0
    private var timer: Timer?
    private let barCount = 19
    private let centerIndex: Int

    override init(frame frameRect: NSRect) {
        centerIndex = barCount / 2
        super.init(frame: frameRect)
        startIdleAnimation()
    }

    required init?(coder: NSCoder) {
        centerIndex = barCount / 2
        super.init(coder: coder)
        startIdleAnimation()
    }

    deinit { timer?.invalidate() }

    private func startIdleAnimation() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.displayLevel += (self.level - self.displayLevel) * 0.30
            self.phase += 0.35
            self.needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 92, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let barW: CGFloat = 2.8
        let gap: CGFloat = 2.2
        let totalW = CGFloat(barCount) * (barW + gap) - gap
        let maxH = bounds.height
        var x = (bounds.width - totalW) / 2
        let env = CGFloat(displayLevel)

        for i in 0..<barCount {
            let distance = CGFloat(abs(i - centerIndex)) / CGFloat(centerIndex)
            let taper = 1.0 - distance * 0.72
            let wave = 0.5 + 0.5 * CGFloat(sin(Double(phase) + Double(i) * 0.6))
            let h = maxH * taper * (0.10 + 0.90 * env * wave)
            let hot = env > 0.75 && i >= barCount - 4
            (hot ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.9)).setFill()
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: barW, height: max(h, 2))
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + gap
        }
    }
}
