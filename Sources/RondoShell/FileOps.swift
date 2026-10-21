import Foundation
import RondoKit

/// "Copy Path": POSIX paths, one per line, in drop order, duplicates removed.
public enum PathJoiner {
    public static func join(_ urls: [URL]) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted { lines.append(path) }
        }
        return lines.joined(separator: "\n")
    }
}

/// Folders Terminal should open at: a plain folder opens at itself, a file (or package such as
/// `.app`) at its parent. Order kept, duplicates removed.
public enum TerminalTargets {
    public static func directories(for urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var dirs: [URL] = []
        for url in urls {
            let u = url.standardizedFileURL
            let dir = FileOps.isPlainDirectory(u) ? u : u.deletingLastPathComponent()
            if seen.insert(dir.path).inserted { dirs.append(dir) }
        }
        return dirs
    }
}

/// One file the Move action handled.
public struct MoveOutcome: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case moved(to: URL)
        /// Cross-volume: the verified copy is in place but the original couldn't be removed.
        case copiedOriginalKept(to: URL, reason: String)
        /// Already in the destination folder — nothing to do.
        case alreadyThere
        case failed(String)
    }
    public let source: URL
    public let status: Status

    public var destination: URL? {
        switch status {
        case .moved(let to), .copiedOriginalKept(let to, _): to
        default: nil
        }
    }
}

/// The only shell code that relocates user files. Never overwrites: every name is resolved with
/// Finder-style collision naming ("photo 2.jpg") and claimed with an exclusive rename.
///
/// Same volume → one atomic rename. Across volumes → copy to a hidden temp name inside the
/// destination folder, verify item count + byte size, rename into place, and only then remove the
/// original. Any failure before that removes the partial copy and leaves the original untouched.
/// Synchronous and potentially slow (cross-volume copies) — call off the main thread.
public enum FileMover {
    /// Free URL for `source` inside `directory`: "photo.jpg" → "photo 2.jpg" → "photo 3.jpg";
    /// plain folders get the number at the end ("Project.v2" → "Project.v2 2").
    public static func destination(for source: URL, in directory: URL, fileManager fm: FileManager = .default) -> URL {
        let name = source.standardizedFileURL.lastPathComponent
        let isDir = FileOps.isPlainDirectory(source)
        let first = directory.appendingPathComponent(name, isDirectory: isDir)
        guard isDir else { return OutputNamer.unique(first) }
        guard fm.fileExists(atPath: first.path) else { return first }
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent("\(name) \(n)", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Moves each source into `directory`. Sources already there are left alone; a folder is never
    /// moved into itself or a descendant. Failures are reported per file, not thrown.
    public static func move(_ sources: [URL], to directory: URL, fileManager fm: FileManager = .default) -> [MoveOutcome] {
        move(sources, to: directory, fileManager: fm, forceCopy: false)
    }

    /// `forceCopy` exercises the cross-volume path on one volume (tests).
    static func move(_ sources: [URL], to directory: URL, fileManager fm: FileManager, forceCopy: Bool) -> [MoveOutcome] {
        let dir = directory.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return sources.map { MoveOutcome(source: $0, status: .failed("Destination is not a folder.")) }
        }
        var outcomes: [MoveOutcome] = []
        var seen = Set<String>()
        for raw in sources {
            let source = raw.standardizedFileURL
            guard seen.insert(source.path).inserted else { continue }
            let link = FileOps.isSymlink(source)
            guard link || fm.fileExists(atPath: source.path) else {
                outcomes.append(MoveOutcome(source: source, status: .failed("File no longer exists.")))
                continue
            }
            let parent = source.deletingLastPathComponent().resolvingSymlinksInPath()
            if parent.path == dir.path {
                outcomes.append(MoveOutcome(source: source, status: .alreadyThere))
                continue
            }
            // A symlink is moved as a link, so only its own location matters, not its target.
            let container = link ? parent.appendingPathComponent(source.lastPathComponent).path : source.resolvingSymlinksInPath().path
            if dir.path == container || dir.path.hasPrefix(container + "/") {
                outcomes.append(MoveOutcome(source: source, status: .failed("Can't move a folder into itself.")))
                continue
            }
            let crossVolume = forceCopy || !FileOps.sameVolume(parent, dir)
            outcomes.append(crossVolume ? copyThenRemove(source, into: dir, fm) : rename(source, into: dir, fm))
        }
        return outcomes
    }

    /// Same volume: exclusive atomic rename, retrying the next free name if one gets taken.
    private static func rename(_ source: URL, into dir: URL, _ fm: FileManager) -> MoveOutcome {
        for _ in 0..<50 {
            let target = destination(for: source, in: dir, fileManager: fm)
            do {
                try FileOps.renameExclusive(source, to: target)
                return MoveOutcome(source: source, status: .moved(to: target))
            } catch FileOps.RenameError.exists {
                continue
            } catch FileOps.RenameError.crossDevice {
                return copyThenRemove(source, into: dir, fm)   // volume check missed (e.g. firmlink)
            } catch {
                return MoveOutcome(source: source, status: .failed(error.localizedDescription))
            }
        }
        return MoveOutcome(source: source, status: .failed("No free name in the destination folder."))
    }

    /// Cross volume: copy → verify → claim final name → remove original.
    private static func copyThenRemove(_ source: URL, into dir: URL, _ fm: FileManager) -> MoveOutcome {
        guard fm.isDeletableFile(atPath: source.path) else {
            return MoveOutcome(source: source, status: .failed("The original can't be removed (no permission), so it wasn't moved."))
        }
        let temp = dir.appendingPathComponent(".rondo-move-\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)")
        func fail(_ why: String) -> MoveOutcome {
            if FileOps.isSymlink(temp) || fm.fileExists(atPath: temp.path) { try? fm.removeItem(at: temp) }
            return MoveOutcome(source: source, status: .failed(why))
        }
        do {
            try fm.copyItem(at: source, to: temp)
        } catch {
            return fail(error.localizedDescription)
        }
        guard let want = FileOps.treeStats(source, fm), let got = FileOps.treeStats(temp, fm), want == got else {
            return fail("The copy didn't match the original (size or item count).")
        }
        var final: URL?
        for _ in 0..<50 {
            let target = destination(for: source, in: dir, fileManager: fm)
            do {
                try FileOps.renameExclusive(temp, to: target)
                final = target
                break
            } catch FileOps.RenameError.exists {
                continue
            } catch {
                return fail(error.localizedDescription)
            }
        }
        guard let final else { return fail("No free name in the destination folder.") }
        do {
            try fm.removeItem(at: source)
        } catch {
            return MoveOutcome(source: source, status: .copiedOriginalKept(to: final, reason: error.localizedDescription))
        }
        return MoveOutcome(source: source, status: .moved(to: final))
    }
}

enum FileOps {
    enum RenameError: Error, LocalizedError {
        case exists
        case crossDevice
        case posix(Int32)

        var errorDescription: String? {
            switch self {
            case .exists: "An item with that name already exists."
            case .crossDevice: "Source and destination are on different volumes."
            case .posix(let code): String(cString: strerror(code))
            }
        }
    }

    /// `rename` that fails instead of replacing an existing item (`RENAME_EXCL`).
    static func renameExclusive(_ from: URL, to: URL) throws {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        switch code {
        case EEXIST: throw RenameError.exists
        case EXDEV: throw RenameError.crossDevice
        case ENOTSUP, EINVAL:
            // File system without RENAME_EXCL: FileManager refuses existing targets too.
            do {
                try FileManager.default.moveItem(at: from, to: to)
            } catch CocoaError.fileWriteFileExists {
                throw RenameError.exists
            }
        default: throw RenameError.posix(code)
        }
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    /// False when either volume can't be determined (the caller then takes the safe copy path).
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    struct TreeStats: Equatable {
        var items = 0
        var bytes: Int64 = 0
    }

    /// Item count + total regular-file bytes, not following symlinks. Nil if anything is unreadable.
    static func treeStats(_ url: URL, _ fm: FileManager) -> TreeStats? {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        func add(_ u: URL, to stats: inout TreeStats) -> Bool {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return false }
            stats.items += 1
            if v.isRegularFile == true, v.isSymbolicLink != true { stats.bytes += Int64(v.fileSize ?? 0) }
            return true
        }
        var stats = TreeStats()
        guard add(url, to: &stats) else { return nil }
        guard !isSymlink(url), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return stats }
        var failed = false
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in
            failed = true
            return false
        }) else { return nil }
        for case let child as URL in e {
            guard add(child, to: &stats) else { return nil }
        }
        return failed ? nil : stats
    }

    /// Directory that is not a package (`.app`, `.rtfd`, …).
    static func isPlainDirectory(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
            return url.hasDirectoryPath
        }
        return (v.isDirectory ?? false) && !(v.isPackage ?? false)
    }
}
