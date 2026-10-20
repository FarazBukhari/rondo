import Foundation
import os
import RondoKit

let mediaLog = Logger(subsystem: "com.farazbukhari.rondo", category: "media")

// MARK: - Progress

/// Clamps to 0...1 and only ever moves forward, so callers can report freely
/// (retries and multi-pass jobs never make the bar jump back).
final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double = -1
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func send(_ value: Double) {
        guard value.isFinite else { return }
        let v = min(1, max(0, value))
        let emit: Bool = lock.withLock {
            guard v > last else { return false }
            last = v
            return true
        }
        if emit { report(v) }
    }

    var root: ProgressSlice { ProgressSlice(sink: self, start: 0, span: 1) }
}

/// A window `start ..< start+span` of the job's overall progress.
struct ProgressSlice: Sendable {
    let sink: ProgressSink
    let start: Double
    let span: Double

    func callAsFunction(_ fraction: Double) {
        guard fraction.isFinite else { return }
        sink.send(start + span * min(1, max(0, fraction)))
    }

    /// Sub-window expressed in this slice's own 0...1 coordinates.
    func sub(_ from: Double, _ length: Double) -> ProgressSlice {
        ProgressSlice(sink: sink, start: start + span * from, span: span * length)
    }

    /// Splits this slice into consecutive windows proportional to `weights`.
    func split(_ weights: [Double]) -> [ProgressSlice] {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return weights.map { _ in self } }
        var acc = 0.0
        return weights.map { w in
            defer { acc += max(0, w) / total }
            return sub(acc, max(0, w) / total)
        }
    }
}

// MARK: - Probe results

struct MediaInfo: Sendable {
    struct Stream: Sendable {
        var index: Int
        var type: String            // "video" | "audio" | "subtitle" | "data" | …
        var codec: String           // ffprobe codec_name
        var width: Int?
        var height: Int?
        var pixFmt: String?
        var sampleRate: Int?
        var channels: Int?
        var channelLayout: String?
        var bitRate: Int?
        var duration: Double?
        var frameRate: Double?
        var bitsPerRawSample: Int?
        var sampleFmt: String?
        var rotation: Double?
        var isAttachedPic: Bool
    }

    var duration: Double?
    var bitRate: Int?
    var formatName: String
    var fileSize: Int64
    var streams: [Stream]

    /// First real video stream (cover art excluded).
    var video: Stream? { streams.first { $0.type == "video" && !$0.isAttachedPic } }
    var audio: Stream? { streams.first { $0.type == "audio" } }

    /// Whole-file bitrate (bits/s), from the container or size ÷ duration.
    var totalBitRate: Int? {
        if let bitRate, bitRate > 0 { return bitRate }
        guard let duration, duration > 0, fileSize > 0 else { return nil }
        return Int(Double(fileSize) * 8 / duration)
    }

    /// Displayed size after the rotation flag is applied (ffmpeg autorotates when decoding).
    var displaySize: (width: Int, height: Int)? {
        guard let v = video, let w = v.width, let h = v.height else { return nil }
        if let r = v.rotation, abs(abs(r).truncatingRemainder(dividingBy: 180) - 90) < 1 { return (h, w) }
        return (w, h)
    }

    var frameRate: Double {
        if let f = video?.frameRate, f > 0, f < 1000 { return f }
        return 30
    }

    /// Video bitrate if known, else total minus audio.
    var videoBitRate: Int? {
        if let b = video?.bitRate, b > 0 { return b }
        guard let total = totalBitRate else { return nil }
        let a = audio?.bitRate ?? (audio == nil ? 0 : 128_000)
        let v = total - a
        return v > 0 ? v : nil
    }

    static func parse(json: Data, fileSize: Int64) throws -> MediaInfo {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw EngineError.failed("ffprobe returned unreadable output")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let rawStreams = root["streams"] as? [[String: Any]] ?? []
        let streams: [Stream] = rawStreams.map { s in
            let disposition = s["disposition"] as? [String: Any] ?? [:]
            var rotation: Double?
            if let side = s["side_data_list"] as? [[String: Any]] {
                rotation = side.compactMap { num($0["rotation"]) }.first
            }
            if rotation == nil, let tags = s["tags"] as? [String: Any] { rotation = num(tags["rotate"]) }
            return Stream(
                index: int(s["index"]) ?? 0,
                type: s["codec_type"] as? String ?? "",
                codec: s["codec_name"] as? String ?? "",
                width: int(s["width"]),
                height: int(s["height"]),
                pixFmt: s["pix_fmt"] as? String,
                sampleRate: int(s["sample_rate"]),
                channels: int(s["channels"]),
                channelLayout: s["channel_layout"] as? String,
                bitRate: int(s["bit_rate"]),
                duration: num(s["duration"]),
                frameRate: rate(s["avg_frame_rate"]) ?? rate(s["r_frame_rate"]),
                bitsPerRawSample: int(s["bits_per_raw_sample"]),
                sampleFmt: s["sample_fmt"] as? String,
                rotation: rotation,
                isAttachedPic: (int(disposition["attached_pic"]) ?? 0) != 0
            )
        }
        var duration = num(format["duration"])
        if duration == nil || duration! <= 0 {
            duration = streams.compactMap(\.duration).max()
        }
        return MediaInfo(
            duration: duration,
            bitRate: int(format["bit_rate"]),
            formatName: format["format_name"] as? String ?? "",
            fileSize: fileSize,
            streams: streams
        )
    }

    private static func num(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d.isFinite ? d : nil
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    private static func int(_ v: Any?) -> Int? { num(v).map { Int($0) } }

    private static func rate(_ v: Any?) -> Double? {
        guard let s = v as? String else { return nil }
        let parts = s.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] != 0, parts[0] > 0 { return parts[0] / parts[1] }
        if parts.count == 1, parts[0] > 0 { return parts[0] }
        return nil
    }
}

// MARK: - ffmpeg / ffprobe

/// Thin wrapper over `ProcessRunner` for ffmpeg + ffprobe.
struct FFmpeg: Sendable {
    let ffmpeg: URL
    let ffprobe: URL
    let encoders: EncoderSet
    let log: @Sendable (String) -> Void

    static func make(tools: ToolLocator, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> FFmpeg {
        let ff = try tools.require("ffmpeg")
        let fp = try tools.require("ffprobe")
        let enc = await EncoderProbe.encoders(ffmpeg: ff)
        return FFmpeg(ffmpeg: ff, ffprobe: fp, encoders: EncoderSet(enc), log: log)
    }

    /// `ffprobe -show_format -show_streams -of json`.
    func probe(_ url: URL) async throws -> MediaInfo {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(ffprobe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path])
        } catch let e as ProcessError {
            throw EngineError.invalidInput("\(url.lastPathComponent) is not a readable media file: \(Self.tail(e.stderrTail))")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return try MediaInfo.parse(json: Data(result.stdout.utf8), fileSize: size)
    }

    /// Runs ffmpeg with `-progress pipe:1 -nostats`; progress = out_time_us / `duration`.
    /// `args` are everything after the global options (inputs, maps, codecs, output).
    func run(_ args: [String], duration: Double?, progress: ProgressSlice?, loglevel: String = "error") async throws -> ProcessResult {
        let full = ["-hide_banner", "-nostdin", "-y", "-loglevel", loglevel,
                    "-nostats", "-progress", "pipe:1", "-stats_period", "0.25"] + args
        log("ffmpeg " + full.joined(separator: " "))
        let total = duration.flatMap { $0 > 0 ? $0 : nil }
        let handler: @Sendable (String) -> Void = { line in
            guard let progress else { return }
            if line.hasPrefix("out_time_us="), let total {
                if let us = Double(line.dropFirst("out_time_us=".count)) {
                    progress(us / 1_000_000 / total)
                }
            } else if line == "progress=end" {
                progress(1)
            }
        }
        do {
            return try await ProcessRunner.run(ffmpeg, full, stdoutLine: handler)
        } catch let e as ProcessError {
            mediaLog.error("ffmpeg failed (\(e.exitCode)): \(e.stderrTail, privacy: .public)")
            throw EngineError.failed("ffmpeg failed: \(Self.tail(e.stderrTail))")
        }
    }

    /// Runs `plans` in order until one succeeds (stream-copy → re-encode → software fallback).
    func runFirstSuccessful<P>(_ plans: [P], build: (P) -> [String], duration: Double?, progress: ProgressSlice?) async throws {
        precondition(!plans.isEmpty)
        var lastError: Error?
        for (i, plan) in plans.enumerated() {
            try Task.checkCancellation()
            do {
                _ = try await run(build(plan), duration: duration, progress: progress)
                return
            } catch let e as EngineError {
                lastError = e
                if i < plans.count - 1 {
                    log("attempt \(i + 1) failed, retrying: \(e.localizedDescription)")
                    mediaLog.notice("attempt \(i + 1) failed, falling back")
                }
            }
        }
        throw lastError ?? EngineError.failed("ffmpeg failed")
    }

    static func tail(_ stderr: String, lines: Int = 4) -> String {
        let t = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return t.suffix(lines).joined(separator: " · ")
    }
}

/// Formats seconds for ffmpeg arguments (no locale, fixed precision).
func fmt(_ seconds: Double) -> String {
    String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
}

func fmtRatio(_ v: Double) -> String {
    String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), v)
}
