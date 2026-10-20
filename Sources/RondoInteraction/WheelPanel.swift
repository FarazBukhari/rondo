import AppKit
import os

/// Borderless, non-activating floating panel that shows a radial wheel at the cursor and
/// accepts file drops on its slices.
///
/// P1 spike: fixed titles, single ring. W1 replaces the view with the real `WheelView`.
public final class WheelPanel {
    public var onSelect: ((_ sliceIndex: Int, _ title: String, _ urls: [URL]) -> Void)?
    public var onCancel: (() -> Void)?

    private let panel: NSPanel
    private let wheel: SpikeWheelView
    private let diameter: CGFloat = 280

    public var isVisible: Bool { panel.isVisible }

    public init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        wheel = SpikeWheelView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        panel.contentView = wheel
        wheel.onDrop = { [weak self] index, urls in
            guard let self else { return }
            let title = self.wheel.titles[index]
            self.dismiss()
            self.onSelect?(index, title, urls)
        }
    }

    /// Shows the wheel centered on `point` (screen coordinates), clamped to the screen.
    public func present(titles: [String], at point: NSPoint) {
        wheel.titles = titles
        wheel.highlighted = nil
        var origin = NSPoint(x: point.x - diameter / 2, y: point.y - diameter / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX), vf.maxX - diameter)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - diameter)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    public func dismiss() {
        panel.orderOut(nil)
    }

    /// True if the screen point is over the visible wheel (used to ignore drag-end outside).
    public func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }
}

/// Minimal radial drop target. Slice 0 starts at 12 o'clock, clockwise.
final class SpikeWheelView: NSView {
    var titles: [String] = [] { didSet { needsDisplay = true } }
    var highlighted: Int? { didSet { if oldValue != highlighted { needsDisplay = true } } }
    var onDrop: ((Int, [URL]) -> Void)?

    private let log = Logger(subsystem: "com.farazbukhari.rondo", category: "wheel")
    private let innerRadiusRatio: CGFloat = 0.32

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override var isFlipped: Bool { false }

    func sliceIndex(at point: NSPoint) -> Int? {
        guard !titles.isEmpty else { return nil }
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - c.x, dy = point.y - c.y
        let r = hypot(dx, dy)
        let outer = min(bounds.width, bounds.height) / 2
        guard r >= outer * innerRadiusRatio, r <= outer else { return nil }
        // Angle clockwise from 12 o'clock, 0..<2π
        var a = atan2(dx, dy)
        if a < 0 { a += 2 * .pi }
        let step = 2 * CGFloat.pi / CGFloat(titles.count)
        return Int(a / step) % titles.count
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !titles.isEmpty else { return }
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) / 2 - 2
        let inner = outer * innerRadiusRatio
        let step = 360.0 / CGFloat(titles.count)

        for (i, title) in titles.enumerated() {
            // NSBezierPath angles: degrees counter-clockwise from 3 o'clock.
            let start = 90 - CGFloat(i) * step
            let end = start - step
            let path = NSBezierPath()
            path.appendArc(withCenter: c, radius: outer, startAngle: start, endAngle: end, clockwise: true)
            path.appendArc(withCenter: c, radius: inner, startAngle: end, endAngle: start, clockwise: false)
            path.close()
            (i == highlighted ? NSColor.controlAccentColor : NSColor.windowBackgroundColor.withAlphaComponent(0.92)).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            let mid = (start + end) / 2 * .pi / 180
            let labelR = (outer + inner) / 2
            let p = NSPoint(x: c.x + cos(mid) * labelR, y: c.y + sin(mid) * labelR)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: i == highlighted ? NSColor.white : NSColor.labelColor,
            ]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs)
        }

        let hub = NSBezierPath(ovalIn: NSRect(x: c.x - inner + 4, y: c.y - inner + 4, width: (inner - 4) * 2, height: (inner - 4) * 2))
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        hub.fill()
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = sliceIndex(at: convert(sender.draggingLocation, from: nil))
        return highlighted == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = sliceIndex(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        log.notice("drop on slice \(index, privacy: .public): \(urls.map(\.path).joined(separator: ", "), privacy: .public)")
        highlighted = nil
        // Defer so the drag session completes before the callback shows UI.
        DispatchQueue.main.async { self.onDrop?(index, urls) }
        return true
    }
}
