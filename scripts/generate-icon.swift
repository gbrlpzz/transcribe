import AppKit

// Renders the Transcribe app icon: white squircle + the tetrahedron from
// the HUD, vertex toward the viewer at 30° roll — white on white, dead
// center, no shadow. The app icon IS the interface, frozen.
// Usage: swift scripts/generate-icon.swift <output-dir>

import simd

func drawIcon(_ size: CGFloat) {
    // Draws into the current graphics context (exact-pixel bitmap).

    // Obsidian squircle (continuous corners, Apple radius ≈ 0.225 × side).
    let rect = NSRect(origin: .zero, size: NSSize(width: size, height: size))
    let squircle = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
    squircle.addClip()
    NSColor(calibratedWhite: 0.985, alpha: 1).setFill()
    rect.fill()
    NSColor(calibratedWhite: 0.78, alpha: 0.90).setStroke()
    let rim = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.004, dy: size * 0.004),
                           xRadius: size * 0.221, yRadius: size * 0.221)
    rim.lineWidth = max(1, size * 0.005)
    rim.stroke()


    // The tetrahedron at rest (tilt only, no spin) — HUD material.
    // Vertex (1,1,1) pointed at the viewer, rolled 30°: all three faces
    // radiate from a central apex inside an upward triangle — maximum
    // form complexity, perfectly symmetric.
    let v: [SIMD3<Float>] = [
        SIMD3(1, 1, 1), SIMD3(1, -1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1),
    ].map { $0 / simd_length($0) }
    let faces = [[0, 1, 2], [0, 3, 1], [0, 2, 3], [1, 3, 2]]

    let a = simd_normalize(SIMD3<Float>(1, 1, 1))
    let zAxis = SIMD3<Float>(0, 0, 1)
    let toViewer = simd_float4x4(simd_quatf(
        angle: acos(max(-1, min(1, simd_dot(a, zAxis)))),
        axis: simd_normalize(simd_cross(a, zAxis))))
    let roll = simd_float4x4(simd_quatf(
        angle: Float.pi / 6, axis: zAxis))
    let model = simd_mul(roll, toViewer)
    let r = size * 0.36
    let center = CGPoint(x: size * 0.5, y: size * 0.5)
    var painted: [(path: NSBezierPath, z: Float)] = []
    for f in faces {
        var pts: [CGPoint] = []
        var zsum: Float = 0
        for i in 0..<f.count {
            let rv = model * SIMD4<Float>(v[f[i]], 1)
            pts.append(CGPoint(x: center.x + CGFloat(rv.x) * r,
                               y: center.y - CGFloat(rv.y) * r))
            zsum += rv.z
        }
        let path = NSBezierPath()
        path.move(to: pts[0])
        pts.dropFirst().forEach { path.line(to: $0) }
        path.close()
        painted.append((path, zsum / Float(f.count)))
    }
    for p in painted.sorted(by: { $0.z < $1.z }) {
        NSColor(calibratedWhite: 1, alpha: 1).setFill()
        NSColor(calibratedWhite: 0.45, alpha: 0.75).setStroke()
        p.path.lineWidth = max(0.75, size * 0.006)
        p.path.fill()
        p.path.stroke()
    }
}

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: swift generate-icon.swift <output-dir>")
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
]
for (px, name) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: outDir.appendingPathComponent(name))
}
print("iconset written to \(outDir.path)")
