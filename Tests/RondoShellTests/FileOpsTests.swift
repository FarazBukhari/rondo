import Foundation
import RondoKit
import Testing
@testable import RondoShell

/// Scratch folder under fixtures/out/W2 (gitignored); removed by the caller.
func makeScratch(_ name: String = #function) throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures/out/W2", isDirectory: true)
    let dir = root.appendingPathComponent("\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func touch(_ url: URL, _ text: String = "x") {
    FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
}

func contents(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

@Suite struct PathJoinerTests {
    @Test func newlineJoinedPosixPaths() {
        let urls = [
            URL(fileURLWithPath: "/Users/me/My Photos/a b.jpg"),
            URL(fileURLWithPath: "/tmp/../tmp/x.txt"),
            URL(fileURLWithPath: "/Users/me/Folder/", isDirectory: true),
        ]
        #expect(PathJoiner.join(urls) == "/Users/me/My Photos/a b.jpg\n/tmp/x.txt\n/Users/me/Folder")
    }

    @Test func dedupesKeepingOrder() {
        let a = URL(fileURLWithPath: "/a.txt"), b = URL(fileURLWithPath: "/b.txt")
        #expect(PathJoiner.join([a, b, a]) == "/a.txt\n/b.txt")
        #expect(PathJoiner.join([a]) == "/a.txt")
        #expect(PathJoiner.join([]) == "")
    }
}

@Suite struct TerminalTargetsTests {
    @Test func folderOpensAtItselfFileAtParent() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let f1 = dir.appendingPathComponent("one.txt"), f2 = dir.appendingPathComponent("two.txt")
        touch(f1); touch(f2)
        let dirs = TerminalTargets.directories(for: [f1, sub, f2]).map(\.path)
        #expect(dirs == [dir.standardizedFileURL.path, sub.standardizedFileURL.path])
    }
}

@Suite struct FileMoverTests {
    @Test func collisionNamingFinderStyle() throws {
        let src = try makeScratch(), dst = try makeScratch()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        touch(dst.appendingPathComponent("photo.jpg"), "existing")
        touch(dst.appendingPathComponent("photo 2.jpg"), "existing 2")
        let input = src.appendingPathComponent("photo.jpg")
        touch(input, "new")

        #expect(FileMover.destination(for: input, in: dst).lastPathComponent == "photo 3.jpg")
        let out = FileMover.move([input], to: dst)
        #expect(out.count == 1)
        #expect(out[0].destination?.lastPathComponent == "photo 3.jpg")
        // Nothing overwritten, source gone, new file intact.
        #expect(contents(dst.appendingPathComponent("photo.jpg")) == "existing")
        #expect(contents(dst.appendingPathComponent("photo 2.jpg")) == "existing 2")
        #expect(contents(dst.appendingPathComponent("photo 3.jpg")) == "new")
        #expect(!FileManager.default.fileExists(atPath: input.path))
    }

    @Test func compoundExtensionAndFolders() throws {
        let src = try makeScratch(), dst = try makeScratch()
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        touch(dst.appendingPathComponent("logs.tar.gz"))
        try FileManager.default.createDirectory(at: dst.appendingPathComponent("Project.v2"), withIntermediateDirectories: true)
        let archive = src.appendingPathComponent("logs.tar.gz")
        touch(archive)
        let folder = src.appendingPathComponent("Project.v2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        touch(folder.appendingPathComponent("inner.txt"), "inner")

        #expect(FileMover.destination(for: archive, in: dst).lastPathComponent == "logs 2.tar.gz")
        #expect(FileMover.destination(for: folder, in: dst).lastPathComponent == "Project.v2 2")
        let out = FileMover.move([archive, folder], to: dst)
        #expect(out.map { $0.destination?.lastPathComponent } == ["logs 2.tar.gz", "Project.v2 2"])
        #expect(contents(dst.appendingPathComponent("Project.v2 2/inner.txt")) == "inner")
    }

    @Test func batchWithSameNamesNeverOverwrites() throws {
        let a = try makeScratch(), b = try makeScratch(), dst = try makeScratch()
        defer { [a, b, dst].forEach { try? FileManager.default.removeItem(at: $0) } }
        touch(a.appendingPathComponent("notes.txt"), "A")
        touch(b.appendingPathComponent("notes.txt"), "B")
        let out = FileMover.move([a.appendingPathComponent("notes.txt"), b.appendingPathComponent("notes.txt")], to: dst)
        #expect(out.map { $0.destination?.lastPathComponent } == ["notes.txt", "notes 2.txt"])
        #expect(contents(dst.appendingPathComponent("notes.txt")) == "A")
        #expect(contents(dst.appendingPathComponent("notes 2.txt")) == "B")
    }

    @Test func alreadyThereIntoItselfAndMissing() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        touch(file, "keep")
        let folder = dir.appendingPathComponent("F", isDirectory: true)
        let inner = folder.appendingPathComponent("Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let missing = dir.appendingPathComponent("gone.txt")

        let out = FileMover.move([file, folder, missing], to: dir)
        #expect(out[0].status == .alreadyThere)
        #expect(contents(file) == "keep")
        #expect(out[1].status == .alreadyThere)
        if case .failed = out[2].status {} else { Issue.record("missing file should fail") }

        let intoSelf = FileMover.move([folder], to: inner)
        if case .failed = intoSelf[0].status {} else { Issue.record("folder into its own child must fail") }
        #expect(FileManager.default.fileExists(atPath: inner.path))
    }

    @Test func destinationMustBeFolder() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt"), notDir = dir.appendingPathComponent("b.txt")
        touch(file); touch(notDir)
        let out = FileMover.move([file], to: notDir)
        if case .failed = out[0].status {} else { Issue.record("expected failure") }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

private func setPermissions(_ url: URL, _ mode: Int) {
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private func leftovers(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".rondo-move-") }
}

/// Cross-volume path (copy → verify → rename → remove), forced on one volume.
@Suite struct FileMoverCopyPathTests {
    @Test func copiesVerifiesRenamesThenRemovesOriginal() throws {
        let src = try makeScratch(), dst = try makeScratch()
        defer { [src, dst].forEach { try? FileManager.default.removeItem(at: $0) } }
        let folder = src.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        touch(folder.appendingPathComponent("a.jpg"), "aaaa")
        touch(folder.appendingPathComponent("nested/b.txt"), "bb")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "a.jpg")
        let file = src.appendingPathComponent("photo.jpg")
        touch(file, "new")
        touch(dst.appendingPathComponent("photo.jpg"), "existing")
        try FileManager.default.createDirectory(at: dst.appendingPathComponent("Album"), withIntermediateDirectories: true)

        let out = FileMover.move([folder, file], to: dst, fileManager: .default, forceCopy: true)
        #expect(out.map { $0.destination?.lastPathComponent } == ["Album 2", "photo 2.jpg"])
        #expect(out.allSatisfy { if case .moved = $0.status { true } else { false } })
        #expect(contents(dst.appendingPathComponent("Album 2/nested/b.txt")) == "bb")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("Album 2/link").path)) == "a.jpg")
        #expect(contents(dst.appendingPathComponent("photo.jpg")) == "existing")
        #expect(contents(dst.appendingPathComponent("photo 2.jpg")) == "new")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(leftovers(dst).isEmpty)
    }

    @Test func failedCopyLeavesOriginalAndNoPartialCopy() throws {
        let src = try makeScratch(), dst = try makeScratch()
        let folder = src.appendingPathComponent("Docs", isDirectory: true)
        let secret = folder.appendingPathComponent("secret.txt")
        defer {
            setPermissions(secret, 0o644)
            [src, dst].forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        touch(folder.appendingPathComponent("ok.txt"), "ok")
        touch(secret, "s")
        setPermissions(secret, 0o000)   // copy fails partway through

        let out = FileMover.move([folder], to: dst, fileManager: .default, forceCopy: true)
        if case .failed = out[0].status {} else { Issue.record("expected failure, got \(out[0].status)") }
        #expect(FileManager.default.fileExists(atPath: secret.path))
        #expect(contents(folder.appendingPathComponent("ok.txt")) == "ok")
        #expect(leftovers(dst).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dst.path)) ?? []).isEmpty)
    }

    @Test func undeletableOriginalIsNotCopied() throws {
        let src = try makeScratch(), dst = try makeScratch()
        let locked = src.appendingPathComponent("Locked", isDirectory: true)
        defer {
            setPermissions(locked, 0o755)
            [src, dst].forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = locked.appendingPathComponent("keep.txt")
        touch(file, "keep")
        setPermissions(locked, 0o555)   // can't unlink inside

        let out = FileMover.move([file], to: dst, fileManager: .default, forceCopy: true)
        if case .failed = out[0].status {} else { Issue.record("expected failure, got \(out[0].status)") }
        #expect(contents(file) == "keep")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dst.path)) ?? []).isEmpty)
    }
}

@Suite struct FileMoverSymlinkTests {
    @Test func symlinkToFolderCanMoveIntoItsTarget() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("Real", isDirectory: true)
        let sub = real.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("F")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let out = FileMover.move([link], to: sub)
        #expect(out[0].destination?.lastPathComponent == "F")
        let moved = sub.appendingPathComponent("F")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: moved.path)) == real.path)
        #expect(FileManager.default.fileExists(atPath: sub.path))   // target untouched

        // A real folder still can't go inside itself.
        let intoSelf = FileMover.move([real], to: sub)
        if case .failed = intoSelf[0].status {} else { Issue.record("folder into its own child must fail") }
    }
}

@Suite @MainActor struct ActionMoveTests {
    @Test func moveRunsOffMainAndReports() async throws {
        let src = try makeScratch(), dst = try makeScratch()
        defer { [src, dst].forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = src.appendingPathComponent("a.txt"), b = src.appendingPathComponent("b.txt")
        touch(a, "A"); touch(b, "B")
        touch(dst.appendingPathComponent("a.txt"), "old")

        let performer = ActionPerformer(floatShelf: FloatShelf(defaults: UserDefaults(suiteName: "rondo.shell.tests.move")!))
        var settings = RondoKit.Settings()
        settings.revealInFinder = false
        performer.settings = { settings }
        var messages: [String] = []
        performer.onMessage = { m, _ in messages.append(m) }

        let out = try #require(await performer.move([a, b], to: dst))
        #expect(out.map { $0.destination?.lastPathComponent } == ["a 2.txt", "b.txt"])
        #expect(contents(dst.appendingPathComponent("a.txt")) == "old")
        #expect(!performer.isMoving([a, b]))
        #expect(messages.isEmpty)
    }
}
