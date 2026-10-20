import AppKit
import Foundation
import Testing
import RondoKit
@testable import DocEngine

@Suite struct DocumentTests {
    static let markdown = """
    # Project Notes

    Intro with **bold**, *italic*, `code` and a [link](https://example.com/a).
    Second line of the same paragraph.

    ## Details

    - one
    - two
        - nested
    1. first
    2. second

    > quoted words

    ```
    let x = 1
    let y = 2
    ```

    | Name | Qty |
    |------|-----|
    | Pear | 5   |
    """

    @Test func markdownToSemanticHTML() async throws {
        let dir = try W5.dir("md-html")
        let md = try W5.write(Self.markdown, to: dir, name: "notes.md")
        let html = try W5.text(try await W5.one(md, to: "html"))
        #expect(html.contains("<h1>Project Notes</h1>"))
        #expect(html.contains("<h2>Details</h2>"))
        #expect(html.contains("<strong>bold</strong>") && html.contains("<em>italic</em>") && html.contains("<code>code</code>"))
        #expect(html.contains("<a href=\"https://example.com/a\">link</a>"))
        #expect(html.contains("<ul>") && html.contains("<ol>") && html.contains("<li>nested"))
        #expect(html.contains("<pre><code>let x = 1\nlet y = 2</code></pre>"))
        #expect(html.contains("<blockquote>") && html.contains("<table>") && html.contains("<th>Name</th>"))
        #expect(html.contains("<title>Project Notes</title>"))
    }

    @Test func markdownRoundTripsThroughRTF() async throws {
        let dir = try W5.dir("md-rtf-md")
        let md = try W5.write(Self.markdown, to: dir, name: "notes.md")
        let rtf = try await W5.one(md, to: "rtf")
        let back = try W5.text(try await W5.one(rtf, to: "md", out: dir.appendingPathComponent("back")))
        #expect(back.contains("# Project Notes"))
        #expect(back.contains("## Details"))
        #expect(back.contains("**bold**") && back.contains("*italic*") && back.contains("`code`"))
        #expect(back.contains("[link](https://example.com/a)"))
        #expect(back.contains("- one\n- two\n    - nested"))
        #expect(back.contains("1. first\n2. second"))
        #expect(back.contains("```\nlet x = 1\nlet y = 2\n```"))
    }

    @Test func markdownToDocxKeepsStructure() async throws {
        let dir = try W5.dir("md-docx")
        let md = try W5.write(Self.markdown, to: dir, name: "notes.md")
        let docx = try await W5.one(md, to: "docx")
        #expect(docx.pathExtension == "docx")
        #expect(W5.zipOK(docx))
        #expect(W5.zipEntry(docx, "word/document.xml")?.contains("Project Notes") == true)
        // DOCX → MD: headings from font sizes, bullets from baked-in markers.
        let back = try W5.text(try await W5.one(docx, to: "md", out: dir.appendingPathComponent("back")))
        #expect(back.contains("# Project Notes"))
        #expect(back.contains("- one"))
        #expect(back.contains("1. first"))
        #expect(back.contains("**bold**"))
    }

    @Test func htmlViaTextutil() async throws {
        let dir = try W5.dir("html-md")
        let html = try W5.write("""
        <html><head><title>Page Title</title></head><body><h1>Big</h1><p>Hello <b>bold</b> and <i>ital</i>
        <a href="https://example.com/">link</a> &amp; more.</p><h2>Sub</h2><ul><li>One</li><li>Two</li></ul>
        <img src="https://example.invalid/x.png"></body></html>
        """, to: dir, name: "page.html")
        let md = try W5.text(try await W5.one(html, to: "md"))
        #expect(md.contains("# Big") && md.contains("## Sub"))
        #expect(md.contains("**bold**") && md.contains("*ital*"))
        #expect(md.contains("[link](https://example.com/)"))
        #expect(md.contains("- One\n- Two"))
        #expect(md.contains("& more"))
        let txt = try W5.text(try await W5.one(html, to: "txt"))
        #expect(txt.contains("Hello bold and ital"))
    }

    @Test func epubStructure() async throws {
        let dir = try W5.dir("epub")
        let txt = try W5.write("Line one\nline two\n\nSecond paragraph <with> & symbols.\n", to: dir, name: "story.txt")
        let epub = try await W5.one(txt, to: "epub")
        let data = try Data(contentsOf: epub)
        // mimetype must be the first entry, stored (method 0), uncompressed content "application/epub+zip".
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(data[8] == 0 && data[9] == 0, "mimetype must be stored")
        let nameLen = Int(data[26]) | Int(data[27]) << 8
        let extraLen = Int(data[28]) | Int(data[29]) << 8
        #expect(String(decoding: data[30..<(30 + nameLen)], as: UTF8.self) == "mimetype")
        #expect(extraLen == 0)
        let start = 30 + nameLen + extraLen
        #expect(String(decoding: data[start..<(start + 20)], as: UTF8.self) == "application/epub+zip")
        #expect(W5.zipOK(epub))
        let container = try #require(W5.zipEntry(epub, "META-INF/container.xml"))
        #expect(container.contains("OEBPS/content.opf"))
        let opf = try #require(W5.zipEntry(epub, "OEBPS/content.opf"))
        #expect(opf.contains("<dc:title>story</dc:title>") && opf.contains("properties=\"nav\""))
        let chapter = try #require(W5.zipEntry(epub, "OEBPS/chapter-1.xhtml"))
        #expect(chapter.contains("Line one<br/>line two"))
        #expect(chapter.contains("&lt;with&gt; &amp; symbols"))
        for entry in ["OEBPS/chapter-1.xhtml", "OEBPS/nav.xhtml", "OEBPS/content.opf", "OEBPS/toc.ncx"] {
            let xml = try #require(W5.zipEntry(epub, entry))
            #expect(XMLParser(data: Data(xml.utf8)).parse(), "\(entry) must be well-formed XML")
        }
    }

    @Test func epubSplitsChaptersAtH1() async throws {
        let dir = try W5.dir("epub-ch")
        let md = try W5.write("# One\n\nAlpha\n\n# Two\n\nBeta\n", to: dir, name: "book.md")
        let epub = try await W5.one(md, to: "epub")
        #expect(W5.zipEntry(epub, "OEBPS/chapter-2.xhtml")?.contains("Beta") == true)
        #expect(W5.zipEntry(epub, "OEBPS/nav.xhtml")?.contains(">Two</a>") == true)
    }

    @Test func pdfPaginates() async throws {
        let dir = try W5.dir("pdf")
        let body = (1...300).map { "Paragraph \($0) with enough words to wrap across the line at least once or twice in a page." }
        let md = try W5.write("# Long\n\n" + body.joined(separator: "\n\n") + "\n\n- bullet\n", to: dir, name: "long.md")
        let pdf = try await W5.one(md, to: "pdf")
        let doc = try #require(CGPDFDocument(pdf as CFURL))
        #expect(doc.numberOfPages > 3)
        let text = try #require(PDFTextProbe.firstPageHasContent(pdf))
        #expect(text)
    }

    @Test func textClippingInput() async throws {
        let dir = try W5.dir("clip")
        let plist: [String: Any] = ["UTI-Data": ["public.utf8-plain-text": "Clipped text\nsecond line"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let clip = dir.appendingPathComponent("snip.textclipping")
        try data.write(to: clip)
        let txt = try W5.text(try await W5.one(clip, to: "txt"))
        #expect(txt.contains("Clipped text") && txt.contains("second line"))
        let md = try W5.text(try await W5.one(clip, to: "md"))
        #expect(md.contains("Clipped text  \nsecond line"))
    }

    /// Every advertised document input → every output, on textutil-generated fixtures.
    @Test(arguments: ["docx", "rtf", "html", "odt", "doc", "rtfd"])
    func matrix(from: String) async throws {
        let dir = try W5.dir("matrix-\(from)")
        let src = try W5.write("Matrix Title\n\nBody text with symbols: é ü — “quotes”.\n", to: dir, name: "seed.txt")
        let input = dir.appendingPathComponent("sample.\(from)")
        #expect(W5.sh("/usr/bin/textutil", ["-convert", from, "-output", input.path, src.path]).0 == 0)
        for to in DocumentEngine.documentOutputs where to != from {
            let out = try await W5.one(input, to: to, out: dir.appendingPathComponent("out"))
            #expect(out.pathExtension == to, "\(from) → \(to)")
            switch to {
            case "docx", "epub":
                #expect(W5.zipOK(out), "\(from) → \(to) zip")
            case "pdf":
                #expect((CGPDFDocument(out as CFURL)?.numberOfPages ?? 0) >= 1, "\(from) → pdf")
            default:
                let t = try W5.text(out)
                #expect(t.contains("Body text with symbols"), "\(from) → \(to) text")
                if to != "rtf" { #expect(t.contains("é ü"), "\(from) → \(to) unicode") }
            }
        }
    }

    @Test func blockExtractorDetectsTextMarkers() throws {
        let a = NSAttributedString(string: "• alpha\n2) beta\nplain\n", attributes: [.font: DocFonts.body()])
        let blocks = BlockExtractor.blocks(from: a)
        try #require(blocks.count == 3)
        if case .listItem(false, 1, _, let inl) = blocks[0] { #expect(inl.first?.text == "alpha") } else { Issue.record("bullet") }
        if case .listItem(true, 1, 2, _) = blocks[1] {} else { Issue.record("ordered") }
        if case .paragraph = blocks[2] {} else { Issue.record("paragraph") }
    }

    @Test func markdownEscaping() {
        #expect(MarkdownWriter.escapeText("a*b_c [x] snake_case _lead") == "a\\*b_c \\[x\\] snake_case \\_lead")
        #expect(MarkdownWriter.escapeLineStart("# not heading") == "\\# not heading")
        #expect(MarkdownWriter.escapeLineStart("1. not list") == "1\\. not list")
        #expect(MarkdownWriter.inline([Inline(text: " bold ", bold: true)]) == " **bold** ")
    }
}

/// Minimal check that a generated PDF page has drawable content.
enum PDFTextProbe {
    static func firstPageHasContent(_ url: URL) -> Bool? {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1),
              let dict = page.dictionary else { return nil }
        var contents: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dict, "Contents", &contents)
    }
}
