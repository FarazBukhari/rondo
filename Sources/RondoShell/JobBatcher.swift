import Foundation
import RondoKit

/// Groups jobs that came from one drop so their outputs are revealed together, once.
///
/// `JobQueue.submit` emits every `.queued` event of one spec synchronously before any of those jobs
/// can finish, so consecutive `.queued` events with the same operation + destination arriving within
/// `window` seconds form one batch. A batch completes when all its jobs reach a terminal event.
public struct JobBatcher {
    struct Key: Hashable {
        let operation: RondoKit.Operation
        let destination: Destination
    }

    struct Batch {
        let key: Key
        var pending: Set<UUID>
        var outputs: [URL]
        var lastQueued: TimeInterval
    }

    public let window: TimeInterval
    private var batches: [Int: Batch] = [:]
    private var batchOf: [UUID: Int] = [:]
    private var openBatch: Int?
    private var nextID = 0

    public init(window: TimeInterval = 0.5) {
        self.window = window
    }

    public var isIdle: Bool { batches.isEmpty }

    public mutating func queued(_ id: UUID, spec: JobSpec, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard batchOf[id] == nil else { return }
        let key = Key(operation: spec.operation, destination: spec.destination)
        if let open = openBatch, var b = batches[open], b.key == key, time - b.lastQueued <= window {
            b.pending.insert(id)
            b.lastQueued = time
            batches[open] = b
            batchOf[id] = open
            return
        }
        let bid = nextID
        nextID += 1
        batches[bid] = Batch(key: key, pending: [id], outputs: [], lastQueued: time)
        batchOf[id] = bid
        openBatch = bid
    }

    /// Records a terminal event. Returns the batch's collected outputs (possibly empty) when this was
    /// its last pending job, otherwise nil. Unknown IDs (queued before the HUD subscribed) are their
    /// own batch.
    public mutating func ended(_ id: UUID, outputs: [URL]) -> [URL]? {
        guard let bid = batchOf.removeValue(forKey: id), var b = batches[bid] else { return outputs }
        b.pending.remove(id)
        b.outputs += outputs
        guard b.pending.isEmpty else {
            batches[bid] = b
            return nil
        }
        batches[bid] = nil
        if openBatch == bid { openBatch = nil }
        return b.outputs
    }
}
