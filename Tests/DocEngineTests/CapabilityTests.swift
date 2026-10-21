import Foundation
import Testing
import RondoKit
@testable import DocEngine

@Suite struct CapabilityTests {
    let pairs = Set(DocumentEngine().conversions().map { "\($0.from)>\($0.to)" })

    @Test func documentMatrix() {
        for from in ["docx", "doc", "rtf", "rtfd", "md", "html", "odt", "textclipping"] {
            for to in ["docx", "txt", "md", "html", "rtf", "pdf", "epub"] where to != from {
                #expect(pairs.contains("\(from)>\(to)"), "missing \(from) → \(to)")
            }
        }
        for to in ["docx", "md", "html", "rtf", "epub"] { #expect(pairs.contains("txt>\(to)")) }
    }

    @Test func respectsPDFEngineOwnership() {
        for to in ["pdf", "jpg", "png"] { #expect(!pairs.contains("txt>\(to)"), "txt → \(to) belongs to W3") }
        let archives: Set<String> = ["zip", "tar.gz", "gz"]
        // pdf → archive is ours (the PDF engine never advertises archive targets); every other pdf → * is W3's.
        #expect(!pairs.contains { $0.hasPrefix("pdf>") && !archives.contains(String($0.dropFirst(4))) }, "pdf → non-archive belongs to W3")
        #expect(pairs.contains("pdf>zip"), "PDFs can be archived")
        let conversionsOnly = pairs.filter { !archives.contains(String($0.split(separator: ">").last!)) }
        #expect(!conversionsOnly.contains { $0.hasPrefix("epub>") || $0.hasPrefix("pages>") }, "EPUB/PAGES input is v2")
        #expect(!conversionsOnly.contains { $0.hasPrefix("ods>") || $0.hasPrefix("xls>") }, "ODS/XLS input is v2")
        #expect(pairs.contains("epub>zip") && pairs.contains("ods>tar.gz"), "any non-PDF file can be archived")
    }

    @Test func subtitlesSpreadsheetsArchives() {
        for p in ["srt>vtt", "vtt>srt", "srt>txt", "vtt>txt",
                  "csv>tsv", "tsv>csv", "csv>xlsx", "tsv>xlsx", "xlsx>csv", "xlsx>tsv", "csv>pdf", "xlsx>pdf",
                  "folder>zip", "folder>tar", "folder>tar.gz",
                  "jpg>zip", "jpg>tar.gz", "jpg>gz", "txt>gz", "mp4>zip",
                  "zip>folder", "tar>folder", "tar.gz>folder", "gz>folder"] {
            #expect(pairs.contains(p), "missing \(p)")
        }
        #expect(!pairs.contains("folder>gz"))
        #expect(!pairs.contains("rtfd>gz"), "packages can't be gzipped")
        #expect(!pairs.contains("zip>zip") && !pairs.contains("folder>folder"))
        #expect(DocumentEngine().tools().isEmpty)
    }

    @Test func rarGatedOnProbe() async {
        let tar = ToolLocator().url(for: "tar")
        let readsRAR = tar.map(Probe.tarAdvertisesRAR) ?? false
        #expect(pairs.contains("rar>folder") == readsRAR)
        #expect(Probe.libarchiveReadsRAR(versionOutput: "bsdtar 3.5.3 - libarchive 3.7.4 zlib/1.2.12"))
        #expect(!Probe.libarchiveReadsRAR(versionOutput: "tar (GNU tar) 1.35"))
        #expect(!Probe.libarchiveReadsRAR(versionOutput: "bsdtar 2.8.3 - libarchive 2.8.3"))
        // Advertising must imply the real listing check passes.
        if readsRAR, let tar { #expect(await Probe.verifyTarReadsRAR(tar)) }
    }

    @Test func slidesOnlyWithExporter() {
        let locator = ToolLocator()
        let hasExporter = locator.has("soffice") || (Slides.keynoteURL() != nil && locator.has("osascript"))
        let slidePairs = pairs.filter { $0.hasPrefix("pptx>") || $0.hasPrefix("ppt>") || $0.hasPrefix("key>") }
            .filter { !$0.hasSuffix(">zip") && !$0.hasSuffix(">tar.gz") && !$0.hasSuffix(">gz") }
        #expect(slidePairs.isEmpty == !hasExporter)
        if hasExporter { #expect(slidePairs.contains("pptx>pdf")) }
    }

    @Test func firstConversionsCallIsFastAndSafeConcurrently() async {
        let start = ContinuousClock.now
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<16 { group.addTask { DocumentEngine().conversions().count } }
            return await group.reduce(into: Set<Int>()) { $0.insert($1) }
        }
        let elapsed = ContinuousClock.now - start
        print("conversions() ×16 concurrent: \(elapsed)")
        #expect(counts.count == 1, "all callers see the same capability set")
        // Typically ~10 ms. Loose bound: the full suite saturates the machine with ffmpeg jobs,
        // and this guards against deadlock / pool starvation, not micro-latency.
        #expect(elapsed < .seconds(60))   // deadlock guard; 1-thread-pool runs take ~15 s
    }

    @Test func syncProcessTimesOut() {
        let start = ContinuousClock.now
        #expect(SyncProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.2) == nil)
        #expect(ContinuousClock.now - start < .seconds(4))   // < the 5 s sleep: proves the kill under load
        #expect(SyncProcess.run(URL(fileURLWithPath: "/bin/echo"), ["hi"], timeout: 2)?.output == "hi\n")
    }

    @Test func missingToolsHideConversions() {
        let empty = ToolLocator(overrides: [:], bundleBin: nil)
        var bare = empty
        bare.searchDirectories = []
        let p = Set(DocumentEngine(tools: bare).conversions().map { "\($0.from)>\($0.to)" })
        #expect(!p.contains("html>md"), "html input needs textutil")
        #expect(!p.contains("folder>zip") && !p.contains("zip>folder"), "archives need ditto/tar")
        #expect(p.contains("xlsx>csv"), "XLSX parts are read in-process")
        #expect(p.contains("md>docx") && p.contains("srt>vtt") && p.contains("csv>xlsx"))
    }
}
