import AppKit
import Foundation
import RondoKit
import SwiftUI
import os

let organizerLog = Logger(subsystem: "com.farazbukhari.rondo", category: "pdf-organizer")

/// PDF organizer windows: reorder / rotate / delete pages, pick split ranges, order files to merge.
/// The organizer never writes files — it hands the inputs + engine options to `submit`, and the app turns
/// that into a `JobSpec` for `PDFDocumentEngine`.
@MainActor public enum PDFOrganizer {
    /// Opens an organizer for `urls` on the mode for `tool`:
    ///  - pdf.reorder (1 PDF): reorder / rotate / delete pages
    ///  - pdf.split (1 PDF): pick split ranges visually
    ///  - pdf.merge (2+ PDFs): order the files (and optionally preview)
    /// `submit(inputs, toolID, options)` is called once on Save/Apply; then the window closes.
    /// For merge, `inputs` is the user's chosen file order.
    public static func open(urls: [URL], tool: ToolID, submit: @escaping ([URL], ToolID, [String: OptionValue]) -> Void) {
        guard let controller = makeController(urls: urls, tool: tool) else { return }
        OrganizerWindowController(controller: controller, submit: submit).show()
    }

    /// Tool IDs this module can open.
    public static let supportedTools: Set<ToolID> = ["pdf.reorder", "pdf.split", "pdf.merge"]

    static func makeController(urls: [URL], tool: ToolID) -> (any OrganizerController)? {
        switch tool.rawValue {
        case "pdf.reorder", "pdf.split":
            guard let url = urls.first else {
                organizerLog.error("\(tool.rawValue, privacy: .public): no input file")
                return nil
            }
            if urls.count > 1 {
                organizerLog.notice("\(tool.rawValue, privacy: .public): \(urls.count) files given; organizing the first only")
            }
            return tool.rawValue == "pdf.reorder" ? ReorderModel(url: url) : SplitModel(url: url)
        case "pdf.merge":
            return MergeModel(urls: urls)
        default:
            organizerLog.error("PDF organizer can't open tool \(tool.rawValue, privacy: .public)")
            return nil
        }
    }

    static func rootView(for controller: any OrganizerController, actions: OrganizerActions) -> AnyView {
        switch controller {
        case let m as ReorderModel: AnyView(ReorderView(model: m, actions: actions))
        case let m as SplitModel: AnyView(SplitView(model: m, actions: actions))
        case let m as MergeModel: AnyView(MergeView(model: m, actions: actions))
        default: AnyView(EmptyView())
        }
    }
}

/// One organizer window. Keeps itself alive until closed; routes keys through `OrganizerCommand`.
@MainActor
final class OrganizerWindowController: NSObject, NSWindowDelegate {
    private static var live: [ObjectIdentifier: OrganizerWindowController] = [:]

    let controller: any OrganizerController
    let window: NSWindow
    private let submit: ([URL], ToolID, [String: OptionValue]) -> Void
    private var keyMonitor: Any?
    private(set) var finished = false

    init(controller: any OrganizerController, submit: @escaping ([URL], ToolID, [String: OptionValue]) -> Void) {
        self.controller = controller
        self.submit = submit
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        var actions = OrganizerActions()
        actions.cancel = { [weak self] in self?.cancel() }
        actions.submit = { [weak self] in self?.commit() }
        let hosting = NSHostingController(rootView: PDFOrganizer.rootView(for: controller, actions: actions))
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: controller is MergeModel ? 640 : 880, height: controller is MergeModel ? 520 : 640))
        window.title = controller.windowTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    func show() {
        Self.live[ObjectIdentifier(self)] = self
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        organizerLog.notice("opened \(self.controller.tool.rawValue, privacy: .public)")
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// True when the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard event.window === window, window.attachedSheet == nil else { return false }
        let editing = window.firstResponder is NSText
        guard let command = OrganizerCommand.from(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                                  modifiers: event.modifierFlags, editingText: editing) else { return false }
        // Merge uses a native list: let it handle arrow keys itself.
        if case .step = command, controller is MergeModel { return false }
        return route(command)
    }

    @discardableResult
    func route(_ command: OrganizerCommand) -> Bool {
        switch command {
        case .cancel: cancel(); return true
        case .submit: commit(); return true
        default: return controller.perform(command)
        }
    }

    // MARK: Finish

    func commit() {
        guard !finished else { return }
        guard let payload = controller.payload() else {
            NSSound.beep()
            return
        }
        finished = true
        let keys = payload.options.keys.sorted().joined(separator: ",")
        organizerLog.notice("submit \(self.controller.tool.rawValue, privacy: .public): \(payload.inputs.count) input(s), options [\(keys, privacy: .public)]")
        submit(payload.inputs, controller.tool, payload.options)
        window.close()
    }

    func cancel() {
        finished = true
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if !finished { organizerLog.notice("closed without saving") }
        finished = true
        Self.live[ObjectIdentifier(self)] = nil
    }
}
