import AppKit
import QuickLookThumbnailing
import RondoKit

/// "Float" action: always-on-top shelves that park files so they can be dragged out later.
/// Each `float(urls:)` call opens one shelf (a float group). Chips are drag sources (copy);
/// dropping files on a shelf calls `onOpenWheel` (click-mode wheel). Last position is remembered.
@MainActor
public final class FloatShelf {
    /// Files dropped on a shelf + cursor (AppKit screen coordinates).
    public var onOpenWheel: (([URL], CGPoint) -> Void)?
    public var groupCount: Int { panels.count }

    private var panels: [FloatShelfPanel] = []
    private let defaults: UserDefaults
    static let originKey = "floatShelf.origin.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Opens a new shelf holding `urls` (duplicates removed).
    public func float(urls: [URL]) {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        guard !unique.isEmpty else { return }
        open(with: unique)
    }

    /// Brings every shelf forward; opens an empty drop shelf when none exist.
    public func showAll() {
        if panels.isEmpty {
            open(with: [])
        } else {
            panels.forEach { $0.orderFrontRegardless() }
        }
    }

    public func closeAll() {
        panels.forEach { $0.close() }
    }

    private func open(with urls: [URL]) {
        let panel = FloatShelfPanel(urls: urls)
        panel.onDrop = { [weak self] urls in
            self?.onOpenWheel?(urls, NSEvent.mouseLocation)
        }
        panel.onMoved = { [weak self] origin in
            self?.defaults.set(NSStringFromPoint(origin), forKey: Self.originKey)
        }
        panel.onClose = { [weak self, weak panel] in
            self?.panels.removeAll { $0 === panel }
        }
        panel.setFrameOrigin(initialOrigin(for: panel.frame.size))
        panels.append(panel)
        panel.orderFrontRegardless()
        ShellLog.logger.notice("float shelf opened with \(urls.count) file(s)")
    }

    /// Saved origin (or right-middle of the screen under the cursor), cascaded per open shelf and
    /// clamped to the visible frame.
    private func initialOrigin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: NSPoint
        if let saved = defaults.string(forKey: Self.originKey) {
            origin = NSPointFromString(saved)
        } else {
            origin = NSPoint(x: visible.maxX - size.width - 24, y: visible.midY - size.height / 2)
        }
        let step = CGFloat(panels.count) * 24
        origin.x += step
        origin.y -= step
        return Self.clamp(origin, size: size, to: visible)
    }

    static func clamp(_ origin: NSPoint, size: NSSize, to visible: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height)
        )
    }
}

// MARK: - Panel

@MainActor
final class FloatShelfPanel: NSPanel, NSWindowDelegate {
    var onDrop: (([URL]) -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var onClose: (() -> Void)?

    private(set) var urls: [URL]
    private let content: ShelfContentView

    static let width: CGFloat = 240
    static let chipHeight: CGFloat = 40
    static let footerHeight: CGFloat = 30
    static let maxVisibleChips = 7

    init(urls: [URL]) {
        self.urls = urls
        content = ShelfContentView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.contentHeight(count: urls.count)),
            styleMask: [.titled, .closable, .utilityWindow, .hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        delegate = self

        content.onDrop = { [weak self] urls in self?.onDrop?(urls) }
        content.onRemove = { [weak self] url in self?.remove(url) }
        contentView = content
        reload()
    }

    static func contentHeight(count: Int) -> CGFloat {
        count == 0 ? 90 : CGFloat(min(count, maxVisibleChips)) * chipHeight + footerHeight + 8
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        if urls.isEmpty { close() } else { reload() }
    }

    private func reload() {
        title = urls.isEmpty ? "Float" : "Float — \(urls.count) item\(urls.count == 1 ? "" : "s")"
        content.show(urls)
        let top = frame.maxY
        let newFrame = frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.contentHeight(count: urls.count)))
        setFrame(NSRect(x: frame.minX, y: top - newFrame.height, width: newFrame.width, height: newFrame.height), display: true)
    }

    func windowDidMove(_ notification: Notification) {
        if isVisible { onMoved?(frame.origin) }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - Content (drop target)

@MainActor
final class ShelfContentView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onRemove: ((URL) -> Void)?

    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let footer = DragAllView()
    private let emptyLabel = NSTextField(labelWithString: "Drop files here")
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        addSubview(scroll)

        addSubview(footer)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func show(_ urls: [URL]) {
        list.subviews.forEach { $0.removeFromSuperview() }
        for url in urls {
            let chip = FileChipView(url: url)
            chip.onRemove = { [weak self] u in self?.onRemove?(u) }
            list.addSubview(chip)
        }
        footer.urls = urls
        footer.isHidden = urls.isEmpty
        scroll.isHidden = urls.isEmpty
        emptyLabel.isHidden = !urls.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let footerH = footer.isHidden ? 0 : FloatShelfPanel.footerHeight
        footer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: footerH)
        scroll.frame = NSRect(x: 0, y: footerH, width: bounds.width, height: bounds.height - footerH)
        let w = scroll.contentSize.width
        let h = FloatShelfPanel.chipHeight
        for (i, chip) in list.subviews.enumerated() {
            chip.frame = NSRect(x: 4, y: 4 + CGFloat(i) * h, width: w - 8, height: h)
        }
        list.frame = NSRect(x: 0, y: 0, width: w, height: max(scroll.contentSize.height, CGFloat(list.subviews.count) * h + 8))
        emptyLabel.sizeToFit()
        emptyLabel.frame.origin = NSPoint(x: (bounds.width - emptyLabel.frame.width) / 2, y: (bounds.height - emptyLabel.frame.height) / 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted || list.subviews.isEmpty else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 8, yRadius: 8)
        path.lineWidth = 2
        path.setLineDash([5, 4], count: 2, phase: 0)
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
    }

    // NSDraggingDestination
    private func acceptable(_ sender: NSDraggingInfo) -> [URL]? {
        if let source = sender.draggingSource as? NSView, source.window === window { return nil }   // own chips
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls?.isEmpty ?? true) ? nil : urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptable(sender) != nil else { return [] }
        highlighted = true
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptable(sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let urls = acceptable(sender) else { return false }
        // Let the drag session finish before the wheel takes over.
        DispatchQueue.main.async { [weak self] in self?.onDrop?(urls) }
        return true
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Drag sources

/// Shared drag-out behavior: start a file drag after a small movement; Finder gets `.copy`.
@MainActor
class FileDragSourceView: NSView, NSDraggingSource {
    private var downPoint: NSPoint?

    var dragURLs: [URL] { [] }
    var dragImage: NSImage? { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
    }

    override func mouseUp(with event: NSEvent) {
        downPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        downPoint = nil
        let fm = FileManager.default
        let urls = dragURLs.filter { fm.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.enumerated().map { i, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = dragImage ?? NSWorkspace.shared.icon(forFile: url.path)
            let side: CGFloat = 32
            let offset = CGFloat(min(i, 6)) * 4
            item.setDraggingFrame(NSRect(x: local.x - side / 2 + offset, y: local.y - side / 2 - offset, width: side, height: side), contents: image)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// One parked file: thumbnail + name. Drag out to copy; double-click opens; context menu.
@MainActor
final class FileChipView: FileDragSourceView {
    let url: URL
    var onRemove: ((URL) -> Void)?

    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override var dragURLs: [URL] { [url] }
    override var dragImage: NSImage? { imageView.image }

    init(url: URL) {
        self.url = url
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: FloatShelfPanel.chipHeight))
        wantsLayer = true
        layer?.cornerRadius = 6

        imageView.image = NSWorkspace.shared.icon(forFile: url.path)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        label.stringValue = url.lastPathComponent
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        addSubview(label)
        toolTip = url.path

        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(openFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove from Shelf", action: #selector(remove), keyEquivalent: "").target = self
        self.menu = menu

        loadThumbnail()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let side = bounds.height - 8
        imageView.frame = NSRect(x: 4, y: 4, width: side, height: side)
        label.sizeToFit()
        let x = imageView.frame.maxX + 8
        label.frame = NSRect(x: x, y: (bounds.height - label.frame.height) / 2, width: bounds.width - x - 4, height: label.frame.height)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            openFile()
            return
        }
        super.mouseDown(with: event)
    }

    @objc private func openFile() { NSWorkspace.shared.open(url) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc private func remove() { onRemove?(url) }

    private func loadThumbnail() {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 64, height: 64),
            scale: scale,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let cg = rep?.cgImage else { return }
            let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
            DispatchQueue.main.async { self?.imageView.image = image }
        }
    }
}

/// Footer handle that drags every file on the shelf at once.
@MainActor
final class DragAllView: FileDragSourceView {
    var urls: [URL] = [] {
        didSet { label.stringValue = urls.count > 1 ? "Drag all \(urls.count)" : "Drag to copy" }
    }

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    override var dragURLs: [URL] { urls }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Drag all")
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        toolTip = "Drag all files out of the shelf"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        label.sizeToFit()
        let total = 16 + 6 + label.frame.width
        let x = (bounds.width - total) / 2
        icon.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame.origin = NSPoint(x: x + 22, y: (bounds.height - label.frame.height) / 2)
    }
}
