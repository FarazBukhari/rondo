import CoreGraphics
import Foundation
import ImageIO
import RondoKit
import ImageEngine
@testable import ImageEditorUI

/// Generated fixtures + engine harness for W6 tests. Everything lands under fixtures/out/W6/.
enum W6 {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func dir(_ sub: String) -> URL {
        let d = root.appendingPathComponent("fixtures/out/W6/\(sub)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Fresh (emptied) output folder for one test.
    static func cleanDir(_ sub: String) -> URL {
        let d = root.appendingPathComponent("fixtures/out/W6/\(sub)", isDirectory: true)
        try? FileManager.default.removeItem(at: d)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Opaque image, four solid quadrants (TL red, TR green, BL blue, BR white) — easy to probe after transforms.
    static func quadrants(_ w: Int, _ h: Int) -> CGImage {
        let ctx = context(w, h)
        let hw = CGFloat(w) / 2, hh = CGFloat(h) / 2
        // CG is bottom-left: top half is y ≥ hh.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: hh, width: hw, height: hh))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: hw, y: hh, width: hw, height: hh))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: hw, height: hh))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: hw, y: 0, width: hw, height: hh))
        return opaque(ctx.makeImage()!)
    }

    /// Drops the alpha channel (so ImageIO writes an RGB PNG and the engine keeps an opaque format).
    static func opaque(_ image: CGImage) -> CGImage {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    /// Colorful original scene for snapshots: sky gradient, sun, hills, a few blocks.
    static func scene(_ w: Int = 1600, _ h: Int = 1000) -> CGImage {
        let ctx = context(w, h)
        let W = CGFloat(w), H = CGFloat(h)
        let sky = CGGradient(colorsSpace: sRGB, colors: [
            CGColor(srgbRed: 0.98, green: 0.62, blue: 0.36, alpha: 1),
            CGColor(srgbRed: 0.36, green: 0.55, blue: 0.86, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H * 0.35), end: CGPoint(x: 0, y: H), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.45, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: W * 0.62, y: H * 0.55, width: H * 0.26, height: H * 0.26))
        ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.45, blue: 0.30, alpha: 1))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: 0))
        ctx.addLine(to: CGPoint(x: 0, y: H * 0.42))
        ctx.addCurve(to: CGPoint(x: W * 0.55, y: H * 0.30), control1: CGPoint(x: W * 0.2, y: H * 0.62), control2: CGPoint(x: W * 0.35, y: H * 0.22))
        ctx.addCurve(to: CGPoint(x: W, y: H * 0.38), control1: CGPoint(x: W * 0.75, y: H * 0.40), control2: CGPoint(x: W * 0.9, y: H * 0.5))
        ctx.addLine(to: CGPoint(x: W, y: 0))
        ctx.closePath()
        ctx.fillPath()
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.95, 0.30, 0.35), (0.98, 0.85, 0.25), (0.35, 0.75, 0.95)]
        for (i, c) in colors.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: W * (0.08 + CGFloat(i) * 0.1), y: H * 0.08, width: W * 0.07, height: H * 0.12))
        }
        return opaque(ctx.makeImage()!)
    }

    /// Transparent canvas with an opaque rounded badge in the middle.
    static func badge(_ w: Int = 600, _ h: Int = 400) -> CGImage {
        let ctx = context(w, h)
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let r = CGRect(x: CGFloat(w) * 0.2, y: CGFloat(h) * 0.2, width: CGFloat(w) * 0.6, height: CGFloat(h) * 0.6)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 40, cornerHeight: 40, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.45, green: 0.30, blue: 0.85, alpha: 1))
        ctx.fillPath()
        return ctx.makeImage()!
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL, orientation: Int? = nil, type: String = "public.png") throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EngineError.failed("write \(url.lastPathComponent)") }
        return url
    }

    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    struct RGBA: Equatable, CustomStringConvertible {
        var r, g, b, a: Int
        var description: String { "rgba(\(r),\(g),\(b),\(a))" }
        func close(to o: RGBA, tolerance: Int = 6) -> Bool {
            abs(r - o.r) <= tolerance && abs(g - o.g) <= tolerance && abs(b - o.b) <= tolerance && abs(a - o.a) <= tolerance
        }
        static let red = RGBA(r: 255, g: 0, b: 0, a: 255)
        static let green = RGBA(r: 0, g: 255, b: 0, a: 255)
        static let blue = RGBA(r: 0, g: 0, b: 255, a: 255)
        static let white = RGBA(r: 255, g: 255, b: 255, a: 255)
        static let black = RGBA(r: 0, g: 0, b: 0, a: 255)
    }

    /// Pixel at top-left coordinates (x, y), redrawn into 8-bit sRGB RGBA.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGBA {
        let ctx = context(1, 1)
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return RGBA(r: Int(p[0]), g: Int(p[1]), b: Int(p[2]), a: Int(p[3]))
    }

    /// Mean absolute per-channel difference (0…255) between two same-size images.
    static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        let w = a.width, h = a.height
        func bytes(_ img: CGImage) -> [UInt8] {
            let ctx = context(w, h)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: p, count: ctx.bytesPerRow * h))
        }
        let x = bytes(a), y = bytes(b)
        var total = 0
        for i in 0..<min(x.count, y.count) { total += abs(Int(x[i]) - Int(y[i])) }
        return Double(total) / Double(max(1, x.count))
    }

    /// Runs the real engine with exactly what the editor would submit; outputs go to `outDir`.
    static func runEngine(_ submission: EditorSubmission, input: URL, outDir: URL) async throws -> URL {
        let tmp = try TempDir.make(prefix: "w6-test")
        defer { TempDir.remove(tmp) }
        let spec = JobSpec(inputs: [input], operation: .tool(submission.tool), options: submission.options, destination: .folder(outDir))
        let outs = try await RasterEngine().run(spec, context: JobContext(tools: ToolLocator(), tempDir: tmp, destination: .folder(outDir)))
        guard let first = outs.first else { throw EngineError.failed("no output") }
        return first
    }
}
