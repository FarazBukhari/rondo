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

    /// Builds a ZIP with Python's zipfile (`/usr/bin/python3 -I`): entries may be symlinks or zero-filled blobs.
    /// Spec items: name, data (text), zeros (byte count), symlink (bool).
    static func pyzip(_ out: URL, _ spec: [[String: Any]]) throws {
        let scripts = runRoot.appendingPathComponent("_scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("mkzip.py")
        if !FileManager.default.fileExists(atPath: script.path) {
            try """
            import json, sys, zipfile
            out, spec = sys.argv[1], json.loads(sys.argv[2])
            with zipfile.ZipFile(out, "w") as z:
                for e in spec:
                    info = zipfile.ZipInfo(e["name"])
                    info.create_system = 3
                    info.external_attr = (0o120777 if e.get("symlink") else 0o100644) << 16
                    info.compress_type = zipfile.ZIP_STORED if e.get("symlink") else zipfile.ZIP_DEFLATED
                    data = b"\\0" * e["zeros"] if "zeros" in e else e.get("data", "").encode()
                    z.writestr(info, data)
            """.write(to: script, atomically: true, encoding: .utf8)
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: spec), as: UTF8.self)
        let (code, _) = sh("/usr/bin/python3", ["-I", script.path, out.path, json])
        guard code == 0 else { throw EngineError.failed("python zip fixture failed (\(code))") }
    }

    static func zipOK(_ url: URL) -> Bool { sh("/usr/bin/unzip", ["-tq", url.path]).0 == 0 }

    static func zipEntry(_ url: URL, _ entry: String) -> String? {
        let (code, out) = sh("/usr/bin/unzip", ["-p", url.path, entry])
        return code == 0 ? out : nil
    }

    /// Hand-built ustar archive (lets tests create entries tar itself would refuse, like "../evil").
    static func ustar(_ entries: [(name: String, data: Data, symlink: String?)]) -> Data {
        ustarLinks(entries.map { ($0.name, $0.data, $0.symlink.map { ("2", $0) }) })
    }

    /// `link` = (typeflag, linkname): "2" symlink, "1" hardlink.
    static func ustarLinks(_ entries: [(name: String, data: Data, link: (type: String, target: String)?)]) -> Data {
        var out = Data()
        for e in entries {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ off: Int, _ len: Int) {
                for (i, b) in Array(s.utf8).prefix(len).enumerated() { h[off + i] = b }
            }
            func octal(_ v: Int, _ off: Int, _ len: Int) { put(String(format: "%0\(len - 1)o", v), off, len - 1) }
            put(e.name, 0, 100)
            octal(e.link == nil ? 0o644 : 0o777, 100, 8)
            octal(0, 108, 8); octal(0, 116, 8)
            octal(e.link == nil ? e.data.count : 0, 124, 12)
            octal(1_700_000_000, 136, 12)
            h[156] = e.link.map { Array($0.type.utf8)[0] } ?? UInt8(ascii: "0")
            if let link = e.link { put(link.target, 157, 100) }
            put("ustar", 257, 6); put("00", 263, 2)
            for i in 148..<156 { h[i] = 0x20 }
            let sum = h.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", sum), 148, 6); h[154] = 0; h[155] = 0x20
            out.append(contentsOf: h)
            if e.link == nil {
                out.append(e.data)
                let pad = (512 - e.data.count % 512) % 512
                out.append(Data(count: pad))
            }
        }
        out.append(Data(count: 1024))
        return out
    }
}
