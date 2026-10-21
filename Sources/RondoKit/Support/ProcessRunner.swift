import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    /// Full stdout when no `stdoutLine` handler was given; empty otherwise.
    public let stdout: String
    /// Last ~16 KB of stderr.
    public let stderrTail: String
}

public struct ProcessError: Error, LocalizedError, Sendable {
    public let command: String
    public let exitCode: Int32
    public let stderrTail: String

    public var errorDescription: String? {
        let tail = stderrTail.split(separator: "\n").suffix(6).joined(separator: "\n")
        return "\(command) failed (exit \(exitCode))\(tail.isEmpty ? "" : ":\n\(tail)")"
    }
}

/// Async, cancellable subprocess runner. On Task cancellation the child gets SIGTERM,
/// then SIGKILL after 2 s, and the call throws `CancellationError`.
public enum ProcessRunner {
    private static let stderrLimit = 16 * 1024

    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        stdoutLine: (@Sendable (String) -> Void)? = nil,
        checkExit: Bool = true
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = stdin.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let state = RunState(lineHandler: stdoutLine)
        let group = DispatchGroup()
        group.enter(); group.enter(); group.enter()   // stdout EOF, stderr EOF, termination

        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; state.finishStdout(); group.leave() } else { state.appendStdout(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; group.leave() } else { state.appendStderr(d, limit: stderrLimit) }
        }
        process.terminationHandler = { _ in
            group.leave()
            // A grandchild that inherited our pipes can keep EOF from ever arriving. Once the
            // direct child has exited, give readers a short drain window, then finish anyway.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { state.drainTimeoutHandler?() }
        }

        let command = ([executable.lastPathComponent] + arguments.prefix(3)).joined(separator: " ")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                    return
                }
                state.setProcess(process)
                if let inPipe, let stdin {
                    // Child may exit without reading: get EPIPE instead of a process-killing SIGPIPE.
                    _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    DispatchQueue.global().async {
                        try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                let finish: @Sendable () -> Void = {
                    guard state.claimFinish() else { return }   // resume exactly once
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let code = process.terminationStatus
                    if state.wasCancelled {
                        cont.resume(throwing: CancellationError())
                    } else if checkExit && code != 0 {
                        cont.resume(throwing: ProcessError(command: command, exitCode: code, stderrTail: state.stderrString))
                    } else {
                        cont.resume(returning: ProcessResult(exitCode: code, stdout: state.stdoutString, stderrTail: state.stderrString))
                    }
                }
                state.drainTimeoutHandler = finish
                group.notify(queue: .global(), execute: finish)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

/// Thread-safe accumulator shared by pipe handlers, termination and cancellation.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var lineBuffer = Data()
    private var stderr = Data()
    private var process: Process?
    private var cancelled = false
    private var finished = false
    /// Set once the continuation is armed; called if pipes don't reach EOF after the child exits.
    var drainTimeoutHandler: (@Sendable () -> Void)? {
        get { lock.withLock { _drainTimeoutHandler } }
        set { lock.withLock { _drainTimeoutHandler = newValue } }
    }
    private var _drainTimeoutHandler: (@Sendable () -> Void)?

    /// True for the first caller only.
    func claimFinish() -> Bool {
        lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
    }
    private let lineHandler: (@Sendable (String) -> Void)?

    init(lineHandler: (@Sendable (String) -> Void)?) {
        self.lineHandler = lineHandler
    }

    func appendStdout(_ d: Data) {
        guard let lineHandler else {
            lock.withLock { stdout.append(d) }
            return
        }
        var lines: [String] = []
        lock.withLock {
            lineBuffer.append(d)
            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                let line = lineBuffer[lineBuffer.startIndex..<nl]
                lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .init(charactersIn: "\r")))
                lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            }
        }
        lines.forEach(lineHandler)
    }

    func finishStdout() {
        guard let lineHandler else { return }
        let rest: Data = lock.withLock { defer { lineBuffer.removeAll() }; return lineBuffer }
        if !rest.isEmpty { lineHandler(String(decoding: rest, as: UTF8.self)) }
    }

    func appendStderr(_ d: Data, limit: Int) {
        lock.withLock {
            stderr.append(d)
            if stderr.count > limit { stderr.removeFirst(stderr.count - limit) }
        }
    }

    var stdoutString: String { lock.withLock { String(decoding: stdout, as: UTF8.self) } }
    var stderrString: String { lock.withLock { String(decoding: stderr, as: UTF8.self) } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func setProcess(_ p: Process) {
        let cancelNow: Bool = lock.withLock { process = p; return cancelled }
        if cancelNow { terminate(p) }
    }

    func cancel() {
        let p: Process? = lock.withLock { cancelled = true; return process }
        if let p { terminate(p) }
    }

    private func terminate(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }
}
