import Foundation
import CoreGraphics
import CoreText
import PDFKit
import RondoKit

/// Page rasterization and plain-text typesetting.
enum PDFRender {
    /// Default cap on a rendered page's total pixels (≈ 200 MB at 8-bit RGBA); DPI is lowered to fit.
    static let maxArea = 50_000_000

    /// Renders one page (crop box, rotation and annotations applied) onto white at `dpi`, lowering the
    /// effective DPI so the bitmap stays within `maxPixels` per side and `maxArea` in total.
    static func render(_ page: PDFPage, dpi: Double, maxPixels: Int = 16_384, maxArea: Int = maxArea) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        let rot = ((page.rotation % 360) + 360) % 360
        let size = (rot == 90 || rot == 270) ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { throw EngineError.invalidInput("Empty page") }
        var scale = (dpi.isFinite ? min(max(1, dpi), 2400) : 300) / 72
        let longest = max(size.width, size.height) * scale
        if longest > CGFloat(maxPixels) { scale *= Double(maxPixels) / Double(longest) }
        let area = Double(size.width * size.height) * scale * scale
        if area > Double(maxArea) { scale *= sqrt(Double(maxArea) / area) * 0.999 }
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: PDFSupport.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw EngineError.failed("Page too large to render (\(w)x\(h))")
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.setShouldSmoothFonts(false)
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        // PDFKit applies the page rotation and box origin itself.
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { throw EngineError.failed("Page render failed") }
        return image
    }

    /// Renders every page into `folder` as `Page NN.ext`; returns the files in page order.
    static func renderPages(_ doc: PDFDocument, format: String, dpi: Double, quality: Double, into folder: URL,
                            progress: (Double) -> Void) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        let n = doc.pageCount
        for i in 0..<n {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            let image = try autoreleasepool { try render(page, dpi: dpi) }
            let url = folder.appendingPathComponent("\(PDFSupport.pageName(i + 1, of: n)).\(format)")
            try PDFSupport.writeImage(image, format: format, quality: quality, dpi: dpi, to: url)
            urls.append(url)
            progress(Double(i + 1) / Double(n))
        }
        return urls
    }

    // MARK: Text → PDF

    struct TextStyle {
        var fontSize: CGFloat = 10
        var monospaced = true
        var pageSize = CGSize(width: 612, height: 792)
        var margin: CGFloat = 54
    }

    /// Typesets plain text into paginated PDF data with Core Text.
    static func typeset(_ text: String, style: TextStyle, title: String?) throws -> Data {
        let font: CTFont = style.monospaced
            ? (CTFontCreateUIFontForLanguage(.userFixedPitch, style.fontSize, nil) ?? CTFontCreateWithName("Menlo-Regular" as CFString, style.fontSize, nil))
            : (CTFontCreateUIFontForLanguage(.system, style.fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, style.fontSize, nil))

        // Tab stops every 4 character widths for monospaced text, Core Text default otherwise.
        var glyph = CTFontGetGlyphWithName(font, "space" as CFString)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        var tabInterval = max(1, advance.width * 4)
        var lineBreak = CTLineBreakMode.byWordWrapping
        let paragraph: CTParagraphStyle = withUnsafeBytes(of: &tabInterval) { tabPtr in
            withUnsafeBytes(of: &lineBreak) { lbPtr in
                let settings = [
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: tabPtr.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: lbPtr.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw EngineError.failed("PDF consumer") }
        var media = CGRect(origin: .zero, size: style.pageSize)
        var info: [String: Any] = [kCGPDFContextCreator as String: "Rondo"]
        if let title { info[kCGPDFContextTitle as String] = title }
        guard let ctx = CGContext(consumer: consumer, mediaBox: &media, info as CFDictionary) else {
            throw EngineError.failed("Can't create PDF")
        }
        let frameRect = media.insetBy(dx: style.margin, dy: style.margin)
        let path = CGPath(rect: frameRect, transform: nil)
        let total = attributed.length
        var location = 0
        var pages = 0
        repeat {
            try Task.checkCancellation()
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            pages += 1
            guard visible.length > 0 else { break }      // nothing fits (huge font) → stop rather than loop forever
            location += visible.length
        } while location < total && pages < 100_000
        ctx.closePDF()
        return data as Data
    }
}
