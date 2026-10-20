import Foundation

/// Aggregates engine capabilities and answers "what can I do with these files?".
/// Capabilities are snapshotted at init (they probe tools); call `refreshed()` after settings change.
public final class EngineRegistry: Sendable {
    public let engines: [any Engine]
    private let conversionsByEngine: [(engineIndex: Int, pairs: Set<ConversionDescriptor>)]
    private let toolsByEngine: [(engineIndex: Int, tools: [ToolDescriptor])]

    public init(engines: [any Engine]) {
        self.engines = engines
        conversionsByEngine = engines.enumerated().map { ($0.offset, Set($0.element.conversions())) }
        toolsByEngine = engines.enumerated().map { ($0.offset, $0.element.tools()) }
    }

    public func refreshed() -> EngineRegistry { EngineRegistry(engines: engines) }

    /// All conversion pairs, deduplicated.
    public var allConversions: Set<ConversionDescriptor> {
        conversionsByEngine.reduce(into: Set()) { $0.formUnion($1.pairs) }
    }

    /// All tools, first engine wins on duplicate IDs.
    public var allTools: [ToolDescriptor] {
        var seen = Set<ToolID>()
        return toolsByEngine.flatMap(\.tools).filter { seen.insert($0.id).inserted }
    }

    public func supports(from: String, to: String) -> Bool {
        conversionsByEngine.contains { $0.pairs.contains(ConversionDescriptor(from: from, to: to)) }
    }

    /// Output formats valid for every input. An input already in the target format counts as
    /// valid (the queue skips it); at least one input must actually need converting.
    public func convertTargets(for inputs: [URL]) -> [Format] {
        let sources = inputs.map { FormatCatalog.format(for: $0)?.id }
        guard !sources.isEmpty, sources.allSatisfy({ $0 != nil }) else { return [] }
        let ids = sources.compactMap { $0 }
        let all = allConversions
        var candidates = Set(all.filter { $0.from == ids[0] }.map(\.to))
        candidates.insert(ids[0])
        for id in ids.dropFirst() {
            var reachable = Set(all.filter { $0.from == id }.map(\.to))
            reachable.insert(id)
            candidates.formIntersection(reachable)
        }
        candidates = candidates.filter { target in ids.contains { $0 != target } }
        return candidates
            .sorted { FormatCatalog.rank($0) < FormatCatalog.rank($1) }
            .compactMap(FormatCatalog.format(id:))
    }

    /// Tools that accept every input's kind and the input count.
    public func tools(for inputs: [URL]) -> [ToolDescriptor] {
        guard !inputs.isEmpty else { return [] }
        let kinds = Set(inputs.map(FormatCatalog.kind(for:)))
        let formats = Set(inputs.compactMap { FormatCatalog.format(for: $0)?.id })
        return allTools.filter { tool in
            guard kinds.isSubset(of: tool.accepts), tool.rejectsFormats.isDisjoint(with: formats) else { return false }
            switch tool.multiInput {
            case .each: return true
            case .single: return inputs.count == 1
            case .combine(let minimum): return inputs.count >= minimum
            }
        }
    }

    public func tool(_ id: ToolID) -> ToolDescriptor? {
        allTools.first { $0.id == id }
    }

    /// Engine able to run `job` (looks at the first input for conversions).
    public func engine(for job: JobSpec) -> (any Engine)? {
        switch job.operation {
        case .convert(let to):
            guard let first = job.inputs.first, let from = FormatCatalog.format(for: first)?.id else { return nil }
            return conversionsByEngine
                .first { $0.pairs.contains(ConversionDescriptor(from: from, to: to)) }
                .map { engines[$0.engineIndex] }
        case .tool(let id):
            return toolsByEngine
                .first { $0.tools.contains { $0.id == id } }
                .map { engines[$0.engineIndex] }
        }
    }
}
