import CoreGraphics
import Foundation
import Testing
@testable import DocEngine

@Suite struct SpreadsheetTests {
    @Test func csvQuotingEdgeCases() {
        let csv = "\u{FEFF}name,qty,note\r\n\"Apple, red\",3,\"says \"\"hi\"\"\"\r\nPear,,\"multi\nline\"\r\n,,\r\n\"\",x,\r\nlast,1,end"
        let rows = Delimited.parse(csv, delimiter: ",")
        #expect(rows == [
            ["name", "qty", "note"],
            ["Apple, red", "3", "says \"hi\""],
            ["Pear", "", "multi\nline"],
            ["", "", ""],
            ["", "x", ""],
            ["last", "1", "end"],
        ])
    }

    @Test func lineEndingsAndBlankLines() {
        #expect(Delimited.parse("a,b\rc,d\r", delimiter: ",") == [["a", "b"], ["c", "d"]])
        #expect(Delimited.parse("a\n\nb\n", delimiter: ",") == [["a"], [""], ["b"]])
        #expect(Delimited.parse("", delimiter: ",") == [])
        #expect(Delimited.parse("x,\"q\"\"\"", delimiter: ",") == [["x", "q\""]])
        #expect(Delimited.parse("in\"side,ok", delimiter: ",") == [["in\"side", "ok"]], "quotes mid-field are literal")
    }

    @Test func writerQuotesOnlyWhenNeeded() {
        let rows = [["plain", "with,comma", "with \"quote\"", "multi\nline", "cr\rhere", ""], ["tab\there", " lead"]]
        let csv = Delimited.write(rows, delimiter: ",")
        #expect(csv.hasPrefix("plain,\"with,comma\",\"with \"\"quote\"\"\",\"multi\nline\",\"cr\rhere\",\r\n"))
        #expect(csv.hasSuffix("tab\there, lead\r\n"))
        #expect(Delimited.parse(csv, delimiter: ",") == rows)
        let tsv = Delimited.write(rows, delimiter: "\t")
        #expect(tsv.contains("\"tab\there\"\t lead\n"))
        #expect(tsv.hasPrefix("plain\twith,comma\twith \"quote\"\t\"multi\nline\""), "TSV quotes only structural fields")
        #expect(Delimited.write([["\"lead quote"]], delimiter: "\t") == "\"\"\"lead quote\"\n")
        #expect(Delimited.parse(tsv, delimiter: "\t") == rows)
    }

    @Test func csvTsvXlsxRoundTripThroughEngine() async throws {
        let dir = try W5.dir("sheets")
        let rows = [["name", "qty", "code", "note"], ["Apple", "3", "007", "red, sweet"], ["Pear", "5.5", "1e3", "says \"hi\""],
                    ["Ünïcode", "-2", "", "a & b < c"]]
        let csv = dir.appendingPathComponent("table.csv")
        try Delimited.write(rows, delimiter: ",").write(to: csv, atomically: true, encoding: .utf8)

        let tsv = try await W5.one(csv, to: "tsv")
        #expect(Delimited.parse(try W5.text(tsv), delimiter: "\t") == rows)

        let xlsx = try await W5.one(csv, to: "xlsx")
        #expect(W5.zipOK(xlsx))
        let sheet = try #require(W5.zipEntry(xlsx, "xl/worksheets/sheet1.xml"))
        #expect(sheet.contains("<c r=\"B2\"><v>3</v></c>"), "plain numbers are numeric cells")
        #expect(sheet.contains("<t>007</t>"), "leading zeros stay text")

        let back = try await W5.one(xlsx, to: "csv", out: dir.appendingPathComponent("back"))
        #expect(Delimited.parse(try W5.text(back), delimiter: ",") == rows)
        let backTSV = try await W5.one(xlsx, to: "tsv", out: dir.appendingPathComponent("back"))
        #expect(Delimited.parse(try W5.text(backTSV), delimiter: "\t") == rows)
    }

    @Test func readsSharedStringsAndSparseCells() async throws {
        let dir = try W5.dir("xlsx-read")
        var zip = ZipBuilder()
        zip.add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
        zip.add("xl/workbook.xml", """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets><sheet name="Data" sheetId="1" r:id="rId7"/></sheets></workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId7" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/data.xml"/>
        </Relationships>
        """)
        zip.add("xl/sharedStrings.xml", """
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">
        <si><t>Header</t></si><si><r><t>Rich </t></r><r><rPr><b/></rPr><t>text</t></r><rPh><t>IGNORED</t></rPh></si><si><t xml:space="preserve"> sp </t></si>
        </sst>
        """)
        zip.add("xl/worksheets/data.xml", """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>
        <row r="3"><c r="A3" t="b"><v>1</v></c><c r="B3"><v>2.5</v></c><c r="C3" t="str"><f>A1</f><v>calc</v></c><c r="D3" t="inlineStr"><is><t>inline</t></is></c></row>
        <row r="4"><c r="B4" t="s"><v>2</v></c></row>
        </sheetData></worksheet>
        """)
        let xlsx = dir.appendingPathComponent("book.xlsx")
        try zip.finish().write(to: xlsx)
        let csv = try await W5.one(xlsx, to: "csv")
        #expect(Delimited.parse(try W5.text(csv), delimiter: ",") == [
            ["Header", "", "Rich text", ""],
            ["", "", "", ""],
            ["TRUE", "2.5", "calc", "inline"],
            ["", " sp ", "", ""],
        ])
    }

    @Test func tableToPDF() async throws {
        let dir = try W5.dir("sheet-pdf")
        var rows = [["id", "name", "a long description column that needs truncation in narrow layouts", "value"]]
        for i in 1...150 { rows.append(["\(i)", "Item \(i)", String(repeating: "lorem ipsum ", count: 12), "\(i * 3)"]) }
        let csv = dir.appendingPathComponent("big.csv")
        try Delimited.write(rows, delimiter: ",").write(to: csv, atomically: true, encoding: .utf8)
        let pdf = try await W5.one(csv, to: "pdf")
        let doc = try #require(CGPDFDocument(pdf as CFURL))
        #expect(doc.numberOfPages >= 3)
    }

    @Test func columnRefs() {
        #expect(XLSX.column(of: "A1") == 0 && XLSX.column(of: "Z9") == 25 && XLSX.column(of: "AB12") == 27)
        #expect(XLSX.row(of: "AB12") == 11)
        #expect((0..<800).allSatisfy { XLSX.column(of: XLSX.columnName($0) + "1") == $0 })
        #expect(XLSX.isNumber("3") && XLSX.isNumber("-2.5") && XLSX.isNumber("1e3"))
        #expect(!XLSX.isNumber("007") && !XLSX.isNumber("1,000") && !XLSX.isNumber("+5") && !XLSX.isNumber("") && !XLSX.isNumber("NaN"))
    }
}
