import Foundation

/// Minimal EPUB 3 container (with an EPUB 2 NCX for older readers).
/// Layout: `mimetype` (first, stored) · META-INF/container.xml · OEBPS/{content.opf, nav.xhtml, toc.ncx, style.css, chapter-N.xhtml}.
struct EPUBBuilder {
    struct Chapter {
        var title: String
        var bodyXHTML: String
    }

    var title: String
    var author: String?
    var language: String = "en"
    var chapters: [Chapter] = []
    var identifier = "urn:uuid:" + UUID().uuidString.lowercased()
    var modified = Date()

    static let css = """
    body { font-family: serif; line-height: 1.45; margin: 0 5%; }
    h1, h2, h3, h4, h5, h6 { font-family: sans-serif; line-height: 1.2; }
    pre { white-space: pre-wrap; font-family: monospace; font-size: 0.9em; background: #f4f4f4; padding: 0.5em; }
    code { font-family: monospace; }
    blockquote { margin-left: 1.5em; color: #555; font-style: italic; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid #999; padding: 0.2em 0.5em; }

    """

    /// Splits blocks into chapters at each level-1 heading when there are at least two; otherwise one chapter.
    static func chapters(from blocks: [Block], defaultTitle: String) -> [Chapter] {
        let h1Count = blocks.filter { if case .heading(1, _) = $0 { return true }; return false }.count
        guard h1Count >= 2 else {
            return [Chapter(title: firstHeading(blocks) ?? defaultTitle, bodyXHTML: XHTMLWriter.body(blocks))]
        }
        var groups: [[Block]] = [[]]
        for b in blocks {
            if case .heading(1, _) = b, !(groups.last?.isEmpty ?? true) { groups.append([]) }
            groups[groups.count - 1].append(b)
        }
        return groups.filter { !$0.isEmpty }.enumerated().map { i, g in
            Chapter(title: firstHeading(g) ?? (i == 0 ? defaultTitle : "Chapter \(i + 1)"), bodyXHTML: XHTMLWriter.body(g))
        }
    }

    private static func firstHeading(_ blocks: [Block]) -> String? {
        for b in blocks {
            if case .heading(_, let inl) = b {
                let t = inl.map(\.text).joined().replacingOccurrences(of: "\u{2028}", with: " ").trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    func build() -> Data {
        var zip = ZipBuilder(date: modified)
        zip.add("mimetype", "application/epub+zip", store: true)
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>

        """)
        let chs = chapters.isEmpty ? [Chapter(title: title, bodyXHTML: "<p></p>\n")] : chapters
        let lang = XML.escape(language, quotes: true)

        var manifest = """
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>

        """
        var spine = ""
        var navItems = ""
        var navPoints = ""
        for (i, ch) in chs.enumerated() {
            let n = i + 1
            let file = "chapter-\(n).xhtml"
            manifest += "    <item id=\"c\(n)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "    <itemref idref=\"c\(n)\"/>\n"
            navItems += "      <li><a href=\"\(file)\">\(XML.escape(ch.title))</a></li>\n"
            navPoints += """
                <navPoint id="np\(n)" playOrder="\(n)"><navLabel><text>\(XML.escape(ch.title))</text></navLabel><content src="\(file)"/></navPoint>

            """
            zip.add("OEBPS/\(file)", XHTMLWriter.document(title: ch.title, language: language, body: ch.bodyXHTML, stylesheet: "style.css"))
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let creator = author.map { "    <dc:creator>\(XML.escape($0))</dc:creator>\n" } ?? ""
        zip.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(lang)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(XML.escape(identifier))</dc:identifier>
            <dc:title>\(XML.escape(title))</dc:title>
            <dc:language>\(XML.escape(language))</dc:language>
        \(creator)    <meta property="dcterms:modified">\(iso.string(from: modified))</meta>
          </metadata>
          <manifest>
        \(manifest)  </manifest>
          <spine toc="ncx">
        \(spine)  </spine>
        </package>

        """)
        zip.add("OEBPS/nav.xhtml", XHTMLWriter.document(title: title, language: language, body: """
        <nav epub:type="toc" id="toc">
          <h1>Contents</h1>
          <ol>
        \(navItems)  </ol>
        </nav>

        """))
        zip.add("OEBPS/toc.ncx", """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="\(XML.escape(identifier, quotes: true))"/></head>
          <docTitle><text>\(XML.escape(title))</text></docTitle>
          <navMap>
        \(navPoints)  </navMap>
        </ncx>

        """)
        zip.add("OEBPS/style.css", Self.css)
        return zip.finish()
    }
}
