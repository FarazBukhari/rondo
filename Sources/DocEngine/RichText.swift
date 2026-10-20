import AppKit
import RondoKit

/// A loaded document: styled text plus metadata.
struct LoadedDocument {
    var text: NSAttributedString
    var title: String?
    var author: String?
}

/// Fonts used for documents we style ourselves (Markdown, plain text).
enum DocFonts {
    static let bodySize: CGFloat = 12
    static let headingSizes: [CGFloat] = [24, 20, 16, 14, 13, 12]

    static func body(size: CGFloat = bodySize) -> NSFont {
        NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    static func mono(size: CGFloat = 11) -> NSFont {
        NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Thread-safe trait conversion (NSFontManager is main-thread only).
    static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard traits != font.fontDescriptor.symbolicTraits else { return font }
        let d = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }
}

enum RichTextIO {
    // MARK: Load

    static func load(_ url: URL, format: String, context: JobContext) async throws -> LoadedDocument {
        switch format {
        case "txt":
            return LoadedDocument(text: plainText(try DocSupport.readText(url)), title: nil, author: nil)
        case "md":
            let md = try DocSupport.readText(url)
            return LoadedDocument(text: MarkdownImport.attributed(md), title: MarkdownImport.title(md), author: nil)
        case "textclipping":
            return LoadedDocument(text: try textClipping(url), title: nil, author: nil)
        case "html":
            // HTML import in-process needs WebKit on the main thread; textutil does it out of process.
            let rtf = try await textutil(url, to: "rtf", extra: ["-noload"], context: context)
            var doc = try native(rtf, type: .rtf)
            if doc.title == nil { doc.title = htmlTitle(url) }
            return doc
        case "rtf", "rtfd", "doc", "docx", "odt":
            let type: NSAttributedString.DocumentType = switch format {
            case "rtf": .rtf
            case "rtfd": .rtfd
            case "doc": .docFormat
            case "docx": .officeOpenXML
            default: .openDocument
            }
            try DocSupport.requireInput(url, allowPackage: format == "rtfd")
            do {
                return try native(url, type: type)
            } catch {
                docLog.info("native \(format, privacy: .public) read failed, trying textutil: \(error.localizedDescription, privacy: .public)")
                let rtf = try await textutil(url, to: "rtf", extra: [], context: context)
                return try native(rtf, type: .rtf)
            }
        default:
            throw EngineError.unsupported("\(format) input")
        }
    }

    static func native(_ url: URL, type: NSAttributedString.DocumentType) throws -> LoadedDocument {
        var attrs: NSDictionary?
        let text: NSAttributedString
        do {
            text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: &attrs)
        } catch {
            throw EngineError.invalidInput("\(url.lastPathComponent) couldn't be read: \(error.localizedDescription)")
        }
        let meta = attrs as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        let title = (meta[.title] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let author = (meta[.author] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return LoadedDocument(text: text, title: title, author: author)
    }

    /// `textutil -convert <fmt>` into the job's scratch space; returns the output file.
    static func textutil(_ input: URL, to format: String, extra: [String], context: JobContext) async throws -> URL {
        let tool = try context.tools.require("textutil")
        let out = try DocSupport.scratchDir(context).appendingPathComponent("converted.\(format)")
        do {
            try await ProcessRunner.run(tool, extra + ["-convert", format, "-output", out.path, input.path])
        } catch let e as ProcessError {
            throw EngineError.failed("textutil couldn't convert \(input.lastPathComponent): \(e.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard DocSupport.exists(out) else { throw EngineError.failed("textutil produced no output for \(input.lastPathComponent)") }
        return out
    }

    /// Plain text → attributed string. Blank lines separate paragraphs; single newlines become line breaks.
    static func plainText(_ s: String) -> NSAttributedString {
        let paragraphs = s.components(separatedBy: "\n")
        var parts: [String] = []
        var current: [String] = []
        for line in paragraphs {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { parts.append(current.joined(separator: "\u{2028}")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\u{2028}")) }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        return NSAttributedString(string: parts.joined(separator: "\n"),
                                  attributes: [.font: DocFonts.body(), .paragraphStyle: style])
    }

    /// Finder text clippings: a property list whose `UTI-Data` holds RTF and/or plain text.
    static func textClipping(_ url: URL) throws -> NSAttributedString {
        try DocSupport.requireInput(url)
        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let uti = plist["UTI-Data"] as? [String: Any] else {
            throw EngineError.invalidInput("\(url.lastPathComponent) isn't a readable text clipping")
        }
        if let rtf = uti["public.rtf"] as? Data, let a = NSAttributedString(rtf: rtf, documentAttributes: nil), a.length > 0 {
            return a
        }
        for key in ["public.utf8-plain-text", "public.plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text"] {
            if let s = uti[key] as? String, !s.isEmpty { return plainText(DocSupport.normalizeNewlines(s)) }
            if let d = uti[key] as? Data, !d.isEmpty {
                let s = key.contains("utf16") ? (String(data: d, encoding: .utf16) ?? "") : DocSupport.decodeText(d)
                if !s.isEmpty { return plainText(DocSupport.normalizeNewlines(s)) }
            }
        }
        throw EngineError.invalidInput("\(url.lastPathComponent) has no text")
    }

    static func htmlTitle(_ url: URL) -> String? {
        guard let s = try? DocSupport.readText(url),
              let r = s.range(of: #"<title[^>]*>([^<]*)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let inner = s[r].replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    // MARK: Write

    static func full(_ a: NSAttributedString) -> NSRange { NSRange(location: 0, length: a.length) }

    static func docx(_ doc: LoadedDocument) throws -> Data {
        let text = ListMarkers.inlined(doc.text)
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        if let t = doc.title { attrs[.title] = t }
        if let a = doc.author { attrs[.author] = a }
        do { return try text.data(from: full(text), documentAttributes: attrs) } catch {
            throw EngineError.failed("Writing DOCX failed: \(error.localizedDescription)")
        }
    }

    static func rtf(_ doc: LoadedDocument) throws -> Data {
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
        if let t = doc.title { attrs[.title] = t }
        if let a = doc.author { attrs[.author] = a }
        do { return try doc.text.data(from: full(doc.text), documentAttributes: attrs) } catch {
            throw EngineError.failed("Writing RTF failed: \(error.localizedDescription)")
        }
    }

    static func html(_ doc: LoadedDocument, fallbackTitle: String) throws -> Data {
        let attrs: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
            .title: doc.title ?? fallbackTitle,
        ]
        do { return try doc.text.data(from: full(doc.text), documentAttributes: attrs) } catch {
            throw EngineError.failed("Writing HTML failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Markdown import

/// Markdown → styled NSAttributedString via Foundation's `AttributedString(markdown:)` presentation intents.
enum MarkdownImport {
    static func title(_ md: String) -> String? {
        for line in md.split(separator: "\n").prefix(40) where line.hasPrefix("# ") {
            let t = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return nil
    }

    static func attributed(_ md: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: md, options: options) else {
            return RichTextIO.plainText(md)
        }
        let out = NSMutableAttributedString()
        var currentBlock: Int?
        var currentCell: Int?
        var lastParagraphAttrs: [NSAttributedString.Key: Any] = [:]
        var listObjects: [Int: NSTextList] = [:]   // list identity → NSTextList (shared by its items)

        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            let blockID = blockIdentity(components)
            let isCode = components.contains { if case .codeBlock = $0.kind { return true }; return false }

            if blockID != currentBlock {
                if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: lastParagraphAttrs)) }
                currentBlock = blockID
                currentCell = nil
            }
            if let cell = components.first(where: { if case .tableCell = $0.kind { return true }; return false }) {
                if let c = currentCell, c != cell.identity { out.append(NSAttributedString(string: "\t", attributes: lastParagraphAttrs)) }
                currentCell = cell.identity
            }
            if isCode, text.hasSuffix("\n") { text.removeLast() }
            if components.contains(where: { if case .thematicBreak = $0.kind { return true }; return false }) { text = "* * *" }

            let attrs = attributes(components: components, inline: run.inlinePresentationIntent, link: run.link,
                                   lists: &listObjects)
            lastParagraphAttrs = attrs
            lastParagraphAttrs[.link] = nil
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    /// Identity of the paragraph-level block a run belongs to (table rows group their cells).
    private static func blockIdentity(_ components: [PresentationIntent.IntentType]) -> Int? {
        if let row = components.first(where: {
            switch $0.kind { case .tableRow, .tableHeaderRow: return true; default: return false }
        }) { return row.identity }
        return components.first?.identity
    }

    private static func attributes(components: [PresentationIntent.IntentType], inline: InlinePresentationIntent?,
                                   link: URL?, lists: inout [Int: NSTextList]) -> [NSAttributedString.Key: Any] {
        var font = DocFonts.body()
        var bold = false, italic = false
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        var hint: BlockHint?
        var color: NSColor?

        var listChain: [NSTextList] = []
        for c in components.reversed() {   // outermost first
            switch c.kind {
            case .header(let level):
                font = DocFonts.body(size: DocFonts.headingSizes[max(0, min(level, 6) - 1)])
                bold = true
                style.headerLevel = level
                style.paragraphSpacingBefore = 6
            case .codeBlock:
                font = DocFonts.mono()
                style.paragraphSpacing = 0
            case .blockQuote:
                hint = .quote
                italic = true
                style.headIndent += 24; style.firstLineHeadIndent += 24
                color = NSColor(srgbRed: 0.35, green: 0.35, blue: 0.35, alpha: 1)
            case .orderedList, .unorderedList:
                let ordered: Bool
                if case .orderedList = c.kind { ordered = true } else { ordered = false }
                let list = lists[c.identity] ?? NSTextList(markerFormat: ordered ? NSTextList.MarkerFormat("{decimal}.") : (listChain.isEmpty ? .disc : .circle), options: 0)
                lists[c.identity] = list
                listChain.append(list)
            case .tableHeaderRow:
                hint = .tableHeader
                bold = true
            case .tableRow:
                if hint == nil { hint = .tableRow }
            case .thematicBreak:
                hint = .rule
                style.alignment = .center
            default:
                break
            }
        }
        if !listChain.isEmpty {
            style.textLists = listChain
            let indent = CGFloat(listChain.count) * 24
            style.headIndent = indent
            style.firstLineHeadIndent = indent - 12
            style.paragraphSpacing = 2
        }

        if let inline {
            if inline.contains(.stronglyEmphasized) { bold = true }
            if inline.contains(.emphasized) { italic = true }
            if inline.contains(.code) { font = DocFonts.mono(size: font.pointSize - 1) }
        }
        font = DocFonts.styled(font, bold: bold, italic: italic)

        var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        if let hint { attrs[.rondoBlock] = hint.rawValue }
        if let color { attrs[.foregroundColor] = color }
        if inline?.contains(.strikethrough) == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link {
            attrs[.link] = link
            attrs[.foregroundColor] = NSColor(srgbRed: 0.0, green: 0.33, blue: 0.8, alpha: 1)
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }
}
