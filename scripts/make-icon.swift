// Generates Rondo's original app icon (segmented wheel motif) as an .iconset, then
// scripts/make-icon.sh turns it into Resources/AppIcon.icns with iconutil.
// Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: content inset ~10%, continuous-corner squircle approximated by a rounded rect.
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow + deep indigo → teal gradient tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1E1B4B))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(0x312E81), color(0x0F766E)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()

    // Segmented ring: 8 slices with gaps; one highlighted slice (the "selected" target).
    let center = CGPoint(x: s / 2, y: s / 2)
    let outerR = tile.width * 0.36
    let innerR = tile.width * 0.2
    let slices = 8
    let gap = 0.06    // radians
    for i in 0..<slices {
        let start = CGFloat.pi / 2 - CGFloat(i) * 2 * .pi / CGFloat(slices) - gap / 2
        let end = start - 2 * .pi / CGFloat(slices) + gap
        let path = CGMutablePath()
        path.addArc(center: center, radius: outerR, startAngle: start, endAngle: end, clockwise: true)
        path.addArc(center: center, radius: innerR, startAngle: end, endAngle: start, clockwise: false)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(i == 1 ? color(0x38BDF8) : color(0xFFFFFF, 0.88))
        ctx.fillPath()
    }

    // Hub: small circle with a curved "transform" arrow.
    let hubR = innerR * 0.62
    ctx.addEllipse(in: CGRect(x: center.x - hubR, y: center.y - hubR, width: hubR * 2, height: hubR * 2))
    ctx.setFillColor(color(0xFFFFFF, 0.95))
    ctx.fillPath()

    let arrowR = hubR * 0.55
    ctx.setStrokeColor(color(0x312E81))
    ctx.setLineWidth(max(1, hubR * 0.2))
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: arrowR, startAngle: .pi * 0.85, endAngle: .pi * 0.05, clockwise: true)
    ctx.strokePath()
    // Arrow head at the arc end (angle 0.05π).
    let tipAngle = CGFloat.pi * 0.05
    let tip = CGPoint(x: center.x + cos(tipAngle) * arrowR, y: center.y + sin(tipAngle) * arrowR)
    let head = hubR * 0.32
    ctx.move(to: CGPoint(x: tip.x - head * 0.9, y: tip.y + head * 0.15))
    ctx.addLine(to: tip)
    ctx.addLine(to: CGPoint(x: tip.x - head * 0.05, y: tip.y + head * 0.95))
    ctx.strokePath()

    return ctx.makeImage()!
}

let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for spec in specs {
    let rep = NSBitmapImageRep(cgImage: render(size: spec.px))
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
    try png.write(to: outDir.appendingPathComponent("\(spec.name).png"))
}
print("wrote \(specs.count) PNGs to \(outDir.path)")
