import Foundation
import CoreGraphics
import ImageIO
import os
import RondoKit

let imageLog = Logger(subsystem: "com.farazbukhari.rondo", category: "image")

/// Catalog ids this engine reads / writes, and ImageIO capability probes.
enum ImageFormats {
    static let inputs = ["jpg", "png", "heic", "webp", "avif", "tiff", "gif", "bmp", "svg"]
    static let outputs = ["jpg", "png", "heic", "webp", "avif", "tiff", "gif", "bmp", "pdf"]
    /// Formats with a quality knob.
    static let lossy: Set<String> = ["jpg", "heic", "webp", "avif"]
    /// Formats that can't carry alpha → flatten onto white.
    static let opaqueOnly: Set<String> = ["jpg", "bmp"]
    /// Formats `magick` can encode when ImageIO can't (or fails at runtime).
    static let magickEncodable: Set<String> = ["webp", "avif", "heic", "jpg", "png", "tiff", "gif", "bmp"]

    static let imageIOReadable: Set<String> = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
    static let imageIOWritable: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static func utType(_ id: String) -> String? { FormatCatalog.format(id: id)?.utType }
    static func ext(_ id: String) -> String { FormatCatalog.format(id: id)?.preferredExtension ?? id }

    static func imageIOCanRead(_ id: String) -> Bool {
        guard id != "svg", let t = utType(id) else { return false }
        return imageIOReadable.contains(t)
    }

    static func imageIOCanWrite(_ id: String) -> Bool {
        guard let t = utType(id) else { return false }
        return imageIOWritable.contains(t)
    }

    static func canRead(_ id: String, tools: ToolLocator) -> Bool {
        imageIOCanRead(id) || tools.has("magick")
    }

    static func canWrite(_ id: String, tools: ToolLocator) -> Bool {
        if id == "pdf" { return true }
        if imageIOCanWrite(id) { return true }
        return magickEncodable.contains(id) && tools.has("magick")
    }
}

// MARK: - Colors

enum ColorParser {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// "#RGB", "#RRGGBB", "#RRGGBBAA", "white", "black", "transparent", "clear".
    static func parse(_ string: String?) -> CGColor? {
        guard var s = string?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return nil }
        switch s {
        case "white": return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case "black": return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case "transparent", "clear", "none": return CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
        case "red": return CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
        case "yellow": return CGColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)
        default: break
        }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Option helpers

extension JobSpec {
    /// Option as a finite Double, or nil when missing / NaN / ±inf.
    func finite(_ key: String) -> Double? {
        let v = double(key, default: .nan)
        return v.isFinite ? v : nil
    }

    /// Finite option clamped to `range` (default when missing or non-finite).
    func clamped(_ key: String, default d: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(finite(key) ?? d, range.lowerBound), range.upperBound)
    }

    /// Integer option, clamped in Double space before converting (never traps on huge / non-finite input).
    func clampedInt(_ key: String, default d: Int, _ range: ClosedRange<Int>) -> Int {
        Int(clamped(key, default: Double(d), Double(range.lowerBound)...Double(range.upperBound)).rounded())
    }

    /// 0…1 quality.
    func unit(_ key: String, default d: Double) -> Double { clamped(key, default: d, 0...1) }

    /// Rect from a `list` option (x, y, w, h; top-left origin, source pixels), clamped to `bounds`.
    func topLeftRect(_ key: String, within size: CGSize) -> CGRect? {
        let v = list(key)
        guard v.count >= 4 else { return nil }
        return clampRect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), to: size)
    }

    /// Flat list of rect quads (x, y, w, h, x, y, w, h, …) in top-left pixel coordinates.
    func topLeftRects(_ key: String, within size: CGSize) -> [CGRect] {
        let v = list(key)
        guard v.count >= 4 else { return [] }
        return stride(from: 0, through: v.count - 4, by: 4).compactMap {
            clampRect(CGRect(x: v[$0], y: v[$0 + 1], width: v[$0 + 2], height: v[$0 + 3]), to: size)
        }
    }
}

func clampRect(_ r: CGRect, to size: CGSize) -> CGRect? {
    guard [r.origin.x, r.origin.y, r.width, r.height].allSatisfy(\.isFinite) else { return nil }
    let c = r.standardized.integral.intersection(CGRect(origin: .zero, size: size))
    return (c.isNull || c.width < 1 || c.height < 1) ? nil : c
}

/// Top-left-origin rect → CoreGraphics bottom-left rect for a canvas of height `h`.
func cgRect(fromTopLeft r: CGRect, canvasHeight h: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

/// Fresh scratch directory inside the job's temp dir.
func scratchDir(_ context: JobContext) throws -> URL {
    let d = context.tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func byteString(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
}

func requireReadableFile(_ url: URL) throws {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
        throw EngineError.invalidInput("\(url.lastPathComponent) is not a readable file")
    }
}
