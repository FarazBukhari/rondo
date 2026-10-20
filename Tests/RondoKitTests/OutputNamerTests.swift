import Foundation
import Testing
@testable import RondoKit

private func makeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RondoKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func touch(_ url: URL) {
    FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
}

@Suite struct OutputNamerTests {
    let namer = OutputNamer()

    @Test func noCollisionKeepsName() throws {
        let dir = try makeDir()
        let input = dir.appendingPathComponent("photo.heic")
        touch(input)
        #expect(namer.url(for: input, ext: "jpg").lastPathComponent == "photo.jpg")
    }

    @Test func finderStyleCollisions() throws {
        let dir = try makeDir()
        let input = dir.appendingPathComponent("photo.heic")
        touch(input)
        touch(dir.appendingPathComponent("photo.jpg"))
        #expect(namer.url(for: input, ext: "jpg").lastPathComponent == "photo 2.jpg")
        touch(dir.appendingPathComponent("photo 2.jpg"))
        #expect(namer.url(for: input, ext: "jpg").lastPathComponent == "photo 3.jpg")
    }

    @Test func sameExtensionNeverOverwritesInput() throws {
        let dir = try makeDir()
        let input = dir.appendingPathComponent("a.jpg")
        touch(input)
        #expect(namer.url(for: input, ext: "jpg").lastPathComponent == "a 2.jpg")
    }

    @Test func suffixAndCompoundExtension() throws {
        let dir = try makeDir()
        let input = dir.appendingPathComponent("logs.tar.gz")
        touch(input)
        #expect(OutputNamer.baseName(of: input) == "logs")
        #expect(namer.url(for: input, ext: "zip", suffix: "repacked").lastPathComponent == "logs repacked.zip")
    }

    @Test func folderCollisions() throws {
        let dir = try makeDir()
        let input = dir.appendingPathComponent("doc.pdf")
        touch(input)
        let first = namer.folder(for: input, suffix: "pages")
        #expect(first.lastPathComponent == "doc (pages)")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        #expect(namer.folder(for: input, suffix: "pages").lastPathComponent == "doc (pages) 2")
    }

    @Test func destinationFolder() throws {
        let dir = try makeDir()
        let out = try makeDir()
        let input = dir.appendingPathComponent("a.png")
        touch(input)
        let url = namer.url(for: input, ext: "jpg", destination: .folder(out))
        #expect(url.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL)
    }

    @Test func commitResolvesLateCollision() throws {
        let dir = try makeDir()
        let input = dir.appendingPathComponent("a.png")
        touch(input)
        let planned = namer.url(for: input, ext: "jpg")
        touch(planned)                       // someone grabbed the name after planning
        let temp = dir.appendingPathComponent("tmp-out.jpg")
        touch(temp)
        let written = try namer.commit(temp, to: planned)
        #expect(written.lastPathComponent == "a 2.jpg")
        #expect(FileManager.default.fileExists(atPath: written.path))
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }
}
