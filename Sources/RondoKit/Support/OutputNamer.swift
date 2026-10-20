import Foundation

/// Decides where outputs go and never overwrites anything: Finder-style collision names
/// ("photo.jpg" → "photo 2.jpg" → "photo 3.jpg").
public struct OutputNamer: Sendable {
    public init() {}

    /// Base name without (compound) extension: "a.tar.gz" → "a", "photo.jpeg" → "photo".
    public static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for f in FormatCatalog.all {
            for ext in f.extensions where ext.contains(".") && lower.hasSuffix("." + ext) {
                return String(name.dropLast(ext.count + 1))
            }
        }
        let ext = url.pathExtension
        return ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    }

    /// Unique output file URL for `input` with extension `ext`.
    /// `suffix` is appended after a space: ("photo", "compressed") → "photo compressed.jpg".
    public func url(for input: URL, ext: String, suffix: String? = nil, destination: Destination = .besideOriginal) -> URL {
        let dir = directory(for: input, destination: destination)
        var stem = Self.baseName(of: input)
        if let suffix, !suffix.isEmpty { stem += " " + suffix }
        return Self.unique(dir.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)"))
    }

    /// Unique output folder for multi-file results: "doc (pages)", "doc (pages) 2".
    public func folder(for input: URL, suffix: String, destination: Destination = .besideOriginal) -> URL {
        let dir = directory(for: input, destination: destination)
        return Self.unique(dir.appendingPathComponent("\(Self.baseName(of: input)) (\(suffix))", isDirectory: true))
    }

    /// Moves a finished temp file/folder to `final`, re-resolving collisions at commit time.
    /// Returns the URL actually written.
    @discardableResult
    public func commit(_ temp: URL, to final: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        var target = Self.unique(final)
        for _ in 0..<50 {
            do {
                try fm.moveItem(at: temp, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                target = Self.unique(target)   // lost a race; pick the next free name
            }
        }
        throw EngineError.failed("Could not find a free output name near \(final.lastPathComponent)")
    }

    func directory(for input: URL, destination: Destination) -> URL {
        switch destination {
        case .besideOriginal: input.deletingLastPathComponent()
        case .folder(let url): url
        }
    }

    /// First non-existing variant of `url`: "x.ext", "x 2.ext", "x 3.ext", …
    public static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let base = baseName(of: url)
        let ext = name.count > base.count ? String(name.dropFirst(base.count)) : ""   // includes leading "."
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(n)\(ext)", isDirectory: url.hasDirectoryPath)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
