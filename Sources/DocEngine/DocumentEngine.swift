import AppKit
import RondoKit

/// Documents, subtitles, archives, spreadsheets and slides.
/// Pure Swift / AppKit text system / Core Text, plus system tools (`textutil`, `ditto`, `tar`, `gzip`, `unzip`)
/// and optional exporters (`soffice`, Keynote) for slides.
public struct DocumentEngine: Engine {
    public let id = "docs"
    private let locator: ToolLocator

    public init(tools: ToolLocator = ToolLocator()) {
        self.locator = tools
    }

    // MARK: Capabilities

    static let documentInputs = ["docx", "doc", "rtf", "rtfd", "txt", "md", "html", "odt", "textclipping"]
    static let documentOutputs = ["docx", "txt", "md", "html", "rtf", "pdf", "epub"]
    static let subtitleFormats = ["srt", "vtt"]
    static let spreadsheetFormats = ["csv", "tsv", "xlsx"]
    static let slideOutputs = ["pdf", "jpg", "png"]
    /// Packages (directories) can be zipped/tarred but not gzipped.
    static let packageFormats: Set<String> = ["rtfd", "pages", "key", "numbers"]

    public func conversions() -> [ConversionDescriptor] {
        var out: [ConversionDescriptor] = []

        // Documents. txt → pdf/jpg/png belongs to the PDF engine.
        let textutil = locator.has("textutil")
        for from in Self.documentInputs where from != "html" || textutil {
            for to in Self.documentOutputs where to != from && !(from == "txt" && to == "pdf") {
                out.append(ConversionDescriptor(from: from, to: to))
            }
        }

        // Subtitles
        out += RondoKit.conversions(from: Self.subtitleFormats, to: Self.subtitleFormats + ["txt"])

        // Spreadsheets (XLSX reading needs unzip)
        let sheetInputs = locator.has("unzip") ? Self.spreadsheetFormats : ["csv", "tsv"]
        out += RondoKit.conversions(from: sheetInputs, to: Self.spreadsheetFormats + ["pdf"])

        // Archives: create
        let hasDitto = locator.has("ditto"), hasTar = locator.has("tar"), hasGzip = locator.has("gzip")
        var folderTargets: [String] = []
        if hasDitto { folderTargets.append("zip") }
        if hasTar { folderTargets += ["tar", "tar.gz"] }
        out += RondoKit.conversions(from: ["folder"], to: folderTargets)
        // pdf → zip/tar.gz/gz included: the PDF engine never advertises archive targets (P3 decision).
        for f in FormatCatalog.all where ![.archive, .folder, .unknown].contains(f.kind) {
            if hasDitto { out.append(ConversionDescriptor(from: f.id, to: "zip")) }
            if hasTar { out.append(ConversionDescriptor(from: f.id, to: "tar.gz")) }
            if hasGzip && !Self.packageFormats.contains(f.id) { out.append(ConversionDescriptor(from: f.id, to: "gz")) }
        }

        // Archives: extract
        var extractable: [String] = []
        if hasDitto && locator.has("unzip") { extractable.append("zip") }
        if hasTar { extractable += ["tar", "tar.gz"] }
        if hasGzip { extractable.append("gz") }
        if let tar = locator.url(for: "tar"), Probe.tarAdvertisesRAR(tar) { extractable.append("rar") }
        out += extractable.map { ConversionDescriptor(from: $0, to: "folder") }

        // Slides
        out += RondoKit.conversions(from: Slides.inputs(locator), to: Self.slideOutputs)

        var seen = Set<ConversionDescriptor>()
        return out.filter { seen.insert($0).inserted }
    }

    public func tools() -> [ToolDescriptor] { [] }

    // MARK: Run

    public func run(_ job: JobSpec, context: JobContext) async throws -> [URL] {
        guard !job.inputs.isEmpty else { throw EngineError.invalidInput("No input files") }
        guard case .convert(let to) = job.operation else {
            if case .tool(let t) = job.operation { throw EngineError.unsupported(t.rawValue) }
            throw EngineError.unsupported("operation")
        }
        var outputs: [URL] = []
        let n = Double(job.inputs.count)
        for (i, input) in job.inputs.enumerated() {
            try Task.checkCancellation()
            let base = Double(i) / n
            let report = context.progress
            let p: (Double) -> Void = { report(base + min(max($0, 0), 1) / n) }
            outputs.append(try await convert(input, to: to, job: job, context: context, progress: p))
        }
        return outputs
    }

    private func convert(_ input: URL, to: String, job: JobSpec, context: JobContext,
                         progress: @escaping (Double) -> Void) async throws -> URL {
        guard let from = FormatCatalog.format(for: input)?.id else {
            throw EngineError.unsupported("Unknown file type: \(input.lastPathComponent)")
        }
        context.log("\(input.lastPathComponent): \(from) → \(to)")

        if Archives.createTargets.contains(to) {
            return try await Archives.create(input, to: to, context: context, progress: progress)
        }
        if to == "folder", Archives.extractSources.contains(from) {
            return try await Archives.extract(input, from: from, context: context, progress: progress)
        }
        if Self.subtitleFormats.contains(from), Self.subtitleFormats.contains(to) || to == "txt" {
            return try convertSubtitles(input, from: from, to: to, context: context)
        }
        if Self.spreadsheetFormats.contains(from), Self.spreadsheetFormats.contains(to) || to == "pdf" {
            return try await convertSpreadsheet(input, from: from, to: to, job: job, context: context, progress: progress)
        }
        if ["ppt", "pptx", "key"].contains(from), Self.slideOutputs.contains(to) {
            return try await Slides.convert(input, from: from, to: to, job: job, context: context, progress: progress)
        }
        if Self.documentInputs.contains(from), Self.documentOutputs.contains(to), from != to {
            return try await convertDocument(input, from: from, to: to, job: job, context: context, progress: progress)
        }
        throw EngineError.unsupported("\(from) → \(to)")
    }

    // MARK: Documents

    private func convertDocument(_ input: URL, from: String, to: String, job: JobSpec, context: JobContext,
                                 progress: @escaping (Double) -> Void) async throws -> URL {
        if from == "txt" && to == "pdf" { throw EngineError.unsupported("txt → pdf is handled by the PDF engine") }
        progress(0.05)
        let doc = try await RichTextIO.load(input, format: from, context: context)
        try Task.checkCancellation()
        progress(0.4)
        let title = doc.title ?? OutputNamer.baseName(of: input)
        let out = try DocSupport.scratchDir(context).appendingPathComponent("document.\(to)")

        switch to {
        case "docx":
            try RichTextIO.docx(doc).write(to: out)
        case "rtf":
            try RichTextIO.rtf(doc).write(to: out)
        case "html":
            if from == "md" {
                // Markdown → semantic HTML (real <h1>/<ul>/<code>), not Cocoa's styled spans.
                let body = XHTMLWriter.body(BlockExtractor.blocks(from: doc.text))
                try htmlDocument(title: title, body: body).write(to: out, atomically: true, encoding: .utf8)
            } else {
                try RichTextIO.html(doc, fallbackTitle: title).write(to: out)
            }
        case "txt":
            try PlainTextWriter.render(doc.text).write(to: out, atomically: true, encoding: .utf8)
        case "md":
            try MarkdownWriter.render(BlockExtractor.blocks(from: doc.text)).write(to: out, atomically: true, encoding: .utf8)
        case "pdf":
            try PDFWriter.write(doc.text, to: out, pageSize: DocSupport.pageSize(job.string("pageSize")),
                                info: .init(title: title, author: doc.author)) { progress(0.4 + $0 * 0.55) }
        case "epub":
            let blocks = BlockExtractor.blocks(from: doc.text)
            var book = EPUBBuilder(title: title, author: doc.author, language: DocSupport.languageCode())
            book.chapters = EPUBBuilder.chapters(from: blocks, defaultTitle: title)
            try book.build().write(to: out)
        default:
            throw EngineError.unsupported("\(from) → \(to)")
        }
        progress(0.97)
        return try DocSupport.commit(out, for: input, ext: to, context: context)
    }

    private func htmlDocument(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="\(DocSupport.languageCode())">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(XML.escape(title))</title>
        <style>
        body { font-family: -apple-system, Helvetica, sans-serif; line-height: 1.5; max-width: 46em; margin: 2em auto; padding: 0 1em; }
        pre { background: #f4f4f4; padding: 0.75em; overflow-x: auto; }
        blockquote { margin-left: 1em; padding-left: 1em; border-left: 3px solid #ccc; color: #555; }
        table { border-collapse: collapse; } th, td { border: 1px solid #bbb; padding: 0.25em 0.6em; }
        </style>
        </head>
        <body>
        \(body)</body>
        </html>

        """
    }

    // MARK: Subtitles

    private func convertSubtitles(_ input: URL, from: String, to: String, context: JobContext) throws -> URL {
        let cues = Subtitles.parse(try DocSupport.readText(input))
        guard !cues.isEmpty else { throw EngineError.invalidInput("No subtitle cues found in \(input.lastPathComponent)") }
        let text: String = switch to {
        case "srt": Subtitles.srt(cues)
        case "vtt": Subtitles.vtt(cues)
        default: Subtitles.plainText(cues)
        }
        let out = try DocSupport.scratchDir(context).appendingPathComponent("subtitles.\(to)")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return try DocSupport.commit(out, for: input, ext: to, context: context)
    }

    // MARK: Spreadsheets

    private func convertSpreadsheet(_ input: URL, from: String, to: String, job: JobSpec, context: JobContext,
                                    progress: @escaping (Double) -> Void) async throws -> URL {
        let rows: [[String]]
        switch from {
        case "csv": rows = Delimited.parse(try DocSupport.readText(input), delimiter: ",")
        case "tsv": rows = Delimited.parse(try DocSupport.readText(input), delimiter: "\t")
        default: rows = try await XLSX.read(input, context: context)
        }
        try Task.checkCancellation()
        progress(0.4)
        let out = try DocSupport.scratchDir(context).appendingPathComponent("table.\(to)")
        switch to {
        case "csv": try Delimited.write(rows, delimiter: ",").write(to: out, atomically: true, encoding: .utf8)
        case "tsv": try Delimited.write(rows, delimiter: "\t").write(to: out, atomically: true, encoding: .utf8)
        case "xlsx": try XLSX.write(Delimited.rectangular(rows), sheetName: OutputNamer.baseName(of: input)).write(to: out)
        case "pdf":
            try PDFWriter.table(Delimited.rectangular(rows), header: job.bool("header", default: true), to: out,
                                pageSize: DocSupport.pageSize(job.string("pageSize")),
                                info: .init(title: OutputNamer.baseName(of: input), author: nil)) { progress(0.4 + $0 * 0.55) }
        default: throw EngineError.unsupported("\(from) → \(to)")
        }
        return try DocSupport.commit(out, for: input, ext: to, context: context)
    }
}
