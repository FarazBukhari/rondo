import AppKit
import CoreGraphics
import Foundation
import Testing
import RondoKit
@testable import DocEngine

/// Regression tests for the P7 review findings (hostile inputs). Numbers refer to the review items.
@Suite struct HardeningTests {
    // MARK: Helpers

    /// Minimal XLSX built in-process: workbook + rels + one sheet (+ optional shared strings / styles).
    func xlsx(_ dir: URL, name: String = "book.xlsx", sheet: String, shared: String? = nil, styles: String? = nil,
              workbookPr: String = "") throws -> URL {
        var zip = ZipBuilder()
        zip.add("xl/workbook.xml", """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\(workbookPr)<sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """)
        zip.add("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(sheet)</sheetData></worksheet>")
        if let shared { zip.add("xl/sharedStrings.xml", shared) }
        if let styles { zip.add("xl/styles.xml", styles) }
        let url = dir.appendingPathComponent(name)
        try zip.finish().write(to: url)
        return url
    }

    func expectInvalid(_ body: () throws -> Void, _ comment: Comment? = nil) {
        do { try body(); Issue.record("expected invalidInput \(comment.map { "\($0)" } ?? "")") } catch let e as EngineError {
            if case .invalidInput = e {} else { Issue.record("wrong error \(e)") }
        } catch { Issue.record("unexpected \(error)") }
    }

    // MARK: 1–2 XLSX references and size

    @Test func xlsxColumnLettersCapped() throws {
        let dir = try W5.dir("h-cols")
        #expect(XLSX.column(of: "XFD1") == 16_383)
        #expect(XLSX.column(of: "XFE1") == nil && XLSX.column(of: "AAAA1") == nil)
        #expect(XLSX.column(of: String(repeating: "Z", count: 40) + "1") == nil, "no Int overflow trap")
        let long = try xlsx(dir, name: "long.xlsx", sheet: "<row r=\"1\"><c r=\"\(String(repeating: "A", count: 30))1\"><v>1</v></c></row>")
        expectInvalid({ _ = try XLSX.read(long) })
        let xfe = try xlsx(dir, name: "xfe.xlsx", sheet: "<row r=\"1\"><c r=\"XFE1\"><v>1</v></c></row>")
        expectInvalid({ _ = try XLSX.read(xfe) })
        let xfd = try xlsx(dir, name: "xfd.xlsx", sheet: "<row r=\"1\"><c r=\"XFD1\"><v>1</v></c></row>")
        #expect(try XLSX.read(xfd).first?.count == 16_384)
    }

    @Test func xlsxSparseAndBounded() throws {
        let dir = try W5.dir("h-rows")
        let start = ContinuousClock.now
        let far = try xlsx(dir, name: "far.xlsx", sheet: "<row r=\"1000000000\"><c r=\"A1000000000\"><v>1</v></c></row>")
        expectInvalid({ _ = try XLSX.read(far) }, "row beyond 1,048,576")
        let area = try xlsx(dir, name: "area.xlsx", sheet: "<row r=\"1\"><c r=\"XFD1\"><v>1</v></c></row><row r=\"1000\"><c r=\"A1000\"><v>1</v></c></row>")
        expectInvalid({ _ = try XLSX.read(area) }, "16384 × 1000 output grid")
        #expect(ContinuousClock.now - start < .seconds(2), "rejection must not allocate the dense grid")

        let many = try xlsx(dir, name: "many.xlsx", sheet: (1...5).map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>" }.joined())
        var small = XLSX.Limits()
        small.maxCells = 4
        expectInvalid({ _ = try XLSX.read(many, limits: small) }, "cell count cap")
        #expect(try XLSX.read(many).count == 5)
    }

    // MARK: 3 Subtitle timestamps

    @Test func hostileTimestamps() {
        for bad in ["inf", "nan", "1e308", "00:00:1e308", "99999999999:00:00", "00:00:inf", "-1:00:00", "00:00:-5"] {
            #expect(Subtitles.timestamp(bad) == nil, "\(bad)")
        }
        let cues = Subtitles.parse("1\n00:00:01,000 --> 99999999999:00:00,000\nhuge\n\n2\n00:00:02,000 --> 00:00:03,000\nok\n")
        #expect(cues.map(\.lines) == [["ok"]] || cues.allSatisfy { $0.end.isFinite && $0.end <= Subtitles.maxSeconds })
        for t in [Double.infinity, -Double.infinity, .nan, 1e300, -5] { _ = Subtitles.stamp(t, sep: ",") }   // must not trap
        #expect(Subtitles.stamp(1e300, sep: ".") == Subtitles.stamp(Subtitles.maxSeconds, sep: "."))
    }

    // MARK: 4 ZIP symlinks

    @Test func zipSymlinkTraversalRejected() async throws {
        let dir = try W5.dir("h-ziplink")
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let cases: [(String, [[String: Any]])] = [
            ("abs", [["name": "l", "data": outside.path, "symlink": true], ["name": "l/f.txt", "data": "pwned"]]),
            ("dotdot", [["name": "l", "data": "../../outside", "symlink": true]]),
            ("through-relative", [["name": "sub/", "data": ""], ["name": "l", "data": "sub", "symlink": true], ["name": "l/f.txt", "data": "x"]]),
            ("case-variant", [["name": "l", "data": "sub", "symlink": true], ["name": "L/f.txt", "data": "x"]]),
        ]
        for (label, spec) in cases {
            let zip = dir.appendingPathComponent("\(label).zip")
            try W5.pyzip(zip, spec)
            await #expect(throws: EngineError.self, "\(label)") { try await W5.one(zip, to: "folder", out: dir.appendingPathComponent("out-\(label)")) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        // Benign relative link inside the archive is fine.
        let ok = dir.appendingPathComponent("ok.zip")
        try W5.pyzip(ok, [["name": "a.txt", "data": "A"], ["name": "rel", "data": "a.txt", "symlink": true]])
        let out = try await W5.one(ok, to: "folder", out: dir.appendingPathComponent("out-ok"))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("a.txt").path))
    }

    /// Documents what `ditto -x -k` itself does with `l -> <outside>` + `l/f.txt` on this macOS (without our pre-scan):
    /// it writes `l` as a plain file holding the target path and then fails on `l/f.txt` ("Not a directory"),
    /// so nothing lands outside. We don't rely on it — the pre-scan rejects such archives first.
    @Test func dittoBehaviourOnSymlinkTraversal() throws {
        let dir = try W5.dir("h-ditto")
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        let dest = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("evil.zip")
        try W5.pyzip(zip, [["name": "l", "data": outside.path, "symlink": true], ["name": "l/f.txt", "data": "pwned"]])
        let (code, _) = W5.sh("/usr/bin/ditto", ["-x", "-k", zip.path, dest.path])
        #expect(code != 0, "ditto fails on the traversal entry")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "nothing written through the link")
        let l = dest.appendingPathComponent("l")
        let isLink = (try? l.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        #expect(!isLink, "ditto materialized the link entry as a regular file")
    }

    // MARK: 5 TAR hardlinks / symlinks

    @Test func tarLinksRejected() async throws {
        let dir = try W5.dir("h-tarlink")
        let cases: [(String, [(name: String, data: Data, link: (type: String, target: String)?)])] = [
            ("hard-abs", [("a.txt", Data("a".utf8), nil), ("h", Data(), ("1", "/etc/hosts"))]),
            ("hard-dotdot", [("a.txt", Data("a".utf8), nil), ("h", Data(), ("1", "../outside.txt"))]),
            ("sym-through", [("sub/x", Data("x".utf8), nil), ("l", Data(), ("2", "sub")), ("l/y", Data("y".utf8), nil)]),
        ]
        for (label, entries) in cases {
            let tar = dir.appendingPathComponent("\(label).tar")
            try W5.ustarLinks(entries).write(to: tar)
            await #expect(throws: EngineError.self, "\(label)") { try await W5.one(tar, to: "folder") }
        }
        // bsdtar-made archive with a `..` symlink is refused before extraction.
        let src = dir.appendingPathComponent("src/pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "x".write(to: src.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("up").path, withDestinationPath: "../..")
        let made = dir.appendingPathComponent("made.tar")
        #expect(W5.sh("/usr/bin/tar", ["-cf", made.path, "-C", src.deletingLastPathComponent().path, "pkg"]).0 == 0)
        await #expect(throws: EngineError.self) { try await W5.one(made, to: "folder") }
        // A safe internal hardlink is fine.
        let ok = dir.appendingPathComponent("ok.tar")
        try W5.ustarLinks([("a.txt", Data("a".utf8), nil), ("b.txt", Data(), ("1", "a.txt"))]).write(to: ok)
        let out = try await W5.one(ok, to: "folder")
        #expect(try String(contentsOf: out.appendingPathComponent("b.txt"), encoding: .utf8) == "a")
    }

    @Test func listingCandidatesAreConservative() {
        #expect(Archives.candidates(after: " -> ", in: "lrwx 0 u g 0 Oct 21 13:12 a -> b -> /etc") == ["b -> /etc", "/etc"])
        #expect(Archives.tarSize("-rw-r--r--  0 me  staff  12345 Oct 21 13:12 a b.txt") == 12345)
        #expect(Archives.tarSize("-rw-r--r--  0 me  staff  7 Jan  2  2024 old.txt") == 7)
    }

    // MARK: 6 XLSX symlink / oversized members

    @Test func xlsxSymlinkMemberRejected() throws {
        let dir = try W5.dir("h-xlsxlink")
        let start = ContinuousClock.now
        for target in ["/dev/zero", NSHomeDirectory() + "/Library/Preferences/.GlobalPreferences.plist"] {
            let book = dir.appendingPathComponent("link-\(target.count).xlsx")
            try W5.pyzip(book, [
                ["name": "xl/workbook.xml", "data": "<workbook><sheets><sheet r:id=\"rId1\" xmlns:r=\"r\"/></sheets></workbook>"],
                ["name": "xl/worksheets/sheet1.xml", "data": target, "symlink": true],
            ])
            expectInvalid({ _ = try XLSX.read(book) }, "symlink -> \(target)")
        }
        // Deadlock/unbounded-read guard, loose for full-suite load (typically < 0.1 s).
        #expect(ContinuousClock.now - start < .seconds(60), "never reads /dev/zero")

        let big = try xlsx(dir, name: "big.xlsx", sheet: "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>\(String(repeating: "x", count: 100_000))</t></is></c></row>")
        var small = XLSX.Limits()
        small.maxMemberBytes = 10_000
        expectInvalid({ _ = try XLSX.read(big, limits: small) }, "member size cap")
    }

    // MARK: 7 chained relative links

    @Test func chainedRelativeLinksRemoved() throws {
        let root = try W5.dir("h-chain")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("d"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("d/e").path, withDestinationPath: "..")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("s").path, withDestinationPath: "d/e/../..")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("ok").path, withDestinationPath: "d")
        try Archives.removeEscapingLinks(in: root)
        #expect(Set(try fm.contentsOfDirectory(atPath: root.path)) == ["d", "ok"])
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("d").path).isEmpty)
    }

    // MARK: 8 Bombs

    @Test func extractionCaps() async throws {
        let dir = try W5.dir("h-bomb")
        let cap: [String: OptionValue] = ["maxExtractBytes": .int(1_000_000)]
        let zip = dir.appendingPathComponent("bomb.zip")
        try W5.pyzip(zip, [["name": "zeros.bin", "zeros": 3_000_000]])
        #expect(DocSupport.fileSize(zip) < 100_000)
        await #expect(throws: EngineError.self) { try await W5.convert(zip, to: "folder", options: cap) }

        let many = dir.appendingPathComponent("many.zip")
        try W5.pyzip(many, (1...5).map { ["name": "f\($0).txt", "data": "x"] })
        await #expect(throws: EngineError.self) { try await W5.convert(many, to: "folder", options: ["maxExtractEntries": .int(3)]) }

        let big = dir.appendingPathComponent("big.tar")
        try W5.ustar([("zeros.bin", Data(count: 2_000_000), nil)]).write(to: big)
        await #expect(throws: EngineError.self) { try await W5.convert(big, to: "folder", options: cap) }

        // Two-member gzip: the ISIZE trailer only describes the tiny last member, so the pre-check passes and
        // the watchdog / final size check has to stop it (gzip itself accepts the file).
        let raw = dir.appendingPathComponent("zeros.bin")
        try Data(count: 4_000_000).write(to: raw)
        let tiny = try W5.write("x", to: dir, name: "tiny.txt")
        #expect(W5.sh("/usr/bin/gzip", ["-k", raw.path]).0 == 0 && W5.sh("/usr/bin/gzip", ["-k", tiny.path]).0 == 0)
        let gz = dir.appendingPathComponent("bomb.bin.gz")
        try (Data(contentsOf: dir.appendingPathComponent("zeros.bin.gz")) + Data(contentsOf: dir.appendingPathComponent("tiny.txt.gz"))).write(to: gz)
        #expect(Archives.gzipDeclaredSize(gz) == 1)
        #expect(W5.sh("/usr/bin/gzip", ["-t", gz.path]).0 == 0, "valid multi-member gzip")
        let out = dir.appendingPathComponent("gz-out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        await #expect(throws: EngineError.invalidInput("bomb.bin.gz expands beyond the 1 MB limit; extraction stopped")) {
            try await W5.convert(gz, to: "folder", out: out, options: cap)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty, "nothing committed")

        // Under the cap everything still works.
        let fine = try await W5.convert(zip, to: "folder", out: dir.appendingPathComponent("fine"), options: ["maxExtractBytes": .int(5_000_000)])
        #expect(fine.count == 1)
    }

    // MARK: 9 Number formats

    @Test func xlsxDatesAndPercents() throws {
        let dir = try W5.dir("h-fmt")
        let styles = """
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="4"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd hh:mm"/><numFmt numFmtId="165" formatCode="[h]:mm:ss"/><numFmt numFmtId="166" formatCode="0.0"/><numFmt numFmtId="167" formatCode="[Red]0.0%;&quot;neg&quot;"/></numFmts>
        <cellXfs count="8"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="10"/><xf numFmtId="164"/><xf numFmtId="165"/><xf numFmtId="166"/><xf numFmtId="21"/><xf numFmtId="167"/></cellXfs>
        </styleSheet>
        """
        let sheet = """
        <row r="1"><c r="A1" s="1"><v>45000</v></c><c r="B1" s="2"><v>0.1234</v></c><c r="C1" s="3"><v>45000.5</v></c><c r="D1" s="4"><v>1.5</v></c></row>
        <row r="2"><c r="A2" s="5"><v>3.14159</v></c><c r="B2" s="6"><v>0.75</v></c><c r="C2" s="7"><v>0.25</v></c><c r="D2" s="0"><v>45000</v></c></row>
        <row r="3"><c r="A3" s="1" t="s"><v>0</v></c><c r="B3" s="99"><v>7</v></c><c r="C3" s="1"><v>1</v></c><c r="D3" s="1"><v>-3</v></c></row>
        """
        let book = try xlsx(dir, sheet: sheet, shared: "<sst><si><t>text</t></si></sst>", styles: styles)
        #expect(try XLSX.read(book) == [
            ["2023-03-15", "12.34%", "2023-03-15 12:00:00", "36:00:00"],
            ["3.14159", "18:00:00", "25.0%", "45000"],
            ["text", "7", "1900-01-01", "-3"],
        ])
        let b1904 = try xlsx(dir, name: "1904.xlsx", sheet: "<row r=\"1\"><c r=\"A1\" s=\"1\"><v>0</v></c></row>", styles: styles,
                             workbookPr: "<workbookPr date1904=\"1\"/>")
        #expect(try XLSX.read(b1904) == [["1904-01-01"]])
        #expect(XLSX.classify(id: 168, code: "mmm\\-yy") == .date)
        #expect(XLSX.classify(id: 169, code: "mm:ss") == .time)
        #expect(XLSX.classify(id: 170, code: "#,##0.00") == nil)
        #expect(XLSX.classify(id: 171, code: "\"day\"0") == nil, "quoted literals ignored")
    }

    // MARK: 10 Dash-leading names

    @Test func dashLeadingNames() async throws {
        let dir = try W5.dir("h-dash")
        let folder = dir.appendingPathComponent("-rf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let file = try W5.write("y", to: dir, name: "-v.txt")
        for (input, target) in [(folder, "tar"), (folder, "tar.gz"), (folder, "zip"), (file, "gz"), (file, "tar.gz"), (file, "zip")] {
            let out = try await W5.one(input, to: target, out: dir.appendingPathComponent("out"))
            #expect(out.lastPathComponent.hasPrefix("-"), "\(input.lastPathComponent) → \(target)")
        }
        let back = try await W5.one(dir.appendingPathComponent("out/-rf.tar.gz"), to: "folder", out: dir.appendingPathComponent("back"))
        #expect(try String(contentsOf: back.appendingPathComponent("f.txt"), encoding: .utf8) == "x")
    }

    // MARK: 11 DPI clamp

    @Test func rasterizeClampsDPI() throws {
        let dir = try W5.dir("h-dpi")
        let pdf = dir.appendingPathComponent("p.pdf")
        try PDFWriter.write(NSAttributedString(string: "page"), to: pdf, pageSize: CGSize(width: 72, height: 72), margin: 8, info: .init())
        for (dpi, side) in [(1e12, 600), (Double.nan, 150), (1, 36), (Double.infinity, 150)] {
            let files = try PDFWriter.rasterize(pdf, format: "png", dpi: dpi, quality: 1, into: dir.appendingPathComponent("o\(side)-\(UUID().uuidString.prefix(4))"))
            let img = try #require(CGImageSourceCreateWithURL(files[0] as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            #expect(img.width == side, "dpi \(dpi)")
        }
    }

    // MARK: 12 Malformed XML

    @Test func malformedXLSXPartsRejected() throws {
        let dir = try W5.dir("h-xml")
        let truncated = try xlsx(dir, name: "trunc.xlsx", sheet: "<row r=\"1\"><c r=\"A1\"><v>1</v></c></row><row r=\"2\"><c r=\"A2\"><v>2")
        expectInvalid({ _ = try XLSX.read(truncated) }, "truncated sheet")
        let badShared = try xlsx(dir, name: "shared.xlsx", sheet: "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row>", shared: "<sst><si><t>x</si></sst>")
        expectInvalid({ _ = try XLSX.read(badShared) }, "malformed shared strings")
    }

    // MARK: 13 Probe locking

    @Test func slowProbeDoesNotBlockOtherKeys() {
        let key = "test-slow-\(UUID().uuidString)"
        let started = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = Probe.once(key) { started.signal(); Thread.sleep(forTimeInterval: 1.5); return true }
        }
        started.wait()
        let t0 = ContinuousClock.now
        #expect(Probe.once("test-fast-\(UUID().uuidString)") { true })
        #expect(ContinuousClock.now - t0 < .milliseconds(500))
        #expect(Probe.once(key) { false }, "second caller of the same key waits for and reuses the first result")
    }

    // MARK: 14 soffice works on a clone

    @Test func sofficeConvertsAClone() async throws {
        let dir = try W5.dir("h-soffice")
        let original = dir.appendingPathComponent("orig", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let deck = try W5.write("fake deck", to: original, name: "deck.pptx")
        let canned = dir.appendingPathComponent("canned.pdf")
        try PDFWriter.write(NSAttributedString(string: String(repeating: "slide ", count: 400)), to: canned,
                            pageSize: CGSize(width: 144, height: 72), margin: 4, info: .init())
        let log = dir.appendingPathComponent("soffice.log")
        let fake = dir.appendingPathComponent("fake-soffice")
        try """
        #!/bin/sh
        out=""; last=""
        while [ $# -gt 0 ]; do
          case "$1" in --outdir) out="$2"; shift 2;; *) last="$1"; shift;; esac
        done
        echo "$last" > '\(log.path)'
        touch "$(dirname "$last")/.~lock.$(basename "$last")#"
        cp '\(canned.path)' "$out/$(basename "${last%.*}").pdf"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let temp = try TempDir.make(prefix: "w5test")
        defer { TempDir.remove(temp) }
        let out = dir.appendingPathComponent("out", isDirectory: true)
        let ctx = JobContext(tools: ToolLocator(overrides: ["soffice": fake.path], bundleBin: nil), tempDir: temp, destination: .folder(out))
        let job = JobSpec(inputs: [deck], operation: .convert(to: "png"), options: ["dpi": .int(1_000_000)], destination: .folder(out))
        let result = try await Slides.convert(deck, from: "pptx", to: "png", job: job, context: ctx, progress: { _ in })
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.path) == ["deck.pptx"], "no lock file beside the original")
        let used = try String(contentsOf: log, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(used != deck.path && used.hasSuffix("/deck.pptx"))
        let firstPage = try FileManager.default.contentsOfDirectory(at: result, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }[0]
        let img = try #require(CGImageSourceCreateWithURL(firstPage as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(img.width == 1200, "dpi clamped to 600 (144 pt wide)")
    }
}
