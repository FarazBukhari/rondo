import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision
import RondoKit

/// Headless image tools: compress, metadata read/strip, QR read.
enum ImageTools {
    // MARK: Compress

    struct Candidate { let url: URL; let size: Int }

    /// Output format for compression: lossy formats keep their format; PNG/GIF are palette-quantized;
    /// TIFF/BMP become JPEG (they have no useful lossy mode).
    static func compressFormat(for source: String?) -> String {
        switch source {
        case "jpg", "heic", "webp", "avif": source!
        case "png": "png"
        case "gif": "gif"
        default: "jpg"
        }
    }

    /// Encodes at `quality` (0…1), or searches for the largest result ≤ `targetBytes`
    /// (binary search ≤ 8 encodes per pass; one downscale pass if even the lowest quality is too big).
    /// `result` is the largest candidate ≤ target, else the smallest produced; `smallest` is the smallest size seen.
    static func compress(_ loaded: LoadedImage, format: String, quality: Double, targetBytes: Int?,
                         tools: ToolLocator, scratch: URL, progress: @escaping (Double) -> Void) async throws -> (result: Candidate, smallest: Int) {
        let palette = format == "png" || format == "gif"
        let props = loaded.carryProperties

        func encode(_ image: CGImage, _ q: Double) async throws -> Candidate {
            try Task.checkCancellation()
            let out = scratch.appendingPathComponent("c-\(UUID().uuidString.prefix(8)).\(ImageFormats.ext(format))")
            if palette {
                try await quantize(image, format: format, quality: q, to: out, tools: tools, scratch: scratch)
            } else {
                try await ImageCodec.write(image, format: format, to: out, quality: q, properties: props, tools: tools, scratch: scratch)
            }
            return Candidate(url: out, size: fileSize(out))
        }

        guard let target = targetBytes, target > 0 else {
            progress(0.3)
            let c = try await encode(loaded.image, quality)
            return (c, c.size)
        }

        var image = loaded.image
        var best: Candidate?          // largest ≤ target
        var smallest: Candidate?
        for pass in 0..<2 {
            var lo = 0.0, hi = 1.0
            var lowestSize = Int.max
            for i in 0..<8 {
                let q = (lo + hi) / 2
                let c = try await encode(image, q)
                progress(Double(pass * 8 + i + 1) / 16)
                if c.size < (smallest?.size ?? .max) { smallest = c }
                lowestSize = min(lowestSize, c.size)
                if c.size <= target {
                    if c.size > (best?.size ?? -1) { best = c }
                    lo = q
                    if Double(c.size) >= Double(target) * 0.97 { break }
                } else {
                    hi = q
                }
            }
            if best != nil { break }
            // Lowest quality still too big: shrink dimensions proportionally and search again.
            let ratio = sqrt(Double(target) / Double(max(1, lowestSize))) * 0.95
            guard ratio < 1 else { break }
            let w = max(1, Int(Double(image.width) * ratio)), h = max(1, Int(Double(image.height) * ratio))
            imageLog.notice("compress: downscaling to \(w)x\(h) to reach target")
            image = try ImageOps.resized(image, width: w, height: h)
        }
        guard let result = best ?? smallest else { throw EngineError.failed("Compression produced no output") }
        return (result, smallest?.size ?? result.size)
    }

    /// PNG/GIF: reduce to a palette with magick (`quality` → 2…256 colors). Without magick, plain re-encode.
    static func quantize(_ image: CGImage, format: String, quality: Double, to out: URL, tools: ToolLocator, scratch: URL) async throws {
        guard let magick = tools.url(for: "magick") else {
            try ImageCodec.writeImageIO(image, type: ImageFormats.utType(format)!, to: out, quality: nil, properties: [:])
            return
        }
        let src = scratch.appendingPathComponent("q-src-\(UUID().uuidString.prefix(8)).png")
        try ImageCodec.writeImageIO(image, type: "public.png", to: src, quality: nil, properties: [:])
        let q = quality.isFinite ? min(max(quality, 0), 1) : 0.7
        let colors = max(2, min(256, Int((pow(q, 1.5) * 254).rounded()) + 2))
        var args = [src.path, "-dither", "FloydSteinberg", "-colors", String(colors)]
        if format == "png" { args += ["-define", "png:compression-level=9", "-define", "png:compression-filter=5"] }
        args.append(ImageCodec.magickPrefix(format) + out.path)
        try await ProcessRunner.run(magick, args)
    }

    // MARK: Metadata read

    static func metadataJSON(_ loaded: LoadedImage, input: URL) throws -> Data {
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: input.path)) ?? [:]
        let iso = ISO8601DateFormatter()
        var file: [String: Any] = [
            "name": input.lastPathComponent,
            "path": input.path,
            "bytes": (attrs[.size] as? NSNumber)?.intValue ?? 0,
            "format": loaded.sourceFormat ?? input.pathExtension.lowercased(),
        ]
        if let d = attrs[.creationDate] as? Date { file["created"] = iso.string(from: d) }
        if let d = attrs[.modificationDate] as? Date { file["modified"] = iso.string(from: d) }

        let img = loaded.image
        var info: [String: Any] = [
            "width": img.width,
            "height": img.height,
            "orientation": Int(loaded.sourceOrientation),
            "hasAlpha": img.hasAlpha,
            "bitsPerComponent": img.bitsPerComponent,
            "frames": loaded.frameCount,
            "dpi": loaded.dpi,
        ]
        if let cs = img.colorSpace {
            info["colorModel"] = "\(cs.model)"
            if let name = cs.name as String? { info["colorSpace"] = name }
        }
        if let profile = loaded.rawProperties[kCGImagePropertyProfileName as String] as? String { info["profile"] = profile }

        let root: [String: Any] = ["file": file, "image": info, "properties": sanitize(loaded.rawProperties)]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Makes an ImageIO property tree JSON-safe (Data → byte count, NaN → nil, keys stringified).
    static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]:
            return d.reduce(into: [String: Any]()) { acc, kv in acc[kv.key] = sanitize(kv.value) }
        case let d as NSDictionary:
            var acc: [String: Any] = [:]
            d.forEach { acc["\($0.key)"] = sanitize($0.value) }
            return acc
        case let a as [Any]:
            return a.map(sanitize)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            let dv = n.doubleValue
            return dv.isFinite ? n : NSNull()
        case let s as String:
            return s.replacingOccurrences(of: "\u{0}", with: "")
        case let data as Data:
            return "<\(data.count) bytes>"
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        default:
            return "\(value)"
        }
    }

    // MARK: Metadata strip

    /// Re-encodes with no EXIF/GPS/IPTC/XMP (keeps the color profile; orientation baked into pixels).
    static func strip(_ loaded: LoadedImage, format: String, quality: Double, to out: URL, tools: ToolLocator, scratch: URL) async throws {
        // Lossless path for JPEG/PNG/TIFF/HEIC when nothing needs baking: copy the coded image, drop metadata.
        if loaded.untouched, loaded.sourceFormat == format, ["jpg", "png", "tiff", "heic"].contains(format),
           losslessStrip(loaded.sourceURL, to: out, type: ImageFormats.utType(format)!) {
            return
        }
        try await ImageCodec.write(loaded.image, format: format, to: out, quality: quality, properties: [:], tools: tools, scratch: scratch)
    }

    static func losslessStrip(_ src: URL, to out: URL, type: String) -> Bool {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else { return false }
        let options: [String: Any] = [
            kCGImageDestinationMetadata as String: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata as String: false,
            kCGImageMetadataShouldExcludeXMP as String: true,
            kCGImageMetadataShouldExcludeGPS as String: true,
        ]
        var err: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &err) else {
            try? FileManager.default.removeItem(at: out)
            return false
        }
        // Verify: anything identifying left behind → fall back to re-encode.
        guard let check = CGImageSourceCreateWithURL(out as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [String: Any] else { return false }
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let leaked = props[kCGImagePropertyGPSDictionary as String] != nil
            || props[kCGImagePropertyIPTCDictionary as String] != nil
            || tiff[kCGImagePropertyTIFFMake as String] != nil || tiff[kCGImagePropertyTIFFModel as String] != nil
            || tiff[kCGImagePropertyTIFFSoftware as String] != nil || tiff[kCGImagePropertyTIFFArtist as String] != nil
            || exif[kCGImagePropertyExifDateTimeOriginal as String] != nil || exif[kCGImagePropertyExifMakerNote as String] != nil
        if leaked { try? FileManager.default.removeItem(at: out) }
        return !leaked
    }

    // MARK: QR / barcodes

    /// Payloads of every QR code / barcode found (Vision first, Core Image QR detector as fallback).
    static func readCodes(_ image: CGImage) -> [String] {
        var found: [String] = []
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            for obs in request.results ?? [] {
                if let s = obs.payloadStringValue, !found.contains(s) { found.append(s) }
            }
        } catch {
            imageLog.notice("Vision barcode detection failed: \(error.localizedDescription, privacy: .public)")
        }
        if found.isEmpty,
           let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) {
            for f in detector.features(in: CIImage(cgImage: image)) {
                if let s = (f as? CIQRCodeFeature)?.messageString, !found.contains(s) { found.append(s) }
            }
        }
        return found
    }
}
