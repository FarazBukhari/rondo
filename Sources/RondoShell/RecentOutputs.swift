import Foundation

/// Most-recent-first list of output files, shared by the HUD (writer) and the status menu (reader).
/// Persisted as paths in UserDefaults so the menu survives relaunch; missing files are skipped.
@MainActor
public final class RecentOutputs {
    public static let shared = RecentOutputs()

    public let limit: Int
    private let defaults: UserDefaults
    private let key = "recentOutputs.v1"
    private var urls: [URL]

    public init(limit: Int = 12, defaults: UserDefaults = .standard) {
        self.limit = limit
        self.defaults = defaults
        urls = (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// Outputs that still exist, newest first.
    public var items: [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public func add(_ new: [URL]) {
        guard !new.isEmpty else { return }
        let paths = Set(new.map(\.path))
        urls = Array((new.reversed() + urls.filter { !paths.contains($0.path) }).prefix(limit))
        defaults.set(urls.map(\.path), forKey: key)
    }

    public func clear() {
        urls = []
        defaults.removeObject(forKey: key)
    }
}
