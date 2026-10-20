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

    /// Removes a directory previously returned by `make`. Refuses anything outside `root`.
    public static func remove(_ dir: URL) {
        let rootPath = root.standardizedFileURL.path
        guard dir.standardizedFileURL.path.hasPrefix(rootPath + "/") else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
