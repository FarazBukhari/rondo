import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import RondoKit
import Vision

/// Downsampled, orientation-corrected preview of the source plus its full-resolution size.
/// All editor state lives in full-resolution pixels; `scale` converts to proxy pixels for drawing only.
public struct ImageProxy: @unchecked Sendable {
    public let image: CGImage
    /// Upright full-resolution size, i.e. the pixel space every submitted coordinate uses.
    public let sourceSize: CGSize
    public let hasAlpha: Bool

    public init(image: CGImage, sourceSize: CGSize, hasAlpha: Bool? = nil) {
        self.image = image
        self.sourceSize = sourceSize
        self.hasAlpha = hasAlpha ?? image.hasAlphaChannel
    }

    /// Proxy pixels per source pixel (≤ 1).
    public var scale: CGFloat { sourceSize.width > 0 ? CGFloat(image.width) / sourceSize.width : 1 }
}

extension CGImage {
    var hasAlphaChannel: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}

public enum ProxyLoaderError: LocalizedError, Equatable {
    case missing(String)
    case unreadable(String)
    case needsMagick(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let n): "\(n) doesn't exist or can't be read."
        case .unreadable(let n): "\(n) isn't an image this Mac can decode."
        case .needsMagick(let n): "Previewing \(n) needs ImageMagick (magick), which wasn't found."
        }
    }
}

public enum ProxyLoader {
    /// Long-edge cap for the on-screen proxy.
    public static let maxPixel = 2048

    /// ImageIO first (orientation applied, downsampled while decoding); `magick` for SVG and anything
    /// ImageIO can't read — rasterized with the same arguments ImageEngine uses so sizes match.
    public static func load(_ url: URL, maxPixel: Int = maxPixel, tools: ToolLocator = ToolLocator()) async throws -> ImageProxy {
        let name = url.lastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else { throw ProxyLoaderError.missing(name) }
        let fmt = FormatCatalog.format(for: url)?.id
        if fmt != "svg", let p = loadImageIO(url, maxPixel: maxPixel) { return p }
        guard let magick = tools.url(for: "magick") else {
            throw fmt == "svg" ? ProxyLoaderError.needsMagick(url.lastPathComponent) : ProxyLoaderError.unreadable(url.lastPathComponent)
        }
        let dir = try TempDir.make(prefix: "image-editor")
        defer { TempDir.remove(dir) }
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        let link = dir.appendingPathComponent("src.\(ext)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let out = dir.appendingPathComponent("decoded.png")
        var args: [String] = []
        if fmt == "svg" { args += ["-density", "96", "-background", "none"] }
        args += [link.path + "[0]", "-auto-orient", "PNG32:" + out.path]
        do {
            try await ProcessRunner.run(magick, args)
        } catch let error as CancellationError {
            throw error
        } catch {
            editorLog.error("magick decode failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw ProxyLoaderError.unreadable(name)
        }
        guard let p = loadImageIO(out, maxPixel: maxPixel) else { throw ProxyLoaderError.unreadable(name) }
        return p
    }

    static func loadImageIO(_ url: URL, maxPixel: Int) -> ImageProxy? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(src)
        let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any]) ?? [:]
        var w = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue ?? 0
        var h = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue ?? 0
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        if w <= 0 || h <= 0, let full = CGImageSourceCreateImageAtIndex(src, index, nil) {
            w = Double(full.width); h = Double(full.height)
        }
        guard w > 0, h > 0 else { return nil }
        if (5...8).contains(orientation) { swap(&w, &h) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, Int(max(w, h))),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) else { return nil }
        let alpha = (props[kCGImagePropertyHasAlpha as String] as? NSNumber)?.boolValue ?? thumb.hasAlphaChannel
        return ImageProxy(image: thumb, sourceSize: CGSize(width: w, height: h), hasAlpha: alpha)
    }

    /// Proxy for an in-memory image (tests, snapshots).
    public static func proxy(for image: CGImage, maxPixel: Int = maxPixel) -> ImageProxy {
        let size = CGSize(width: image.width, height: image.height)
        let s = min(1, CGFloat(maxPixel) / max(size.width, size.height))
        guard s < 1 else { return ImageProxy(image: image, sourceSize: size) }
        let w = max(1, Int((size.width * s).rounded())), h = max(1, Int((size.height * s).rounded()))
        let ctx = PreviewRenderer.context(width: w, height: h)
        ctx?.interpolationQuality = .high
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ImageProxy(image: ctx?.makeImage() ?? image, sourceSize: size, hasAlpha: image.hasAlphaChannel)
    }
}

/// Live previews on the proxy. Each mirrors the ImageEngine operation for the same options; lengths given
/// in source pixels (blur radius, padding, pixelate blocks) are multiplied by `scale` (proxy px per source px).
public enum PreviewRenderer {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Same options as ImageEngine's context (default working space) so filters land on the same values.
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func size(_ image: CGImage) -> CGSize { CGSize(width: image.width, height: image.height) }

    // MARK: Orientation

    /// Pixels of `image` rotated/flipped the way `image.crop` does it.
    public static func oriented(_ image: CGImage, _ o: Orientation) -> CGImage {
        guard !o.isIdentity else { return image }
        let src = size(image), dst = o.orientedSize(src)
        guard let ctx = context(width: Int(dst.width), height: Int(dst.height)) else { return image }
        // bottom-left source → top-left source → oriented top-left → bottom-left destination
        let fSrc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: src.height)
        let fDst = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: dst.height)
        ctx.concatenate(fSrc.concatenating(o.transform(for: src)).concatenating(fDst))
        ctx.draw(image, in: CGRect(origin: .zero, size: src))
        return ctx.makeImage() ?? image
    }

    // MARK: Adjust

    public static func adjusted(_ image: CGImage, _ a: AdjustSettings, scale: CGFloat) -> CGImage {
        guard !a.isDefault else { return image }
        let extent = CGRect(origin: .zero, size: size(image))
        var ci = CIImage(cgImage: image)
        if a.exposure != 0 { ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.brightness != 0 || a.contrast != 1 || a.saturation != 1 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: a.brightness, kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation,
            ])
        }
        if a.gamma != 1 { ci = ci.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / max(0.05, a.gamma)]) }
        if a.vibrance != 0 { ci = ci.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance]) }
        if a.hue != 0 { ci = ci.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: a.hue * .pi / 180]) }
        if a.temperature != 6500 || a.tint != 0 {
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: a.temperature, y: a.tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if a.sharpness > 0 {
            ci = ci.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: a.sharpness, kCIInputRadiusKey: max(0.3, 1.69 * min(1, scale)),
            ])
        }
        if a.blur > 0 { ci = ci.clampedToExtent().applyingGaussianBlur(sigma: a.blur * Double(scale)).cropped(to: extent) }
        switch a.filter {
        case "sepia": ci = ci.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 1.0])
        case "invert": ci = ci.applyingFilter("CIColorInvert")
        case "mono", "noir", "chrome", "fade", "instant", "process", "tonal", "transfer":
            ci = ci.applyingFilter("CIPhotoEffect" + a.filter.prefix(1).uppercased() + a.filter.dropFirst())
        default: break
        }
        return ciContext.createCGImage(ci.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: sRGB) ?? image
    }

    // MARK: Redact

    /// `settings.regions` are source pixels; drawn into the proxy at `scale`.
    public static func redacted(_ image: CGImage, _ settings: RedactSettings, sourceSize: CGSize, scale: CGFloat) -> CGImage {
        let regions = settings.pixelRegions(bounds: sourceSize)
        guard !regions.isEmpty else { return image }
        let H = CGFloat(image.height)
        func proxyRect(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        }
        switch settings.style {
        case .black, .pixelate:
            guard let ctx = context(width: image.width, height: image.height) else { return image }
            ctx.draw(image, in: CGRect(origin: .zero, size: size(image)))
            for r in regions {
                let pr = proxyRect(r)
                let dest = CGRect(x: pr.minX, y: H - pr.maxY, width: pr.width, height: pr.height)
                if settings.style == .black {
                    ctx.setFillColor(settings.color.cgColor)
                    ctx.fill(dest)
                    continue
                }
                // Same block count as the engine: block = max(6, min(w,h)/8) source px.
                let block = max(6, min(r.width, r.height) / 8)
                let sw = max(1, Int((r.width / block).rounded())), sh = max(1, Int((r.height / block).rounded()))
                guard let piece = image.cropping(to: pr.integral), let small = context(width: sw, height: sh) else { continue }
                small.interpolationQuality = .high
                small.draw(piece, in: CGRect(x: 0, y: 0, width: sw, height: sh))
                guard let tiny = small.makeImage() else { continue }
                ctx.saveGState()
                ctx.interpolationQuality = .none
                ctx.draw(tiny, in: dest)
                ctx.restoreGState()
            }
            return ctx.makeImage() ?? image
        case .blur:
            let base = CIImage(cgImage: image)
            var ci = base
            for r in regions {
                let pr = proxyRect(r)
                let cr = CGRect(x: pr.minX, y: H - pr.maxY, width: pr.width, height: pr.height)
                let sigma = Double(max(8, min(r.width, r.height) / 4) * scale)
                ci = base.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: cr).composited(over: ci)
            }
            let extent = CGRect(origin: .zero, size: size(image))
            return ciContext.createCGImage(ci.cropped(to: extent), from: extent, format: .RGBA8, colorSpace: sRGB) ?? image
        }
    }

    // MARK: Background

    /// Composites `subject` (the proxy, or a lifted subject) like `image.background`; padding is in source px.
    public static func backgrounded(_ subject: CGImage, _ b: BackgroundSettings, scale: CGFloat) -> CGImage {
        let p = (CGFloat(max(0, b.padding)) * scale).rounded()
        if b.mode == .remove && p == 0 { return subject }
        let W = subject.width + 2 * Int(p), H = subject.height + 2 * Int(p)
        guard let ctx = context(width: W, height: H) else { return subject }
        let fill = b.mode == .remove ? nil : b.color
        if let fill {
            ctx.setFillColor(fill.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }
        ctx.draw(subject, in: CGRect(x: p, y: p, width: CGFloat(subject.width), height: CGFloat(subject.height)))
        return ctx.makeImage() ?? subject
    }

    /// Vision subject lift on the proxy (preview of `replace` / `remove`).
    @available(macOS 14.0, *)
    public static func liftSubject(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
            throw EngineError.failed("No subject found in image")
        }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: sRGB) else {
            throw EngineError.failed("Subject render failed")
        }
        return cg
    }

    // MARK: Annotate (for flattened snapshots / tests)

    /// Proxy with annotations burned in — the same drawing the engine does, scaled to the proxy.
    public static func annotated(_ image: CGImage, _ shapes: [Annotation], scale: CGFloat) -> CGImage {
        guard let ctx = context(width: image.width, height: image.height) else { return image }
        ctx.draw(image, in: CGRect(origin: .zero, size: size(image)))
        ctx.scaleBy(x: scale, y: scale)
        ShapeRenderer.draw(shapes, in: ctx, canvasHeight: CGFloat(image.height) / scale)
        return ctx.makeImage() ?? image
    }
}
