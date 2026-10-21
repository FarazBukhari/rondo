import Foundation
import CoreGraphics
import ImageIO
import RondoKit

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
    var size: CGSize { CGSize(width: width, height: height) }
}

/// Pure CoreGraphics pixel operations. All coordinates handed in by callers are top-left origin.
/// Every op throws instead of silently returning its input when a canvas can't be created.
enum ImageOps {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Largest bitmap any op will allocate (≈ 800 MB at 8-bit RGBA) — big enough for 200 MP camera files.
    static let maxPixelArea = 200_000_000
    /// Largest output a resize may *create* (upscaling is where runaway sizes come from).
    static let maxResizeArea = 100_000_000
    static let maxSide = 65_535

    static func checkCanvas(_ width: Int, _ height: Int) throws {
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, width <= maxSide, height <= maxSide, !overflow, area <= maxPixelArea else {
            throw EngineError.invalidInput("Image would be \(width)×\(height) px; the limit is \(maxPixelArea / 1_000_000) MP")
        }
    }

    /// Bitmap context that keeps the source's color space (ICC profile) and bit depth where CG allows it.
    static func context(width: Int, height: Int, like image: CGImage?, opaque: Bool) throws -> CGContext {
        try checkCanvas(width, height)
        var cs = image?.colorSpace ?? sRGB
        let usable = (cs.model == .rgb || cs.model == .monochrome) && cs.supportsOutput
        if !usable || (cs.model == .monochrome && !opaque) { cs = sRGB }
        let deep = (image?.bitsPerComponent ?? 8) > 8
        func make(_ space: CGColorSpace, _ bpc: Int) -> CGContext? {
            let alpha: CGImageAlphaInfo = space.model == .monochrome ? .none : (opaque ? .noneSkipLast : .premultipliedLast)
            return CGContext(data: nil, width: width, height: height, bitsPerComponent: bpc,
                             bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)
        }
        guard let ctx = (deep ? make(cs, 16) : nil) ?? make(cs, 8) ?? make(sRGB, 8) else {
            throw EngineError.failed("Couldn't allocate a \(width)×\(height) canvas")
        }
        ctx.interpolationQuality = .high
        return ctx
    }

    static func image(from ctx: CGContext) throws -> CGImage {
        guard let img = ctx.makeImage() else { throw EngineError.failed("Couldn't render image") }
        return img
    }

    /// Palette (indexed), sub-8-bit, or unusual color models → 8-bit (or 16-bit) RGB/gray via a bitmap
    /// context, so every encoder and pixel op sees a plain image (ImageIO writes unreadable palette BMPs otherwise).
    static func normalized(_ image: CGImage) throws -> CGImage {
        let model = image.colorSpace?.model
        let plain = (model == .rgb || model == .monochrome) && image.bitsPerComponent >= 8
        guard !plain else { return image }
        let ctx = try context(width: image.width, height: image.height, like: image, opaque: !image.hasAlpha)
        ctx.draw(image, in: CGRect(origin: .zero, size: image.size))
        return try self.image(from: ctx)
    }

    /// Opaque 8-bit RGB (source RGB profile kept when usable) — the one layout every BMP reader handles.
    static func rgb8(_ image: CGImage) throws -> CGImage {
        try checkCanvas(image.width, image.height)
        let src = image.colorSpace
        let cs = (src?.model == .rgb && src?.supportsOutput == true) ? src! : sRGB
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw EngineError.failed("Couldn't allocate a \(image.width)×\(image.height) canvas")
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: image.size))
        ctx.draw(image, in: CGRect(origin: .zero, size: image.size))
        return try self.image(from: ctx)
    }

    /// Bakes an EXIF orientation into the pixels so every output format displays upright.
    static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) throws -> CGImage {
        guard orientation != .up else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)       // stored (encoded) size
        let swaps: Bool = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let outW = swaps ? h : w, outH = swaps ? w : h               // display size

        var t = CGAffineTransform.identity
        switch orientation {
        case .down, .downMirrored:
            t = t.translatedBy(x: outW, y: outH).rotated(by: .pi)
        case .left, .leftMirrored:
            t = t.translatedBy(x: outW, y: 0).rotated(by: .pi / 2)
        case .right, .rightMirrored:
            t = t.translatedBy(x: 0, y: outH).rotated(by: -.pi / 2)
        default: break
        }
        // The mirror happens in the stored image's space (after rotation), so it spans the stored width.
        switch orientation {
        case .upMirrored, .downMirrored, .leftMirrored, .rightMirrored:
            t = t.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        default: break
        }
        let ctx = try context(width: Int(outW), height: Int(outH), like: image, opaque: !image.hasAlpha)
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return try self.image(from: ctx)
    }

    /// Clockwise rotation by a multiple of 90°, then optional flips.
    static func rotated(_ image: CGImage, degrees: Int, flipH: Bool = false, flipV: Bool = false) throws -> CGImage {
        var img = image
        switch ((degrees % 360) + 360) % 360 {
        case 90: img = try oriented(img, .right)
        case 180: img = try oriented(img, .down)
        case 270: img = try oriented(img, .left)
        default: break
        }
        if flipH { img = try oriented(img, .upMirrored) }
        if flipV { img = try oriented(img, .downMirrored) }
        return img
    }

    /// Composites onto a solid color (default white), dropping alpha.
    static func flattened(_ image: CGImage, color: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) throws -> CGImage {
        guard image.hasAlpha else { return image }
        let ctx = try context(width: image.width, height: image.height, like: image, opaque: true)
        let r = CGRect(origin: .zero, size: image.size)
        ctx.setFillColor(color)
        ctx.fill(r)
        ctx.draw(image, in: r)
        return try self.image(from: ctx)
    }

    static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width != image.width || height != image.height else { return image }
        let ctx = try context(width: width, height: height, like: image, opaque: !image.hasAlpha)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try self.image(from: ctx)
    }

    /// Crop with a top-left-origin rect (CGImage cropping uses top-left pixel coordinates).
    static func cropped(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        guard let r = clampRect(rect, to: image.size), let c = image.cropping(to: r) else {
            throw EngineError.invalidInput("Crop rect is outside the image")
        }
        // Detach from the parent's backing store so re-encoders see a compact image.
        let ctx = try context(width: c.width, height: c.height, like: c, opaque: !c.hasAlpha)
        ctx.draw(c, in: CGRect(origin: .zero, size: c.size))
        return try self.image(from: ctx)
    }

    /// Aspect-fit size of `size` inside `box`.
    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let s = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * s, height: size.height * s)
    }

    static func fill(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let s = max(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * s, height: size.height * s)
    }
}
