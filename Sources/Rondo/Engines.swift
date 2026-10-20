import Foundation
import ImageEngine
import MediaEngine
import PDFEngine
import RondoKit

/// The app's engine set. Keep in sync with `rondo-cli`'s `makeRegistry`.
func makeRegistry(settings: Settings) -> (EngineRegistry, ToolLocator) {
    let tools = ToolLocator.fromSettings(settings)
    let registry = EngineRegistry(engines: [
        RasterEngine(tools: tools),
        PDFDocumentEngine(tools: tools),
        FFmpegEngine(tools: tools),
    ])
    return (registry, tools)
}

/// Settings-derived defaults merged under explicit options for a job.
func defaultOptions(for operation: RondoKit.Operation, inputs: [URL], registry: EngineRegistry, settings: Settings) -> [String: OptionValue] {
    var options: [String: OptionValue] = [:]
    let inputKinds = Set(inputs.map(FormatCatalog.kind(for:)))
    switch operation {
    case .convert(let to):
        let target = FormatCatalog.format(id: to)
        if target?.kind == .image || inputKinds.contains(.image) {
            options["quality"] = .double(settings.imageQuality)
        }
        if inputKinds.contains(.pdf), target?.kind == .image {
            options["dpi"] = .int(settings.pdfRenderDPI)
        }
    case .tool(let id):
        options = registry.tool(id)?.defaultOptions ?? [:]
        if inputKinds == [.image], options["quality"] == nil {
            options["quality"] = .double(settings.imageQuality)
        }
    }
    return options
}
