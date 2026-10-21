import AppKit
import RondoKit
import SwiftUI

/// Entry point for the media editor windows (video trim/split/crop/snapshot/speed, audio trim/bleep).
/// Editors never write files: they collect options and hand them to `submit`.
@MainActor
public enum MediaEditor {
    private static var controllers: [URL: MediaEditorWindowController] = [:]
    /// Closed editors whose preview processes / scratch dirs are still being cleaned up.
    private static var closing: [ObjectIdentifier: MediaEditorModel] = [:]
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
        controller.onClose = {
            controllers[key] = nil
            trackCleanup(of: model)
        }
        controllers[key] = controller
        if presentsWindows { controller.show() }
        model.start()
    }

    /// Closes every editor without submitting (e.g. on quit). Cleanup continues in the background.
    public static func closeAll() {
        for c in Array(controllers.values) { c.close() }
    }

    /// Closes every editor without submitting, then waits until each one's preview processes have
    /// exited and its scratch dir is removed — including editors closed earlier whose cleanup is still
    /// running. After `timeout` seconds it deletes any remaining scratch dirs itself and returns.
    /// For `applicationShouldTerminate` (`.terminateLater`).
    public static func closeAllAndWait(timeout: TimeInterval = 5) async {
        closeAll()
        let models = Array(closing.values)
        guard !models.isEmpty else { return }
        let finished = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(cont)
            Task { @MainActor in
                for m in models { await m.waitForCleanup() }
                once.resume(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                once.resume(false)
            }
        }
        if !finished {
            editorLog.error("editor cleanup timed out after \(timeout)s; removing scratch dirs directly")
            for m in models { m.removeWorkDirNow() }
        }
    }

    private static func trackCleanup(of model: MediaEditorModel) {
        let id = ObjectIdentifier(model)
        closing[id] = model
        Task { @MainActor in
            await model.waitForCleanup()
            closing[id] = nil
        }
    }

    /// Editors closed but not yet fully cleaned up (tests).
    static var cleanupsInFlight: Int { closing.count }

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

/// Resumes a continuation exactly once (first of several racing tasks wins).
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?

    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }

    func resume(_ value: T) {
        let c: CheckedContinuation<T, Never>? = lock.withLock {
            defer { cont = nil }
            return cont
        }
        c?.resume(returning: value)
    }
}

/// Escape closes the window (no submit) even when no button has focus.
final class EditorWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
