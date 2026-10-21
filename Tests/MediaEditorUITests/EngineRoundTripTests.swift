import Foundation
import MediaEngine
import RondoKit
import Testing
@testable import MediaEditorUI

/// Editor drafts → option dictionaries → the real FFmpegEngine on generated fixtures.
/// Outputs land in fixtures/out/W7/engine/<case>/ (cleared at the start of each case).
@Suite(.serialized) struct EngineRoundTripTests {
    let tools = ToolLocator()

    private func run(_ panel: EditorPanel, on name: String, case label: String,
                     edit: (inout EditorDraft) -> Void, playhead: Double = 0) async throws -> (outputs: [URL], options: [String: OptionValue]) {
        let input = try await W7Fixtures.shared.url(name)
        let details = try await MediaDetails.probe(input, tools: tools)
        let isVideo = details.hasVideo
        var draft = EditorDraft(isVideo: isVideo, duration: details.duration, videoSize: details.displaySize,
                                frameRate: details.frameRate ?? 30)
        edit(&draft)
        #expect(draft.problem(for: panel) == nil)
        let options = draft.options(for: panel, playhead: playhead)
        let out = try W7Fixtures.outDir("engine/\(label)")
        for f in (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
        let temp = try TempDir.make(prefix: "w7-engine")
        defer { TempDir.remove(temp) }
        let job = JobSpec(inputs: [input], operation: .tool(panel.toolID(isVideo: isVideo)), options: options, destination: .folder(out))
        let outputs = try await FFmpegEngine(tools: tools).run(job, context: JobContext(tools: tools, tempDir: temp, destination: .folder(out)))
        #expect(!outputs.isEmpty)
        for o in outputs { #expect(o.path.hasPrefix(out.path)) }
        return (outputs, options)
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func trimKeepsTheChosenSections() async throws {
        let (outs, _) = try await run(.trim, on: "clip.mp4", case: "trim") { d in
            d.keep.setLowerBound(of: 0, to: 0.5)
            d.keep.setUpperBound(of: 0, to: 1.5)
            d.keep.add(2.2...2.7)
        }
        let info = try await MediaDetails.probe(outs[0], tools: tools)
        #expect(abs(info.duration - 1.5) < 0.15, "duration \(info.duration)")
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func splitMarkersMakeOneFilePerPart() async throws {
        let (outs, options) = try await run(.split, on: "clip.mp4", case: "split") { d in
            d.markers.add(1)
            d.markers.add(2)
            d.precise = true
        }
        #expect(options["ranges"] == .ranges([0...1, 1...2, 2...3]))
        let folder = try #require(outs.first)
        let parts = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".mp4") }.sorted()
        #expect(parts.count == 3, "\(parts)")
        for p in parts {
            let info = try await MediaDetails.probe(folder.appendingPathComponent(p), tools: tools)
            #expect(abs(info.duration - 1) < 0.15, "\(p) \(info.duration)")
        }
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func cropOnARotatedClipUsesDisplayedPixels() async throws {
        // rotated.mp4 is 320×180 coded, shown as 180×320. Crop the top half of what the user sees.
        let (outs, options) = try await run(.crop, on: "rotated.mp4", case: "crop-rotated") { d in
            #expect(d.videoSize == CGSize(width: 180, height: 320))
            let frame = CropGeometry.aspectFit(d.videoSize!, in: CGRect(x: 0, y: 0, width: 900, height: 500))
            let topHalfInView = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
            d.crop = CropGeometry.viewToVideo(topHalfInView, frame: frame, videoSize: d.videoSize!)
        }
        #expect(options["rect"] == .list([0, 0, 180, 160]))
        let info = try await MediaDetails.probe(outs[0], tools: tools)
        #expect(info.displaySize == CGSize(width: 180, height: 160), "\(String(describing: info.displaySize))")
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func cropWithAspectPreset() async throws {
        let (outs, _) = try await run(.crop, on: "clip.mp4", case: "crop-square") { d in
            d.setAspect(.square)
        }
        let info = try await MediaDetails.probe(outs[0], tools: tools)
        #expect(info.displaySize == CGSize(width: 180, height: 180))
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func snapshotSpeedAndAudioTools() async throws {
        let (shot, shotOptions) = try await run(.snapshot, on: "clip.mp4", case: "snapshot", edit: { _ in }, playhead: 99)
        #expect(shot[0].pathExtension == "png")
        guard case .double(let t)? = shotOptions["time"] else { Issue.record("no time"); return }
        #expect(t < 3 && t > 2.9)

        let (fast, _) = try await run(.speed, on: "clip.mp4", case: "speed") { d in d.speed = 2 }
        let fastInfo = try await MediaDetails.probe(fast[0], tools: tools)
        #expect(abs(fastInfo.duration - 1.5) < 0.15)

        let (trimmed, trimOptions) = try await run(.trim, on: "step.wav", case: "audio-trim") { d in
            d.keep.setUpperBound(of: 0, to: 1)
        }
        #expect(trimOptions["precise"] == nil)
        let trimmedInfo = try await MediaDetails.probe(trimmed[0], tools: tools)
        #expect(abs(trimmedInfo.duration - 1) < 0.05)

        let (bleeped, _) = try await run(.bleep, on: "step.wav", case: "audio-bleep") { d in
            d.bleeps.add(1.5...2)
            d.frequency = 800
        }
        let bleepInfo = try await MediaDetails.probe(bleeped[0], tools: tools)
        #expect(abs(bleepInfo.duration - 3) < 0.05)
    }
}
