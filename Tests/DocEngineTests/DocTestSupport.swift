import Foundation
import RondoKit
@testable import DocEngine

/// Shared helpers: per-test scratch dirs under fixtures/out/W5/, job runner, small file utilities.
enum W5 {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `fixtures/out/W5/tests`, emptied once per test process so runs don't pile up on a tight disk.
    static let runRoot: URL = {
        let r = repoRoot.appendingPathComponent("fixtures/out/W5/tests", isDirectory: true)
        try? FileManager.default.removeItem(at: r)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }()

    /// Fresh directory `fixtures/out/W5/tests/<name>-<short uuid>`.
    static func dir(_ name: String) throws -> URL {
        let d = runRoot.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static let engine = DocumentEngine()

    /// Runs one conversion job, writing into `out`. Returns the output URLs.
    static func convert(_ input: URL, to target: String, out: URL? = nil,
                        options: [String: OptionValue] = [:]) async throws -> [URL] {
        let dest = out ?? input.deletingLastPathComponent()
        let temp = try TempDir.make(prefix: "w5test")
        defer { TempDir.remove(temp) }
        let ctx = JobContext(tempDir: temp, destination: .folder(dest))
        let spec = JobSpec(inputs: [input], operation: .convert(to: target), options: options, destination: .folder(dest))
        return try await engine.run(spec, context: ctx)
    }

    static func one(_ input: URL, to target: String, out: URL? = nil) async throws -> URL {
        let r = try await convert(input, to: target, out: out)
        guard r.count == 1 else { throw EngineError.failed("expected 1 output, got \(r.count)") }
        return r[0]
    }

    @discardableResult
    static func write(_ text: String, to dir: URL, name: String) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// Runs a system tool synchronously; returns (exit code, stdout).
    @discardableResult
    static func sh(_ exe: String, _ args: [String], cwd: URL? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func zipOK(_ url: URL) -> Bool { sh("/usr/bin/unzip", ["-tq", url.path]).0 == 0 }

    static func zipEntry(_ url: URL, _ entry: String) -> String? {
        let (code, out) = sh("/usr/bin/unzip", ["-p", url.path, entry])
        return code == 0 ? out : nil
    }

    /// Hand-built ustar archive (lets tests create entries tar itself would refuse, like "../evil").
    static func ustar(_ entries: [(name: String, data: Data, symlink: String?)]) -> Data {
        var out = Data()
        for e in entries {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ off: Int, _ len: Int) {
                for (i, b) in Array(s.utf8).prefix(len).enumerated() { h[off + i] = b }
            }
            func octal(_ v: Int, _ off: Int, _ len: Int) { put(String(format: "%0\(len - 1)o", v), off, len - 1) }
            put(e.name, 0, 100)
            octal(e.symlink == nil ? 0o644 : 0o777, 100, 8)
            octal(0, 108, 8); octal(0, 116, 8)
            octal(e.symlink == nil ? e.data.count : 0, 124, 12)
            octal(1_700_000_000, 136, 12)
            h[156] = e.symlink == nil ? UInt8(ascii: "0") : UInt8(ascii: "2")
            if let link = e.symlink { put(link, 157, 100) }
            put("ustar", 257, 6); put("00", 263, 2)
            for i in 148..<156 { h[i] = 0x20 }
            let sum = h.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", sum), 148, 6); h[154] = 0; h[155] = 0x20
            out.append(contentsOf: h)
            if e.symlink == nil {
                out.append(e.data)
                let pad = (512 - e.data.count % 512) % 512
                out.append(Data(count: pad))
            }
        }
        out.append(Data(count: 1024))
        return out
    }
}
