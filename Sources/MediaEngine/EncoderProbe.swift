import Foundation
import RondoKit

struct EncoderSet: Sendable {
    let names: Set<String>
    init(_ names: Set<String>) { self.names = names }
    func has(_ name: String) -> Bool { names.contains(name) }
}

/// Cached `ffmpeg -encoders` listing, keyed by ffmpeg path.
enum EncoderProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Set<String>] = [:]

    static func cached(_ ffmpeg: URL) -> Set<String>? {
        lock.withLock { cache[ffmpeg.path] }
    }

    static func encoders(ffmpeg: URL) async -> Set<String> {
        if let hit = cached(ffmpeg) { return hit }
        do {
            let r = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-encoders"])
            let set = parse(r.stdout)
            if !set.isEmpty { lock.withLock { cache[ffmpeg.path] = set } }
            return set
        } catch {
            mediaLog.error("ffmpeg -encoders failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Synchronous variant for `conversions()` / `tools()`. Runs the probe on a detached task and
    /// waits (bounded). A failed or timed-out probe is not cached, so the next call retries.
    static func encodersBlocking(ffmpeg: URL) -> Set<String> {
        if let hit = cached(ffmpeg) { return hit }
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.set(await encoders(ffmpeg: ffmpeg))
            sem.signal()
        }
        if sem.wait(timeout: .now() + 15) == .timedOut {
            mediaLog.error("ffmpeg -encoders probe timed out")
            return []
        }
        return box.get()
    }

    /// Parses lines like ` V....D libx264              libx264 H.264 …` after the `------` separator.
    static func parse(_ output: String) -> Set<String> {
        var names = Set<String>()
        var inList = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("------") { inList = true; continue }
            guard inList else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6 else { continue }
            names.insert(String(parts[1]))
        }
        return names
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Set<String> = []
        func set(_ v: Set<String>) { lock.withLock { value = v } }
        func get() -> Set<String> { lock.withLock { value } }
    }
}
