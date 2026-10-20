import Foundation
import Testing
import RondoKit
@testable import DocEngine

@Suite struct ArchiveTests {
    /// sample-folder/{a.txt, sub/b.txt}
    func makeFolder(in dir: URL, name: String = "sample-folder") throws -> URL {
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "alpha".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "beta".write(to: folder.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    func assertSampleTree(_ root: URL) throws {
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "alpha")
        #expect(try String(contentsOf: root.appendingPathComponent("sub/b.txt"), encoding: .utf8) == "beta")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains { $0.hasPrefix("._") || $0 == "__MACOSX" })
    }

    @Test(arguments: ["zip", "tar", "tar.gz"])
    func folderRoundTrip(format: String) async throws {
        let dir = try W5.dir("arch-\(format)")
        let folder = try makeFolder(in: dir)
        let archive = try await W5.one(folder, to: format, out: dir.appendingPathComponent("archives"))
        #expect(archive.lastPathComponent == "sample-folder.\(format)")
        #expect(FormatCatalog.format(for: archive)?.id == format)
        let extracted = try await W5.one(archive, to: "folder", out: dir.appendingPathComponent("extracted"))
        #expect(extracted.lastPathComponent == "sample-folder", "single top-level folder is unwrapped and named after the archive")
        try assertSampleTree(extracted)
        #expect(FormatCatalog.format(for: extracted)?.id == "folder")
    }

    @Test func singleFileGzipRoundTrip() async throws {
        let dir = try W5.dir("arch-gz")
        let file = try W5.write("hello gzip\n", to: dir, name: "notes.txt")
        let gz = try await W5.one(file, to: "gz")
        #expect(gz.lastPathComponent == "notes.txt.gz")
        #expect(FileManager.default.fileExists(atPath: file.path), "input must be untouched")
        let folder = try await W5.one(gz, to: "folder", out: dir.appendingPathComponent("x"))
        #expect(folder.lastPathComponent == "notes")
        #expect(try String(contentsOf: folder.appendingPathComponent("notes.txt"), encoding: .utf8) == "hello gzip\n")
    }

    @Test func singleFileZipAndTarGz() async throws {
        let dir = try W5.dir("arch-file")
        let file = try W5.write("zip me\n", to: dir, name: "doc.md")
        let zip = try await W5.one(file, to: "zip")
        #expect(zip.lastPathComponent == "doc.md.zip")
        #expect(W5.zipOK(zip))
        let tgz = try await W5.one(file, to: "tar.gz")
        #expect(tgz.lastPathComponent == "doc.md.tar.gz")
        #expect(W5.sh("/usr/bin/tar", ["-tzf", tgz.path]).1.contains("doc.md"))
        // Second conversion of the same file never overwrites.
        let zip2 = try await W5.one(file, to: "zip")
        #expect(zip2.lastPathComponent == "doc.md 2.zip")
    }

    @Test func extractingMultipleTopLevelEntriesWraps() async throws {
        let dir = try W5.dir("arch-multi")
        var zip = ZipBuilder()
        zip.add("one.txt", "1")
        zip.add("two.txt", "2")
        let archive = dir.appendingPathComponent("bundle.zip")
        try zip.finish().write(to: archive)
        let out = try await W5.one(archive, to: "folder")
        #expect(out.lastPathComponent == "bundle")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)) == ["one.txt", "two.txt"])
    }

    @Test(arguments: ["../evil.txt", "ok/../../evil.txt", "/tmp/rondo-evil.txt"])
    func zipTraversalRejected(entry: String) async throws {
        let dir = try W5.dir("arch-evil-zip")
        var zip = ZipBuilder()
        zip.add("fine.txt", "ok")
        zip.add(entry, "pwned")
        let archive = dir.appendingPathComponent("evil.zip")
        try zip.finish().write(to: archive)
        await #expect(throws: EngineError.self) { try await W5.one(archive, to: "folder") }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["evil.zip"], "nothing may be written on rejection")
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }

    @Test func tarTraversalRejected() async throws {
        let dir = try W5.dir("arch-evil-tar")
        let tar = dir.appendingPathComponent("evil.tar")
        try W5.ustar([("fine.txt", Data("ok".utf8), nil), ("../evil.txt", Data("pwned".utf8), nil)]).write(to: tar)
        #expect(W5.sh("/usr/bin/tar", ["-tf", tar.path]).1.contains("../evil.txt"), "fixture sanity")
        await #expect(throws: EngineError.self) { try await W5.one(tar, to: "folder") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["evil.tar"])
    }

    @Test func escapingSymlinksRemoved() async throws {
        let dir = try W5.dir("arch-link")
        let tar = dir.appendingPathComponent("links.tar")
        try W5.ustar([
            ("pkg/readme.txt", Data("hi".utf8), nil),
            ("pkg/inside", Data(), "readme.txt"),
            ("pkg/outside", Data(), "/etc/hosts"),
            ("pkg/up", Data(), "../../../../etc"),
        ]).write(to: tar)
        let out = try await W5.one(tar, to: "folder")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
        #expect(names == ["readme.txt", "inside"])
    }

    @Test func rarExtractionWhenSupported() async throws {
        guard let tar = ToolLocator().url(for: "tar"), Probe.tarReadsRAR(tar) else { return }
        let dir = try W5.dir("arch-rar")
        let rar = dir.appendingPathComponent("pack.rar")
        try RAR4Writer.archive(entries: [("a.txt", Data("rar a".utf8)), ("b.txt", Data("rar b".utf8))]).write(to: rar)
        let out = try await W5.one(rar, to: "folder")
        #expect(out.lastPathComponent == "pack")
        #expect(try String(contentsOf: out.appendingPathComponent("b.txt"), encoding: .utf8) == "rar b")

        let evil = dir.appendingPathComponent("evil.rar")
        try RAR4Writer.archive(entries: [("../evil.txt", Data("x".utf8))]).write(to: evil)
        await #expect(throws: EngineError.self) { try await W5.one(evil, to: "folder", out: dir.appendingPathComponent("e")) }
    }

    @Test func corruptArchiveFails() async throws {
        let dir = try W5.dir("arch-bad")
        let bad = try W5.write("not a zip", to: dir, name: "bad.zip")
        await #expect(throws: (any Error).self) { try await W5.one(bad, to: "folder") }
    }

    @Test func unsafeEntryRules() {
        for bad in ["../x", "a/../../x", "/etc/passwd", "\\x", "C:\\x", "~/x", "a\\..\\x"] { #expect(Archives.isUnsafe(bad), "\(bad)") }
        for ok in ["a.txt", "dir/", "dir/a..b.txt", "..hidden", "a/b/c"] { #expect(!Archives.isUnsafe(ok), "\(ok)") }
        #expect(Archives.folderName(for: URL(fileURLWithPath: "/x/notes.txt.gz")) == "notes")
        #expect(Archives.folderName(for: URL(fileURLWithPath: "/x/site.v2.zip")) == "site.v2")
    }
}
