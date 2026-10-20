import Foundation

/// Per-job services handed to an engine.
public struct JobContext: Sendable {
    /// 0...1. Throttled and clamped by the queue; engines may call freely.
    public let progress: @Sendable (Double) -> Void
    public let log: @Sendable (String) -> Void
    public let tools: ToolLocator
    public let namer: OutputNamer
    /// Per-job scratch dir. Write outputs here, then `namer.commit(_:to:)` into place.
    /// Deleted by the queue when the job ends.
    public let tempDir: URL
    public let destination: Destination

    public init(
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { _ in },
        tools: ToolLocator = ToolLocator(),
        namer: OutputNamer = OutputNamer(),
        tempDir: URL,
        destination: Destination = .besideOriginal
    ) {
        self.progress = progress
        self.log = log
        self.tools = tools
        self.namer = namer
        self.tempDir = tempDir
        self.destination = destination
    }

    /// Unique scratch file inside `tempDir`.
    public func tempFile(named name: String) -> URL {
        let dir = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Final location for an output derived from `input`, honoring the job destination.
    public func outputURL(for input: URL, ext: String, suffix: String? = nil) -> URL {
        namer.url(for: input, ext: ext, suffix: suffix, destination: destination)
    }
}

public protocol Engine: Sendable {
    var id: String { get }
    /// Conversions this Mac can perform right now (gate on tools / codec support).
    func conversions() -> [ConversionDescriptor]
    /// Tools this Mac can perform right now.
    func tools() -> [ToolDescriptor]
    /// Runs one job. Must honor Task cancellation, never modify inputs, and return final output URLs.
    func run(_ job: JobSpec, context: JobContext) async throws -> [URL]
}

public enum EngineError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case missingTool(String)
    case invalidInput(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let s): "Not supported: \(s)"
        case .missingTool(let s): "Required tool not found: \(s)"
        case .invalidInput(let s): "Invalid input: \(s)"
        case .failed(let s): s
        }
    }
}
