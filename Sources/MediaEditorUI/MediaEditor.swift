import AppKit
import RondoKit
import SwiftUI

/// Entry point for the media editor windows (video trim/split/crop/snapshot/speed, audio trim/bleep).
/// Editors never write files: they collect options and hand them to `submit`.
@MainActor
public enum MediaEditor {
    private static var controllers: [URL: MediaEditorWindowController] = [:]
    /// Tests turn this off so windows are built but never put on screen.
    static var presentsWindows = true

    /// Opens (or focuses) an editor for `url` on the panel for `tool`
    /// (video.trim, video.crop, video.split, video.snapshot, audio.trim, audio.bleep; video.speed also works).
    /// `submit(inputs, toolID, options)` is called once on Save/Apply; then the window closes.
    public static func open(url: URL, tool: ToolID, submit: @escaping ([URL], ToolID, [String: OptionValue]) -> Void) {
        open(url: url, tool: tool, tools: ToolLocator.fromSettings(), submit: submit)
    }

    static func open(url: URL, tool: ToolID, tools: ToolLocator, submit: @escaping ([URL], ToolID, [String: OptionValue]) -> Void) {
        let key = url.standardizedFileURL
        let mapped = EditorPanel.panel(for: tool)
        if mapped == nil { editorLog.notice("no editor panel for \(tool.rawValue, privacy: .public); opening the default panel") }

        if let existing = controllers[key] {
            existing.model.submitHandler = submit
            if let mapped, mapped.isVideo == existing.model.isVideo { existing.model.panel = mapped.panel }
            if presentsWindows { existing.show() }
            return
        }

        let isVideo: Bool
        switch FormatCatalog.kind(for: url) {
        case .video: isVideo = true
        case .audio: isVideo = false
        default: isVideo = mapped?.isVideo ?? true
        }
        let panels = EditorPanel.panels(isVideo: isVideo)
        let panel = mapped.map(\.panel).flatMap { panels.contains($0) ? $0 : nil } ?? panels[0]

        let model = MediaEditorModel(url: url, panel: panel, isVideo: isVideo, tools: tools)
        model.submitHandler = submit
        let controller = MediaEditorWindowController(model: model)
        controller.onClose = { controllers[key] = nil }
        controllers[key] = controller
        if presentsWindows { controller.show() }
        model.start()
    }

    /// Closes every editor without submitting (e.g. on quit).
    public static func closeAll() {
        for c in Array(controllers.values) { c.close() }
    }

    static var openControllers: [MediaEditorWindowController] { Array(controllers.values) }

    static func controller(for url: URL) -> MediaEditorWindowController? {
        controllers[url.standardizedFileURL]
    }
}

/// Window owning one `MediaEditorModel`. Closing it (button, ⌘W, Esc, red light) shuts the model down
/// without submitting.
@MainActor
final class MediaEditorWindowController: NSObject, NSWindowDelegate {
    let model: MediaEditorModel
    let window: NSWindow
    var onClose: (() -> Void)?
    private var keyMonitor: Any?

    init(model: MediaEditorModel) {
        self.model = model
        let size = model.isVideo ? NSSize(width: 920, height: 680) : NSSize(width: 840, height: 440)
        let window = EditorWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.title = model.url.lastPathComponent
        window.representedURL = model.url
        window.isReleasedWhenClosed = false
        window.minSize = model.isVideo ? NSSize(width: 720, height: 540) : NSSize(width: 680, height: 360)
        window.contentView = NSHostingView(rootView: MediaEditorView(model: model))
        window.setContentSize(size)
        self.window = window
        super.init()
        window.delegate = self
        model.closeHandler = { [weak self] in self?.close() }
        // Space / arrows / I / O / M / B / Delete while this window is key (not while typing in a field).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let key = EditorKey.from(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                           modifiers: event.modifierFlags) else { return event }
            let windowNumber = event.windowNumber
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.window.windowNumber == windowNumber, !(self.window.firstResponder is NSText) else { return false }
                return self.model.handle(key)
            }
            return consumed ? nil : event
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        if window.isVisible {
            window.close()   // → windowWillClose
        } else {
            finish()
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    private func finish() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.shutdown()
        let done = onClose
        onClose = nil
        done?()
    }
}

/// Escape closes the window (no submit) even when no button has focus.
final class EditorWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
