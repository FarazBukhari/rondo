import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Generated PDFs for organizer tests, written under fixtures/out/W8/src/.
enum W8Fixtures {
    static let root: URL = {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("fixtures/out/W8", isDirectory: true)
    }()

    static func dir(_ name: String) -> URL {
        let d = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Fresh, empty directory under fixtures/out/W8 (only ever removes inside W8).
    static func freshDir(_ name: String) -> URL {
        let d = root.appendingPathComponent(name, isDirectory: true)
        precondition(d.path.hasPrefix(root.path))
        try? FileManager.default.removeItem(at: d)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// `pages` pages, each a tinted card reading "Page N" (PDF text — `PDFPage.string` returns it).
    /// Pages listed in `landscape` are 792×612.
    @discardableResult
    static func makePDF(_ name: String, pages: Int, landscape: Set<Int> = [], label: String = "Page") -> URL {
        let url = dir("src").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path),
           let doc = PDFDocument(url: url), doc.pageCount == pages { return url }
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &media, nil)!
        for i in 1...pages {
            var box = landscape.contains(i) ? CGRect(x: 0, y: 0, width: 792, height: 612) : media
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            let hue = CGFloat((i * 47) % 360) / 360
            let tint = NSColor(hue: hue, saturation: 0.35, brightness: 0.97, alpha: 1).usingColorSpace(.sRGB)!.cgColor
            let ink = NSColor(hue: hue, saturation: 0.8, brightness: 0.45, alpha: 1).usingColorSpace(.sRGB)!.cgColor
            ctx.setFillColor(tint)
            ctx.fill(box.insetBy(dx: 40, dy: 40))
            ctx.setFillColor(ink)
            ctx.fill(CGRect(x: 40, y: box.height - 120, width: box.width - 80, height: 80))   // header bar marks "up"
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 110, nil)
            let attr = NSAttributedString(string: "\(label) \(i)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 70, y: box.height / 2 - 40)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// Page texts of a PDF ("Page 3" …), trimmed.
    static func texts(_ url: URL) -> [String] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return (0..<doc.pageCount).map { (doc.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func rotations(_ url: URL) -> [Int] {
        guard let doc = PDFDocument(url: url) else { return [] }
        return (0..<doc.pageCount).map { doc.page(at: $0)?.rotation ?? -1 }
    }
}
