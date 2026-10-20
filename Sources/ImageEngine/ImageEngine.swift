import Foundation
import CoreGraphics
import RondoKit

/// Image conversions + image tools. ImageIO first; `magick` for WebP write, SVG read, and ImageIO gaps.
public struct RasterEngine: Engine {
    public let id = "image"
    private let locator: ToolLocator

    public init(tools: ToolLocator = ToolLocator()) {
        self.locator = tools
    }

    // MARK: Capabilities

    public func conversions() -> [ConversionDescriptor] {
        let ins = ImageFormats.inputs.filter { ImageFormats.canRead($0, tools: locator) }
        let outs = ImageFormats.outputs.filter { ImageFormats.canWrite($0, tools: locator) }
        return RondoKit.conversions(from: ins, to: outs)
    }

    public func tools() -> [ToolDescriptor] { Self.descriptors }

    static let image: Set<FileKind> = [.image]

    static let descriptors: [ToolDescriptor] = [
        ToolDescriptor(id: "image.compress", title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", accepts: image, options: [
            OptionSpec(key: "quality", title: "Quality", control: .slider(min: 0.05, max: 1, step: 0.05), defaultValue: .double(0.7)),
            OptionSpec(key: "percent", title: "Reduce size by (%)", control: .slider(min: 5, max: 95, step: 5), defaultValue: nil),
            OptionSpec(key: "targetBytes", title: "Target size", control: .bytes, defaultValue: nil),
        ]),
        ToolDescriptor(id: "image.resize", title: "Resize", symbol: "arrow.up.left.and.arrow.down.right", accepts: image, options: [
            OptionSpec(key: "width", title: "Width (px)", control: .integer(min: 1, max: 20_000), defaultValue: nil),
            OptionSpec(key: "height", title: "Height (px)", control: .integer(min: 1, max: 20_000), defaultValue: nil),
            OptionSpec(key: "percent", title: "Scale (%)", control: .slider(min: 1, max: 400, step: 1), defaultValue: .double(50)),
            OptionSpec(key: "keepAspect", title: "Keep aspect ratio", control: .toggle, defaultValue: .bool(true)),
        ]),
        ToolDescriptor(id: "image.metadata.read", title: "Read Metadata", symbol: "info.circle", accepts: image),
        ToolDescriptor(id: "image.metadata.strip", title: "Remove Metadata", symbol: "tag.slash", accepts: image),
        ToolDescriptor(id: "image.qr.read", title: "Read QR Code", symbol: "qrcode.viewfinder", accepts: image),
        ToolDescriptor(id: "image.toPDF", title: "Images to PDF", symbol: "doc.richtext", accepts: image, multiInput: .combine(minimum: 1), options: [
            OptionSpec(key: "pageSize", title: "Page size", control: .choice(["fit", "a4", "letter"]), defaultValue: .string("fit")),
            OptionSpec(key: "margin", title: "Margin (pt)", control: .integer(min: 0, max: 144), defaultValue: .int(0)),
            OptionSpec(key: "quality", title: "Image quality", control: .slider(min: 0.1, max: 1, step: 0.05), defaultValue: .double(0.9)),
        ]),
        ToolDescriptor(id: "image.collage", title: "Collage", symbol: "square.grid.2x2", accepts: image, multiInput: .combine(minimum: 2), options: [
            OptionSpec(key: "layout", title: "Layout", control: .choice(["grid", "horizontal", "vertical"]), defaultValue: .string("grid")),
            OptionSpec(key: "columns", title: "Columns (0 = auto)", control: .integer(min: 0, max: 12), defaultValue: .int(0)),
            OptionSpec(key: "cellSize", title: "Cell size (px)", control: .integer(min: 50, max: 4000), defaultValue: .int(600)),
            OptionSpec(key: "spacing", title: "Spacing (px)", control: .integer(min: 0, max: 200), defaultValue: .int(12)),
            OptionSpec(key: "background", title: "Background", control: .text, defaultValue: .string("#FFFFFF")),
            OptionSpec(key: "fill", title: "Fill cells (crop)", control: .toggle, defaultValue: .bool(false)),
            OptionSpec(key: "format", title: "Format", control: .choice(["jpg", "png"]), defaultValue: .string("jpg")),
        ]),
        // Editor-backed tools (W6). Headless run takes the explicit options listed here.
        ToolDescriptor(id: "image.crop", title: "Crop", symbol: "crop", accepts: image, multiInput: .single, needsUI: true, options: [
            OptionSpec(key: "rect", title: "Rect x,y,w,h (px, top-left)", control: .text, defaultValue: nil),
            OptionSpec(key: "rotation", title: "Rotate (°, clockwise)", control: .choice(["0", "90", "180", "270"]), defaultValue: .int(0)),
            OptionSpec(key: "flipH", title: "Flip horizontal", control: .toggle, defaultValue: .bool(false)),
            OptionSpec(key: "flipV", title: "Flip vertical", control: .toggle, defaultValue: .bool(false)),
        ]),
        ToolDescriptor(id: "image.adjust", title: "Adjust", symbol: "slider.horizontal.3", accepts: image, needsUI: true, options: [
            OptionSpec(key: "brightness", title: "Brightness", control: .slider(min: -1, max: 1, step: 0.01), defaultValue: .double(0)),
            OptionSpec(key: "contrast", title: "Contrast", control: .slider(min: 0.25, max: 4, step: 0.01), defaultValue: .double(1)),
            OptionSpec(key: "saturation", title: "Saturation", control: .slider(min: 0, max: 2, step: 0.01), defaultValue: .double(1)),
            OptionSpec(key: "exposure", title: "Exposure (EV)", control: .slider(min: -3, max: 3, step: 0.05), defaultValue: .double(0)),
            OptionSpec(key: "gamma", title: "Gamma", control: .slider(min: 0.25, max: 4, step: 0.01), defaultValue: .double(1)),
            OptionSpec(key: "vibrance", title: "Vibrance", control: .slider(min: -1, max: 1, step: 0.01), defaultValue: .double(0)),
            OptionSpec(key: "hue", title: "Hue (°)", control: .slider(min: -180, max: 180, step: 1), defaultValue: .double(0)),
            OptionSpec(key: "temperature", title: "Temperature (K)", control: .slider(min: 2000, max: 12000, step: 50), defaultValue: .double(6500)),
            OptionSpec(key: "tint", title: "Tint", control: .slider(min: -150, max: 150, step: 1), defaultValue: .double(0)),
            OptionSpec(key: "sharpness", title: "Sharpness", control: .slider(min: 0, max: 2, step: 0.05), defaultValue: .double(0)),
            OptionSpec(key: "blur", title: "Blur (px)", control: .slider(min: 0, max: 100, step: 1), defaultValue: .double(0)),
            OptionSpec(key: "filter", title: "Filter", control: .choice(ImageEdits.filterPresets), defaultValue: .string("none")),
        ]),
        ToolDescriptor(id: "image.annotate", title: "Annotate", symbol: "pencil.tip.crop.circle", accepts: image, multiInput: .single, needsUI: true, options: [
            OptionSpec(key: "shapes", title: "Shapes (JSON)", control: .text, defaultValue: nil),
        ]),
        ToolDescriptor(id: "image.redact", title: "Redact", symbol: "eye.slash", accepts: image, multiInput: .single, needsUI: true, options: [
            OptionSpec(key: "regions", title: "Regions x,y,w,h,… (px, top-left)", control: .text, defaultValue: nil),
            OptionSpec(key: "style", title: "Style", control: .choice(["black", "pixelate", "blur"]), defaultValue: .string("black")),
            OptionSpec(key: "color", title: "Color", control: .text, defaultValue: nil),
        ]),
        ToolDescriptor(id: "image.background", title: "Background", symbol: "square.fill.on.square", accepts: image, needsUI: true, options: [
            OptionSpec(key: "mode", title: "Mode", control: .choice(["fill", "replace", "remove"]), defaultValue: .string("fill")),
            OptionSpec(key: "color", title: "Color", control: .text, defaultValue: .string("#FFFFFF")),
            OptionSpec(key: "padding", title: "Padding (px)", control: .integer(min: 0, max: 2000), defaultValue: .int(0)),
        ]),
    ]

    // MARK: Run

    public func run(_ job: JobSpec, context: JobContext) async throws -> [URL] {
        guard !job.inputs.isEmpty else { throw EngineError.invalidInput("No input files") }
        switch job.operation {
        case .convert(let to):
            guard ImageFormats.outputs.contains(to) else { throw EngineError.unsupported("image → \(to)") }
            return try await eachInput(job, context) { input, p in try await convert(input, to: to, job: job, context: context, progress: p) }
        case .tool(let tool):
            switch tool.rawValue {
            case "image.compress": return try await eachInput(job, context) { try await compress($0, job: job, context: context, progress: $1) }
            case "image.resize": return try await eachInput(job, context) { try await resize($0, job: job, context: context, progress: $1) }
            case "image.metadata.read": return try await eachInput(job, context) { try await metadataRead($0, job: job, context: context, progress: $1) }
            case "image.metadata.strip": return try await eachInput(job, context) { try await metadataStrip($0, job: job, context: context, progress: $1) }
            case "image.qr.read": return try await eachInput(job, context) { try await qrRead($0, job: job, context: context, progress: $1) }
            case "image.toPDF": return try await toPDF(job, context: context)
            case "image.collage": return try await collage(job, context: context)
            case "image.crop": return try await eachInput(job, context) { try await crop($0, job: job, context: context, progress: $1) }
            case "image.adjust":
                return try await eachInput(job, context) { input, p in
                    try await edit(input, suffix: "adjusted", job: job, context: context, progress: p) { img, _ in
                        try ImageEdits.adjust(img, .init(job: job))
                    }
                }
            case "image.annotate":
                let shapes = try ImageEdits.decodeShapes(job.string("shapes"))
                return try await eachInput(job, context) { input, p in
                    try await edit(input, suffix: "annotated", job: job, context: context, progress: p) { img, _ in
                        try ImageEdits.annotate(img, shapes: shapes)
                    }
                }
            case "image.redact":
                let style = ImageEdits.RedactStyle(rawValue: job.string("style") ?? "black") ?? .black
                return try await eachInput(job, context) { input, p in
                    try await edit(input, suffix: "redacted", job: job, context: context, progress: p) { img, _ in
                        var regions = job.topLeftRects("regions", within: img.size)
                        if regions.isEmpty, let r = job.topLeftRect("rect", within: img.size) { regions = [r] }
                        return try ImageEdits.redact(img, regions: regions, style: style, color: ColorParser.parse(job.string("color")))
                    }
                }
            case "image.background":
                return try await eachInput(job, context) { try await background($0, job: job, context: context, progress: $1) }
            default:
                throw EngineError.unsupported(tool.rawValue)
            }
        }
    }

    /// Runs `body` per input, mapping each file's progress into its slice of 0…1.
    private func eachInput(_ job: JobSpec, _ context: JobContext,
                           _ body: (URL, @escaping (Double) -> Void) async throws -> URL) async throws -> [URL] {
        var outputs: [URL] = []
        let n = Double(job.inputs.count)
        for (i, input) in job.inputs.enumerated() {
            try Task.checkCancellation()
            let base = Double(i) / n
            let report = context.progress
            outputs.append(try await body(input) { report(base + min(max($0, 0), 1) / n) })
        }
        return outputs
    }

    private func load(_ input: URL, job: JobSpec, context: JobContext, scratch: URL) async throws -> LoadedImage {
        try await ImageCodec.load(input, tools: context.tools, scratch: scratch, svgDPI: job.double("dpi", default: 96))
    }

    /// Format an edited image is saved in: the input's own format when writable, else PNG.
    private func editFormat(for loaded: LoadedImage, tools: ToolLocator, needsAlpha: Bool = false) -> String {
        guard let f = loaded.sourceFormat, f != "svg", f != "pdf", ImageFormats.canWrite(f, tools: tools) else { return "png" }
        if needsAlpha && ImageFormats.opaqueOnly.contains(f) { return "png" }
        return f
    }

    private func commit(_ temp: URL, for input: URL, ext: String, suffix: String?, context: JobContext) throws -> URL {
        try context.namer.commit(temp, to: context.outputURL(for: input, ext: ext, suffix: suffix))
    }

    // MARK: Convert

    private func convert(_ input: URL, to target: String, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        let scratch = try scratchDir(context)
        let loaded = try await load(input, job: job, context: context, scratch: scratch)
        progress(0.4)
        let out = scratch.appendingPathComponent("out.\(ImageFormats.ext(target))")
        if target == "pdf" {
            try ImageCompose.writePDF([loaded], to: out, pageSize: .fit, margin: 0, quality: job.double("quality", default: 0.9),
                                      title: OutputNamer.baseName(of: input)) { _ in }
        } else {
            try await ImageCodec.write(loaded.image, format: target, to: out, quality: job.double("quality", default: 0.85),
                                       properties: loaded.carryProperties, tools: context.tools, scratch: scratch)
        }
        progress(0.9)
        context.log("\(input.lastPathComponent) → \(target)")
        return try commit(out, for: input, ext: ImageFormats.ext(target), suffix: nil, context: context)
    }

    // MARK: Tools

    private func compress(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        let scratch = try scratchDir(context)
        let loaded = try await load(input, job: job, context: context, scratch: scratch)
        guard loaded.sourceFormat != "svg" else { throw EngineError.unsupported("Compressing SVG (convert it first)") }
        let format = ImageTools.compressFormat(for: loaded.sourceFormat)
        let original = fileSize(input)
        var target: Int? = job.int("targetBytes", default: 0) > 0 ? job.int("targetBytes", default: 0) : nil
        if target == nil, case let p = job.double("percent", default: 0), p > 0 {
            target = max(1, Int(Double(original) * (1 - min(p, 99) / 100)))
        }
        var result = try await ImageTools.compress(loaded, format: format, quality: job.double("quality", default: 0.7),
                                                   targetBytes: target, tools: context.tools, scratch: scratch, progress: progress)
        // Never hand back something bigger than the original in the same format.
        if result.size >= original, format == loaded.sourceFormat {
            let copy = scratch.appendingPathComponent("orig.\(ImageFormats.ext(format))")
            try FileManager.default.copyItem(at: input, to: copy)
            result = .init(url: copy, size: original)
            context.log("\(input.lastPathComponent): already as small as requested; kept original bytes")
        }
        context.log("\(input.lastPathComponent): \(original) → \(result.size) bytes")
        return try commit(result.url, for: input, ext: ImageFormats.ext(format), suffix: "compressed", context: context)
    }

    private func resize(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        let scratch = try scratchDir(context)
        let loaded = try await load(input, job: job, context: context, scratch: scratch)
        progress(0.3)
        let img = loaded.image
        let w0 = Double(img.width), h0 = Double(img.height)
        let reqW = job.int("width", default: 0), reqH = job.int("height", default: 0)
        let keep = job.bool("keepAspect", default: true)
        var w: Double, h: Double
        switch (reqW > 0, reqH > 0) {
        case (true, true):
            if keep { let s = min(Double(reqW) / w0, Double(reqH) / h0); (w, h) = (w0 * s, h0 * s) } else { (w, h) = (Double(reqW), Double(reqH)) }
        case (true, false): (w, h) = (Double(reqW), h0 * Double(reqW) / w0)
        case (false, true): (w, h) = (w0 * Double(reqH) / h0, Double(reqH))
        case (false, false):
            let s = max(0.01, job.double("percent", default: 50) / 100)
            (w, h) = (w0 * s, h0 * s)
        }
        let W = max(1, min(40_000, Int(w.rounded()))), H = max(1, min(40_000, Int(h.rounded())))
        let resized = ImageOps.resized(img, width: W, height: H)
        let format = editFormat(for: loaded, tools: context.tools)
        let out = scratch.appendingPathComponent("out.\(ImageFormats.ext(format))")
        try await ImageCodec.write(resized, format: format, to: out, quality: job.double("quality", default: 0.9),
                                   properties: loaded.carryProperties, tools: context.tools, scratch: scratch)
        progress(0.9)
        return try commit(out, for: input, ext: ImageFormats.ext(format), suffix: "resized", context: context)
    }

    private func metadataRead(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        let scratch = try scratchDir(context)
        let loaded = try await load(input, job: job, context: context, scratch: scratch)
        let data = try ImageTools.metadataJSON(loaded, input: input)
        let out = scratch.appendingPathComponent("metadata.json")
        try data.write(to: out)
        return try commit(out, for: input, ext: "json", suffix: "metadata", context: context)
    }

    private func metadataStrip(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        let scratch = try scratchDir(context)
        let loaded = try await load(input, job: job, context: context, scratch: scratch)
        guard loaded.sourceFormat != "svg" else { throw EngineError.unsupported("Stripping SVG metadata") }
        progress(0.3)
        let format = editFormat(for: loaded, tools: context.tools)
        let out = scratch.appendingPathComponent("out.\(ImageFormats.ext(format))")
        try await ImageTools.strip(loaded, format: format, quality: job.double("quality", default: 0.92), to: out,
                                   tools: context.tools, scratch: scratch)
        return try commit(out, for: input, ext: ImageFormats.ext(format), suffix: "stripped", context: context)
    }

    private func qrRead(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        let scratch = try scratchDir(context)
        let loaded = try await load(input, job: job, context: context, scratch: scratch)
        progress(0.3)
        let codes = ImageTools.readCodes(loaded.image)
        guard !codes.isEmpty else { throw EngineError.failed("No QR code or barcode found in \(input.lastPathComponent)") }
        let out = scratch.appendingPathComponent("codes.txt")
        try (codes.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        return try commit(out, for: input, ext: "txt", suffix: "QR", context: context)
    }

    private func toPDF(_ job: JobSpec, context: JobContext) async throws -> [URL] {
        let scratch = try scratchDir(context)
        var items: [LoadedImage] = []
        for (i, input) in job.inputs.enumerated() {
            try Task.checkCancellation()
            items.append(try await load(input, job: job, context: context, scratch: scratch))
            context.progress(0.5 * Double(i + 1) / Double(job.inputs.count))
        }
        let first = job.inputs[0]
        let out = scratch.appendingPathComponent("out.pdf")
        let size = ImageCompose.PageSize(rawValue: job.string("pageSize") ?? "fit") ?? .fit
        let report = context.progress
        try ImageCompose.writePDF(items, to: out, pageSize: size, margin: job.double("margin", default: 0),
                                  quality: job.double("quality", default: 0.9), title: OutputNamer.baseName(of: first)) { report(0.5 + 0.5 * $0) }
        return [try commit(out, for: first, ext: "pdf", suffix: job.inputs.count > 1 ? "images" : nil, context: context)]
    }

    private func collage(_ job: JobSpec, context: JobContext) async throws -> [URL] {
        guard job.inputs.count >= 2 else { throw EngineError.invalidInput("Collage needs at least 2 images") }
        let scratch = try scratchDir(context)
        var images: [CGImage] = []
        for (i, input) in job.inputs.enumerated() {
            try Task.checkCancellation()
            images.append(try await load(input, job: job, context: context, scratch: scratch).image)
            context.progress(0.6 * Double(i + 1) / Double(job.inputs.count))
        }
        var o = ImageCompose.CollageOptions()
        o.layout = ImageCompose.Layout(rawValue: job.string("layout") ?? "grid") ?? .grid
        o.columns = job.int("columns", default: 0)
        o.cellSize = job.int("cellSize", default: 600)
        o.spacing = job.int("spacing", default: 12)
        o.background = ColorParser.parse(job.string("background")) ?? o.background
        o.fill = job.bool("fill", default: false)
        var format = job.string("format") ?? "jpg"
        if !["jpg", "png", "heic", "tiff"].contains(format) || !ImageFormats.canWrite(format, tools: context.tools) { format = "jpg" }
        if o.background.alpha < 1 && format == "jpg" { format = "png" }
        let canvas = try ImageCompose.collage(images, options: o)
        context.progress(0.8)
        let out = scratch.appendingPathComponent("collage.\(ImageFormats.ext(format))")
        try await ImageCodec.write(canvas, format: format, to: out, quality: job.double("quality", default: 0.9),
                                   tools: context.tools, scratch: scratch)
        return [try commit(out, for: job.inputs[0], ext: ImageFormats.ext(format), suffix: "collage", context: context)]
    }

    private func crop(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        try await edit(input, suffix: "cropped", job: job, context: context, progress: progress) { img, _ in
            let rotated = ImageOps.rotated(img, degrees: job.int("rotation", default: 0),
                                           flipH: job.bool("flipH", default: false), flipV: job.bool("flipV", default: false))
            guard !job.list("rect").isEmpty else {
                if rotated.width == img.width && rotated.height == img.height && job.int("rotation", default: 0) % 360 == 0
                    && !job.bool("flipH", default: false) && !job.bool("flipV", default: false) {
                    throw EngineError.invalidInput("crop needs a `rect` (x,y,w,h)")
                }
                return rotated
            }
            guard let rect = job.topLeftRect("rect", within: rotated.size), let out = ImageOps.cropped(rotated, to: rect) else {
                throw EngineError.invalidInput("Crop rect is outside the image")
            }
            return out
        }
    }

    private func background(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        let mode = ImageEdits.BackgroundMode(rawValue: job.string("mode") ?? "fill") ?? .fill
        let color = ColorParser.parse(job.string("color")) ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let needsAlpha = mode == .remove || color.alpha < 1
        return try await edit(input, suffix: "background", job: job, context: context, progress: progress, needsAlpha: needsAlpha) { img, _ in
            try ImageEdits.background(img, mode: mode, color: color, padding: job.int("padding", default: 0))
        }
    }

    /// Load → transform → save in the input's format (PNG for SVG / alpha-needing results) with a suffix.
    private func edit(_ input: URL, suffix: String, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void,
                      needsAlpha: Bool = false, _ transform: (CGImage, LoadedImage) throws -> CGImage) async throws -> URL {
        let scratch = try scratchDir(context)
        let loaded = try await load(input, job: job, context: context, scratch: scratch)
        progress(0.3)
        try Task.checkCancellation()
        let result = try transform(loaded.image, loaded)
        progress(0.7)
        let format = editFormat(for: loaded, tools: context.tools, needsAlpha: needsAlpha)
        let out = scratch.appendingPathComponent("out.\(ImageFormats.ext(format))")
        try await ImageCodec.write(result, format: format, to: out, quality: job.double("quality", default: 0.92),
                                   properties: loaded.carryProperties, tools: context.tools, scratch: scratch)
        return try commit(out, for: input, ext: ImageFormats.ext(format), suffix: suffix, context: context)
    }
}
