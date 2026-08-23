import AppKit
import simd

/// One white translucent platonic solid per dictation stage — the whole
/// state language: tetrahedron records, cube transcribes, octahedron
/// confirms. Precessing spin, uniform pale fill, hairline edges, diffused
/// contact shadow. Vector-only: no assets, no GPU frameworks.
final class DictationSolidView: NSView {
    enum Stage { case recording, transcribing, success }
    /// .solid paints every face the same near-white (default); .wireframe
    /// strokes edges only.
    enum Style { case solid, wireframe }


    struct Solid {
        let vertices: [SIMD3<Float>]
        let faces: [[Int]]
    }

    private static func unit(_ v: [SIMD3<Float>]) -> [SIMD3<Float>] {
        v.map { $0 / simd_length($0) }
    }

    private static let tetrahedron = Solid(
        vertices: unit([
            SIMD3(1, 1, 1), SIMD3(1, -1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1),
        ]),
        faces: [[0, 1, 2], [0, 3, 1], [0, 2, 3], [1, 3, 2]])

    private static let cube = Solid(
        vertices: unit([
            SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
            SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1),
        ]),
        faces: [
            [0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7],
            [1, 5, 6, 2], [4, 5, 1, 0], [3, 2, 6, 7],
        ])

    private static let octahedron = Solid(
        vertices: [
            SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
            SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1),
        ],
        faces: [
            [0, 2, 4], [2, 1, 4], [1, 3, 4], [3, 0, 4],
            [2, 0, 5], [1, 2, 5], [3, 1, 5], [0, 3, 5],
        ])

    private static func solid(for stage: Stage) -> Solid {
        switch stage {
        case .recording: return tetrahedron
        case .transcribing: return cube
        case .success: return octahedron
        }
    }

    /// Radians per second — one unhurried revolution every ~18 s.
    private static let omega: Float = 0.35
    /// Fixed light toward the viewer's upper right.

    var stage: Stage = .recording {
        didSet { guard stage != oldValue else { return }; rebuildFaces() }
    }

    var style: Style = .solid {
        didSet { guard style != oldValue else { return }; rebuildFaces() }
    }

    var isSpinning = false {
        didSet { guard isSpinning != oldValue else { return }
            clock.fireDate = isSpinning ? .now : .distantFuture }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    private let shadowLayer = CAGradientLayer()
    private var faceLayers: [CAShapeLayer] = []
    private var phase: Float = 0
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
        rebuildFaces()
    }

    private func rebuildFaces() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let solid = Self.solid(for: stage)
        faceLayers = (0..<solid.faces.count).map { _ in
            let f = CAShapeLayer()
            f.strokeColor = NSColor(calibratedWhite: 0.42, alpha: 0.50).cgColor
            f.lineWidth = 0.4
            f.contentsScale = window?.backingScaleFactor ?? 2
            f.shadowColor = NSColor.white.cgColor
            f.shadowOpacity = 0.30
            f.shadowRadius = 2.5
            f.shadowOffset = .zero
            layer?.addSublayer(f)
            return f
        }
        // Diffused contact shadow: radial falloff, the same softness
        // language as the panel shadow behind the notch.
        let pad = bounds.width * 0.04
        shadowLayer.frame = CGRect(x: pad, y: bounds.height * 0.015,
                                   width: bounds.width - pad * 2,
                                   height: bounds.height * 0.16)
        let grad = shadowLayer
        grad.colors = [NSColor.black.withAlphaComponent(0.30).cgColor,
                       NSColor.black.withAlphaComponent(0.10).cgColor,
                       NSColor.black.withAlphaComponent(0).cgColor]
        grad.locations = [0, 0.55, 1]
        grad.startPoint = CGPoint(x: 0.5, y: 0.5)
        grad.endPoint = CGPoint(x: 1.0, y: 0.5)
        grad.type = .radial
        layer?.insertSublayer(shadowLayer, at: 0)
        renderFrame()
    }

    override func layout() {
        super.layout()
        rebuildFaces()
    }

    private func tick() {
        let t = CACurrentMediaTime()
        if lastTick > 0 { phase += Self.omega * Float(t - lastTick) }
        lastTick = t
        renderFrame()
    }

    private func renderFrame() {
        guard bounds.width > 1, layer != nil else { return }
        let solid = Self.solid(for: stage)
        // Precession: two incommensurate axes — the solid tumbles like a
        // drifting gyroscope; no angle class ever repeats exactly.
        let tilt = rotation(angle: 0.55, axis: simd_normalize(SIMD3<Float>(1, 0.12, 0.18)))
        let spin = rotation(angle: phase, axis: simd_normalize(SIMD3<Float>(0.22, 1, 0.14)))
        let precess = rotation(angle: phase * 0.37,
                               axis: simd_normalize(SIMD3<Float>(0.10, 0.30, 1)))
        let model = simd_mul(precess, simd_mul(spin, tilt))

        let size = min(bounds.width, bounds.height)
        let r = size * 0.36
        let center = CGPoint(x: bounds.midX, y: bounds.midY + size * 0.08)

        struct Painted { let path: CGPath; let z: Float }
        var painted: [Painted] = []
        painted.reserveCapacity(solid.faces.count)
        for f in solid.faces {
            var pts: [CGPoint] = []
            pts.reserveCapacity(f.count)
            var zsum: Float = 0
            for i in 0..<f.count {
                let rv = simd_mul(model, SIMD4<Float>(solid.vertices[f[i]], 1))
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
            let fl = faceLayers[i]
            fl.path = p.path
            fl.fillColor = style == .solid
                ? NSColor(calibratedWhite: 0.97, alpha: 0.86).cgColor : nil
        }
    }
}

private func rotation(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let a = simd_normalize(axis), c = cos(angle), s = sin(angle), d = 1 - c
    let m = simd_float3x3(
        SIMD3(c + d*a.x*a.x, d*a.x*a.y - s*a.z, d*a.x*a.z + s*a.y),
        SIMD3(d*a.x*a.y + s*a.z, c + d*a.y*a.y, d*a.y*a.z - s*a.x),
        SIMD3(d*a.x*a.z - s*a.y, d*a.y*a.z + s*a.x, c + d*a.z*a.z))
    return simd_float4x4(
        SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0),
        SIMD4(m.columns.2, 0), SIMD4(0, 0, 0, 1))
}
