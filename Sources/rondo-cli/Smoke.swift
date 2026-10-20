import Foundation
import RondoKit

/// Runs every advertised conversion for every fixture, plus headless tools, and validates outputs.
enum Smoke {
    struct Row {
        let kind: FileKind
        let label: String
        let ok: Bool
        let detail: String
        let seconds: Double
    }

    /// Explicit options for tools whose defaults alone can't run headless (needsUI tools etc.).
    /// Keys follow docs/ARCHITECTURE.md "Tool option keys" + engine reports.
    static var headlessOptions: [String: [String: OptionValue]] = [
        "image.crop": ["rect": .list([10, 10, 80, 60])],
        "image.redact": ["rect": .list([10, 10, 40, 30])],
        "video.trim": ["ranges": .ranges([0.5...1.5])],
        "audio.trim": ["ranges": .ranges([0.5...1.5])],
        "video.crop": ["rect": .list([0, 0, 80, 60])],
        "video.split": ["ranges": .ranges([0...1, 1...2])],
        "video.snapshot": ["time": .double(1)],
        "audio.bleep": ["ranges": .ranges([0.5...1.0])],
        "pdf.reorder": ["order": .list([2, 1])],
        "pdf.split": ["ranges": .ranges([1...1, 2...2])],
    ]

    /// Fixture pairs for combine tools, by kind.
    static let combineInputs: [FileKind: [String]] = [
        .image: ["sample.png", "second.png"],
        .video: ["sample.mp4", "second.mp4"],
        .pdf: ["sample.pdf", "images.pdf"],
    ]

    static func run(_ args: [String]) async -> Int32 {
        var p = ArgParser(args)
        guard p.positionals.count == 2 else {
            fputs("usage: rondo-cli smoke <srcDir> <outDir> [--min 0.9] [--only <kind>]\n", stderr)
            return 2
        }
        let src = CLI.fileURL(p.positionals[0])
        let out = CLI.fileURL(p.positionals[1])
        let minRatio = Double(p.value("--min") ?? "") ?? 0.9
        let only = p.value("--only").flatMap(FileKind.init(rawValue:))
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let registry = makeRegistry()
        let fixtures = ((try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var rows: [Row] = []

        for fixture in fixtures {
            let kind = FormatCatalog.kind(for: fixture)
            if let only, kind != only { continue }
            let from = FormatCatalog.format(for: fixture)?.id ?? "?"

            for target in registry.convertTargets(for: [fixture]) {
                let dir = out.appendingPathComponent("\(fixture.lastPathComponent)→\(target.id)", isDirectory: true)
                let spec = JobSpec(inputs: [fixture], operation: .convert(to: target.id), destination: .folder(dir))
                rows.append(await check(spec, kind: kind, label: "\(from) → \(target.id)", expect: target.id, registry: registry, dir: dir))
            }

            for tool in registry.tools(for: [fixture]) {
                if case .combine = tool.multiInput { continue }
                let dir = out.appendingPathComponent("\(fixture.lastPathComponent)⚙\(tool.id.rawValue)", isDirectory: true)
                let options = tool.defaultOptions.merging(headlessOptions[tool.id.rawValue] ?? [:]) { _, explicit in explicit }
                let spec = JobSpec(inputs: [fixture], operation: .tool(tool.id), options: options, destination: .folder(dir))
                rows.append(await check(spec, kind: kind, label: "\(from) ⚙ \(tool.id.rawValue)", expect: nil, registry: registry, dir: dir))
            }
        }

        for (kind, names) in combineInputs.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let only, kind != only { continue }
            let inputs = names.map { src.appendingPathComponent($0) }
            guard inputs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            for tool in registry.tools(for: inputs) {
                guard case .combine = tool.multiInput else { continue }
                let dir = out.appendingPathComponent("combine⚙\(tool.id.rawValue)", isDirectory: true)
                let options = tool.defaultOptions.merging(headlessOptions[tool.id.rawValue] ?? [:]) { _, explicit in explicit }
                let spec = JobSpec(inputs: inputs, operation: .tool(tool.id), options: options, destination: .folder(dir))
                rows.append(await check(spec, kind: kind, label: "\(names.joined(separator: "+")) ⚙ \(tool.id.rawValue)", expect: nil, registry: registry, dir: dir))
            }
        }

        return report(rows, minRatio: minRatio, out: out)
    }

    static func check(_ spec: JobSpec, kind: FileKind, label: String, expect: String?, registry: EngineRegistry, dir: URL) async -> Row {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let start = Date()
        let result = await Runner.run(spec, registry: registry, timeout: 120)
        let secs = Date().timeIntervalSince(start)
        if let failure = result.failures.first {
            return Row(kind: kind, label: label, ok: false, detail: oneLine(failure), seconds: secs)
        }
        if result.outputs.isEmpty {
            return Row(kind: kind, label: label, ok: false, detail: "no outputs", seconds: secs)
        }
        for output in result.outputs {
            if let problem = Validator.problem(with: output, expected: expect) {
                return Row(kind: kind, label: label, ok: false, detail: "\(output.lastPathComponent): \(problem)", seconds: secs)
            }
        }
        return Row(kind: kind, label: label, ok: true, detail: result.outputs.map(\.lastPathComponent).joined(separator: ", "), seconds: secs)
    }

    static func report(_ rows: [Row], minRatio: Double, out: URL) -> Int32 {
        var md = "| Kind | Pass | Fail |\n|------|------|------|\n"
        func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
        print(pad("kind", 12) + " pass  fail")
        for kind in FileKind.allCases {
            let r = rows.filter { $0.kind == kind }
            guard !r.isEmpty else { continue }
            let pass = r.filter(\.ok).count
            print(pad(kind.rawValue, 12) + String(format: " %4d  %4d", pass, r.count - pass))
            md += "| \(kind.rawValue) | \(pass) | \(r.count - pass) |\n"
        }
        let failures = rows.filter { !$0.ok }
        if !failures.isEmpty {
            print("\nFAILURES")
            md += "\n## Failures\n\n"
            for f in failures {
                print("  ✘ \(f.label): \(f.detail)")
                md += "- `\(f.label)`: \(f.detail)\n"
            }
        }
        let slow = rows.filter { $0.seconds > 10 }.sorted { $0.seconds > $1.seconds }.prefix(5)
        if !slow.isEmpty {
            print("\nSLOWEST")
            slow.forEach { print(String(format: "  %6.1fs  ", $0.seconds) + $0.label) }
        }
        let pass = rows.filter(\.ok).count
        let ratio = rows.isEmpty ? 0 : Double(pass) / Double(rows.count)
        let summary = String(format: "%d/%d passed (%.1f%%), threshold %.0f%%", pass, rows.count, ratio * 100, minRatio * 100)
        print("\n" + summary)
        md += "\n" + summary + "\n"
        try? md.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        return ratio >= minRatio ? 0 : 1
    }

    static func oneLine(_ s: String) -> String {
        let line = s.split(separator: "\n").map(String.init).first { !$0.isEmpty } ?? s
        return String(line.prefix(160))
    }
}
