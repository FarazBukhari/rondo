import Foundation
import Testing
import RondoKit
@testable import MediaEngine

struct Pair: CustomTestStringConvertible, Sendable {
    let from: String
    let to: String
    var testDescription: String { "\(from) → \(to)" }
}

let videoPairs: [Pair] = VideoContainer.inputIDs.flatMap { from in
    (VideoContainer.outputIDs + ["gif", "mp3"]).filter { $0 != from }.map { Pair(from: from, to: $0) }
}

let audioPairs: [Pair] = FFmpegEngine.audioInputIDs.flatMap { from in
    FFmpegEngine.audioInputIDs.filter { $0 != from }.map { Pair(from: from, to: $0) }
}

let smokeDir = Fixtures.packageRoot.appendingPathComponent("fixtures/out/src", isDirectory: true)

let fixtureName: [String: String] = [
    "mp4": "clip.mp4", "m4v": "clip.m4v", "mov": "clip.mov", "mkv": "clip.mkv",
    "webm": "clip.webm", "avi": "clip.avi", "wmv": "clip.wmv",
    "mp3": "tone.mp3", "m4a": "tone.m4a", "wav": "tone.wav", "flac": "tone.flac",
    "ogg": "tone.ogg", "opus": "tone.opus", "aiff": "tone.aiff", "wma": "tone.wma",
]

@Suite struct ConversionTests {
    @Test(arguments: videoPairs)
    func video(_ pair: Pair) async throws {
        try await convert(pair)
    }

    @Test(arguments: audioPairs)
    func audio(_ pair: Pair) async throws {
        try await convert(pair)
    }

    /// Same matrix over the orchestrator's smoke fixtures (mono audio, VP9 WebM), when present.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: smokeDir.path)), arguments: videoPairs + audioPairs)
    func smokeFixtures(_ pair: Pair) async throws {
        try await convert(pair, input: smokeDir.appendingPathComponent("sample.\(pair.from)"))
    }

    func convert(_ pair: Pair, input given: URL? = nil) async throws {
        let input: URL
        if let given { input = given } else { input = try await Fixtures.shared.url(fixtureName[pair.from]!) }
        let before = FileStamp(input)
        let box = try Sandbox()
        defer { box.cleanup() }
        let progress = ProgressRecorder()
        let outputs = try await box.run(JobSpec(inputs: [input], operation: .convert(to: pair.to)), progress: progress)

        #expect(FileStamp(input) == before, "input was modified")
        try #require(outputs.count == 1)
        let out = outputs[0]
        let dst = try #require(FormatCatalog.format(id: pair.to))
        #expect(out.pathExtension == dst.preferredExtension)
        #expect(out.deletingLastPathComponent().standardizedFileURL == box.dir.standardizedFileURL)
        #expect(box.contents.count == 1)
        progress.expectMonotonic()

        let info = try await Probe.info(out)
        if let container = VideoContainer.forFormat(pair.to) {
            let videoOK = container.copyVideo.union(container.videoEncoders.map(\.codecName))
            let audioOK = container.copyAudio.union(container.audioEncoders.map(\.codecName))
            #expect(videoOK.contains(info.video?.codec ?? "none"), "video codec \(info.video?.codec ?? "none")")
            #expect(audioOK.contains(info.audio?.codec ?? "none"), "audio codec \(info.audio?.codec ?? "none")")
            #expect(info.video?.width == 160 && info.video?.height == 120)
            #expect(approx(info.duration, 2.0), "duration \(info.duration ?? -1)")
        } else if pair.to == "gif" {
            #expect(info.video?.codec == "gif")
            #expect(info.video?.width == 160)
        } else if let target = AudioTarget.forFormat(pair.to) {
            #expect(info.video == nil)
            let expected = target.copyable.union(AudioTarget.encoderCodecs(target))
            #expect(expected.contains(info.audio?.codec ?? "none"), "audio codec \(info.audio?.codec ?? "none")")
            #expect(approx(info.duration, 2.0), "duration \(info.duration ?? -1)")
        } else {
            Issue.record("unexpected target \(pair.to)")
        }
    }

    @Test func gifOptions() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let box = try Sandbox()
        defer { box.cleanup() }
        let out = try await box.run(JobSpec(inputs: [input], operation: .convert(to: "gif"),
                                            options: ["fps": .double(5), "width": .int(80)]))
        let info = try await Probe.info(out[0])
        #expect(info.video?.width == 80)
        #expect(info.video?.height == 60)
    }

    @Test func streamCopyWhenContainerAllows() async throws {
        // mp4 (h264 + aac) → mkv should copy both streams bit-for-bit.
        let input = try await Fixtures.shared.url("clip.mp4")
        let box = try Sandbox()
        defer { box.cleanup() }
        let out = try await box.run(JobSpec(inputs: [input], operation: .convert(to: "mkv")))
        let src = try await Probe.info(input)
        let dst = try await Probe.info(out[0])
        #expect(dst.video?.codec == "h264")
        #expect(dst.audio?.codec == "aac")
        #expect(dst.video?.bitRate == nil || src.video?.bitRate == nil || abs((dst.video!.bitRate!) - src.video!.bitRate!) < 20_000)
    }

    @Test func collisionGetsFinderStyleName() async throws {
        let input = try await Fixtures.shared.url("tone.wav")
        let box = try Sandbox()
        defer { box.cleanup() }
        let a = try await box.run(JobSpec(inputs: [input], operation: .convert(to: "mp3")))
        let b = try await box.run(JobSpec(inputs: [input], operation: .convert(to: "mp3")))
        #expect(a[0].lastPathComponent == "tone.mp3")
        #expect(b[0].lastPathComponent == "tone 2.mp3")
    }

    @Test func videoWithoutAudioToMP3Fails() async throws {
        let input = try await Fixtures.shared.url("small.mp4")
        let box = try Sandbox()
        defer { box.cleanup() }
        await #expect(throws: EngineError.self) {
            try await box.run(JobSpec(inputs: [input], operation: .convert(to: "mp3")))
        }
        #expect(box.contents.isEmpty)
    }
}

extension AudioTarget {
    /// Every codec this target can produce when encoding.
    static func encoderCodecs(_ t: AudioTarget) -> Set<String> {
        switch t.id {
        case "mp3": ["mp3"]
        case "m4a": ["aac", "alac"]
        case "wav": ["pcm_s16le", "pcm_s24le"]
        case "flac": ["flac"]
        case "ogg": ["vorbis", "opus"]
        case "opus": ["opus"]
        case "aiff": ["pcm_s16be", "pcm_s24be"]
        case "wma": ["wmav2"]
        default: []
        }
    }
}
