import Foundation

public enum WheelKind: String, Codable, Sendable, CaseIterable {
    case convert, tools, actions
}

public enum WheelPayload: Hashable, Sendable {
    case convert(String)     // Format.id
    case tool(ToolID)
    case action(ActionID)
}

public struct WheelItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let payload: WheelPayload

    public init(id: String, title: String, symbol: String, payload: WheelPayload) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.payload = payload
    }
}

public protocol WheelItemProvider: Sendable {
    func items(for inputs: [URL], wheel: WheelKind) -> [WheelItem]
}

/// Builds wheel items from the engine registry (convert/tools) and the fixed action list.
public struct RegistryWheelItemProvider: WheelItemProvider {
    public let registry: EngineRegistry

    public init(registry: EngineRegistry) {
        self.registry = registry
    }

    public func items(for inputs: [URL], wheel: WheelKind) -> [WheelItem] {
        guard !inputs.isEmpty else { return [] }
        switch wheel {
        case .convert:
            return registry.convertTargets(for: inputs).map {
                WheelItem(id: "convert.\($0.id)", title: $0.displayName, symbol: $0.kind.symbol, payload: .convert($0.id))
            }
        case .tools:
            return registry.tools(for: inputs).map {
                WheelItem(id: $0.id.rawValue, title: $0.title, symbol: $0.symbol, payload: .tool($0.id))
            }
        case .actions:
            return ActionID.allCases.map {
                WheelItem(id: "action.\($0.rawValue)", title: $0.title, symbol: $0.symbol, payload: .action($0))
            }
        }
    }
}
