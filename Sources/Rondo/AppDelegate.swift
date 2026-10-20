import AppKit
import os
import RondoInteraction
import RondoKit

/// Composition root. Interim (P3): drag → wheel wired to W1's API; engines and shell land in P4.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.farazbukhari.rondo", category: "app")
    private var statusItem: NSStatusItem!
    private var lastDropItem: NSMenuItem!
    private let settings = Settings.load()
    private lazy var registry = EngineRegistry(engines: [])
    private lazy var dragMonitor = DragMonitor(settings: settings)
    private lazy var wheel = WheelPanel(itemProvider: RegistryWheelItemProvider(registry: registry))

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        dragMonitor.onTrigger = { [weak self] trigger in
            self?.wheel.present(inputs: trigger.urls, at: trigger.location, kind: trigger.kind, mode: .drag)
        }
        dragMonitor.onDragEnded = { [weak self] location, _ in
            self?.wheel.dragEnded(at: location)
        }
        wheel.onSelect = { [weak self] item, urls in
            self?.handle(item, urls: urls)
        }
        dragMonitor.start()
        log.notice("Rondo launched")
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Rondo")
        let menu = NSMenu()
        lastDropItem = NSMenuItem(title: "No drops yet", action: nil, keyEquivalent: "")
        menu.addItem(lastDropItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Rondo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func handle(_ item: WheelItem, urls: [URL]) {
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        log.notice("wheel select \(item.id, privacy: .public): \(names, privacy: .public)")
        lastDropItem.title = "Last: \(names) → \(item.title)"
    }
}
