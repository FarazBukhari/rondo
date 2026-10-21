import Foundation
import RondoKit

/// Archive creation (folder/file → zip, tar, tar.gz, gz) and safe extraction (zip, tar, tar.gz, gz, rar → folder).
enum Archives {
    static let createTargets = ["zip", "tar", "tar.gz", "gz"]
    static let extractSources = ["zip", "tar", "tar.gz", "gz", "rar"]

    // MARK: Create

    static func create(_ input: URL, to format: String, context: JobContext, progress: (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: input.path) else { throw EngineError.invalidInput("\(input.lastPathComponent) doesn't exist") }
        let isDir = DocSupport.isDirectory(input)
        let work = try DocSupport.scratchDir(context)
        let parent = input.deletingLastPathComponent()
        let name = input.lastPathComponent
        progress(0.05)

        let out: URL
        switch format {
        case "zip":
            out = work.appendingPathComponent("archive.zip")
            let ditto = try context.tools.require("ditto")
            try await run(ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, out.path], what: "ditto")
        case "tar", "tar.gz":
            out = work.appendingPathComponent(format == "tar" ? "archive.tar" : "archive.tar.gz")
            let tar = try context.tools.require("tar")
            try await run(tar, [format == "tar" ? "-cf" : "-czf", out.path, "-C", parent.path, name],
                          env: DocSupport.archiveEnvironment, what: "tar")
        case "gz":
            guard !isDir else { throw EngineError.unsupported("GZIP compresses single files; choose ZIP or TAR.GZ for folders") }
            let gzip = try context.tools.require("gzip")
            let copy = work.appendingPathComponent(name)
            try fm.copyItem(at: input, to: copy)   // APFS clone; gzip replaces the copy, never the input
            try await run(gzip, ["-f", copy.path], what: "gzip")
            out = work.appendingPathComponent(name + ".gz")
        default:
            throw EngineError.unsupported("archive format \(format)")
        }
        guard fm.fileExists(atPath: out.path) else { throw EngineError.failed("\(format) archive wasn't created") }
        progress(0.9)

        // Finder-style names keep the full original name: "a.txt" → "a.txt.zip", "my.photos" → "my.photos.tar.gz".
        let dir = DocSupport.outputDirectory(for: input, context: context)
        let ext = FormatCatalog.format(id: format)?.preferredExtension ?? format
        return try context.namer.commit(out, to: OutputNamer.unique(dir.appendingPathComponent("\(name).\(ext)")))
    }

    // MARK: Extract

    static func extract(_ input: URL, from format: String, context: JobContext, progress: (Double) -> Void) async throws -> URL {
        try DocSupport.requireInput(input)
        let fm = FileManager.default
        let work = try DocSupport.scratchDir(context)
        let dest = work.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        switch format {
        case "zip":
            let unzip = try context.tools.require("unzip")
            let listing = try await ProcessRunner.run(unzip, ["-Z1", input.path], checkExit: false)
            guard listing.exitCode == 0 else { throw EngineError.invalidInput("\(input.lastPathComponent) isn't a readable ZIP") }
            try validate(entries: lines(listing.stdout), archive: input)
            progress(0.2)
            let ditto = try context.tools.require("ditto")
            try await run(ditto, ["-x", "-k", input.path, dest.path], what: "ditto")
            try? fm.removeItem(at: dest.appendingPathComponent("__MACOSX"))
        case "tar", "tar.gz", "rar":
            let tar = try context.tools.require("tar")
            if format == "rar", !(await Probe.verifyTarReadsRAR(tar)) {
                try Task.checkCancellation()
                throw EngineError.unsupported("RAR archives: \(tar.path) can't read them on this Mac")
            }
            let listing = try await ProcessRunner.run(tar, ["-tf", input.path], checkExit: false)
            guard listing.exitCode == 0 else {
                throw EngineError.invalidInput("\(input.lastPathComponent) isn't a readable \(format.uppercased()) archive")
            }
            try validate(entries: lines(listing.stdout), archive: input)
            progress(0.2)
            try await run(tar, ["-xf", input.path, "-C", dest.path], env: DocSupport.archiveEnvironment, what: "tar")
        case "gz":
            let gzip = try context.tools.require("gzip")
            let inner = innerName(forGzip: input)
            let copy = dest.appendingPathComponent(inner + ".gz")
            try fm.copyItem(at: input, to: copy)
            progress(0.2)
            try await run(gzip, ["-d", "-f", copy.path], what: "gzip")
        default:
            throw EngineError.unsupported("extracting \(format)")
        }
        progress(0.85)
        try removeEscapingLinks(in: dest)

        // A single top-level folder is unwrapped (no "name/name/…" nesting); either way the result is folder `<name>`.
        let top = try fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.lastPathComponent != ".DS_Store" }
        guard !top.isEmpty else { throw EngineError.failed("\(input.lastPathComponent) is empty") }
        var result = dest
        if top.count == 1, DocSupport.isDirectory(top[0]),
           (try? top[0].resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
            result = top[0]
        }
        let dir = DocSupport.outputDirectory(for: input, context: context)
        return try context.namer.commit(result, to: OutputNamer.unique(dir.appendingPathComponent(folderName(for: input), isDirectory: true)))
    }

    /// "photos.zip" → "photos"; "notes.txt.gz" → "notes" (no extension, so the folder never looks like a file type).
    static func folderName(for archive: URL) -> String {
        var base = OutputNamer.baseName(of: archive)
        let ext = (base as NSString).pathExtension
        if !ext.isEmpty, FormatCatalog.format(for: URL(fileURLWithPath: "/x/" + base)) != nil {
            base = (base as NSString).deletingPathExtension
        }
        return base.isEmpty ? "Archive" : base
    }

    /// "notes.txt.gz" → "notes.txt"; "data.gzip" → "data".
    static func innerName(forGzip url: URL) -> String {
        let name = url.lastPathComponent
        for ext in [".gz", ".gzip", ".GZ"] where name.hasSuffix(ext) && name.count > ext.count {
            return String(name.dropLast(ext.count))
        }
        return name + ".out"
    }

    // MARK: Safety

    static func lines(_ s: String) -> [String] {
        s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Rejects absolute paths, `..` components, home-relative and drive-letter paths.
    static func isUnsafe(_ entry: String) -> Bool {
        let e = entry.trimmingCharacters(in: .init(charactersIn: "\r"))
        if e.hasPrefix("/") || e.hasPrefix("\\") || e.hasPrefix("~") { return true }
        if e.count >= 2, e.dropFirst().first == ":", e.first?.isLetter == true { return true }
        let parts = e.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.contains("..")
    }

    static func validate(entries: [String], archive: URL) throws {
        if let bad = entries.first(where: isUnsafe) {
            docLog.error("refusing \(archive.lastPathComponent, privacy: .public): unsafe entry \(bad, privacy: .public)")
            throw EngineError.invalidInput("\(archive.lastPathComponent) contains an unsafe path (\(bad)); not extracted")
        }
    }

    /// Deletes symlinks that are absolute or resolve outside the extraction root.
    static func removeEscapingLinks(in root: URL) throws {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        var bad: [URL] = []
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
            if target.hasPrefix("/") { bad.append(url); continue }
            let parentPath = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            let resolved = URL(fileURLWithPath: parentPath).appendingPathComponent(target).standardizedFileURL.path
            if resolved != rootPath && !resolved.hasPrefix(rootPath + "/") { bad.append(url) }
        }
        for url in bad {
            docLog.error("removed escaping symlink \(url.lastPathComponent, privacy: .public)")
            try fm.removeItem(at: url)
        }
    }

    // MARK: Helpers

    private static func run(_ tool: URL, _ args: [String], env: [String: String]? = nil, what: String) async throws {
        do {
            try await ProcessRunner.run(tool, args, environment: env)
        } catch let e as ProcessError {
            let tail = e.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").suffix(3).joined(separator: "\n")
            throw EngineError.failed("\(what) failed (exit \(e.exitCode))\(tail.isEmpty ? "" : ": \(tail)")")
        }
    }
}
