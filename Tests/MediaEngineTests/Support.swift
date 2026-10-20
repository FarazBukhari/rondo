import Foundation
import Testing
import RondoKit
@testable import MediaEngine

/// Tiny generated fixtures (2 s, 160×120 testsrc / 440 Hz sine) under fixtures/out/W4/src.
actor Fixtures {
    static let shared = Fixtures()
    private var task: Task<URL, Error>?

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let specs: [(name: String, args: [String])] = {
        let video = ["-f", "lavfi", "-i", "testsrc=size=160x120:rate=25:duration=2"]
        let tone = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=2"]
        let av = video + tone
        let x264 = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
        let stereo = ["-ac", "2"]
        return [
            ("clip.mp4", av + x264 + ["-c:a", "aac"] + stereo + ["-shortest"]),
            ("clip.m4v", av + x264 + ["-c:a", "aac"] + stereo + ["-shortest"]),
            ("clip.mov", av + x264 + ["-c:a", "pcm_s16le"] + stereo + ["-shortest"]),
            ("clip.mkv", av + x264 + ["-c:a", "libopus"] + stereo + ["-shortest"]),
            ("clip.webm", av + ["-c:v", "libvpx", "-b:v", "200k", "-deadline", "realtime", "-c:a", "libopus"] + stereo + ["-shortest"]),
            ("clip.avi", av + ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "libmp3lame"] + stereo + ["-shortest"]),
            ("clip.wmv", av + ["-c:v", "wmv2", "-b:v", "300k", "-c:a", "wmav2"] + stereo + ["-shortest"]),
            ("small.mp4", ["-f", "lavfi", "-i", "testsrc2=size=120x90:rate=30:duration=1"] + x264),
            ("tone.mp3", tone + ["-c:a", "libmp3lame", "-b:a", "128k"] + stereo),
            ("tone.m4a", tone + ["-c:a", "aac", "-b:a", "128k"] + stereo),
            ("tone.wav", tone + ["-c:a", "pcm_s16le"] + stereo),
            ("tone.flac", tone + ["-c:a", "flac"] + stereo),
            ("tone.ogg", tone + ["-c:a", "vorbis", "-strict", "-2"] + stereo),
            ("tone.opus", tone + ["-c:a", "libopus", "-b:a", "96k"] + stereo),
            ("tone.aiff", tone + ["-c:a", "pcm_s16be"] + stereo),
            ("tone.wma", tone + ["-c:a", "wmav2", "-b:a", "128k"] + stereo),
            ("mono.wav", tone + ["-c:a", "pcm_s16le"]),
            ("quiet.wav", ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=2,volume=0.03", "-c:a", "pcm_s16le"] + stereo),
        ]
    }()

    func dir() async throws -> URL {
        if let task { return try await task.value }
        let t = Task { try await Self.generate() }
        task = t
        return try await t.value
    }

    func url(_ name: String) async throws -> URL {
        try await dir().appendingPathComponent(name)
    }

    private static func generate() async throws -> URL {
        let dir = packageRoot.appendingPathComponent("fixtures/out/W4/src", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ffmpeg = try ToolLocator().require("ffmpeg")
        for spec in specs {
            let final = dir.appendingPathComponent(spec.name)
            if FileManager.default.fileExists(atPath: final.path) { continue }
            let ext = final.pathExtension
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).\(ext)")
            try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"] + spec.args + [tmp.path])
            try? FileManager.default.moveItem(at: tmp, to: final)
            try? FileManager.default.removeItem(at: tmp)
        }
        return dir
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    private let hook: (@Sendable (Double) -> Void)?
    init(hook: (@Sendable (Double) -> Void)? = nil) { self.hook = hook }
    func add(_ v: Double) {
        lock.withLock { _values.append(v) }
        hook?(v)
    }
    var values: [Double] { lock.withLock { _values } }

    func expectMonotonic(sourceLocation: SourceLocation = #_sourceLocation) {
        let v = values
        #expect(!v.isEmpty, sourceLocation: sourceLocation)
        #expect(v.allSatisfy { $0 >= 0 && $0 <= 1 }, sourceLocation: sourceLocation)
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 <= $1 }, "progress not monotonic: \(v)", sourceLocation: sourceLocation)
        #expect(v.last == 1, sourceLocation: sourceLocation)
    }
}

/// Per-test output folder (deleted at the end).
struct Sandbox {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rondo-w4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    var contents: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    /// Runs `spec` with outputs into this sandbox; returns outputs.
    func run(_ spec: JobSpec, progress: ProgressRecorder = ProgressRecorder(),
             engine: FFmpegEngine = FFmpegEngine(), tools: ToolLocator = ToolLocator()) async throws -> [URL] {
        let temp = try TempDir.make(prefix: "w4test")
        defer { TempDir.remove(temp) }
        var spec = spec
        spec.destination = .folder(dir)
        let ctx = JobContext(progress: { progress.add($0) }, tools: tools, tempDir: temp, destination: spec.destination)
        return try await engine.run(spec, context: ctx)
    }
}

enum Probe {
    static func info(_ url: URL) async throws -> MediaInfo {
        let ff = try await FFmpeg.make(tools: ToolLocator())
        return try await ff.probe(url)
    }

    /// Mean/max volume (dB) via volumedetect over an optional window.
    static func volume(_ url: URL, start: Double? = nil, length: Double? = nil) async throws -> (mean: Double, max: Double) {
        let ffmpeg = try ToolLocator().require("ffmpeg")
        // atrim on decoded timestamps (input -ss on WAV is not sample-accurate).
        var filters: [String] = []
        if let start {
            let end = length.map { ":end=\(start + $0)" } ?? ""
            filters.append("atrim=start=\(start)\(end)")
        }
        filters.append("volumedetect")
        let args = ["-hide_banner", "-nostdin", "-nostats", "-i", url.path,
                    "-map", "0:a:0", "-af", filters.joined(separator: ","), "-f", "null", "-"]
        let r = try await ProcessRunner.run(ffmpeg, args)
        func value(_ key: String) -> Double {
            guard let line = r.stderrTail.split(separator: "\n").last(where: { $0.contains(key) }),
                  let token = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: " ").first
            else { return .nan }
            return Double(token) ?? -.infinity
        }
        return (value("mean_volume"), value("max_volume"))
    }
}

/// Snapshot of an input's size + mtime, to prove engines never modify inputs.
struct FileStamp: Equatable {
    let size: Int
    let modified: Date?
    init(_ url: URL) {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        size = v?.fileSize ?? -1
        modified = v?.contentModificationDate
    }
}

func approx(_ a: Double?, _ b: Double, tolerance: Double = 0.3) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

/// Cancels a task from inside a callback, even if the callback fires before the task handle is set.
final class Canceller: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<[URL], Error>?
    private var requested = false

    func set(_ t: Task<[URL], Error>) {
        let cancelNow: Bool = lock.withLock { task = t; return requested }
        if cancelNow { t.cancel() }
    }

    func cancel() {
        let t: Task<[URL], Error>? = lock.withLock { requested = true; return task }
        t?.cancel()
    }
}
