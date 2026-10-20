import Foundation

/// Namespaced tool identifier, e.g. "image.compress", "video.trim", "pdf.merge".
public struct ToolID: Hashable, Codable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// File actions (Actions wheel). Handled by RondoShell, never by engines.
public enum ActionID: String, Codable, Sendable, CaseIterable {
    case airdrop, float, copy, move, copyPath, terminal

    public var title: String {
        switch self {
        case .airdrop: "AirDrop"
        case .float: "Float"
        case .copy: "Copy"
        case .move: "Move"
        case .copyPath: "Copy Path"
        case .terminal: "Terminal"
        }
    }

    public var symbol: String {
        switch self {
        case .airdrop: "dot.radiowaves.left.and.right"
        case .float: "pin"
        case .copy: "doc.on.doc"
        case .move: "folder"
        case .copyPath: "link"
        case .terminal: "terminal"
        }
    }
}

public enum OptionValue: Hashable, Codable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    /// Time ranges in seconds, page ranges (1-based, inclusive), etc.
    case ranges([ClosedRange<Double>])
    /// Generic list (page order, filter names, …).
    case list([Double])
}

public enum Operation: Hashable, Codable, Sendable {
    case convert(to: String)   // Format.id
    case tool(ToolID)
}

public enum Destination: Hashable, Codable, Sendable {
    case besideOriginal
    case folder(URL)
}

public struct JobSpec: Hashable, Codable, Sendable {
    public var inputs: [URL]
    public var operation: Operation
    public var options: [String: OptionValue]
    public var destination: Destination

    public init(inputs: [URL], operation: Operation, options: [String: OptionValue] = [:], destination: Destination = .besideOriginal) {
        self.inputs = inputs
        self.operation = operation
        self.options = options
        self.destination = destination
    }

    // MARK: Typed option access (engines fall back to their own defaults)

    public func bool(_ key: String, default d: Bool) -> Bool {
        if case .bool(let v)? = options[key] { return v }
        return d
    }

    public func int(_ key: String, default d: Int) -> Int {
        switch options[key] {
        case .int(let v)?: return v
        case .double(let v)?: return Int(v)
        default: return d
        }
    }

    public func double(_ key: String, default d: Double) -> Double {
        switch options[key] {
        case .double(let v)?: return v
        case .int(let v)?: return Double(v)
        default: return d
        }
    }

    public func string(_ key: String) -> String? {
        if case .string(let v)? = options[key] { return v }
        return nil
    }

    public func ranges(_ key: String) -> [ClosedRange<Double>] {
        if case .ranges(let v)? = options[key] { return v }
        return []
    }

    public func list(_ key: String) -> [Double] {
        if case .list(let v)? = options[key] { return v }
        return []
    }
}

/// How a tool treats multiple inputs.
public enum MultiInput: Hashable, Sendable {
    /// Run once per input file (JobQueue splits the batch).
    case each
    /// All inputs form one job (merge, join, collage, images → PDF).
    case combine(minimum: Int)
    /// Exactly one input.
    case single
}

/// Describes a tool option for headless defaults and settings/editor UI.
public struct OptionSpec: Hashable, Sendable {
    public enum Control: Hashable, Sendable {
        case slider(min: Double, max: Double, step: Double)
        case integer(min: Int, max: Int)
        case toggle
        case choice([String])
        case text
        case bytes          // target file size
        case ranges         // time/page ranges
        case rect           // list x,y,w,h (source pixels, top-left origin)
        case list           // numeric list (page order, rotations, regions…)
        case json           // structured payload as JSON string (annotation shapes)
    }

    public let key: String
    public let title: String
    public let control: Control
    public let defaultValue: OptionValue?

    public init(key: String, title: String, control: Control, defaultValue: OptionValue?) {
        self.key = key
        self.title = title
        self.control = control
        self.defaultValue = defaultValue
    }
}

public struct ToolDescriptor: Hashable, Sendable, Identifiable {
    public let id: ToolID
    public let title: String
    public let symbol: String
    public let accepts: Set<FileKind>
    public let multiInput: MultiInput
    /// True → the shell opens the matching editor window first; the engine still runs headless
    /// with the explicit options the editor produces.
    public let needsUI: Bool
    public let options: [OptionSpec]
    /// Format ids this tool can't handle even though their kind is accepted (e.g. "svg" for image.compress).
    public let rejectsFormats: Set<String>

    public init(id: ToolID, title: String, symbol: String, accepts: Set<FileKind>, multiInput: MultiInput = .each, needsUI: Bool = false, options: [OptionSpec] = [], rejectsFormats: Set<String> = []) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.accepts = accepts
        self.multiInput = multiInput
        self.needsUI = needsUI
        self.options = options
        self.rejectsFormats = rejectsFormats
    }

    /// Default option values from the specs.
    public var defaultOptions: [String: OptionValue] {
        options.reduce(into: [:]) { acc, spec in
            if let v = spec.defaultValue { acc[spec.key] = v }
        }
    }
}

public struct ConversionDescriptor: Hashable, Sendable {
    public let from: String   // Format.id
    public let to: String     // Format.id
    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Convenience: every pair in `from × to`, skipping identity.
public func conversions(from: [String], to: [String]) -> [ConversionDescriptor] {
    from.flatMap { f in to.filter { $0 != f }.map { ConversionDescriptor(from: f, to: $0) } }
}
