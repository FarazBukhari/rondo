import Foundation

/// Editable set of time spans (seconds) inside `0...duration`: sorted, disjoint, each at least
/// `minLength` long. Used for Trim (spans to keep) and Bleep (spans to mute).
///
/// Bound edits clamp against the neighbours (touching is allowed while dragging); call
/// `normalize()` when a drag ends to merge spans that now touch.
public struct TimeRangeList: Equatable, Sendable {
    public private(set) var ranges: [ClosedRange<Double>]
    public let duration: Double
    public let minLength: Double

    /// Gaps at or below this are treated as touching and merged.
    static let tolerance = 1e-3

    public init(duration: Double, minLength: Double = 0.1, ranges: [ClosedRange<Double>] = []) {
        self.duration = max(0, duration)
        self.minLength = max(0, min(minLength, max(0, duration)))
        self.ranges = Self.normalized(ranges, duration: self.duration, minLength: self.minLength)
    }

    /// One span covering the whole clip.
    public static func whole(duration: Double, minLength: Double = 0.1) -> TimeRangeList {
        TimeRangeList(duration: duration, minLength: minLength, ranges: [0...max(0, duration)])
    }

    /// Clamp to `0...duration`, sort, merge overlapping/touching spans, drop spans shorter than `minLength`.
    public static func normalized(_ input: [ClosedRange<Double>], duration: Double, minLength: Double) -> [ClosedRange<Double>] {
        let clamped: [ClosedRange<Double>] = input.compactMap { r in
            guard r.lowerBound.isFinite, r.upperBound.isFinite else { return nil }
            let lo = min(max(0, r.lowerBound), duration)
            let hi = min(max(0, r.upperBound), duration)
            return hi > lo ? lo...hi : nil
        }
        var merged: [ClosedRange<Double>] = []
        for r in clamped.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound + tolerance {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged.filter { $0.upperBound - $0.lowerBound >= minLength - 1e-9 }
    }

    // MARK: Queries

    public var isEmpty: Bool { ranges.isEmpty }
    public var count: Int { ranges.count }
    public var totalLength: Double { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    /// True when the list is exactly one span covering the whole clip.
    public var coversWholeClip: Bool {
        ranges.count == 1 && ranges[0].lowerBound <= Self.tolerance && ranges[0].upperBound >= duration - Self.tolerance
    }

    public func index(containing t: Double) -> Int? {
        ranges.firstIndex { $0.contains(t) }
    }

    /// Free spans between the ranges (the parts Trim removes).
    public var complement: [ClosedRange<Double>] {
        var gaps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for r in ranges {
            if r.lowerBound - cursor > Self.tolerance { gaps.append(cursor...r.lowerBound) }
            cursor = r.upperBound
        }
        if duration - cursor > Self.tolerance { gaps.append(cursor...duration) }
        return gaps
    }

    /// The free span containing `t`, if `t` is not inside a range.
    public func gap(containing t: Double) -> ClosedRange<Double>? {
        guard t >= 0, t <= duration, index(containing: t) == nil else { return nil }
        return complement.first { $0.contains(t) }
    }

    // MARK: Edits

    public mutating func reset(to new: [ClosedRange<Double>]) {
        ranges = Self.normalized(new, duration: duration, minLength: minLength)
    }

    /// Adds a span (stretched to `minLength` if shorter), merging with anything it overlaps.
    /// Returns the index of the span that now contains it.
    @discardableResult
    public mutating func add(_ r: ClosedRange<Double>) -> Int? {
        guard duration > 0 else { return nil }
        var lo = min(max(0, r.lowerBound), duration)
        var hi = min(max(0, r.upperBound), duration)
        if hi - lo < minLength {
            hi = min(duration, lo + minLength)
            lo = max(0, hi - minLength)
        }
        ranges = Self.normalized(ranges + [lo...hi], duration: duration, minLength: minLength)
        return index(containing: (lo + hi) / 2)
    }

    /// Adds a span of `length` starting at `t`, fitted inside the free gap around `t` (shifted back
    /// if it would run into the next span). If `t` is already inside a span, returns that span's index.
    @discardableResult
    public mutating func insert(at t: Double, length: Double) -> Int? {
        if let i = index(containing: t) { return i }
        guard let gap = gap(containing: t) else { return nil }
        // Keep a hair of space next to existing spans so `normalize()` doesn't merge the new one away.
        let lower = gap.lowerBound + (gap.lowerBound > 0 ? Self.tolerance * 2 : 0)
        let upper = gap.upperBound - (gap.upperBound < duration ? Self.tolerance * 2 : 0)
        guard upper - lower >= minLength else { return nil }
        let len = min(max(length, minLength), upper - lower)
        let lo = min(max(t, lower), upper - len)
        let r = lo...(lo + len)
        ranges.append(r)
        ranges.sort { $0.lowerBound < $1.lowerBound }
        return index(containing: (r.lowerBound + r.upperBound) / 2)
    }

    public mutating func remove(at i: Int) {
        guard ranges.indices.contains(i) else { return }
        ranges.remove(at: i)
    }

    /// Cuts `cut` out of every span; pieces shorter than `minLength` disappear.
    public mutating func subtract(_ cut: ClosedRange<Double>) {
        var out: [ClosedRange<Double>] = []
        for r in ranges {
            if cut.upperBound <= r.lowerBound || cut.lowerBound >= r.upperBound {
                out.append(r)
                continue
            }
            if cut.lowerBound > r.lowerBound { out.append(r.lowerBound...cut.lowerBound) }
            if cut.upperBound < r.upperBound { out.append(cut.upperBound...r.upperBound) }
        }
        ranges = out.filter { $0.upperBound - $0.lowerBound >= minLength - 1e-9 }
    }

    /// Moves the start of span `i`, clamped between the previous span's end and `end - minLength`.
    @discardableResult
    public mutating func setLowerBound(of i: Int, to t: Double) -> Double {
        guard ranges.indices.contains(i) else { return t }
        let floor = i > 0 ? ranges[i - 1].upperBound : 0
        let ceiling = ranges[i].upperBound - minLength
        let v = min(max(t, floor), max(floor, ceiling))
        ranges[i] = v...ranges[i].upperBound
        return v
    }

    /// Moves the end of span `i`, clamped between `start + minLength` and the next span's start.
    @discardableResult
    public mutating func setUpperBound(of i: Int, to t: Double) -> Double {
        guard ranges.indices.contains(i) else { return t }
        let ceiling = i < ranges.count - 1 ? ranges[i + 1].lowerBound : duration
        let floor = ranges[i].lowerBound + minLength
        let v = max(min(t, ceiling), min(floor, ceiling))
        ranges[i] = ranges[i].lowerBound...v
        return v
    }

    /// Shifts span `i` by `delta`, keeping its length, clamped between its neighbours.
    public mutating func move(_ i: Int, by delta: Double) {
        guard ranges.indices.contains(i) else { return }
        let r = ranges[i]
        let floor = i > 0 ? ranges[i - 1].upperBound : 0
        let ceiling = i < ranges.count - 1 ? ranges[i + 1].lowerBound : duration
        let len = r.upperBound - r.lowerBound
        let lo = min(max(r.lowerBound + delta, floor), ceiling - len)
        ranges[i] = lo...(lo + len)
    }

    /// Merges spans that touch after a drag.
    public mutating func normalize() {
        ranges = Self.normalized(ranges, duration: duration, minLength: minLength)
    }
}
