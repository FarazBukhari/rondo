import Foundation
import Testing
import RondoKit
@testable import MediaEngine

/// User quality settings: `crf`, `preset`, `audioBitrate` (kbps).
@Suite struct QualityTests {
    private func convert(_ file: String, to target: String, _ options: [String: OptionValue]) async throws -> (URL, Sandbox) {
        let input = try await Fixtures.shared.url(file)
        let box = try Sandbox()
        let out = try await box.run(JobSpec(inputs: [input], operation: .convert(to: target), options: options))
        return (out[0], box)
    }

    @Test(arguments: [("clip.webm", "mp4"), ("clip.mp4", "webm"), ("clip.mkv", "avi"), ("clip.mp4", "wmv")])
    func lowerCRFMakesLargerVideo(_ file: String, _ target: String) async throws {
        let (hi, b1) = try await convert(file, to: target, ["crf": .int(12)])
        defer { b1.cleanup() }
        let (lo, b2) = try await convert(file, to: target, ["crf": .int(42)])
        defer { b2.cleanup() }
        let big = FileStamp(hi).size, small = FileStamp(lo).size
        #expect(big > small, "crf 12 → \(big) B, crf 42 → \(small) B")
    }

    @Test func compressQualityModeUsesCRF() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let box = try Sandbox(); defer { box.cleanup() }
        let p = ProgressRecorder()
        let out = try await box.run(JobSpec(inputs: [input], operation: .tool("video.compress"),
                                            options: ["crf": .int(40), "preset": .string("fast"), "audioBitrate": .int(64)]),
                                    progress: p)
        #expect(FileStamp(out[0]).size < FileStamp(input).size)
        let info = try await Probe.info(out[0])
        #expect(info.video?.codec == "h264")
        #expect(approx(info.duration, 2))
        p.expectMonotonic()

        // Lossless CRF can't shrink the clip → clear error, nothing written.
        let box2 = try Sandbox(); defer { box2.cleanup() }
        await #expect(throws: EngineError.self) {
            try await box2.run(JobSpec(inputs: [input], operation: .tool("video.compress"), options: ["crf": .int(0)]))
        }
        #expect(box2.contents.isEmpty)
    }

    @Test(arguments: [("tone.wav", "mp3"), ("tone.flac", "m4a"), ("tone.wav", "opus"), ("tone.mp3", "wma")])
    func audioBitrateSetsOutputBitrate(_ file: String, _ target: String) async throws {
        let (lowURL, b1) = try await convert(file, to: target, ["audioBitrate": .int(64)])
        defer { b1.cleanup() }
        let (highURL, b2) = try await convert(file, to: target, ["audioBitrate": .int(256)])
        defer { b2.cleanup() }
        let low = try await Probe.info(lowURL), high = try await Probe.info(highURL)
        let lowRate = low.audio?.bitRate ?? low.totalBitRate ?? 0
        let highRate = high.audio?.bitRate ?? high.totalBitRate ?? 0
        #expect(lowRate > 0 && lowRate < 100_000, "64k → \(lowRate)")
        #expect(highRate > lowRate * 2, "64k → \(lowRate), 256k → \(highRate)")
    }

    @Test func audioBitrateOnVideoConversionAndCompress() async throws {
        let (out, b1) = try await convert("clip.mov", to: "mp4", ["audioBitrate": .int(64)])   // pcm → aac re-encode
        defer { b1.cleanup() }
        let info = try await Probe.info(out)
        #expect((info.audio?.bitRate ?? 0) < 90_000, "audio \(info.audio?.bitRate ?? -1)")

        let input = try await Fixtures.shared.url("tone.wav")
        let box = try Sandbox(); defer { box.cleanup() }
        let c = try await box.run(JobSpec(inputs: [input], operation: .tool("audio.compress"), options: ["audioBitrate": .int(96)]))
        #expect(c[0].pathExtension == "m4a")
        let ci = try await Probe.info(c[0])
        #expect(approx(Double(ci.audio?.bitRate ?? 0) / 1000, 96, tolerance: 25))
    }

    @Test func streamCopyIgnoresQuality() async throws {
        let input = try await Fixtures.shared.url("clip.mp4")
        let (out, box) = try await convert("clip.mp4", to: "mkv", ["crf": .int(45), "audioBitrate": .int(32)])
        defer { box.cleanup() }
        let src = try await Probe.info(input), dst = try await Probe.info(out)
        #expect(dst.audio?.codec == "aac")
        #expect(abs(Double(FileStamp(out).size) - Double(FileStamp(input).size)) < Double(FileStamp(input).size) * 0.1)
        #expect(dst.video?.width == src.video?.width)
    }

    @Test func encoderArgsMapping() throws {
        let json = """
        {"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":1280,"height":720,"avg_frame_rate":"30/1"}],
         "format":{"duration":"10"}}
        """
        let info = try MediaInfo.parse(json: Data(json.utf8), fileSize: 0)
        // Absent keys → previous defaults.
        #expect(VideoEncoder.x264.args(rate: .auto, info: info).starts(with: ["-c:v", "libx264", "-preset", "medium", "-crf", "20"]))
        #expect(VideoEncoder.vp9.args(rate: .auto, info: info).contains("32"))
        // Given keys.
        let q = Quality(crf: 18, preset: "slow")
        #expect(VideoEncoder.x264.args(rate: .auto, info: info, quality: q).starts(with: ["-c:v", "libx264", "-preset", "slow", "-crf", "18"]))
        let vp9 = VideoEncoder.vp9.args(rate: .auto, info: info, quality: Quality(crf: 23))
        #expect(vp9.starts(with: ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0"]))
        #expect(VideoEncoder.mpeg4.args(rate: .auto, info: info, quality: Quality(crf: 23)).contains("3"))
        let vt = { (crf: Int) -> Int in
            let a = VideoEncoder.h264VT.args(rate: .auto, info: info, quality: Quality(crf: crf))
            return Int(a[a.firstIndex(of: "-b:v")! + 1])!
        }
        #expect(vt(23) == VideoEncoder.estimateBitrate(info))
        #expect(vt(17) > vt(23) && vt(23) > vt(29))
        // Bad preset falls back; crf clamps.
        #expect(Quality(crf: 99, preset: "warp9").crf == 51)
        #expect(Quality(crf: 99, preset: "warp9").preset == nil)
        let job = JobSpec(inputs: [], operation: .convert(to: "mp4"), options: ["crf": .int(23), "preset": .string("Fast"), "audioBitrate": .int(192)])
        #expect(Quality(job) == Quality(crf: 23, preset: "fast", audioBitrate: 192_000))
        #expect(Quality(JobSpec(inputs: [], operation: .convert(to: "mp4"))).isEmpty)
    }
}

/// Encoder probe must not depend on the Swift cooperative pool.
@Suite(.serialized) struct EncoderProbeConcurrencyTests {
    @Test func concurrentFirstCallersShareOneProbe() throws {
        let ffmpeg = try ToolLocator().require("ffmpeg")
        let before = EncoderProbe.spawnCount
        EncoderProbe.resetCache()
        let results = ResultList()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            results.add(EncoderProbe.encodersBlocking(ffmpeg: ffmpeg))
        }
        // ≤ 1: a probe already in flight from another suite may legitimately fill the cache for us.
        #expect(EncoderProbe.spawnCount - before <= 1)
        #expect(results.all.count == 8)
        #expect(Set(results.all.map(\.count)).count == 1)
        #expect(results.all.first?.contains("aac") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func syncCapabilityChecksFromManyTasksDoNotStarve() async throws {
        EncoderProbe.resetCache()
        let width = ProcessInfo.processInfo.activeProcessorCount * 4
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<width {
                group.addTask { FFmpegEngine().conversions().count + FFmpegEngine().tools().count }
            }
            var out: [Int] = []
            for await c in group { out.append(c) }
            return out
        }
        #expect(counts.count == width)
        #expect(Set(counts).count == 1)
        #expect((counts.first ?? 0) > 100)
    }
}

final class ResultList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Set<String>] = []
    func add(_ s: Set<String>) { lock.withLock { items.append(s) } }
    var all: [Set<String>] { lock.withLock { items } }
}
