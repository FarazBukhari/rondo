import Foundation

/// Split points (seconds) inside a clip. N markers → N+1 consecutive parts, each at least `minGap` long.
public struct SplitMarkers: Equatable, Sendable {
    public private(set) var times: [Double]
    public let duration: Double
    public let minGap: Double

    public init(duration: Double, minGap: Double = 0.1, times: [Double] = []) {
        self.duration = max(0, duration)
        self.minGap = max(0, minGap)
        self.times = []
        for t in times.sorted() { add(t) }
    }

    public var count: Int { times.count }
    public var isEmpty: Bool { times.isEmpty }
    public var partCount: Int { times.count + 1 }

    /// Consecutive parts `[0, m1], [m1, m2], …, [mn, duration]`.
    public var parts: [ClosedRange<Double>] {
        guard duration > 0 else { return [] }
        let edges = [0] + times + [duration]
        return zip(edges, edges.dropFirst()).map { $0...$1 }
    }

    /// A marker fits at `t` if it leaves at least `minGap` to both clip ends and every other marker.
    public func canAdd(_ t: Double) -> Bool {
        guard t.isFinite, t >= minGap, t <= duration - minGap else { return false }
        return !times.contains { abs($0 - t) < minGap }
    }

    @discardableResult
    public mutating func add(_ t: Double) -> Int? {
        guard canAdd(t) else { return nil }
        let i = times.firstIndex { $0 > t } ?? times.count
        times.insert(t, at: i)
        return i
    }

    public mutating func remove(at i: Int) {
        guard times.indices.contains(i) else { return }
        times.remove(at: i)
    }

    /// Removes the marker closest to `t` if it is within `tolerance`.
    @discardableResult
    public mutating func removeNearest(to t: Double, within tolerance: Double) -> Bool {
        guard let i = nearest(to: t, within: tolerance) else { return false }
        times.remove(at: i)
        return true
    }

    public func nearest(to t: Double, within tolerance: Double) -> Int? {
        let best = times.indices.min { abs(times[$0] - t) < abs(times[$1] - t) }
        guard let best, abs(times[best] - t) <= tolerance else { return nil }
        return best
    }

    /// Moves marker `i`, clamped so every part stays at least `minGap` long. Returns the new time.
    @discardableResult
    public mutating func move(_ i: Int, to t: Double) -> Double {
        guard times.indices.contains(i) else { return t }
        let floor = (i > 0 ? times[i - 1] : 0) + minGap
        let ceiling = (i < times.count - 1 ? times[i + 1] : duration) - minGap
        guard ceiling >= floor else { return times[i] }
        let v = min(max(t, floor), ceiling)
        times[i] = v
        return v
    }

    /// Replaces the markers with `n - 1` evenly spaced ones (n clamped so parts stay ≥ `minGap`).
    public mutating func setEqualParts(_ n: Int) {
        let maxParts = minGap > 0 ? max(1, Int((duration / minGap).rounded(.down))) : max(1, n)
        let n = min(max(1, n), maxParts)
        let step = duration / Double(n)
        times = (1..<max(1, n)).map { Double($0) * step }
    }
}
