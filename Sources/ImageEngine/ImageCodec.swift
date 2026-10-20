import Foundation
import CoreGraphics
import ImageIO
import RondoKit

/// A decoded image with orientation baked into the pixels.
struct LoadedImage {
    var image: CGImage
    /// Metadata worth carrying into converted outputs (EXIF/GPS/IPTC/TIFF/DPI), orientation removed.
    var carryProperties: [String: Any]
    /// Raw ImageIO properties of the source frame (for metadata read).
    var rawProperties: [String: Any]
    var sourceFormat: String?
    var sourceURL: URL
    var dpi: Double
    var frameCount: Int
    var sourceOrientation: UInt32
    /// Pixels came straight from the file with no transform (lets JPEG → PDF pass the bytes through).
    var untouched: Bool
}

enum ImageCodec {
    // MARK: Load

    /// Decodes `url` via ImageIO, or via `magick` for SVG and anything ImageIO can't read.
    static func load(_ url: URL, tools: ToolLocator, scratch: URL, svgDPI: Double = 96) async throws -> LoadedImage {
        try requireReadableFile(url)
        let fmt = FormatCatalog.format(for: url)?.id
        if fmt != "svg", let loaded = loadImageIO(url, format: fmt) { return loaded }
        guard let magick = tools.url(for: "magick") else {
            if fmt == "svg" { throw EngineError.missingTool("magick") }
            throw EngineError.invalidInput("\(url.lastPathComponent) isn't a readable image")
        }
        let png = try await magickDecode(url, format: fmt, magick: magick, scratch: scratch, svgDPI: svgDPI)
        guard var loaded = loadImageIO(png, format: "png") else {
            throw EngineError.failed("Couldn't decode \(url.lastPathComponent)")
        }
        loaded.sourceFormat = fmt
        loaded.sourceURL = url
        loaded.untouched = false
        return loaded
    }

    static func loadImageIO(_ url: URL, format: String?) -> LoadedImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(src) as String?,
              ImageFormats.imageIOReadable.contains(type) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        guard let raw = CGImageSourceCreateImageAtIndex(src, index, nil) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any]) ?? [:]
        let o = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: o) ?? .up
        let image = ImageOps.normalized(ImageOps.oriented(raw, orientation))
        let dpi = (props[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue ?? 72
        return LoadedImage(
            image: image,
            carryProperties: carryable(props),
            rawProperties: props,
            sourceFormat: format,
            sourceURL: url,
            dpi: dpi > 1 ? dpi : 72,
            frameCount: count,
            sourceOrientation: o,
            untouched: orientation == .up
        )
    }

    /// Keeps camera/location/IPTC metadata; drops orientation and stale pixel dimensions.
    static func carryable(_ props: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        let keep = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight].map { $0 as String }
        for k in keep { if let v = props[k] { out[k] = v } }
        if var tiff = out[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation as String)
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = out[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            out[kCGImagePropertyExifDictionary as String] = exif
        }
        return out
    }

    /// Rasterizes via ImageMagick into a PNG inside `scratch`. Input is symlinked to a safe name
    /// so magick never interprets brackets/globs in user file names.
    static func magickDecode(_ url: URL, format: String?, magick: URL, scratch: URL, svgDPI: Double) async throws -> URL {
        let ext = format.map(ImageFormats.ext) ?? (url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased())
        let link = scratch.appendingPathComponent("decode-src-\(UUID().uuidString.prefix(8)).\(ext)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let out = scratch.appendingPathComponent("decoded-\(UUID().uuidString.prefix(8)).png")
        var args: [String] = []
        if format == "svg" { args += ["-density", String(Int(max(18, min(1200, svgDPI)))), "-background", "none"] }
        args += [link.path + "[0]", "-auto-orient", "PNG32:" + out.path]
        try await ProcessRunner.run(magick, args)
        return out
    }

    // MARK: Write

    /// Encodes `image` as catalog format `format` (not "pdf") at `url`.
    /// ImageIO first; `magick` when ImageIO can't write the type or fails at runtime (e.g. no HEVC encoder).
    static func write(_ image: CGImage, format: String, to url: URL, quality: Double?, properties: [String: Any] = [:],
                      tools: ToolLocator, scratch: URL) async throws {
        guard let type = ImageFormats.utType(format) else { throw EngineError.unsupported("writing \(format)") }
        var prepared = ImageFormats.opaqueOnly.contains(format) ? ImageOps.flattened(image) : ImageOps.normalized(image)
        if format == "bmp" { prepared = ImageOps.rgb8(prepared) }
        let q = ImageFormats.lossy.contains(format) ? quality : nil
        var imageIOError: Error?
        if ImageFormats.imageIOWritable.contains(type) {
            do {
                try writeImageIO(prepared, type: type, to: url, quality: q, properties: properties)
                // BMP is the format where ImageIO has written files it can't read back; verify it.
                if format == "bmp" && !decodes(url) {
                    try? FileManager.default.removeItem(at: url)
                    throw EngineError.failed("BMP encode produced an unreadable file")
                }
                return
            } catch {
                imageIOError = error
                imageLog.notice("ImageIO \(format, privacy: .public) encode failed, trying magick")
            }
        }
        guard ImageFormats.magickEncodable.contains(format), let magick = tools.url(for: "magick") else {
            throw imageIOError ?? EngineError.missingTool("magick")
        }
        let src = scratch.appendingPathComponent("encode-src-\(UUID().uuidString.prefix(8)).png")
        try writeImageIO(prepared, type: "public.png", to: src, quality: nil, properties: [:])
        var args = [src.path]
        if let q { args += ["-quality", String(Int((min(max(q, 0), 1) * 100).rounded()))] }
        args.append(magickPrefix(format) + url.path)
        try await ProcessRunner.run(magick, args)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError.failed("magick produced no \(format) output")
        }
    }

    static func decodes(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
    }

    static func magickPrefix(_ format: String) -> String {
        switch format {
        case "jpg": "JPEG:"
        default: format.uppercased() + ":"
        }
    }

    static func writeImageIO(_ image: CGImage, type: String, to url: URL, quality: Double?, properties: [String: Any]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw EngineError.failed("Can't create \(type) encoder")
        }
        var props = properties
        props[kCGImagePropertyOrientation as String] = 1
        if let q = quality { props[kCGImageDestinationLossyCompressionQuality as String] = min(max(q, 0), 1) }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw EngineError.failed("Encoding \(type) failed")
        }
    }

    /// In-memory encode (used for JPEG streams embedded in PDFs).
    static func encodeData(_ image: CGImage, type: String, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }
        var props: [String: Any] = [:]
        if let q = quality { props[kCGImageDestinationLossyCompressionQuality as String] = q }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
