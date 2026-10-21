import Foundation
import CoreGraphics
import os
import RondoKit

let docLog = Logger(subsystem: "com.farazbukhari.rondo", category: "docs")

enum DocSupport {
    /// Fresh scratch dir inside the job's temp dir.
    static func scratchDir(_ context: JobContext) throws -> URL {
        let d = context.tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Throws unless `url` is an existing regular file (packages like .rtfd are allowed when `allowPackage`).
    static func requireInput(_ url: URL, allowPackage: Bool = false) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw EngineError.invalidInput("\(url.lastPathComponent) doesn't exist")
        }
        if isDir.boolValue && !allowPackage {
            throw EngineError.invalidInput("\(url.lastPathComponent) is a folder")
        }
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Decodes text by BOM, then UTF-8, then Windows-1252, then Latin-1. Strips the BOM and normalizes line endings to LF.
    static func decodeText(_ data: Data) -> String {
        var s: String
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            s = String(decoding: data.dropFirst(3), as: UTF8.self)
        } else if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE {
            s = String(data: data, encoding: .utf16LittleEndian) ?? String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        } else if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF {
            s = String(data: data, encoding: .utf16BigEndian) ?? String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? ""
        } else if let u = String(data: data, encoding: .utf8) {
            s = u
        } else {
            s = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        }
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return normalizeNewlines(s)
    }

    static func normalizeNewlines(_ s: String) -> String {
        // Scalar check: in Swift "\r\n" is one Character, so `s.contains("\r")` misses CRLF.
        guard s.unicodeScalars.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func readText(_ url: URL) throws -> String {
        try requireInput(url)
        return decodeText(try Data(contentsOf: url))
    }

    /// Letter for US-style locales, else A4. `pageSize` option ("letter" / "a4") overrides.
    static func pageSize(_ option: String?) -> CGSize {
        switch option?.lowercased() {
        case "a4": return CGSize(width: 595.28, height: 841.89)
        case "letter": return CGSize(width: 612, height: 792)
        default:
            let region: String
            if #available(macOS 13, *) { region = Locale.current.region?.identifier ?? "US" } else { region = "US" }
            return ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR"].contains(region)
                ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
        }
    }

    static func languageCode() -> String {
        if #available(macOS 13, *) { return Locale.current.language.languageCode?.identifier ?? "en" }
        return "en"
    }

    /// Commits a finished temp output beside the input (or into the job destination).
    static func commit(_ temp: URL, for input: URL, ext: String, suffix: String? = nil, context: JobContext) throws -> URL {
        try context.namer.commit(temp, to: context.outputURL(for: input, ext: ext, suffix: suffix))
    }

    /// Directory the job's outputs land in (beside the input, or the chosen folder).
    static func outputDirectory(for input: URL, context: JobContext) -> URL {
        context.outputURL(for: input, ext: "x").deletingLastPathComponent()
    }

    /// Free bytes on the volume holding `url` (fresh value, no URL resource cache).
    static func freeBytes(at url: URL) -> Int64? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let v = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else { return nil }
        return Int64(v)
    }

    /// Environment for archive tools: no AppleDouble `._` files in tarballs.
    static var archiveEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"
        return env
    }
}

// MARK: - Probes

/// Capability probes. The synchronous path (used by `conversions()`) never touches Swift concurrency:
/// it runs Foundation `Process` on the calling thread with a hard kill timeout, cached once per key
/// behind a lock so concurrent first callers wait for one probe instead of spawning their own.
enum Probe {
    /// One cell per key; the global lock only guards the dictionary, never a running probe.
    private final class Cell: @unchecked Sendable {
        let lock = NSLock()
        var value: Bool?
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var cells: [String: Cell] = [:]

    private static func cell(_ key: String) -> Cell {
        registryLock.withLock {
            if let c = cells[key] { return c }
            let c = Cell()
            cells[key] = c
            return c
        }
    }

    /// Computes `key` once; concurrent first callers of the same key wait on that key's lock only.
    /// `nil` from `compute` (e.g. a timeout) is not cached.
    static func once(_ key: String, _ compute: () -> Bool?) -> Bool {
        let c = cell(key)
        c.lock.lock()
        defer { c.lock.unlock() }
        if let v = c.value { return v }
        guard let v = compute() else { return false }
        c.value = v
        return v
    }

    /// Async-side cache (short critical sections only; never held across a subprocess).
    private static let asyncLock = NSLock()
    nonisolated(unsafe) private static var asyncCache: [String: Bool] = [:]
    static func cached(_ key: String) -> Bool? { asyncLock.withLock { asyncCache[key] } }
    static func store(_ key: String, _ value: Bool) { asyncLock.withLock { asyncCache[key] = value } }

    /// Cheap advertising check: `tar` is bsdtar on libarchive ≥ 3 (RAR reader built in since 3.0).
    /// One `tar --version` spawn, ~10 ms, cached.
    static func tarAdvertisesRAR(_ tar: URL) -> Bool {
        once("rar-version:" + tar.path) {
            guard let r = SyncProcess.run(tar, ["--version"], timeout: 3) else { return nil }
            guard r.status == 0 else { return false }
            return libarchiveReadsRAR(versionOutput: r.output)
        }
    }

    static func libarchiveReadsRAR(versionOutput s: String) -> Bool {
        guard s.contains("bsdtar"),
              let r = s.range(of: #"libarchive (\d+)\."#, options: .regularExpression) else { return false }
        let major = Int(s[r].dropFirst("libarchive ".count).prefix { $0.isNumber }) ?? 0
        return major >= 3
    }

    /// Real check, run lazily by the first RAR job: list a tiny generated RAR4 archive. Async (ProcessRunner), cached.
    static func verifyTarReadsRAR(_ tar: URL) async -> Bool {
        let key = "rar-listing:" + tar.path
        if let hit = cached(key) { return hit }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rondo-rar-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var ok = false
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let rar = dir.appendingPathComponent("probe.rar")
            try RAR4Writer.archive(entries: [("probe.txt", Data("ok".utf8))]).write(to: rar)
            let r = try await ProcessRunner.run(tar, ["-tf", rar.path], checkExit: false)
            ok = r.exitCode == 0 && r.stdout.contains("probe.txt")
        } catch is CancellationError {
            return false   // not cached; the next job retries
        } catch {
            ok = false
        }
        store(key, ok)
        return ok
    }
}

/// Blocking subprocess for capability probes only (jobs use `ProcessRunner`). Runs on the calling thread;
/// output is drained on a GCD queue; the child gets SIGTERM at `timeout`, SIGKILL 1 s later.
enum SyncProcess {
    struct Result {
        let status: Int32
        let output: String
    }

    /// nil when the tool can't launch or timed out.
    static func run(_ exe: URL, _ args: [String], timeout: TimeInterval) -> Result? {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }

        let output = DataBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            docLog.error("probe \(exe.lastPathComponent, privacy: .public) timed out")
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                exited.wait()
            }
            _ = drained.wait(timeout: .now() + 1)
            return nil
        }
        _ = drained.wait(timeout: .now() + 1)
        return Result(status: p.terminationStatus, output: String(decoding: output.get(), as: UTF8.self))
    }

    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.withLock { data = d } }
        func get() -> Data { lock.withLock { data } }
    }
}

// MARK: - Tiny RAR 4.x writer (stored entries only) — used for the lazy RAR check and tests.

enum RAR4Writer {
    static func archive(entries: [(name: String, data: Data)]) -> Data {
        var out = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])   // marker block
        // Main archive header
        var main = Data([0x73])
        main.le16(0)            // flags
        main.le16(13)           // header size
        main.le16(0); main.le32(0)
        out.le16(UInt16(CRC32.checksum(main) & 0xFFFF))
        out.append(main)

        for (name, data) in entries {
            let nameData = Data(name.utf8)
            var h = Data([0x74])
            h.le16(0x8000)                          // LONG_BLOCK (data follows)
            h.le16(UInt16(32 + nameData.count))     // header size
            h.le32(UInt32(data.count))              // packed size
            h.le32(UInt32(data.count))              // unpacked size
            h.append(3)                             // host OS: Unix
            h.le32(CRC32.checksum(data))
            h.le32(0x5B21_0000)                     // DOS time (2025-09-01)
            h.append(20)                            // version needed
            h.append(0x30)                          // method: store
            h.le16(UInt16(nameData.count))
            h.le32(0o100644)                        // Unix mode
            h.append(nameData)
            out.le16(UInt16(CRC32.checksum(h) & 0xFFFF))
            out.append(h)
            out.append(data)
        }
        out.append(contentsOf: [0xC4, 0x3D, 0x7B, 0x00, 0x40, 0x07, 0x00])   // end of archive
        return out
    }
}
