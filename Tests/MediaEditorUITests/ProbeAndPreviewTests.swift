import AppKit
import AVFoundation
import Foundation
import RondoKit
import Testing
@testable import MediaEditorUI

@Suite struct ProbeParseTests {
    @Test func parsesRotationSideDataAndIgnoresCoverArt() throws {
        let json = """
        {"streams":[
          {"index":0,"codec_type":"video","width":600,"height":600,"disposition":{"attached_pic":1}},
          {"index":1,"codec_type":"video","width":1920,"height":1080,"avg_frame_rate":"30000/1001",
           "side_data_list":[{"side_data_type":"Display Matrix","rotation":-90}],"disposition":{"attached_pic":0}},
          {"index":2,"codec_type":"audio","sample_rate":"48000","channels":2}
        ],"format":{"duration":"12.500000"}}
        """
        let d = try MediaDetails.parse(ffprobeJSON: Data(json.utf8))
        #expect(d.duration == 12.5)
        #expect(d.naturalSize == CGSize(width: 1920, height: 1080))
        #expect(d.rotation == 270)
        #expect(d.displaySize == CGSize(width: 1080, height: 1920))
        #expect(abs((d.frameRate ?? 0) - 29.97) < 0.01)
        #expect(d.hasAudio && d.sampleRate == 48000)
    }

    @Test func parsesRotateTagAudioOnlyAndStreamDuration() throws {
        let tagged = """
        {"streams":[{"codec_type":"video","width":640,"height":480,"tags":{"rotate":"90"},"r_frame_rate":"25/1"}],
         "format":{"duration":"N/A"}}
        """
        let v = try MediaDetails.parse(ffprobeJSON: Data(tagged.utf8))
        #expect(v.displaySize == CGSize(width: 480, height: 640))
        #expect(v.frameRate == 25)
        #expect(!v.hasAudio)
        #expect(v.duration == 0)

        let audio = """
        {"streams":[{"codec_type":"audio","sample_rate":"44100","duration":"3.25"},
                    {"codec_type":"video","width":500,"height":500,"disposition":{"attached_pic":1}}],"format":{}}
        """
        let a = try MediaDetails.parse(ffprobeJSON: Data(audio.utf8))
        #expect(!a.hasVideo && a.hasAudio)
        #expect(a.duration == 3.25)
        #expect(a.sampleRate == 44100)
        #expect(throws: (any Error).self) { try MediaDetails.parse(ffprobeJSON: Data("[]".utf8)) }
    }

    @Test func peakLevelParsing() {
        let lines = ["frame:0    pts:0       pts_time:0", "lavfi.astats.Overall.Peak_level=-6.000000",
                     "frame:1 pts:160", "lavfi.astats.Overall.Peak_level=-inf", "lavfi.astats.Overall.Peak_level=0.0",
                     "lavfi.astats.Overall.Peak_level=-90"]
        let levels = PreviewGenerator.parsePeakLevels(lines)
        #expect(levels.count == 4)
        #expect(abs(levels[0] - 0.9) < 1e-6)
        #expect(levels[1] == 0 && levels[2] == 1 && levels[3] == 0)
        #expect(PreviewGenerator.resample([0.1, 0.9, 0.2, 0.3], to: 2) == [0.9, 0.3])
        #expect(PreviewGenerator.resample([0.5], to: 3) == [0.5, 0.5, 0.5])
        #expect(PreviewGenerator.resample([], to: 3).isEmpty)
        #expect(PreviewGenerator.thumbnailTimes(count: 4, duration: 2) == [0.25, 0.75, 1.25, 1.75])
    }
}

@Suite(.serialized) struct MediaIntegrationTests {
    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func probesRealFilesIncludingRotation() async throws {
        let tools = ToolLocator()
        let clip = try await MediaDetails.probe(try await W7Fixtures.shared.url("clip.mp4"), tools: tools)
        #expect(abs(clip.duration - 3) < 0.1)
        #expect(clip.displaySize == CGSize(width: 320, height: 180))
        #expect(clip.hasAudio && clip.frameRate == 25)

        let rotated = try await MediaDetails.probe(try await W7Fixtures.shared.url("rotated.mp4"), tools: tools)
        #expect(rotated.naturalSize == CGSize(width: 320, height: 180))
        #expect(rotated.rotation == 90 || rotated.rotation == 270)
        #expect(rotated.displaySize == CGSize(width: 180, height: 320))

        // AVFoundation agrees on the displayed size (track preferredTransform).
        let av = try await MediaDetails.probeAV(try await W7Fixtures.shared.url("rotated.mp4"))
        #expect(av.displaySize == CGSize(width: 180, height: 320))

        let wav = try await MediaDetails.probe(try await W7Fixtures.shared.url("step.wav"), tools: tools)
        #expect(!wav.hasVideo && wav.hasAudio && wav.sampleRate == 44100)

        await #expect(throws: (any Error).self) {
            _ = try await MediaDetails.probe(W7Fixtures.packageRoot.appendingPathComponent("Package.swift"), tools: tools)
        }
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func generatesFramesWaveformAndProxy() async throws {
        let work = try TempDir.make(prefix: "w7-test")
        defer { TempDir.remove(work) }
        let tools = ToolLocator()

        // Rotated clip: thumbnails come out portrait (ffmpeg autorotates, like the engine).
        let gen = PreviewGenerator(source: try await W7Fixtures.shared.url("rotated.mp4"), workDir: work, tools: tools)
        let frame = try #require(try await gen.frame(at: 1, height: 80, name: "f.png"))
        let image = try #require(NSImage(contentsOf: frame))
        let rep = try #require(image.representations.first)
        #expect(rep.pixelsHigh == 80 && (rep.pixelsWide == 44 || rep.pixelsWide == 46), "\(rep.pixelsWide)×\(rep.pixelsHigh)")
        // Past the end → no frame, no throw.
        #expect(try await gen.frame(at: 999, height: 80, name: "none.png") == nil)

        // AVFoundation filmstrip path agrees on orientation and reports every index once.
        let avImages = await avFrames(try await W7Fixtures.shared.url("rotated.mp4"), times: [0.5, 1, 1.5, 2])
        #expect(avImages.map(\.0).sorted() == [0, 1, 2, 3])
        #expect(avImages.allSatisfy { $0.1.size.height == 80 && $0.1.size.width == 45 })

        // Waveform: quiet first second, loud after.
        let wave = PreviewGenerator(source: try await W7Fixtures.shared.url("step.wav"), workDir: work, tools: tools)
        let levels = try await wave.waveform(duration: 3, sampleRate: 44100, buckets: 300)
        #expect(abs(levels.count - 300) <= 2)
        let quiet = levels.prefix(80).max() ?? 1
        let loud = levels.suffix(150).min() ?? 0
        #expect(quiet < 0.3 && loud > 0.6 && loud - quiet > 0.4, "quiet \(quiet) loud \(loud)")

        // Proxies: MKV video → playable MP4; Ogg/Opus → playable M4A.
        #expect(await PreviewGenerator.canPlayNatively(try await W7Fixtures.shared.url("clip.mp4"), needsVideo: true))
        let mkv = try await W7Fixtures.shared.url("clip.mkv")
        #expect(!(await PreviewGenerator.canPlayNatively(mkv, needsVideo: true)))
        let progress = LineCollector()
        let proxy = try await PreviewGenerator(source: mkv, workDir: work, tools: tools)
            .proxy(hasVideo: true, hasAudio: true, duration: 3) { progress.append(String($0)) }
        #expect(proxy.deletingLastPathComponent().standardizedFileURL == work.standardizedFileURL)
        #expect(await PreviewGenerator.canPlayNatively(proxy, needsVideo: true))
        #expect(progress.lines.last == "1.0")
        let proxied = try await MediaDetails.probe(proxy, tools: tools)
        #expect(abs(proxied.duration - 3) < 0.15)

        let ogg = try await W7Fixtures.shared.url("tone.ogg")
        let audioProxy = try await PreviewGenerator(source: ogg, workDir: work, tools: tools)
            .proxy(hasVideo: false, hasAudio: true, duration: 3) { _ in }
        #expect(audioProxy.pathExtension == "m4a")
        #expect(await PreviewGenerator.canPlayNatively(audioProxy, needsVideo: false))
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func proxyGenerationIsCancellable() async throws {
        let work = try TempDir.make(prefix: "w7-cancel")
        defer { TempDir.remove(work) }
        let gen = PreviewGenerator(source: try await W7Fixtures.shared.url("long.mkv"), workDir: work, tools: ToolLocator())
        let task = Task { try await gen.proxy(hasVideo: true, hasAudio: false, duration: 30) { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        task.cancel()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 60)   // generous: full-suite runs saturate the CPU
        if case .success = result { Issue.record("proxy finished before it could be cancelled") }
        if case .failure(let e) = result { #expect(e is CancellationError) }
    }
}

@MainActor
private func avFrames(_ url: URL, times: [Double]) async -> [(Int, NSImage)] {
    var out: [(Int, NSImage)] = []
    await PreviewGenerator.avFrames(url: url, times: times, height: 80) { i, image in out.append((i, image)) }
    return out
}
