import AppKit
import os
import RondoInteraction

/// Composition root. P1 spike: status item + Finder drag → modifier → wheel → drop.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.farazbukhari.rondo", category: "app")
    private var statusItem: NSStatusItem!
    private let dragMonitor = DragMonitor()
    private let wheel = WheelPanel()
    private var lastDropItem: NSMenuItem!

    private let spikeTitles: [NSEvent.ModifierFlags.RawValue: [String]] = [
        NSEvent.ModifierFlags.shift.rawValue: ["JPG", "PNG", "PDF", "HEIC"],
        NSEvent.ModifierFlags.option.rawValue: ["Compress", "Crop", "Resize", "Strip"],
        NSEvent.ModifierFlags.control.rawValue: ["AirDrop", "Float", "Copy", "Path"],
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        dragMonitor.onTrigger = { [weak self] trigger in
            guard let self else { return }
            let titles = self.spikeTitles[trigger.modifier.rawValue] ?? ["?"]
            self.wheel.present(titles: titles, at: trigger.location)
        }
        dragMonitor.onDragEnded = { [weak self] in
            guard let self else { return }
            // Drop on the wheel is handled by the wheel; anything else cancels.
            if !self.wheel.contains(NSEvent.mouseLocation) { self.wheel.dismiss() }
        }
        wheel.onSelect = { [weak self] index, title, urls in
            self?.handleSpikeDrop(title: title, urls: urls)
        }
        dragMonitor.start()
        log.notice("Rondo launched")
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Rondo")
        }
        let menu = NSMenu()
        lastDropItem = NSMenuItem(title: "No drops yet", action: nil, keyEquivalent: "")
        menu.addItem(lastDropItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Rondo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func handleSpikeDrop(title: String, urls: [URL]) {
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        log.notice("spike drop → \(title, privacy: .public): \(names, privacy: .public)")
        lastDropItem.title = "Last drop: \(names) → \(title)"

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Wheel drop received"
        alert.informativeText = "\(urls.count) file(s) → \(title)\n\(names)"
        alert.runModal()
    }
}
