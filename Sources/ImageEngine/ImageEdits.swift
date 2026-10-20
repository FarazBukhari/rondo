import Foundation
import CoreGraphics
import CoreImage
import CoreText
import Vision
import RondoKit

/// Pixel edits behind the editor-backed tools (crop / adjust / annotate / redact / background).
/// Every function is headless and takes explicit values so W6's editor can build a JobSpec.
enum ImageEdits {
    // MARK: Adjust

    struct Adjustments: Equatable {
        var brightness = 0.0      // -1…1
        var contrast = 1.0        // 0.25…4
        var saturation = 1.0      // 0…2
        var exposure = 0.0        // EV -3…3
        var gamma = 1.0           // 0.25…4
        var vibrance = 0.0        // -1…1
        var hue = 0.0             // degrees -180…180
        var temperature = 6500.0  // Kelvin, higher = warmer
        var tint = 0.0            // -150…150
        var sharpness = 0.0       // 0…2
        var blur = 0.0            // radius px 0…100
        var filter = "none"       // none|mono|noir|chrome|fade|instant|process|tonal|transfer|sepia|invert

        init() {}

        init(job: JobSpec) {
            brightness = job.double("brightness", default: 0)
            contrast = job.double("contrast", default: 1)
            saturation = job.double("saturation", default: 1)
            exposure = job.double("exposure", default: 0)
            gamma = job.double("gamma", default: 1)
            vibrance = job.double("vibrance", default: 0)
            hue = job.double("hue", default: 0)
            temperature = job.double("temperature", default: 6500)
            tint = job.double("tint", default: 0)
            sharpness = job.double("sharpness", default: 0)
            blur = job.double("blur", default: 0)
            filter = job.string("filter")?.lowercased() ?? "none"
        }
    }

    static let filterPresets = ["none", "mono", "noir", "chrome", "fade", "instant", "process", "tonal", "transfer", "sepia", "invert"]

    static func adjust(_ image: CGImage, _ a: Adjustments) throws -> CGImage {
        guard a != Adjustments() else { return image }
        let extent = CGRect(origin: .zero, size: image.size)
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
        if a.sharpness > 0 { ci = ci.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness]) }
        if a.blur > 0 { ci = ci.clampedToExtent().applyingGaussianBlur(sigma: a.blur).cropped(to: extent) }
        switch a.filter {
        case "none", "": break
        case "sepia": ci = ci.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 1.0])
        case "invert": ci = ci.applyingFilter("CIColorInvert")
        case "mono", "noir", "chrome", "fade", "instant", "process", "tonal", "transfer":
            ci = ci.applyingFilter("CIPhotoEffect" + a.filter.prefix(1).uppercased() + a.filter.dropFirst())
        default: throw EngineError.invalidInput("Unknown filter \(a.filter)")
        }
        return try render(ci.cropped(to: extent), like: image)
    }

    static func render(_ ci: CIImage, like image: CGImage) throws -> CGImage {
        let cs = (image.colorSpace?.model == .rgb && image.colorSpace?.supportsOutput == true) ? image.colorSpace! : ImageOps.sRGB
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let format: CIFormat = image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        guard let out = ctx.createCGImage(ci, from: CGRect(origin: .zero, size: image.size), format: format, colorSpace: cs) else {
            throw EngineError.failed("Core Image render failed")
        }
        return out
    }

    // MARK: Annotate

    /// One shape, decoded from the `shapes` JSON option. Coordinates: source pixels, top-left origin.
    struct Shape: Decodable {
        var type: String                 // rect | ellipse | line | arrow | freehand | text
        var x: Double?
        var y: Double?
        var w: Double?
        var h: Double?
        var points: [[Double]]?          // line/arrow: 2 points; freehand: many
        var color: String?               // hex, default #FF3B30
        var lineWidth: Double?           // default 4
        var fill: Bool?                  // rect/ellipse: filled instead of stroked
        var text: String?
        var fontSize: Double?            // default 32
        var font: String?                // PostScript name, default system bold
    }

    static func decodeShapes(_ json: String?) throws -> [Shape] {
        guard let json, !json.isEmpty else { throw EngineError.invalidInput("annotate needs a `shapes` JSON option") }
        do { return try JSONDecoder().decode([Shape].self, from: Data(json.utf8)) }
        catch { throw EngineError.invalidInput("Bad `shapes` JSON: \(error.localizedDescription)") }
    }

    static func annotate(_ image: CGImage, shapes: [Shape]) throws -> CGImage {
        guard let ctx = ImageOps.context(width: image.width, height: image.height, like: image, opaque: !image.hasAlpha) else {
            throw EngineError.failed("Can't create canvas")
        }
        let H = CGFloat(image.height)
        ctx.draw(image, in: CGRect(origin: .zero, size: image.size))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        func pt(_ p: [Double]) -> CGPoint? { p.count >= 2 ? CGPoint(x: p[0], y: Double(H) - p[1]) : nil }

        for s in shapes {
            try Task.checkCancellation()
            let color = ColorParser.parse(s.color) ?? CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
            let lw = CGFloat(max(0.5, s.lineWidth ?? 4))
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
            ctx.setLineWidth(lw)
            let rect = cgRect(fromTopLeft: CGRect(x: s.x ?? 0, y: s.y ?? 0, width: s.w ?? 0, height: s.h ?? 0), canvasHeight: H)
            switch s.type.lowercased() {
            case "rect", "rectangle", "highlight":
                if s.fill ?? (s.type == "highlight") { ctx.fill(rect) } else { ctx.stroke(rect) }
            case "ellipse", "circle", "oval":
                if s.fill ?? false { ctx.fillEllipse(in: rect) } else { ctx.strokeEllipse(in: rect) }
            case "line", "arrow", "freehand", "pen":
                let pts = (s.points ?? []).compactMap(pt)
                guard pts.count >= 2 else { continue }
                ctx.beginPath()
                ctx.addLines(between: pts)
                ctx.strokePath()
                if s.type.lowercased() == "arrow", let tip = pts.last {
                    let from = pts[pts.count - 2]
                    let angle = atan2(tip.y - from.y, tip.x - from.x)
                    let len = max(12, lw * 4)
                    let a1 = CGPoint(x: tip.x - len * cos(angle - .pi / 7), y: tip.y - len * sin(angle - .pi / 7))
                    let a2 = CGPoint(x: tip.x - len * cos(angle + .pi / 7), y: tip.y - len * sin(angle + .pi / 7))
                    ctx.beginPath()
                    ctx.move(to: tip); ctx.addLine(to: a1); ctx.addLine(to: a2); ctx.closePath()
                    ctx.fillPath()
                }
            case "text":
                guard let text = s.text, !text.isEmpty else { continue }
                drawText(text, at: CGPoint(x: s.x ?? 0, y: s.y ?? 0), size: CGFloat(s.fontSize ?? 32), fontName: s.font,
                         color: color, in: ctx, canvasHeight: H)
            default:
                throw EngineError.invalidInput("Unknown shape type \(s.type)")
            }
        }
        guard let out = ctx.makeImage() else { throw EngineError.failed("Annotate render failed") }
        return out
    }

    /// Draws text with its top-left at `origin` (top-left canvas coordinates). Supports "\n".
    static func drawText(_ text: String, at origin: CGPoint, size: CGFloat, fontName: String?, color: CGColor,
                         in ctx: CGContext, canvasHeight H: CGFloat) {
        let font: CTFont = fontName.map { CTFontCreateWithName($0 as CFString, size, nil) }
            ?? CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let lineHeight = ascent + descent + leading
        ctx.saveGState()
        ctx.textMatrix = .identity
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let attr = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
            let ctLine = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: origin.x, y: H - origin.y - ascent - CGFloat(i) * lineHeight)
            CTLineDraw(ctLine, ctx)
        }
        ctx.restoreGState()
    }

    // MARK: Redact

    enum RedactStyle: String { case black, pixelate, blur }

    static func redact(_ image: CGImage, regions: [CGRect], style: RedactStyle, color: CGColor?) throws -> CGImage {
        guard !regions.isEmpty else { throw EngineError.invalidInput("redact needs `regions` (x,y,w,h quads) or `rect`") }
        let H = CGFloat(image.height)
        switch style {
        case .black:
            guard let ctx = ImageOps.context(width: image.width, height: image.height, like: image, opaque: !image.hasAlpha) else {
                throw EngineError.failed("Can't create canvas")
            }
            ctx.draw(image, in: CGRect(origin: .zero, size: image.size))
            ctx.setFillColor(color ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            for r in regions { ctx.fill(cgRect(fromTopLeft: r, canvasHeight: H)) }
            guard let out = ctx.makeImage() else { throw EngineError.failed("Redact render failed") }
            return out
        case .pixelate:
            guard let ctx = ImageOps.context(width: image.width, height: image.height, like: image, opaque: !image.hasAlpha) else {
                throw EngineError.failed("Can't create canvas")
            }
            ctx.draw(image, in: CGRect(origin: .zero, size: image.size))
            for r in regions {
                guard let piece = image.cropping(to: r) else { continue }
                let block = max(6, min(r.width, r.height) / 8)
                let sw = max(1, Int((r.width / block).rounded())), sh = max(1, Int((r.height / block).rounded()))
                let small = ImageOps.resized(piece, width: sw, height: sh)
                ctx.saveGState()
                ctx.interpolationQuality = .none
                ctx.draw(small, in: cgRect(fromTopLeft: r, canvasHeight: H))
                ctx.restoreGState()
            }
            guard let out = ctx.makeImage() else { throw EngineError.failed("Redact render failed") }
            return out
        case .blur:
            var ci = CIImage(cgImage: image)
            let base = ci
            for r in regions {
                let cr = cgRect(fromTopLeft: r, canvasHeight: H)
                let sigma = max(8, min(r.width, r.height) / 4)
                let blurred = base.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: cr)
                ci = blurred.composited(over: ci)
            }
            return try render(ci, like: image)
        }
    }

    // MARK: Background

    enum BackgroundMode: String { case fill, replace, remove }

    /// fill: composite transparent areas onto `color`, with optional `padding` px on every side.
    /// replace / remove (macOS 14+): lift the subject with Vision, then put it on `color` or leave it transparent.
    static func background(_ image: CGImage, mode: BackgroundMode, color: CGColor, padding: Int) throws -> CGImage {
        var subject = image
        if mode != .fill { subject = try liftSubject(image) }
        if mode == .remove && padding == 0 { return subject }
        let p = max(0, padding)
        let W = subject.width + 2 * p, H = subject.height + 2 * p
        let fillColor = mode == .remove ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0) : color
        let opaque = fillColor.alpha >= 1 && mode != .remove
        guard let ctx = ImageOps.context(width: W, height: H, like: image, opaque: opaque) else {
            throw EngineError.failed("Can't create canvas")
        }
        ctx.setFillColor(fillColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.draw(subject, in: CGRect(x: p, y: p, width: subject.width, height: subject.height))
        guard let out = ctx.makeImage() else { throw EngineError.failed("Background render failed") }
        return out
    }

    static func liftSubject(_ image: CGImage) throws -> CGImage {
        guard #available(macOS 14.0, *) else {
            throw EngineError.unsupported("Subject lifting needs macOS 14 or later")
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch {
            throw EngineError.failed("Subject detection unavailable: \(error.localizedDescription)")
        }
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
            throw EngineError.failed("No subject found in image")
        }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: ImageOps.sRGB) else {
            throw EngineError.failed("Subject render failed")
        }
        return cg
    }
}
