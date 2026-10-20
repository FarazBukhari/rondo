import AppKit
import Carbon.HIToolbox
import Foundation
import RondoKit
import Testing
@testable import RondoShell

@Suite struct SettingsRoundTripTests {
    func custom() -> RondoKit.Settings {
        var s = RondoKit.Settings()
        s.convertModifier = .command
        s.toolsModifier = .shift
        s.actionsModifier = .control
        s.imageQuality = 0.6
        s.videoCRF = 28
        s.videoPreset = "slow"
        s.audioBitrateKbps = 320
        s.pdfRenderDPI = 150
        s.destination = .folder(URL(fileURLWithPath: "/Users/me/Converted", isDirectory: true))
        s.revealInFinder = false
        s.hotkey = Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command, .shift])
        s.launchAtLogin = true
        s.toolPaths = ["ffmpeg": "/opt/ffmpeg/bin/ffmpeg"]
        return s
    }

    @Test func jsonRoundTrip() throws {
        let s = custom()
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(RondoKit.Settings.self, from: data) == s)
        #expect(try JSONDecoder().decode(RondoKit.Settings.self, from: JSONEncoder().encode(RondoKit.Settings())) == RondoKit.Settings())
    }

    @Test func userDefaultsRoundTrip() throws {
        let suite = "rondo.shell.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(RondoKit.Settings.load(from: defaults) == RondoKit.Settings())
        let s = custom()
        s.save(to: defaults)
        #expect(RondoKit.Settings.load(from: defaults) == s)
    }

    @Test func lenientDecoding() throws {
        let json = #"{"videoCRF": 30, "imageQuality": "bad", "unknownKey": 1, "toolsModifier": "hyper"}"#
        let s = try JSONDecoder().decode(RondoKit.Settings.self, from: Data(json.utf8))
        #expect(s.videoCRF == 30)
        #expect(s.imageQuality == RondoKit.Settings().imageQuality)
        #expect(s.toolsModifier == .option)
        #expect(s.hotkey == RondoKit.Settings().hotkey)
    }

    @Test func clearedHotkeyPersists() throws {
        var s = RondoKit.Settings()
        s.hotkey = nil
        let decoded = try JSONDecoder().decode(RondoKit.Settings.self, from: JSONEncoder().encode(s))
        // Synthesized encode omits a nil hotkey, so decoding restores the ⌃⌥Space default.
        // Contract request filed with the orchestrator (encode hotkey as explicit null).
        #expect(decoded.hotkey == nil)
    }

    @Test func modifierMappingSwaps() {
        let s = RondoKit.Settings()   // shift/option/control
        let t = ModifierMapping.assign(.option, to: .convert, in: s)
        #expect(t.convertModifier == .option)
        #expect(t.toolsModifier == .shift)       // swapped
        #expect(t.actionsModifier == .control)
        let u = ModifierMapping.assign(.command, to: .actions, in: t)
        #expect(u.actionsModifier == .command)
        #expect(Set([u.convertModifier, u.toolsModifier, u.actionsModifier]).count == 3)
        #expect(ModifierMapping.assign(.shift, to: .convert, in: s) == s)
        #expect(u.wheel(for: .command) == .actions)
    }
}

@Suite struct HotkeyFormatTests {
    @Test func displayStrings() {
        #expect(HotkeyFormat.string(for: RondoKit.Settings().hotkey!) == "⌃⌥Space")
        #expect(HotkeyFormat.string(for: Hotkey(keyCode: UInt32(kVK_ANSI_K), modifiers: [.command, .shift, .control])) == "⌃⇧⌘K")
        #expect(HotkeyFormat.string(for: Hotkey(keyCode: UInt32(kVK_F5), modifiers: [])) == "F5")
        #expect(HotkeyFormat.keyName(999) == "Key 999")
    }

    @Test func carbonMaskAndValidity() {
        #expect(HotkeyFormat.carbonModifiers([.control, .option]) == UInt32(controlKey | optionKey))
        #expect(HotkeyFormat.carbonModifiers([]) == 0)
        #expect(HotkeyFormat.modifiers(from: [.command, .shift]) == [.shift, .command])
        #expect(HotkeyFormat.isValid(Hotkey(keyCode: 49, modifiers: [.control])))
        #expect(!HotkeyFormat.isValid(Hotkey(keyCode: 49, modifiers: [])))
        #expect(!HotkeyFormat.isValid(Hotkey(keyCode: 0, modifiers: [.shift])))
        #expect(HotkeyFormat.isValid(Hotkey(keyCode: UInt32(kVK_F12), modifiers: [])))
    }
}

@Suite struct JobBatcherTests {
    let a = URL(fileURLWithPath: "/x/a.png"), b = URL(fileURLWithPath: "/x/b.png"), c = URL(fileURLWithPath: "/x/c.png")

    @Test func oneDropRevealsOnceWithAllOutputs() {
        var batcher = JobBatcher()
        let ids = [UUID(), UUID(), UUID()]
        let spec = JobSpec(inputs: [a], operation: .convert(to: "jpg"))
        for id in ids { batcher.queued(id, spec: spec, at: 10) }
        #expect(batcher.ended(ids[1], outputs: [b]) == nil)
        #expect(batcher.ended(ids[0], outputs: [a]) == nil)
        #expect(batcher.ended(ids[2], outputs: []) == [b, a])   // failed/cancelled job contributes nothing
        #expect(batcher.isIdle)
    }

    @Test func differentOperationsOrLateJobsAreSeparate() {
        var batcher = JobBatcher(window: 0.5)
        let j1 = UUID(), j2 = UUID(), j3 = UUID()
        batcher.queued(j1, spec: JobSpec(inputs: [a], operation: .convert(to: "jpg")), at: 0)
        batcher.queued(j2, spec: JobSpec(inputs: [b], operation: .convert(to: "png")), at: 0.01)
        batcher.queued(j3, spec: JobSpec(inputs: [c], operation: .convert(to: "png")), at: 5)
        #expect(batcher.ended(j1, outputs: [a]) == [a])
        #expect(batcher.ended(j2, outputs: [b]) == [b])
        #expect(batcher.ended(j3, outputs: [c]) == [c])
    }

    @Test func unknownJobIsItsOwnBatch() {
        var batcher = JobBatcher()
        #expect(batcher.ended(UUID(), outputs: [a]) == [a])
    }
}

@Suite struct FinderSelectionParsingTests {
    @Test func aliasListToURLs() {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/one.txt")), at: 1)
        list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/tmp/two folder", isDirectory: true)), at: 2)
        let urls = FinderSelection.fileURLs(in: list).map(\.path)
        #expect(urls == ["/tmp/one.txt", "/tmp/two folder"])
        #expect(FinderSelection.fileURLs(in: NSAppleEventDescriptor.list()).isEmpty)
    }
}

@Suite @MainActor struct RecentOutputsTests {
    @Test func newestFirstDedupedPersisted() throws {
        let dir = try makeScratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "rondo.shell.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = (1...4).map { dir.appendingPathComponent("f\($0).txt") }
        files.forEach { touch($0) }

        let recents = RecentOutputs(limit: 3, defaults: defaults)
        recents.add([files[0]])
        recents.add([files[1], files[2]])
        recents.add([files[0]])
        #expect(recents.items.map(\.lastPathComponent) == ["f1.txt", "f3.txt", "f2.txt"])
        recents.add([files[3]])
        #expect(recents.items.count == 3)

        try FileManager.default.removeItem(at: files[3])
        let reloaded = RecentOutputs(limit: 3, defaults: defaults)
        #expect(reloaded.items.map(\.lastPathComponent) == ["f1.txt", "f3.txt"])   // missing f4 skipped
        reloaded.clear()
        #expect(RecentOutputs(limit: 3, defaults: defaults).items.isEmpty)
    }
}
