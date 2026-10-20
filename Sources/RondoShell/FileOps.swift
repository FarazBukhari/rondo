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
        /// Already in the destination folder — nothing to do.
        case alreadyThere
        case failed(String)
    }
    public let source: URL
    public let status: Status

    public var destination: URL? {
        if case .moved(let to) = status { return to }
        return nil
    }
}

/// The only shell code that relocates user files. Never overwrites: every name is resolved with
/// Finder-style collision naming ("photo 2.jpg") and re-resolved if another process wins a race.
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
            let resolved = source.resolvingSymlinksInPath()
            guard fm.fileExists(atPath: source.path) || isSymlink(source, fm) else {
                outcomes.append(MoveOutcome(source: source, status: .failed("File no longer exists.")))
                continue
            }
            if source.deletingLastPathComponent().resolvingSymlinksInPath().path == dir.path {
                outcomes.append(MoveOutcome(source: source, status: .alreadyThere))
                continue
            }
            if dir.path == resolved.path || dir.path.hasPrefix(resolved.path + "/") {
                outcomes.append(MoveOutcome(source: source, status: .failed("Can't move a folder into itself.")))
                continue
            }
            outcomes.append(moveOne(source, into: dir, fm))
        }
        return outcomes
    }

    private static func moveOne(_ source: URL, into dir: URL, _ fm: FileManager) -> MoveOutcome {
        var target = destination(for: source, in: dir, fileManager: fm)
        for _ in 0..<50 {
            do {
                try fm.moveItem(at: source, to: target)   // fails (never overwrites) if target exists
                return MoveOutcome(source: source, status: .moved(to: target))
            } catch CocoaError.fileWriteFileExists {
                target = destination(for: source, in: dir, fileManager: fm)
            } catch {
                return MoveOutcome(source: source, status: .failed(error.localizedDescription))
            }
        }
        return MoveOutcome(source: source, status: .failed("No free name in the destination folder."))
    }

    private static func isSymlink(_ url: URL, _ fm: FileManager) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

enum FileOps {
    /// Directory that is not a package (`.app`, `.rtfd`, …).
    static func isPlainDirectory(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
            return url.hasDirectoryPath
        }
        return (v.isDirectory ?? false) && !(v.isPackage ?? false)
    }
}
