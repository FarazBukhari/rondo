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
    private var moving = Set<String>()

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
        guard !isMoving(urls) else {
            report("Those items are already being moved.", nil)
            return
        }
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
            Task { @MainActor [weak self] in _ = await self?.move(urls, to: dir) }
        }
    }

    /// True while any of `urls` is part of a Move still running.
    public func isMoving(_ urls: [URL]) -> Bool {
        urls.contains { moving.contains($0.standardizedFileURL.path) }
    }

    /// Collision-safe move ("name 2.ext") on a background thread, then reveal the moved files if
    /// enabled. Single-flight: items already being moved are refused (returns nil).
    @discardableResult
    public func move(_ urls: [URL], to directory: URL) async -> [MoveOutcome]? {
        guard !isMoving(urls) else {
            report("Those items are already being moved.", nil)
            return nil
        }
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        moving.formUnion(paths)
        defer { moving.subtract(paths) }

        let outcomes = await Task.detached(priority: .userInitiated) {
            FileMover.move(urls, to: directory)
        }.value

        let landed = outcomes.compactMap(\.destination)
        let problems = outcomes.compactMap { o -> String? in
            switch o.status {
            case .failed(let why): "\(o.source.lastPathComponent): \(why)"
            case .copiedOriginalKept(_, let why): "\(o.source.lastPathComponent): copied, but the original couldn't be removed (\(why))"
            default: nil
            }
        }
        ShellLog.logger.notice("moved \(landed.count) item(s) to \(directory.path, privacy: .public); \(problems.count) problem(s)")
        if !landed.isEmpty, settings().revealInFinder {
            NSWorkspace.shared.activateFileViewerSelecting(landed)
        }
        if !problems.isEmpty {
            report("Some items couldn't be moved.", problems.prefix(8).joined(separator: "\n"))
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
