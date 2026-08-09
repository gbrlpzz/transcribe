// Renders the Transcribe app icon: macOS squircle + SF Symbol "mic.fill".
// Usage: swift scripts/generate-icon.swift <output-dir>
// Produces AppIcon.icns + AppIcon.png (1024) in the output directory.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: swift generate-icon.swift <output-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let S: CGFloat = 1024
let image = NSImage(size: NSSize(width: S, height: S), flipped: false) { rect in
    // --- squircle background ---
    let path = NSBezierPath(roundedRect: rect, xRadius: S * 0.2237, yRadius: S * 0.2237)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.18, green: 0.29, blue: 0.94, alpha: 1.0),   // #2E4AF0
        NSColor(srgbRed: 0.36, green: 0.55, blue: 0.98, alpha: 1.0),   // #5C8DFA
    ])!
    gradient.draw(in: path, angle: -90)

    // --- standard microphone glyph (SF Symbol mic.fill), white ---
    let cfg = NSImage.SymbolConfiguration(pointSize: S * 0.44, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else {
        return true
    }
    let glyphSize = symbol.size
    let glyphRect = NSRect(x: (S - glyphSize.width) / 2,
                           y: (S - glyphSize.height) / 2,
                           width: glyphSize.width, height: glyphSize.height)
    // draw the template glyph, then recolor to white with sourceAtop
    NSColor.black.set()
    symbol.draw(in: glyphRect)
    NSColor.white.set()
    glyphRect.fill(using: .sourceAtop)
    return true
}

// write 1024 png
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("could not render icon")
    exit(1)
}
try png.write(to: outDir.appendingPathComponent("AppIcon.png"))

// iconset for iconutil
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes {
    let small = NSImage(size: NSSize(width: px, height: px), flipped: false) { rect in
        image.draw(in: rect)
        return true
    }
    guard let t = small.tiffRepresentation,
          let r = NSBitmapImageRep(data: t),
          let p = r.representation(using: .png, properties: [:]) else { continue }
    try? p.write(to: iconset.appendingPathComponent(name))
}
print("iconset written")
