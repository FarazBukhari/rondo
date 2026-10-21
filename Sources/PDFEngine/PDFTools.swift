import Foundation
import CoreGraphics
import PDFKit
import Quartz
import RondoKit

/// Page-level PDF tools: compress, merge, split, reorder, metadata strip.
enum PDFTools {
    // MARK: Compress

    struct Candidate { let url: URL; let size: Int }

    /// Re-encodes embedded images as JPEG at `quality`, downsampled to `dpi`, keeping text and vectors
    /// (Quartz filter applied while PDFKit rewrites the file).
    static func recompressImages(_ input: URL, quality: Double, dpi: Double, to out: URL) throws -> Candidate {
        let doc = try PDFSupport.open(input)
        let props: [String: Any] = [
            "Domains": ["Applications": true, "Printing": true],
            "FilterType": 1,
            "Name": "Rondo Compress",
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": min(max(quality, 0), 1),
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": max(18, dpi),
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": 100_000,
                            "ImageSizeMin": 0,
                        ] as [String: Any],
                    ] as [String: Any],
                ],
            ],
        ]
        guard let filter = QuartzFilter(properties: props) else { throw EngineError.failed("Quartz filter unavailable") }
        let ok = doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter])
        guard ok, FileManager.default.fileExists(atPath: out.path) else { throw EngineError.failed("PDF rewrite failed") }
        return Candidate(url: out, size: PDFSupport.fileSize(out))
    }

    /// Fallback / last resort: every page becomes one JPEG at `dpi` (text no longer selectable).
    static func rasterize(_ input: URL, quality: Double, dpi: Double, to out: URL) throws -> Candidate {
        let doc = try PDFSupport.open(input)
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(out as CFURL, mediaBox: &media, nil) else { throw EngineError.failed("Can't create PDF") }
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            let image = try PDFRender.render(page, dpi: dpi)
            let box = page.bounds(for: .cropBox)
            let rot = ((page.rotation % 360) + 360) % 360
            var rect = CGRect(origin: .zero, size: (rot == 90 || rot == 270) ? CGSize(width: box.height, height: box.width) : box.size)
            let boxData = Data(bytes: &rect, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            let data = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
            if let provider = CGDataProvider(data: data as CFData),
               let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                ctx.draw(jpeg, in: rect)
            } else {
                ctx.draw(image, in: rect)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return Candidate(url: out, size: PDFSupport.fileSize(out))
    }

    enum CompressMode: String { case images, rasterize }

    /// Quality-only, or a search for the largest result ≤ `targetBytes`:
    /// 1. binary search on quality at `dpi`; 2. if even the lowest quality is too big, binary search the DPI
    /// (at quality 0.5) and refine quality there; 3. if images mode still can't fit, repeat with rasterized pages.
    /// Returns the largest candidate ≤ target (else the smallest produced) and the smallest size seen.
    static func compress(_ input: URL, mode: CompressMode, quality: Double, dpi: Double, targetBytes: Int?, scratch: URL,
                         progress: (Double) -> Void) throws -> (result: Candidate, smallest: Int) {
        var attempt = 0
        func encode(_ m: CompressMode, _ q: Double, _ d: Double) throws -> Candidate {
            try Task.checkCancellation()
            attempt += 1
            let out = scratch.appendingPathComponent("pdf-c\(attempt).pdf")
            switch m {
            case .images:
                do { return try recompressImages(input, quality: q, dpi: d, to: out) }
                catch {
                    pdfLog.notice("Quartz filter failed (\(error.localizedDescription, privacy: .public)); rasterizing")
                    return try rasterize(input, quality: q, dpi: d, to: out)
                }
            case .rasterize:
                return try rasterize(input, quality: q, dpi: d, to: out)
            }
        }

        guard let target = targetBytes, target > 0 else {
            progress(0.2)
            let c = try encode(mode, quality, dpi)
            return (c, c.size)
        }

        var best: Candidate?          // largest ≤ target
        var smallest: Candidate?
        let budget = Double(mode == .images ? 44 : 22)
        func record(_ c: Candidate) -> Candidate {
            if c.size < (smallest?.size ?? .max) { smallest = c }
            if c.size <= target, c.size > (best?.size ?? -1) { best = c }
            progress(min(0.99, Double(attempt) / budget))
            return c
        }
        func closeEnough() -> Bool { Double(best?.size ?? 0) >= Double(target) * 0.95 }

        /// Binary search on quality in lo…hi at `d`; returns the smallest size seen.
        func searchQuality(_ m: CompressMode, _ d: Double, lo: Double = 0, hi: Double = 1) throws -> Int {
            var lo = lo, hi = hi, minSize = Int.max
            for _ in 0..<8 {
                let q = (lo + hi) / 2
                let c = record(try encode(m, q, d))
                minSize = min(minSize, c.size)
                if c.size <= target { lo = q } else { hi = q }
                if closeEnough() || hi - lo < 0.01 { break }
            }
            return minSize
        }

        let modes: [CompressMode] = mode == .images ? [.images, .rasterize] : [.rasterize]
        for m in modes {
            let startDPI = max(18, m == .images ? dpi : min(dpi, 150))
            let minSize = try searchQuality(m, startDPI)
            if closeEnough() || minSize <= target { break }    // fits (or the best this mode can do without growing)
            // Too big even at the lowest quality: find the largest DPI that fits at mid quality, then refine.
            var lo = 18.0, hi = startDPI, fit: Double?
            for _ in 0..<6 {
                let d = (lo + hi) / 2
                if record(try encode(m, 0.5, d)).size <= target { fit = d; lo = d } else { hi = d }
                if hi - lo < 2 { break }
            }
            if let fit {
                _ = try searchQuality(m, fit, lo: 0.5, hi: 1)
            } else {
                _ = try searchQuality(m, 18, lo: 0, hi: 0.5)
            }
            if best != nil { break }
        }
        guard let result = best ?? smallest else { throw EngineError.failed("Compression produced no output") }
        return (result, smallest?.size ?? result.size)
    }

    // MARK: Merge / split / reorder

    static func merge(_ inputs: [URL], to out: URL, progress: (Double) -> Void) throws {
        let merged = PDFDocument()
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let doc = try PDFSupport.open(url)
            for p in 0..<doc.pageCount {
                guard let page = doc.page(at: p)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
            progress(Double(i + 1) / Double(inputs.count) * 0.9)
        }
        guard merged.pageCount > 0 else { throw EngineError.invalidInput("No pages to merge") }
        guard merged.write(to: out) else { throw EngineError.failed("Writing merged PDF failed") }
    }

    /// 1-based inclusive page ranges. Empty `ranges` → chunks of `every` pages.
    /// Ranges are clamped to the document in Double space (open ends like `1-inf` mean "to the last page");
    /// NaN or fully out-of-range entries are dropped. `every` is clamped to 1…pageCount.
    static func splitRanges(_ ranges: [ClosedRange<Double>], every: Int, pageCount: Int) -> [ClosedRange<Int>] {
        guard pageCount > 0 else { return [] }
        let last = Double(pageCount)
        if !ranges.isEmpty {
            return ranges.compactMap { r in
                let a = r.lowerBound.rounded(), b = r.upperBound.rounded()
                guard !a.isNaN, !b.isNaN, b >= 1, a <= last else { return nil }
                return Int(max(1, a))...Int(min(last, b))
            }
        }
        let n = min(max(1, every), pageCount)
        return stride(from: 1, through: pageCount, by: n).map { $0...min(pageCount, $0 + (n - 1)) }
    }

    static func extract(_ doc: PDFDocument, pages: ClosedRange<Int>, to out: URL) throws {
        let part = PDFDocument()
        for p in pages {
            guard let page = doc.page(at: p - 1)?.copy() as? PDFPage else { continue }
            part.insert(page, at: part.pageCount)
        }
        guard part.pageCount > 0, part.write(to: out) else { throw EngineError.failed("Writing pages \(pages) failed") }
    }

    static func rangeName(_ r: ClosedRange<Int>, of count: Int) -> String {
        r.count == 1 ? PDFSupport.pageName(r.lowerBound, of: count)
            : "Pages \(PDFSupport.pageName(r.lowerBound, of: count).dropFirst(5))-\(PDFSupport.pageName(r.upperBound, of: count).dropFirst(5))"
    }

    /// Matches W8's organizer encodings (`PageArrangement.options`):
    /// - `order`: 1-based source pages in output order (repeats allowed). Omitted → 1…N.
    /// - `rotations`: clockwise degrees, one per entry of that sequence — i.e. parallel to `order`, or to
    ///   source pages 1…N when `order` is omitted — indexed *before* deletions (missing = 0).
    /// - `deletions`: 1-based source pages dropped from the sequence (their rotation entries are ignored).
    static func reorder(_ doc: PDFDocument, order: [Int], rotations: [Int], deletions: Set<Int>, to out: URL) throws {
        let sequence = order.isEmpty ? Array(1...doc.pageCount) : order
        let result = PDFDocument()
        for (i, src) in sequence.enumerated() where !deletions.contains(src) {
            guard let page = doc.page(at: src - 1)?.copy() as? PDFPage else { continue }
            let add = i < rotations.count ? rotations[i] : 0
            let snapped = Int((Double(add) / 90).rounded()) * 90
            page.rotation = (((page.rotation + snapped) % 360) + 360) % 360
            result.insert(page, at: result.pageCount)
        }
        guard result.pageCount > 0 else { throw EngineError.invalidInput("Every page was deleted") }
        guard result.write(to: out) else { throw EngineError.failed("Writing reordered PDF failed") }
    }

    // MARK: Metadata

    /// Rebuilds the document from copies of its pages: drops the Info dictionary (title/author/subject/
    /// keywords/creator/dates) and the catalog's XMP `/Metadata` stream, which a plain rewrite keeps.
    /// The outline (bookmarks) is carried over.
    static func stripMetadata(_ input: URL, to out: URL) throws {
        let doc = try PDFSupport.open(input)
        let clean = PDFDocument()
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            clean.insert(page, at: clean.pageCount)
        }
        if let root = doc.outlineRoot, root.numberOfChildren > 0 {
            let newRoot = PDFOutline()
            copyOutline(root, into: newRoot, from: doc, to: clean)
            clean.outlineRoot = newRoot
        }
        guard clean.pageCount > 0, clean.write(to: out) else { throw EngineError.failed("Writing PDF failed") }
    }

    private static func copyOutline(_ src: PDFOutline, into dst: PDFOutline, from old: PDFDocument, to new: PDFDocument) {
        for i in 0..<src.numberOfChildren {
            guard let child = src.child(at: i) else { continue }
            let item = PDFOutline()
            item.label = child.label
            item.isOpen = child.isOpen
            if let dest = child.destination, let page = dest.page {
                let idx = old.index(for: page)
                if idx != NSNotFound, let target = new.page(at: idx) { item.destination = PDFDestination(page: target, at: dest.point) }
            }
            dst.insertChild(item, at: dst.numberOfChildren)
            copyOutline(child, into: item, from: old, to: new)
        }
    }
}
