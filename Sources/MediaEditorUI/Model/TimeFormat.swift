import Foundation

/// Locale-independent `m:ss.ff` / `h:mm:ss.ff` formatting and parsing.
public enum TimeFormat {
    /// `0:01.25`, `12:03.50`, `1:02:03.00`. `fractionDigits` 0…3.
    public static func string(_ seconds: Double, fractionDigits: Int = 2, forceHours: Bool = false) -> String {
        let digits = min(3, max(0, fractionDigits))
        let scale = pow(10, Double(digits))
        let total = (max(0, seconds.isFinite ? seconds : 0) * scale).rounded()
        let whole = Int(total / scale)
        let frac = Int(total) - whole * Int(scale)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        var out = h > 0 || forceHours ? "\(h):\(pad(m)):\(pad(s))" : "\(m):\(pad(s))"
        if digits > 0 {
            let f = String(frac)
            out += "." + String(repeating: "0", count: digits - f.count) + f
        }
        return out
    }

    /// Short human length: `1.5 s`, `12 s`, `2:05`.
    public static func length(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), seconds) }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        return string(seconds, fractionDigits: 0)
    }

    /// Parses `62.5`, `1:02.5`, `1:02:03`, `0:01.04`. Nil for garbage or negatives.
    public static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0, v.isFinite else { return nil }
            if i > 0, v >= 60 { return nil }
            total = total * 60 + v
        }
        return total
    }

    private static func pad(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
}
