import AppKit
import Foundation
import PDFKit
import RondoKit

/// What every organizer mode exposes to the window: keyboard commands and the final submit payload.
@MainActor
protocol OrganizerController: AnyObject {
    var tool: ToolID { get }
    var windowTitle: String { get }
    var canSubmit: Bool { get }
    /// Handles a keyboard command; false → not applicable (the window may still handle cancel/submit).
    func perform(_ command: OrganizerCommand) -> Bool
    /// Inputs + engine options for the submit closure, or nil if nothing can be submitted.
    func payload() -> (inputs: [URL], options: [String: OptionValue])?
}

// MARK: - Reorder

@MainActor
final class ReorderModel: ObservableObject, OrganizerController {
    let tool: ToolID = "pdf.reorder"
    let url: URL
    let loadError: String?
    @Published private(set) var history: Undoable<PageArrangement>
    @Published var selection = SelectionState<Int>()
    @Published var dropTarget: DropTarget?
    @Published var thumbSize: CGFloat = 136
    let thumbnails: ThumbnailStore
    /// Ids being dragged inside the grid (nil when no internal drag is in flight).
    var dragging: Set<Int>?

    struct DropTarget: Equatable {
        let id: Int
        let before: Bool
    }

    init(url: URL, thumbnails: ThumbnailStore? = nil) {
        self.url = url
        self.thumbnails = thumbnails ?? ThumbnailStore()
        switch PDFProbe.probe(url) {
        case .ok(let n):
            history = Undoable(PageArrangement(pageCount: n))
            loadError = nil
        case .failed(let message):
            history = Undoable(PageArrangement(pageCount: 0))
            loadError = message
        }
    }

    var arrangement: PageArrangement { history.current }
    var items: [PageItem] { arrangement.items }
    var order: [Int] { items.map(\.id) }
    var windowTitle: String { "Reorganize Pages — \(url.lastPathComponent)" }
    var canSubmit: Bool { loadError == nil && !items.isEmpty && !arrangement.isUnchanged }
    var hasSelection: Bool { !selection.selected.isEmpty }

    var statusText: String {
        if let loadError { return loadError }
        var parts = ["\(items.count) of \(arrangement.pageCount) pages"]
        if hasSelection { parts.append("\(selection.selected.count) selected") }
        let deleted = arrangement.deletedSources.count
        if deleted > 0 { parts.append("\(deleted) deleted") }
        let rotated = items.filter { $0.rotation != 0 }.count
        if rotated > 0 { parts.append("\(rotated) rotated") }
        if items.isEmpty { parts.append("nothing left to save") }
        return parts.joined(separator: " · ")
    }

    // MARK: Edits

    func click(_ id: Int, kind: ClickKind) { selection.click(id, kind: kind, order: order) }
    func clearSelection() { selection.clear() }
    func selectAll() { selection.selectAll(order) }

    func rotateSelection(by degrees: Int) {
        let ids = selection.selected
        guard !ids.isEmpty else { return }
        history.apply { $0.rotate(ids, by: degrees) }
    }

    func deleteSelection() {
        let ids = selection.selected
        guard !ids.isEmpty else { return }
        // Keep a neighbor selected so repeated ⌫ walks through the document.
        let firstIndex = items.firstIndex { ids.contains($0.id) } ?? 0
        history.apply { $0.delete(ids) }
        let remaining = order
        selection.clear()
        if !remaining.isEmpty { selection.click(remaining[min(firstIndex, remaining.count - 1)], kind: .plain, order: remaining) }
    }

    func move(_ ids: Set<Int>, to destination: Int) {
        history.apply { $0.move(ids, to: destination) }
    }

    /// Drop handler: moves the dragged ids (or the selection if the dragged page is part of it).
    func drop(on target: DropTarget) {
        defer { dragging = nil; dropTarget = nil }
        guard let ids = dragging, !ids.contains(target.id), let index = arrangement.index(of: target.id) else { return }
        move(ids, to: target.before ? index : index + 1)
    }

    func dropAtEnd() {
        defer { dragging = nil; dropTarget = nil }
        guard let ids = dragging else { return }
        move(ids, to: items.count)
    }

    func beginDrag(_ id: Int) {
        if !selection.selected.contains(id) { selection.click(id, kind: .plain, order: order) }
        dragging = selection.selected
    }

    func undo() { step { $0.undo() } }
    func redo() { step { $0.redo() } }

    /// Undo/redo; pages that reappear (an undone delete) become the selection.
    private func step(_ body: (inout Undoable<PageArrangement>) -> Bool) {
        let before = Set(order)
        guard body(&history) else { return }
        let restored = Set(order).subtracting(before)
        if !restored.isEmpty { selection.selected = restored }
        selection.prune(to: order)
    }

    func perform(_ command: OrganizerCommand) -> Bool {
        guard loadError == nil else { return false }
        switch command {
        case .deleteSelection: deleteSelection()
        case .rotateRight: rotateSelection(by: 90)
        case .rotateLeft: rotateSelection(by: -90)
        case .undo: undo()
        case .redo: redo()
        case .selectAll: selectAll()
        case .step(let d): selection.step(d, order: order)
        case .cancel, .submit: return false
        }
        return true
    }

    func payload() -> (inputs: [URL], options: [String: OptionValue])? {
        guard canSubmit else { return nil }
        return ([url], arrangement.options)
    }
}

// MARK: - Split

@MainActor
final class SplitModel: ObservableObject, OrganizerController {
    enum Style: String, CaseIterable, Identifiable {
        case ranges, every
        var id: String { rawValue }
        var title: String { self == .ranges ? "Pick Ranges" : "Every N Pages" }
    }

    let tool: ToolID = "pdf.split"
    let url: URL
    let loadError: String?
    let pageCount: Int
    @Published private(set) var history: Undoable<SplitPlan>
    @Published var selection = SelectionState<Int>()
    @Published var style: Style = .ranges
    @Published var every: Int = 1
    @Published var thumbSize: CGFloat = 120
    let thumbnails: ThumbnailStore

    init(url: URL, thumbnails: ThumbnailStore? = nil) {
        self.url = url
        self.thumbnails = thumbnails ?? ThumbnailStore()
        switch PDFProbe.probe(url) {
        case .ok(let n): pageCount = n; loadError = nil
        case .failed(let m): pageCount = 0; loadError = m
        }
        history = Undoable(SplitPlan(pageCount: pageCount))
    }

    var plan: SplitPlan { history.current }
    var pages: [Int] { pageCount > 0 ? Array(1...pageCount) : [] }
    var windowTitle: String { "Split — \(url.lastPathComponent)" }

    /// The plan as it would be saved: a live selection counts as one more set of parts.
    var previewPlan: SplitPlan { plan.adding(selection.selected) }

    var outputRanges: [ClosedRange<Int>] {
        switch style {
        case .ranges: previewPlan.outputRanges
        case .every: SplitPlan.every(every, pageCount: pageCount)
        }
    }

    var canSubmit: Bool { loadError == nil && !outputRanges.isEmpty }

    /// Index of the output file `page` lands in (for color bands), nil if it's not exported.
    func partIndex(of page: Int) -> Int? {
        outputRanges.firstIndex { $0.contains(page) }
    }

    var statusText: String {
        if let loadError { return loadError }
        let ranges = outputRanges
        if ranges.isEmpty { return "Select pages, then Add Part — or split every N pages." }
        let files = ranges.count == 1 ? "1 PDF" : "\(ranges.count) PDFs"
        let summary = SplitPlan.describe(ranges)
        return "Creates \(files): pages \(summary.count > 90 ? String(summary.prefix(90)) + "…" : summary)"
    }

    func click(_ page: Int, kind: ClickKind) { selection.click(page, kind: kind, order: pages) }

    func addPart() {
        let sel = selection.selected
        guard !sel.isEmpty else { return }
        history.apply { $0.addParts(from: sel) }
        selection.clear()
    }

    func removeSelectedFromParts() {
        let sel = selection.selected
        guard !sel.isEmpty else { return }
        history.apply { $0.remove(pages: sel) }
    }

    func removePart(_ range: ClosedRange<Int>) { history.apply { $0.removePart(range) } }
    func clearParts() { history.apply { $0.clear() } }

    func setIncludeRest(_ on: Bool) { history.apply { $0.includeRest = on } }
    func undo() { history.undo() }
    func redo() { history.redo() }

    func perform(_ command: OrganizerCommand) -> Bool {
        guard loadError == nil else { return false }
        switch command {
        case .deleteSelection: removeSelectedFromParts()
        case .undo: history.undo()
        case .redo: history.redo()
        case .selectAll: selection.selectAll(pages)
        case .step(let d): selection.step(d, order: pages)
        case .rotateLeft, .rotateRight, .cancel, .submit: return false
        }
        return true
    }

    func payload() -> (inputs: [URL], options: [String: OptionValue])? {
        guard canSubmit else { return nil }
        switch style {
        case .ranges: return ([url], SplitPlan.options(ranges: outputRanges))
        case .every: return ([url], SplitPlan.options(every: every))
        }
    }
}

// MARK: - Merge

@MainActor
final class MergeModel: ObservableObject, OrganizerController {
    let tool: ToolID = "pdf.merge"
    @Published private(set) var history: Undoable<MergeList>
    @Published var selection: Set<UUID> = []
    @Published var notice: String?
    let thumbnails: ThumbnailStore

    init(urls: [URL], thumbnails: ThumbnailStore? = nil) {
        self.thumbnails = thumbnails ?? ThumbnailStore()
        let (entries, skipped) = Self.entries(for: urls)
        history = Undoable(MergeList(entries))
        notice = Self.skippedNotice(skipped)
    }

    var list: MergeList { history.current }
    var entries: [MergeEntry] { list.entries }
    var windowTitle: String { "Merge PDFs" }
    var canSubmit: Bool { list.canSubmit }

    var statusText: String {
        let n = entries.count
        if n < 2 { return n == 0 ? "Drop PDFs here to merge them." : "Add at least one more PDF to merge." }
        return "\(n) files · \(list.totalPages) pages total — top to bottom is the page order"
    }

    static func isPDF(_ url: URL) -> Bool {
        FormatCatalog.format(for: url)?.id == "pdf" || url.pathExtension.lowercased() == "pdf"
    }

    /// Reads page counts; drops anything that isn't an openable PDF.
    static func entries(for urls: [URL]) -> ([MergeEntry], [String]) {
        var entries: [MergeEntry] = []
        var skipped: [String] = []
        for url in urls {
            guard isPDF(url) else { skipped.append(url.lastPathComponent); continue }
            switch PDFProbe.probe(url) {
            case .ok(let n): entries.append(MergeEntry(url: url, pageCount: n))
            case .failed: skipped.append(url.lastPathComponent)
            }
        }
        return (entries, skipped)
    }

    static func skippedNotice(_ skipped: [String]) -> String? {
        guard !skipped.isEmpty else { return nil }
        let names = skipped.prefix(3).joined(separator: ", ") + (skipped.count > 3 ? "…" : "")
        return "Skipped \(skipped.count) file\(skipped.count == 1 ? "" : "s") that \(skipped.count == 1 ? "isn't a" : "aren't") readable PDF\(skipped.count == 1 ? "" : "s"): \(names)"
    }

    func add(_ urls: [URL], at index: Int? = nil) {
        let (new, skipped) = Self.entries(for: urls)
        var added = 0
        history.apply { added = $0.add(new, at: index) }
        let dupes = new.count - added
        var notes: [String] = []
        if let s = Self.skippedNotice(skipped) { notes.append(s) }
        if dupes > 0 { notes.append("\(dupes) already in the list") }
        notice = notes.isEmpty ? nil : notes.joined(separator: " · ")
        selection = Set(entries.map(\.id)).intersection(new.map(\.id))
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let ids = Set(offsets.compactMap { entries.indices.contains($0) ? entries[$0].id : nil })
        history.apply { $0.move(ids, to: destination) }
    }

    func shiftSelection(by delta: Int) {
        let ids = selection
        history.apply { $0.shift(ids, by: delta) }
    }

    func removeSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        history.apply { $0.remove(ids) }
        selection = []
    }

    func remove(_ id: UUID) {
        history.apply { $0.remove([id]) }
        selection.remove(id)
    }

    func sortByName() { history.apply { $0.sortByName() } }

    func perform(_ command: OrganizerCommand) -> Bool {
        switch command {
        case .deleteSelection: removeSelection()
        case .undo: history.undo(); selection.formIntersection(entries.map(\.id))
        case .redo: history.redo(); selection.formIntersection(entries.map(\.id))
        case .selectAll: selection = Set(entries.map(\.id))
        case .step, .rotateLeft, .rotateRight, .cancel, .submit: return false
        }
        return true
    }

    func payload() -> (inputs: [URL], options: [String: OptionValue])? {
        guard canSubmit else { return nil }
        return (list.inputs, [:])
    }

    /// Lets the user pick more PDFs.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }
}
