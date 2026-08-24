import AppKit
import simd

/// One white translucent tetrahedron IS the whole state language. The shape
/// never changes; behavior does: recording spins gently about one axis,
/// transcribing tumbles the other way faster, done eases and locks into
/// the app-icon pose (vertex at you). Vector-only: no assets, no GPU frameworks.
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

    /// AppKit clips layer-backed views to their bounds by default — which
    /// would amputate our silhouette shadow. Opt out.
    override var wantsDefaultClipping: Bool { false }

    var isSpinning = false {
        didSet {
            guard isSpinning != oldValue else { return }
            if isSpinning {
                locking = false
                settled = false  // a new run must move again, even right after a settle
                clock.fireDate = .now
            } else {
                // Settle the shortest quaternion arc to the icon pose.
                settled = false
                lockFromQ = simd_quatf(simd_mul(rotation(angle: phase, axis: spinAxis), tilt))
                lockStart = CACurrentMediaTime()
                locking = true
                clock.fireDate = .now
            }
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    private let shadowLayer = CAGradientLayer()
    private var faceLayers: [CAShapeLayer] = []
    var phase: Float = 0
    private var locking = false
    private var settled = false
    private var lockFromQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var lockStart: TimeInterval = 0
    /// The app-icon pose (vertex at the viewer, 30° roll): done lands as
    /// literally the icon, unmistakable from any spin angle.
    private let restQ: simd_quatf = {
        let a = simd_normalize(SIMD3<Float>(1, 1, 1))
        let z = SIMD3<Float>(0, 0, 1)
        let toViewer = simd_quatf(angle: acos(max(-1, min(1, simd_dot(a, z)))),
                                  axis: simd_normalize(simd_cross(a, z)))
        return simd_mul(simd_quatf(angle: Float.pi / 6, axis: z), toViewer)
    }()
    /// Fixed-duration settle: guaranteed to finish (no asymptotic crawl).
    private let lockDuration: TimeInterval = 0.8
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
        // Orthogonal-light projection: the root layer shadows its own
        // composited silhouette, so the solid reads against ANY background,
        // light or dark — form first, theme never.
        layer?.masksToBounds = false  // and see wantsDefaultClipping below
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 10
        layer?.shadowOffset = .zero
        clock.fireDate = .distantFuture
        RunLoop.main.add(clock, forMode: .common)
        // Four face layers, built once — the geometry never changes.
        faceLayers = (0..<4).map { _ in
            let f = CAShapeLayer()
            // Same stroke recipe as the app icon: soft gray, not an outline.
            f.strokeColor = NSColor(calibratedWhite: 0.45, alpha: 0.75).cgColor
            f.lineWidth = 0.5
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
        shadowLayer.colors = [NSColor.black.withAlphaComponent(0.60).cgColor,
                              NSColor.black.withAlphaComponent(0.20).cgColor,
                              NSColor.black.withAlphaComponent(0).cgColor]
        shadowLayer.locations = [0, 0.55, 1]
        shadowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadowLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        shadowLayer.type = .radial
        if shadowLayer.superlayer == nil { layer?.insertSublayer(shadowLayer, at: 0) }
        renderFrame(currentModel(at: CACurrentMediaTime()))
    }

    /// Spins while running; while settling, arcs to the rest pose with the
    /// same fixed easeOutCubic window: quick start, gentle landing, done.
    private func currentModel(at t: TimeInterval) -> simd_float4x4 {
        if settled { return simd_float4x4(restQ) }
        guard locking else { return simd_mul(rotation(angle: phase, axis: spinAxis), tilt) }
        let p = Float(min(1, (t - lockStart) / lockDuration))
        let e = 1 - pow(1 - p, 3)
        if p >= 1 {
            settled = true
            locking = false
            clock.fireDate = .distantFuture
        }
        return simd_float4x4(simd_slerp(lockFromQ, restQ, e))
    }

    private func tick() {
        let t = CACurrentMediaTime()
        if lastTick > 0, !locking {
            phase += omega * Float(t - lastTick)
        }
        lastTick = t
        renderFrame(currentModel(at: t))
    }

    private func renderFrame(_ model: simd_float4x4) {
        guard bounds.width > 1, layer != nil else { return }

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
            faceLayers[i].fillColor = NSColor(calibratedWhite: 0.97, alpha: 0.96).cgColor
        }
    }
}

private func rotation(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(simd_quatf(angle: angle, axis: simd_normalize(axis)))
}
