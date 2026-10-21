import Foundation
import Testing
@testable import RondoKit

/// Engine stub with fixed capabilities that writes a tiny output file per input.
struct StubEngine: Engine {
    let id: String
    var pairs: [ConversionDescriptor] = []
    var toolList: [ToolDescriptor] = []
    var delayNanos: UInt64 = 0

    func conversions() -> [ConversionDescriptor] { pairs }
    func tools() -> [ToolDescriptor] { toolList }

    func run(_ job: JobSpec, context: JobContext) async throws -> [URL] {
        var outputs: [URL] = []
        for (i, input) in job.inputs.enumerated() {
            if delayNanos > 0 { try await Task.sleep(nanoseconds: delayNanos) }
            context.progress(Double(i + 1) / Double(job.inputs.count) * 0.9)
            let ext: String
            switch job.operation {
            case .convert(let to): ext = FormatCatalog.format(id: to)?.preferredExtension ?? to
            case .tool: ext = input.pathExtension
            }
            let temp = context.tempFile(named: "out.\(ext)")
            FileManager.default.createFile(atPath: temp.path, contents: Data("out".utf8))
            outputs.append(try context.namer.commit(temp, to: context.outputURL(for: input, ext: ext, suffix: job.operation == .convert(to: ext) ? nil : "out")))
        }
        return outputs
    }
}

@Suite struct FormatCatalogTests {
    @Test func lookupByExtensionCaseInsensitive() {
        #expect(FormatCatalog.format(for: URL(fileURLWithPath: "/x/IMG_1.JPEG"))?.id == "jpg")
        #expect(FormatCatalog.format(for: URL(fileURLWithPath: "/x/a.heif"))?.id == "heic")
        #expect(FormatCatalog.format(for: URL(fileURLWithPath: "/x/clip.MOV"))?.kind == .video)
        #expect(FormatCatalog.format(for: URL(fileURLWithPath: "/x/notes.markdown"))?.id == "md")
    }

    @Test func compoundExtensionWins() {
        #expect(FormatCatalog.format(for: URL(fileURLWithPath: "/x/logs.tar.gz"))?.id == "tar.gz")
        #expect(FormatCatalog.format(for: URL(fileURLWithPath: "/x/data.gz"))?.id == "gz")
    }

    @Test func lookupByUTType() {
        #expect(FormatCatalog.format(utType: "com.adobe.pdf")?.id == "pdf")
        #expect(FormatCatalog.format(utType: "public.mp3")?.kind == .audio)
    }

    @Test func folderAndUnknown() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(FormatCatalog.kind(for: dir) == .folder)
        #expect(FormatCatalog.kind(for: URL(fileURLWithPath: "/x/thing.zzz")) == .unknown)
    }

    @Test func idsUnique() {
        #expect(Set(FormatCatalog.all.map(\.id)).count == FormatCatalog.all.count)
    }
}

@Suite struct EngineRegistryTests {
    let registry = EngineRegistry(engines: [
        StubEngine(id: "img", pairs: conversions(from: ["jpg", "png", "heic"], to: ["jpg", "png", "webp", "heic"])
            + [ConversionDescriptor(from: "svg", to: "png")],
                   toolList: [
                    ToolDescriptor(id: "image.compress", title: "Compress", symbol: "arrow.down.circle", accepts: [.image]),
                    ToolDescriptor(id: "image.toPDF", title: "To PDF", symbol: "doc", accepts: [.image], multiInput: .combine(minimum: 1)),
                    ToolDescriptor(id: "image.crop", title: "Crop", symbol: "crop", accepts: [.image], multiInput: .single, needsUI: true),
                   ]),
        StubEngine(id: "media", pairs: conversions(from: ["mp4", "mov"], to: ["mp4", "mov", "gif"]),
                   toolList: [ToolDescriptor(id: "video.join", title: "Join", symbol: "film", accepts: [.video], multiInput: .combine(minimum: 2))]),
    ])

    private func u(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    @Test func singleInputTargetsExcludeSelf() {
        let ids = registry.convertTargets(for: [u("a.jpg")]).map(\.id)
        #expect(ids == ["png", "heic", "webp"])   // catalog order, no jpg
    }

    @Test func batchIntersectionAllowsAlreadyInTarget() {
        let ids = Set(registry.convertTargets(for: [u("a.jpg"), u("b.png")]).map(\.id))
        #expect(ids == ["jpg", "png", "heic", "webp"])
    }

    @Test func mixedKindsHaveNoCommonTarget() {
        #expect(registry.convertTargets(for: [u("a.jpg"), u("b.mp4")]).isEmpty)
    }

    @Test func oneWayInput() {
        #expect(registry.convertTargets(for: [u("a.svg")]).map(\.id) == ["png"])
        #expect(registry.convertTargets(for: [u("a.svg"), u("b.jpg")]).map(\.id) == ["png"])
    }

    @Test func unknownInputHasNothing() {
        #expect(registry.convertTargets(for: [u("a.zzz")]).isEmpty)
    }

    @Test func toolsRespectKindAndCount() {
        #expect(Set(registry.tools(for: [u("a.jpg")]).map(\.id.rawValue)) == ["image.compress", "image.toPDF", "image.crop"])
        #expect(Set(registry.tools(for: [u("a.jpg"), u("b.png")]).map(\.id.rawValue)) == ["image.compress", "image.toPDF"])
        #expect(registry.tools(for: [u("a.mp4")]).isEmpty)
        #expect(registry.tools(for: [u("a.mp4"), u("b.mov")]).map(\.id.rawValue) == ["video.join"])
    }

    @Test func rejectedFormatsHideTool() {
        let reg = EngineRegistry(engines: [StubEngine(id: "x", toolList: [
            ToolDescriptor(id: "image.compress", title: "Compress", symbol: "a", accepts: [.image], rejectsFormats: ["svg"]),
        ])])
        #expect(reg.tools(for: [u("a.svg")]).isEmpty)
        #expect(reg.tools(for: [u("a.png")]).count == 1)
        #expect(reg.tools(for: [u("a.png"), u("b.svg")]).isEmpty)
    }

    @Test func engineLookup() {
        #expect(registry.engine(for: JobSpec(inputs: [u("a.mov")], operation: .convert(to: "gif")))?.id == "media")
        #expect(registry.engine(for: JobSpec(inputs: [u("a.jpg")], operation: .tool("image.crop")))?.id == "img")
        #expect(registry.engine(for: JobSpec(inputs: [u("a.jpg")], operation: .convert(to: "mp4"))) == nil)
    }

    @Test func wheelProvider() {
        let provider = RegistryWheelItemProvider(registry: registry)
        #expect(provider.items(for: [u("a.jpg")], wheel: .convert).first?.payload == .convert("png"))
        #expect(provider.items(for: [u("a.jpg")], wheel: .actions).count == ActionID.allCases.count)
        #expect(provider.items(for: [], wheel: .tools).isEmpty)
    }
}

@Suite struct SettingsTests {
    @Test func roundTrip() throws {
        var s = Settings()
        s.toolsModifier = .command
        s.destination = .folder(URL(fileURLWithPath: "/tmp/out"))
        s.toolPaths = ["ffmpeg": "/x/ffmpeg"]
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(Settings.self, from: data) == s)
    }

    @Test func partialJSONKeepsDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"videoCRF": 30, "bogus": 1}"#.utf8))
        #expect(s.videoCRF == 30)
        #expect(s.convertModifier == .shift)
        #expect(s.imageQuality == Settings().imageQuality)
    }

    @Test func wheelTriggerRoundTripsAndDefaults() throws {
        var s = Settings()
        #expect(s.wheelTrigger == .press)
        s.wheelTrigger = .tap
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s)).wheelTrigger == .tap)
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).wheelTrigger == .press)
    }

    @Test func clearedHotkeyStaysCleared() throws {
        var s = Settings()
        s.hotkey = nil
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        #expect(decoded.hotkey == nil)
    }

    @Test func modifierMapping() {
        let s = Settings()
        #expect(s.wheel(for: .shift) == .convert)
        #expect(s.wheel(for: .option) == .tools)
        #expect(s.wheel(for: .control) == .actions)
        #expect(s.wheel(for: .command) == nil)
    }
}
