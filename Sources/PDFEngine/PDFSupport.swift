import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import os
import RondoKit

let pdfLog = Logger(subsystem: "com.farazbukhari.rondo", category: "pdf")

enum PDFSupport {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func open(_ url: URL) throws -> PDFDocument {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw EngineError.invalidInput("\(url.lastPathComponent) is not a readable file")
        }
        guard let doc = PDFDocument(url: url) else { throw EngineError.invalidInput("\(url.lastPathComponent) isn't a readable PDF") }
        if doc.isLocked { throw EngineError.invalidInput("\(url.lastPathComponent) is password-protected") }
        guard doc.pageCount > 0 else { throw EngineError.invalidInput("\(url.lastPathComponent) has no pages") }
        return doc
    }

    static func scratchDir(_ context: JobContext) throws -> URL {
        let d = context.tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// "Page 7" / "Page 07" (zero-padded to the page count's width so Finder sorts them).
    static func pageName(_ n: Int, of count: Int) -> String {
        let width = String(count).count
        let num = String(n)
        return "Page " + String(repeating: "0", count: max(0, width - num.count)) + num
    }

    /// Reads a text file in its own encoding (BOM / UTF-8), falling back to Latin-1. Normalizes line endings.
    static func readText(_ url: URL) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw EngineError.invalidInput("\(url.lastPathComponent) is not a readable file")
        }
        var enc = String.Encoding.utf8
        let s: String
        if let v = try? String(contentsOf: url, usedEncoding: &enc) {
            s = v
        } else {
            let data = try Data(contentsOf: url)
            s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        }
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Writes DPI into an image's metadata so Preview reports the render resolution.
    static func writeImage(_ image: CGImage, format: String, quality: Double, dpi: Double, to url: URL) throws {
        let type = format == "jpg" ? "public.jpeg" : "public.png"
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw EngineError.failed("Can't create \(type) encoder")
        }
        var props: [String: Any] = [kCGImagePropertyDPIWidth as String: dpi, kCGImagePropertyDPIHeight as String: dpi]
        if format == "jpg" { props[kCGImageDestinationLossyCompressionQuality as String] = min(max(quality, 0), 1) }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EngineError.failed("Encoding \(format) failed") }
    }

    /// Page size for text documents: Letter in the US/Canada-style locales, else A4. Overridable via `pageSize`.
    static func pageSize(_ option: String?) -> CGSize {
        switch option?.lowercased() {
        case "a4": return CGSize(width: 595.28, height: 841.89)
        case "letter": return CGSize(width: 612, height: 792)
        default:
            let region = Locale.current.region?.identifier ?? "US"
            return ["US", "CA", "MX", "PH", "CL", "CO", "VE"].contains(region)
                ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
        }
    }
}

extension JobSpec {
    /// 1-based page numbers from a `list` option, keeping only valid ones.
    func pageList(_ key: String, pageCount: Int) -> [Int] {
        list(key).map { Int($0.rounded()) }.filter { (1...pageCount).contains($0) }
    }
}
