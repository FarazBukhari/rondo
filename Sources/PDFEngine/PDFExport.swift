import AppKit
import Foundation
import PDFKit
import Vision
import RondoKit

/// PDF → TXT / MD / DOCX / EPUB.
enum PDFExport {
    // MARK: Text

    /// Text per page. Pages without a text layer are OCR'd with Vision when `ocr` is true.
    static func pageTexts(_ doc: PDFDocument, ocr: Bool, progress: (Double) -> Void) throws -> [String] {
        var out: [String] = []
        let n = doc.pageCount
        for i in 0..<n {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { out.append(""); continue }
            var text = page.string ?? ""
            if ocr, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = (try? recognize(page)) ?? ""
            }
            out.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            progress(Double(i + 1) / Double(n))
        }
        return out
    }

    static func recognize(_ page: PDFPage) throws -> String {
        let image = try PDFRender.render(page, dpi: 200, maxPixels: 4000)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func plainText(_ pages: [String]) -> String {
        pages.joined(separator: "\n\n") + "\n"
    }

    // MARK: Markdown

    static func markdown(_ pages: [String], title: String) -> String {
        var md = "# \(escapeInline(title))\n"
        for (i, text) in pages.enumerated() {
            md += "\n## Page \(i + 1)\n\n"
            let paras = paragraphs(text)
            md += paras.isEmpty ? "_(no text)_\n" : paras.map(escapeBlock).joined(separator: "\n\n") + "\n"
        }
        return md
    }

    /// Escapes characters that would accidentally start Markdown block syntax.
    static func escapeBlock(_ s: String) -> String {
        guard let first = s.first else { return s }
        if "#>+-*=|`".contains(first) { return "\\" + s }
        if let r = s.range(of: #"^\d+(?=[.)]\s)"#, options: .regularExpression) {
            return s[..<r.upperBound] + "\\" + s[r.upperBound...]
        }
        return s
    }

    static func escapeInline(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
    }

    /// Reflows PDF lines into paragraphs: a blank line, or a short line ending a sentence, ends a paragraph.
    static func paragraphs(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let longest = lines.map(\.count).max() ?? 0
        var result: [String] = []
        var current = ""
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty { result.append(current); current = "" }
                continue
            }
            if current.isEmpty { current = line }
            else if current.hasSuffix("-") && !current.hasSuffix(" -") { current = String(current.dropLast()) + line }
            else { current += " " + line }
            let endsSentence = line.last.map { ".!?:;\"”’)".contains($0) } ?? false
            if endsSentence && Double(line.count) < Double(longest) * 0.8 {
                result.append(current); current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: DOCX

    /// Page-by-page attributed text written as Office Open XML; pages separated by page breaks.
    /// nil when the document has no text at all (even after OCR).
    static func docx(_ doc: PDFDocument, ocr: Bool, progress: (Double) -> Void) throws -> Data? {
        let result = NSMutableAttributedString()
        let n = doc.pageCount
        let bodyFont = NSFont.systemFont(ofSize: 12)
        for i in 0..<n {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            var pageText: NSAttributedString = page.attributedString ?? NSAttributedString()
            if pageText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ocr,
               let recognized = try? recognize(page), !recognized.isEmpty {
                pageText = NSAttributedString(string: recognized, attributes: [.font: bodyFont])
            }
            if i > 0 { result.append(NSAttributedString(string: "\u{0C}", attributes: [.font: bodyFont])) }
            result.append(pageText)
            if !pageText.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont])) }
            progress(Double(i + 1) / Double(n) * 0.9)
        }
        let visible = result.string.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0C}")))
        guard !visible.isEmpty else { return nil }
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        if let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String { attrs[.title] = title }
        if let author = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String { attrs[.author] = author }
        return try result.data(from: NSRange(location: 0, length: result.length), documentAttributes: attrs)
    }

    // MARK: EPUB

    /// EPUB 3 (with an EPUB 2 NCX for older readers): one XHTML chapter per page, reflowed paragraphs.
    static func epub(pages: [String], title: String, author: String?, language: String = "en") -> Data {
        let uid = "urn:uuid:" + UUID().uuidString.lowercased()
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let t = xml(title)
        let lang = xml(language)

        var zip = ZipWriter()
        zip.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        zip.add("META-INF/container.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8))

        let ids = pages.indices.map { "page-\($0 + 1)" }
        var manifest = """
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>

        """
        var spine = ""
        var navItems = ""
        var navPoints = ""
        for (i, id) in ids.enumerated() {
            manifest += "    <item id=\"\(id)\" href=\"\(id).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "    <itemref idref=\"\(id)\"/>\n"
            navItems += "      <li><a href=\"\(id).xhtml\">Page \(i + 1)</a></li>\n"
            navPoints += """
                <navPoint id="np-\(i + 1)" playOrder="\(i + 1)"><navLabel><text>Page \(i + 1)</text></navLabel><content src="\(id).xhtml"/></navPoint>

            """
        }

        zip.add("OEBPS/content.opf", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="\(lang)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(uid)</dc:identifier>
            <dc:title>\(t)</dc:title>
            <dc:creator>\(xml(author ?? "Unknown"))</dc:creator>
            <dc:language>\(lang)</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
        \(manifest)  </manifest>
          <spine toc="ncx">
        \(spine)  </spine>
        </package>
        """.utf8))

        zip.add("OEBPS/nav.xhtml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
        <head><meta charset="UTF-8"/><title>\(t)</title></head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>\(t)</h1>
            <ol>
        \(navItems)    </ol>
          </nav>
        </body>
        </html>
        """.utf8))

        zip.add("OEBPS/toc.ncx", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="\(uid)"/></head>
          <docTitle><text>\(t)</text></docTitle>
          <navMap>
        \(navPoints)  </navMap>
        </ncx>
        """.utf8))

        zip.add("OEBPS/style.css", Data("""
        body { font-family: serif; line-height: 1.45; margin: 0 5%; }
        h2 { font-size: 1em; color: #666; font-weight: normal; margin-top: 2em; }
        p { margin: 0 0 0.8em 0; text-align: left; }
        """.utf8))

        for (i, text) in pages.enumerated() {
            let paras = paragraphs(text)
            let body = paras.isEmpty ? "<p class=\"empty\"></p>" : paras.map { "<p>\(xml($0))</p>" }.joined(separator: "\n    ")
            zip.add("OEBPS/\(ids[i]).xhtml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
            <head><meta charset="UTF-8"/><title>Page \(i + 1)</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
            <body>
              <section epub:type="chapter" id="\(ids[i])">
                <h2>Page \(i + 1)</h2>
                \(body)
              </section>
            </body>
            </html>
            """.utf8))
        }
        return zip.finish()
    }

    /// XML-escapes and drops characters XML 1.0 forbids (control chars, lone surrogates, U+FFFE/FFFF).
    static func xml(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                let v = scalar.value
                if v < 0x20 || v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
