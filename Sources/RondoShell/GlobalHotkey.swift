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
    /// Called when the hotkey fires but there is nothing to act on (empty selection, permission
    /// denied, Finder error). Default: beep + log.
    public var onError: ((FinderSelectionError) -> Void)?
    /// Only act when Finder is the active app, so a stale selection is never used by surprise.
    public var requireFinderFrontmost = true
    public private(set) var hotkey: Hotkey?

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

    /// Registers `hotkey` to fetch Finder's selection and call `onOpenWheel(urls, cursor)`.
    /// The point is in AppKit screen coordinates (`NSEvent.mouseLocation`).
    @discardableResult
    public func registerFinderSelection(_ hotkey: Hotkey, onOpenWheel: @escaping ([URL], CGPoint) -> Void) -> Bool {
        register(hotkey) { [weak self] in
            let cursor = NSEvent.mouseLocation
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderSelection.bundleID
            let result: Result<[URL], FinderSelectionError> =
                (self?.requireFinderFrontmost ?? true) && !frontmost ? .failure(.finderNotFrontmost) : FinderSelection.current()
            switch result {
            case .success(let urls):
                onOpenWheel(urls, cursor)
            case .failure(let error):
                ShellLog.logger.notice("hotkey: \(error.localizedDescription, privacy: .public)")
                if let onError = self?.onError { onError(error) } else { NSSound.beep() }
            }
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
    case script(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "Nothing is selected in Finder."
        case .notPermitted: "Rondo isn't allowed to control Finder. Allow it in System Settings › Privacy & Security › Automation."
        case .finderNotRunning: "Finder isn't running."
        case .finderNotFrontmost: "Finder isn't the active app."
        case .script(let m): "Couldn't read the Finder selection: \(m)"
        }
    }
}

public enum FinderSelection {
    public static let bundleID = "com.apple.finder"
    static let source = "tell application \"Finder\" to get selection as alias list"

    /// Current Finder selection as file URLs. Runs an Apple Event; call on the main thread.
    /// The first call triggers macOS's Automation consent prompt (the user decides).
    @MainActor
    public static func current() -> Result<[URL], FinderSelectionError> {
        switch AppleScriptRunner.run(source) {
        case .failure(let e):
            return .failure(e)
        case .success(let desc):
            let urls = fileURLs(in: desc)
            return urls.isEmpty ? .failure(.empty) : .success(urls)
        }
    }

    static func fileURLs(in desc: NSAppleEventDescriptor) -> [URL] {
        if desc.descriptorType == typeAEList {
            guard desc.numberOfItems > 0 else { return [] }
            return (1...desc.numberOfItems).compactMap { desc.atIndex($0).flatMap(fileURL) }
        }
        return fileURL(desc).map { [$0] } ?? []
    }

    private static func fileURL(_ d: NSAppleEventDescriptor) -> URL? {
        if let u = d.fileURLValue { return u }
        return d.coerce(toDescriptorType: typeFileURL)?.fileURLValue
    }
}

/// Thin `NSAppleScript` wrapper mapping well-known Apple Event errors.
enum AppleScriptRunner {
    @MainActor
    static func run(_ source: String) -> Result<NSAppleEventDescriptor, FinderSelectionError> {
        guard let script = NSAppleScript(source: source) else { return .failure(.script("invalid script")) }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (info[NSAppleScript.errorMessage] as? String) ?? "error \(code)"
            switch code {
            case -1743: return .failure(.notPermitted)       // errAEEventNotPermitted
            case -600: return .failure(.finderNotRunning)    // procNotFound
            default: return .failure(.script(message))
            }
        }
        return .success(result)
    }
}
