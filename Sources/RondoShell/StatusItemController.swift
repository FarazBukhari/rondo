import AppKit
import RondoKit

/// Menu-bar item: original template icon, menu (Recent Outputs ▸, Show Float Shelf, Settings…,
/// Permissions…, Quit), and the button accepts file drops → `onOpenWheel` (click-mode wheel).
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    /// Files dropped on the menu-bar icon + cursor (AppKit screen coordinates).
    public var onOpenWheel: (([URL], CGPoint) -> Void)?
    public var onShowFloatShelf: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenPermissions: (() -> Void)?
    /// Default: `NSApp.terminate(nil)`.
    public var onQuit: (() -> Void)?

    public let recents: RecentOutputs
    public private(set) var statusItem: NSStatusItem?

    private let menu = NSMenu()
    private var busy = false

    public init(recents: RecentOutputs? = nil) {
        self.recents = recents ?? .shared
        super.init()
    }

    /// Creates the status item. Call once from `applicationDidFinishLaunching`.
    public func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.image = StatusIcon.image(busy: false)
        item.button?.toolTip = "Rondo — drop files here"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        rebuildMenu()
        enableDrops()
    }

    public func uninstall() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    /// Swap to the "jobs running" icon variant.
    public func setBusy(_ busy: Bool) {
        guard busy != self.busy else { return }
        self.busy = busy
        statusItem?.button?.image = StatusIcon.image(busy: busy)
    }

    // MARK: Menu

    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let recentItem = NSMenuItem(title: "Recent Outputs", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let items = recents.items
        if items.isEmpty {
            let none = NSMenuItem(title: "No recent outputs", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for url in items {
                let mi = NSMenuItem(title: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = url
                mi.toolTip = url.path
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 16, height: 16)
                mi.image = icon
                sub.addItem(mi)
            }
            sub.addItem(.separator())
            sub.addItem(item("Clear Recent Outputs", #selector(clearRecents)))
        }
        recentItem.submenu = sub
        menu.addItem(recentItem)
        menu.addItem(.separator())
        menu.addItem(item("Show Float Shelf", #selector(showFloat)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Permissions…", #selector(openPermissions)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Rondo", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func clearRecents() { recents.clear() }
    @objc private func showFloat() { onShowFloatShelf?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openPermissions() { (onOpenPermissions ?? onOpenSettings)?() }
    @objc private func quit() {
        if let onQuit { onQuit() } else { NSApp.terminate(nil) }
    }

    // MARK: Drops (the status bar window forwards NSDraggingDestination calls to its delegate)

    private func enableDrops(attempt: Int = 0) {
        guard let window = statusItem?.button?.window else {
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.enableDrops(attempt: attempt + 1) }
            } else {
                ShellLog.logger.error("status item has no window; drops disabled")
            }
            return
        }
        window.registerForDraggedTypes([.fileURL])
        window.delegate = self
    }

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        statusItem?.button?.highlight(true)
        return .copy
    }

    public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? [] : .copy
    }

    public func draggingExited(_ sender: NSDraggingInfo?) {
        statusItem?.button?.highlight(false)
    }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem?.button?.highlight(false)
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        let point = NSEvent.mouseLocation
        ShellLog.logger.notice("status item drop: \(urls.count) file(s)")
        // Let the drag session end before the wheel panel appears.
        DispatchQueue.main.async { [weak self] in self?.onOpenWheel?(urls, point) }
        return true
    }
}

/// Original menu-bar glyph: a ring split into three arcs (one per wheel) around a hub.
enum StatusIcon {
    static func image(busy: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r: CGFloat = 7
            NSColor.black.setStroke()
            for i in 0..<3 {
                let start = CGFloat(i) * 120 + 100
                let arc = NSBezierPath()
                arc.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: start + 96)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                arc.stroke()
            }
            let hub = busy ? NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6) : NSRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: hub).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Rondo"
        return image
    }
}
