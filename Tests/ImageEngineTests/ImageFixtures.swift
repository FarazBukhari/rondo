import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import RondoKit
@testable import ImageEngine

/// Small generated fixtures (≤200 px) in a per-test temp dir.
enum Fx {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func dir(_ name: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("RondoW3Tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    /// 160×120: blue→cyan gradient, red 24×24 block at top-left, green 24×24 block at bottom-right.
    /// `alpha`: top-right quadrant fully transparent.
    static func pattern(width: Int = 160, height: Int = 120, alpha: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        let W = CGFloat(width), H = CGFloat(height)
        let grad = CGGradient(colorsSpace: sRGB, colors: [CGColor(srgbRed: 0.1, green: 0.2, blue: 0.8, alpha: 1),
                                                          CGColor(srgbRed: 0.2, green: 0.8, blue: 0.9, alpha: 1)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: W, y: H), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: H - 24, width: 24, height: 24))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: W - 24, y: 0, width: 24, height: 24))
        if alpha { ctx.clear(CGRect(x: W / 2, y: H / 2, width: W / 2, height: H / 2)) }
        return ctx.makeImage()!
    }

    /// Photo-like content (gradient + deterministic noise) so lossy sizes vary smoothly with quality.
    static func noisy(width: Int = 200, height: Int = 200, seed: UInt64 = 42) -> CGImage {
        var rng = seed
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let n = Int((rng >> 33) % 90)
                let i = (y * width + x) * 4
                bytes[i] = UInt8(min(255, x * 255 / width / 2 + n))
                bytes[i + 1] = UInt8(min(255, y * 255 / height / 2 + n))
                bytes[i + 2] = UInt8(min(255, 120 + n))
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func qr(_ text: String, scale: Int = 6) -> CGImage {
        let f = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data(text.utf8), "inputCorrectionLevel": "M"])!
        let ci = f.outputImage!
        let small = CIContext().createCGImage(ci, from: ci.extent)!
        let pad = 4 * scale
        let W = small.width * scale + 2 * pad, H = small.height * scale + 2 * pad
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .none
        ctx.draw(small, in: CGRect(x: pad, y: pad, width: small.width * scale, height: small.height * scale))
        return ctx.makeImage()!
    }

    @discardableResult
    static func write(_ image: CGImage, type: String, to url: URL, props: [String: Any] = [:], quality: Double = 0.95) -> Bool {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { return false }
        var p = props
        p[kCGImageDestinationLossyCompressionQuality as String] = quality
        CGImageDestinationAddImage(d, image, p as CFDictionary)
        return CGImageDestinationFinalize(d)
    }

    static func magick(_ args: [String]) async throws {
        guard let m = ToolLocator().url(for: "magick") else { throw EngineError.missingTool("magick") }
        try await ProcessRunner.run(m, args)
    }

    static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="160" height="120" viewBox="0 0 160 120">
      <rect x="0" y="0" width="160" height="120" fill="#3366cc"/>
      <rect x="0" y="0" width="24" height="24" fill="#ff0000"/>
      <rect x="136" y="96" width="24" height="24" fill="#00ff00"/>
    </svg>
    """

    /// Writes the 160×120 pattern as `id` (catalog format id). Returns nil if this Mac can't produce it.
    static func fixture(_ id: String, in dir: URL, name: String = "sample", alpha: Bool = false) async throws -> URL? {
        let url = dir.appendingPathComponent("\(name).\(ImageFormats.ext(id))")
        let img = pattern(alpha: alpha)
        switch id {
        case "svg":
            try svg.write(to: url, atomically: true, encoding: .utf8)
            return url
        case "webp":
            let png = dir.appendingPathComponent("\(name)-webp-src.png")
            write(img, type: "public.png", to: png)
            try await magick([png.path, "-quality", "95", "WEBP:" + url.path])
            try? FileManager.default.removeItem(at: png)
            return url
        default:
            guard let t = ImageFormats.utType(id) else { return nil }
            if write(id == "jpg" || id == "bmp" ? ImageOps.flattened(img) : img, type: t, to: url) { return url }
            let png = dir.appendingPathComponent("\(name)-src.png")
            write(img, type: "public.png", to: png)
            try? await magick([png.path, ImageCodec.magickPrefix(id) + url.path])
            try? FileManager.default.removeItem(at: png)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    static func load(_ url: URL) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }

    static func properties(_ url: URL) -> [String: Any] {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any]) ?? [:]
    }

    struct RGBA { let r, g, b, a: Int }

    /// Pixel at top-left coordinates, in sRGB 0…255 (unpremultiplied enough for opaque checks).
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGBA {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * image.width * 4 + x * 4
        return RGBA(r: Int(p[i]), g: Int(p[i + 1]), b: Int(p[i + 2]), a: Int(p[i + 3]))
    }

    static func isRed(_ p: RGBA) -> Bool { p.r > 180 && p.g < 90 && p.b < 90 }
    static func isWhite(_ p: RGBA) -> Bool { p.r > 235 && p.g > 235 && p.b > 235 && p.a > 235 }

    static func pdfPageCount(_ url: URL) -> Int { CGPDFDocument(url as CFURL)?.numberOfPages ?? 0 }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var all: [Double] { lock.withLock { values } }
}

extension RasterEngine {
    /// Runs a job with a fresh temp dir (cleaned up afterwards).
    func runTest(_ spec: JobSpec, progress: ProgressLog? = nil) async throws -> [URL] {
        let tmp = try TempDir.make(prefix: "w3-image-test")
        defer { TempDir.remove(tmp) }
        let ctx = JobContext(progress: { progress?.add($0) }, tools: ToolLocator(), tempDir: tmp)
        return try await run(spec, context: ctx)
    }
}
