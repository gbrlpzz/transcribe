import AppKit
import simd

/// One white translucent tetrahedron IS the whole state language. The shape
/// never changes; behavior does: recording spins gently about one axis,
/// transcribing tumbles the other way faster, done eases and locks into a
/// canonical rest pose. Vector-only: no assets, no GPU frameworks.
final class DictationSolidView: NSView {
    enum Stage { case recording, transcribing, success }

    /// Radians per second — one unhurried revolution every ~18 s recording,
    /// a brisker reversed tumble while transcribing.
    private var omega: Float { stage == .transcribing ? -0.55 : 0.35 }
    /// Distinct spin axes per stage so the change of state is instant.
    private var spinAxis: SIMD3<Float> {
        stage == .transcribing
            ? simd_normalize(SIMD3<Float>(1, 0.15, 0.20))
            : simd_normalize(SIMD3<Float>(0.22, 1, 0.14))
    }
    /// Fixed tilt so the silhouette never lands edge-on dead flat.
    private let tilt = rotation(angle: 0.55, axis: simd_normalize(SIMD3<Float>(1, 0.12, 0.18)))

    var stage: Stage = .recording

    var isSpinning = false {
        didSet {
            guard isSpinning != oldValue else { return }
            if isSpinning {
                locking = false
                clock.fireDate = .now
            } else {
                // Settle the shortest way to the canonical rest pose: the
                // tilt-only orientation offset so an internal edge stays
                // visible — a solid at rest, not a flat triangle.
                let tau = Float.pi * 2
                lockTarget = ((phase - 0.7) / tau).rounded() * tau + 0.7
                locking = true
                clock.fireDate = .now
            }
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    private let shadowLayer = CAGradientLayer()
    private var faceLayers: [CAShapeLayer] = []
    var phase: Float = 0  // internal so the HUD and preview harness can pin the rest pose
    private var locking = false
    private var lockTarget: Float = 0
    private var lastTick: TimeInterval = 0
    private lazy var clock: Timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
        self?.tick()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    private func commonInit() {
        wantsLayer = true
        clock.fireDate = .distantFuture
        RunLoop.main.add(clock, forMode: .common)
        // Four face layers, built once — the geometry never changes.
        faceLayers = (0..<4).map { _ in
            let f = CAShapeLayer()
            f.strokeColor = NSColor(calibratedWhite: 0.28, alpha: 0.60).cgColor
            f.lineWidth = 0.4
            f.contentsScale = window?.backingScaleFactor ?? 2
            f.shadowColor = NSColor.white.cgColor
            f.shadowOpacity = 0.30
            f.shadowRadius = 2.5
            f.shadowOffset = .zero
            layer?.addSublayer(f)
            return f
        }
        layoutSolid()
    }

    override func layout() {
        super.layout()
        layoutSolid()
    }

    /// Diffused contact shadow: radial falloff, the same softness language
    /// as the panel shadow behind the notch.
    private func layoutSolid() {
        guard bounds.width > 1 else { return }
        let pad = bounds.width * 0.02
        shadowLayer.frame = CGRect(x: pad, y: bounds.height * 0.015,
                                   width: bounds.width - pad * 2,
                                   height: bounds.height * 0.18)
        shadowLayer.colors = [NSColor.black.withAlphaComponent(0.45).cgColor,
                              NSColor.black.withAlphaComponent(0.15).cgColor,
                              NSColor.black.withAlphaComponent(0).cgColor]
        shadowLayer.locations = [0, 0.55, 1]
        shadowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadowLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        shadowLayer.type = .radial
        if shadowLayer.superlayer == nil { layer?.insertSublayer(shadowLayer, at: 0) }
        renderFrame()
    }

    private func tick() {
        let t = CACurrentMediaTime()
        if lastTick > 0 {
            let dt = Float(t - lastTick)
            if locking {
                phase += (lockTarget - phase) * min(1, dt * 1.5)
                if abs(lockTarget - phase) < 0.005 {
                    phase = lockTarget
                    locking = false
                    clock.fireDate = .distantFuture
                }
            } else {
                phase += omega * dt
            }
        }
        lastTick = t
        renderFrame()
    }

    private func renderFrame() {
        guard bounds.width > 1, layer != nil else { return }
        let model = simd_mul(rotation(angle: phase, axis: spinAxis), tilt)

        let size = min(bounds.width, bounds.height)
        let r = size * 0.36
        let center = CGPoint(x: bounds.midX, y: bounds.midY + size * 0.08)

        // Unit tetrahedron.
        let v = [
            SIMD3<Float>(1, 1, 1), SIMD3<Float>(1, -1, -1),
            SIMD3<Float>(-1, 1, -1), SIMD3<Float>(-1, -1, 1),
        ].map { $0 / simd_length($0) }
        let faces = [[0, 1, 2], [0, 3, 1], [0, 2, 3], [1, 3, 2]]

        struct Painted { let path: CGPath; let z: Float }
        var painted: [Painted] = []
        painted.reserveCapacity(faces.count)
        for f in faces {
            var pts: [CGPoint] = []
            pts.reserveCapacity(f.count)
            var zsum: Float = 0
            for i in 0..<f.count {
                let rv = simd_mul(model, SIMD4<Float>(v[f[i]], 1))
                pts.append(CGPoint(x: center.x + CGFloat(rv.x) * r,
                                   y: center.y - CGFloat(rv.y) * r))
                zsum += rv.z
            }
            let path = CGMutablePath()
            path.addLines(between: pts)
            path.closeSubpath()
            painted.append(Painted(path: path, z: zsum / Float(f.count)))
        }
        // Painter's algorithm: farthest first. Convex solids sort exactly.
        painted.sort { $0.z < $1.z }
        for (i, p) in painted.enumerated() {
            faceLayers[i].path = p.path
            faceLayers[i].fillColor = NSColor(calibratedWhite: 0.97, alpha: 0.90).cgColor
        }
    }
}

private func rotation(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(axis)))
}
