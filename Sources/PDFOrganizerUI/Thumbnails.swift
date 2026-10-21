import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// A page of a PDF on disk (1-based page).
struct ThumbKey: Hashable, Sendable {
    let url: URL
    let page: Int
}

/// Renders page thumbnails with PDFKit on one background queue (its own read-only `PDFDocument` per file —
/// the user's file is never written) and publishes them on the main actor. Rendering is lazy (cells
/// request on appear) with a small LRU cap so huge PDFs don't hold every page in memory.
@MainActor
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [ThumbKey: CGImage] = [:]

    /// Longest side of a rendered thumbnail, in pixels.
    let maxPixels: CGFloat
    let capacity: Int
    private var pending: Set<ThumbKey> = []
    private var lastUse: [ThumbKey: UInt64] = [:]
    private var clock: UInt64 = 0
    private let renderer = PageRenderer()

    init(maxPixels: CGFloat = 320, capacity: Int = 400) {
        self.maxPixels = maxPixels
        self.capacity = capacity
    }

    func image(_ key: ThumbKey) -> CGImage? { images[key] }

    func request(_ key: ThumbKey) {
        clock += 1
        lastUse[key] = clock
        guard images[key] == nil, !pending.contains(key) else { return }
        pending.insert(key)
        let size = maxPixels
        renderer.render(key, maxPixels: size) { [weak self] image in
            Task { @MainActor in self?.deliver(key, image) }
        }
    }

    /// Renders synchronously on the calling thread (tests / snapshot rendering).
    func loadNow(_ keys: [ThumbKey]) {
        let local = PageRenderer.Documents()
        for key in keys where images[key] == nil {
            clock += 1
            lastUse[key] = clock
            if let img = PageRenderer.renderPage(key, maxPixels: maxPixels, documents: local) { images[key] = img }
        }
    }

    private func deliver(_ key: ThumbKey, _ image: CGImage?) {
        pending.remove(key)
        guard let image else { return }
        images[key] = image
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        guard images.count > capacity else { return }
        let victims = images.keys.sorted { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) }.prefix(images.count - capacity)
        for key in victims {
            images[key] = nil
            lastUse[key] = nil
        }
    }
}

/// Background PDFKit renderer. All document access happens on `queue`.
final class PageRenderer: @unchecked Sendable {
    final class Documents {
        private var docs: [URL: PDFDocument] = [:]
        func document(_ url: URL) -> PDFDocument? {
            if let d = docs[url] { return d }
            guard let d = PDFDocument(url: url), !d.isLocked else { return nil }
            docs[url] = d
            return d
        }
    }

    private let queue = DispatchQueue(label: "com.farazbukhari.rondo.pdf-organizer.thumbs", qos: .userInitiated)
    private let documents = Documents()

    func render(_ key: ThumbKey, maxPixels: CGFloat, completion: @escaping @Sendable (CGImage?) -> Void) {
        queue.async { [documents] in
            let image = Self.renderPage(key, maxPixels: maxPixels, documents: documents)
            completion(image)
        }
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// White page, aspect-fit into `maxPixels`, with the page's own rotation applied (not the user's).
    static func renderPage(_ key: ThumbKey, maxPixels: CGFloat, documents: Documents) -> CGImage? {
        guard let doc = documents.document(key.url), let page = doc.page(at: key.page - 1) else { return nil }
        let box = page.bounds(for: .cropBox)
        let rot = ((page.rotation % 360) + 360) % 360
        let size = (rot == 90 || rot == 270) ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = maxPixels / max(size.width, size.height)
        let w = max(1, Int((size.width * scale).rounded())), h = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(w) / size.width, y: CGFloat(h) / size.height)
        page.draw(with: .cropBox, to: ctx)   // PDFKit applies the page's rotation and box origin
        return ctx.makeImage()
    }
}

/// Opens a PDF read-only to learn its page count, or why it can't be organized.
enum PDFProbe {
    enum Result: Equatable {
        case ok(pageCount: Int)
        case failed(String)
    }

    static func probe(_ url: URL) -> Result {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return .failed("\(url.lastPathComponent) can't be found.")
        }
        guard let doc = PDFDocument(url: url) else { return .failed("\(url.lastPathComponent) isn't a readable PDF.") }
        if doc.isLocked { return .failed("\(url.lastPathComponent) is password-protected.") }
        guard doc.pageCount > 0 else { return .failed("\(url.lastPathComponent) has no pages.") }
        return .ok(pageCount: doc.pageCount)
    }
}
