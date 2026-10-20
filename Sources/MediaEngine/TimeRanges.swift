import Foundation
import RondoKit

enum TimeRanges {
    /// Clamps to `0...duration`, drops ranges shorter than 50 ms; keeps order and overlaps.
    static func clamp(_ ranges: [ClosedRange<Double>], duration: Double?) -> [ClosedRange<Double>] {
        ranges.compactMap { r in
            let lo = max(0, r.lowerBound)
            let hi = duration.map { min($0, r.upperBound) } ?? r.upperBound
            return hi - lo >= 0.05 ? lo...hi : nil
        }
    }

    /// `clamp`, then sorted and merged.
    static func normalize(_ ranges: [ClosedRange<Double>], duration: Double?) -> [ClosedRange<Double>] {
        let sorted = clamp(ranges, duration: duration).sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for r in sorted {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    static func totalLength(_ ranges: [ClosedRange<Double>]) -> Double {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// `between(t,a,b)+between(t,c,d)` for `enable=` expressions.
    static func betweenExpr(_ ranges: [ClosedRange<Double>]) -> String {
        ranges.map { "between(t,\(fmt($0.lowerBound)),\(fmt($0.upperBound)))" }.joined(separator: "+")
    }

    /// N equal consecutive parts of `duration`.
    static func equalParts(_ n: Int, duration: Double) -> [ClosedRange<Double>] {
        let n = max(1, n)
        let step = duration / Double(n)
        return (0..<n).map { i in
            let lo = Double(i) * step
            let hi = i == n - 1 ? duration : Double(i + 1) * step
            return lo...hi
        }
    }

    /// atempo accepts 0.5…2.0 per instance on older ffmpeg; chain for anything outside.
    static func atempoChain(_ speed: Double) -> [String] {
        var r = speed
        var parts: [String] = []
        while r > 2.0 { parts.append("atempo=2.0"); r /= 2 }
        while r < 0.5 { parts.append("atempo=0.5"); r /= 0.5 }
        if abs(r - 1) > 1e-6 || parts.isEmpty { parts.append("atempo=\(fmtRatio(r))") }
        return parts
    }
}
