import Foundation
import RondoKit

struct EncoderSet: Sendable {
    let names: Set<String>
    init(_ names: Set<String>) { self.names = names }
    func has(_ name: String) -> Bool { names.contains(name) }
}

/// Cached `ffmpeg -encoders` listing, keyed by ffmpeg path.
///
/// The probe never waits on Swift-concurrency work: it runs ffmpeg with Foundation `Process`
/// on the calling thread (sync path) or on a GCD queue (async path), with a GCD kill timer.
/// One probe at a time per process (behind `probeLock`), so concurrent first callers share it.
enum EncoderProbe {
    private static let cacheLock = NSLock()
    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Set<String>] = [:]
    nonisolated(unsafe) private static var spawned = 0

    static let timeout: TimeInterval = 10

    static func cached(_ ffmpeg: URL) -> Set<String>? {
        cacheLock.withLock { cache[ffmpeg.path] }
    }

    /// Number of ffmpeg probes actually spawned (tests).
    static var spawnCount: Int { cacheLock.withLock { spawned } }

    /// Drops the cache (tests).
    static func resetCache() { cacheLock.withLock { cache.removeAll() } }

    /// Async entry point: hops to a GCD thread so no cooperative-pool thread blocks on the subprocess.
    static func encoders(ffmpeg: URL) async -> Set<String> {
        if let hit = cached(ffmpeg) { return hit }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: encodersBlocking(ffmpeg: ffmpeg))
            }
        }
    }

    /// Synchronous probe for `conversions()` / `tools()`. Blocks only on the ffmpeg process.
    /// Failed probes are not cached, so the next call retries.
    static func encodersBlocking(ffmpeg: URL) -> Set<String> {
        if let hit = cached(ffmpeg) { return hit }
        probeLock.lock()
        defer { probeLock.unlock() }
        if let hit = cached(ffmpeg) { return hit }
        cacheLock.withLock { spawned += 1 }
        guard let output = runSync(ffmpeg, ["-hide_banner", "-nostdin", "-encoders"], timeout: timeout) else {
            mediaLog.error("ffmpeg -encoders probe failed or timed out")
            return []
        }
        let set = parse(output)
        if !set.isEmpty { cacheLock.withLock { cache[ffmpeg.path] = set } }
        return set
    }

    /// Runs a short-lived tool synchronously; SIGKILL after `timeout`. Nil on launch failure,
    /// non-zero exit, or timeout.
    static func runSync(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let pid = process.processIdentifier
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if process.isRunning { kill(pid, SIGKILL) } }
        timer.resume()

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
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
}
