import Foundation
import RondoKit

/// Fallback core checks when `scripts/test.sh` can't run (e.g. Testing.framework missing).
enum SelfTest {
    static func run() async -> Int32 {
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "✔" : "✘") \(name)")
            if !ok { failures.append(name) }
        }

        check("catalog ids unique", Set(FormatCatalog.all.map(\.id)).count == FormatCatalog.all.count)
        check("tar.gz detection", FormatCatalog.format(for: URL(fileURLWithPath: "/x/a.tar.gz"))?.id == "tar.gz")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rondo-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("a.png")
        FileManager.default.createFile(atPath: input.path, contents: Data([1]))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.jpg").path, contents: Data([1]))
        check("namer collision", OutputNamer().url(for: input, ext: "jpg").lastPathComponent == "a 2.jpg")

        let echo = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["ok"])
        check("process runner", echo?.stdout == "ok\n")

        let registry = makeRegistry()
        for engine in registry.engines {
            check("engine \(engine.id) has capabilities", !engine.conversions().isEmpty || !engine.tools().isEmpty)
        }
        print("\(registry.allConversions.count) conversions, \(registry.allTools.count) tools")
        print(failures.isEmpty ? "selftest passed" : "selftest FAILED: \(failures.count)")
        return failures.isEmpty ? 0 : 1
    }
}
