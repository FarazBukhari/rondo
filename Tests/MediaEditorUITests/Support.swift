import Foundation
import RondoKit
import Testing
@testable import MediaEditorUI

/// Small generated fixtures under fixtures/out/W7/src (ffmpeg lavfi; no downloads).
actor W7Fixtures {
    static let shared = W7Fixtures()
    private var task: Task<URL, Error>?

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let outRoot = packageRoot.appendingPathComponent("fixtures/out/W7", isDirectory: true)

    static var hasFFmpeg: Bool { ToolLocator().has("ffmpeg") && ToolLocator().has("ffprobe") }

    static let specs: [(name: String, args: [String])] = {
        let video = ["-f", "lavfi", "-i", "testsrc=size=320x180:rate=25:duration=3"]
        let tone = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3"]
        let x264 = ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
        return [
            ("clip.mp4", video + tone + x264 + ["-c:a", "aac", "-ac", "2", "-shortest"]),
            ("clip.mkv", video + tone + x264 + ["-c:a", "libopus", "-ac", "2", "-shortest"]),
            // First second quiet, then loud: the waveform must show the step.
            ("step.wav", ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=3,volume='if(lt(t,1),0.02,0.9)':eval=frame",
                          "-c:a", "pcm_s16le"]),
            ("tone.ogg", tone + ["-c:a", "libopus", "-b:a", "64k"]),
            // Heavy-to-decode clip (1080p, ~1.3 s to proxy here) so proxy generation is still running when we cancel it.
            ("long.mkv", ["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30:duration=30"] + x264 + ["-crf", "40"]),
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
        let dir = outRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ffmpeg = try ToolLocator().require("ffmpeg")
        for spec in specs {
            let final = dir.appendingPathComponent(spec.name)
            if FileManager.default.fileExists(atPath: final.path) { continue }
            let tmp = dir.appendingPathComponent("tmp-" + spec.name)
            try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + spec.args + [tmp.path])
            try FileManager.default.moveItem(at: tmp, to: final)
        }
        // Same clip flagged to display rotated a quarter turn (stream copy + display matrix).
        let rotated = dir.appendingPathComponent("rotated.mp4")
        if !FileManager.default.fileExists(atPath: rotated.path) {
            let tmp = dir.appendingPathComponent("tmp-rotated.mp4")
            try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-display_rotation", "90",
                                                 "-i", dir.appendingPathComponent("clip.mp4").path, "-c", "copy", tmp.path])
            try FileManager.default.moveItem(at: tmp, to: rotated)
        }
        // Second name for the heavy clip (hard link: no extra disk) so two editors can build proxies at once.
        let longB = dir.appendingPathComponent("long-b.mkv")
        if !FileManager.default.fileExists(atPath: longB.path) {
            try FileManager.default.linkItem(at: dir.appendingPathComponent("long.mkv"), to: longB)
        }
        return dir
    }

    /// Fresh output dir under fixtures/out/W7/<name>.
    static func outDir(_ name: String) throws -> URL {
        let d = outRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

/// Polls `condition` on the main actor until true or `timeout` seconds pass. The default is generous:
/// the full suite runs every target in parallel (ffmpeg-heavy engine suites included), so preview work
/// can be slow there even though it takes well under a second on an idle machine.
@MainActor
func waitUntil(_ timeout: Double = 180, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
}

func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }

func approx(_ a: [ClosedRange<Double>], _ b: [ClosedRange<Double>], _ eps: Double = 1e-6) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { approx($0.lowerBound, $1.lowerBound, eps) && approx($0.upperBound, $1.upperBound, eps) }
}

func approx(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-6) -> Bool {
    abs(a.minX - b.minX) <= eps && abs(a.minY - b.minY) <= eps && abs(a.width - b.width) <= eps && abs(a.height - b.height) <= eps
}
