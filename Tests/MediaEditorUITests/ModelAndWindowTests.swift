import AppKit
import Foundation
import RondoKit
import Testing
@testable import MediaEditorUI

/// Records submit calls.
@MainActor
final class SubmitRecorder {
    var calls: [([URL], ToolID, [String: OptionValue])] = []
    var handler: ([URL], ToolID, [String: OptionValue]) -> Void {
        { [weak self] inputs, tool, options in self?.calls.append((inputs, tool, options)) }
    }
}

/// True if any process still has `path` on its command line.
func processMentioning(_ path: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}

@Suite(.serialized) @MainActor struct ModelLifecycleTests {
    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func loadsPreviewsAndSubmitsExactlyOnce() async throws {
        let url = try await W7Fixtures.shared.url("clip.mp4")
        let model = MediaEditorModel(url: url, panel: .trim, isVideo: true, tools: ToolLocator())
        let recorder = SubmitRecorder()
        var closes = 0
        model.submitHandler = recorder.handler
        model.closeHandler = { closes += 1 }
        model.start()
        #expect(await waitUntil { model.load == .ready })
        #expect(abs(model.draft.duration - 3) < 0.1)
        #expect(model.draft.videoSize == CGSize(width: 320, height: 180))
        #expect(await waitUntil { model.player != nil }, "no player")
        #expect(model.preview == .native)
        #expect(await waitUntil { !model.filmstrip.isEmpty }, "no filmstrip frames")
        #expect(await waitUntil { model.filmstrip.count == MediaEditorModel.filmstripCount },
                "filmstrip \(model.filmstrip.count)/\(MediaEditorModel.filmstripCount)")
        #expect(Set(model.filmstrip.map(\.id)) == Set(0..<MediaEditorModel.filmstripCount))
        let work = try #require(model.workDir)
        #expect(FileManager.default.fileExists(atPath: work.path))

        // Whole clip kept → nothing to do yet.
        #expect(!model.canSubmit)
        model.submit()
        #expect(recorder.calls.isEmpty)

        model.seek(to: 0.5)
        model.setInPoint()
        model.seek(to: 2)
        model.setOutPoint()
        #expect(model.canSubmit)
        model.submit()
        model.submit()
        #expect(recorder.calls.count == 1)
        #expect(closes == 1)
        let call = try #require(recorder.calls.first)
        #expect(call.0 == [url])
        #expect(call.1 == "video.trim")
        #expect(call.2 == ["ranges": .ranges([0.5...2]), "precise": .bool(true)])

        model.shutdown()
        await model.waitForCleanup()
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(model.player == nil)
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func closingWhileTheProxyBuildsKillsFFmpegAndCleansUp() async throws {
        let url = try await W7Fixtures.shared.url("long.mkv")
        let model = MediaEditorModel(url: url, panel: .split, isVideo: true, tools: ToolLocator())
        let recorder = SubmitRecorder()
        model.submitHandler = recorder.handler
        model.start()
        #expect(await waitUntil {
            if case .preparing = model.preview { return true }
            return false
        })
        let work = try #require(model.workDir)
        let started = Date()
        model.shutdown()
        await model.waitForCleanup()
        #expect(Date().timeIntervalSince(started) < 60)   // SIGTERM → exit; generous for a loaded machine
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(!processMentioning(work.path))
        #expect(model.preview != .proxy)
        #expect(recorder.calls.isEmpty)
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func shutdownWaitsForSupersededStillFrames() async throws {
        let model = MediaEditorModel(url: try await W7Fixtures.shared.url("long.mkv"), panel: .snapshot, isVideo: true, tools: ToolLocator())
        model.start()
        #expect(await waitUntil {
            if case .preparing = model.preview { return true } else { return false }
        })
        let work = try #require(model.workDir)
        // Each seek supersedes the previous still frame; give each time to reach ffmpeg.
        for t in [3.0, 9.0, 21.0] {
            model.seek(to: t)
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        model.shutdown()
        await model.waitForCleanup()
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(!processMentioning(work.path))
        try await Task.sleep(nanoseconds: 300_000_000)   // nothing writes into it afterwards
        #expect(!FileManager.default.fileExists(atPath: work.path))
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func audioEditorBuildsWaveformAndBleepOptions() async throws {
        let url = try await W7Fixtures.shared.url("step.wav")
        let model = MediaEditorModel(url: url, panel: .bleep, isVideo: false, tools: ToolLocator())
        let recorder = SubmitRecorder()
        model.submitHandler = recorder.handler
        model.start()
        #expect(await waitUntil { model.load == .ready && !model.waveform.isEmpty })
        #expect(model.draft.videoSize == nil)
        #expect(model.problem == "Mark at least one section to bleep.")
        model.seek(to: 1.25)
        model.addRange()
        #expect(model.selectedRange == 0)
        model.draft.tone = false
        model.submit()
        let call = try #require(recorder.calls.first)
        #expect(call.1 == "audio.bleep")
        #expect(call.2["ranges"] == .ranges([1.25...1.75]))
        #expect(call.2["tone"] == .bool(false))
        model.shutdown()
        await model.waitForCleanup()
    }

    @Test func unreadableFileFailsWithoutSubmitting() async throws {
        let url = W7Fixtures.packageRoot.appendingPathComponent("Package.swift")
        let model = MediaEditorModel(url: url, panel: .trim, isVideo: true, tools: ToolLocator())
        model.start()
        #expect(await waitUntil {
            if case .failed = model.load { return true }
            return false
        })
        #expect(!model.canSubmit)
        model.shutdown()
        await model.waitForCleanup()
    }

    @Test func panelEditsOnALoadedModel() {
        let model = MediaEditorModel(url: URL(fileURLWithPath: "/tmp/x.mp4"), panel: .split, isVideo: true)
        model.loadForPreview(details: MediaDetails(duration: 10, naturalSize: CGSize(width: 640, height: 360), frameRate: 25, hasAudio: true))
        model.seek(to: 4)
        model.addMarker()
        model.seek(to: 4.05)   // too close to the first marker
        model.addMarker()
        #expect(model.draft.markers.times == [4])
        model.equalParts = 4
        model.applyEqualParts()
        #expect(model.draft.markers.parts.count == 4)
        model.seek(to: 5.1)
        model.removeMarker()   // nearest (5.0) within tolerance
        #expect(model.draft.markers.times == [2.5, 7.5])
        #expect(model.options == ["ranges": .ranges([0...2.5, 2.5...7.5, 7.5...10]), "precise": .bool(true)])

        model.panel = .trim
        model.seek(to: 5)
        model.removeSection()          // cut ~1 s around the playhead
        #expect(model.draft.keep.count == 2)
        #expect(model.toolID == "video.trim")

        model.panel = .snapshot
        model.step(frames: 3)
        #expect(abs(model.currentTime - 5.12) < 1e-9)
        model.seek(to: 99)
        guard case .double(let snapTime)? = model.options["time"] else { Issue.record("no time"); return }
        #expect(abs(snapTime - 9.95) < 1e-9)

        model.panel = .speed
        model.draft.speed = 0.5
        #expect(model.toolID == "video.speed")
        #expect(model.options == ["speed": .double(0.5)])
        #expect(model.statusText.contains("0:20.00"))
        model.shutdown()
    }
}

@Suite @MainActor struct KeyboardTests {
    @Test func mapsKeyEvents() {
        #expect(EditorKey.from(keyCode: 49, characters: " ", modifiers: []) == .space)
        #expect(EditorKey.from(keyCode: 123, characters: nil, modifiers: [.shift]) == .shiftLeft)
        #expect(EditorKey.from(keyCode: 124, characters: nil, modifiers: [.numericPad, .function]) == .right)
        #expect(EditorKey.from(keyCode: 34, characters: "I", modifiers: []) == .character("i"))
        #expect(EditorKey.from(keyCode: 51, characters: nil, modifiers: []) == .delete)
        #expect(EditorKey.from(keyCode: 13, characters: "w", modifiers: [.command]) == nil)   // ⌘W stays a menu shortcut
        #expect(EditorKey.from(keyCode: 18, characters: "1", modifiers: []) == nil)
    }

    @Test func keysDriveThePanels() {
        let model = MediaEditorModel(url: URL(fileURLWithPath: "/tmp/k.mp4"), panel: .trim, isVideo: true)
        #expect(!model.handle(.right))   // not loaded yet
        model.loadForPreview(details: MediaDetails(duration: 4, naturalSize: CGSize(width: 320, height: 180), frameRate: 25, hasAudio: false))
        #expect(!model.handle(.space))   // no player → not consumed
        #expect(model.handle(.shiftRight))
        #expect(model.handle(.character("i")))
        #expect(model.handle(.right))
        #expect(model.handle(.shiftRight))
        #expect(model.handle(.character("o")))
        #expect(model.draft.keep.ranges == [1...2.04])
        #expect(!model.handle(.character("m")))   // marker key only on Split
        model.panel = .split
        #expect(model.handle(.character("m")))
        #expect(model.draft.markers.times == [2.04])
        #expect(model.handle(.delete))
        #expect(model.draft.markers.isEmpty)
        #expect(model.handle(.end) && model.currentTime == 4)
        #expect(model.handle(.home) && model.currentTime == 0)
        model.shutdown()
    }
}

@Suite(.serialized) @MainActor struct WindowTests {
    init() {
        _ = NSApplication.shared
        MediaEditor.presentsWindows = false
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func reopenFocusesSameWindowAndEscapeClosesWithoutSubmitting() async throws {
        let url = try await W7Fixtures.shared.url("clip.mp4")
        let recorder = SubmitRecorder()
        MediaEditor.open(url: url, tool: "video.crop", tools: ToolLocator(), submit: recorder.handler)
        let controller = try #require(MediaEditor.controller(for: url))
        #expect(controller.model.panel == .crop)
        #expect(controller.window.title == "clip.mp4")

        MediaEditor.open(url: url, tool: "video.trim", tools: ToolLocator(), submit: recorder.handler)
        #expect(MediaEditor.controller(for: url) === controller)
        #expect(controller.model.panel == .trim)
        // An audio tool can't switch a video editor's panel.
        MediaEditor.open(url: url, tool: "audio.bleep", tools: ToolLocator(), submit: recorder.handler)
        #expect(controller.model.panel == .trim)

        #expect(await waitUntil { controller.model.load == .ready })
        controller.window.cancelOperation(nil)   // Escape
        #expect(MediaEditor.controller(for: url) == nil)
        #expect(controller.model.isShutDown)
        #expect(recorder.calls.isEmpty)
        await controller.model.waitForCleanup()
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func applyClosesTheWindowAfterOneSubmit() async throws {
        let url = try await W7Fixtures.shared.url("clip.mp4")
        let recorder = SubmitRecorder()
        MediaEditor.open(url: url, tool: "video.snapshot", tools: ToolLocator(), submit: recorder.handler)
        let controller = try #require(MediaEditor.controller(for: url))
        #expect(await waitUntil { controller.model.load == .ready })
        #expect(abs(controller.model.currentTime - 1.5) < 0.1)   // snapshot starts mid-clip
        controller.model.submit()
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.1 == "video.snapshot")
        #expect(MediaEditor.controller(for: url) == nil)
        #expect(controller.model.isShutDown)
        await controller.model.waitForCleanup()
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func closeAllAndWaitKillsPreviewWorkAndRemovesScratchDirs() async throws {
        let urls = [try await W7Fixtures.shared.url("long.mkv"), try await W7Fixtures.shared.url("long-b.mkv")]
        let recorder = SubmitRecorder()
        MediaEditor.open(url: urls[0], tool: "video.trim", tools: ToolLocator(), submit: recorder.handler)
        MediaEditor.open(url: urls[1], tool: "video.crop", tools: ToolLocator(), submit: recorder.handler)
        let models = try urls.map { try #require(MediaEditor.controller(for: $0)).model }
        // Both are building playback proxies (MKV isn't AVFoundation-playable).
        #expect(await waitUntil {
            models.allSatisfy { if case .preparing = $0.preview { return true } else { return false } }
        })
        let dirs = try models.map { try #require($0.workDir) }
        // Scrub so superseded still-frame jobs are in flight as well.
        for m in models { m.seek(to: 5) }
        try await Task.sleep(nanoseconds: 200_000_000)
        for m in models { m.seek(to: 12) }

        await MediaEditor.closeAllAndWait(timeout: 120)   // generous: full-suite runs saturate the CPU
        #expect(MediaEditor.openControllers.isEmpty)
        let leftovers = Set((try? FileManager.default.contentsOfDirectory(atPath: TempDir.root.path)) ?? [])
        for d in dirs {
            #expect(!FileManager.default.fileExists(atPath: d.path), "\(d.lastPathComponent) survived")
            #expect(!leftovers.contains(d.lastPathComponent))
            #expect(!processMentioning(d.path), "ffmpeg still running for \(d.lastPathComponent)")
        }
        #expect(models.allSatisfy { $0.isShutDown && $0.preview != .proxy && $0.player == nil })
        #expect(recorder.calls.isEmpty)
        #expect(await waitUntil { MediaEditor.cleanupsInFlight == 0 })
    }

    @Test(.enabled(if: W7Fixtures.hasFFmpeg))
    func closeAllAndWaitTimeoutStillRemovesScratchDirs() async throws {
        let url = try await W7Fixtures.shared.url("long.mkv")
        MediaEditor.open(url: url, tool: "video.split", tools: ToolLocator(), submit: { _, _, _ in })
        let model = try #require(MediaEditor.controller(for: url)).model
        #expect(await waitUntil {
            if case .preparing = model.preview { return true } else { return false }
        })
        let dir = try #require(model.workDir)
        await MediaEditor.closeAllAndWait(timeout: 0)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        await model.waitForCleanup()
        #expect(!processMentioning(dir.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        // Nothing open → returns at once.
        await MediaEditor.closeAllAndWait()
    }

    @Test func cancelButtonPathAndUnknownToolDefaults() async throws {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist.m4a")
        let recorder = SubmitRecorder()
        MediaEditor.open(url: url, tool: "audio.normalize", tools: ToolLocator(), submit: recorder.handler)
        let controller = try #require(MediaEditor.controller(for: url))
        #expect(!controller.model.isVideo)
        #expect(controller.model.panel == .trim)
        controller.model.cancel()
        #expect(MediaEditor.controller(for: url) == nil)
        #expect(recorder.calls.isEmpty)
        await controller.model.waitForCleanup()
    }
}
