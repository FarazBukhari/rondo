import AppKit
import Foundation
import RondoKit

// Pure, view-free logic for the organizer. Everything here is value types so it can be unit-tested
// without a window. Page numbers are 1-based throughout (the engine's convention).

// MARK: - Undo

/// Linear undo/redo history around a value. `apply` records a step only when the value actually changed.
struct Undoable<State: Equatable>: Equatable {
    private(set) var current: State
    private var past: [State] = []
    private var future: [State] = []
    let limit: Int

    init(_ initial: State, limit: Int = 200) {
        current = initial
        self.limit = limit
    }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    /// The value the history started from (or the oldest one kept).
    var original: State { past.first ?? current }

    @discardableResult
    mutating func apply(_ change: (inout State) -> Void) -> Bool {
        var next = current
        change(&next)
        guard next != current else { return false }
        past.append(current)
        if past.count > limit { past.removeFirst(past.count - limit) }
        current = next
        future.removeAll()
        return true
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = past.popLast() else { return false }
        future.append(current)
        current = previous
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let next = future.popLast() else { return false }
        past.append(current)
        current = next
        return true
    }
}

// MARK: - Ordered moves

extension Array where Element: Identifiable {
    /// Moves the elements whose ids are in `ids` (keeping their relative order) so they sit just before
    /// the element that is at `destination` in the *current* array (`destination == count` → end).
    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`.
    func moving(_ ids: Set<Element.ID>, to destination: Int) -> [Element] {
        let moving = filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return self }
        let clamped = Swift.min(Swift.max(destination, 0), count)
        let before = self[..<clamped].filter { !ids.contains($0.id) }.count
        var rest = filter { !ids.contains($0.id) }
        rest.insert(contentsOf: moving, at: before)
        return rest
    }
}

// MARK: - Reorder (pdf.reorder)

/// One page in the organizer: which source page it shows and how much rotation the user added.
struct PageItem: Hashable, Identifiable {
    /// Stable identity. Equals the source page for the initial arrangement.
    let id: Int
    /// 1-based page in the source PDF.
    let source: Int
    /// Clockwise degrees added by the user, normalized to 0 / 90 / 180 / 270.
    var rotation: Int = 0
}

/// The page list being edited in reorder mode. Deleted pages are simply absent from `items`.
struct PageArrangement: Equatable {
    let pageCount: Int
    private(set) var items: [PageItem]

    init(pageCount: Int) {
        self.pageCount = max(0, pageCount)
        items = pageCount > 0 ? (1...pageCount).map { PageItem(id: $0, source: $0) } : []
    }

    static func normalized(_ degrees: Int) -> Int {
        let snapped = Int((Double(degrees) / 90).rounded()) * 90
        return ((snapped % 360) + 360) % 360
    }

    mutating func move(_ ids: Set<Int>, to destination: Int) {
        items = items.moving(ids, to: destination)
    }

    /// Adds `degrees` (clockwise; negative = counter-clockwise) to every page in `ids`, mod 360.
    mutating func rotate(_ ids: Set<Int>, by degrees: Int) {
        for i in items.indices where ids.contains(items[i].id) {
            items[i].rotation = Self.normalized(items[i].rotation + degrees)
        }
    }

    mutating func delete(_ ids: Set<Int>) {
        items.removeAll { ids.contains($0.id) }
    }

    func index(of id: Int) -> Int? { items.firstIndex { $0.id == id } }

    /// Source pages no longer present, ascending.
    var deletedSources: [Int] {
        let kept = Set(items.map(\.source))
        return pageCount > 0 ? (1...pageCount).filter { !kept.contains($0) } : []
    }

    var isUnchanged: Bool { self == PageArrangement(pageCount: pageCount) }

    /// Engine options for `pdf.reorder`, minimal:
    /// - kept pages still ascending → no `order`; `deletions` lists dropped pages; `rotations` parallel to 1…N.
    /// - otherwise → `order` = kept pages in output order (deleted pages are simply absent);
    ///   `rotations` parallel to `order`.
    /// Keys are omitted when they'd be no-ops; an unchanged arrangement yields `[:]`.
    var options: [String: OptionValue] {
        let kept = items.map(\.source)
        var out: [String: OptionValue] = [:]
        let ascending = zip(kept, kept.dropFirst()).allSatisfy { $0 < $1 }
        let rotations: [Int]
        if ascending {
            let deleted = deletedSources
            if !deleted.isEmpty { out["deletions"] = .list(deleted.map(Double.init)) }
            let bySource = Dictionary(items.map { ($0.source, $0.rotation) }, uniquingKeysWith: { a, _ in a })
            rotations = pageCount > 0 ? (1...pageCount).map { bySource[$0] ?? 0 } : []
        } else {
            out["order"] = .list(kept.map(Double.init))
            rotations = items.map(\.rotation)
        }
        if rotations.contains(where: { $0 != 0 }) { out["rotations"] = .list(rotations.map(Double.init)) }
        return out
    }
}

// MARK: - Split (pdf.split)

/// Split parts the user has defined. `parts` is always sorted and non-overlapping.
struct SplitPlan: Equatable {
    let pageCount: Int
    private(set) var parts: [ClosedRange<Int>] = []
    /// Also export the pages not covered by any part (each uncovered run becomes a part).
    var includeRest = false

    init(pageCount: Int, parts: [ClosedRange<Int>] = [], includeRest: Bool = false) {
        self.pageCount = max(0, pageCount)
        self.includeRest = includeRest
        self.parts = Self.normalize(parts, pageCount: self.pageCount)
    }

    /// Contiguous runs of `pages` (clamped to 1…pageCount), ascending.
    static func runs(_ pages: Set<Int>, pageCount: Int) -> [ClosedRange<Int>] {
        let sorted = pages.filter { $0 >= 1 && $0 <= pageCount }.sorted()
        guard var start = sorted.first else { return [] }
        var result: [ClosedRange<Int>] = []
        var end = start
        for p in sorted.dropFirst() {
            if p == end + 1 { end = p; continue }
            result.append(start...end)
            start = p
            end = p
        }
        result.append(start...end)
        return result
    }

    /// Clamps, drops empties, and resolves overlaps (later ranges win) — keeps adjacent ranges separate.
    static func normalize(_ ranges: [ClosedRange<Int>], pageCount: Int) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for r in ranges {
            let lo = max(1, r.lowerBound), hi = min(pageCount, r.upperBound)
            guard lo <= hi else { continue }
            result = subtract(Set(lo...hi), from: result) + [lo...hi]
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func subtract(_ pages: Set<Int>, from ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        ranges.flatMap { r in runs(Set(r).subtracting(pages), pageCount: r.upperBound) }
    }

    /// Each contiguous run of `selection` becomes a part; pages already in other parts move to the new one.
    mutating func addParts(from selection: Set<Int>) {
        let new = Self.runs(selection, pageCount: pageCount)
        guard !new.isEmpty else { return }
        parts = (Self.subtract(Set(new.flatMap { $0 }), from: parts) + new).sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Takes `pages` out of whatever parts contain them (a part may split in two).
    mutating func remove(pages: Set<Int>) {
        parts = Self.subtract(pages, from: parts)
    }

    mutating func removePart(_ range: ClosedRange<Int>) {
        parts.removeAll { $0 == range }
    }

    mutating func clear() { parts = [] }

    func adding(_ selection: Set<Int>) -> SplitPlan {
        var copy = self
        copy.addParts(from: selection)
        return copy
    }

    /// Runs of pages not covered by any part.
    var uncovered: [ClosedRange<Int>] {
        guard pageCount > 0 else { return [] }
        return Self.runs(Set(1...pageCount).subtracting(parts.flatMap { $0 }), pageCount: pageCount)
    }

    /// What the engine will write: one PDF per range, ascending.
    var outputRanges: [ClosedRange<Int>] {
        (parts + (includeRest ? uncovered : [])).sorted { $0.lowerBound < $1.lowerBound }
    }

    static func every(_ n: Int, pageCount: Int) -> [ClosedRange<Int>] {
        guard pageCount > 0 else { return [] }
        let step = max(1, n)
        return stride(from: 1, through: pageCount, by: step).map { $0...min(pageCount, $0 + step - 1) }
    }

    static func options(ranges: [ClosedRange<Int>]) -> [String: OptionValue] {
        ["ranges": .ranges(ranges.map { Double($0.lowerBound)...Double($0.upperBound) })]
    }

    static func options(every n: Int) -> [String: OptionValue] {
        ["every": .int(max(1, n))]
    }

    /// "1–3, 5, 7–8"
    static func describe(_ ranges: [ClosedRange<Int>]) -> String {
        ranges.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }.joined(separator: ", ")
    }
}

// MARK: - Merge (pdf.merge)

struct MergeEntry: Hashable, Identifiable {
    let id: UUID
    let url: URL
    let pageCount: Int

    init(id: UUID = UUID(), url: URL, pageCount: Int) {
        self.id = id
        self.url = url
        self.pageCount = pageCount
    }
}

/// Files to merge, in output order.
struct MergeList: Equatable {
    private(set) var entries: [MergeEntry] = []

    init(_ entries: [MergeEntry] = []) {
        add(entries)
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// Appends (or inserts at `index`) entries whose file isn't already listed. Returns how many were added.
    @discardableResult
    mutating func add(_ new: [MergeEntry], at index: Int? = nil) -> Int {
        var seen = Set(entries.map { Self.key($0.url) })
        let fresh = new.filter { seen.insert(Self.key($0.url)).inserted }
        let at = min(max(index ?? entries.count, 0), entries.count)
        entries.insert(contentsOf: fresh, at: at)
        return fresh.count
    }

    mutating func move(_ ids: Set<UUID>, to destination: Int) {
        entries = entries.moving(ids, to: destination)
    }

    /// Moves the selected entries one step up (-1) or down (+1) as a block.
    mutating func shift(_ ids: Set<UUID>, by delta: Int) {
        let indices = entries.indices.filter { ids.contains(entries[$0].id) }
        guard let first = indices.first, let last = indices.last else { return }
        if delta < 0, first > 0 {
            move(ids, to: first - 1)
        } else if delta > 0, last < entries.count - 1 {
            move(ids, to: last + 2)
        }
    }

    mutating func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
    }

    mutating func sortByName() {
        entries.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    var inputs: [URL] { entries.map(\.url) }
    var totalPages: Int { entries.reduce(0) { $0 + $1.pageCount } }
    var canSubmit: Bool { entries.count >= 2 }
}

// MARK: - Selection

enum ClickKind: Equatable {
    case plain, toggle, extend

    init(_ flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift) { self = .extend }
        else if flags.contains(.command) { self = .toggle }
        else { self = .plain }
    }
}

/// Finder-style click selection over an ordered list of ids.
struct SelectionState<ID: Hashable>: Equatable {
    var selected: Set<ID> = []
    var anchor: ID?

    mutating func click(_ id: ID, kind: ClickKind, order: [ID]) {
        switch kind {
        case .plain:
            selected = [id]
            anchor = id
        case .toggle:
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            anchor = id
        case .extend:
            guard let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) else {
                selected = [id]
                self.anchor = id
                return
            }
            selected.formUnion(order[min(a, b)...max(a, b)])
        }
    }

    mutating func selectAll(_ order: [ID]) {
        selected = Set(order)
        anchor = order.first
    }

    mutating func clear() {
        selected = []
        anchor = nil
    }

    /// Moves a single-item selection by `delta` along `order` (arrow keys).
    mutating func step(_ delta: Int, order: [ID]) {
        guard !order.isEmpty else { return }
        let current = anchor.flatMap { order.firstIndex(of: $0) }
        let next: Int
        if let current { next = min(max(current + delta, 0), order.count - 1) }
        else { next = delta >= 0 ? 0 : order.count - 1 }
        selected = [order[next]]
        anchor = order[next]
    }

    /// Drops ids that no longer exist.
    mutating func prune(to order: [ID]) {
        let live = Set(order)
        selected.formIntersection(live)
        if let a = anchor, !live.contains(a) { anchor = nil }
    }
}

// MARK: - Keyboard

enum OrganizerCommand: Equatable {
    case deleteSelection, rotateRight, rotateLeft, undo, redo, selectAll, cancel, submit
    case step(Int)

    /// Maps a key-down to a command. `editingText` = a text field has focus (plain keys go to it).
    static func from(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags, editingText: Bool = false) -> OrganizerCommand? {
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        let key = characters?.lowercased()
        switch keyCode {
        case 53: return .cancel                                            // Esc
        case 36, 76: return mods == [.command] ? .submit : nil             // ⌘↩ / ⌘⌤
        case 51, 117:                                                       // ⌫ / ⌦
            if editingText { return nil }
            return (mods.isEmpty || mods == [.command]) ? .deleteSelection : nil
        case 123: return (mods.isEmpty && !editingText) ? .step(-1) : nil   // ←
        case 124: return (mods.isEmpty && !editingText) ? .step(1) : nil    // →
        default: break
        }
        switch (mods, key) {
        case ([.command], "r"): return .rotateRight
        case ([.command, .shift], "r"): return .rotateLeft
        case ([.command], "l"): return .rotateLeft
        case ([.command], "z"): return .undo
        case ([.command, .shift], "z"): return .redo
        case ([.command], "a"): return editingText ? nil : .selectAll
        case ([.command], "w"), ([.command], "."): return .cancel
        default: return nil
        }
    }
}
