import AppKit
import Foundation
import RondoKit
import Testing
@testable import RondoInteraction

private let files = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]

/// Runs a scripted event sequence; returns all outputs in order.
private func run(_ machine: inout DragGestureMachine, _ steps: [(TimeInterval, DragGestureMachine.Event)]) -> [DragGestureMachine.Output] {
    steps.flatMap { machine.handle($0.1, at: $0.0) }
}

private func triggers(_ outputs: [DragGestureMachine.Output]) -> [WheelKind] {
    outputs.compactMap { output -> WheelKind? in
        guard case .trigger(_, let kind, _) = output else { return nil }
        return kind
    }
}

@Suite struct DragGestureMachineTests {
    let settings = Settings()   // Shift → convert, Option → tools, Control → actions

    @Test func defaultMappingFromSettings() {
        let map = DragGestureMachine.mapping(from: settings)
        #expect(map == [.shift: .convert, .option: .tools, .control: .actions])
    }

    @Test func tapDuringDragTriggersOnPress() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: nil, modifiers: [])),
            (0.2, .mouseDragged(files: files, modifiers: [])),
            (0.5, .modifiers([.shift])),
            (0.6, .modifiers([])),
            (0.9, .mouseUp),
        ])
        #expect(out == [
            .dragBegan(files),
            .trigger(urls: files, kind: .convert, modifier: .shift),
            .dragEnded(urls: files, triggered: true),
        ])
        #expect(m.phase == .idle)
    }

    @Test func holdFiresOnceAndReleaseDoesNothing() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.2, .modifiers([.option])),
            (0.3, .modifiers([.option])),
            (1.5, .mouseDragged(files: nil, modifiers: [.option])),
            (2.0, .modifiers([])),
        ])
        #expect(triggers(out) == [.tools])
    }

    @Test func modifierHeldAtMouseDownIsIgnoredUntilRepressed() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [.option])),          // ⌥-copy drag
            (0.1, .mouseDragged(files: files, modifiers: [.option])),
            (0.5, .modifiers([.option])),
            (0.8, .modifiers([])),
        ])
        #expect(triggers(out).isEmpty)
        // Pressing it again during the same drag is a real tap.
        #expect(triggers(m.handle(.modifiers([.option]), at: 1.0)) == [.tools])
    }

    @Test func pressAndReleaseBeforeDragDoesNothing() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .modifiers([.shift])),
            (0.1, .modifiers([])),
            (0.2, .mouseDown(modifiers: [])),
            (0.3, .modifiers([.shift])),                        // pressed after mouse-down…
            (0.35, .modifiers([])),                             // …released before the file drag
            (0.4, .mouseDragged(files: files, modifiers: [])),
            (0.8, .mouseUp),
        ])
        #expect(out == [.dragBegan(files), .dragEnded(urls: files, triggered: false)])
    }

    @Test func pressAfterMouseDownStillHeldAtDragStartTriggers() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [.control])),
        ])
        #expect(out == [.dragBegan(files), .trigger(urls: files, kind: .actions, modifier: .control)])
    }

    @Test func heldAtMouseDownReleasedBeforeDragThenPressed() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [.shift])),
            (0.05, .modifiers([])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.3, .modifiers([.shift])),
        ])
        #expect(triggers(out) == [.convert])
    }

    @Test func dragEndsWithoutKey() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.2, .modifiers([])),
            (0.3, .mouseDragged(files: nil, modifiers: [])),
            (0.4, .mouseUp),
        ])
        #expect(out == [.dragBegan(files), .dragEnded(urls: files, triggered: false)])
    }

    @Test func nonFileDragNeverBegins() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: nil, modifiers: [])),
            (0.2, .mouseDragged(files: [], modifiers: [.shift])),
            (0.3, .modifiers([.shift])),
            (0.4, .mouseUp),
        ])
        #expect(out.isEmpty)
    }

    @Test func modifiersWithoutMouseDownAreIgnored() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .modifiers([.shift])),
            (0.1, .mouseDragged(files: files, modifiers: [.shift])),   // no mouse-down seen
            (0.2, .mouseUp),
        ])
        #expect(out.isEmpty)
    }

    @Test func secondModifierSwitchesKind() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.2, .modifiers([.shift])),
            (0.3, .modifiers([])),
            (0.5, .modifiers([.option])),
            (0.6, .modifiers([])),
            (0.8, .modifiers([.option])),   // re-tap same key → trigger again (panel ignores duplicates)
        ])
        #expect(triggers(out) == [.convert, .tools, .tools])
    }

    @Test func unmappedModifierIgnored() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.2, .modifiers([.command])),
            (0.3, .modifiers([.command, .shift])),   // mapped key while ⌘ held still counts
        ])
        #expect(triggers(out) == [.convert])
    }

    @Test func simultaneousPressPrefersWheelOrder() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.2, .modifiers([.control, .option])),
        ])
        #expect(triggers(out) == [.tools])
    }

    @Test func remapAtRuntime() {
        var m = DragGestureMachine(settings: settings)
        _ = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
        ])
        var s = settings
        s.convertModifier = .command
        s.toolsModifier = .shift
        m.mapping = DragGestureMachine.mapping(from: s)
        #expect(triggers(m.handle(.modifiers([.shift]), at: 0.2)) == [.tools])
        #expect(triggers(m.handle(.modifiers([.shift, .command]), at: 0.3)) == [.convert])
    }

    @Test func missedMouseUpClosesDragOnNextMouseDown() {
        var m = DragGestureMachine(settings: settings)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (5.0, .mouseDown(modifiers: [])),
        ])
        #expect(out == [.dragBegan(files), .dragEnded(urls: files, triggered: false)])
        #expect(m.phase == .armed)
    }

    // MARK: Tap policy

    @Test func tapPolicyFiresOnQuickRelease() {
        var m = DragGestureMachine(settings: settings, policy: .standardTap)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.5, .modifiers([.shift])),
            (0.6, .modifiers([.shift])),
            (0.7, .modifiers([])),
        ])
        #expect(out == [.dragBegan(files), .trigger(urls: files, kind: .convert, modifier: .shift)])
    }

    @Test func tapPolicyIgnoresHold() {
        var m = DragGestureMachine(settings: settings, policy: .standardTap)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.5, .modifiers([.option])),
            (0.7, .modifiers([.option])),
            (0.9, .modifiers([.option])),
            (1.2, .modifiers([])),
            (1.5, .mouseUp),
        ])
        #expect(triggers(out).isEmpty)
        #expect(out.last == .dragEnded(urls: files, triggered: false))
    }

    @Test func tapPolicyIgnoresSlowReleaseWithoutIntermediateSamples() {
        var m = DragGestureMachine(settings: settings, policy: .standardTap)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.5, .modifiers([.shift])),
            (1.0, .modifiers([])),
        ])
        #expect(triggers(out).isEmpty)
    }

    @Test func tapPolicyIgnoresChords() {
        var m = DragGestureMachine(settings: settings, policy: .standardTap)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.5, .modifiers([.shift])),
            (0.55, .modifiers([.shift, .command])),
            (0.6, .modifiers([.command])),
            (0.65, .modifiers([])),
        ])
        #expect(triggers(out).isEmpty)
    }

    @Test func tapPolicyReleaseAfterDragEndIsIgnored() {
        var m = DragGestureMachine(settings: settings, policy: .standardTap)
        let out = run(&m, [
            (0.0, .mouseDown(modifiers: [])),
            (0.1, .mouseDragged(files: files, modifiers: [])),
            (0.2, .modifiers([.shift])),
            (0.3, .mouseUp),
            (0.35, .modifiers([])),
        ])
        #expect(triggers(out).isEmpty)
    }

    // MARK: AppKit flag mapping

    @Test func modifierFlagMapping() {
        #expect(DragMonitor.modifierKeys(in: []) == [])
        #expect(DragMonitor.modifierKeys(in: [.shift, .capsLock, .function]) == [.shift])
        #expect(DragMonitor.modifierKeys(in: [.option, .control, .command]) == [.option, .control, .command])
    }
}
