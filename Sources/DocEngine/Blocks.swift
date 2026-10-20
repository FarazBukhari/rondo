import AppKit

/// Semantic view of a rich-text document, shared by the Markdown, XHTML and EPUB writers.
struct Inline: Equatable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var strike = false
    var link: String?

    func sameStyle(_ o: Inline) -> Bool {
        bold == o.bold && italic == o.italic && code == o.code && strike == o.strike && link == o.link
    }
}

enum Block: Equatable {
    case heading(Int, [Inline])
    case paragraph([Inline])
    case listItem(ordered: Bool, depth: Int, number: Int, [Inline])
    case code(String)
    case quote([Inline])
    case rule
    case table([[String]], header: Bool)
}

/// Hint attribute set by our own importers (Markdown) so block types survive into the writers.
extension NSAttributedString.Key {
    static let rondoBlock = NSAttributedString.Key("RondoBlock")
}

enum BlockHint: String {
    case quote, rule, tableRow, tableHeader
}

enum BlockExtractor {
    /// Leading text bullets/numbers (e.g. DOCX list items, plain text): "• ", "- ", "1. ", "2) ".
    static let markerRegex = try! NSRegularExpression(pattern: #"^[\t ]*(?:([•◦▪▫●○■□‣⁃–\-*])|(\d{1,3})[.)])[\t ]+(?=\S)"#)

    private struct Para {
        var range: NSRange
        var text: String
        var style: NSParagraphStyle?
        var hint: BlockHint?
        var mono: Bool
        var bold: Bool
        var maxSize: CGFloat
    }

    static func blocks(from attr: NSAttributedString) -> [Block] {
        let ns = attr.string as NSString
        guard attr.length > 0 else { return [] }

        let base = baseFontSize(attr)
        var paras: [Para] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]) { sub, range, enclosing, _ in
            let text = sub ?? ""
            let probe = range.length > 0 ? range : NSRange(location: enclosing.location, length: min(1, enclosing.length))
            var mono = probe.length > 0, bold = probe.length > 0
            var maxSize: CGFloat = 0
            if probe.length > 0 {
                attr.enumerateAttribute(.font, in: probe) { value, r, _ in
                    let font = value as? NSFont
                    let piece = ns.substring(with: r)
                    let blank = piece.trimmingCharacters(in: .whitespaces).isEmpty
                    if !isMono(font) && !blank { mono = false }
                    if !isBold(font) && !blank { bold = false }
                    maxSize = max(maxSize, font?.pointSize ?? 12)
                }
            }
            let at = min(probe.location, attr.length - 1)
            let style = attr.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
            let hint = (attr.attribute(.rondoBlock, at: at, effectiveRange: nil) as? String).flatMap(BlockHint.init(rawValue:))
            paras.append(Para(range: range, text: text, style: style, hint: hint, mono: mono, bold: bold, maxSize: maxSize))
        }

        // Heading levels: explicit headerLevel wins; otherwise rank distinct "big" sizes (largest = h1).
        func headingCandidate(_ p: Para) -> Bool {
            let t = p.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.count <= 200, !p.mono, p.hint == nil, (p.style?.textLists ?? []).isEmpty,
                  !t.contains("\u{2028}") else { return false }
            return p.maxSize >= base * 1.15 && (p.bold || p.maxSize >= base * 1.3)
        }
        let sizes = Array(Set(paras.filter { ($0.style?.headerLevel ?? 0) == 0 && headingCandidate($0) }
            .map { ($0.maxSize * 2).rounded() / 2 })).sorted(by: >)

        var blocks: [Block] = []
        var code: [String] = []
        var table: [[String]] = []
        var tableHeader = false
        var counters: [Int] = []
        var lastLists: [NSTextList] = []

        func flushCode() {
            guard !code.isEmpty else { return }
            while let last = code.last, last.trimmingCharacters(in: .whitespaces).isEmpty { code.removeLast() }
            if !code.isEmpty { blocks.append(.code(code.joined(separator: "\n"))) }
            code = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            blocks.append(.table(table, header: tableHeader))
            table = []; tableHeader = false
        }
        func resetLists() { counters = []; lastLists = [] }

        for p in paras {
            let trimmed = p.text.trimmingCharacters(in: .whitespaces)
            if p.hint != .tableRow && p.hint != .tableHeader { flushTable() }
            if p.mono && p.hint == nil && (p.style?.textLists ?? []).isEmpty {
                if trimmed.isEmpty && code.isEmpty { continue }
                code.append(p.text)
                resetLists()
                continue
            }
            flushCode()
            if trimmed.isEmpty { continue }

            switch p.hint {
            case .rule?:
                blocks.append(.rule); resetLists(); continue
            case .quote?:
                blocks.append(.quote(inlines(attr, p.range))); resetLists(); continue
            case .tableRow?, .tableHeader?:
                if table.isEmpty { tableHeader = p.hint == .tableHeader }
                table.append(p.text.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) })
                resetLists(); continue
            case nil:
                break
            }

            if let lists = p.style?.textLists, !lists.isEmpty {
                let depth = lists.count
                let list = lists[depth - 1]
                if counters.count > depth { counters.removeLast(counters.count - depth) }
                while counters.count < depth { counters.append(0) }
                if lastLists.count >= depth, lastLists[depth - 1] !== list { counters[depth - 1] = 0 }
                if counters[depth - 1] == 0 { counters[depth - 1] = max(list.startingItemNumber, 1) - 1 }
                counters[depth - 1] += 1
                lastLists = lists
                blocks.append(.listItem(ordered: isOrdered(list), depth: depth, number: counters[depth - 1], inlines(attr, p.range)))
                continue
            }

            if let m = markerRegex.firstMatch(in: p.text, range: NSRange(location: 0, length: (p.text as NSString).length)) {
                let leading = p.text.prefix { $0 == "\t" || $0 == " " }
                let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let styleIndent = Int((p.style?.headIndent ?? 0) / 36)
                let depth = max(1, min(6, max(indent / 4 + 1, styleIndent)))
                let ordered = m.range(at: 2).location != NSNotFound
                let number = ordered ? Int((p.text as NSString).substring(with: m.range(at: 2))) ?? 1 : 1
                let body = NSRange(location: p.range.location + m.range.length, length: p.range.length - m.range.length)
                lastLists = []
                blocks.append(.listItem(ordered: ordered, depth: depth, number: number, inlines(attr, body)))
                continue
            }
            resetLists()

            if let level = p.style?.headerLevel, level > 0 {
                blocks.append(.heading(min(level, 6), plain(inlines(attr, p.range))))
            } else if headingCandidate(p), let idx = sizes.firstIndex(of: (p.maxSize * 2).rounded() / 2) {
                blocks.append(.heading(min(idx + 1, 6), plain(inlines(attr, p.range))))
            } else {
                blocks.append(.paragraph(inlines(attr, p.range)))
            }
        }
        flushCode()
        flushTable()
        return blocks
    }

    /// Headings carry their own weight; drop bold so writers don't emit "# **Title**".
    private static func plain(_ inl: [Inline]) -> [Inline] {
        merge(inl.map { var i = $0; i.bold = false; return i })
    }

    static func inlines(_ attr: NSAttributedString, _ range: NSRange) -> [Inline] {
        guard range.length > 0 else { return [] }
        var out: [Inline] = []
        let ns = attr.string as NSString
        attr.enumerateAttributes(in: range) { attrs, r, _ in
            var text = ns.substring(with: r)
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !text.isEmpty else { return }
            let font = attrs[.font] as? NSFont
            var link: String?
            if let u = attrs[.link] as? URL { link = u.absoluteString } else if let s = attrs[.link] as? String { link = s }
            let strike = ((attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
            out.append(Inline(text: text, bold: isBold(font), italic: isItalic(font, attrs), code: isMono(font),
                              strike: strike, link: link))
        }
        return merge(out)
    }

    static func merge(_ inl: [Inline]) -> [Inline] {
        var out: [Inline] = []
        for i in inl {
            if let last = out.last, last.sameStyle(i) { out[out.count - 1].text += i.text } else { out.append(i) }
        }
        return out
    }

    static func baseFontSize(_ attr: NSAttributedString) -> CGFloat {
        var hist: [CGFloat: Int] = [:]
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, r, _ in
            let size = ((value as? NSFont)?.pointSize ?? 12)
            hist[(size * 2).rounded() / 2, default: 0] += r.length
        }
        return hist.max { $0.value < $1.value }?.key ?? 12
    }

    static func isBold(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let n = font.fontName.lowercased()
        return n.contains("bold") || n.contains("black") || n.contains("heavy") || n.contains("semibold")
    }

    static func isItalic(_ font: NSFont?, _ attrs: [NSAttributedString.Key: Any]) -> Bool {
        if let o = attrs[.obliqueness] as? NSNumber, o.doubleValue > 0.05 { return true }
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.italic) { return true }
        let n = font.fontName.lowercased()
        return n.contains("italic") || n.contains("oblique")
    }

    static func isMono(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }
        let n = font.fontName.lowercased()
        return ["courier", "menlo", "monaco", "sfmono", "consolas", "andalemono", "mono"].contains { n.contains($0) }
    }

    static func isOrdered(_ list: NSTextList) -> Bool {
        let f = list.markerFormat.rawValue.lowercased()
        return ["decimal", "roman", "alpha", "octal", "hex"].contains { f.contains($0) }
    }
}

// MARK: - Markdown

enum MarkdownWriter {
    static func render(_ blocks: [Block]) -> String {
        var out = ""
        var prevWasList = false
        for b in blocks {
            let isList: Bool
            if case .listItem = b { isList = true } else { isList = false }
            if !out.isEmpty { out += (isList && prevWasList) ? "\n" : "\n\n" }
            prevWasList = isList
            switch b {
            case .heading(let level, let inl):
                out += String(repeating: "#", count: level) + " " + inline(inl).replacingOccurrences(of: "  \n", with: " ")
            case .paragraph(let inl):
                out += escapeLineStart(inline(inl))
            case .listItem(let ordered, let depth, let number, let inl):
                let indent = String(repeating: "    ", count: depth - 1)
                let marker = ordered ? "\(number). " : "- "
                let body = inline(inl).replacingOccurrences(of: "\n", with: "\n" + indent + "    ")
                out += indent + marker + body
            case .code(let text):
                let fence = text.contains("```") ? "~~~~" : "```"
                out += fence + "\n" + text + "\n" + fence
            case .quote(let inl):
                out += inline(inl).split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            case .rule:
                out += "---"
            case .table(let rows, let header):
                out += table(rows, header: header)
            }
        }
        return out.isEmpty ? out : out + "\n"
    }

    static func table(_ rows: [[String]], header: Bool) -> String {
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return "" }
        func row(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: cols - cells.count)
            return "| " + padded.map { escapeText($0).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        var lines: [String] = []
        var body = rows
        if header, let first = body.first {
            lines.append(row(first)); body.removeFirst()
        } else {
            lines.append(row(Array(repeating: "", count: cols)))
        }
        lines.append("|" + Array(repeating: " --- |", count: cols).joined())
        lines += body.map(row)
        return lines.joined(separator: "\n")
    }

    static func inline(_ inl: [Inline]) -> String {
        var out = ""
        for i in inl {
            if i.code {
                let t = i.text.replacingOccurrences(of: "\u{2028}", with: " ")
                guard !t.isEmpty else { continue }
                let span = t.contains("`") ? "`` " + t + " ``" : "`" + t + "`"
                out += wrapLink(span, i.link)
                continue
            }
            let core = i.text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { out += hardBreaks(i.text); continue }
            let lead = String(i.text.prefix { $0 == " " || $0 == "\t" })
            let trail = String(i.text.reversed().prefix { $0 == " " || $0 == "\t" })
            var s = hardBreaks(escapeText(core))
            if i.italic { s = "*" + s + "*" }
            if i.bold { s = "**" + s + "**" }
            if i.strike { s = "~~" + s + "~~" }
            out += lead + wrapLink(s, i.link) + trail
        }
        return out
    }

    private static func wrapLink(_ s: String, _ link: String?) -> String {
        guard let link, !link.isEmpty else { return s }
        let dest = link.contains(" ") || link.contains("(") || link.contains(")") ? "<" + link + ">" : link
        return "[" + s + "](" + dest + ")"
    }

    private static func hardBreaks(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2028}", with: "  \n")
    }

    /// Escapes Markdown punctuation that would otherwise change meaning.
    static func escapeText(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        for (idx, c) in chars.enumerated() {
            switch c {
            case "\\", "`", "*", "[", "]", "<":
                out.append("\\"); out.append(c)
            case "_":
                let prev = idx > 0 ? chars[idx - 1] : " "
                let next = idx + 1 < chars.count ? chars[idx + 1] : " "
                if prev.isLetter || prev.isNumber, next.isLetter || next.isNumber { out.append(c) } else { out += "\\_" }
            default:
                out.append(c)
            }
        }
        return out
    }

    /// Block-level markers at the start of a line ("# ", "> ", "- ", "1. ") in a plain paragraph.
    static func escapeLineStart(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let l = String(line)
            if l.hasPrefix("#") || l.hasPrefix(">") || l.hasPrefix("+ ") || l.hasPrefix("- ") || l == "-" || l.hasPrefix("=") {
                return "\\" + l
            }
            if let r = l.range(of: #"^\d{1,9}[.)](?=\s|$)"#, options: .regularExpression) {
                var m = l
                m.insert("\\", at: m.index(before: r.upperBound))
                return m
            }
            return l
        }.joined(separator: "\n")
    }
}

// MARK: - XHTML (EPUB chapters and semantic HTML)

enum XHTMLWriter {
    static func body(_ blocks: [Block]) -> String {
        var out = ""
        var stack: [Bool] = []      // open lists: ordered?
        var liOpen: [Bool] = []

        func closeLists(to depth: Int) {
            while stack.count > depth {
                if liOpen.removeLast() { out += "</li>" }
                out += stack.removeLast() ? "</ol>\n" : "</ul>\n"
            }
        }

        for b in blocks {
            if case .listItem(let ordered, let depth, _, let inl) = b {
                closeLists(to: depth)
                if stack.count == depth {
                    if liOpen[depth - 1] { out += "</li>\n"; liOpen[depth - 1] = false }
                    if stack[depth - 1] != ordered {
                        out += stack[depth - 1] ? "</ol>\n" : "</ul>\n"
                        out += ordered ? "<ol>\n" : "<ul>\n"
                        stack[depth - 1] = ordered
                    }
                }
                while stack.count < depth {
                    if let last = liOpen.last, !last { out += "<li>"; liOpen[liOpen.count - 1] = true }
                    out += ordered ? "<ol>\n" : "<ul>\n"
                    stack.append(ordered); liOpen.append(false)
                }
                out += "<li>" + inline(inl)
                liOpen[depth - 1] = true
                continue
            }
            closeLists(to: 0)
            switch b {
            case .heading(let level, let inl):
                out += "<h\(level)>" + inline(inl) + "</h\(level)>\n"
            case .paragraph(let inl):
                out += "<p>" + inline(inl) + "</p>\n"
            case .code(let text):
                out += "<pre><code>" + XML.escape(text) + "</code></pre>\n"
            case .quote(let inl):
                out += "<blockquote><p>" + inline(inl) + "</p></blockquote>\n"
            case .rule:
                out += "<hr/>\n"
            case .table(let rows, let header):
                out += "<table>\n"
                for (i, row) in rows.enumerated() {
                    let tag = header && i == 0 ? "th" : "td"
                    out += "<tr>" + row.map { "<\(tag)>" + XML.escape($0) + "</\(tag)>" }.joined() + "</tr>\n"
                }
                out += "</table>\n"
            case .listItem:
                break
            }
        }
        closeLists(to: 0)
        return out
    }

    static func inline(_ inl: [Inline]) -> String {
        var out = ""
        for i in inl {
            var s = XML.escape(i.text).replacingOccurrences(of: "\u{2028}", with: "<br/>").replacingOccurrences(of: "\n", with: "<br/>")
            if i.code { s = "<code>" + s + "</code>" }
            if i.italic { s = "<em>" + s + "</em>" }
            if i.bold { s = "<strong>" + s + "</strong>" }
            if i.strike { s = "<del>" + s + "</del>" }
            if let link = i.link, !link.isEmpty { s = "<a href=\"" + XML.escape(link, quotes: true) + "\">" + s + "</a>" }
            out += s
        }
        return out
    }

    /// Standalone XHTML document (used for EPUB chapters).
    static func document(title: String, language: String, body: String, stylesheet: String? = nil) -> String {
        var head = "<meta charset=\"UTF-8\"/>\n<title>\(XML.escape(title))</title>\n"
        if let stylesheet { head += "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(stylesheet)\"/>\n" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
        <head>
        \(head)</head>
        <body>
        \(body)</body>
        </html>

        """
    }
}

// MARK: - Plain text

enum PlainTextWriter {
    /// Plain text with list markers inlined, attachments dropped, line separators as newlines.
    static func render(_ attr: NSAttributedString) -> String {
        var s = ListMarkers.inlined(attr).string
        s = s.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if !s.hasSuffix("\n") { s += "\n" }
        return s
    }
}

/// CoreText and AppKit's DOCX writer don't draw NSTextList markers; bake them into the text.
enum ListMarkers {
    static func inlined(_ attr: NSAttributedString) -> NSAttributedString {
        let ns = attr.string as NSString
        guard attr.length > 0 else { return attr }
        var inserts: [(Int, String, [NSAttributedString.Key: Any])] = []
        var counters: [Int] = []
        var lastLists: [NSTextList] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            let at = min(enclosing.location, attr.length - 1)
            guard let style = attr.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle,
                  !style.textLists.isEmpty else {
                counters = []; lastLists = []
                return
            }
            let lists = style.textLists
            let depth = lists.count
            let list = lists[depth - 1]
            if counters.count > depth { counters.removeLast(counters.count - depth) }
            while counters.count < depth { counters.append(0) }
            if lastLists.count >= depth, lastLists[depth - 1] !== list { counters[depth - 1] = 0 }
            if counters[depth - 1] == 0 { counters[depth - 1] = max(list.startingItemNumber, 1) - 1 }
            counters[depth - 1] += 1
            lastLists = lists
            let marker = list.marker(forItemNumber: counters[depth - 1])
            let indent = String(repeating: "    ", count: depth - 1)
            var attrs = attr.attributes(at: at, effectiveRange: nil)
            attrs[.link] = nil
            inserts.append((range.location, indent + (marker.isEmpty ? "•" : marker) + " ", attrs))
        }
        guard !inserts.isEmpty else { return attr }
        let out = NSMutableAttributedString(attributedString: attr)
        for (loc, text, attrs) in inserts.reversed() {
            out.insert(NSAttributedString(string: text, attributes: attrs), at: loc)
        }
        // Strip the list structure so native writers don't add a second marker.
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { value, r, _ in
            guard let ps = value as? NSParagraphStyle, !ps.textLists.isEmpty,
                  let m = ps.mutableCopy() as? NSMutableParagraphStyle else { return }
            m.textLists = []
            out.addAttribute(.paragraphStyle, value: m, range: r)
        }
        return out
    }
}
