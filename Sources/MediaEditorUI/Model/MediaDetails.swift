import AVFoundation
import CoreGraphics
import Foundation
import RondoKit

/// What the editor needs to know about a media file. Sizes are pixels; `displaySize` is after rotation
/// (what the user sees, and what the engine's crop `rect` refers to).
public struct MediaDetails: Equatable, Sendable {
    public var duration: Double
    /// Coded size of the first real video stream (cover art ignored); nil for audio-only files.
    public var naturalSize: CGSize?
    /// 0, 90, 180 or 270.
    public var rotation: Int
    public var frameRate: Double?
    public var hasAudio: Bool
    public var sampleRate: Int?

    public init(duration: Double, naturalSize: CGSize?, rotation: Int = 0, frameRate: Double? = nil, hasAudio: Bool, sampleRate: Int? = nil) {
        self.duration = duration
        self.naturalSize = naturalSize
        self.rotation = CropGeometry.normalizedRotation(Double(rotation))
        self.frameRate = frameRate
        self.hasAudio = hasAudio
        self.sampleRate = sampleRate
    }

    public var hasVideo: Bool { naturalSize != nil }

    public var displaySize: CGSize? {
        naturalSize.map { CropGeometry.displaySize(natural: $0, rotation: rotation) }
    }

    // MARK: ffprobe

    /// Parses `ffprobe -show_format -show_streams -of json`.
    public static func parse(ffprobeJSON data: Data) throws -> MediaDetails {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.failed("ffprobe returned unreadable output")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = root["streams"] as? [[String: Any]] ?? []

        let video = streams.first { s in
            let disposition = s["disposition"] as? [String: Any] ?? [:]
            return s["codec_type"] as? String == "video" && (int(disposition["attached_pic"]) ?? 0) == 0
        }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }

        var natural: CGSize?
        var rotation = 0.0
        var fps: Double?
        if let v = video, let w = int(v["width"]), let h = int(v["height"]), w > 0, h > 0 {
            natural = CGSize(width: w, height: h)
            if let side = v["side_data_list"] as? [[String: Any]], let r = side.compactMap({ num($0["rotation"]) }).first {
                rotation = r
            } else if let tags = v["tags"] as? [String: Any], let r = num(tags["rotate"]) {
                rotation = r
            }
            fps = rate(v["avg_frame_rate"]) ?? rate(v["r_frame_rate"])
        }

        var duration = num(format["duration"]) ?? 0
        if duration <= 0 { duration = streams.compactMap { num($0["duration"]) }.max() ?? 0 }

        return MediaDetails(
            duration: max(0, duration),
            naturalSize: natural,
            rotation: Int(rotation.rounded()),
            frameRate: fps.flatMap { $0 > 0 && $0 < 1000 ? $0 : nil },
            hasAudio: audio != nil,
            sampleRate: audio.flatMap { int($0["sample_rate"]) }
        )
    }

    /// ffprobe when available (every format, same view of rotation as the engine), else AVFoundation.
    public static func probe(_ url: URL, tools: ToolLocator) async throws -> MediaDetails {
        if let ffprobe = tools.url(for: "ffprobe") {
            do {
                let result = try await ProcessRunner.run(ffprobe, ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path])
                return try parse(ffprobeJSON: Data(result.stdout.utf8))
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as ProcessError {
                editorLog.error("ffprobe failed: \(e.stderrTail, privacy: .public)")
                throw EngineError.invalidInput("\(url.lastPathComponent) is not a readable media file")
            }
        }
        return try await probeAV(url)
    }

    /// AVFoundation fallback (only formats macOS can open).
    public static func probeAV(_ url: URL) async throws -> MediaDetails {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var natural: CGSize?
        var rotation = 0
        var fps: Double?
        if let v = videoTracks.first {
            let (size, transform, rate) = try await v.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            if size.width > 0, size.height > 0 {
                natural = size
                rotation = CropGeometry.rotationDegrees(of: transform)
                fps = rate > 0 ? Double(rate) : nil
            }
        }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 || natural != nil || !audioTracks.isEmpty else {
            throw EngineError.invalidInput("\(url.lastPathComponent) is not a readable media file")
        }
        return MediaDetails(duration: seconds.isFinite ? seconds : 0, naturalSize: natural, rotation: rotation,
                            frameRate: fps, hasAudio: !audioTracks.isEmpty)
    }

    // MARK: JSON helpers

    private static func num(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue.isFinite ? n.doubleValue : nil
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
