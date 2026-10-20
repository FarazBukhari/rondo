import Foundation
import RondoKit

/// When a modifier counts as "tapped" during a file drag.
public enum ModifierTriggerPolicy: Equatable, Sendable {
    /// Fire on the key-down edge (fastest; the wheel stays open after release). Default.
    case press
    /// Fire on release, only if the key went down during the drag and was held less than `maxHold`
    /// with no other modifier joining it. Holding a modifier (e.g. ⌥ to force a Finder copy) never opens a wheel.
    case tap(maxHold: TimeInterval)

    public static let standardTap = ModifierTriggerPolicy.tap(maxHold: 0.35)
}

/// Pure state machine behind `DragMonitor`: mouse + drag-pasteboard + modifier samples in,
/// "file drag began / wheel trigger / drag ended" out. No AppKit; driven by synthetic events in tests.
///
/// Rules:
/// - A drag is a *file* drag once the drag pasteboard changed since mouse-down and yields file URLs.
/// - Only modifiers that go down **after mouse-down** count. A modifier already held at mouse-down
///   (Shift-click, ⌥-copy drag) must be released and pressed again.
/// - Pressing and releasing a modifier before the file drag is detected does nothing.
/// - Each mapped press (or tap, per policy) during the drag emits `.trigger`; a different modifier
///   later in the same drag emits another trigger (the wheel switches kind).
public struct DragGestureMachine: Sendable {
    public enum Event: Equatable, Sendable {
        case mouseDown(modifiers: Set<ModifierKey>)
        /// `files` = file URLs on the drag pasteboard if it changed since mouse-down, else nil/empty.
        case mouseDragged(files: [URL]?, modifiers: Set<ModifierKey>)
        case modifiers(Set<ModifierKey>)
        case mouseUp
    }

    public enum Output: Equatable, Sendable {
        case dragBegan([URL])
        case trigger(urls: [URL], kind: WheelKind, modifier: ModifierKey)
        case dragEnded(urls: [URL], triggered: Bool)
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Mouse is down; waiting for the drag pasteboard to carry files.
        case armed
        case dragging
    }

    public var mapping: [ModifierKey: WheelKind]
    public var policy: ModifierTriggerPolicy
    public private(set) var phase: Phase = .idle
    public private(set) var urls: [URL] = []
    public private(set) var triggerCount = 0

    private var held: Set<ModifierKey> = []
    private var pending: (key: ModifierKey, since: TimeInterval, chorded: Bool)?

    public init(mapping: [ModifierKey: WheelKind], policy: ModifierTriggerPolicy = .press) {
        self.mapping = mapping
        self.policy = policy
    }

    public init(settings: Settings, policy: ModifierTriggerPolicy = .press) {
        self.init(mapping: Self.mapping(from: settings), policy: policy)
    }

    /// Modifier → wheel map from Settings (first match wins if two kinds share a key).
    public static func mapping(from settings: Settings) -> [ModifierKey: WheelKind] {
        var map: [ModifierKey: WheelKind] = [:]
        for key in ModifierKey.allCases {
            if let kind = settings.wheel(for: key) { map[key] = kind }
        }
        return map
    }

    public var isDragging: Bool { phase == .dragging }

    public mutating func handle(_ event: Event, at time: TimeInterval) -> [Output] {
        switch (phase, event) {
        case (.dragging, .mouseDown(let mods)):
            // Missed mouse-up: close the old drag, arm a new one.
            let out = endDrag()
            arm(mods)
            return out
        case (_, .mouseDown(let mods)):
            arm(mods)
            return []

        case (.idle, .modifiers(let mods)), (.idle, .mouseDragged(_, let mods)):
            held = mods
            return []

        case (.armed, .modifiers(let mods)):
            // Keep presses made after mouse-down pending (they are compared at drag start);
            // drop releases so a key held at mouse-down and released can be pressed again.
            held.formIntersection(mods)
            return []
        case (.armed, .mouseDragged(let files, let mods)):
            guard let files, !files.isEmpty else {
                held.formIntersection(mods)
                return []
            }
            phase = .dragging
            urls = files
            triggerCount = 0
            pending = nil
            return [.dragBegan(files)] + transition(to: mods, at: time)

        case (.dragging, .modifiers(let mods)), (.dragging, .mouseDragged(_, let mods)):
            return transition(to: mods, at: time)

        case (.dragging, .mouseUp):
            return endDrag()
        case (_, .mouseUp):
            phase = .idle
            return []
        }
    }

    // MARK: - Private

    private mutating func arm(_ mods: Set<ModifierKey>) {
        phase = .armed
        held = mods
        urls = []
        pending = nil
        triggerCount = 0
    }

    private mutating func endDrag() -> [Output] {
        let out = Output.dragEnded(urls: urls, triggered: triggerCount > 0)
        phase = .idle
        urls = []
        pending = nil
        return [out]
    }

    private mutating func transition(to mods: Set<ModifierKey>, at time: TimeInterval) -> [Output] {
        let pressed = mods.subtracting(held)
        let released = held.subtracting(mods)
        held = mods
        switch policy {
        case .press:
            guard let key = firstMapped(pressed) else { return [] }
            return [fire(key)]
        case .tap(let maxHold):
            var out: [Output] = []
            if var p = pending {
                if !pressed.isEmpty { p.chorded = true }
                if released.contains(p.key) {
                    if !p.chorded, time - p.since <= maxHold { out.append(fire(p.key)) }
                    pending = nil
                } else if time - p.since > maxHold {
                    pending = nil   // a hold, not a tap
                } else {
                    pending = p
                }
            }
            if pending == nil, pressed.count == 1, let key = firstMapped(pressed) {
                pending = (key, time, false)
            }
            return out
        }
    }

    private mutating func fire(_ key: ModifierKey) -> Output {
        triggerCount += 1
        // `key` is always mapped here (callers filter via firstMapped).
        return .trigger(urls: urls, kind: mapping[key] ?? .convert, modifier: key)
    }

    /// Mapped key among `keys`, preferring wheel order (convert, tools, actions) on simultaneous presses.
    private func firstMapped(_ keys: Set<ModifierKey>) -> ModifierKey? {
        keys.compactMap { key in mapping[key].map { (key, $0) } }
            .min { a, b in
                let ia = WheelKind.allCases.firstIndex(of: a.1)!, ib = WheelKind.allCases.firstIndex(of: b.1)!
                return ia != ib ? ia < ib : a.0.rawValue < b.0.rawValue
            }?.0
    }
}
