import Foundation
import PDFKit
import RondoKit

/// PDF conversions (→ JPG/PNG/TXT/MD/DOCX/EPUB), TXT → PDF/JPG/PNG, and PDF page tools.
/// Everything here is built on PDFKit / Core Graphics / Core Text / Vision — no external tools.
public struct PDFDocumentEngine: Engine {
    public let id = "pdf"
    private let locator: ToolLocator

    public init(tools: ToolLocator = ToolLocator()) {
        self.locator = tools
    }

    // MARK: Capabilities

    public func conversions() -> [ConversionDescriptor] {
        RondoKit.conversions(from: ["pdf"], to: ["jpg", "png", "txt", "md", "docx", "epub"])
            + RondoKit.conversions(from: ["txt"], to: ["pdf", "jpg", "png"])
    }

    public func tools() -> [ToolDescriptor] { Self.descriptors }

    static let pdf: Set<FileKind> = [.pdf]

    static let descriptors: [ToolDescriptor] = [
        ToolDescriptor(id: "pdf.compress", title: "Compress", symbol: "arrow.down.doc", accepts: pdf, options: [
            OptionSpec(key: "quality", title: "Image quality", control: .slider(min: 0.05, max: 1, step: 0.05), defaultValue: .double(0.6)),
            OptionSpec(key: "dpi", title: "Image resolution (DPI)", control: .integer(min: 36, max: 600), defaultValue: .int(150)),
            OptionSpec(key: "percent", title: "Reduce size by (%)", control: .slider(min: 5, max: 95, step: 5), defaultValue: nil),
            OptionSpec(key: "targetBytes", title: "Target size", control: .bytes, defaultValue: nil),
            OptionSpec(key: "mode", title: "Mode", control: .choice(["images", "rasterize"]), defaultValue: .string("images")),
        ]),
        ToolDescriptor(id: "pdf.merge", title: "Merge", symbol: "doc.on.doc", accepts: pdf, multiInput: .combine(minimum: 2)),
        ToolDescriptor(id: "pdf.split", title: "Split", symbol: "scissors", accepts: pdf, options: [
            OptionSpec(key: "ranges", title: "Page ranges", control: .ranges, defaultValue: nil),
            OptionSpec(key: "every", title: "Pages per file", control: .integer(min: 1, max: 10_000), defaultValue: .int(1)),
        ]),
        ToolDescriptor(id: "pdf.reorder", title: "Reorganize Pages", symbol: "rectangle.grid.1x2", accepts: pdf, multiInput: .single, needsUI: true, options: [
            OptionSpec(key: "order", title: "Page order (1-based)", control: .text, defaultValue: nil),
            OptionSpec(key: "rotations", title: "Rotation per output page (°)", control: .text, defaultValue: nil),
            OptionSpec(key: "deletions", title: "Pages to delete (1-based)", control: .text, defaultValue: nil),
        ]),
        ToolDescriptor(id: "pdf.text.extract", title: "Extract Text", symbol: "doc.plaintext", accepts: pdf, options: [
            OptionSpec(key: "ocr", title: "OCR pages without text", control: .toggle, defaultValue: .bool(true)),
        ]),
        ToolDescriptor(id: "pdf.metadata.strip", title: "Remove Metadata", symbol: "tag.slash", accepts: pdf),
    ]

    // MARK: Run

    public func run(_ job: JobSpec, context: JobContext) async throws -> [URL] {
        guard !job.inputs.isEmpty else { throw EngineError.invalidInput("No input files") }
        switch job.operation {
        case .convert(let to):
            return try await eachInput(job, context) { input, p in
                let from = FormatCatalog.format(for: input)?.id
                switch (from, to) {
                case ("pdf", "jpg"), ("pdf", "png"): return try pdfToImages(input, format: to, job: job, context: context, progress: p)
                case ("pdf", "txt"): return try pdfToText(input, job: job, context: context, progress: p)
                case ("pdf", "md"): return try pdfToMarkdown(input, job: job, context: context, progress: p)
                case ("pdf", "docx"): return try pdfToDocx(input, job: job, context: context, progress: p)
                case ("pdf", "epub"): return try pdfToEpub(input, job: job, context: context, progress: p)
                case ("txt", "pdf"), ("txt", "jpg"), ("txt", "png"): return try textTo(input, format: to, job: job, context: context, progress: p)
                default: throw EngineError.unsupported("\(from ?? "?") → \(to)")
                }
            }
        case .tool(let tool):
            switch tool.rawValue {
            case "pdf.compress": return try await eachInput(job, context) { try compress($0, job: job, context: context, progress: $1) }
            case "pdf.merge": return try [merge(job, context: context)]
            case "pdf.split": return try await eachInput(job, context) { try split($0, job: job, context: context, progress: $1) }
            case "pdf.reorder": return try await eachInput(job, context) { try reorder($0, job: job, context: context, progress: $1) }
            case "pdf.text.extract": return try await eachInput(job, context) { try pdfToText($0, job: job, context: context, progress: $1) }
            case "pdf.metadata.strip": return try await eachInput(job, context) { try stripMetadata($0, job: job, context: context, progress: $1) }
            default: throw EngineError.unsupported(tool.rawValue)
            }
        }
    }

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

    private func commit(_ temp: URL, for input: URL, ext: String, suffix: String? = nil, context: JobContext) throws -> URL {
        try context.namer.commit(temp, to: context.outputURL(for: input, ext: ext, suffix: suffix))
    }

    /// One file → beside the original; several → `name (pages)/` folder.
    private func commitPages(_ files: [URL], folder: URL, for input: URL, ext: String, context: JobContext) throws -> URL {
        if files.count == 1 { return try commit(files[0], for: input, ext: ext, context: context) }
        return try context.namer.commit(folder, to: context.namer.folder(for: input, suffix: "pages", destination: context.destination))
    }

    /// Text-producing conversions refuse to commit content-free files.
    private func requireText(_ pages: [String], input: URL, ocr: Bool) throws {
        guard pages.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        throw noText(input, ocr: ocr)
    }

    private func noText(_ input: URL, ocr: Bool) -> EngineError {
        .invalidInput("No text found in \(input.lastPathComponent) " + (ocr ? "(OCR found nothing either)" : "(OCR is off)"))
    }

    private func title(of doc: PDFDocument, input: URL) -> String {
        if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
           !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        return OutputNamer.baseName(of: input)
    }

    // MARK: Conversions

    private func pdfToImages(_ input: URL, format: String, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) throws -> URL {
        let doc = try PDFSupport.open(input)
        let scratch = try PDFSupport.scratchDir(context)
        let folder = scratch.appendingPathComponent("pages", isDirectory: true)
        let dpi = Double(job.int("dpi", default: 300))
        let files = try PDFRender.renderPages(doc, format: format, dpi: dpi, quality: job.double("quality", default: 0.9),
                                              into: folder) { progress($0 * 0.95) }
        context.log("\(input.lastPathComponent): \(files.count) page(s) → \(format) @ \(Int(dpi)) DPI")
        return try commitPages(files, folder: folder, for: input, ext: format, context: context)
    }

    private func pdfToText(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) throws -> URL {
        let doc = try PDFSupport.open(input)
        let ocr = job.bool("ocr", default: true)
        let pages = try PDFExport.pageTexts(doc, ocr: ocr) { progress($0 * 0.9) }
        try requireText(pages, input: input, ocr: ocr)
        let out = try PDFSupport.scratchDir(context).appendingPathComponent("text.txt")
        try PDFExport.plainText(pages).write(to: out, atomically: true, encoding: .utf8)
        return try commit(out, for: input, ext: "txt", context: context)
    }

    private func pdfToMarkdown(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) throws -> URL {
        let doc = try PDFSupport.open(input)
        let ocr = job.bool("ocr", default: true)
        let pages = try PDFExport.pageTexts(doc, ocr: ocr) { progress($0 * 0.9) }
        try requireText(pages, input: input, ocr: ocr)
        let out = try PDFSupport.scratchDir(context).appendingPathComponent("text.md")
        try PDFExport.markdown(pages, title: title(of: doc, input: input)).write(to: out, atomically: true, encoding: .utf8)
        return try commit(out, for: input, ext: "md", context: context)
    }

    private func pdfToDocx(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) throws -> URL {
        let doc = try PDFSupport.open(input)
        let ocr = job.bool("ocr", default: true)
        guard let data = try PDFExport.docx(doc, ocr: ocr, progress: progress) else { throw noText(input, ocr: ocr) }
        let out = try PDFSupport.scratchDir(context).appendingPathComponent("doc.docx")
        try data.write(to: out)
        return try commit(out, for: input, ext: "docx", context: context)
    }

    private func pdfToEpub(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) throws -> URL {
        let doc = try PDFSupport.open(input)
        let ocr = job.bool("ocr", default: true)
        let pages = try PDFExport.pageTexts(doc, ocr: ocr) { progress($0 * 0.8) }
        try requireText(pages, input: input, ocr: ocr)
        let author = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        let lang = Locale.preferredLanguages.first.map { String($0.prefix(while: { $0 != "-" && $0 != "_" })) } ?? "en"
        let data = PDFExport.epub(pages: pages, title: title(of: doc, input: input), author: author, language: lang)
        let out = try PDFSupport.scratchDir(context).appendingPathComponent("book.epub")
        try data.write(to: out)
        return try commit(out, for: input, ext: "epub", context: context)
    }

    /// TXT → PDF / JPG / PNG via Core Text. Options: `fontSize` (pt, default 10), `font` ("mono" | "sans"),
    /// `pageSize` ("auto" | "a4" | "letter"), `dpi` for images (default 150), `quality` for JPG.
    private func textTo(_ input: URL, format: String, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) throws -> URL {
        let text = try PDFSupport.readText(input)
        var style = PDFRender.TextStyle()
        style.fontSize = CGFloat(min(max(job.double("fontSize", default: 10), 4), 96))
        style.monospaced = (job.string("font") ?? "mono") != "sans"
        style.pageSize = PDFSupport.pageSize(job.string("pageSize"))
        let base = OutputNamer.baseName(of: input)
        let pdfData = try PDFRender.typeset(text, style: style, title: base)
        progress(0.4)
        let scratch = try PDFSupport.scratchDir(context)
        if format == "pdf" {
            let out = scratch.appendingPathComponent("text.pdf")
            try pdfData.write(to: out)
            return try commit(out, for: input, ext: "pdf", context: context)
        }
        guard let doc = PDFDocument(data: pdfData) else { throw EngineError.failed("Typesetting failed") }
        let folder = scratch.appendingPathComponent("pages", isDirectory: true)
        let files = try PDFRender.renderPages(doc, format: format, dpi: Double(job.int("dpi", default: 150)),
                                              quality: job.double("quality", default: 0.9), into: folder) { progress(0.4 + $0 * 0.55) }
        return try commitPages(files, folder: folder, for: input, ext: format, context: context)
    }

    // MARK: Tools

    private func compress(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) throws -> URL {
        let scratch = try PDFSupport.scratchDir(context)
        let original = PDFSupport.fileSize(input)
        var target: Int? = job.int("targetBytes", default: 0) > 0 ? job.int("targetBytes", default: 0) : nil
        if target == nil, case let p = job.double("percent", default: 0), p > 0 {
            target = max(1, Int(Double(original) * (1 - min(p, 99) / 100)))
        }
        let mode = PDFTools.CompressMode(rawValue: job.string("mode") ?? "images") ?? .images
        var result = try PDFTools.compress(input, mode: mode, quality: job.double("quality", default: 0.6),
                                           dpi: Double(job.int("dpi", default: 150)), targetBytes: target,
                                           scratch: scratch, progress: { progress($0 * 0.95) })
        if result.size >= original {
            let copy = scratch.appendingPathComponent("orig.pdf")
            try FileManager.default.copyItem(at: input, to: copy)
            result = .init(url: copy, size: original)
            context.log("\(input.lastPathComponent): already as small as requested; kept original bytes")
        }
        context.log("\(input.lastPathComponent): \(original) → \(result.size) bytes")
        return try commit(result.url, for: input, ext: "pdf", suffix: "compressed", context: context)
    }

    private func merge(_ job: JobSpec, context: JobContext) throws -> URL {
        guard job.inputs.count >= 2 else { throw EngineError.invalidInput("Merge needs at least 2 PDFs") }
        let out = try PDFSupport.scratchDir(context).appendingPathComponent("merged.pdf")
        try PDFTools.merge(job.inputs, to: out, progress: context.progress)
        return try commit(out, for: job.inputs[0], ext: "pdf", suffix: "merged", context: context)
    }

    /// `ranges` (1-based inclusive) → one file per range; else chunks of `every` pages (default 1).
    private func split(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) throws -> URL {
        let doc = try PDFSupport.open(input)
        let n = doc.pageCount
        let parts = PDFTools.splitRanges(job.ranges("ranges"), every: job.int("every", default: 1), pageCount: n)
        guard !parts.isEmpty else { throw EngineError.invalidInput("No valid page ranges (document has \(n) pages)") }
        let scratch = try PDFSupport.scratchDir(context)
        let folder = scratch.appendingPathComponent("split", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        for (i, r) in parts.enumerated() {
            try Task.checkCancellation()
            let url = folder.appendingPathComponent("\(PDFTools.rangeName(r, of: n)).pdf")
            try PDFTools.extract(doc, pages: r, to: url)
            files.append(url)
            progress(Double(i + 1) / Double(parts.count) * 0.95)
        }
        if files.count == 1 {
            let r = parts[0]
            let suffix = r.count == 1 ? "page \(r.lowerBound)" : "pages \(r.lowerBound)-\(r.upperBound)"
            return try commit(files[0], for: input, ext: "pdf", suffix: suffix, context: context)
        }
        return try context.namer.commit(folder, to: context.namer.folder(for: input, suffix: "pages", destination: context.destination))
    }

    private func reorder(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) throws -> URL {
        let doc = try PDFSupport.open(input)
        let n = doc.pageCount
        let order = job.pageList("order", pageCount: n)
        if !job.list("order").isEmpty && order.isEmpty { throw EngineError.invalidInput("`order` has no valid pages (1…\(n))") }
        let rotations = job.list("rotations").map { Int($0.rounded()) }
        let deletions = Set(job.pageList("deletions", pageCount: n))
        let out = try PDFSupport.scratchDir(context).appendingPathComponent("reordered.pdf")
        try PDFTools.reorder(doc, order: order, rotations: rotations, deletions: deletions, to: out)
        progress(0.9)
        return try commit(out, for: input, ext: "pdf", suffix: "reordered", context: context)
    }

    private func stripMetadata(_ input: URL, job: JobSpec, context: JobContext, progress: @escaping (Double) -> Void) throws -> URL {
        let out = try PDFSupport.scratchDir(context).appendingPathComponent("stripped.pdf")
        try PDFTools.stripMetadata(input, to: out)
        progress(0.9)
        return try commit(out, for: input, ext: "pdf", suffix: "stripped", context: context)
    }
}
