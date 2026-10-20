import AppKit
import os

/// Watches system-wide mouse drags. When files are being dragged (from Finder or any app)
/// and the user taps a mapped modifier key, fires `onTrigger` with the dragged files.
///
/// P1 spike: proves global drag + modifier detection works without Accessibility.
/// Mouse events come from global NSEvent monitors; modifier state is polled from
/// `NSEvent.modifierFlags` during a drag because global key-event monitors need Accessibility.
public final class DragMonitor {
    public struct Trigger {
        public let urls: [URL]
        public let modifier: NSEvent.ModifierFlags
        public let location: NSPoint   // screen coordinates, bottom-left origin
    }

    public var onTrigger: ((Trigger) -> Void)?
    public var onDragEnded: (() -> Void)?
    /// Modifiers that open a wheel. Order matters only for simultaneous presses.
    public var watchedModifiers: [NSEvent.ModifierFlags] = [.shift, .option, .control]

    private let log = Logger(subsystem: "com.farazbukhari.rondo", category: "drag")
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var changeCountAtMouseDown = 0
    private var draggedURLs: [URL]?
    private var lastFlags: NSEvent.ModifierFlags = []

    public init() {}

    deinit { stop() }

    public func start() {
        guard monitors.isEmpty else { return }
        let add: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Void = { mask, handler in
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
                self.monitors.append(m)
            }
        }
        add(.leftMouseDown) { [weak self] _ in self?.mouseDown() }
        add(.leftMouseDragged) { [weak self] _ in self?.mouseDragged() }
        add(.leftMouseUp) { [weak self] _ in self?.mouseUp() }
        add(.flagsChanged) { [weak self] e in self?.flagsChanged(e.modifierFlags) }
        log.notice("DragMonitor started (\(self.monitors.count, privacy: .public) monitors)")
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        endDrag()
    }

    // MARK: - Event handling

    private func mouseDown() {
        changeCountAtMouseDown = dragPasteboard.changeCount
        endDrag()
    }

    private func mouseDragged() {
        guard draggedURLs == nil else { return }
        guard dragPasteboard.changeCount != changeCountAtMouseDown else { return }
        let urls = dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        draggedURLs = urls
        lastFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        log.notice("file drag began: \(urls.count, privacy: .public) item(s), first=\(urls[0].lastPathComponent, privacy: .public)")
        startPolling()
    }

    private func mouseUp() {
        guard draggedURLs != nil else { return }
        log.notice("drag ended")
        endDrag()
        onDragEnded?()
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        handleFlags(flags.intersection(.deviceIndependentFlagsMask))
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.handleFlags(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        defer { lastFlags = flags }
        guard let urls = draggedURLs else { return }
        let pressed = flags.subtracting(lastFlags)
        guard let modifier = watchedModifiers.first(where: { pressed.contains($0) }) else { return }
        log.notice("modifier tap during drag: \(modifier.rawValue, privacy: .public)")
        onTrigger?(Trigger(urls: urls, modifier: modifier, location: NSEvent.mouseLocation))
    }

    private func endDrag() {
        pollTimer?.invalidate()
        pollTimer = nil
        draggedURLs = nil
    }
}
