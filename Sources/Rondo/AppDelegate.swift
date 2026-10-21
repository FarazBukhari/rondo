import AppKit
import ImageEditorUI
import MediaEditorUI
import os
import PDFOrganizerUI
import RondoInteraction
import RondoKit
import RondoShell

/// Composition root: drag/status-item/hotkey/float entry points → wheel → jobs or actions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.farazbukhari.rondo", category: "app")

    private var settings = Settings.load()
    private var registry: EngineRegistry
    private let queue: JobQueue
    private let recents = RecentOutputs.shared

    private let dragMonitor: DragMonitor
    private let wheel: WheelPanel
    private let statusItem: StatusItemController
    private var hud: ProgressHUD!
    private let floatShelf = FloatShelf()
    private lazy var actions = ActionPerformer(floatShelf: floatShelf)
    private lazy var settingsWindow = SettingsWindowController(settings: settings)
    private let hotkey = GlobalHotkey()
    private var busyWatcher: Task<Void, Never>?

    override init() {
        let (registry, tools) = makeRegistry(settings: settings)
        self.registry = registry
        queue = JobQueue(registry: registry, tools: tools)
        dragMonitor = DragMonitor(settings: settings, policy: Self.policy(for: settings))
        wheel = WheelPanel(itemProvider: RegistryWheelItemProvider(registry: registry))
        statusItem = StatusItemController(recents: recents)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()
        statusItem.onOpenWheel = { [weak self] urls, point in self?.openWheelForClick(urls, at: point) }
        statusItem.onShowFloatShelf = { [weak self] in self?.floatShelf.showAll() }
        statusItem.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        statusItem.onOpenPermissions = { [weak self] in self?.settingsWindow.show(tab: .permissions) }
        statusItem.onQuit = { NSApp.terminate(nil) }

        floatShelf.onOpenWheel = { [weak self] urls, point in self?.openWheelForClick(urls, at: point) }

        dragMonitor.onTrigger = { [weak self] trigger in
            self?.wheel.present(inputs: trigger.urls, at: trigger.location, kind: trigger.kind, mode: .drag)
        }
        dragMonitor.onDragEnded = { [weak self] location, _ in
            self?.wheel.dragEnded(at: location)
        }
        wheel.onSelect = { [weak self] item, urls in self?.handle(item, urls: urls) }

        settingsWindow.onChange = { [weak self] new in self?.apply(new) }
        settingsWindow.onHotkeyRecording = { [weak self] recording in
            if recording { self?.hotkey.unregister() } else { self?.registerHotkey() }
        }
        hotkey.onError = { [weak self] error in
            self?.log.notice("hotkey: \(error.localizedDescription, privacy: .public)")
        }

        ImageEditor.tools = ToolLocator.fromSettings(settings)
        TempDir.sweep()   // leftovers from crashes / forced quits (>1 h old)
        attachQueue()
        registerHotkey()
        dragMonitor.start()
        showWelcomeIfFirstLaunch()
        log.notice("Rondo launched: \(self.registry.allConversions.count) conversions, \(self.registry.allTools.count) tools")
    }

    /// Quit waits (bounded) for running jobs to cancel and clean their temp dirs, so no
    /// ffmpeg/magick children or partial temp output outlive the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ImageEditor.closeAll()
        let queue = self.queue
        Task { @MainActor in
            await MediaEditor.closeAllAndWait(timeout: 5)   // kills preview ffmpeg, removes scratch dirs
            await queue.cancelAll()
            let deadline = Date().addingTimeInterval(5)
            while await queue.activeCount > 0, Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        dragMonitor.stop()
        hotkey.unregister()
    }

    // MARK: - Wiring

    /// (Re)creates the HUD and busy indicator for the current queue.
    private func attachQueue() {
        hud?.stop()
        hud = ProgressHUD(queue: queue, recents: recents)
        hud.toolTitle = { [weak self] in self?.registry.tool($0)?.title }
        hud.shouldReveal = { [weak self] in self?.settings.revealInFinder ?? true }

        busyWatcher?.cancel()
        let events = queue.subscribe()
        busyWatcher = Task { @MainActor [weak self] in
            var active = Set<UUID>()
            for await event in events {
                switch event {
                case .queued(let id, _): active.insert(id)
                case .finished(let id, _), .failed(let id, _), .cancelled(let id): active.remove(id)
                default: break
                }
                self?.statusItem.setBusy(!active.isEmpty)
            }
        }
    }

    private func registerHotkey() {
        hotkey.unregister()
        guard let hk = settings.hotkey else { return }
        let ok = hotkey.registerFinderSelection(hk) { [weak self] urls, point in
            self?.wheel.present(inputs: urls, at: point, kind: .convert, mode: .click)
        }
        if !ok { log.error("hotkey registration failed") }
    }

    private func apply(_ new: Settings) {
        let toolsChanged = new.toolPaths != settings.toolPaths
        let hotkeyChanged = new.hotkey != settings.hotkey
        settings = new
        dragMonitor.settings = new
        dragMonitor.policy = Self.policy(for: new)
        if hotkeyChanged { registerHotkey() }
        if toolsChanged { scheduleRegistryRebuild() }
    }

    private var registryRebuild: DispatchWorkItem?

    /// Tool-path fields change on every keystroke: rebuild engines once typing settles, then
    /// swap them into the existing queue (HUD, busy indicator and running jobs are unaffected).
    private func scheduleRegistryRebuild() {
        registryRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let (registry, tools) = makeRegistry(settings: self.settings)
            ImageEditor.tools = tools
            self.registry = registry
            self.wheel.itemProvider = RegistryWheelItemProvider(registry: registry)
            let queue = self.queue
            Task { await queue.update(registry: registry, tools: tools) }
            self.log.notice("engines rebuilt for new tool paths: \(registry.allConversions.count) conversions")
        }
        registryRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: - Wheel

    /// Status-item / Float / hotkey entry: wheel kind from the modifiers held right now.
    private func openWheelForClick(_ urls: [URL], at point: CGPoint) {
        let held = DragMonitor.modifierKeys(in: NSEvent.modifierFlags)
        // Deterministic when several mapped modifiers are held: Convert, then Tools, then Actions.
        let kind = WheelKind.allCases.first { kind in held.contains { self.settings.wheel(for: $0) == kind } } ?? .convert
        wheel.present(inputs: urls, at: point, kind: kind, mode: .click)
    }

    private func handle(_ item: WheelItem, urls: [URL]) {
        log.notice("select \(item.id, privacy: .public) on \(urls.count) item(s)")
        switch item.payload {
        case .action(let action):
            actions.perform(action, urls: urls)
        case .convert(let id):
            submit(.convert(to: id), urls: urls)
        case .tool(let id):
            guard let tool = registry.tool(id) else { return }
            if tool.needsUI && !openEditor(for: tool, urls: urls) {
                showMessage("\(tool.title) needs its editor", detail: "Editor windows arrive in a later build phase.")
                return
            }
            if !tool.needsUI { submit(.tool(id), urls: urls) }
        }
    }

    private func submit(_ operation: RondoKit.Operation, urls: [URL], extra: [String: OptionValue] = [:]) {
        let options = defaultOptions(for: operation, inputs: urls, registry: registry, settings: settings)
            .merging(extra) { _, explicit in explicit }
        let spec = JobSpec(inputs: urls, operation: operation, options: options, destination: settings.destination)
        let queue = self.queue
        Task { await queue.submit(spec) }
    }

    /// Opens the editor window for a `needsUI` tool. Editors never write files: they call back
    /// with explicit options, which run through the queue like any other job.
    /// Returns false when no editor handles the tool.
    private func openEditor(for tool: ToolDescriptor, urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let submit: ([URL], ToolID, [String: OptionValue]) -> Void = { [weak self] inputs, id, options in
            self?.submit(.tool(id), urls: inputs, extra: options)
        }
        let id = tool.id.rawValue
        // Single-file editors open one window per file (capped); merge arranges all files at once.
        let perFile = Array(urls.prefix(Self.maxEditorWindows))
        if id.hasPrefix("image.") {
            perFile.forEach { ImageEditor.open(url: $0, tool: tool.id, submit: submit) }
        } else if id.hasPrefix("video.") || id.hasPrefix("audio.") {
            perFile.forEach { MediaEditor.open(url: $0, tool: tool.id, submit: submit) }
        } else if tool.id == "pdf.merge" {
            PDFOrganizer.open(urls: urls, tool: tool.id, submit: submit)
            return true
        } else if PDFOrganizer.supportedTools.contains(tool.id) {
            perFile.forEach { PDFOrganizer.open(urls: [$0], tool: tool.id, submit: submit) }
        } else {
            return false
        }
        if urls.count > perFile.count {
            showMessage("Opened \(perFile.count) of \(urls.count) files",
                        detail: "\(tool.title) edits one file per window; Rondo opens at most \(Self.maxEditorWindows) at a time.")
        }
        return true
    }

    private static let maxEditorWindows = 5
    private static let welcomeShownKey = "welcomeShown.v1"

    /// One-time hint: Rondo lives in the menu bar and is driven by drag + modifier keys.
    private func showWelcomeIfFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.welcomeShownKey) else { return }
        defaults.set(true, forKey: Self.welcomeShownKey)
        let s = settings
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rondo is in your menu bar"
        alert.informativeText = """
        Drag any file, and while dragging tap:
          \(s.convertModifier.symbol)  Convert   ·   \(s.toolsModifier.symbol)  Tools   ·   \(s.actionsModifier.symbol)  Actions
        Drop on a slice. Results are saved next to the original — originals are never changed.

        You can also drop files on the menu-bar icon, or select files in Finder and press the keyboard shortcut.
        """
        alert.addButton(withTitle: "Got It")
        alert.addButton(withTitle: "Open Settings…")
        if alert.runModal() == .alertSecondButtonReturn {
            settingsWindow.show()
        }
    }

    private static func policy(for settings: Settings) -> ModifierTriggerPolicy {
        settings.wheelTrigger == .tap ? .standardTap : .press
    }

    private func showMessage(_ title: String, detail: String?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail ?? ""
        alert.runModal()
    }
}
