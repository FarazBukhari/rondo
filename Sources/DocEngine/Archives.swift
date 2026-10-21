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
            // "--" so a name starting with "-" is never parsed as an option. ditto/gzip only get absolute paths.
            try await run(tar, [format == "tar" ? "-cf" : "-czf", out.path, "-C", parent.path, "--", name],
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

    static func extract(_ input: URL, from format: String, job: JobSpec = JobSpec(inputs: [], operation: .convert(to: "folder")),
                        context: JobContext, progress: (Double) -> Void) async throws -> URL {
        try DocSupport.requireInput(input)
        let fm = FileManager.default
        let work = try DocSupport.scratchDir(context)
        let dest = work.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let limits = Limits.forExtraction(into: work, job: job)
        let name = input.lastPathComponent
        let startFree = DocSupport.freeBytes(at: work) ?? 0
        let consumed: @Sendable () -> Int64 = { max(0, startFree - (DocSupport.freeBytes(at: work) ?? startFree)) }

        switch format {
        case "zip":
            let listed: [ZipEntry]
            do { listed = try ZipReader.entries(input, maxEntries: limits.maxEntries) } catch let f as ZipReader.Failure {
                throw EngineError.invalidInput("\(name) isn't a usable ZIP: \(f.description)")
            }
            try validate(try zipListing(listed, archive: input), archive: input, limits: limits)
            progress(0.2)
            let ditto = try context.tools.require("ditto")
            try await runWatched(ditto, ["-x", "-k", input.path, dest.path], what: "ditto", archive: name,
                                 limit: limits.maxBytes, measure: consumed)
            try? fm.removeItem(at: dest.appendingPathComponent("__MACOSX"))
        case "tar", "tar.gz", "rar":
            let tar = try context.tools.require("tar")
            if format == "rar", !(await Probe.verifyTarReadsRAR(tar)) {
                try Task.checkCancellation()
                throw EngineError.unsupported("RAR archives: \(tar.path) can't read them on this Mac")
            }
            try validate(try await tarListing(input, tar: tar), archive: input, limits: limits)
            progress(0.2)
            try await runWatched(tar, ["-xf", input.path, "-C", dest.path], env: DocSupport.archiveEnvironment, what: "tar",
                                 archive: name, limit: limits.maxBytes, measure: consumed)
        case "gz":
            let gzip = try context.tools.require("gzip")
            let inner = innerName(forGzip: input)
            let declared = gzipDeclaredSize(input)
            if declared > limits.maxBytes { throw tooLarge(name, declared, limits) }
            let copy = dest.appendingPathComponent(inner + ".gz")
            try fm.copyItem(at: input, to: copy)
            progress(0.2)
            let out = dest.appendingPathComponent(inner)
            try await runWatched(gzip, ["-d", "-f", copy.path], what: "gzip", archive: name,
                                 limit: limits.maxBytes, measure: { Int64(DocSupport.fileSize(out)) })
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

    /// Extraction caps: uncompressed bytes ≤ min(20 GB, 80% of free space on the temp volume), entries ≤ 100k.
    /// Job options `maxExtractBytes` / `maxExtractEntries` can only lower them (tests use this).
    struct Limits {
        var maxBytes: Int64
        var maxEntries: Int

        static func forExtraction(into dir: URL, job: JobSpec) -> Limits {
            let free = DocSupport.freeBytes(at: dir) ?? (20 << 30)
            var bytes = min(Int64(20) << 30, Int64(Double(free) * 0.8))
            if job.options["maxExtractBytes"] != nil { bytes = min(bytes, Int64(max(0, job.int("maxExtractBytes", default: 0)))) }
            var entries = 100_000
            if job.options["maxExtractEntries"] != nil { entries = min(entries, max(0, job.int("maxExtractEntries", default: 0))) }
            return Limits(maxBytes: bytes, maxEntries: entries)
        }
    }

    enum EntryKind { case file, directory, symlink, hardlink, other }

    struct ListedEntry {
        var path: String
        var kind: EntryKind
        /// Link target(s). Several candidates when a text listing is ambiguous; all must be safe.
        var targets: [String] = []
        var size: Int64 = 0
    }

    static func tooLarge(_ name: String, _ bytes: Int64, _ limits: Limits) -> EngineError {
        let f = ByteCountFormatter()
        return .invalidInput("\(name) would expand to \(f.string(fromByteCount: bytes)), over the \(f.string(fromByteCount: limits.maxBytes)) limit; not extracted")
    }

    /// Rejects: too many entries, too many bytes, unsafe paths, links with absolute/`..` targets,
    /// and any entry whose path runs through a symlink entry (e.g. `l -> /x` then `l/f`).
    static func validate(_ entries: [ListedEntry], archive: URL, limits: Limits) throws {
        let name = archive.lastPathComponent
        guard entries.count <= limits.maxEntries else {
            throw EngineError.invalidInput("\(name) has \(entries.count) entries, over the \(limits.maxEntries) limit; not extracted")
        }
        let total = entries.reduce(Int64(0)) { $0 &+ max(0, $1.size) }
        if total > limits.maxBytes || total < 0 { throw tooLarge(name, total, limits) }

        var linkPaths = Set<String>()
        for e in entries {
            if isUnsafe(e.path) { throw refuse(archive, "unsafe path \(e.path)") }
            if e.kind == .symlink || e.kind == .hardlink {
                if e.targets.isEmpty { throw refuse(archive, "link \(e.path) has no readable target") }
                if let bad = e.targets.first(where: { $0.isEmpty || isUnsafe($0) }) {
                    throw refuse(archive, "link \(e.path) points outside the archive (\(bad))")
                }
            }
            if e.kind == .symlink { linkPaths.insert(normalized(e.path)) }
        }
        guard !linkPaths.isEmpty else { return }
        for e in entries {
            let parts = normalized(e.path).split(separator: "/")
            guard parts.count > 1 else { continue }
            for i in 1..<parts.count where linkPaths.contains(parts[0..<i].joined(separator: "/")) {
                throw refuse(archive, "\(e.path) is inside the symbolic link \(parts[0..<i].joined(separator: "/"))")
            }
        }
    }

    private static func refuse(_ archive: URL, _ why: String) -> EngineError {
        docLog.error("refusing \(archive.lastPathComponent, privacy: .public): \(why, privacy: .public)")
        return .invalidInput("\(archive.lastPathComponent) contains an unsafe entry (\(why)); not extracted")
    }

    /// Comparison key: "./A//b/" → "a/b" (APFS is case-insensitive and normalization-insensitive by default).
    static func normalized(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .filter { $0 != "." }
            .joined(separator: "/")
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    static func zipListing(_ entries: [ZipEntry], archive: URL) throws -> [ListedEntry] {
        try entries.map { z in
            var e = ListedEntry(path: z.name, kind: z.isDirectory ? .directory : .file,
                                size: Int64(clamping: z.uncompressedSize))
            if z.isSymlink {
                e.kind = .symlink
                do {
                    let target = try ZipReader.read(archive, entry: z, maxBytes: 4096)
                    e.targets = [String(decoding: target, as: UTF8.self)]
                } catch {
                    throw refuse(archive, "unreadable symbolic link \(z.name)")
                }
            }
            return e
        }
    }

    /// `tar -tf` gives exact names; `tar -tvf` (C locale) gives types, sizes and link targets, line for line.
    static func tarListing(_ archive: URL, tar: URL) async throws -> [ListedEntry] {
        var env = DocSupport.archiveEnvironment
        env["LC_ALL"] = "C"
        let names = try await ProcessRunner.run(tar, ["-tf", archive.path], environment: env, checkExit: false)
        let verbose = try await ProcessRunner.run(tar, ["-tvf", archive.path], environment: env, checkExit: false)
        guard names.exitCode == 0, verbose.exitCode == 0 else {
            throw EngineError.invalidInput("\(archive.lastPathComponent) isn't a readable archive")
        }
        let n = lines(names.stdout), v = lines(verbose.stdout)
        guard n.count == v.count else { throw refuse(archive, "listing couldn't be verified") }
        return zip(n, v).map { name, line in
            var e = ListedEntry(path: name, kind: .other, size: tarSize(line))
            switch line.first {
            case "-": e.kind = .file
            case "d": e.kind = .directory
            case "l": e.kind = .symlink; e.targets = candidates(after: " -> ", in: line)
            case "h": e.kind = .hardlink; e.targets = candidates(after: " link to ", in: line)
            default: e.kind = .other
            }
            return e
        }
    }

    /// Every substring following an occurrence of `marker` (names may contain the marker; all candidates must pass).
    static func candidates(after marker: String, in line: String) -> [String] {
        var out: [String] = []
        var search = line.startIndex..<line.endIndex
        while let r = line.range(of: marker, range: search) {
            out.append(String(line[r.upperBound...]))
            search = r.upperBound..<line.endIndex
        }
        return out
    }

    private static let sizeRegex = try! NSRegularExpression(
        pattern: #"\s(\d+)\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4})\s"#)

    /// Size column of a `tar -tvf` line (the number just before the date). Unparseable → 0; the watchdog still applies.
    static func tarSize(_ line: String) -> Int64 {
        guard let m = sizeRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let r = Range(m.range(at: 1), in: line) else { return 0 }
        return Int64(line[r]) ?? Int64.max
    }

    /// ISIZE trailer (uncompressed size mod 2³²). A hint only — the watchdog enforces the real cap.
    static func gzipDeclaredSize(_ url: URL) -> Int64 {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size >= 4, (try? fh.seek(toOffset: size - 4)) != nil,
              let d = try? fh.read(upToCount: 4), d.count == 4 else { return 0 }
        return Int64(d.u32(0))
    }

    /// Removes symlinks that are absolute or whose relative target has any `..` component. Lexical resolution
    /// can be fooled by chained links (`e -> ..`, `s -> d/e/../..`), so `..` is refused outright.
    static func removeEscapingLinks(in root: URL) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        var bad: [URL] = []
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
            if isUnsafe(target) { bad.append(url) }
        }
        for url in bad {
            docLog.error("removed escaping symlink \(url.lastPathComponent, privacy: .public)")
            try fm.removeItem(at: url)
        }
    }

    /// Runs an extractor while polling `measure()`; stops it (and fails) once output exceeds `limit`.
    static func runWatched(_ tool: URL, _ args: [String], env: [String: String]? = nil, what: String, archive: String,
                           limit: Int64, measure: @escaping @Sendable () -> Int64) async throws {
        let overLimit = EngineError.invalidInput("\(archive) expands beyond the \(ByteCountFormatter().string(fromByteCount: limit)) limit; extraction stopped")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await run(tool, args, env: env, what: what) }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 150_000_000)
                    if measure() > limit { throw overLimit }
                }
            }
            try await group.next()
            group.cancelAll()
        }
        if measure() > limit { throw overLimit }
    }

    // MARK: Helpers

    static func run(_ tool: URL, _ args: [String], env: [String: String]? = nil, what: String) async throws {
        do {
            try await ProcessRunner.run(tool, args, environment: env)
        } catch let e as ProcessError {
            let tail = e.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").suffix(3).joined(separator: "\n")
            throw EngineError.failed("\(what) failed (exit \(e.exitCode))\(tail.isEmpty ? "" : ": \(tail)")")
        }
    }
}
