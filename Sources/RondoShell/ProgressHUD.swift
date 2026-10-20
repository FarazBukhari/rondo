import AppKit
import RondoKit
import SwiftUI

/// Floating, non-activating panel listing active and recent jobs from a `JobQueue`.
///
/// - Subscribes in `init`, so create it before the first `submit`.
/// - Shows itself when a job is queued; hides a few seconds after the queue goes idle.
/// - Jobs from one drop are batched (`JobBatcher`); when the batch ends its outputs are revealed
///   together, once, if `shouldReveal()` (default: `Settings.revealInFinder`).
@MainActor
public final class ProgressHUD: NSObject, NSWindowDelegate {
    /// Cancels one job. Default: `queue.cancel(id)`.
    public var onCancel: (UUID) -> Void
    /// Read when a batch completes. Default reads `Settings.load().revealInFinder`.
    public var shouldReveal: () -> Bool = { Settings.load().revealInFinder }
    /// Display title for tool jobs (e.g. `{ registry.tool($0)?.title }`). Falls back to the raw ID.
    public var toolTitle: (ToolID) -> String? = { _ in nil }
    /// Called with every finished job's outputs (after `recents` is updated).
    public var onOutputs: (([URL]) -> Void)?
    /// Seconds the HUD stays up after the queue goes idle (longer when something failed).
    public var idleHideDelay: TimeInterval = 2.5
    public var idleHideDelayAfterFailure: TimeInterval = 8

    public let recents: RecentOutputs
    public var isVisible: Bool { panel.isVisible }

    private let queue: JobQueue
    private let model = HUDModel()
    private var batcher = JobBatcher()
    private let panel: NSPanel
    private var hosting: ClickThroughHostingView<HUDView>!
    private var consumer: Task<Void, Never>?
    private var hideWork: DispatchWorkItem?
    private var userMovedPanel = false
    private var placing = false

    static let width: CGFloat = 340

    public init(queue: JobQueue, recents: RecentOutputs? = nil, onCancel: ((UUID) -> Void)? = nil) {
        self.queue = queue
        self.recents = recents ?? .shared
        self.onCancel = onCancel ?? { id in Task { await queue.cancel(id) } }
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            styleMask: [.titled, .closable, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.title = "Rondo"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let view = HUDView(
            model: model,
            cancel: { [weak self] id in self?.cancel(id) },
            reveal: { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) },
            cancelAll: { [weak self] in self?.cancelAll() },
            clear: { [weak self] in self?.clearFinished() }
        )
        hosting = ClickThroughHostingView(rootView: view)
        panel.contentView = hosting

        let stream = queue.subscribe()
        consumer = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    /// Stops consuming events (the stream ends) and closes the panel.
    public func stop() {
        consumer?.cancel()
        consumer = nil
        panel.orderOut(nil)
    }

    public func show() {
        cancelScheduledHide()
        model.prune()
        resize()
        if !panel.isVisible { place() }
        panel.orderFrontRegardless()
    }

    public func hide() {
        cancelScheduledHide()
        panel.orderOut(nil)
    }

    // MARK: - Events

    func handle(_ event: JobEvent) {
        switch event {
        case .queued(let id, let spec):
            batcher.queued(id, spec: spec)
            model.add(row(id: id, spec: spec))
            show()
        case .started(let id):
            model.update(id) { $0.state = .running }
        case .progress(let id, let value):
            model.update(id) {
                if $0.state == .queued { $0.state = .running }
                $0.progress = max($0.progress, min(max(value, 0), 1))
            }
        case .finished(let id, let outputs):
            model.update(id) {
                $0.state = .finished
                $0.progress = 1
                $0.outputs = outputs
                $0.endedAt = Date()
            }
            if !outputs.isEmpty {
                recents.add(outputs)
                onOutputs?(outputs)
            }
            batchEnded(id, outputs: outputs)
        case .failed(let id, let message):
            model.update(id) {
                $0.state = .failed
                $0.error = message
                $0.endedAt = Date()
            }
            batchEnded(id, outputs: [])
        case .cancelled(let id):
            model.update(id) {
                $0.state = .cancelled
                $0.endedAt = Date()
            }
            batchEnded(id, outputs: [])
        }
        resize()
        if event.isTerminal, model.activeCount == 0 { scheduleHide() }
    }

    private func batchEnded(_ id: UUID, outputs: [URL]) {
        guard let all = batcher.ended(id, outputs: outputs), !all.isEmpty, shouldReveal() else { return }
        let existing = all.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        ShellLog.logger.notice("revealing \(existing.count) output(s)")
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    private func row(id: UUID, spec: JobSpec) -> HUDModel.Row {
        let first = spec.inputs.first
        var name = first?.lastPathComponent ?? "Job"
        if spec.inputs.count > 1 { name += " + \(spec.inputs.count - 1) more" }
        let detail: String
        switch spec.operation {
        case .convert(let to):
            detail = "→ " + (FormatCatalog.format(id: to)?.displayName ?? to.uppercased())
        case .tool(let tool):
            detail = toolTitle(tool) ?? tool.rawValue
        }
        let symbol = first.map { FormatCatalog.kind(for: $0).symbol } ?? FileKind.unknown.symbol
        return HUDModel.Row(id: id, name: name, detail: detail, symbol: symbol)
    }

    // MARK: - Commands

    private func cancel(_ id: UUID) {
        onCancel(id)
    }

    private func cancelAll() {
        for row in model.rows where row.isActive { onCancel(row.id) }
    }

    private func clearFinished() {
        model.removeFinished()
        resize()
        if model.rows.isEmpty { hide() }
    }

    // MARK: - Visibility & layout

    private func scheduleHide() {
        cancelScheduledHide()
        let delay = model.rows.contains { $0.state == .failed && $0.isRecent } ? idleHideDelayAfterFailure : idleHideDelay
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.activeCount == 0 else { return }
            self.panel.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelScheduledHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func resize() {
        let height = HUDView.contentHeight(rowCount: model.rows.count)
        let frame = panel.frame
        let newFrame = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height))
        guard abs(newFrame.height - frame.height) > 0.5 || abs(newFrame.width - frame.width) > 0.5 else { return }
        // Keep the top edge fixed.
        let origin = NSPoint(x: frame.minX, y: frame.maxY - newFrame.height)
        placing = true
        panel.setFrame(NSRect(origin: origin, size: newFrame.size), display: true)
        placing = false
    }

    /// Top-right of the screen under the cursor, below the menu bar — unless the user dragged it.
    private func place() {
        guard !userMovedPanel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        placing = true
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12))
        placing = false
    }

    public func windowDidMove(_ notification: Notification) {
        if !placing, panel.isVisible { userMovedPanel = true }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

/// The HUD never takes key focus; let the first click hit Cancel/Reveal directly.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Model

@MainActor
final class HUDModel: ObservableObject {
    enum State: Equatable {
        case queued, running, finished, failed, cancelled
    }

    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let detail: String
        let symbol: String
        var state: State = .queued
        var progress: Double = 0
        var outputs: [URL] = []
        var error: String?
        var endedAt: Date?

        var isActive: Bool { state == .queued || state == .running }
        var isRecent: Bool { endedAt.map { Date().timeIntervalSince($0) < 60 } ?? true }
    }

    @Published private(set) var rows: [Row] = []
    static let keepFinished = 8

    var activeCount: Int { rows.filter(\.isActive).count }

    func add(_ row: Row) {
        rows.append(row)
        trim()
    }

    func update(_ id: UUID, _ change: (inout Row) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[i])
    }

    func removeFinished() {
        rows.removeAll { !$0.isActive }
    }

    /// Drops finished rows older than a minute.
    func prune() {
        rows.removeAll { !$0.isActive && !$0.isRecent }
        trim()
    }

    private func trim() {
        let finished = rows.filter { !$0.isActive }
        guard finished.count > Self.keepFinished else { return }
        let drop = Set(finished.prefix(finished.count - Self.keepFinished).map(\.id))
        rows.removeAll { drop.contains($0.id) }
    }
}

// MARK: - View

struct HUDView: View {
    @ObservedObject var model: HUDModel
    let cancel: (UUID) -> Void
    let reveal: ([URL]) -> Void
    let cancelAll: () -> Void
    let clear: () -> Void

    static let rowHeight: CGFloat = 50
    static let footerHeight: CGFloat = 34
    static let maxVisibleRows = 6

    static func contentHeight(rowCount: Int) -> CGFloat {
        CGFloat(min(max(rowCount, 1), maxVisibleRows)) * rowHeight + footerHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.rows.isEmpty {
                        Text("No jobs")
                            .foregroundColor(.secondary)
                            .frame(height: Self.rowHeight)
                    }
                    ForEach(model.rows) { row in
                        HUDRowView(row: row, cancel: { cancel(row.id) }, reveal: { reveal(row.outputs) })
                            .frame(height: Self.rowHeight)
                        Divider().opacity(0.4)
                    }
                }
            }
            footer
        }
        .frame(width: ProgressHUD.width)
    }

    private var footer: some View {
        HStack {
            let active = model.activeCount
            Text(active == 0 ? "Idle" : "\(active) job\(active == 1 ? "" : "s") running")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if active > 0 {
                Button("Cancel All", action: cancelAll)
                    .controlSize(.small)
            }
            if model.rows.contains(where: { !$0.isActive }) {
                Button("Clear", action: clear)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.footerHeight)
    }
}

struct HUDRowView: View {
    let row: HUDModel.Row
    let cancel: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol)
                .font(.system(size: 18))
                .frame(width: 24)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                status
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var status: some View {
        switch row.state {
        case .queued:
            ProgressView(value: 0).progressViewStyle(.linear).opacity(0.5)
        case .running:
            ProgressView(value: row.progress).progressViewStyle(.linear)
        case .finished:
            Text(row.outputs.count > 1 ? "Done — \(row.outputs.count) files" : (row.outputs.first?.lastPathComponent ?? "Done"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .failed:
            Text(row.error ?? "Failed")
                .font(.system(size: 11))
                .foregroundColor(.red)
                .lineLimit(2)
                .help(row.error ?? "")
        case .cancelled:
            Text("Cancelled")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch row.state {
        case .queued, .running:
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Cancel")
        case .finished where !row.outputs.isEmpty:
            Button(action: reveal) {
                Image(systemName: "magnifyingglass.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .help("Show in Finder")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        default:
            EmptyView()
        }
    }
}
