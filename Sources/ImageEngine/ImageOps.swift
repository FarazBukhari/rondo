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
enum ImageOps {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Bitmap context that keeps the source's color space (ICC profile) and bit depth where CG allows it.
    static func context(width: Int, height: Int, like image: CGImage?, opaque: Bool) -> CGContext? {
        var cs = image?.colorSpace ?? sRGB
        let usable = (cs.model == .rgb || cs.model == .monochrome) && cs.supportsOutput
        if !usable || (cs.model == .monochrome && !opaque) { cs = sRGB }
        let deep = (image?.bitsPerComponent ?? 8) > 8
        func make(_ space: CGColorSpace, _ bpc: Int) -> CGContext? {
            let alpha: CGImageAlphaInfo = space.model == .monochrome ? .none : (opaque ? .noneSkipLast : .premultipliedLast)
            return CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: bpc,
                             bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)
        }
        let ctx = (deep ? make(cs, 16) : nil) ?? make(cs, 8) ?? make(sRGB, 8)
        ctx?.interpolationQuality = .high
        return ctx
    }

    /// Palette (indexed), sub-8-bit, or unusual color models → 8-bit (or 16-bit) RGB/gray via a bitmap
    /// context, so every encoder and pixel op sees a plain image (ImageIO writes unreadable palette BMPs otherwise).
    static func normalized(_ image: CGImage) -> CGImage {
        let model = image.colorSpace?.model
        let plain = (model == .rgb || model == .monochrome) && image.bitsPerComponent >= 8
        guard !plain, let ctx = context(width: image.width, height: image.height, like: image, opaque: !image.hasAlpha) else { return image }
        ctx.draw(image, in: CGRect(origin: .zero, size: image.size))
        return ctx.makeImage() ?? image
    }

    /// Opaque 8-bit RGB (source RGB profile kept when usable) — the one layout every BMP reader handles.
    static func rgb8(_ image: CGImage) -> CGImage {
        let src = image.colorSpace
        let cs = (src?.model == .rgb && src?.supportsOutput == true) ? src! : sRGB
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: image.size))
        ctx.draw(image, in: CGRect(origin: .zero, size: image.size))
        return ctx.makeImage() ?? image
    }

    /// Bakes an EXIF orientation into the pixels so every output format displays upright.
    static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let swaps: Bool = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
        let outW = swaps ? h : w, outH = swaps ? w : h

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
        switch orientation {
        case .upMirrored, .downMirrored:
            t = t.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored:
            t = t.translatedBy(x: h, y: 0).scaledBy(x: -1, y: 1)
        default: break
        }
        guard let ctx = context(width: Int(outW), height: Int(outH), like: image, opaque: !image.hasAlpha) else { return image }
        ctx.concatenate(t)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Clockwise rotation by a multiple of 90°, then optional flips.
    static func rotated(_ image: CGImage, degrees: Int, flipH: Bool = false, flipV: Bool = false) -> CGImage {
        var img = image
        switch ((degrees % 360) + 360) % 360 {
        case 90: img = oriented(img, .right)
        case 180: img = oriented(img, .down)
        case 270: img = oriented(img, .left)
        default: break
        }
        if flipH { img = oriented(img, .upMirrored) }
        if flipV { img = oriented(img, .downMirrored) }
        return img
    }

    /// Composites onto a solid color (default white), dropping alpha.
    static func flattened(_ image: CGImage, color: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) -> CGImage {
        guard image.hasAlpha, let ctx = context(width: image.width, height: image.height, like: image, opaque: true) else { return image }
        let r = CGRect(origin: .zero, size: image.size)
        ctx.setFillColor(color)
        ctx.fill(r)
        ctx.draw(image, in: r)
        return ctx.makeImage() ?? image
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard width != image.width || height != image.height,
              let ctx = context(width: width, height: height, like: image, opaque: !image.hasAlpha) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// Crop with a top-left-origin rect (CGImage cropping uses top-left pixel coordinates).
    static func cropped(_ image: CGImage, to rect: CGRect) -> CGImage? {
        guard let r = clampRect(rect, to: image.size) else { return nil }
        guard let c = image.cropping(to: r) else { return nil }
        // Detach from the parent's backing store so re-encoders see a compact image.
        guard let ctx = context(width: c.width, height: c.height, like: c, opaque: !c.hasAlpha) else { return c }
        ctx.draw(c, in: CGRect(origin: .zero, size: c.size))
        return ctx.makeImage() ?? c
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
