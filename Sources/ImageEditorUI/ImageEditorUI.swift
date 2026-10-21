import AppKit
import os
import RondoKit
import SwiftUI

let editorLog = Logger(subsystem: "com.farazbukhari.rondo", category: "image-editor")

/// Entry point for the image editor windows (Crop / Adjust / Annotate / Redact / Background).
/// Editors never write files: Save hands explicit options to `submit`, and the app runs the job.
@MainActor
public enum ImageEditor {
    public typealias Submit = ([URL], ToolID, [String: OptionValue]) -> Void

    /// Locator used for SVG / non-ImageIO previews via `magick`. The app may replace it with its settings-based one.
    public static var tools = ToolLocator()

    static var controllers: [URL: ImageEditorWindowController] = [:]
    /// Tests: build windows without ordering them on screen or activating the app.
    static var headless = false

    /// Opens (or focuses) an editor window for `url`, starting on the panel for `tool`.
    /// `submit(inputs, toolID, options)` is called once when the user clicks Save/Apply; then the window closes.
    public static func open(url: URL, tool: ToolID, submit: @escaping Submit) {
        let key = url.standardizedFileURL
        if let existing = controllers[key] {
            if let panel = EditorPanel(tool: tool) { existing.model.panel = panel }
            existing.submit = submit
            existing.show()
            return
        }
        let model = ImageEditorModel(url: key, tool: tool)
        let controller = ImageEditorWindowController(model: model, submit: submit)
        controller.onClosed = { controllers[key] = nil }
        controllers[key] = controller
        editorLog.notice("open \(tool.rawValue, privacy: .public) for \(key.lastPathComponent, privacy: .public)")
        controller.show()
        let locator = tools
        Task { await model.load(tools: locator) }
    }

    /// Files with an open editor window.
    public static var openURLs: [URL] { Array(controllers.keys) }

    /// Closes every editor window without submitting.
    public static func closeAll() {
        for c in Array(controllers.values) { c.close() }
    }

    static func model(for url: URL) -> ImageEditorModel? { controllers[url.standardizedFileURL]?.model }
    static func window(for url: URL) -> NSWindow? { controllers[url.standardizedFileURL]?.window }
}

/// Escape anywhere in the window cancels the editor (SwiftUI's Cancel button catches it first when it can).
final class EditorWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class ImageEditorWindowController: NSWindowController, NSWindowDelegate {
    let model: ImageEditorModel
    var submit: ImageEditor.Submit
    var onClosed: (() -> Void)?

    init(model: ImageEditorModel, submit: @escaping ImageEditor.Submit) {
        self.model = model
        self.submit = submit
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.title = model.url.lastPathComponent
        window.subtitle = "Rondo Image Editor"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = NSHostingController(rootView: ImageEditorView(model: model))
        window.setContentSize(NSSize(width: 1040, height: 700))
        window.minSize = NSSize(width: 780, height: 500)
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onCancel = { [weak self] in self?.model.cancel() }
        model.onFinish = { [weak self] submission in self?.finish(submission) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        guard !ImageEditor.headless else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish(_ submission: EditorSubmission?) {
        if let submission {
            submit([model.url], submission.tool, submission.options)
        } else {
            editorLog.notice("cancel \(self.model.url.lastPathComponent, privacy: .public)")
        }
        close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing via the title bar: never submit.
        model.onFinish = nil
        model.cancel()
        let closed = onClosed
        onClosed = nil
        closed?()
    }
}
