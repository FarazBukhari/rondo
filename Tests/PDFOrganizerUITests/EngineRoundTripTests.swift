import Foundation
import PDFKit
import RondoKit
import Testing
import PDFEngine
@testable import PDFOrganizerUI

/// Organizer options → the real PDFDocumentEngine → check the written PDF. Outputs under fixtures/out/W8/engine/.
@Suite(.serialized) struct EngineRoundTripTests {
    static let out = W8Fixtures.freshDir("engine")

    func run(_ inputs: [URL], _ tool: ToolID, _ options: [String: OptionValue]) async throws -> [URL] {
        let spec = JobSpec(inputs: inputs, operation: .tool(tool), options: options, destination: .folder(Self.out))
        let tmp = try TempDir.make(prefix: "w8-organizer")
        defer { TempDir.remove(tmp) }
        return try await PDFDocumentEngine().run(spec, context: JobContext(tempDir: tmp, destination: .folder(Self.out)))
    }

    @Test func reorderRotateDelete() async throws {
        let src = W8Fixtures.makePDF("four.pdf", pages: 4)
        var a = PageArrangement(pageCount: 4)
        a.move([4], to: 0)
        a.delete([2])
        a.rotate([1], by: 90)
        a.rotate([3], by: -90)
        let out = try #require(try await run([src], "pdf.reorder", a.options).first)
        #expect(W8Fixtures.texts(out) == ["Page 4", "Page 1", "Page 3"])
        #expect(W8Fixtures.rotations(out) == [0, 90, 270])
        #expect(W8Fixtures.texts(src) == ["Page 1", "Page 2", "Page 3", "Page 4"])   // input untouched
    }

    @Test func deletionsPathKeepsRotationsAligned() async throws {
        let src = W8Fixtures.makePDF("four.pdf", pages: 4)
        var a = PageArrangement(pageCount: 4)
        a.delete([1, 3])
        a.rotate([4], by: 180)
        #expect(a.options["order"] == nil)
        let out = try #require(try await run([src], "pdf.reorder", a.options).first)
        #expect(W8Fixtures.texts(out) == ["Page 2", "Page 4"])
        #expect(W8Fixtures.rotations(out) == [0, 180])
    }

    @Test func splitParts() async throws {
        let src = W8Fixtures.makePDF("five.pdf", pages: 5, landscape: [4])
        var p = SplitPlan(pageCount: 5)
        p.addParts(from: [1, 2])
        p.addParts(from: [3])
        p.includeRest = true
        let folder = try #require(try await run([src], "pdf.split", SplitPlan.options(ranges: p.outputRanges)).first)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }
        let parts = files.map(W8Fixtures.texts).sorted { ($0.first ?? "") < ($1.first ?? "") }
        #expect(parts == [["Page 1", "Page 2"], ["Page 3"], ["Page 4", "Page 5"]])
    }

    @Test func mergeInUserOrder() async throws {
        let a = W8Fixtures.makePDF("merge-a.pdf", pages: 2, label: "A")
        let b = W8Fixtures.makePDF("merge-b.pdf", pages: 1, label: "B")
        var l = MergeList([MergeEntry(url: a, pageCount: 2), MergeEntry(url: b, pageCount: 1)])
        l.move([l.entries[1].id], to: 0)
        let out = try #require(try await run(l.inputs, "pdf.merge", [:]).first)
        #expect(W8Fixtures.texts(out) == ["B 1", "A 1", "A 2"])
    }
}
