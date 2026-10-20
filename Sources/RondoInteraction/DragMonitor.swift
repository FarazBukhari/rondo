import AppKit
import os
import RondoKit

/// Watches system-wide mouse drags. When file(s) are dragged (from Finder or any app) and the user
/// taps a modifier mapped in `Settings`, emits a `Trigger` with the files, wheel kind, and cursor point.
///
/// Technique (validated in P1 on macOS 26, no Accessibility needed): global NSEvent monitors for
/// mouse down/dragged/up; file drag ⇔ `NSPasteboard(name: .drag).changeCount` changed since mouse-down
/// and it holds file URLs; modifier state polled from `NSEvent.modifierFlags` at 30 Hz during the drag
/// (global `.flagsChanged` is also observed but is not relied on). Decisions live in `DragGestureMachine`.
@MainActor
public final class DragMonitor {
    public struct Trigger: Equatable, Sendable {
        public let urls: [URL]
        public let kind: WheelKind
        public let modifier: ModifierKey
        /// Cursor in screen coordinates (bottom-left origin) when the modifier fired.
        public let location: CGPoint

        public init(urls: [URL], kind: WheelKind, modifier: ModifierKey, location: CGPoint) {
            self.urls = urls
            self.kind = kind
            self.modifier = modifier
            self.location = location
        }
    }

    /// File drag detected (before any modifier). Useful to pre-compute wheel items.
    public var onDragBegan: (([URL]) -> Void)?
    /// Mapped modifier tapped during a file drag → open (or switch) the wheel.
    public var onTrigger: ((Trigger) -> Void)?
    /// The file drag ended (mouse up). `location` in screen coordinates.
    public var onDragEnded: ((_ location: CGPoint, _ triggered: Bool) -> Void)?

    /// Modifier → wheel mapping source. Assign at runtime to apply remapped keys (takes effect immediately).
    public var settings: Settings {
        didSet { machine.mapping = DragGestureMachine.mapping(from: settings) }
    }

    public var policy: ModifierTriggerPolicy {
        get { machine.policy }
        set { machine.policy = newValue }
    }

    public private(set) var isRunning = false
    public var isDragging: Bool { machine.isDragging }

    private let log = Logger(subsystem: "com.farazbukhari.rondo", category: "drag")
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var machine: DragGestureMachine
    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var changeCountAtMouseDown = 0
    private var lastExaminedChangeCount: Int?

    public init(settings: Settings = Settings(), policy: ModifierTriggerPolicy = .press) {
        self.settings = settings
        self.machine = DragGestureMachine(settings: settings, policy: policy)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let specs: [(NSEvent.EventTypeMask, @MainActor (DragMonitor, NSEvent) -> Void)] = [
            (.leftMouseDown, { $0.mouseDown($1) }),
            (.leftMouseDragged, { $0.mouseDragged($1) }),
            (.leftMouseUp, { m, _ in m.mouseUp() }),
            (.flagsChanged, { $0.feed(.modifiers(Self.modifierKeys(in: $1.modifierFlags))) }),
        ]
        for (mask, handler) in specs {
            let token = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self, event)
                }
            }
            if let token { monitors.append(token) }
        }
        log.notice("DragMonitor started (\(self.monitors.count, privacy: .public) monitors)")
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        stopPolling()
        if machine.isDragging { feed(.mouseUp) }
        log.notice("DragMonitor stopped")
    }

    /// `NSEvent.ModifierFlags` → the keys Rondo can map.
    public nonisolated static func modifierKeys(in flags: NSEvent.ModifierFlags) -> Set<ModifierKey> {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        var keys: Set<ModifierKey> = []
        if f.contains(.shift) { keys.insert(.shift) }
        if f.contains(.option) { keys.insert(.option) }
        if f.contains(.control) { keys.insert(.control) }
        if f.contains(.command) { keys.insert(.command) }
        return keys
    }

    // MARK: - Event handling

    private var currentModifiers: Set<ModifierKey> { Self.modifierKeys(in: NSEvent.modifierFlags) }

    private func mouseDown(_ event: NSEvent) {
        changeCountAtMouseDown = dragPasteboard.changeCount
        lastExaminedChangeCount = nil
        feed(.mouseDown(modifiers: Self.modifierKeys(in: event.modifierFlags)))
    }

    private func mouseDragged(_ event: NSEvent) {
        let mods = Self.modifierKeys(in: event.modifierFlags)
        guard machine.phase == .armed else {
            feed(.mouseDragged(files: nil, modifiers: mods))
            return
        }
        feed(.mouseDragged(files: newDragFiles(), modifiers: mods))
    }

    private func mouseUp() {
        feed(.mouseUp)
    }

    /// File URLs on the drag pasteboard if it changed since mouse-down (each change read once).
    private func newDragFiles() -> [URL]? {
        let count = dragPasteboard.changeCount
        guard count != changeCountAtMouseDown, count != lastExaminedChangeCount else { return nil }
        lastExaminedChangeCount = count
        let urls = dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.isEmpty ? nil : urls
    }

    private func feed(_ event: DragGestureMachine.Event) {
        let outputs = machine.handle(event, at: ProcessInfo.processInfo.systemUptime)
        for output in outputs {
            switch output {
            case .dragBegan(let urls):
                log.notice("file drag began: \(urls.count, privacy: .public) item(s), first=\(urls[0].lastPathComponent, privacy: .public)")
                startPolling()
                onDragBegan?(urls)
            case .trigger(let urls, let kind, let modifier):
                log.notice("modifier \(modifier.rawValue, privacy: .public) → \(kind.rawValue, privacy: .public) wheel")
                onTrigger?(Trigger(urls: urls, kind: kind, modifier: modifier, location: NSEvent.mouseLocation))
            case .dragEnded(_, let triggered):
                log.notice("file drag ended (triggered=\(triggered, privacy: .public))")
                stopPolling()
                onDragEnded?(NSEvent.mouseLocation, triggered)
            }
        }
    }

    // MARK: - Polling (modifiers without Accessibility; missed mouse-up safety net)

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard machine.isDragging else { return stopPolling() }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            feed(.mouseUp)   // the global mouse-up never arrived
        } else {
            feed(.modifiers(currentModifiers))
        }
    }
}
