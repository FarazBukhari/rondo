import Foundation
import CoreGraphics
import ImageIO
import RondoKit

/// Images → PDF (one image per page) and collages.
enum ImageCompose {
    enum PageSize: String { case fit, a4, letter }

    /// Writes one page per image. `fit` pages match the image's physical size (pixels at its DPI).
    static func writePDF(_ items: [LoadedImage], to url: URL, pageSize: PageSize, margin: Double, quality: Double,
                         title: String?, progress: (Double) -> Void) throws {
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [String: Any] = [kCGPDFContextCreator as String: "Rondo"]
        if let title { info[kCGPDFContextTitle as String] = title }
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary) else {
            throw EngineError.failed("Can't create PDF")
        }
        let m = CGFloat(max(0, margin))
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            let img = item.image
            let natural = CGSize(width: CGFloat(img.width) * 72 / item.dpi, height: CGFloat(img.height) * 72 / item.dpi)
            let landscape = natural.width > natural.height
            var page: CGSize
            switch pageSize {
            case .fit: page = CGSize(width: natural.width + 2 * m, height: natural.height + 2 * m)
            case .a4: page = landscape ? CGSize(width: 841.89, height: 595.28) : CGSize(width: 595.28, height: 841.89)
            case .letter: page = landscape ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792)
            }
            var box = CGRect(origin: .zero, size: page)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            let area = CGRect(origin: .zero, size: page).insetBy(dx: m, dy: m)
            let drawSize = pageSize == .fit ? natural : ImageOps.fit(natural, in: area.size)
            let rect = CGRect(x: area.midX - drawSize.width / 2, y: area.midY - drawSize.height / 2,
                              width: drawSize.width, height: drawSize.height)
            ctx.interpolationQuality = .high
            ctx.draw(embeddable(item, quality: quality), in: rect)
            ctx.endPDFPage()
            progress(Double(i + 1) / Double(max(1, items.count)))
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
    }

    static func collage(_ images: [CGImage], options o: CollageOptions) throws -> CGImage {
        guard !images.isEmpty else { throw EngineError.invalidInput("No images for collage") }
        let n = images.count
        let gap = CGFloat(max(0, o.spacing))
        var cell = CGFloat(max(16, o.cellSize))
        var frames: [CGRect] = []          // top-left origin
        var canvas = CGSize.zero
        let maxSide: CGFloat = 16_000

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
                for img in images {
                    let w = (cell * CGFloat(img.width) / CGFloat(max(1, img.height))).rounded()
                    frames.append(CGRect(x: x, y: gap, width: w, height: cell))
                    x += w + gap
                }
                canvas = CGSize(width: x, height: cell + 2 * gap)
            case .vertical:
                var y = gap
                for img in images {
                    let h = (cell * CGFloat(img.height) / CGFloat(max(1, img.width))).rounded()
                    frames.append(CGRect(x: gap, y: y, width: cell, height: h))
                    y += h + gap
                }
                canvas = CGSize(width: cell + 2 * gap, height: y)
            }
        }
        layout()
        if max(canvas.width, canvas.height) > maxSide {
            cell = max(16, (cell * maxSide / max(canvas.width, canvas.height)).rounded(.down))
            layout()
        }

        let opaque = o.background.alpha >= 1
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: ImageOps.sRGB,
                                  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue) else {
            throw EngineError.failed("Collage canvas too large")
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(o.background)
        ctx.fill(CGRect(origin: .zero, size: canvas))
        for (img, frame) in zip(images, frames) {
            try Task.checkCancellation()
            let cg = cgRect(fromTopLeft: frame, canvasHeight: canvas.height)
            let s = (o.fill && o.layout == .grid) ? ImageOps.fill(img.size, in: frame.size) : ImageOps.fit(img.size, in: frame.size)
            let r = CGRect(x: cg.midX - s.width / 2, y: cg.midY - s.height / 2, width: s.width, height: s.height)
            ctx.saveGState()
            ctx.clip(to: cg)
            ctx.draw(img, in: r)
            ctx.restoreGState()
        }
        guard let out = ctx.makeImage() else { throw EngineError.failed("Collage render failed") }
        return out
    }
}
