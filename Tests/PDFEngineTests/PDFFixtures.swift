import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import RondoKit
@testable import PDFEngine

enum PFx {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let pageSize = CGSize(width: 200, height: 260)

    static func dir(_ name: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("RondoW3Tests", isDirectory: true)
            .appendingPathComponent("pdf-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    /// Small PDF: one page per string, each with that text and a red 20×20 pt block at the page's top-left.
    /// `image` is drawn on page 1 at `imageSize` pt (for compression tests).
    static func makePDF(_ texts: [String], at url: URL, title: String? = nil, author: String? = nil, subject: String? = nil,
                        image: CGImage? = nil, imageSize: CGSize = CGSize(width: 180, height: 180)) {
        var media = CGRect(origin: .zero, size: pageSize)
        var info: [String: Any] = [:]
        if let title { info[kCGPDFContextTitle as String] = title }
        if let author { info[kCGPDFContextAuthor as String] = author }
        if let subject { info[kCGPDFContextSubject as String] = subject }
        let ctx = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary)!
        for (i, text) in texts.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: pageSize.height - 20, width: 20, height: 20))
            if i == 0, let image {
                // Embed as a DCT (JPEG) stream like real-world PDFs do.
                let data = NSMutableData()
                let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality as String: 0.95] as CFDictionary)
                CGImageDestinationFinalize(dest)
                let jpeg = CGImage(jpegDataProviderSource: CGDataProvider(data: data as CFData)!, decode: nil,
                                   shouldInterpolate: true, intent: .defaultIntent)!
                ctx.draw(jpeg, in: CGRect(x: 10, y: 10, width: imageSize.width, height: imageSize.height))
            }
            drawText(text, in: ctx, rect: CGRect(x: 24, y: 24, width: pageSize.width - 48, height: pageSize.height - 60))
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func drawText(_ text: String, in ctx: CGContext, rect: CGRect, size: CGFloat = 12) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ])
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
    }

    /// PDF whose only page is a picture of text (no text layer) — for OCR.
    static func makeScannedPDF(_ text: String, at url: URL) {
        let W = 1000, H = 300
        let bmp = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bmp.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: W, height: H))
        drawText(text, in: bmp, rect: CGRect(x: 40, y: 40, width: W - 80, height: H - 80), size: 72)
        let img = bmp.makeImage()!
        var media = CGRect(x: 0, y: 0, width: 500, height: 150)
        let ctx = CGContext(url as CFURL, mediaBox: &media, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(img, in: media)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    static func noisy(width: Int = 400, height: Int = 400, seed: UInt64 = 7) -> CGImage {
        var rng = seed
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let n = Int((rng >> 33) % 80)
                let i = (y * width + x) * 4
                bytes[i] = UInt8(min(255, x * 200 / width + n / 2))
                bytes[i + 1] = UInt8(min(255, y * 200 / height + n / 2))
                bytes[i + 2] = UInt8(min(255, 100 + n))
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func load(_ url: URL) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }

    struct RGBA { let r, g, b, a: Int }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGBA {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * image.width * 4 + x * 4
        return RGBA(r: Int(p[i]), g: Int(p[i + 1]), b: Int(p[i + 2]), a: Int(p[i + 3]))
    }

    static func isRed(_ p: RGBA) -> Bool { p.r > 180 && p.g < 90 && p.b < 90 }

    static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func text(_ url: URL) -> String { PDFDocument(url: url)?.string ?? "" }
}

extension PDFDocumentEngine {
    func runTest(_ spec: JobSpec) async throws -> [URL] {
        let tmp = try TempDir.make(prefix: "w3-pdf-test")
        defer { TempDir.remove(tmp) }
        return try await run(spec, context: JobContext(tools: ToolLocator(), tempDir: tmp))
    }
}
