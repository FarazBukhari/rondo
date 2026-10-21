import AppKit
import Foundation
import RondoKit
import SwiftUI
import Testing
@testable import MediaEditorUI

/// Renders editor states to PNG under fixtures/out/W7/render/ (light + dark) for a visual check.
@Suite(.serialized) @MainActor struct RenderTests {
    init() { _ = NSApplication.shared }

    static func png(_ model: MediaEditorModel, size: CGSize, appearance: NSAppearance.Name) throws -> Data {
        let view = NSHostingView(rootView: MediaEditorView(model: model))
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        // No run-loop spinning: it would hold the (shared) main actor and stall other suites' tests.
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        window.contentView = nil
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Loads real frames/waveform for `name` via the preview generator, without starting playback.
    static func model(_ name: String, panel: EditorPanel, isVideo: Bool, still at: Double?) async throws -> MediaEditorModel {
        let url = try await W7Fixtures.shared.url(name)
        let tools = ToolLocator()
        let details = try await MediaDetails.probe(url, tools: tools)
        let work = try TempDir.make(prefix: "w7-render")
        defer { TempDir.remove(work) }
        let gen = PreviewGenerator(source: url, workDir: work, tools: tools)
        var frames: [NSImage] = []
        var levels: [Float] = []
        var still: NSImage?
        if isVideo {
            // Same AVFoundation path the editor uses for native formats (no ffmpeg process per frame).
            var indexed: [(Int, NSImage)] = []
            let times = PreviewGenerator.thumbnailTimes(count: MediaEditorModel.filmstripCount, duration: details.duration)
            await PreviewGenerator.avFrames(url: url, times: times, height: 108) { i, image in indexed.append((i, image)) }
            frames = indexed.sorted { $0.0 < $1.0 }.map(\.1)
            if let at, let f = try await gen.frame(at: at, height: 720, name: "still.png"), let d = try? Data(contentsOf: f) {
                still = NSImage(data: d)
            }
        } else {
            levels = try await gen.waveform(duration: details.duration, sampleRate: details.sampleRate, buckets: MediaEditorModel.waveformBuckets)
        }
        let model = MediaEditorModel(url: url, panel: panel, isVideo: isVideo, tools: tools)
        model.loadForPreview(details: details, filmstrip: frames, waveform: levels, still: still)
        if let at { model.setPlayheadForPreview(at) }
        return model
    }

    static let videoSize = CGSize(width: 920, height: 680)
    static let audioSize = CGSize(width: 840, height: 440)

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func rendersEditorStates() async throws {
        let out = try W7Fixtures.outDir("render")
        var cases: [(String, MediaEditorModel, CGSize)] = []

        let trim = try await Self.model("clip.mp4", panel: .trim, isVideo: true, still: 1.2)
        trim.draft.keep.reset(to: [0.4...1.6, 2.0...2.8])
        trim.selectedRange = 0
        cases.append(("video-trim", trim, Self.videoSize))

        let crop = try await Self.model("clip.mp4", panel: .crop, isVideo: true, still: 0.8)
        crop.draft.crop = CGRect(x: 60, y: 24, width: 176, height: 132)
        crop.draft.aspect = .fourThree
        cases.append(("video-crop", crop, Self.videoSize))

        let portrait = try await Self.model("rotated.mp4", panel: .crop, isVideo: true, still: 1.0)
        portrait.draft.setAspect(.square)
        cases.append(("video-crop-rotated", portrait, Self.videoSize))

        let split = try await Self.model("clip.mp4", panel: .split, isVideo: true, still: 2.2)
        split.draft.markers.add(1.0)
        split.draft.markers.add(2.2)
        split.selectedMarker = 1
        cases.append(("video-split", split, Self.videoSize))

        let snapshot = try await Self.model("clip.mp4", panel: .snapshot, isVideo: true, still: 1.5)
        cases.append(("video-snapshot", snapshot, Self.videoSize))

        let speed = try await Self.model("clip.mp4", panel: .speed, isVideo: true, still: 0.5)
        speed.draft.speed = 1.5
        cases.append(("video-speed", speed, Self.videoSize))

        let bleep = try await Self.model("step.wav", panel: .bleep, isVideo: false, still: nil)
        bleep.draft.bleeps.reset(to: [1.2...1.6, 2.2...2.5])
        bleep.selectedRange = 1
        bleep.setPlayheadForPreview(2.3)
        cases.append(("audio-bleep", bleep, Self.audioSize))

        let audioTrim = try await Self.model("step.wav", panel: .trim, isVideo: false, still: nil)
        audioTrim.draft.keep.reset(to: [0.8...2.6])
        audioTrim.selectedRange = 0
        audioTrim.setPlayheadForPreview(1.4)
        cases.append(("audio-trim", audioTrim, Self.audioSize))

        for (name, model, size) in cases {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let data = try Self.png(model, size: size, appearance: appearance)
                #expect(data.count > 20_000, "\(name)-\(suffix) looks blank (\(data.count) bytes)")
                try data.write(to: out.appendingPathComponent("\(name)-\(suffix).png"))
            }
            model.shutdown()
        }
    }
}
