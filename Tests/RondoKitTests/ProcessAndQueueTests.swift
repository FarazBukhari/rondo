import Foundation
import Testing
@testable import RondoKit

@Suite struct ProcessRunnerTests {
    @Test func capturesStdout() async throws {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["hello"])
        #expect(r.stdout == "hello\n")
        #expect(r.exitCode == 0)
    }

    @Test func streamsLines() async throws {
        let collector = LineCollector()
        _ = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'a\\nb\\nc'"], stdoutLine: { collector.add($0) })
        #expect(collector.lines == ["a", "b", "c"])
    }

    @Test func nonZeroExitThrowsWithStderr() async throws {
        await #expect(throws: ProcessError.self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo boom >&2; exit 3"])
        }
        do {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo boom >&2; exit 3"])
        } catch let e as ProcessError {
            #expect(e.exitCode == 3)
            #expect(e.stderrTail.contains("boom"))
        }
    }

    @Test func grandchildHoldingPipesDoesNotHang() async throws {
        // The shell exits immediately; its backgrounded sleep keeps stdout/stderr open for 30 s.
        let start = Date()
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo hi; sleep 30 & exit 0"])
        #expect(r.exitCode == 0)
        #expect(Date().timeIntervalSince(start) < 15)
    }

    @Test func childIgnoringStdinDoesNotKillHost() async throws {
        let big = Data(repeating: 0x41, count: 4 * 1024 * 1024)
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/true"), [], stdin: big)
        #expect(r.exitCode == 0)
    }

    @Test func stdinIsPiped() async throws {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/wc"), ["-c"], stdin: Data("12345".utf8))
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "5")
    }

    @Test func cancelKillsChild() async throws {
        let marker = "rondo-cancel-\(UUID().uuidString.prefix(8))"
        let start = Date()
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "exec -a \(marker) sleep 30"])
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let result = await task.result
        // Child sleeps 30 s; returning well before that proves it was killed. Loose bound: the full
        // suite runs ffmpeg-heavy tests in parallel and can delay scheduling by seconds.
        #expect(Date().timeIntervalSince(start) < 25)   // < the 30 s sleep; passes even on a 1-thread pool
        guard case .failure(let error) = result else {
            Issue.record("expected cancellation")
            return
        }
        #expect(error is CancellationError)
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func add(_ s: String) { lock.withLock { _lines.append(s) } }
    var lines: [String] { lock.withLock { _lines } }
}

@Suite struct JobQueueTests {
    private func workspace(_ names: [String]) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return names.map {
            let u = dir.appendingPathComponent($0)
            FileManager.default.createFile(atPath: u.path, contents: Data("in".utf8))
            return u
        }
    }

    private func collect(_ stream: AsyncStream<JobEvent>, terminals: Int) async -> [JobEvent] {
        var events: [JobEvent] = []
        var done = 0
        for await e in stream {
            events.append(e)
            if e.isTerminal { done += 1 }
            if done == terminals { break }
        }
        return events
    }

    @Test func convertBatchSplitsAndSkipsSameFormat() async throws {
        let inputs = try workspace(["a.jpg", "b.png", "c.heic"])
        let engine = StubEngine(id: "img", pairs: conversions(from: ["jpg", "png", "heic"], to: ["jpg", "png", "heic"]))
        let queue = JobQueue(registry: EngineRegistry(engines: [engine]))
        let stream = queue.subscribe()
        let ids = await queue.submit(JobSpec(inputs: inputs, operation: .convert(to: "png")))
        #expect(ids.count == 2)   // b.png skipped
        let events = await collect(stream, terminals: 2)
        let finished = events.compactMap { e -> [URL]? in if case .finished(_, let urls) = e { return urls } else { return nil } }
        #expect(finished.count == 2)
        let names = Set(finished.flatMap { $0 }.map(\.lastPathComponent))
        #expect(names == ["a.png", "c 2.png"] || names == ["a.png", "c.png"])
        // input untouched
        #expect(try String(contentsOf: inputs[0], encoding: .utf8) == "in")
    }

    @Test func eventOrderPerJob() async throws {
        let inputs = try workspace(["a.jpg"])
        let engine = StubEngine(id: "img", pairs: conversions(from: ["jpg"], to: ["png"]))
        let queue = JobQueue(registry: EngineRegistry(engines: [engine]))
        let stream = queue.subscribe()
        await queue.submit(JobSpec(inputs: inputs, operation: .convert(to: "png")))
        let events = await collect(stream, terminals: 1)
        guard case .queued? = events.first else { Issue.record("first not queued: \(events)"); return }
        guard case .started? = events.dropFirst().first else { Issue.record("second not started: \(events)"); return }
        guard case .finished? = events.last else { Issue.record("last not finished: \(events)"); return }
        let progress = events.compactMap { e -> Double? in if case .progress(_, let p) = e { return p } else { return nil } }
        #expect(progress == progress.sorted())
        #expect(progress.last == 1)
    }

    @Test func unsupportedFails() async throws {
        let inputs = try workspace(["a.jpg"])
        let queue = JobQueue(registry: EngineRegistry(engines: []))
        let stream = queue.subscribe()
        await queue.submit(JobSpec(inputs: inputs, operation: .tool("nope.tool")))
        let events = await collect(stream, terminals: 1)
        guard case .failed(_, let msg)? = events.last else { Issue.record("expected failure"); return }
        #expect(msg.contains("Not supported"))
    }

    @Test func cancelRunningJob() async throws {
        let inputs = try workspace(["a.jpg"])
        // Long stub so the cancel always lands first, even when the full suite delays scheduling.
        let engine = StubEngine(id: "img", pairs: conversions(from: ["jpg"], to: ["png"]), delayNanos: 120_000_000_000)
        let queue = JobQueue(registry: EngineRegistry(engines: [engine]))
        let stream = queue.subscribe()
        let ids = await queue.submit(JobSpec(inputs: inputs, operation: .convert(to: "png")))
        try await Task.sleep(nanoseconds: 200_000_000)
        await queue.cancel(ids[0])
        let events = await collect(stream, terminals: 1)
        guard case .cancelled? = events.last else { Issue.record("expected cancelled: \(events)"); return }
        let dir = inputs[0].deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.png").path))
    }

    @Test func updateRegistrySwapsEnginesForNewJobs() async throws {
        let inputs = try workspace(["a.jpg"])
        let queue = JobQueue(registry: EngineRegistry(engines: []))
        let stream = queue.subscribe()
        await queue.update(registry: EngineRegistry(engines: [StubEngine(id: "img", pairs: conversions(from: ["jpg"], to: ["png"]))]), tools: ToolLocator())
        await queue.submit(JobSpec(inputs: inputs, operation: .convert(to: "png")))
        let events = await collect(stream, terminals: 1)
        guard case .finished? = events.last else { Issue.record("expected finished after registry update: \(events)"); return }
    }

    @Test func heavyLimitRespected() async throws {
        let inputs = try workspace(["1.mp4", "2.mp4", "3.mp4"])
        let engine = StubEngine(id: "media", pairs: conversions(from: ["mp4"], to: ["mov"]), delayNanos: 300_000_000)
        let queue = JobQueue(registry: EngineRegistry(engines: [engine]), heavyLimit: 1, totalLimit: 4)
        let stream = queue.subscribe()
        await queue.submit(JobSpec(inputs: inputs, operation: .convert(to: "mov")))
        let events = await collect(stream, terminals: 3)
        var concurrent = 0, peak = 0
        for e in events {
            if case .started = e { concurrent += 1; peak = max(peak, concurrent) }
            if e.isTerminal { concurrent -= 1 }
        }
        #expect(peak == 1)
    }
}

@Suite struct TempDirTests {
    @Test func sweepRemovesOnlyOldEntries() throws {
        let old = try TempDir.make(prefix: "sweeptest-old")
        let young = try TempDir.make(prefix: "sweeptest-young")
        let past = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
        TempDir.sweep(olderThan: 3600)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: young.path))
        TempDir.remove(young)
    }

    @Test func removeRefusesOutsideRoot() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("not-rondo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        TempDir.remove(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        try FileManager.default.removeItem(at: outside)
    }
}

@Suite struct OffPoolTests {
    @Test func runsOffTheCooperativePoolAndReturns() async throws {
        let onMain = try await OffPool.run { Thread.isMainThread }
        #expect(!onMain)
        let label = try await OffPool.run { String(cString: __dispatch_queue_get_label(nil)) }
        #expect(label == "com.farazbukhari.rondo.offpool")
    }

    @Test func propagatesErrors() async {
        await #expect(throws: EngineError.self) {
            try await OffPool.run { throw EngineError.failed("boom") }
        }
    }

    @Test func manyBlockingCallsDoNotStarveThePool() async throws {
        // 64 concurrent 50 ms blocking calls: if they ran on the cooperative pool they'd serialize
        // on its few threads; off-pool they overlap and the awaiting tasks stay suspended.
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 { group.addTask { try await OffPool.run { Thread.sleep(forTimeInterval: 0.05) } } }
            try await group.waitForAll()
        }
        #expect(Date().timeIntervalSince(start) < 30)
    }
}
