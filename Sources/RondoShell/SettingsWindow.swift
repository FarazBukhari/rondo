import AppKit
import RondoKit
import SwiftUI

// SwiftUI also declares `Settings` (a scene) — spell out `RondoKit.Settings` here.

/// Settings window (SwiftUI in `NSHostingController`). Every edit is saved to UserDefaults and
/// reported through `onChange` so the app can re-register the hotkey, rebuild the tool locator, etc.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public enum Tab: String, CaseIterable, Sendable {
        case general, quality, tools, permissions
    }

    public var onChange: ((RondoKit.Settings) -> Void)? {
        get { model.onChange }
        set { model.onChange = newValue }
    }
    /// True while the hotkey recorder is listening — pause the global hotkey so it can be re-recorded.
    public var onHotkeyRecording: ((Bool) -> Void)? {
        get { model.onRecording }
        set { model.onRecording = newValue }
    }
    public var settings: RondoKit.Settings { model.settings }

    private let model: SettingsModel
    private var window: NSWindow?

    public init(settings: RondoKit.Settings? = nil, defaults: UserDefaults = .standard) {
        model = SettingsModel(settings: settings ?? RondoKit.Settings.load(from: defaults), defaults: defaults)
        super.init()
    }

    public func show(tab: Tab? = nil) {
        if let tab { model.tab = tab }
        model.refreshStatus()
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.close()
    }

    /// Push settings changed elsewhere into the window (does not call `onChange`).
    public func update(_ settings: RondoKit.Settings) {
        model.replace(settings)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Rondo Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: SettingsView.width, height: SettingsView.height))
        window.delegate = self
        return window
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        model.refreshStatus()
    }

    public func windowWillClose(_ notification: Notification) {
        model.stopRecordingIfNeeded()
    }
}

// MARK: - Model

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var settings: RondoKit.Settings
    @Published var tab: SettingsWindowController.Tab = .general
    @Published var accessibilityTrusted = false
    @Published var automation: Permissions.AutomationStatus = .notChecked
    @Published var launchStatus = ""
    @Published var launchError: String?
    @Published var recordingHotkey = false
    @Published var hotkeyWarning: String?

    var onChange: ((RondoKit.Settings) -> Void)?
    var onRecording: ((Bool) -> Void)?

    private let defaults: UserDefaults
    private var keyMonitor: Any?

    static let knownTools: [(name: String, purpose: String)] = [
        ("ffmpeg", "Video and audio conversion"),
        ("ffprobe", "Media inspection"),
        ("magick", "Extra image formats (WebP, AVIF, SVG…)"),
        ("pandoc", "Document conversion (optional)"),
        ("soffice", "Office documents via LibreOffice (optional)"),
    ]

    init(settings: RondoKit.Settings, defaults: UserDefaults) {
        self.settings = settings
        self.defaults = defaults
    }

    func apply(_ change: (inout RondoKit.Settings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        settings = s
        s.save(to: defaults)
        onChange?(s)
    }

    func replace(_ s: RondoKit.Settings) {
        settings = s
    }

    func binding<T>(_ keyPath: WritableKeyPath<RondoKit.Settings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { v in self.apply { $0[keyPath: keyPath] = v } })
    }

    func modifierBinding(_ wheel: WheelKind) -> Binding<ModifierKey> {
        Binding(
            get: { ModifierMapping.current(wheel, in: self.settings) },
            set: { m in self.apply { $0 = ModifierMapping.assign(m, to: wheel, in: $0) } }
        )
    }

    func refreshStatus() {
        accessibilityTrusted = Permissions.accessibilityTrusted
        launchStatus = LaunchAtLogin.statusText
        // Keep the stored flag honest (the user may have changed Login Items in System Settings).
        let actual = LaunchAtLogin.isEnabled || LaunchAtLogin.requiresApproval
        if settings.launchAtLogin != actual, launchError == nil {
            apply { $0.launchAtLogin = actual }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LaunchAtLogin.set(on)
            launchError = nil
            apply { $0.launchAtLogin = on }
        } catch {
            launchError = error.localizedDescription
            ShellLog.logger.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
        launchStatus = LaunchAtLogin.statusText
    }

    func checkAutomation() {
        automation = Permissions.checkAutomation()
    }

    // MARK: Hotkey recording

    func toggleRecording() {
        recordingHotkey ? stopRecordingIfNeeded() : startRecording()
    }

    func startRecording() {
        guard keyMonitor == nil else { return }
        hotkeyWarning = nil
        recordingHotkey = true
        onRecording?(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleRecording(event) ? nil : event
        }
    }

    func stopRecordingIfNeeded() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
        recordingHotkey = false
        onRecording?(false)
    }

    /// Returns true when the event was consumed.
    private func handleRecording(_ event: NSEvent) -> Bool {
        let mods = HotkeyFormat.modifiers(from: event.modifierFlags)
        if mods.isEmpty, event.keyCode == 53 {           // Esc: cancel
            stopRecordingIfNeeded()
            return true
        }
        if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117 {   // Delete: clear
            apply { $0.hotkey = nil }
            stopRecordingIfNeeded()
            return true
        }
        let hk = Hotkey(keyCode: UInt32(event.keyCode), modifiers: mods)
        guard HotkeyFormat.isValid(hk) else {
            hotkeyWarning = "Use at least one of ⌃ ⌥ ⌘ (or a function key)."
            NSSound.beep()
            return true
        }
        hotkeyWarning = nil
        apply { $0.hotkey = hk }
        stopRecordingIfNeeded()
        return true
    }

    // MARK: Tools

    func detected(_ tool: String) -> URL? {
        ToolLocator(overrides: settings.toolPaths).url(for: tool)
    }

    func overrideIsInvalid(_ tool: String) -> Bool {
        guard let p = settings.toolPaths[tool], !p.isEmpty else { return false }
        return !FileManager.default.isExecutableFile(atPath: p)
    }

    func toolPathBinding(_ tool: String) -> Binding<String> {
        Binding(
            get: { self.settings.toolPaths[tool] ?? "" },
            set: { v in
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                self.apply { $0.toolPaths[tool] = trimmed.isEmpty ? nil : trimmed }
            }
        )
    }

    func chooseTool(_ tool: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(tool) executable"
        panel.prompt = "Use"
        if panel.runModal() == .OK, let url = panel.url {
            apply { $0.toolPaths[tool] = url.path }
        }
    }

    // MARK: Destination

    var destinationFolder: URL? {
        if case .folder(let u) = settings.destination { return u }
        return nil
    }

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Save converted files in:"
        if panel.runModal() == .OK, let url = panel.url {
            apply { $0.destination = .folder(url) }
        }
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    static let width: CGFloat = 540
    static let height: CGFloat = 480

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsWindowController.Tab.general)
            QualityPane(model: model)
                .tabItem { Label("Quality", systemImage: "slider.horizontal.3") }
                .tag(SettingsWindowController.Tab.quality)
            ToolsPane(model: model)
                .tabItem { Label("Tools", systemImage: "hammer") }
                .tag(SettingsWindowController.Tab.tools)
            PermissionsPane(model: model)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsWindowController.Tab.permissions)
        }
        .padding(12)
        .frame(width: Self.width, height: Self.height)
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                modifierPicker("Convert wheel", .convert)
                modifierPicker("Tools wheel", .tools)
                modifierPicker("Actions wheel", .actions)
                Picker("Open the wheel", selection: model.binding(\.wheelTrigger)) {
                    Text("As soon as the key goes down").tag(WheelTrigger.press)
                    Text("On a quick tap (key released)").tag(WheelTrigger.tap)
                }
            } header: {
                Text("While dragging files, tap")
            } footer: {
                Text("Each key opens one wheel; picking a key that's in use swaps the two. Choose “quick tap” if you hold ⌥ while dragging to make Finder copy instead of move.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Keyboard shortcut (acts on the Finder selection)") {
                LabeledContent("Shortcut") {
                    HStack {
                        Button(action: model.toggleRecording) {
                            Text(hotkeyTitle).frame(minWidth: 120)
                        }
                        if model.settings.hotkey != nil, !model.recordingHotkey {
                            Button("Clear") { model.apply { $0.hotkey = nil } }
                        }
                    }
                }
                if let warning = model.hotkeyWarning {
                    Text(warning).font(.caption).foregroundColor(.orange)
                }
            }

            Section("Output") {
                Picker("Save converted files", selection: destinationKind) {
                    Text("Next to the original").tag(0)
                    Text("In a folder").tag(1)
                }
                if let folder = model.destinationFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(folder.path).lineLimit(1).truncationMode(.middle)
                            Button("Choose…", action: model.chooseDestinationFolder)
                        }
                    }
                }
                Toggle("Reveal results in Finder", isOn: model.binding(\.revealInFinder))
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(get: { model.settings.launchAtLogin }, set: model.setLaunchAtLogin))
                LabeledContent("Status", value: model.launchStatus)
                if let error = model.launchError {
                    Text(error).font(.caption).foregroundColor(.red)
                }
                if LaunchAtLogin.requiresApproval {
                    Button("Open Login Items Settings") { LaunchAtLogin.openLoginItemsSettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hotkeyTitle: String {
        if model.recordingHotkey { return "Type shortcut… (Esc cancels)" }
        return model.settings.hotkey.map(HotkeyFormat.string(for:)) ?? "None — click to record"
    }

    private var destinationKind: Binding<Int> {
        Binding(
            get: { model.destinationFolder == nil ? 0 : 1 },
            set: { v in
                if v == 0 {
                    model.apply { $0.destination = .besideOriginal }
                } else if model.destinationFolder == nil {
                    model.chooseDestinationFolder()
                }
            }
        )
    }

    private func modifierPicker(_ title: String, _ wheel: WheelKind) -> some View {
        Picker(title, selection: model.modifierBinding(wheel)) {
            ForEach(ModifierKey.allCases, id: \.self) { m in
                Text("\(m.symbol)  \(m.rawValue.capitalized)").tag(m)
            }
        }
    }
}

private struct QualityPane: View {
    @ObservedObject var model: SettingsModel
    static let presets = ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"]
    static let bitrates = [96, 128, 160, 192, 256, 320]
    static let dpis = [72, 150, 200, 300, 600]

    var body: some View {
        Form {
            Section("Images (JPEG, HEIC, WebP, AVIF)") {
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: model.binding(\.imageQuality), in: 0.1...1, step: 0.05)
                        Text("\(Int((model.settings.imageQuality * 100).rounded()))%")
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            Section("Video") {
                Stepper(value: model.binding(\.videoCRF), in: 0...51) {
                    LabeledContent("Quality (CRF)", value: "\(model.settings.videoCRF) — lower is better")
                }
                Picker("Encoder preset", selection: model.binding(\.videoPreset)) {
                    ForEach(Self.presets, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Audio") {
                Picker("Bitrate", selection: model.binding(\.audioBitrateKbps)) {
                    ForEach(Self.bitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                }
            }
            Section("PDF") {
                Picker("Render resolution", selection: model.binding(\.pdfRenderDPI)) {
                    ForEach(Self.dpis, id: \.self) { Text("\($0) dpi").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ToolsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(SettingsModel.knownTools, id: \.name) { tool in
                    ToolRow(model: model, name: tool.name, purpose: tool.purpose)
                }
            } header: {
                Text("External tools")
            } footer: {
                Text("Leave a path empty to search Homebrew and system folders. Changes apply to new jobs.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ToolRow: View {
    @ObservedObject var model: SettingsModel
    let name: String
    let purpose: String

    var body: some View {
        let found = model.detected(name)
        let invalid = model.overrideIsInvalid(name)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: found != nil ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundColor(found != nil ? .green : .secondary)
                Text(name).font(.system(.body, design: .monospaced))
                Text(purpose).font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            Text(found?.path ?? "Not found")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                TextField("Custom path (optional)", text: model.toolPathBinding(name))
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { model.chooseTool(name) }
            }
            if invalid {
                Text("That path isn't an executable file; using the search path instead.")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PermissionsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    statusLabel(model.accessibilityTrusted ? "Granted" : "Not granted", ok: model.accessibilityTrusted)
                }
                HStack {
                    Button("Open Accessibility Settings") { Permissions.openAccessibilitySettings() }
                    Button("Re-check") { model.refreshStatus() }
                }
            } header: {
                Text("Accessibility")
            } footer: {
                Text("Optional. Lets arrow keys and Return pick a slice while you're dragging.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                LabeledContent("Status") {
                    statusLabel(model.automation.title, ok: model.automation == .allowed)
                }
                HStack {
                    Button("Check Now") { model.checkAutomation() }
                    Button("Open Automation Settings") { Permissions.openAutomationSettings() }
                }
            } header: {
                Text("Automation (Finder)")
            } footer: {
                Text("Needed for the keyboard shortcut to read the Finder selection. “Check Now” asks Finder for its name; macOS may ask you to allow it.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Text("Rondo never changes these settings itself. Rebuilding an ad-hoc signed copy can reset grants.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func statusLabel(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundColor(ok ? .green : .orange)
            Text(text)
        }
    }
}
