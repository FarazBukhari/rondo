import AppKit
import Foundation
import RondoKit
import SwiftUI
import Testing
@testable import ImageEditorUI

/// Polls `condition` on the main actor. Generous by default: in full-suite runs the main actor and the
/// thread pools are shared with many heavy suites. Re-checks once after the deadline, because the work we
/// wait for may have been queued behind this very wake-up.
@MainActor
func waitUntil(_ what: String, timeout: Double = 180, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            for _ in 0..<5 { await Task.yield() }
            try await Task.sleep(nanoseconds: 200_000_000)
            if condition() { return }
            throw EngineError.failed("timed out after \(Int(timeout)) s waiting for \(what)")
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
}

/// Public entry point + window lifecycle. Headless: windows are built but never ordered on screen.
@MainActor
@Suite(.serialized) struct WindowTests {
    typealias Call = (inputs: [URL], tool: ToolID, options: [String: OptionValue])

    init() {
        _ = NSApplication.shared
        ImageEditor.headless = true
    }

    static func fixture() throws -> URL {
        try W6.writePNG(W6.quadrants(64, 48), to: W6.dir("src").appendingPathComponent("window.png"))
    }

    @Test func saveSubmitsOnceThenCloses() async throws {
        let url = try Self.fixture()
        var calls: [Call] = []
        ImageEditor.open(url: url, tool: "image.crop") { calls.append(($0, $1, $2)) }
        defer { ImageEditor.closeAll() }
        let model = try #require(ImageEditor.model(for: url))
        let window = try #require(ImageEditor.window(for: url))
        #expect(window.title == "window.png")
        #expect(window.contentViewController is NSHostingController<ImageEditorView>)

        // Opening the same file again focuses the existing editor on the requested panel.
        ImageEditor.open(url: url, tool: "image.adjust") { calls.append(($0, $1, $2)) }
        #expect(ImageEditor.openURLs == [url.standardizedFileURL])
        #expect(model.panel == .adjust)

        try await waitUntil("image load") { model.loadState == .ready }
        #expect(model.sourceSize == CGSize(width: 64, height: 48))
        model.adjust.saturation = 0
        model.panel = .crop
        model.crop.rotateClockwise()
        #expect(model.canSave)
        model.save()   // saves the Crop panel only
        try await waitUntil("submit") { !calls.isEmpty }
        try await waitUntil("window close") { ImageEditor.openURLs.isEmpty }
        #expect(calls.count == 1)
        #expect(calls.first?.inputs == [url.standardizedFileURL])
        #expect(calls.first?.tool == "image.crop")
        #expect(calls.first?.options == ["rotation": .int(90), "flipH": .bool(false), "flipV": .bool(false)])
        #expect(ImageEditor.openURLs.isEmpty)
        model.save()
        #expect(calls.count == 1)
    }

    @Test func escapeCancelAndCloseNeverSubmit() async throws {
        let url = try Self.fixture()
        var calls: [Call] = []
        let submit: ImageEditor.Submit = { calls.append(($0, $1, $2)) }
        defer { ImageEditor.closeAll() }

        // Escape key in the window.
        ImageEditor.open(url: url, tool: "image.redact", submit: submit)
        var model = try #require(ImageEditor.model(for: url))
        try await waitUntil("image load") { model.loadState == .ready }
        model.redact.regions = [CGRect(x: 1, y: 1, width: 10, height: 10)]
        let window = try #require(ImageEditor.window(for: url))
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.keyDown(with: esc)
        #expect(model.finished && ImageEditor.openURLs.isEmpty)

        // cancelOperation (Esc / ⌘. routed by AppKit).
        ImageEditor.open(url: url, tool: "image.annotate", submit: submit)
        model = try #require(ImageEditor.model(for: url))
        try #require(ImageEditor.window(for: url)).cancelOperation(nil)
        #expect(model.finished && ImageEditor.openURLs.isEmpty)

        // Title-bar close mid-edit.
        ImageEditor.open(url: url, tool: "image.crop", submit: submit)
        model = try #require(ImageEditor.model(for: url))
        try await waitUntil("image load") { model.loadState == .ready }
        model.crop.rotateClockwise()
        try #require(ImageEditor.window(for: url)).close()
        #expect(model.finished && ImageEditor.openURLs.isEmpty)

        // Cancel button path.
        ImageEditor.open(url: url, tool: "image.background", submit: submit)
        model = try #require(ImageEditor.model(for: url))
        model.cancel()
        #expect(ImageEditor.openURLs.isEmpty)

        #expect(calls.isEmpty)
    }

    @Test func unreadableFileShowsErrorAndCanStillClose() async throws {
        let url = W6.dir("src").appendingPathComponent("not-an-image.png")
        try Data("nope".utf8).write(to: url)
        var calls = 0
        ImageEditor.open(url: url, tool: "image.crop") { _, _, _ in calls += 1 }
        let model = try #require(ImageEditor.model(for: url))
        try await waitUntil("load failure") { if case .failed = model.loadState { return true }; return false }
        #expect(!model.canSave)
        model.save()
        model.cancel()
        #expect(calls == 0 && ImageEditor.openURLs.isEmpty)
    }
}
