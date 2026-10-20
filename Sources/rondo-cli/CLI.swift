import CoreImage
import Foundation
import ImageEngine
import ImageIO
import UniformTypeIdentifiers
import MediaEngine
import PDFEngine
import RondoKit

/// Same engine set as the app's composition root.
/// P3 interim: DocumentEngine (W5) joins in P4.
func makeRegistry(tools: ToolLocator = ToolLocator()) -> EngineRegistry {
    EngineRegistry(engines: [
        RasterEngine(tools: tools),
        PDFDocumentEngine(tools: tools),
        FFmpegEngine(tools: tools),
    ])
}

enum CLI {
    static let usage = """
    usage: rondo-cli <command> [args]

      list <file...>                         convert targets + tools for the files (as one batch)
      matrix                                 every conversion pair this Mac supports
      convert <file...> --to <fmt> [--out <dir>] [--opt k=v ...]
      tool <tool.id> <file...> [--out <dir>] [--opt k=v ...]
      smoke <srcDir> <outDir> [--min 0.9] [--only <kind>]
      selftest                               quick core checks
      gen-qr <text> <out.png>                write a QR code PNG (fixture helper)

    Option values: true/false → bool, 3 → int, 0.5 → double, 1,2,3 → list, 0-1.5,3-4 → ranges, else string.
    Outputs go beside the inputs unless --out is given.
    """

    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else {
            print(usage)
            return 2
        }
        let rest = Array(args.dropFirst())
        switch command {
        case "list": return list(rest)
        case "matrix": return matrix()
        case "convert": return await convert(rest)
        case "tool": return await tool(rest)
        case "smoke": return await Smoke.run(rest)
        case "selftest": return await SelfTest.run()
        case "gen-qr": return genQR(rest)
        case "help", "-h", "--help":
            print(usage)
            return 0
        default:
            fputs("unknown command: \(command)\n\(usage)\n", stderr)
            return 2
        }
    }

    // MARK: Commands

    static func list(_ args: [String]) -> Int32 {
        let files = args.map(fileURL)
        guard !files.isEmpty else { fputs("list: no files\n", stderr); return 2 }
        let registry = makeRegistry()
        for f in files {
            let fmt = FormatCatalog.format(for: f)
            print("\(f.lastPathComponent): \(fmt?.id ?? "?") (\(FormatCatalog.kind(for: f).rawValue))")
        }
        print("convert → " + registry.convertTargets(for: files).map(\.id).joined(separator: " "))
        let tools = registry.tools(for: files).map { t -> String in
            var flags: [String] = []
            if t.needsUI { flags.append("ui") }
            if case .combine = t.multiInput { flags.append("combine") }
            return flags.isEmpty ? t.id.rawValue : "\(t.id.rawValue)[\(flags.joined(separator: ","))]"
        }
        print("tools   → " + tools.joined(separator: " "))
        return 0
    }

    static func matrix() -> Int32 {
        let registry = makeRegistry()
        let byFrom = Dictionary(grouping: registry.allConversions, by: \.from)
        for from in byFrom.keys.sorted(by: { FormatCatalog.rank($0) < FormatCatalog.rank($1) }) {
            let tos = byFrom[from]!.map(\.to).sorted { FormatCatalog.rank($0) < FormatCatalog.rank($1) }
            print("\(from) → \(tos.joined(separator: " "))")
        }
        print("\(registry.allConversions.count) conversions, \(registry.allTools.count) tools")
        return 0
    }

    static func convert(_ args: [String]) async -> Int32 {
        var p = ArgParser(args)
        guard let to = p.value("--to") else { fputs("convert: --to <fmt> required\n", stderr); return 2 }
        let spec = JobSpec(inputs: p.positionals.map(fileURL), operation: .convert(to: to), options: p.options, destination: p.destination)
        return await execute(spec, registry: makeRegistry())
    }

    static func tool(_ args: [String]) async -> Int32 {
        var p = ArgParser(args)
        guard let id = p.positionals.first else { fputs("tool: <tool.id> required\n", stderr); return 2 }
        let registry = makeRegistry()
        let toolID = ToolID(id)
        let defaults = registry.tool(toolID)?.defaultOptions ?? [:]
        let spec = JobSpec(
            inputs: p.positionals.dropFirst().map(fileURL),
            operation: .tool(toolID),
            options: defaults.merging(p.options) { _, explicit in explicit },
            destination: p.destination
        )
        return await execute(spec, registry: registry)
    }

    static func execute(_ spec: JobSpec, registry: EngineRegistry) async -> Int32 {
        guard !spec.inputs.isEmpty else { fputs("no input files\n", stderr); return 2 }
        let result = await Runner.run(spec, registry: registry, timeout: 600)
        result.outputs.forEach { print($0.path) }
        result.failures.forEach { fputs("error: \($0)\n", stderr) }
        if result.jobCount == 0 { fputs("nothing to do\n", stderr) }
        return result.failures.isEmpty ? 0 : 1
    }

    static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}

/// Runs one JobSpec through a fresh JobQueue and collects results.
enum Runner {
    struct Result {
        var jobCount = 0
        var outputs: [URL] = []
        var failures: [String] = []
    }

    static func run(_ spec: JobSpec, registry: EngineRegistry, timeout: TimeInterval) async -> Result {
        let queue = JobQueue(registry: registry)
        let stream = queue.subscribe()
        let ids = await queue.submit(spec)
        var result = Result(jobCount: ids.count)
        guard !ids.isEmpty else { return result }

        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await queue.cancelAll()
        }
        defer { watchdog.cancel() }

        var remaining = Set(ids)
        for await event in stream {
            guard remaining.contains(event.jobID) else { continue }
            switch event {
            case .finished(let id, let urls):
                result.outputs += urls
                remaining.remove(id)
            case .failed(let id, let message):
                result.failures.append(message)
                remaining.remove(id)
            case .cancelled(let id):
                result.failures.append("cancelled (timeout \(Int(timeout))s)")
                remaining.remove(id)
            default:
                break
            }
            if remaining.isEmpty { break }
        }
        return result
    }
}

struct ArgParser {
    var positionals: [String] = []
    var options: [String: OptionValue] = [:]
    var flags: [String: String] = [:]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--opt", i + 1 < args.count {
                let kv = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { options[kv[0]] = Self.parse(kv[1]) }
                i += 2
            } else if a.hasPrefix("--"), i + 1 < args.count {
                flags[a] = args[i + 1]
                i += 2
            } else {
                positionals.append(a)
                i += 1
            }
        }
    }

    mutating func value(_ flag: String) -> String? { flags[flag] }

    var destination: Destination {
        guard let out = flags["--out"] else { return .besideOriginal }
        let url = CLI.fileURL(out)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return .folder(url)
    }

    static func parse(_ raw: String) -> OptionValue {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if let i = Int(raw) { return .int(i) }
        if let d = Double(raw) { return .double(d) }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count > 1 || raw.contains("-") {
            let ranges = parts.compactMap { part -> ClosedRange<Double>? in
                let ends = part.split(separator: "-", maxSplits: 1).compactMap { Double($0) }
                guard ends.count == 2, ends[0] <= ends[1] else { return nil }
                return ends[0]...ends[1]
            }
            if ranges.count == parts.count { return .ranges(ranges) }
            let numbers = parts.compactMap(Double.init)
            if numbers.count == parts.count { return .list(numbers) }
        }
        return .string(raw)
    }
}

extension CLI {
    static func genQR(_ args: [String]) -> Int32 {
        guard args.count == 2, let filter = CIFilter(name: "CIQRCodeGenerator") else {
            fputs("usage: rondo-cli gen-qr <text> <out.png>\n", stderr)
            return 2
        }
        filter.setValue(Data(args[0].utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let qr = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return 1 }
        let padded = qr.transformed(by: CGAffineTransform(translationX: 32, y: 32))
            .composited(over: CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -32, dy: -32).offsetBy(dx: 32, dy: 32)))
        let context = CIContext()
        guard let cg = context.createCGImage(padded, from: padded.extent),
              let dest = CGImageDestinationCreateWithURL(fileURL(args[1]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? 0 : 1
    }
}
