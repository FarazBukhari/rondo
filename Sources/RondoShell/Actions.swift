import AppKit
import RondoKit

/// Actions wheel: AirDrop, Float, Copy, Move, Copy Path, Terminal. Works on any files/folders.
/// Only `move` relocates user files, and it never overwrites (`FileMover`).
@MainActor
public final class ActionPerformer: NSObject, NSSharingServiceDelegate {
    public let floatShelf: FloatShelf
    /// Current settings (reveal after Move). Default reads UserDefaults.
    public var settings: () -> Settings = { Settings.load() }
    /// User-facing problems (AirDrop unavailable, move failures…). Default: an alert.
    public var onMessage: ((String, String?) -> Void)?

    private var sharing: NSSharingService?

    public init(floatShelf: FloatShelf) {
        self.floatShelf = floatShelf
        super.init()
    }

    public func perform(_ action: ActionID, urls: [URL]) {
        guard !urls.isEmpty else { return }
        ShellLog.logger.notice("action \(action.rawValue, privacy: .public) on \(urls.count) item(s)")
        switch action {
        case .airdrop: airDrop(urls)
        case .float: floatShelf.float(urls: urls)
        case .copy: copyToPasteboard(urls)
        case .move: chooseFolderAndMove(urls)
        case .copyPath: copyPaths(urls)
        case .terminal: openTerminal(at: urls)
        }
    }

    // MARK: AirDrop

    public func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            report("AirDrop isn't available.", "Turn on Wi-Fi and Bluetooth, then try again.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.delegate = self
        sharing = service
        service.perform(withItems: urls)
    }

    public nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            ShellLog.logger.error("AirDrop failed: \(message, privacy: .public)")
            self.sharing = nil
        }
    }

    public nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor in self.sharing = nil }
    }

    // MARK: Pasteboard

    /// File URLs on the general pasteboard; pasting in Finder copies the files.
    public func copyToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    /// Newline-joined POSIX paths as plain text.
    public func copyPaths(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(PathJoiner.join(urls), forType: .string)
    }

    // MARK: Move

    public func chooseFolderAndMove(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.message = urls.count == 1
            ? "Move “\(urls[0].lastPathComponent)” to:"
            : "Move \(urls.count) items to:"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let dir = panel.url else { return }
            self?.move(urls, to: dir)
        }
    }

    /// Collision-safe move ("name 2.ext"), then reveal the moved files if enabled.
    @discardableResult
    public func move(_ urls: [URL], to directory: URL) -> [MoveOutcome] {
        let outcomes = FileMover.move(urls, to: directory)
        let moved = outcomes.compactMap(\.destination)
        let failures = outcomes.compactMap { o -> String? in
            if case .failed(let why) = o.status { return "\(o.source.lastPathComponent): \(why)" }
            return nil
        }
        ShellLog.logger.notice("moved \(moved.count) item(s) to \(directory.path, privacy: .public); \(failures.count) failed")
        if !moved.isEmpty, settings().revealInFinder {
            NSWorkspace.shared.activateFileViewerSelecting(moved)
        }
        if !failures.isEmpty {
            report("Some items couldn't be moved.", failures.prefix(8).joined(separator: "\n"))
        }
        return outcomes
    }

    // MARK: Terminal

    /// `open -a Terminal <dir>` for each distinct folder (at most 5).
    public func openTerminal(at urls: [URL]) {
        let dirs = Array(TerminalTargets.directories(for: urls).prefix(5))
        guard let open = ToolLocator().url(for: "open") else {
            report("Couldn't find /usr/bin/open.", nil)
            return
        }
        Task { [weak self] in
            for dir in dirs {
                do {
                    try await ProcessRunner.run(open, ["-a", "Terminal", dir.path])
                } catch {
                    self?.report("Couldn't open Terminal.", error.localizedDescription)
                    return
                }
            }
        }
    }

    // MARK: -

    private func report(_ message: String, _ info: String?) {
        ShellLog.logger.error("\(message, privacy: .public) \(info ?? "", privacy: .public)")
        if let onMessage {
            onMessage(message, info)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        if let info { alert.informativeText = info }
        alert.runModal()
    }
}
