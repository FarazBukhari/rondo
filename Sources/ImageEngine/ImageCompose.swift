import Foundation
import CoreGraphics
import ImageIO
import RondoKit

/// Images → PDF (one image per page) and collages. Both stream: each input is decoded only when its
/// page/cell is drawn, downsampled to the pixels that page/cell actually needs, then released.
enum ImageCompose {
    enum PageSize: String { case fit, a4, letter }

    /// Resolution images are kept at on fixed-size (A4/Letter) pages.
    static let pageImageDPI: CGFloat = 300
    /// Cap for a single embedded image on `fit` pages (huge sources are downsampled to this area).
    static let maxEmbedArea: CGFloat = 100_000_000

    /// Writes one page per source. `fit` pages match the image's physical size (pixels at its DPI).
    static func writePDF(_ sources: [ImageSource], to url: URL, pageSize: PageSize, margin: Double, quality: Double,
                         title: String?, progress: (Double) -> Void) throws {
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [String: Any] = [kCGPDFContextCreator as String: "Rondo"]
        if let title { info[kCGPDFContextTitle as String] = title }
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary) else {
            throw EngineError.failed("Can't create PDF")
        }
        let m = CGFloat(margin.isFinite ? min(max(0, margin), 720) : 0)
        for (i, source) in sources.enumerated() {
            try Task.checkCancellation()
            let px = source.pixelSize
            let natural = CGSize(width: px.width * 72 / source.dpi, height: px.height * 72 / source.dpi)
            let landscape = natural.width > natural.height
            var page: CGSize
            switch pageSize {
            case .fit: page = CGSize(width: natural.width + 2 * m, height: natural.height + 2 * m)
            case .a4: page = landscape ? CGSize(width: 841.89, height: 595.28) : CGSize(width: 595.28, height: 841.89)
            case .letter: page = landscape ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792)
            }
            let area = CGRect(origin: .zero, size: page).insetBy(dx: min(m, page.width / 2 - 1), dy: min(m, page.height / 2 - 1))
            let drawSize = pageSize == .fit ? natural : ImageOps.fit(natural, in: area.size)
            let rect = CGRect(x: area.midX - drawSize.width / 2, y: area.midY - drawSize.height / 2,
                              width: drawSize.width, height: drawSize.height)

            // Pixels this page needs: native on fit pages (capped), 300 DPI of the drawn size otherwise.
            var needed = pageSize == .fit ? max(px.width, px.height) : max(drawSize.width, drawSize.height) * pageImageDPI / 72
            let srcArea = px.width * px.height
            if srcArea > maxEmbedArea { needed = min(needed, max(px.width, px.height) * sqrt(maxEmbedArea / srcArea)) }
            let maxPixel = Int(min(needed.rounded(.up), CGFloat(Int32.max)))

            try autoreleasepool {
                let item = try ImageCodec.decode(source, maxPixel: maxPixel)
                var box = CGRect(origin: .zero, size: page)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
                ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
                ctx.interpolationQuality = .high
                ctx.draw(embeddable(item, quality: quality), in: rect)
                ctx.endPDFPage()
            }
            progress(Double(i + 1) / Double(max(1, sources.count)))
        }
        ctx.closePDF()
    }

    /// Opaque images go in as DCT (JPEG) streams so PDFs stay small; untouched JPEGs pass through byte-for-byte.
    static func embeddable(_ item: LoadedImage, quality: Double) -> CGImage {
        let img = item.image
        guard !img.hasAlpha else { return img }
        if item.untouched, item.sourceFormat == "jpg", let provider = CGDataProvider(url: item.sourceURL as CFURL),
           let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return jpeg
        }
        if let data = ImageCodec.encodeData(img, type: "public.jpeg", quality: quality),
           let provider = CGDataProvider(data: data as CFData),
           let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            return jpeg
        }
        return img
    }

    // MARK: Collage

    enum Layout: String { case grid, horizontal, vertical }

    struct CollageOptions {
        var layout: Layout = .grid
        var columns: Int = 0          // 0 = auto (≈ √n)
        var cellSize: Int = 600       // grid cell edge; row height (horizontal); column width (vertical)
        var spacing: Int = 12         // gap between cells and around the edge
        var background: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        var fill: Bool = false        // grid: aspect-fill (crop) instead of aspect-fit
        /// Canvas cap (8-bit RGBA ≈ 4 bytes/px); cells shrink to fit under it.
        var maxArea: CGFloat = 50_000_000
        var maxSide: CGFloat = 16_000
    }

    /// Lays out `sizes` (upright pixel sizes), then asks `image(index, maxPixel)` for each cell's picture
    /// at the resolution the cell needs — one at a time.
    static func collage(sizes: [CGSize], options o: CollageOptions,
                        image: (Int, Int) throws -> CGImage) throws -> CGImage {
        guard !sizes.isEmpty else { throw EngineError.invalidInput("No images for collage") }
        let n = sizes.count
        let gap = CGFloat(min(max(0, o.spacing), 1000))
        var cell = CGFloat(min(max(16, o.cellSize), 8000))
        var frames: [CGRect] = []          // top-left origin
        var canvas = CGSize.zero

        func layout() {
            frames.removeAll()
            switch o.layout {
            case .grid:
                let cols = o.columns > 0 ? min(o.columns, n) : Int(ceil(sqrt(Double(n))))
                let rows = Int(ceil(Double(n) / Double(cols)))
                canvas = CGSize(width: CGFloat(cols) * cell + CGFloat(cols + 1) * gap,
                                height: CGFloat(rows) * cell + CGFloat(rows + 1) * gap)
                for i in 0..<n {
                    let c = i % cols, r = i / cols
                    frames.append(CGRect(x: gap + CGFloat(c) * (cell + gap), y: gap + CGFloat(r) * (cell + gap), width: cell, height: cell))
                }
            case .horizontal:
                var x = gap
                for s in sizes {
                    let w = max(1, (cell * s.width / max(1, s.height)).rounded())
                    frames.append(CGRect(x: x, y: gap, width: w, height: cell))
                    x += w + gap
                }
                canvas = CGSize(width: x, height: cell + 2 * gap)
            case .vertical:
                var y = gap
                for s in sizes {
                    let h = max(1, (cell * s.height / max(1, s.width)).rounded())
                    frames.append(CGRect(x: gap, y: y, width: cell, height: h))
                    y += h + gap
                }
                canvas = CGSize(width: cell + 2 * gap, height: y)
            }
        }
        func tooBig() -> Bool { canvas.width * canvas.height > o.maxArea || max(canvas.width, canvas.height) > o.maxSide }

        layout()
        var tries = 0
        while tooBig() && cell > 16 && tries < 12 {
            let byArea = sqrt(o.maxArea / (canvas.width * canvas.height))
            let bySide = o.maxSide / max(canvas.width, canvas.height)
            cell = max(16, (cell * min(byArea, bySide) * 0.98).rounded(.down))
            layout()
            tries += 1
        }
        guard !tooBig() else {
            throw EngineError.invalidInput("Collage of \(n) images would exceed \(Int(o.maxArea / 1_000_000)) MP; use fewer images or less spacing")
        }

        let opaque = o.background.alpha >= 1
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: ImageOps.sRGB,
                                  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue) else {
            throw EngineError.failed("Couldn't allocate the collage canvas")
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(o.background)
        ctx.fill(CGRect(origin: .zero, size: canvas))
        for (i, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let cg = cgRect(fromTopLeft: frame, canvasHeight: canvas.height)
            let s = (o.fill && o.layout == .grid) ? ImageOps.fill(sizes[i], in: frame.size) : ImageOps.fit(sizes[i], in: frame.size)
            let r = CGRect(x: cg.midX - s.width / 2, y: cg.midY - s.height / 2, width: s.width, height: s.height)
            try autoreleasepool {
                let img = try image(i, Int(max(s.width, s.height).rounded(.up)))
                ctx.saveGState()
                ctx.clip(to: cg)
                ctx.draw(img, in: r)
                ctx.restoreGState()
            }
        }
        return try ImageOps.image(from: ctx)
    }
}
