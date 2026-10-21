import Foundation

public enum TempDir {
    /// Root for all Rondo scratch space: $TMPDIR/Rondo.
    public static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Rondo", isDirectory: true)
    }

    /// Fresh unique directory under `root`.
    public static func make(prefix: String = "job") throws -> URL {
        let dir = root.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deletes leftovers under `root` (from crashes or forced quits) last modified more than
    /// `olderThan` seconds ago. Young entries are kept so a concurrently running rondo-cli or app
    /// instance isn't disturbed. Returns the number of entries removed.
    @discardableResult
    public static func sweep(olderThan age: TimeInterval = 3600, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var removed = 0
        for child in children {
            let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(modified) > age else { continue }
            if (try? fm.removeItem(at: child)) != nil { removed += 1 }
        }
        return removed
    }

    /// Removes a directory previously returned by `make`. Refuses anything outside `root`.
    public static func remove(_ dir: URL) {
        let rootPath = root.standardizedFileURL.path
        guard dir.standardizedFileURL.path.hasPrefix(rootPath + "/") else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
