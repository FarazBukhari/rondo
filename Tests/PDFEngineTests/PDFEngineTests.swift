import AppKit
import Foundation
import PDFKit
import Testing
import RondoKit
@testable import PDFEngine

private let threePages = ["Alpha page one. The quick brown fox.", "Bravo page two. Jumps over the lazy dog.", "Charlie page three. The end."]

@Suite struct PDFCapabilityTests {
    @Test func descriptorsAndPairs() {
        let e = PDFDocumentEngine()
        let pairs = Set(e.conversions().map { "\($0.from)>\($0.to)" })
        #expect(pairs == ["pdf>jpg", "pdf>png", "pdf>txt", "pdf>md", "pdf>docx", "pdf>epub", "txt>pdf", "txt>jpg", "txt>png"])
        let ids = Set(e.tools().map(\.id.rawValue))
        #expect(ids == ["pdf.compress", "pdf.merge", "pdf.split", "pdf.reorder", "pdf.text.extract", "pdf.metadata.strip"])
        #expect(e.tools().filter(\.needsUI).map(\.id.rawValue) == ["pdf.reorder"])
        #expect(e.tools().first { $0.id == "pdf.merge" }?.multiInput == .combine(minimum: 2))
    }
}

@Suite struct PDFConversionTests {
    @Test func pdfToImagesMultiPageFolder() async throws {
        let dir = try PFx.dir("raster")
        defer { PFx.cleanup(dir) }
        let src = dir.appendingPathComponent("doc.pdf")
        PFx.makePDF(threePages, at: src)
        let out = try await PDFDocumentEngine().runTest(JobSpec(inputs: [src], operation: .convert(to: "png")))
        #expect(out.count == 1)
        #expect(out[0].lastPathComponent == "doc (pages)")
        let files = try FileManager.default.contentsOfDirectory(atPath: out[0].path).sorted()
        #expect(files == ["Page 1.png", "Page 2.png", "Page 3.png"])
        let img = try #require(PFx.load(out[0].appendingPathComponent("Page 1.png")))
        #expect(img.width == 833 && img.height == 1083)      // 200×260 pt @ 300 DPI
        #expect(PFx.isRed(PFx.pixel(img, 20, 20)))

        let jpg = try await PDFDocumentEngine().runTest(JobSpec(inputs: [src], operation: .convert(to: "jpg"), options: ["dpi": .int(72)]))
        #expect(jpg[0].lastPathComponent == "doc (pages) 2")
        let j = try #require(PFx.load(jpg[0].appendingPathComponent("Page 2.jpg")))
        #expect(j.width == 200 && j.height == 260)
    }

    @Test func singlePagePDFGivesSingleImage() async throws {
        let dir = try PFx.dir("single")
        defer { PFx.cleanup(dir) }
        let src = dir.appendingPathComponent("one.pdf")
        PFx.makePDF(["Only page"], at: src)
        let out = try await PDFDocumentEngine().runTest(JobSpec(inputs: [src], operation: .convert(to: "jpg"), options: ["dpi": .int(144)]))
        #expect(out[0].lastPathComponent == "one.jpg")
        #expect(PFx.load(out[0])?.width == 400)
    }

    @Test func pdfToTextAndMarkdown() async throws {
        let dir = try PFx.dir("text")
        defer { PFx.cleanup(dir) }
        let src = dir.appendingPathComponent("doc.pdf")
        PFx.makePDF(threePages, at: src, title: "Test Doc")
        let e = PDFDocumentEngine()
        let txt = try await e.runTest(JobSpec(inputs: [src], operation: .convert(to: "txt")))
        #expect(txt[0].lastPathComponent == "doc.txt")
        let t = try String(contentsOf: txt[0], encoding: .utf8)
        let a = try #require(t.range(of: "Alpha page one")), b = try #require(t.range(of: "Bravo page two")), c = try #require(t.range(of: "Charlie page three"))
        #expect(a.lowerBound < b.lowerBound && b.lowerBound < c.lowerBound)

        let md = try await e.runTest(JobSpec(inputs: [src], operation: .convert(to: "md")))
        let m = try String(contentsOf: md[0], encoding: .utf8)
        #expect(m.hasPrefix("# Test Doc\n"))
        #expect(m.contains("## Page 1") && m.contains("## Page 3"))
        #expect(m.contains("Bravo page two"))

        let extracted = try await e.runTest(JobSpec(inputs: [src], operation: .tool("pdf.text.extract")))
        #expect(extracted[0].lastPathComponent == "doc 2.txt")
    }

    @Test func pdfToDocx() async throws {
        let dir = try PFx.dir("docx")
        defer { PFx.cleanup(dir) }
        let src = dir.appendingPathComponent("doc.pdf")
        PFx.makePDF(threePages, at: src)
        let out = try await PDFDocumentEngine().runTest(JobSpec(inputs: [src], operation: .convert(to: "docx")))
        #expect(out[0].pathExtension == "docx")
        let back = try NSAttributedString(url: out[0], options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(back.string.contains("Alpha page one"))
        #expect(back.string.contains("Charlie page three"))
        let bytes = try Data(contentsOf: out[0])
        #expect(bytes.prefix(2) == Data("PK".utf8))
    }

    @Test func pdfToEpub() async throws {
        let dir = try PFx.dir("epub")
        defer { PFx.cleanup(dir) }
        let src = dir.appendingPathComponent("book.pdf")
        PFx.makePDF(threePages + ["Fish & <chips> \"quoted\""], at: src, title: "My Book", author: "A. Writer")
        let out = try await PDFDocumentEngine().runTest(JobSpec(inputs: [src], operation: .convert(to: "epub")))
        #expect(out[0].lastPathComponent == "book.epub")
        let data = try Data(contentsOf: out[0])
        // mimetype first, stored (method 0), no extra field.
        #expect(data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        #expect(data[8] == 0 && data[9] == 0)
        #expect(data[28] == 0 && data[29] == 0)
        #expect(String(decoding: data[30..<38], as: UTF8.self) == "mimetype")
        #expect(String(decoding: data[38..<58], as: UTF8.self) == "application/epub+zip")

        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        try await ProcessRunner.run(unzip, ["-tq", out[0].path])
        let opf = try await ProcessRunner.run(unzip, ["-p", out[0].path, "OEBPS/content.opf"]).stdout
        #expect(opf.contains("<dc:title>My Book</dc:title>"))
        #expect(opf.contains("<dc:creator>A. Writer</dc:creator>"))
        #expect(opf.contains("page-4.xhtml"))
        let p4 = try await ProcessRunner.run(unzip, ["-p", out[0].path, "OEBPS/page-4.xhtml"]).stdout
        #expect(p4.contains("Fish &amp; &lt;chips&gt; &quot;quoted&quot;"))
        let p2 = try await ProcessRunner.run(unzip, ["-p", out[0].path, "OEBPS/page-2.xhtml"]).stdout
        #expect(p2.contains("Bravo page two"))
        // Well-formed XHTML
        #expect(throws: Never.self) { _ = try XMLDocument(xmlString: p4, options: []) }
        #expect(throws: Never.self) { _ = try XMLDocument(xmlString: opf, options: []) }
    }

    @Test func textToPDFAndImages() async throws {
        let dir = try PFx.dir("txt")
        defer { PFx.cleanup(dir) }
        let src = dir.appendingPathComponent("notes.txt")
        let lines = (1...150).map { "Line \($0)\tcolumn text that is reasonably long to wrap maybe" }
        try lines.joined(separator: "\r\n").write(to: src, atomically: true, encoding: .utf8)
        let e = PDFDocumentEngine()
        let pdf = try await e.runTest(JobSpec(inputs: [src], operation: .convert(to: "pdf"), options: ["pageSize": .string("letter")]))
        #expect(pdf[0].lastPathComponent == "notes.pdf")
        let doc = try #require(PDFDocument(url: pdf[0]))
        #expect(doc.pageCount >= 2)
        #expect(doc.page(at: 0)?.bounds(for: .mediaBox).width == 612)
        let s = doc.string ?? ""
        #expect(s.contains("Line 1") && s.contains("Line 150"))

        let short = dir.appendingPathComponent("short.txt")
        try "Hello Rondo".write(to: short, atomically: true, encoding: .utf8)
        let png = try await e.runTest(JobSpec(inputs: [short], operation: .convert(to: "png"), options: ["dpi": .int(72), "pageSize": .string("a4")]))
        #expect(png[0].lastPathComponent == "short.png")
        let img = try #require(PFx.load(png[0]))
        #expect(img.width == 595 && img.height == 842)

        let jpgs = try await e.runTest(JobSpec(inputs: [src], operation: .convert(to: "jpg"), options: ["dpi": .int(50)]))
        #expect(jpgs[0].lastPathComponent == "notes (pages)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: jpgs[0].path).count == doc.pageCount)

        let latin = dir.appendingPathComponent("latin.txt")
        try Data([0x43, 0x61, 0x66, 0xE9]).write(to: latin)   // "Café" in Latin-1
        let lp = try await e.runTest(JobSpec(inputs: [latin], operation: .convert(to: "pdf")))
        #expect(PFx.text(lp[0]).contains("Café"))
    }
}

@Suite struct PDFToolTests {
    @Test func compressToTargetKeepsText() async throws {
        let dir = try PFx.dir("compress")
        defer { PFx.cleanup(dir) }
        let src = dir.appendingPathComponent("photo.pdf")
        PFx.makePDF(["Heavy page with photo", "Second page"], at: src, image: PFx.noisy())
        let original = PFx.size(src)
        let e = PDFDocumentEngine()

        let q = try await e.runTest(JobSpec(inputs: [src], operation: .tool("pdf.compress")))
        #expect(q[0].lastPathComponent == "photo compressed.pdf")
        #expect(PFx.size(q[0]) < original)
        #expect(PFx.text(q[0]).contains("Second page"))

        let target = original * 3 / 10
        let t = try await e.runTest(JobSpec(inputs: [src], operation: .tool("pdf.compress"), options: ["targetBytes": .int(target)]))
        let size = PFx.size(t[0])
        #expect(abs(Double(size - target)) <= Double(target) * 0.10, "target \(target), got \(size), original \(original)")
        #expect(PFx.text(t[0]).contains("Heavy page"))
        #expect(PDFDocument(url: t[0])?.pageCount == 2)

        let pct = try await e.runTest(JobSpec(inputs: [src], operation: .tool("pdf.compress"), options: ["percent": .double(60)]))
        let t2 = original * 4 / 10
        #expect(abs(Double(PFx.size(pct[0]) - t2)) <= Double(t2) * 0.10, "percent target \(t2), got \(PFx.size(pct[0]))")

        let r = try await e.runTest(JobSpec(inputs: [src], operation: .tool("pdf.compress"), options: ["mode": .string("rasterize"), "dpi": .int(72)]))
        #expect(PDFDocument(url: r[0])?.pageCount == 2)
        #expect(PFx.size(r[0]) < original)
    }

    @Test func mergeSplitReorder() async throws {
        let dir = try PFx.dir("pages")
        defer { PFx.cleanup(dir) }
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        PFx.makePDF(threePages, at: a)
        PFx.makePDF(["Delta page four"], at: b)
        let e = PDFDocumentEngine()

        let merged = try await e.runTest(JobSpec(inputs: [a, b], operation: .tool("pdf.merge")))
        #expect(merged.count == 1 && merged[0].lastPathComponent == "a merged.pdf")
        let m = try #require(PDFDocument(url: merged[0]))
        #expect(m.pageCount == 4)
        #expect(m.page(at: 3)?.string?.contains("Delta") == true)

        let split = try await e.runTest(JobSpec(inputs: [a], operation: .tool("pdf.split")))
        #expect(split[0].lastPathComponent == "a (pages)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: split[0].path).sorted() == ["Page 1.pdf", "Page 2.pdf", "Page 3.pdf"])
        #expect(PDFDocument(url: split[0].appendingPathComponent("Page 2.pdf"))?.string?.contains("Bravo") == true)

        let ranged = try await e.runTest(JobSpec(inputs: [a], operation: .tool("pdf.split"), options: ["ranges": .ranges([1...2, 3...3])]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: ranged[0].path).sorted() == ["Page 3.pdf", "Pages 1-2.pdf"])
        #expect(PDFDocument(url: ranged[0].appendingPathComponent("Pages 1-2.pdf"))?.pageCount == 2)

        let one = try await e.runTest(JobSpec(inputs: [a], operation: .tool("pdf.split"), options: ["ranges": .ranges([2...3])]))
        #expect(one[0].lastPathComponent == "a pages 2-3.pdf")

        let re = try await e.runTest(JobSpec(inputs: [a], operation: .tool("pdf.reorder"), options: [
            "order": .list([3, 1, 2]), "rotations": .list([90, 0, 0]), "deletions": .list([2]),
        ]))
        #expect(re[0].lastPathComponent == "a reordered.pdf")
        let r = try #require(PDFDocument(url: re[0]))
        #expect(r.pageCount == 2)
        #expect(r.page(at: 0)?.string?.contains("Charlie") == true)
        #expect(r.page(at: 0)?.rotation == 90)
        #expect(r.page(at: 1)?.string?.contains("Alpha") == true)

        // Rotated page renders rotated: 260×200, red block (unrotated top-left) now at top-right.
        let png = try await e.runTest(JobSpec(inputs: [re[0]], operation: .convert(to: "png"), options: ["dpi": .int(72)]))
        let img = try #require(PFx.load(png[0].appendingPathComponent("Page 1.png")))
        #expect(img.width == 260 && img.height == 200)
        #expect(PFx.isRed(PFx.pixel(img, 250, 10)))

        await #expect(throws: EngineError.self) {
            _ = try await e.runTest(JobSpec(inputs: [a], operation: .tool("pdf.reorder"), options: ["deletions": .list([1, 2, 3])]))
        }
    }

    @Test func metadataStrip() async throws {
        let dir = try PFx.dir("meta")
        defer { PFx.cleanup(dir) }
        let src = dir.appendingPathComponent("secret.pdf")
        PFx.makePDF(threePages, at: src, title: "Quarterly Secret", author: "Jane Roe", subject: "Internal")
        #expect(PDFDocument(url: src)?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Jane Roe")
        let out = try await PDFDocumentEngine().runTest(JobSpec(inputs: [src], operation: .tool("pdf.metadata.strip")))
        #expect(out[0].lastPathComponent == "secret stripped.pdf")
        let doc = try #require(PDFDocument(url: out[0]))
        let attrs = doc.documentAttributes ?? [:]
        #expect((attrs[PDFDocumentAttribute.authorAttribute] as? String ?? "").isEmpty)
        #expect((attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "").isEmpty)
        #expect((attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? "").isEmpty)
        let raw = try Data(contentsOf: out[0])
        #expect(raw.range(of: Data("Jane Roe".utf8)) == nil)
        #expect(raw.range(of: Data("Quarterly Secret".utf8)) == nil)
        #expect(doc.pageCount == 3)
    }

    @Test func ocrFallbackForScannedPages() async throws {
        let dir = try PFx.dir("ocr")
        defer { PFx.cleanup(dir) }
        let src = dir.appendingPathComponent("scan.pdf")
        PFx.makeScannedPDF("RONDO SCAN TEST", at: src)
        let srcText = PFx.text(src)
        #expect(srcText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let out = try await PDFDocumentEngine().runTest(JobSpec(inputs: [src], operation: .tool("pdf.text.extract")))
        let text = try String(contentsOf: out[0], encoding: .utf8).uppercased()
        #expect(text.contains("RONDO") && text.contains("SCAN"), "OCR got: \(text)")
        await #expect(throws: EngineError.invalidInput("No text found in scan.pdf (OCR is off)")) {
            _ = try await PDFDocumentEngine().runTest(JobSpec(inputs: [src], operation: .tool("pdf.text.extract"), options: ["ocr": .bool(false)]))
        }
    }

    @Test func badInputsFailCleanly() async throws {
        let dir = try PFx.dir("bad")
        defer { PFx.cleanup(dir) }
        let fake = dir.appendingPathComponent("fake.pdf")
        try "not a pdf".write(to: fake, atomically: true, encoding: .utf8)
        await #expect(throws: EngineError.self) {
            _ = try await PDFDocumentEngine().runTest(JobSpec(inputs: [fake], operation: .convert(to: "png")))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["fake.pdf"])
    }

    @Test func zipWriterRoundTrip() async throws {
        var z = ZipWriter()
        z.add("a.txt", Data(String(repeating: "hello ", count: 200).utf8))
        z.add("dir/b.bin", Data((0..<255).map { UInt8($0) }), compress: false)
        let dir = try PFx.dir("zip")
        defer { PFx.cleanup(dir) }
        let url = dir.appendingPathComponent("t.zip")
        try z.finish().write(to: url)
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", url.path, "a.txt"])
        #expect(r.stdout == String(repeating: "hello ", count: 200))
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

@Suite struct PDFRegressionTests {
    /// Smoke bug: image-only PDFs with no recoverable text committed empty .txt files.
    @Test func textlessPDFCommitsNothing() async throws {
        let dir = try PFx.dir("notext")
        defer { PFx.cleanup(dir) }
        let src = dir.appendingPathComponent("images.pdf")
        let ctx = CGContext(data: nil, width: 120, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: PFx.sRGB,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        PFx.makePDF(["", ""], at: src, image: ctx.makeImage()!)
        let e = PDFDocumentEngine()
        let jobs: [JobSpec] = ["txt", "md", "docx", "epub"].map { JobSpec(inputs: [src], operation: .convert(to: $0)) }
            + [JobSpec(inputs: [src], operation: .tool("pdf.text.extract"))]
        for job in jobs {
            do {
                _ = try await e.runTest(job)
                Issue.record("\(job.operation) should have failed")
            } catch let err as EngineError {
                #expect(err == .invalidInput("No text found in images.pdf (OCR found nothing either)"), "\(job.operation): \(err)")
            }
        }
        do {
            _ = try await e.runTest(JobSpec(inputs: [src], operation: .convert(to: "txt"), options: ["ocr": .bool(false)]))
            Issue.record("ocr=false should fail too")
        } catch let err as EngineError {
            #expect(err == .invalidInput("No text found in images.pdf (OCR is off)"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["images.pdf"])
        // Image outputs still work for the same file.
        let png = try await e.runTest(JobSpec(inputs: [src], operation: .convert(to: "png"), options: ["dpi": .int(72)]))
        #expect(png[0].lastPathComponent == "images (pages)")
    }
}
