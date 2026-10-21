import Foundation
import RondoKit

/// XLSX → rows of display strings. Parts are read in memory via `ZipReader` (size-capped, symlink members
/// refused); the sheet is stored sparsely and bounded by Excel's own limits before anything dense is built.
extension XLSX {
    struct Limits {
        var maxRows = 1_048_576
        var maxColumns = 16_384
        var maxCells = 5_000_000          // non-empty cells
        var maxArea = 10_000_000          // rows × columns of the output grid
        var maxMemberBytes = 256 << 20    // per XML part, uncompressed
        static let `default` = Limits()
    }

    // MARK: Read

    /// First worksheet: shared/inline strings, numbers (dates/times/percents formatted per cell style),
    /// booleans and cached formula results.
    static func read(_ url: URL, limits: Limits = .default) throws -> [[String]] {
        try DocSupport.requireInput(url)
        let name = url.lastPathComponent
        let entries: [ZipEntry]
        do { entries = try ZipReader.entries(url, maxEntries: 100_000) } catch let f as ZipReader.Failure {
            throw EngineError.invalidInput("\(name) isn't a readable XLSX (\(f.description))")
        }
        var byName: [String: ZipEntry] = [:]
        for e in entries where byName[e.name] == nil { byName[e.name] = e }

        func member(_ path: String) throws -> Data? {
            guard let e = byName[path] else { return nil }
            if e.isSymlink { throw EngineError.invalidInput("\(name) contains a symbolic link (\(path)); not read") }
            do { return try ZipReader.read(url, entry: e, maxBytes: limits.maxMemberBytes) } catch let f as ZipReader.Failure {
                throw EngineError.invalidInput("\(name): \(f.description)")
            }
        }

        let workbook = try member("xl/workbook.xml")
        let sheetPath = try firstSheetPath(workbook: workbook, rels: try member("xl/_rels/workbook.xml.rels"),
                                           names: Set(byName.keys))
        guard let sheet = try member(sheetPath) else { throw EngineError.invalidInput("\(name) has no worksheet") }
        let shared = try member("xl/sharedStrings.xml").map { try SharedStrings.parse($0) } ?? []
        let styles = try member("xl/styles.xml").map { try Styles.parse($0) } ?? Styles()
        let date1904 = workbook.flatMap { AttrScanner.first(in: $0, element: "workbookPr", attribute: "date1904") }
            .map { $0 == "1" || $0.lowercased() == "true" } ?? false
        return try Sheet.parse(sheet, shared: shared, styles: styles, date1904: date1904, limits: limits)
    }

    /// Workbook → first `<sheet r:id>` → rels target, resolved lexically inside the package; else sheet1.xml / first sheet.
    static func firstSheetPath(workbook: Data?, rels: Data?, names: Set<String>) throws -> String {
        if let workbook, let rels,
           let rid = AttrScanner.first(in: workbook, element: "sheet", attribute: "r:id") ?? AttrScanner.first(in: workbook, element: "sheet", attribute: "id"),
           let target = AttrScanner.target(in: rels, id: rid) {
            let raw = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            var parts: [Substring] = []
            for p in raw.split(separator: "/") {
                if p == "." { continue }
                if p == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
                parts.append(p)
            }
            let path = parts.joined(separator: "/")
            if names.contains(path) { return path }
        }
        if names.contains("xl/worksheets/sheet1.xml") { return "xl/worksheets/sheet1.xml" }
        if let any = names.filter({ $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") && !$0.dropFirst(14).contains("/") }).sorted().first {
            return any
        }
        throw EngineError.invalidInput("No worksheet found")
    }

    /// "AB12" → zero-based column 27. nil for no letters, more than 3 letters, or beyond XFD (16384).
    static func column(of ref: String) -> Int? {
        var n = 0
        var letters = 0
        for c in ref.unicodeScalars {
            let v = c.value | 0x20   // ASCII lowercase
            guard v >= 97 && v <= 122 else { break }
            letters += 1
            if letters > 3 { return nil }
            n = n * 26 + Int(v - 96)
        }
        guard letters > 0, n <= 16_384 else { return nil }
        return n - 1
    }

    /// "AB12" → zero-based row 11. nil when missing or out of Int range.
    static func row(of ref: String) -> Int? {
        let digits = ref.drop { $0.isLetter }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let v = Int(digits), v >= 1 else { return nil }
        return v - 1
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

    static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    // MARK: Shared strings

    final class SharedStrings: NSObject, XMLParserDelegate {
        var items: [String] = []
        private var current = ""
        private var inSI = false, inT = false, inPhonetic = false

        static func parse(_ data: Data) throws -> [String] {
            let d = SharedStrings()
            let p = XMLParser(data: data)
            p.delegate = d
            guard p.parse() else { throw EngineError.invalidInput("Malformed shared strings XML (\(p.parserError?.localizedDescription ?? "parse error"))") }
            return d.items
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch XLSX.local(name) {
            case "si": inSI = true; current = ""
            case "t": inT = true
            case "rPh": inPhonetic = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch XLSX.local(name) {
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

    // MARK: Styles (number formats)

    enum NumberKind: Equatable {
        case date, time, dateTime, elapsed
        case percent(decimals: Int)
    }

    final class Styles: NSObject, XMLParserDelegate {
        var customFormats: [Int: String] = [:]
        var cellFormatIDs: [Int] = []   // cellXfs index → numFmtId
        private var inCellXfs = false

        static func parse(_ data: Data) throws -> Styles {
            let s = Styles()
            let p = XMLParser(data: data)
            p.delegate = s
            guard p.parse() else { throw EngineError.invalidInput("Malformed styles XML (\(p.parserError?.localizedDescription ?? "parse error"))") }
            return s
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch XLSX.local(name) {
            case "numFmt":
                if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] { customFormats[id] = code }
            case "cellXfs": inCellXfs = true
            case "xf" where inCellXfs && cellFormatIDs.count < 1_000_000:
                cellFormatIDs.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if XLSX.local(name) == "cellXfs" { inCellXfs = false }
        }

        func kind(style: Int) -> NumberKind? {
            guard style >= 0, style < cellFormatIDs.count else { return nil }
            let id = cellFormatIDs[style]
            return XLSX.classify(id: id, code: customFormats[id])
        }
    }

    /// Built-in date/time/percent ids, else inspects the custom format code (literals and [colors] stripped).
    static func classify(id: Int, code: String?) -> NumberKind? {
        switch id {
        case 14, 15, 16, 17: return .date
        case 18, 19, 20, 21, 45, 47: return .time
        case 22: return .dateTime
        case 46: return .elapsed
        case 9: return .percent(decimals: 0)
        case 10: return .percent(decimals: 2)
        default: break
        }
        guard let code, !code.isEmpty else { return nil }
        let section = String(code.split(separator: ";", omittingEmptySubsequences: false).first ?? "")
        var plain = ""
        var elapsed = false
        var i = section.startIndex
        while i < section.endIndex {
            let c = section[i]
            switch c {
            case "\"":
                let rest = section[section.index(after: i)...]
                i = rest.firstIndex(of: "\"").map { section.index(after: $0) } ?? section.endIndex
                continue
            case "\\", "_", "*":
                i = section.index(i, offsetBy: 2, limitedBy: section.endIndex) ?? section.endIndex
                continue
            case "[":
                let close = section[i...].firstIndex(of: "]") ?? section.endIndex
                let inner = section[section.index(after: i)..<close].lowercased()
                if !inner.isEmpty, inner.allSatisfy({ $0 == "h" || $0 == "m" || $0 == "s" }) { elapsed = true }
                i = close < section.endIndex ? section.index(after: close) : close
                continue
            default:
                plain.append(c)
            }
            i = section.index(after: i)
        }
        let lower = plain.lowercased()
        if lower.contains("%") {
            let decimals = lower.split(separator: ".", maxSplits: 1).dropFirst().first.map { $0.prefix { $0 == "0" || $0 == "#" }.count } ?? 0
            return .percent(decimals: decimals)
        }
        if lower == "general" { return nil }
        let hasDate = lower.contains("d") || lower.contains("y")
        let hasTime = lower.contains("h") || lower.contains("s")
        if elapsed { return .elapsed }
        if hasDate && hasTime { return .dateTime }
        if hasDate { return .date }
        if hasTime { return .time }
        return nil
    }

    /// Formats a numeric cell: ISO `yyyy-MM-dd`, `HH:mm:ss`, `yyyy-MM-dd HH:mm:ss`, elapsed `H:mm:ss`, or `x%`.
    static func format(_ raw: String, kind: NumberKind, date1904: Bool) -> String {
        guard let v = Double(raw.trimmingCharacters(in: .whitespaces)), v.isFinite else { return raw }
        switch kind {
        case .percent(let d):
            return String(format: "%.\(min(d, 10))f%%", v * 100)
        case .elapsed:
            guard abs(v) < 1e7 else { return raw }
            let total = Int((abs(v) * 86_400).rounded())
            return (v < 0 ? "-" : "") + String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        case .date, .time, .dateTime:
            guard v >= 0, v < 2_958_466 else { return raw }   // through 9999-12-31
            var days = Int(v.rounded(.down))
            var secs = Int(((v - Double(days)) * 86_400).rounded())
            if secs >= 86_400 { days += 1; secs -= 86_400 }
            let time = String(format: "%02d:%02d:%02d", secs / 3600, (secs / 60) % 60, secs % 60)
            if kind == .time { return time }
            // 1900 system: serial 1 = 1900-01-01 and Excel's phantom 1900-02-29 is serial 60.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let base = date1904 ? DateComponents(year: 1904, month: 1, day: 1)
                : (days < 60 ? DateComponents(year: 1899, month: 12, day: 31) : DateComponents(year: 1899, month: 12, day: 30))
            guard let start = cal.date(from: base), let date = cal.date(byAdding: .day, value: days, to: start) else { return raw }
            let c = cal.dateComponents([.year, .month, .day], from: date)
            let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            return kind == .date ? day : day + " " + time
        }
    }

    // MARK: Sheet

    final class Sheet: NSObject, XMLParserDelegate {
        private var cells: [Int: [Int: String]] = [:]    // sparse: row → column → text
        private var cellCount = 0
        private let shared: [String]
        private let styles: Styles
        private let date1904: Bool
        private let limits: Limits
        private var rowIndex = -1
        private var colIndex = -1
        private var type = ""
        private var style = -1
        private var value = ""
        private var inlineText = ""
        private var inV = false, inT = false, inIS = false
        private var maxRow = -1, maxCol = -1
        private(set) var failure: String?

        init(shared: [String], styles: Styles, date1904: Bool, limits: Limits) {
            self.shared = shared
            self.styles = styles
            self.date1904 = date1904
            self.limits = limits
        }

        static func parse(_ data: Data, shared: [String], styles: Styles = Styles(), date1904: Bool = false,
                          limits: Limits = .default) throws -> [[String]] {
            let s = Sheet(shared: shared, styles: styles, date1904: date1904, limits: limits)
            let p = XMLParser(data: data)
            p.delegate = s
            let ok = p.parse()
            if let f = s.failure { throw EngineError.invalidInput(f) }
            guard ok else { throw EngineError.invalidInput("Malformed worksheet XML (\(p.parserError?.localizedDescription ?? "parse error"))") }
            guard s.maxRow >= 0, s.maxCol >= 0 else { return [] }
            let rows = s.maxRow + 1, cols = s.maxCol + 1
            guard rows.multipliedReportingOverflow(by: cols).partialValue <= limits.maxArea, rows <= limits.maxRows, cols <= limits.maxColumns else {
                throw EngineError.invalidInput("Worksheet spans \(rows) rows × \(cols) columns, over the \(limits.maxArea)-cell limit")
            }
            return (0..<rows).map { r in
                guard let row = s.cells[r] else { return Array(repeating: "", count: cols) }
                return (0..<cols).map { row[$0] ?? "" }
            }
        }

        private func fail(_ parser: XMLParser, _ message: String) {
            if failure == nil { failure = message }
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard failure == nil else { return }
            switch XLSX.local(name) {
            case "row":
                if let r = attributes["r"] {
                    guard let n = Int(r), n >= 1, n <= limits.maxRows else { return fail(parser, "Row \(r.prefix(20)) is outside the sheet limits") }
                    rowIndex = n - 1
                } else {
                    rowIndex += 1
                }
                colIndex = -1
            case "c":
                if let ref = attributes["r"], !ref.isEmpty {
                    guard let c = XLSX.column(of: ref) else { return fail(parser, "Cell reference \(ref.prefix(20)) is outside the sheet limits") }
                    colIndex = c
                    if ref.contains(where: \.isNumber) {
                        guard let r = XLSX.row(of: ref), r < limits.maxRows else { return fail(parser, "Cell reference \(ref.prefix(20)) is outside the sheet limits") }
                        rowIndex = r
                    }
                } else {
                    colIndex += 1
                }
                guard colIndex < limits.maxColumns, rowIndex < limits.maxRows else { return fail(parser, "Worksheet exceeds \(limits.maxColumns) columns or \(limits.maxRows) rows") }
                type = attributes["t"] ?? ""
                style = attributes["s"].flatMap(Int.init) ?? -1
                value = ""; inlineText = ""
            case "v": inV = true
            case "is": inIS = true
            case "t" where inIS: inT = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard failure == nil else { return }
            switch XLSX.local(name) {
            case "v": inV = false
            case "t": inT = false
            case "is": inIS = false
            case "c":
                let display: String
                switch type {
                case "s": display = Int(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 && $0 < shared.count ? shared[$0] : nil } ?? ""
                case "inlineStr": display = inlineText
                case "b": display = value == "1" ? "TRUE" : (value.isEmpty ? "" : "FALSE")
                case "", "n": display = styles.kind(style: style).map { XLSX.format(value, kind: $0, date1904: date1904) } ?? value
                default: display = value
                }
                if !display.isEmpty, rowIndex >= 0, colIndex >= 0 {
                    if cells[rowIndex]?[colIndex] == nil {
                        cellCount += 1
                        guard cellCount <= limits.maxCells else { return fail(parser, "Worksheet has more than \(limits.maxCells) cells") }
                    }
                    cells[rowIndex, default: [:]][colIndex] = display
                    maxRow = max(maxRow, rowIndex); maxCol = max(maxCol, colIndex)
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard failure == nil else { return }
            if inV { value += string } else if inIS && inT { inlineText += string }
        }
    }
}

/// Tiny attribute scanner for workbook.xml / rels (stops at the first match). Malformed XML → nil (callers fall back).
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
        p.parse()   // false after abortParsing on a hit; a malformed document simply yields no result
        return f.result
    }

    static func first(in data: Data, element: String, attribute: String) -> String? {
        scan(data) { name, attrs in name == element ? attrs[attribute] : nil }
    }

    static func target(in rels: Data, id: String) -> String? {
        scan(rels) { name, attrs in name == "Relationship" && attrs["Id"] == id ? attrs["Target"] : nil }
    }
}
