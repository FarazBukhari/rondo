import Foundation

/// Finds external executables. Apps launched from Finder get a minimal PATH, so search
/// explicit locations first: bundled bin → user override → Homebrew (Intel, Apple Silicon) → system → $PATH.
public struct ToolLocator: Sendable {
    public var overrides: [String: String]
    public var searchDirectories: [URL]

    public init(overrides: [String: String] = [:], bundleBin: URL? = Bundle.main.resourceURL?.appendingPathComponent("bin")) {
        self.overrides = overrides
        var dirs: [URL] = []
        if let bundleBin { dirs.append(bundleBin) }
        dirs += ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].map { URL(fileURLWithPath: $0) }
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for p in envPath.split(separator: ":") {
            let u = URL(fileURLWithPath: String(p))
            if !dirs.contains(u) { dirs.append(u) }
        }
        searchDirectories = dirs
    }

    /// Locator using the tool-path overrides saved in Settings.
    public static func fromSettings(_ settings: Settings = .load()) -> ToolLocator {
        ToolLocator(overrides: settings.toolPaths)
    }

    public func url(for tool: String) -> URL? {
        let fm = FileManager.default
        if let o = overrides[tool], !o.isEmpty, fm.isExecutableFile(atPath: o) {
            return URL(fileURLWithPath: o)
        }
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(tool)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func has(_ tool: String) -> Bool { url(for: tool) != nil }

    /// URL for `tool` or a `missingTool` error.
    public func require(_ tool: String) throws -> URL {
        guard let u = url(for: tool) else { throw EngineError.missingTool(tool) }
        return u
    }
}
