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

    /// Every tool hides itself for formats this Mac can't decode (e.g. SVG without magick).
    public func tools() -> [ToolDescriptor] {
        let unreadable = Set(ImageFormats.inputs.filter { !ImageFormats.canRead($0, tools: locator) })
        return Self.descriptors(unreadable: unreadable)
    }

    static let image: Set<FileKind> = [.image]

    /// Formats each tool's `run` refuses outright (beyond what this Mac can't decode).
    static let toolRejects: [String: Set<String>] = [
        "image.compress": ["svg"],          // vector source: nothing meaningful to recompress
        "image.metadata.strip": ["svg"],    // would rasterize the SVG
    ]

    static func descriptors(unreadable: Set<String>) -> [ToolDescriptor] {
        baseDescriptors.map { d in
            ToolDescriptor(id: d.id, title: d.title, symbol: d.symbol, accepts: d.accepts, multiInput: d.multiInput,
                           needsUI: d.needsUI, options: d.options,
                           rejectsFormats: d.rejectsFormats.union(unreadable).union(toolRejects[d.id.rawValue] ?? []))
        }
    }

    static let baseDescriptors: [ToolDescriptor] = [
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
        try await ImageCodec.load(input, tools: context.tools, scratch: scratch, svgDPI: job.clamped("dpi", default: 96, 18...1200))
    }

    private func probe(_ input: URL, job: JobSpec, context: JobContext, scratch: URL) async throws -> ImageSource {
        try await ImageCodec.probe(input, tools: context.tools, scratch: scratch, svgDPI: job.clamped("dpi", default: 96, 18...1200))
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
        let out = scratch.appendingPathComponent("out.\(ImageFormats.ext(target))")
        if target == "pdf" {
            let source = try await probe(input, job: job, context: context, scratch: scratch)
            progress(0.3)
            try ImageCompose.writePDF([source], to: out, pageSize: .fit, margin: 0, quality: job.unit("quality", default: 0.9),
                                      title: OutputNamer.baseName(of: input)) { _ in }
        } else {
            let loaded = try await load(input, job: job, context: context, scratch: scratch)
            progress(0.4)
            try await ImageCodec.write(loaded.image, format: target, to: out, quality: job.unit("quality", default: 0.85),
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
        // Explicit byte target is strict (fail if unreachable); percent is best-effort.
        let explicit = job.finite("targetBytes").map { Int(min(max($0, 0), 1e15)) }.flatMap { $0 > 0 ? $0 : nil }
        var target = explicit
        if target == nil, let p = job.finite("percent"), p > 0 {
            target = max(1, Int(Double(original) * (1 - min(p, 99) / 100)))
        }
        let outcome = try await ImageTools.compress(loaded, format: format, quality: job.unit("quality", default: 0.7),
                                                    targetBytes: target, tools: context.tools, scratch: scratch, progress: progress)
        var result = outcome.result
        // Never hand back something bigger than the original in the same format.
        if result.size >= original, format == loaded.sourceFormat {
            let copy = scratch.appendingPathComponent("orig.\(ImageFormats.ext(format))")
            try FileManager.default.copyItem(at: input, to: copy)
            result = .init(url: copy, size: original)
            context.log("\(input.lastPathComponent): already as small as requested; kept original bytes")
        }
        if let explicit, result.size > explicit {
            let best = min(outcome.smallest, format == loaded.sourceFormat ? original : .max)
            throw EngineError.failed("Couldn't get \(input.lastPathComponent) under \(byteString(explicit)); smallest achievable ≈ \(byteString(best))")
        }
        context.log("\(input.lastPathComponent): \(original) → \(result.size) bytes")
        return try commit(result.url, for: input, ext: ImageFormats.ext(format), suffix: "compressed", context: context)
    }

    /// `width`/`height` (px) win over `percent` (scale %). Output is capped at `ImageOps.maxResizeArea`;
    /// the target is validated from the probed size before anything is decoded.
    private func resize(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        let scratch = try scratchDir(context)
        let source = try await probe(input, job: job, context: context, scratch: scratch)
        let w0 = Double(source.pixelSize.width), h0 = Double(source.pixelSize.height)
        func dimension(_ key: String) throws -> Double? {
            guard job.options[key] != nil else { return nil }
            guard let v = job.finite(key) else { throw EngineError.invalidInput("`\(key)` must be a finite number") }
            return v > 0 ? v : nil
        }
        let reqW = try dimension("width"), reqH = try dimension("height")
        let keep = job.bool("keepAspect", default: true)
        var w: Double, h: Double
        switch (reqW, reqH) {
        case let (rw?, rh?):
            if keep { let s = min(rw / w0, rh / h0); (w, h) = (w0 * s, h0 * s) } else { (w, h) = (rw, rh) }
        case let (rw?, nil): (w, h) = (rw, h0 * rw / w0)
        case let (nil, rh?): (w, h) = (w0 * rh / h0, rh)
        case (nil, nil):
            let pct = job.double("percent", default: 50)
            guard pct.isFinite, pct > 0 else { throw EngineError.invalidInput("`percent` must be a positive number") }
            (w, h) = (w0 * pct / 100, h0 * pct / 100)
        }
        w = max(1, w.rounded()); h = max(1, h.rounded())
        guard w.isFinite, h.isFinite, w * h <= Double(ImageOps.maxResizeArea), w <= Double(ImageOps.maxSide), h <= Double(ImageOps.maxSide) else {
            throw EngineError.invalidInput(String(format: "Resizing to %.0f×%.0f px exceeds the %d MP limit", min(w, 9e15), min(h, 9e15),
                                                  ImageOps.maxResizeArea / 1_000_000))
        }
        let W = Int(w), H = Int(h)
        // Downscales decode straight to (about) the target size; upscales decode at full size.
        let loaded = try ImageCodec.decode(source, maxPixel: max(W, H))
        progress(0.4)
        let resized = try ImageOps.resized(loaded.image, width: W, height: H)
        let format = editFormat(for: loaded, tools: context.tools)
        let out = scratch.appendingPathComponent("out.\(ImageFormats.ext(format))")
        try await ImageCodec.write(resized, format: format, to: out, quality: job.unit("quality", default: 0.9),
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
        try await ImageTools.strip(loaded, format: format, quality: job.unit("quality", default: 0.92), to: out,
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

    /// Probes every input up front (sizes only), then decodes one page at a time while writing.
    private func toPDF(_ job: JobSpec, context: JobContext) async throws -> [URL] {
        let scratch = try scratchDir(context)
        var sources: [ImageSource] = []
        for (i, input) in job.inputs.enumerated() {
            try Task.checkCancellation()
            sources.append(try await probe(input, job: job, context: context, scratch: scratch))
            context.progress(0.2 * Double(i + 1) / Double(job.inputs.count))
        }
        let first = job.inputs[0]
        let out = scratch.appendingPathComponent("out.pdf")
        let size = ImageCompose.PageSize(rawValue: job.string("pageSize") ?? "fit") ?? .fit
        let report = context.progress
        try ImageCompose.writePDF(sources, to: out, pageSize: size, margin: job.clamped("margin", default: 0, 0...720),
                                  quality: job.unit("quality", default: 0.9), title: OutputNamer.baseName(of: first)) { report(0.2 + 0.8 * $0) }
        return [try commit(out, for: first, ext: "pdf", suffix: job.inputs.count > 1 ? "images" : nil, context: context)]
    }

    /// Lays out from probed sizes, then decodes each image at its cell's pixel size while drawing.
    private func collage(_ job: JobSpec, context: JobContext) async throws -> [URL] {
        guard job.inputs.count >= 2 else { throw EngineError.invalidInput("Collage needs at least 2 images") }
        let scratch = try scratchDir(context)
        var sources: [ImageSource] = []
        for (i, input) in job.inputs.enumerated() {
            try Task.checkCancellation()
            sources.append(try await probe(input, job: job, context: context, scratch: scratch))
            context.progress(0.2 * Double(i + 1) / Double(job.inputs.count))
        }
        var o = ImageCompose.CollageOptions()
        o.layout = ImageCompose.Layout(rawValue: job.string("layout") ?? "grid") ?? .grid
        o.columns = job.clampedInt("columns", default: 0, 0...1000)
        o.cellSize = job.clampedInt("cellSize", default: 600, 16...8000)
        o.spacing = job.clampedInt("spacing", default: 12, 0...1000)
        o.background = ColorParser.parse(job.string("background")) ?? o.background
        o.fill = job.bool("fill", default: false)
        var format = job.string("format") ?? "jpg"
        if !["jpg", "png", "heic", "tiff"].contains(format) || !ImageFormats.canWrite(format, tools: context.tools) { format = "jpg" }
        if o.background.alpha < 1 && format == "jpg" { format = "png" }
        let report = context.progress
        let n = Double(sources.count)
        let canvas = try ImageCompose.collage(sizes: sources.map(\.pixelSize), options: o) { i, maxPixel in
            defer { report(0.2 + 0.6 * Double(i + 1) / n) }
            return try ImageCodec.decode(sources[i], maxPixel: maxPixel).image
        }
        let out = scratch.appendingPathComponent("collage.\(ImageFormats.ext(format))")
        try await ImageCodec.write(canvas, format: format, to: out, quality: job.unit("quality", default: 0.9),
                                   tools: context.tools, scratch: scratch)
        return [try commit(out, for: job.inputs[0], ext: ImageFormats.ext(format), suffix: "collage", context: context)]
    }

    private func crop(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        let degrees = job.clampedInt("rotation", default: 0, -3600...3600)
        let flipH = job.bool("flipH", default: false), flipV = job.bool("flipV", default: false)
        return try await edit(input, suffix: "cropped", job: job, context: context, progress: progress) { img, _ in
            let rotated = try ImageOps.rotated(img, degrees: degrees, flipH: flipH, flipV: flipV)
            guard !job.list("rect").isEmpty else {
                if degrees % 360 == 0 && !flipH && !flipV { throw EngineError.invalidInput("crop needs a `rect` (x,y,w,h)") }
                return rotated
            }
            guard let rect = job.topLeftRect("rect", within: rotated.size) else {
                throw EngineError.invalidInput("Crop rect is outside the image")
            }
            return try ImageOps.cropped(rotated, to: rect)
        }
    }

    private func background(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) async throws -> URL {
        let mode = ImageEdits.BackgroundMode(rawValue: job.string("mode") ?? "fill") ?? .fill
        let color = ColorParser.parse(job.string("color")) ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let needsAlpha = mode == .remove || color.alpha < 1
        return try await edit(input, suffix: "background", job: job, context: context, progress: progress, needsAlpha: needsAlpha) { img, _ in
            try ImageEdits.background(img, mode: mode, color: color, padding: job.clampedInt("padding", default: 0, 0...10_000))
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
        try await ImageCodec.write(result, format: format, to: out, quality: job.unit("quality", default: 0.92),
                                   properties: loaded.carryProperties, tools: context.tools, scratch: scratch)
        return try commit(out, for: input, ext: ImageFormats.ext(format), suffix: suffix, context: context)
    }
}
