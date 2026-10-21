import AppKit
import CoreText
import ImageIO
import RondoKit

/// PDF output via Core Text (thread-safe; no AppKit views).
enum PDFWriter {
    struct Info {
        var title: String?
        var author: String?
    }

    private static func context(_ url: URL, size: CGSize, info: Info) throws -> CGContext {
        var box = CGRect(origin: .zero, size: size)
        var aux: [CFString: Any] = [kCGPDFContextCreator: "Rondo"]
        if let t = info.title { aux[kCGPDFContextTitle] = t }
        if let a = info.author { aux[kCGPDFContextAuthor] = a }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, aux as CFDictionary) else {
            throw EngineError.failed("Can't create PDF at \(url.lastPathComponent)")
        }
        return ctx
    }

    /// Paginates styled text onto pages of `pageSize` with `margin` on every side. Returns the page count.
    @discardableResult
    static func write(_ text: NSAttributedString, to url: URL, pageSize: CGSize, margin: CGFloat = 72, info: Info,
                      progress: (Double) -> Void = { _ in }) throws -> Int {
        let prepared = prepare(text)
        let ctx = try context(url, size: pageSize, info: info)
        let frameRect = CGRect(x: margin, y: margin, width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)
        let framesetter = CTFramesetterCreateWithAttributedString(prepared as CFAttributedString)
        let total = prepared.length
        var location = 0
        var pages = 0
        repeat {
            try Task.checkCancellation()
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            pages += 1
            let visible = CTFrameGetVisibleStringRange(frame)
            // Guarantee forward progress even if a single glyph can't fit the frame.
            location += max(visible.length, total > location ? 1 : 0)
            if total > 0 { progress(Double(location) / Double(total)) }
        } while location < total
        ctx.closePDF()
        return pages
    }

    /// Bakes list markers in and drops attachment glyphs Core Text can't draw.
    static func prepare(_ text: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: ListMarkers.inlined(text))
        m.mutableString.replaceOccurrences(of: "\u{FFFC}", with: "", options: [], range: NSRange(location: 0, length: m.length))
        return m
    }

    // MARK: Tables

    /// Draws rows as a ruled grid. First row is bold when `header`; it repeats at the top of every page.
    @discardableResult
    static func table(_ rows: [[String]], header: Bool, to url: URL, pageSize portrait: CGSize, info: Info,
                      progress: (Double) -> Void = { _ in }) throws -> Int {
        let margin: CGFloat = 36
        let fontSize: CGFloat = 9
        let font = DocFonts.body(size: fontSize)
        let boldFont = DocFonts.styled(font, bold: true, italic: false)
        let cols = max(1, rows.map(\.count).max() ?? 1)
        let padX: CGFloat = 4, rowHeight: CGFloat = fontSize * 1.9

        // Natural column widths (capped), then landscape if they don't fit portrait.
        var natural = Array(repeating: CGFloat(24), count: cols)
        for (ri, row) in rows.prefix(2000).enumerated() {
            for (ci, cell) in row.enumerated() {
                let w = lineWidth(cell, font: ri == 0 && header ? boldFont : font) + 2 * padX
                natural[ci] = min(max(natural[ci], w), 220)
            }
        }
        let naturalTotal = natural.reduce(0, +)
        let landscape = naturalTotal > portrait.width - 2 * margin && portrait.width < portrait.height
        let page = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
        let available = page.width - 2 * margin
        let scale = naturalTotal > available ? available / naturalTotal : 1
        let widths = natural.map { $0 * scale }
        let tableWidth = widths.reduce(0, +)

        let ctx = try context(url, size: page, info: info)
        let headerRow = header ? rows.first : nil
        let body = header ? Array(rows.dropFirst()) : rows
        let perPage = max(1, Int((page.height - 2 * margin) / rowHeight) - (headerRow == nil ? 0 : 1))
        var index = 0
        var pages = 0
        repeat {
            try Task.checkCancellation()
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            var y = page.height - margin
            var drawn: [[String]] = []
            if let headerRow { drawn.append(headerRow) }
            drawn += body[index..<min(body.count, index + perPage)]
            for (ri, row) in drawn.enumerated() {
                let isHeader = headerRow != nil && ri == 0
                if isHeader {
                    ctx.setFillColor(CGColor(gray: 0.92, alpha: 1))
                    ctx.fill(CGRect(x: margin, y: y - rowHeight, width: tableWidth, height: rowHeight))
                }
                var x = margin
                for ci in 0..<cols {
                    let cell = ci < row.count ? row[ci] : ""
                    drawCell(cell, in: CGRect(x: x + padX, y: y - rowHeight, width: widths[ci] - 2 * padX, height: rowHeight),
                             font: isHeader ? boldFont : font, ctx: ctx)
                    x += widths[ci]
                }
                y -= rowHeight
            }
            // Grid
            ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
            ctx.setLineWidth(0.5)
            let top = page.height - margin
            let bottom = top - CGFloat(drawn.count) * rowHeight
            for r in 0...drawn.count {
                let yy = top - CGFloat(r) * rowHeight
                ctx.move(to: CGPoint(x: margin, y: yy)); ctx.addLine(to: CGPoint(x: margin + tableWidth, y: yy))
            }
            var x = margin
            ctx.move(to: CGPoint(x: x, y: top)); ctx.addLine(to: CGPoint(x: x, y: bottom))
            for w in widths {
                x += w
                ctx.move(to: CGPoint(x: x, y: top)); ctx.addLine(to: CGPoint(x: x, y: bottom))
            }
            ctx.strokePath()
            ctx.endPDFPage()
            pages += 1
            index += perPage
            progress(body.isEmpty ? 1 : Double(min(index, body.count)) / Double(body.count))
        } while index < body.count
        ctx.closePDF()
        return pages
    }

    private static func lineWidth(_ s: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]) as CFAttributedString)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func drawCell(_ s: String, in rect: CGRect, font: NSFont, ctx: CGContext) {
        guard !s.isEmpty, rect.width > 4 else { return }
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        let str = NSAttributedString(string: flat, attributes: [.font: font])
        var line = CTLineCreateWithAttributedString(str as CFAttributedString)
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > rect.width {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font]) as CFAttributedString)
            line = CTLineCreateTruncatedLine(line, Double(rect.width), .end, ellipsis) ?? line
        }
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + (rect.height - font.capHeight) / 2)
        CTLineDraw(line, ctx)
    }

    // MARK: Rasterize (slides → images)

    /// Renders each page of a PDF to JPG/PNG at `dpi`. Returns files in page order.
    static func rasterize(_ pdf: URL, format: String, dpi: Double, quality: Double, into dir: URL,
                          progress: (Double) -> Void = { _ in }) throws -> [URL] {
        guard let doc = CGPDFDocument(pdf as CFURL), doc.numberOfPages > 0 else {
            throw EngineError.failed("Exported PDF is unreadable")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let count = doc.numberOfPages
        let width = String(count).count
        var files: [URL] = []
        let dpi = dpi.isFinite ? min(max(dpi, 36), 600) : 150
        let scale = dpi / 72
        for n in 1...count {
            try Task.checkCancellation()
            guard let page = doc.page(at: n) else { continue }
            let box = page.getBoxRect(.cropBox)
            let pw = box.width * scale, ph = box.height * scale
            guard pw.isFinite, ph.isFinite, pw <= 20_000, ph <= 20_000 else {
                throw EngineError.failed("Page \(n) is too large to render at \(Int(dpi)) DPI")
            }
            let w = max(1, Int(pw.rounded())), h = max(1, Int(ph.rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            guard let image = ctx.makeImage() else { continue }
            let num = String(n)
            let name = "Slide " + String(repeating: "0", count: max(0, width - num.count)) + num + "." + format
            let out = dir.appendingPathComponent(name)
            let type = format == "jpg" ? "public.jpeg" : "public.png"
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else { continue }
            var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
            if format == "jpg" { props[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1) }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw EngineError.failed("Encoding \(format) failed") }
            files.append(out)
            progress(Double(n) / Double(count))
        }
        guard !files.isEmpty else { throw EngineError.failed("No pages rendered") }
        return files
    }
}
