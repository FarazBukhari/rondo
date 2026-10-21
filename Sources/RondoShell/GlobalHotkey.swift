import AppKit
import Carbon.HIToolbox
import RondoKit

/// System-wide hotkey via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
///
/// One instance owns at most one registration; `register` replaces the previous one.
/// Typical use: `registerFinderSelection(settings.hotkey, onOpenWheel:)` — reads Finder's selection
/// (Automation permission, prompted by macOS on first use) and calls back with the files and cursor.
@MainActor
public final class GlobalHotkey {
    /// Notified when the hotkey fires but there is nothing to act on (empty selection, permission
    /// denied, Finder error), after the default feedback.
    public var onError: ((FinderSelectionError) -> Void)?
    /// Beep for empty selection / Finder not active / no response; an alert offering the Automation
    /// privacy pane when Finder access is denied. Set false to handle everything in `onError`.
    public var showsDefaultFeedback = true
    /// Only act when Finder is the active app, so a stale selection is never used by surprise.
    public var requireFinderFrontmost = true
    /// Seconds to wait for Finder (`osascript`) before giving up.
    public var finderTimeout: TimeInterval = 10
    public private(set) var hotkey: Hotkey?
    private var fetching = false

    private var ref: EventHotKeyRef?
    private var slot: UInt32 = 0

    public init() {}

    /// Registers `hotkey`; `handler` runs on the main actor each time it is pressed.
    /// Returns false if macOS refused (e.g. another app already owns the combination).
    @discardableResult
    public func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        guard HotkeyFormat.isValid(hotkey) else {
            ShellLog.logger.error("hotkey \(HotkeyFormat.string(for: hotkey), privacy: .public) rejected: needs ⌃, ⌥ or ⌘")
            return false
        }
        HotkeyDispatcher.installIfNeeded()
        let id = HotkeyDispatcher.nextID()
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            HotkeyFormat.carbonModifiers(hotkey.modifiers),
            EventHotKeyID(signature: HotkeyDispatcher.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        guard status == noErr, let newRef else {
            ShellLog.logger.error("RegisterEventHotKey \(HotkeyFormat.string(for: hotkey), privacy: .public) failed: \(status)")
            return false
        }
        ref = newRef
        slot = id
        self.hotkey = hotkey
        HotkeyDispatcher.handlers[id] = handler
        ShellLog.logger.notice("hotkey registered: \(HotkeyFormat.string(for: hotkey), privacy: .public)")
        return true
    }

    /// Registers `hotkey` to fetch Finder's selection (off the main thread, via `osascript`) and call
    /// `onOpenWheel(urls, cursor)` on the main actor. The point is the cursor at key press, in AppKit
    /// screen coordinates. Presses while a fetch is still running are ignored.
    @discardableResult
    public func registerFinderSelection(_ hotkey: Hotkey, onOpenWheel: @escaping ([URL], CGPoint) -> Void) -> Bool {
        register(hotkey) { [weak self] in
            guard let self, !self.fetching else { return }
            let cursor = NSEvent.mouseLocation
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderSelection.bundleID
            if self.requireFinderFrontmost, !frontmost {
                self.failed(.finderNotFrontmost)
                return
            }
            self.fetching = true
            let timeout = self.finderTimeout
            Task { @MainActor [weak self] in
                let result = await FinderSelection.current(timeout: timeout)
                guard let self else { return }
                self.fetching = false
                switch result {
                case .success(let urls): onOpenWheel(urls, cursor)
                case .failure(let error): self.failed(error)
                }
            }
        }
    }

    private func failed(_ error: FinderSelectionError) {
        ShellLog.logger.notice("hotkey: \(error.localizedDescription, privacy: .public)")
        if showsDefaultFeedback { Self.presentDefaultFeedback(for: error) }
        onError?(error)
    }

    /// Beep, or for a denied Automation permission an alert that can open the privacy pane.
    public static func presentDefaultFeedback(for error: FinderSelectionError) {
        guard error == .notPermitted else {
            NSSound.beep()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rondo can't read the Finder selection"
        alert.informativeText = "Allow Rondo to control Finder in System Settings › Privacy & Security › Automation, then press the shortcut again."
        alert.addButton(withTitle: "Open Automation Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAutomationSettings()
        }
    }

    public func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotkeyDispatcher.handlers[slot] = nil
        hotkey = nil
    }
}

/// Single Carbon event handler for the app, dispatching to registered closures by hotkey ID.
@MainActor
enum HotkeyDispatcher {
    static var signature: OSType { hotkeySignature }
    static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var installed = false
    private static var counter: UInt32 = 0

    static func nextID() -> UInt32 {
        counter += 1
        return counter
    }

    static func installIfNeeded() {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
        if status == noErr {
            installed = true
        } else {
            ShellLog.logger.error("InstallEventHandler failed: \(status)")
        }
    }

    static func fire(_ id: UInt32) {
        handlers[id]?()
    }
}

private let hotkeySignature: OSType = 0x524E_444F   // 'RNDO'

private func hotKeyCallback(_ call: EventHandlerCallRef?, _ event: EventRef?, _ user: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hk = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hk
    )
    guard status == noErr, hk.signature == hotkeySignature else { return OSStatus(eventNotHandledErr) }
    let id = hk.id
    Task { @MainActor in HotkeyDispatcher.fire(id) }
    return noErr
}

// MARK: - Finder selection

public enum FinderSelectionError: Error, LocalizedError, Equatable {
    case empty
    /// Automation (Apple Events → Finder) denied in System Settings › Privacy & Security › Automation.
    case notPermitted
    case finderNotRunning
    case finderNotFrontmost
    case timedOut
    case script(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Nothing is selected in Finder."
        case .notPermitted: "Rondo isn't allowed to control Finder. Allow it in System Settings › Privacy & Security › Automation."
        case .finderNotRunning: "Finder isn't running."
        case .finderNotFrontmost: "Finder isn't the active app."
        case .timedOut: "Finder didn't respond in time. If macOS asked for permission, try again."
        case .script(let m): "Couldn't read the Finder selection: \(m)"
        }
    }
}

public enum FinderSelection {
    public static let bundleID = "com.apple.finder"
    /// POSIX paths of the selection, one per line (folders end in "/").
    static let script = [
        "tell application \"Finder\" to set sel to selection as alias list",
        "set out to \"\"",
        "repeat with a in sel",
        "set out to out & POSIX path of (contents of a) & linefeed",
        "end repeat",
        "return out",
    ]

    /// Current Finder selection as file URLs. Runs `osascript` off the main thread with a timeout.
    /// The first call triggers macOS's Automation consent prompt (the user decides).
    public static func current(timeout: TimeInterval = 10) async -> Result<[URL], FinderSelectionError> {
        switch await AppleScriptRunner.run(script, timeout: timeout) {
        case .failure(let e):
            return .failure(e)
        case .success(let out):
            let urls = parse(out)
            return urls.isEmpty ? .failure(.empty) : .success(urls)
        }
    }

    /// `osascript` stdout (one POSIX path per line) → file URLs.
    static func parse(_ output: String) -> [URL] {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0) }
    }
}

/// Runs AppleScript through `/usr/bin/osascript` (RondoKit `ProcessRunner`) so a busy Finder or a
/// pending consent prompt never blocks the main thread. Maps well-known Apple Event errors.
enum AppleScriptRunner {
    static func run(_ lines: [String], timeout: TimeInterval) async -> Result<String, FinderSelectionError> {
        guard let osascript = ToolLocator().url(for: "osascript") else { return .failure(.script("osascript not found")) }
        let args = lines.flatMap { ["-e", $0] }
        do {
            let output: String? = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { try await ProcessRunner.run(osascript, args).stdout }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()   // kills osascript on timeout
                return first
            }
            guard let output else { return .failure(.timedOut) }
            return .success(output)
        } catch let e as ProcessError {
            return .failure(map(stderr: e.stderrTail))
        } catch {
            return .failure(.script(error.localizedDescription))
        }
    }

    /// "…: execution error: Not authorized to send Apple events to Finder. (-1743)" → `.notPermitted`.
    static func map(stderr: String) -> FinderSelectionError {
        let line = stderr.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        var code = 0
        if line.hasSuffix(")"), let open = line.lastIndex(of: "(") {
            code = Int(line[line.index(after: open)..<line.index(before: line.endIndex)]) ?? 0
        }
        switch code {
        case -1743, -1744: return .notPermitted   // errAEEventNotPermitted / would require consent
        case -600: return .finderNotRunning       // procNotFound
        case -1712: return .timedOut              // errAETimeout
        default:
            var message = line
            if let r = message.range(of: "execution error: ") { message = String(message[r.upperBound...]) }
            return .script(message.isEmpty ? "osascript failed" : message)
        }
    }
}
