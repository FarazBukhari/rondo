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
        let dir = final.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Cross-volume moves are copy+delete: a failure mid-copy would leave a partial file at the
        // final name. Stage a hidden copy in the destination first, then rename on that volume.
        var source = temp
        var staged: URL?
        if !Self.sameVolume(temp, dir) {
            let hidden = dir.appendingPathComponent(".rondo-partial-\(UUID().uuidString)-\(final.lastPathComponent)", isDirectory: final.hasDirectoryPath)
            do {
                try fm.copyItem(at: temp, to: hidden)
            } catch {
                try? fm.removeItem(at: hidden)
                throw error
            }
            staged = hidden
            source = hidden
        }
        defer { if let staged, Self.exists(staged) { try? fm.removeItem(at: staged) } }

        var target = Self.unique(final)
        for _ in 0..<50 {
            do {
                try fm.moveItem(at: source, to: target)
                if staged != nil { try? fm.removeItem(at: temp) }
                return target
            } catch CocoaError.fileWriteFileExists {
                target = Self.unique(target)   // lost a race; pick the next free name
            }
        }
        throw EngineError.failed("Could not find a free output name near \(final.lastPathComponent)")
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return true }
        return va.isEqual(vb)
    }

    /// Existence without following symlinks: a dangling link still occupies its name.
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    func directory(for input: URL, destination: Destination) -> URL {
        switch destination {
        case .besideOriginal: input.deletingLastPathComponent()
        case .folder(let url): url
        }
    }

    /// First non-existing variant of `url`: "x.ext", "x 2.ext", "x 3.ext", …
    public static func unique(_ url: URL) -> URL {
        guard exists(url) else { return url }
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        // Folders have no extension: "my.report (pages)" → "my.report (pages) 2".
        let base = url.hasDirectoryPath ? name : baseName(of: url)
        let ext = name.count > base.count ? String(name.dropFirst(base.count)) : ""   // includes leading "."
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(n)\(ext)", isDirectory: url.hasDirectoryPath)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}
