import Foundation

/// SRT / WebVTT parsing and writing. Tolerant: BOM, CRLF/CR, missing or junk indices, missing blank
/// lines between cues, VTT headers/NOTE/STYLE/REGION blocks, cue settings, hour-less timestamps.
enum Subtitles {
    struct Cue: Equatable {
        var start: Double   // seconds
        var end: Double
        var lines: [String]
    }

    // MARK: Parse

    static func parse(_ raw: String) -> [Cue] {
        var text = DocSupport.normalizeNewlines(raw)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.components(separatedBy: "\n")

        var cues: [Cue] = []
        var current: Cue?
        var skippingBlock = false      // inside a VTT NOTE/STYLE/REGION block or the header block
        var i = 0
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("WEBVTT") { skippingBlock = true }

        func finish() {
            if var c = current {
                while let last = c.lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { c.lines.removeLast() }
                if !c.lines.isEmpty || c.end > c.start { cues.append(c) }
            }
            current = nil
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let (start, end) = timing(trimmed) {
                // A bare index line directly before this timing belongs to the new cue, not the previous text.
                if var c = current, let last = c.lines.last, isIndex(last) {
                    c.lines.removeLast()
                    current = c
                }
                finish()
                skippingBlock = false
                current = Cue(start: start, end: max(end, start), lines: [])
                i += 1
                continue
            }
            if trimmed.isEmpty {
                finish()
                skippingBlock = false
                i += 1
                continue
            }
            if skippingBlock { i += 1; continue }
            if current == nil {
                // Outside a cue: VTT block keywords start a skipped block; anything else is an index/identifier.
                if trimmed.hasPrefix("NOTE") || trimmed == "STYLE" || trimmed == "REGION" { skippingBlock = true }
                i += 1
                continue
            }
            current!.lines.append(line.trimmingCharacters(in: .init(charactersIn: " \t")))
            i += 1
        }
        finish()
        return cues
    }

    private static func isIndex(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy(\.isNumber)
    }

    /// "00:01:02,345 --> 00:01:04,000 [settings]" (SRT/VTT, ',' or '.', hours optional).
    static func timing(_ line: String) -> (Double, Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let rightAll = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let right = rightAll.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        guard let a = timestamp(left), let b = timestamp(right) else { return nil }
        return (a, b)
    }

    static func timestamp(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var seconds = 0.0
        for (idx, p) in parts.enumerated() {
            let isLast = idx == parts.count - 1
            if isLast {
                guard let v = Double(p), v >= 0 else { return nil }
                seconds = seconds * 60 + v
            } else {
                guard !p.isEmpty, p.allSatisfy(\.isNumber), let v = Int(p) else { return nil }
                seconds = seconds * 60 + Double(v)
            }
        }
        return seconds
    }

    // MARK: Write

    static func srt(_ cues: [Cue]) -> String {
        var out = ""
        for (i, c) in cues.enumerated() {
            out += "\(i + 1)\n\(stamp(c.start, sep: ",")) --> \(stamp(c.end, sep: ","))\n"
            out += c.lines.map(toSRTText).joined(separator: "\n")
            out += "\n\n"
        }
        return out
    }

    static func vtt(_ cues: [Cue]) -> String {
        var out = "WEBVTT\n\n"
        for c in cues {
            out += "\(stamp(c.start, sep: ".")) --> \(stamp(c.end, sep: "."))\n"
            out += c.lines.map(toVTTText).joined(separator: "\n")
            out += "\n\n"
        }
        return out
    }

    /// One line per cue, timing and markup removed; consecutive duplicates (rolling captions) collapsed.
    static func plainText(_ cues: [Cue]) -> String {
        var lines: [String] = []
        for c in cues {
            let joined = c.lines.map { unescape(stripTags($0)) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !joined.isEmpty, joined != lines.last else { continue }
            lines.append(joined)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func stamp(_ t: Double, sep: String) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, f = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, sep, f)
    }

    // MARK: Markup

    /// Markup tags start with a letter, digit (VTT timestamps) or "/" — a lone "<" in dialogue isn't a tag.
    private static let tagRegex = try! NSRegularExpression(pattern: #"</?[A-Za-z0-9][^<>]*>"#)

    static func stripTags(_ s: String) -> String {
        tagRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lrm;", with: "")
            .replacingOccurrences(of: "&rlm;", with: "").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Keeps tags both formats understand (b, i, u); drops the rest.
    private static func filterTags(_ s: String) -> String {
        tagRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed().reduce(s) { acc, m in
            guard let r = Range(m.range, in: acc) else { return acc }
            let tag = acc[r].lowercased()
            let keep = ["<b>", "</b>", "<i>", "</i>", "<u>", "</u>"].contains(tag)
            return keep ? acc : acc.replacingCharacters(in: r, with: "")
        }
    }

    /// VTT cue text → SRT: voice/class/timestamp tags dropped, entities decoded.
    static func toSRTText(_ s: String) -> String {
        unescape(filterTags(s))
    }

    /// SRT text → VTT: unsupported tags (e.g. <font>) dropped, bare & and < escaped, "-->" defused.
    static func toVTTText(_ s: String) -> String {
        let kept = filterTags(unescape(s))
        var out = ""
        var i = kept.startIndex
        while i < kept.endIndex {
            let c = kept[i]
            if c == "<", let close = kept[i...].firstIndex(of: ">") {
                let tag = kept[i...close].lowercased()
                if ["<b>", "</b>", "<i>", "</i>", "<u>", "</u>"].contains(tag) {
                    out += kept[i...close]
                    i = kept.index(after: close)
                    continue
                }
            }
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(c)
            }
            i = kept.index(after: i)
        }
        return out.replacingOccurrences(of: "--&gt;", with: "-&gt;")
    }
}
