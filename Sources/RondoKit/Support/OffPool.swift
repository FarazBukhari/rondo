import Foundation

/// Runs blocking framework calls on a dedicated GCD queue while the caller *suspends*.
///
/// Some system frameworks block internally on work they schedule onto the Swift-concurrency
/// cooperative pool (Vision's text recognizer does). Calling them synchronously from a pool
/// thread can then starve the pool and deadlock — reliably on low-core machines such as CI
/// runners. Route such calls through `OffPool.run` from async code instead of calling them
/// inline. Cancellation is checked before the work starts; the work itself isn't interrupted.
public enum OffPool {
    private static let queue = DispatchQueue(
        label: "com.farazbukhari.rondo.offpool",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public static func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let box: Box<T> = try await withCheckedThrowingContinuation { cont in
            queue.async {
                cont.resume(with: Result { Box(value: try body()) })
            }
        }
        return box.value
    }

    /// Lets non-Sendable results (CGImage arrays, CF types) cross the queue hop; the producing
    /// closure has finished before the value is read, so there is no concurrent access.
    private struct Box<T>: @unchecked Sendable {
        let value: T
    }
}
