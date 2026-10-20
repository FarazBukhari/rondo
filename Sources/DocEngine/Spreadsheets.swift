import Foundation
import RondoKit

/// Delimited text (RFC 4180) and a minimal XLSX reader/writer.
enum Delimited {
    /// Parses CSV/TSV. Quotes are honored only at the start of a field; `""` inside quotes is a literal quote;
    /// quoted fields may span lines. Accepts LF, CRLF and CR row ends. A trailing newline doesn't add a row.
    static func parse(_ raw: String, delimiter: Character) -> [[String]] {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false   // any char (or quote) seen for the current field
        let scalars = text.unicodeScalars   // walked in place; no copy of large files
        var i = scalars.startIndex
        let d = delimiter.unicodeScalars.first!

        func endField() { row.append(field); field = ""; fieldStarted = false }
        func endRow() { endField(); rows.append(row); row = [] }
        func peek(_ j: String.UnicodeScalarView.Index) -> Unicode.Scalar? {
            let n = scalars.index(after: j)
            return n < scalars.endIndex ? scalars[n] : nil
        }

        while i < scalars.endIndex {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if peek(i) == "\"" { field.unicodeScalars.append("\""); i = scalars.index(i, offsetBy: 2); continue }
                    inQuotes = false
                } else {
                    field.unicodeScalars.append(c)
                }
                i = scalars.index(after: i)
                continue
            }
            switch c {
            case "\"" where !fieldStarted:
                inQuotes = true; fieldStarted = true
            case d:
                endField()
            case "\r":
                endRow()
                if peek(i) == "\n" { i = scalars.index(after: i) }
            case "\n":
                endRow()
            default:
                field.unicodeScalars.append(c); fieldStarted = true
            }
            i = scalars.index(after: i)
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// RFC 4180 output. CSV rows end in CRLF; TSV in LF. Fields are quoted only when needed.
    static func write(_ rows: [[String]], delimiter: Character) -> String {
        let eol = delimiter == "," ? "\r\n" : "\n"
        return rows.map { row in
            row.map { quote($0, delimiter: delimiter) }.joined(separator: String(delimiter))
        }.joined(separator: eol) + (rows.isEmpty ? "" : eol)
    }

    /// CSV: quote on delimiter, quote, CR or LF (RFC 4180). TSV: only on tab/CR/LF or a leading quote,
    /// so ordinary text with quotes stays readable (the parser treats mid-field quotes literally).
    static func quote(_ f: String, delimiter: Character) -> String {
        let d = delimiter.unicodeScalars.first!
        let structural = f.unicodeScalars.contains { $0 == d || $0 == "\n" || $0 == "\r" }
        let needs = structural || (delimiter == "," ? f.contains("\"") : f.hasPrefix("\""))
        guard needs else { return f }
        return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Pads ragged rows to the widest row (keeps CSV → XLSX/PDF grids rectangular).
    static func rectangular(_ rows: [[String]]) -> [[String]] {
        let w = rows.map(\.count).max() ?? 0
        return rows.map { $0.count < w ? $0 + Array(repeating: "", count: w - $0.count) : $0 }
    }
}

// MARK: - XLSX

enum XLSX {
    // MARK: Read

    /// First worksheet as rows of display strings (shared/inline strings, numbers, booleans, cached formula results).
    static func read(_ url: URL, context: JobContext) async throws -> [[String]] {
        try DocSupport.requireInput(url)
        let unzip = try context.tools.require("unzip")
        let work = try DocSupport.scratchDir(context)
        // Only named members are extracted, into scratch space; unzip strips "../" components itself.
        let r = try await ProcessRunner.run(unzip, ["-qq", "-o", url.path,
                                                    "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/sharedStrings.xml",
                                                    "xl/worksheets/*.xml", "-d", work.path], checkExit: false)
        guard r.exitCode == 0 || r.exitCode == 1 || r.exitCode == 11 else {
            throw EngineError.invalidInput("\(url.lastPathComponent) isn't a readable XLSX")
        }
        let sheet = try firstSheet(in: work)
        let shared = (try? Data(contentsOf: work.appendingPathComponent("xl/sharedStrings.xml"))).map(SharedStrings.parse) ?? []
        let data = try Data(contentsOf: sheet)
        return Sheet.parse(data, shared: shared)
    }

    static func firstSheet(in root: URL) throws -> URL {
        let fm = FileManager.default
        if let wb = try? Data(contentsOf: root.appendingPathComponent("xl/workbook.xml")),
           let rels = try? Data(contentsOf: root.appendingPathComponent("xl/_rels/workbook.xml.rels")),
           let rid = AttrScanner.first(in: wb, element: "sheet", attribute: "r:id") ?? AttrScanner.first(in: wb, element: "sheet", attribute: "id"),
           let target = AttrScanner.target(in: rels, id: rid) {
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            let u = root.appendingPathComponent(path).standardizedFileURL
            if u.path.hasPrefix(root.standardizedFileURL.path + "/"), fm.fileExists(atPath: u.path) { return u }
        }
        let fallback = root.appendingPathComponent("xl/worksheets/sheet1.xml")
        if fm.fileExists(atPath: fallback.path) { return fallback }
        let dir = root.appendingPathComponent("xl/worksheets")
        if let any = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter({ $0.hasSuffix(".xml") }).sorted().first {
            return dir.appendingPathComponent(any)
        }
        throw EngineError.invalidInput("No worksheet found")
    }

    /// "AB12" → zero-based column 27.
    static func column(of ref: String) -> Int? {
        var n = 0
        var any = false
        for c in ref.uppercased().unicodeScalars {
            guard c.value >= 65 && c.value <= 90 else { break }
            n = n * 26 + Int(c.value - 64)
            any = true
        }
        return any ? n - 1 : nil
    }

    static func row(of ref: String) -> Int? {
        let digits = ref.drop { $0.isLetter }
        return Int(digits).map { $0 - 1 }
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    // MARK: Write

    /// Minimal valid SpreadsheetML package: one sheet, inline strings, numeric cells for plain numbers, bold header.
    static func write(_ rows: [[String]], sheetName: String = "Sheet1", boldHeader: Bool = true) -> Data {
        // Excel rejects []:*?/\ in sheet names and names over 31 characters.
        let cleaned = String(sheetName.filter { !"[]:*?/\\".contains($0) }.prefix(31)).trimmingCharacters(in: .whitespaces)
        let name = cleaned.isEmpty ? "Sheet1" : cleaned
        var zip = ZipBuilder()
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """)
        zip.add("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="\(XML.escape(name, quotes: true))" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """)
        zip.add("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """)

        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """
        for (ri, row) in rows.enumerated() {
            sheet += "<row r=\"\(ri + 1)\">"
            for (ci, value) in row.enumerated() where !value.isEmpty {
                let ref = columnName(ci) + String(ri + 1)
                let style = boldHeader && ri == 0 && rows.count > 1 ? " s=\"1\"" : ""
                if isNumber(value) {
                    sheet += "<c r=\"\(ref)\"\(style)><v>\(value)</v></c>"
                } else {
                    let space = value.first?.isWhitespace == true || value.last?.isWhitespace == true || value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
                    sheet += "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t\(space ? " xml:space=\"preserve\"" : "")>\(XML.escape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"
        zip.add("xl/worksheets/sheet1.xml", sheet)
        return zip.finish()
    }

    /// Plain decimal numbers only; keeps "007", "1,000", "+5", phone numbers etc. as text.
    static func isNumber(_ s: String) -> Bool {
        guard s.count <= 15, s.range(of: #"^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil else { return false }
        return Double(s)?.isFinite == true
    }

    // MARK: XML parsing

    final class SharedStrings: NSObject, XMLParserDelegate {
        var items: [String] = []
        private var current = ""
        private var inSI = false, inT = false, inPhonetic = false

        static func parse(_ data: Data) -> [String] {
            let d = SharedStrings()
            let p = XMLParser(data: data)
            p.delegate = d
            p.parse()
            return d.items
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch local(name) {
            case "si": inSI = true; current = ""
            case "t": inT = true
            case "rPh": inPhonetic = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(name) {
            case "si": items.append(current); inSI = false
            case "t": inT = false
            case "rPh": inPhonetic = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inSI && inT && !inPhonetic { current += string }
        }
    }

    final class Sheet: NSObject, XMLParserDelegate {
        private var cells: [Int: [Int: String]] = [:]
        private let shared: [String]
        private var rowIndex = -1
        private var colIndex = -1
        private var type = ""
        private var value = ""
        private var inlineText = ""
        private var inV = false, inT = false, inIS = false
        private var maxRow = -1, maxCol = -1

        init(shared: [String]) { self.shared = shared }

        static func parse(_ data: Data, shared: [String]) -> [[String]] {
            let s = Sheet(shared: shared)
            let p = XMLParser(data: data)
            p.delegate = s
            p.parse()
            guard s.maxRow >= 0, s.maxCol >= 0 else { return [] }
            return (0...s.maxRow).map { r in (0...s.maxCol).map { c in s.cells[r]?[c] ?? "" } }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch local(name) {
            case "row":
                rowIndex = attributes["r"].flatMap(Int.init).map { $0 - 1 } ?? rowIndex + 1
                colIndex = -1
            case "c":
                let ref = attributes["r"] ?? ""
                colIndex = XLSX.column(of: ref) ?? colIndex + 1
                if let r = XLSX.row(of: ref) { rowIndex = r }
                type = attributes["t"] ?? ""
                value = ""; inlineText = ""
            case "v": inV = true
            case "is": inIS = true
            case "t" where inIS: inT = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(name) {
            case "v": inV = false
            case "t": inT = false
            case "is": inIS = false
            case "c":
                let display: String
                switch type {
                case "s": display = Int(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 && $0 < shared.count ? shared[$0] : nil } ?? ""
                case "inlineStr": display = inlineText
                case "b": display = value == "1" ? "TRUE" : (value.isEmpty ? "" : "FALSE")
                default: display = value
                }
                if !display.isEmpty, rowIndex >= 0, colIndex >= 0 {
                    cells[rowIndex, default: [:]][colIndex] = display
                    maxRow = max(maxRow, rowIndex); maxCol = max(maxCol, colIndex)
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inV { value += string } else if inIS && inT { inlineText += string }
        }
    }

    static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

/// Tiny attribute scanner for workbook.xml / rels (avoids a full parse for two lookups).
enum AttrScanner {
    final class Finder: NSObject, XMLParserDelegate {
        let match: (String, [String: String]) -> String?
        var result: String?
        init(_ match: @escaping (String, [String: String]) -> String?) { self.match = match }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if result == nil, let r = match(XLSX.local(name), attributes) { result = r; parser.abortParsing() }
        }
    }

    static func scan(_ data: Data, _ match: @escaping (String, [String: String]) -> String?) -> String? {
        let f = Finder(match)
        let p = XMLParser(data: data)
        p.delegate = f
        p.parse()
        return f.result
    }

    static func first(in data: Data, element: String, attribute: String) -> String? {
        scan(data) { name, attrs in name == element ? attrs[attribute] : nil }
    }

    static func target(in rels: Data, id: String) -> String? {
        scan(rels) { name, attrs in name == "Relationship" && attrs["Id"] == id ? attrs["Target"] : nil }
    }
}
