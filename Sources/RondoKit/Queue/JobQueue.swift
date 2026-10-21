import Foundation
import os

public enum JobEvent: Sendable {
    case queued(UUID, JobSpec)
    case started(UUID)
    case progress(UUID, Double)
    case finished(UUID, [URL])
    case failed(UUID, String)
    case cancelled(UUID)

    public var jobID: UUID {
        switch self {
        case .queued(let id, _), .started(let id), .progress(let id, _),
             .finished(let id, _), .failed(let id, _), .cancelled(let id):
            id
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled: true
        default: false
        }
    }
}

/// Runs jobs with bounded concurrency. Heavy jobs (video) are capped separately.
/// Per-file operations are split into one job per input; inputs already in the target format are skipped.
public actor JobQueue {
    private var registry: EngineRegistry
    private let heavyLimit: Int
    private let totalLimit: Int
    private var tools: ToolLocator
    private let hub = EventHub()

    private var pending: [(id: UUID, spec: JobSpec, heavy: Bool)] = []
    private var running: [UUID: (task: Task<Void, Never>, heavy: Bool)] = [:]

    public init(
        registry: EngineRegistry,
        heavyLimit: Int = 2,
        totalLimit: Int = max(2, ProcessInfo.processInfo.activeProcessorCount),
        tools: ToolLocator = ToolLocator()
    ) {
        self.registry = registry
        self.heavyLimit = max(1, heavyLimit)
        self.totalLimit = max(1, totalLimit)
        self.tools = tools
    }

    /// Independent event stream per subscriber (HUD, menu, CLI…). Subscribe before submitting.
    public nonisolated func subscribe() -> AsyncStream<JobEvent> {
        hub.subscribe()
    }

    public var activeCount: Int { pending.count + running.count }

    /// Swaps the engines/tool paths used for jobs started from now on (e.g. after the user
    /// edits tool paths). Running jobs keep the engine they started with; subscribers are unaffected.
    public func update(registry: EngineRegistry, tools: ToolLocator) {
        self.registry = registry
        self.tools = tools
    }

    /// Queues `spec`, returning the job IDs it was split into (may be empty if nothing to do).
    @discardableResult
    public func submit(_ spec: JobSpec) -> [UUID] {
        let jobs = split(spec)
        var ids: [UUID] = []
        for job in jobs {
            let id = UUID()
            ids.append(id)
            let heavy = job.inputs.contains { FormatCatalog.kind(for: $0).isHeavy }
            pending.append((id, job, heavy))
            hub.emit(.queued(id, job))
        }
        pump()
        return ids
    }

    public func cancel(_ id: UUID) {
        if let i = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: i)
            hub.emit(.cancelled(id))
        } else {
            running[id]?.task.cancel()
        }
    }

    public func cancelAll() {
        for job in pending { hub.emit(.cancelled(job.id)) }
        pending.removeAll()
        running.values.forEach { $0.task.cancel() }
    }

    // MARK: - Scheduling

    private func split(_ spec: JobSpec) -> [JobSpec] {
        func single(_ url: URL) -> JobSpec {
            var s = spec
            s.inputs = [url]
            return s
        }
        switch spec.operation {
        case .convert(let to):
            return spec.inputs
                .filter { FormatCatalog.format(for: $0)?.id != to }
                .map(single)
        case .tool(let id):
            if case .each? = registry.tool(id)?.multiInput {
                return spec.inputs.map(single)
            }
            return spec.inputs.isEmpty ? [] : [spec]
        }
    }

    private func pump() {
        var i = 0
        while i < pending.count, running.count < totalLimit {
            let job = pending[i]
            let heavyRunning = running.values.filter(\.heavy).count
            if job.heavy && heavyRunning >= heavyLimit {
                i += 1
                continue
            }
            pending.remove(at: i)
            start(job.id, job.spec, heavy: job.heavy)
        }
    }

    private func start(_ id: UUID, _ spec: JobSpec, heavy: Bool) {
        hub.emit(.started(id))
        let registry = self.registry
        let tools = self.tools
        let hub = self.hub
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.execute(id: id, spec: spec, registry: registry, tools: tools, hub: hub)
            await self?.jobEnded(id)
        }
        running[id] = (task, heavy)
    }

    private func jobEnded(_ id: UUID) {
        running[id] = nil
        pump()
    }

    private static let logger = Logger(subsystem: "com.farazbukhari.rondo", category: "job")

    private static func execute(id: UUID, spec: JobSpec, registry: EngineRegistry, tools: ToolLocator, hub: EventHub) async {
        let throttle = ProgressThrottle(id: id, hub: hub)
        var tempDir: URL?
        defer { if let tempDir { TempDir.remove(tempDir) } }
        do {
            guard let engine = registry.engine(for: spec) else {
                throw EngineError.unsupported(describe(spec))
            }
            let dir = try TempDir.make()
            tempDir = dir
            let context = JobContext(
                progress: { throttle.report($0) },
                log: { message in logger.notice("[\(id.uuidString.prefix(8), privacy: .public)] \(message, privacy: .public)") },
                tools: tools,
                namer: OutputNamer(),
                tempDir: dir,
                destination: spec.destination
            )
            let outputs = try await engine.run(spec, context: context)
            throttle.close()
            hub.emit(.progress(id, 1))
            hub.emit(.finished(id, outputs))
        } catch {
            throttle.close()
            if error is CancellationError || Task.isCancelled {
                hub.emit(.cancelled(id))
            } else {
                logger.error("job \(id.uuidString.prefix(8), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                hub.emit(.failed(id, error.localizedDescription))
            }
        }
    }

    static func describe(_ spec: JobSpec) -> String {
        let from = spec.inputs.first.flatMap { FormatCatalog.format(for: $0)?.displayName } ?? "file"
        switch spec.operation {
        case .convert(let to): return "\(from) → \(FormatCatalog.format(id: to)?.displayName ?? to)"
        case .tool(let id): return "\(id.rawValue) on \(from)"
        }
    }
}

/// Thread-safe fan-out of events to every subscriber, in emission order.
final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<JobEvent>.Continuation] = [:]

    func subscribe() -> AsyncStream<JobEvent> {
        let key = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { cont in
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.subscribers.removeValue(forKey: key) }
            }
            lock.withLock { subscribers[key] = cont }
        }
    }

    func emit(_ event: JobEvent) {
        let subs = lock.withLock { Array(subscribers.values) }
        subs.forEach { $0.yield(event) }
    }
}

/// Clamps, keeps monotonic, and rate-limits progress; drops reports after the job ends.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let id: UUID
    private let hub: EventHub
    private var last: Double = 0
    private var lastTime: TimeInterval = 0
    private var closed = false

    init(id: UUID, hub: EventHub) {
        self.id = id
        self.hub = hub
    }

    func report(_ value: Double) {
        let v = min(max(value.isFinite ? value : 0, 0), 1)
        let now = ProcessInfo.processInfo.systemUptime
        let shouldEmit: Bool = lock.withLock {
            guard !closed, v > last else { return false }
            guard v - last >= 0.01 || now - lastTime >= 0.1 else { return false }
            last = v
            lastTime = now
            return true
        }
        if shouldEmit { hub.emit(.progress(id, v)) }
    }

    func close() {
        lock.withLock { closed = true }
    }
}
