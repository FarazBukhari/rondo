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
    // Reading lives in XLSXReader.swift.

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

}
