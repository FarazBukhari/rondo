import AppKit
import AVFoundation
import Foundation
import os
import RondoKit

let editorLog = Logger(subsystem: "com.farazbukhari.rondo", category: "media-editor")

/// Preview-only artefacts (filmstrip frames, waveform peaks, playback proxy), produced with ffmpeg
/// into `workDir` (a `TempDir`, never beside the user's file). Every call is cancellable: the
/// ffmpeg child is killed when the calling task is cancelled.
public struct PreviewGenerator: Sendable {
    public let source: URL
    public let workDir: URL
    public let ffmpeg: URL?

    public init(source: URL, workDir: URL, tools: ToolLocator) {
        self.source = source
        self.workDir = workDir
        self.ffmpeg = tools.url(for: "ffmpeg")
    }

    private func requireFFmpeg() throws -> URL {
        guard let ffmpeg else { throw EngineError.missingTool("ffmpeg") }
        return ffmpeg
    }

    // MARK: Frames

    /// Centres of `count` equal slices of the clip.
    public static func thumbnailTimes(count: Int, duration: Double) -> [Double] {
        guard count > 0, duration > 0 else { return [] }
        let step = duration / Double(count)
        return (0..<count).map { (Double($0) + 0.5) * step }
    }

    /// One frame at `time`, scaled to `height` px (displayed orientation — ffmpeg autorotates).
    /// Returns nil when ffmpeg produced no frame (e.g. a seek past the last frame).
    public func frame(at time: Double, height: Int, name: String) async throws -> URL? {
        let ff = try requireFFmpeg()
        let out = workDir.appendingPathComponent(name)
        let h = max(2, height / 2 * 2)
        let args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error",
                    "-ss", Self.fmt(max(0, time)), "-i", source.path,
                    "-map", "0:V:0", "-frames:v", "1", "-an",
                    "-vf", "scale=-2:'min(\(h),ih)':flags=bilinear", "-update", "1", out.path]
        do {
            try await ProcessRunner.run(ff, args)
        } catch let e as ProcessError {
            editorLog.notice("frame at \(time) failed: \(e.stderrTail, privacy: .public)")
            return nil
        }
        return FileManager.default.fileExists(atPath: out.path) ? out : nil
    }

    /// Thumbnails via AVFoundation for formats it can open (displayed orientation). `onFrame` runs on
    /// the main queue as each image arrives; returns when all are done, failed, or the task is cancelled.
    @MainActor
    public static func avFrames(url: URL, times: [Double], height: CGFloat,
                                onFrame: @escaping @MainActor (Int, NSImage) -> Void) async {
        guard !times.isEmpty else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let requested = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        let counter = FrameCounter(total: times.count)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                generator.generateCGImagesAsynchronously(forTimes: requested.map { NSValue(time: $0) }) { time, cgImage, _, result, _ in
                    let index = requested.firstIndex { CMTimeCompare($0, time) == 0 }
                    let image = (result == .succeeded ? cgImage : nil).map { NSImage(cgImage: $0, size: .zero) }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let index, let image { onFrame(index, image) }
                        }
                        if counter.finishOne() { done.resume() }
                    }
                }
            }
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    // MARK: Waveform

    /// Peak level per bucket, 0…1 on a 60 dB scale, about `buckets` values across the clip.
    public func waveform(duration: Double, sampleRate: Int?, buckets: Int) async throws -> [Float] {
        let ff = try requireFFmpeg()
        guard duration > 0, buckets > 0 else { return [] }
        let sr = Double(sampleRate ?? 48_000)
        let perBucket = max(32, Int((sr * duration / Double(buckets)).rounded()))
        let filter = "aformat=channel_layouts=mono,asetnsamples=n=\(perBucket):p=0,"
            + "astats=metadata=1:reset=1:measure_overall=Peak_level:measure_perchannel=none,"
            + "ametadata=mode=print:key=lavfi.astats.Overall.Peak_level:file=-"
        let collector = LineCollector()
        try await ProcessRunner.run(ff, ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", source.path,
                                         "-map", "0:a:0", "-af", filter, "-f", "null", "-"],
                                    stdoutLine: { collector.append($0) })
        return Self.parsePeakLevels(collector.lines)
    }

    /// `lavfi.astats.Overall.Peak_level=-6.02` lines → display levels.
    public static func parsePeakLevels(_ lines: [String]) -> [Float] {
        let key = "lavfi.astats.Overall.Peak_level="
        return lines.compactMap { line in
            guard let r = line.range(of: key) else { return nil }
            return level(fromDB: String(line[r.upperBound...]))
        }
    }

    /// dBFS → 0…1 over a 60 dB range; `-inf`/garbage → 0.
    public static func level(fromDB text: String) -> Float {
        guard let db = Double(text.trimmingCharacters(in: .whitespaces)), db.isFinite else { return 0 }
        return Float(min(1, max(0, (db + 60) / 60)))
    }

    /// Averages/peaks `levels` down (or stretches up) to exactly `count` values for drawing.
    public static func resample(_ levels: [Float], to count: Int) -> [Float] {
        guard count > 0, !levels.isEmpty else { return [] }
        return (0..<count).map { i in
            let lo = Int(Double(i) * Double(levels.count) / Double(count))
            let hi = max(lo + 1, Int(Double(i + 1) * Double(levels.count) / Double(count)))
            return levels[min(lo, levels.count - 1)..<min(hi, levels.count)].max() ?? 0
        }
    }

    // MARK: Playback proxy

    /// Extensions AVFoundation can't open on macOS — these get a proxy.
    public static let nonNativeExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "ogg", "oga", "opus", "wma", "flv", "mpg", "mpeg", "ts", "3gp"]

    /// True when AVFoundation can play `url` directly (and decode its video when `needsVideo`).
    public static func canPlayNatively(_ url: URL, needsVideo: Bool) async -> Bool {
        if nonNativeExtensions.contains(url.pathExtension.lowercased()) { return false }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        if needsVideo {
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            guard let track = tracks.first, (try? await track.load(.isPlayable)) == true else { return false }
        }
        return true
    }

    /// Low-res H.264/AAC MP4 (or AAC M4A for audio) that AVFoundation can play, same timeline as the
    /// source. Tries libx264 → VideoToolbox → MPEG-4 part 2.
    public func proxy(hasVideo: Bool, hasAudio: Bool, duration: Double,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let ff = try requireFFmpeg()
        let out = workDir.appendingPathComponent(hasVideo ? "proxy.mp4" : "proxy.m4a")
        let audio = hasAudio ? ["-map", "0:a:0", "-c:a", "aac", "-b:a", "128k", "-ac", "2"] : ["-an"]
        let videoPlans: [[String]] = hasVideo
            ? [["-c:v", "libx264", "-preset", "ultrafast", "-tune", "fastdecode", "-crf", "28"],
               ["-c:v", "h264_videotoolbox", "-b:v", "1500k"],
               ["-c:v", "mpeg4", "-q:v", "5"]]
            : [[]]
        var lastError: Error?
        for plan in videoPlans {
            try Task.checkCancellation()
            var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-nostats",
                        "-progress", "pipe:1", "-stats_period", "0.25", "-i", source.path]
            if hasVideo {
                args += ["-map", "0:V:0", "-vf", "scale=-2:'2*trunc(min(480,ih)/2)',format=yuv420p"] + plan
            } else {
                args += ["-vn"]
            }
            args += audio + ["-movflags", "+faststart", out.path]
            let total = duration
            do {
                try await ProcessRunner.run(ff, args, stdoutLine: { line in
                    if line.hasPrefix("out_time_us="), total > 0, let us = Double(line.dropFirst("out_time_us=".count)) {
                        progress(min(1, max(0, us / 1_000_000 / total)))
                    }
                })
                progress(1)
                return out
            } catch let e as ProcessError {
                editorLog.notice("proxy attempt failed: \(e.stderrTail, privacy: .public)")
                lastError = EngineError.failed("Preview failed: \(e.stderrTail.split(separator: "\n").last ?? "")")
            }
        }
        throw lastError ?? EngineError.failed("Preview failed")
    }

    static func fmt(_ seconds: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }
}

/// Counts AVAssetImageGenerator callbacks (one per requested time, including failures/cancels).
final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(total: Int) { remaining = total }

    /// True exactly once, when the last callback arrives.
    func finishOne() -> Bool {
        lock.withLock {
            remaining -= 1
            return remaining == 0
        }
    }
}

/// Thread-safe line sink for `ProcessRunner`'s stdout handler.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var lines: [String] { lock.withLock { storage } }
}
