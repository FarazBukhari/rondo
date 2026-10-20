import Foundation
import Testing
import RondoKit
@testable import MediaEngine

private typealias T = FFmpegEngine.ToolIDs

private func tool(_ id: ToolID, _ inputs: [URL], _ options: [String: OptionValue] = [:]) -> JobSpec {
    JobSpec(inputs: inputs, operation: .tool(id), options: options)
}

@Suite struct VideoToolTests {
    @Test func compressPercent() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let before = FileStamp(input)
        let box = try Sandbox(); defer { box.cleanup() }
        let p = ProgressRecorder()
        let out = try await box.run(tool(T.videoCompress, [input], ["percent": .double(50)]), progress: p)
        #expect(out[0].lastPathComponent == "clip compressed.mp4")
        #expect(FileStamp(out[0]).size < before.size)
        #expect(FileStamp(input) == before)
        let info = try await Probe.info(out[0])
        #expect(info.video?.codec == "h264" && info.audio?.codec == "aac")
        #expect(approx(info.duration, 2))
        p.expectMonotonic()
    }

    @Test func compressTargetBytesTwoPass() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let srcSize = FileStamp(input).size
        let target = srcSize * 6 / 10
        let box = try Sandbox(); defer { box.cleanup() }
        let p = ProgressRecorder()
        let out = try await box.run(tool(T.videoCompress, [input], ["targetBytes": .int(target)]), progress: p)
        let size = FileStamp(out[0]).size
        #expect(size <= target * 115 / 100, "got \(size) for target \(target)")
        p.expectMonotonic()
    }

    @Test func compressKeepsContainer() async throws {
        let input = try await Fixtures.shared.url("clip.webm")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoCompress, [input], ["percent": .double(40)]))
        #expect(out[0].pathExtension == "webm")
        let info = try await Probe.info(out[0])
        #expect(["vp9", "vp8"].contains(info.video?.codec ?? ""))
    }

    @Test func trimSingleRange() async throws {
        let input = try await Fixtures.shared.url("clip.mov")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoTrim, [input], ["ranges": .ranges([0.5...1.5])]))
        #expect(out[0].lastPathComponent == "clip trimmed.mov")
        let info = try await Probe.info(out[0])
        #expect(approx(info.duration, 1.0, tolerance: 0.15), "duration \(info.duration ?? -1)")
    }

    @Test func trimMultipleRangesJoinsThem() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoTrim, [input], ["ranges": .ranges([0...0.5, 1.0...1.6])]))
        let info = try await Probe.info(out[0])
        #expect(approx(info.duration, 1.1, tolerance: 0.15), "duration \(info.duration ?? -1)")
        #expect(info.audio != nil)
    }

    @Test func trimFastCopy() async throws {
        let input = try await Fixtures.shared.url("clip.mkv")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoTrim, [input], ["ranges": .ranges([0...1.0]), "precise": .bool(false)]))
        let info = try await Probe.info(out[0])
        #expect(info.duration ?? 0 > 0.5 && info.duration ?? 9 < 1.6)
    }

    @Test func trimWithoutRangesFails() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let box = try Sandbox(); defer { box.cleanup() }
        await #expect(throws: EngineError.self) { try await box.run(tool(T.videoTrim, [input])) }
        #expect(box.contents.isEmpty)
    }

    @Test func crop() async throws {
        let input = try await Fixtures.shared.url("clip.avi")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoCrop, [input], ["rect": .list([10, 10, 81, 61])]))
        #expect(out[0].lastPathComponent == "clip cropped.avi")
        let info = try await Probe.info(out[0])
        #expect(info.video?.width == 80 && info.video?.height == 60)
        #expect(approx(info.duration, 2))
    }

    @Test(arguments: [(2.0, 1.0), (0.5, 4.0), (4.0, 0.5)])
    func speed(_ speed: Double, _ expected: Double) async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoSpeed, [input], ["speed": .double(speed)]))
        let info = try await Probe.info(out[0])
        #expect(approx(info.duration, expected, tolerance: 0.2), "duration \(info.duration ?? -1)")
        #expect(approx(info.audio?.duration, expected, tolerance: 0.2), "audio \(info.audio?.duration ?? -1)")
    }

    @Test func splitEqualParts() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoSplit, [input], ["parts": .int(2)]))
        #expect(out[0].lastPathComponent == "clip (parts)")
        let files = try FileManager.default.contentsOfDirectory(at: out[0], includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.map(\.lastPathComponent) == ["clip 1.mp4", "clip 2.mp4"])
        for f in files {
            let info = try await Probe.info(f)
            #expect(approx(info.duration, 1.0, tolerance: 0.15))
        }
    }

    @Test func splitByRanges() async throws {
        let input = try await Fixtures.shared.url("clip.wmv")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoSplit, [input], ["ranges": .ranges([0...0.6, 0.6...2])]))
        let files = try FileManager.default.contentsOfDirectory(at: out[0], includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.pathExtension == "wmv" })
    }

    @Test func joinCompatibleUsesStreamCopy() async throws {
        let a = try await Fixtures.shared.url("clip.mp4")
        let b = try await Fixtures.shared.url("clip.m4v")
        let box = try Sandbox(); defer { box.cleanup() }
        let p = ProgressRecorder()
        let out = try await box.run(tool(T.videoJoin, [a, b]), progress: p)
        #expect(out.count == 1)
        #expect(out[0].lastPathComponent == "clip joined.mp4")
        let info = try await Probe.info(out[0])
        #expect(approx(info.duration, 4.0, tolerance: 0.3), "duration \(info.duration ?? -1)")
        #expect(info.audio?.codec == "aac")
        p.expectMonotonic()
    }

    @Test func joinMismatchedReencodes() async throws {
        let a = try await Fixtures.shared.url("clip.mp4")
        let b = try await Fixtures.shared.url("small.mp4")   // 120×90, 30 fps, no audio
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoJoin, [a, b]))
        let info = try await Probe.info(out[0])
        #expect(approx(info.duration, 3.0, tolerance: 0.3), "duration \(info.duration ?? -1)")
        #expect(info.video?.width == 160 && info.video?.height == 120)
        #expect(info.audio != nil)
    }

    @Test func snapshot() async throws {
        let input = try await Fixtures.shared.url("clip.webm")
        let box = try Sandbox(); defer { box.cleanup() }
        let p = ProgressRecorder()
        let out = try await box.run(tool(T.videoSnapshot, [input], ["time": .double(1.0)]), progress: p)
        #expect(out[0].lastPathComponent == "clip snapshot.png")
        let info = try await Probe.info(out[0])
        #expect(info.video?.codec == "png" && info.video?.width == 160)
        p.expectMonotonic()
    }

    @Test func snapshotPastEndFallsBack() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoSnapshot, [input], ["time": .double(99)]))
        #expect(FileManager.default.fileExists(atPath: out[0].path))
    }

    @Test(arguments: [("clip.mp4", "auto", "m4a", "aac"), ("clip.mkv", "auto", "opus", "opus"),
                      ("clip.mov", "auto", "wav", "pcm_s16le"), ("clip.webm", "mp3", "mp3", "mp3")])
    func extractAudio(_ file: String, _ format: String, _ ext: String, _ codec: String) async throws {
        let input = try await Fixtures.shared.url(file)
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.videoExtractAudio, [input], ["format": .string(format)]))
        #expect(out[0].lastPathComponent == "clip audio.\(ext)")
        let info = try await Probe.info(out[0])
        #expect(info.audio?.codec == codec)
        #expect(info.video == nil)
        #expect(approx(info.duration, 2))
    }

    @Test(arguments: ["mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v", "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"])
    func stripMetadata(_ ext: String) async throws {
        let isVideo = VideoContainer.inputIDs.contains(ext)
        let src = try await Fixtures.shared.url(isVideo ? "clip.\(ext)" : "tone.\(ext)")
        let box = try Sandbox(); defer { box.cleanup() }
        let tagged = box.dir.appendingPathComponent("tagged.\(ext)")
        try await ProcessRunner.run(try ToolLocator().require("ffmpeg"),
                                    ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-i", src.path, "-map", "0",
                                     "-c", "copy", "-metadata", "title=Secret Title", "-metadata", "artist=Someone", tagged.path])
        let tags = try await formatTags(tagged)
        #expect(tags.values.contains("Secret Title"))

        let out = try await box.run(tool(T.stripMetadata, [tagged]))
        #expect(out[0].lastPathComponent == "tagged stripped.\(ext)")
        let after = try await formatTags(out[0])
        #expect(!after.values.contains("Secret Title"), "tags left: \(after)")
        #expect(!after.values.contains("Someone"))
        let info = try await Probe.info(out[0])
        #expect(approx(info.duration, 2))
    }

    private func formatTags(_ url: URL) async throws -> [String: String] {
        let ffprobe = try ToolLocator().require("ffprobe")
        let r = try await ProcessRunner.run(ffprobe, ["-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json", url.path])
        let obj = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] ?? [:]
        var tags: [String: String] = [:]
        if let f = obj["format"] as? [String: Any], let t = f["tags"] as? [String: String] { tags.merge(t) { a, _ in a } }
        for s in obj["streams"] as? [[String: Any]] ?? [] {
            if let t = s["tags"] as? [String: String] { tags.merge(t) { a, _ in a } }
        }
        return tags.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }
}

@Suite struct AudioToolTests {
    @Test func compressLossyKeepsFormat() async throws {
        let input = try await Fixtures.shared.url("tone.mp3")
        let box = try Sandbox(); defer { box.cleanup() }
        let p = ProgressRecorder()
        let out = try await box.run(tool(T.audioCompress, [input], ["percent": .double(50)]), progress: p)
        #expect(out[0].lastPathComponent == "tone compressed.mp3")
        #expect(FileStamp(out[0]).size < FileStamp(input).size)
        p.expectMonotonic()
    }

    @Test func compressLosslessBecomesAAC() async throws {
        let input = try await Fixtures.shared.url("tone.wav")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.audioCompress, [input], ["percent": .double(80)]))
        #expect(out[0].lastPathComponent == "tone compressed.m4a")
        let info = try await Probe.info(out[0])
        #expect(info.audio?.codec == "aac")
        #expect(FileStamp(out[0]).size < FileStamp(input).size / 3)
    }

    @Test(arguments: ["tone.m4a", "tone.ogg", "tone.opus", "tone.wma"])
    func compressTargetBytes(_ file: String) async throws {
        let input = try await Fixtures.shared.url(file)
        let target = FileStamp(input).size / 2
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.audioCompress, [input], ["targetBytes": .int(target)]))
        #expect(out[0].pathExtension == input.pathExtension)
        let size = FileStamp(out[0]).size
        #expect(size < FileStamp(input).size)
        #expect(size <= target * 130 / 100, "got \(size) for \(target)")
    }

    @Test func normalizeRaisesQuietAudio() async throws {
        let input = try await Fixtures.shared.url("quiet.wav")
        let box = try Sandbox(); defer { box.cleanup() }
        let p = ProgressRecorder()
        let out = try await box.run(tool(T.audioNormalize, [input]), progress: p)
        #expect(out[0].lastPathComponent == "quiet normalized.wav")
        let info = try await Probe.info(out[0])
        #expect(info.audio?.sampleRate == 44_100)
        #expect(info.audio?.codec == "pcm_s16le")
        #expect(approx(info.duration, 2, tolerance: 0.1))
        let before = try await Probe.volume(input)
        let after = try await Probe.volume(out[0])
        #expect(after.mean > before.mean + 10, "before \(before.mean) after \(after.mean)")
        p.expectMonotonic()
    }

    @Test(arguments: ["tone.opus", "tone.mp3"])
    func normalizeLossy(_ file: String) async throws {
        let input = try await Fixtures.shared.url(file)
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.audioNormalize, [input], ["lufs": .double(-14)]))
        #expect(out[0].pathExtension == input.pathExtension)
        let info = try await Probe.info(out[0])
        #expect(approx(info.duration, 2, tolerance: 0.15))
    }

    @Test func trimSingleAndMulti() async throws {
        let input = try await Fixtures.shared.url("tone.flac")
        let box = try Sandbox(); defer { box.cleanup() }
        let one = try await box.run(tool(T.audioTrim, [input], ["ranges": .ranges([0.5...1.5])]))
        #expect(one[0].lastPathComponent == "tone trimmed.flac")
        #expect(approx(try await Probe.info(one[0]).duration, 1.0, tolerance: 0.05))
        let two = try await box.run(tool(T.audioTrim, [input], ["ranges": .ranges([0...0.5, 1.2...1.7])]))
        #expect(approx(try await Probe.info(two[0]).duration, 1.0, tolerance: 0.05))
    }

    @Test func bleepSilenceMutesRange() async throws {
        let input = try await Fixtures.shared.url("tone.wav")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.audioBleep, [input], ["ranges": .ranges([0.5...1.2]), "tone": .bool(false)]))
        #expect(out[0].lastPathComponent == "tone bleeped.wav")
        let inside = try await Probe.volume(out[0], start: 0.52, length: 0.66)
        let outside = try await Probe.volume(out[0], start: 1.25, length: 0.5)
        #expect(inside.max < -80 || inside.max.isInfinite, "inside \(inside)")
        #expect(outside.max > -30, "outside \(outside)")
    }

    @Test func bleepToneReplacesRange() async throws {
        let input = try await Fixtures.shared.url("tone.m4a")
        let box = try Sandbox(); defer { box.cleanup() }
        let p = ProgressRecorder()
        let out = try await box.run(tool(T.audioBleep, [input], ["ranges": .ranges([0.5...1.2]), "frequency": .double(1000)]), progress: p)
        let info = try await Probe.info(out[0])
        #expect(info.audio?.codec == "aac")
        #expect(approx(info.duration, 2, tolerance: 0.1))
        let inside = try await Probe.volume(out[0], start: 0.6, length: 0.5)
        #expect(inside.max > -30, "tone should be audible: \(inside)")
        p.expectMonotonic()
    }

    @Test(arguments: [("tone.mp3", "mono", 1, "tone mono.mp3"), ("mono.wav", "stereo", 2, "mono stereo.wav"),
                      ("tone.aiff", "swap", 2, "tone swapped.aiff"), ("tone.ogg", "mono", 1, "tone mono.ogg")])
    func channels(_ file: String, _ mode: String, _ count: Int, _ name: String) async throws {
        let input = try await Fixtures.shared.url(file)
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(tool(T.audioChannels, [input], ["channels": .string(mode)]))
        #expect(out[0].lastPathComponent == name)
        let info = try await Probe.info(out[0])
        #expect(info.audio?.channels == count)
    }

    @Test func swapNeedsStereo() async throws {
        let input = try await Fixtures.shared.url("mono.wav")
        let box = try Sandbox(); defer { box.cleanup() }
        await #expect(throws: EngineError.self) {
            try await box.run(tool(T.audioChannels, [input], ["channels": .string("swap")]))
        }
    }
}

/// Regression: ffmpeg's native Vorbis encoder aborted (`floor_encode` assertion) when re-encoding
/// decoded Vorbis, so every same-format tool on .ogg failed. Every audio tool on ogg + opus inputs.
@Suite struct OggOpusRegressionTests {
    static let toolCases: [(String, [String: OptionValue])] = [
        ("audio.compress", ["percent": .double(40)]),
        ("audio.normalize", [:]),
        ("audio.trim", ["ranges": .ranges([0.2...1.4])]),
        ("audio.bleep", ["ranges": .ranges([0.5...1.0])]),
        ("audio.bleep", ["ranges": .ranges([0.5...1.0]), "tone": .bool(false)]),
        ("audio.channels", ["channels": .string("mono")]),
        ("audio.channels", ["channels": .string("stereo")]),
        ("audio.channels", ["channels": .string("swap")]),
        ("media.metadata.strip", [:]),
    ]

    static var inputs: [String] {
        var names = ["tone.ogg", "tone.opus"]
        for ext in ["ogg", "opus"] where FileManager.default.fileExists(atPath: smokeDir.appendingPathComponent("sample.\(ext)").path) {
            names.append("smoke:sample.\(ext)")
        }
        return names
    }

    @Test(arguments: inputs, 0..<toolCases.count)
    func audioTool(_ file: String, _ index: Int) async throws {
        let (id, options) = Self.toolCases[index]
        let input: URL = file.hasPrefix("smoke:")
            ? smokeDir.appendingPathComponent(String(file.dropFirst(6)))
            : try await Fixtures.shared.url(file)
        let srcInfo = try await Probe.info(input)
        if id == "audio.channels", options["channels"] == .string("swap"), srcInfo.audio?.channels != 2 { return }
        let box = try Sandbox(); defer { box.cleanup() }
        let p = ProgressRecorder()
        let out = try await box.run(JobSpec(inputs: [input], operation: .tool(ToolID(id)), options: options), progress: p)
        #expect(out[0].pathExtension == input.pathExtension)
        let info = try await Probe.info(out[0])
        #expect(["vorbis", "opus"].contains(info.audio?.codec ?? ""), "codec \(info.audio?.codec ?? "none")")
        // Same-format tools keep Vorbis (the s16 workaround, not the Opus fallback) unless they need Opus.
        let needsOpus = id == "audio.compress" || options["channels"] == .string("mono")
        if input.pathExtension == "ogg" && !needsOpus {
            #expect(info.audio?.codec == "vorbis")
        }
        #expect((info.duration ?? 0) > 0.5)
        p.expectMonotonic()
    }

    @Test func extractToOggUsesVorbis() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let box = try Sandbox(); defer { box.cleanup() }
        let out = try await box.run(JobSpec(inputs: [input], operation: .tool("video.audio.extract"), options: ["format": .string("ogg")]))
        let info = try await Probe.info(out[0])
        #expect(info.audio?.codec == "vorbis")
        #expect(approx(info.duration, 2))
    }
}

@Suite struct CancellationTests {
    /// Cancel as soon as ffmpeg reports progress; the job must throw and leave nothing behind.
    @Test(arguments: [
        JobSpec(inputs: [], operation: .convert(to: "webm")),
        JobSpec(inputs: [], operation: .tool("video.compress"), options: ["targetBytes": .int(20_000)]),
        JobSpec(inputs: [], operation: .tool("audio.normalize")),
    ])
    func cancelLeavesNoOutput(_ template: JobSpec) async throws {
        let file = template.operation == .tool("audio.normalize") ? "tone.wav" : "clip.mp4"
        let input = try await Fixtures.shared.url(file)
        let before = FileStamp(input)
        let box = try Sandbox(); defer { box.cleanup() }
        var spec = template
        spec.inputs = [input]
        let canceller = Canceller()
        let progress = ProgressRecorder { v in if v > 0 { canceller.cancel() } }
        let task = Task {
            try await box.run(spec, progress: progress)
        }
        canceller.set(task)
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected cancellation, got \(result)")
            return
        }
        #expect(error is CancellationError, "got \(error)")
        #expect(box.contents.isEmpty, "left: \(box.contents)")
        #expect(FileStamp(input) == before)
    }

    @Test func cancelBeforeStartThrows() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let box = try Sandbox(); defer { box.cleanup() }
        let task = Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            return try await box.run(JobSpec(inputs: [input], operation: .convert(to: "mov")))
        }
        task.cancel()
        let result = await task.result
        guard case .failure = result else { Issue.record("expected failure"); return }
        #expect(box.contents.isEmpty)
    }
}
