import Foundation
import Testing
import RondoKit
@testable import MediaEngine

@Suite struct CapabilityTests {
    @Test func conversionsCoverTheMatrix() {
        let engine = FFmpegEngine()
        let pairs = Set(engine.conversions())
        for from in VideoContainer.inputIDs {
            for to in VideoContainer.outputIDs + ["gif", "mp3"] where to != from {
                #expect(pairs.contains(ConversionDescriptor(from: from, to: to)), "missing \(from)→\(to)")
            }
        }
        for from in FFmpegEngine.audioInputIDs {
            for to in FFmpegEngine.audioInputIDs where to != from {
                #expect(pairs.contains(ConversionDescriptor(from: from, to: to)), "missing \(from)→\(to)")
            }
        }
        #expect(!pairs.contains(ConversionDescriptor(from: "mp4", to: "m4v")))   // m4v is input-only
        #expect(!pairs.contains(ConversionDescriptor(from: "mp3", to: "mp4")))
        #expect(pairs.allSatisfy { $0.from != $0.to })
    }

    @Test func toolsAndFlags() throws {
        let tools = FFmpegEngine().tools()
        let ids = Set(tools.map(\.id.rawValue))
        #expect(ids == ["video.compress", "video.trim", "video.crop", "video.speed", "video.split", "video.join",
                        "video.snapshot", "video.audio.extract", "media.metadata.strip", "audio.compress",
                        "audio.normalize", "audio.trim", "audio.bleep", "audio.channels"])
        let ui = Set(tools.filter(\.needsUI).map(\.id.rawValue))
        #expect(ui == ["video.trim", "video.crop", "video.split", "video.snapshot", "audio.trim", "audio.bleep"])
        let join = try #require(tools.first { $0.id == "video.join" })
        #expect(join.multiInput == .combine(minimum: 2))
        #expect(tools.first { $0.id == "video.compress" }?.multiInput == .each)
        #expect(tools.first { $0.id == "media.metadata.strip" }?.accepts == [.video, .audio])
    }

    @Test func registryRoutesMediaJobs() {
        let registry = EngineRegistry(engines: [FFmpegEngine()])
        #expect(registry.supports(from: "mov", to: "gif"))
        let job = JobSpec(inputs: [URL(fileURLWithPath: "/tmp/x.mkv")], operation: .convert(to: "mp4"))
        #expect(registry.engine(for: job)?.id == "media")
        let tools = registry.tools(for: [URL(fileURLWithPath: "/tmp/a.mp4"), URL(fileURLWithPath: "/tmp/b.mov")])
        #expect(tools.contains { $0.id == "video.join" })
        #expect(!registry.tools(for: [URL(fileURLWithPath: "/tmp/a.mp4")]).contains { $0.id == "video.join" })
    }

    @Test func missingFFmpegDisablesEverything() async throws {
        var locator = ToolLocator(overrides: [:], bundleBin: nil)
        locator.searchDirectories = []
        let engine = FFmpegEngine(tools: locator)
        #expect(engine.conversions().isEmpty)
        #expect(engine.tools().isEmpty)
        let box = try Sandbox(); defer { box.cleanup() }
        let input = try await Fixtures.shared.url("tone.wav")
        await #expect(throws: EngineError.missingTool("ffmpeg")) {
            try await box.run(JobSpec(inputs: [input], operation: .convert(to: "mp3")), engine: engine, tools: locator)
        }
    }
}

@Suite struct HelperTests {
    @Test func parsesEncoderList() {
        let sample = """
        Encoders:
         V..... = Video
         ------
         V....D libx264              libx264 H.264 / AVC
         V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
         A....D aac                  AAC (Advanced Audio Coding)
         A..X.D vorbis               Vorbis
        """
        #expect(EncoderProbe.parse(sample) == ["libx264", "h264_videotoolbox", "aac", "vorbis"])
    }

    @Test func realEncoderProbeHasBasics() async throws {
        let ffmpeg = try ToolLocator().require("ffmpeg")
        let set = await EncoderProbe.encoders(ffmpeg: ffmpeg)
        #expect(set.contains("aac") && set.contains("flac") && set.contains("png"))
        #expect(EncoderProbe.encodersBlocking(ffmpeg: ffmpeg) == set)
    }

    @Test func rangesNormalizeMergeAndClamp() {
        let r = TimeRanges.normalize([1.5...3, -1...0.5, 0.4...1, 2.9...2.92], duration: 2.5)
        #expect(r == [0...1, 1.5...2.5])
        #expect(TimeRanges.totalLength(r) == 2)
        #expect(TimeRanges.equalParts(4, duration: 2) == [0...0.5, 0.5...1, 1...1.5, 1.5...2])
        #expect(TimeRanges.betweenExpr([0...1]) == "between(t,0.000,1.000)")
    }

    @Test func atempoChainsStayInRange() {
        #expect(TimeRanges.atempoChain(4) == ["atempo=2.0", "atempo=2.000000"])
        #expect(TimeRanges.atempoChain(0.25) == ["atempo=0.5", "atempo=0.500000"])
        #expect(TimeRanges.atempoChain(1.5) == ["atempo=1.500000"])
        #expect(TimeRanges.atempoChain(8).count == 3)
    }

    @Test func planOrderCopyThenHardwareThenSoftware() throws {
        let json = """
        {"streams":[{"index":0,"codec_type":"video","codec_name":"vp9","width":160,"height":120},
                    {"index":1,"codec_type":"audio","codec_name":"aac","channels":2}],"format":{"duration":"2"}}
        """
        let info = try MediaInfo.parse(json: Data(json.utf8), fileSize: 1000)
        let mp4 = try #require(VideoContainer.forFormat("mp4"))
        let all = EncoderSet(["h264_videotoolbox", "libx264", "aac"])
        let plans = try mp4.plans(info: info, encoders: all, allowVideoCopy: true, allowAudioCopy: true)
        #expect(plans == [
            StreamPlan(video: .encode(.h264VT, .auto), audio: .copy),
            StreamPlan(video: .encode(.h264VT, .auto), audio: .encode(.aac, bitrate: nil)),
            StreamPlan(video: .encode(.x264, .auto), audio: .encode(.aac, bitrate: nil)),
        ])
        let swOnly = try mp4.plans(info: info, encoders: EncoderSet(["libx264", "aac"]), allowVideoCopy: false, allowAudioCopy: false)
        #expect(swOnly == [StreamPlan(video: .encode(.x264, .auto), audio: .encode(.aac, bitrate: nil))])
        #expect(throws: EngineError.self) {
            try mp4.plans(info: info, encoders: EncoderSet(["aac"]), allowVideoCopy: true, allowAudioCopy: true)
        }
        let mkv = try #require(VideoContainer.forFormat("mkv"))
        #expect(try mkv.plans(info: info, encoders: all, allowVideoCopy: true, allowAudioCopy: true).first
                == StreamPlan(video: .copy, audio: .copy))
    }

    @Test func oggPrefersVorbisButCompressionNeedsBitrateControl() {
        let ogg = AudioTarget.forFormat("ogg")!
        let enc = EncoderSet(["vorbis", "libopus"])
        #expect(ogg.encoder(enc, source: nil) == .vorbisNative)
        #expect(ogg.encoder(enc, source: nil, needsBitrateControl: true) == .libopus)
        #expect(AudioEncoder.vorbisNative.args(bitrate: nil, source: nil) == ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"])
    }

    @Test func parsesLoudnormBlock() throws {
        let stderr = """
        [Parsed_loudnorm_0 @ 0x7f]
        {
        \t"input_i" : "-21.75",
        \t"input_tp" : "-18.06",
        \t"input_lra" : "0.00",
        \t"input_thresh" : "-31.75",
        \t"target_offset" : "0.05"
        }
        [out#0/null @ 0x7f] video:0KiB audio:750KiB
        """
        let m = try FFmpegEngine.parseLoudnorm(stderr)
        #expect(m["input_i"] == "-21.75")
        #expect(m["target_offset"] == "0.05")
    }

    @Test func progressSinkIsMonotonicAndSlices() {
        let rec = ProgressRecorder()
        let sink = ProgressSink { rec.add($0) }
        let root = sink.root
        sink.send(0)
        let parts = root.split([1, 3])
        parts[0](0.5)    // 0.125
        parts[0](0.2)    // ignored (backwards)
        parts[1](0.5)    // 0.25 + 0.375
        root(2)          // clamped to 1
        root(0.9)        // ignored
        #expect(rec.values == [0, 0.125, 0.625, 1])
    }

    @Test func mediaInfoParsesRotationAndRates() throws {
        let json = """
        {"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":1920,"height":1080,
          "avg_frame_rate":"30000/1001","side_data_list":[{"rotation":-90}],"disposition":{"attached_pic":0}},
          {"index":1,"codec_type":"audio","codec_name":"aac","sample_rate":"48000","channels":2,"bit_rate":"128000"}],
         "format":{"duration":"10.5","bit_rate":"5000000","format_name":"mov,mp4"}}
        """
        let info = try MediaInfo.parse(json: Data(json.utf8), fileSize: 0)
        #expect(info.duration == 10.5)
        #expect(info.displaySize?.width == 1080 && info.displaySize?.height == 1920)
        #expect(abs(info.frameRate - 29.97) < 0.01)
        #expect(info.videoBitRate == 5_000_000 - 128_000)
        #expect(info.audio?.sampleRate == 48_000)
    }
}
