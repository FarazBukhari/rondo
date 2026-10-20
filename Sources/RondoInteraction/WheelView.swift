import AppKit
import os
import RondoKit

/// Radial wheel: rings of slices (SF Symbol + label) around a hub (file icon, count, cancel).
///
/// Layer-backed, draws in `draw(_:)` with dynamic system colors (light/dark aware). Transparent
/// background — `WheelPanel` puts a blurred disc behind it.
///
/// - `.drag` mode: file-drag destination. Hovering a slice highlights it; dropping returns `.copy`
///   (Finder never moves the source) and fires `onActivate`. Hub / outside reject the drop.
/// - `.click` mode: hover highlights, click (or press-drag-release) on a slice activates, click on the
///   hub or outside the rings cancels. Arrow keys / Enter / Esc when first responder.
@MainActor
public final class WheelView: NSView {
    public enum Mode: Sendable { case drag, click }

    /// Hub feedback state.
    enum HubState: Equatable { case normal, cancel, applied }

    public private(set) var model: WheelModel
    public var mode: Mode = .drag { didSet { updateTracking() } }
    /// Files the wheel acts on (hub icon + count; fallback URLs when a drop carries none).
    public var inputs: [URL] = [] { didSet { inputsChanged() } }

    /// Slice chosen. `urls` = files from the drop pasteboard, or `inputs` for click/keyboard.
    public var onActivate: ((WheelItem, [URL]) -> Void)?
    public var onCancel: (() -> Void)?

    var hubState: HubState = .normal { didSet { if hubState != oldValue { needsDisplay = true } } }

    private let log = Logger(subsystem: "com.farazbukhari.rondo", category: "wheel")
    private var hubIcon: NSImage?
    private var symbolCache: [String: NSImage] = [:]
    private var trackingArea: NSTrackingArea?
    private var pressHit: WheelHit?
    /// The wheel opens under the cursor; the hub only reads as "Cancel" after the cursor has left it once.
    private var hubCancelArmed = false

    public init(model: WheelModel, mode: Mode = .drag) {
        self.model = model
        self.mode = mode
        super.init(frame: NSRect(x: 0, y: 0, width: model.diameter, height: model.diameter))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Rondo wheel")
        updateTracking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    public func setModel(_ model: WheelModel) {
        self.model = model
        hubState = .normal
        hubCancelArmed = false
        setFrameSize(NSSize(width: model.diameter, height: model.diameter))
        needsDisplay = true
    }

    /// Marks the wheel as applied (keyboard Enter during a drag): shows a check, swallows nothing.
    func showApplied() {
        hubState = .applied
        model.select(nil)
        needsDisplay = true
    }

    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Geometry

    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    func hit(atViewPoint p: NSPoint) -> WheelHit {
        model.hitTest(CGPoint(x: p.x - center.x, y: p.y - center.y))
    }

    /// Applies a hit as hover/drag-over highlight. Returns the slice item, if any.
    @discardableResult
    func highlight(_ hit: WheelHit?) -> WheelItem? {
        guard hubState != .applied else { return nil }
        var newSelection: WheelSlot?
        var newHub = HubState.normal
        switch hit {
        case .slice(let slot):
            newSelection = slot
            hubCancelArmed = true
        case .hub:
            if hubCancelArmed { newHub = .cancel }
        case .outside:
            hubCancelArmed = true
        case nil:
            break
        }
        if newSelection != model.selection {
            model.select(newSelection)
            needsDisplay = true
        }
        hubState = newHub
        return model.selectedItem
    }

    // MARK: - Keyboard

    /// Feeds one key (from `keyDown` or the panel's global key monitor during a drag).
    @discardableResult
    func handleKey(_ key: WheelKey) -> WheelNavResult {
        guard hubState != .applied else { return .ignored }
        let result = model.handle(key)
        switch result {
        case .moved:
            hubState = .normal
            needsDisplay = true
        case .apply(let item):
            activate(item, urls: inputs)
        case .cancel:
            onCancel?()
        case .ignored:
            break
        }
        return result
    }

    public override func keyDown(with event: NSEvent) {
        if let key = WheelKey(keyCode: event.keyCode) {
            handleKey(key)
        } else {
            super.keyDown(with: event)
        }
    }

    public override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private func activate(_ item: WheelItem, urls: [URL]) {
        log.notice("wheel select \(item.id, privacy: .public) for \(urls.count, privacy: .public) file(s)")
        onActivate?(item, urls)
    }

    // MARK: - Mouse (click mode)

    private func updateTracking() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard mode == .click else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        guard mode == .click else { return }
        highlight(hit(atViewPoint: convert(event.locationInWindow, from: nil)))
    }

    public override func mouseExited(with event: NSEvent) {
        guard mode == .click else { return }
        highlight(nil)
    }

    public override func mouseDown(with event: NSEvent) {
        guard mode == .click else { return }
        let h = hit(atViewPoint: convert(event.locationInWindow, from: nil))
        if h == .outside {
            onCancel?()
            return
        }
        pressHit = h
        highlight(h)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard mode == .click, pressHit != nil else { return }
        highlight(hit(atViewPoint: convert(event.locationInWindow, from: nil)))
    }

    public override func mouseUp(with event: NSEvent) {
        guard mode == .click, pressHit != nil else { return }
        pressHit = nil
        switch hit(atViewPoint: convert(event.locationInWindow, from: nil)) {
        case .slice(let slot):
            if let item = model.item(at: slot) { activate(item, urls: inputs) }
        case .hub, .outside:
            onCancel?()
        }
    }

    // MARK: - NSDraggingDestination (drag mode)

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let item = highlight(hit(atViewPoint: convert(sender.draggingLocation, from: nil)))
        return item == nil ? [] : .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight(nil)
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard hubState != .applied, case .slice = hit(atViewPoint: convert(sender.draggingLocation, from: nil)) else {
            return false
        }
        return true
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard case .slice(let slot) = hit(atViewPoint: convert(sender.draggingLocation, from: nil)),
              let item = model.item(at: slot) else { return false }
        let dropped = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let urls = dropped.isEmpty ? inputs : dropped
        guard !urls.isEmpty else { return false }
        // Defer so the drag session completes (Finder gets `.copy`) before callbacks show UI.
        DispatchQueue.main.async { [weak self] in self?.activate(item, urls: urls) }
        return true
    }

    // MARK: - Drawing

    private func inputsChanged() {
        if let first = inputs.first {
            hubIcon = NSWorkspace.shared.icon(forFile: first.path)
        } else {
            hubIcon = nil
        }
        needsDisplay = true
    }

    private enum Palette {
        static var sliceFill: NSColor { NSColor.labelColor.withAlphaComponent(0.045) }
        static var sliceFillAlt: NSColor { NSColor.labelColor.withAlphaComponent(0.085) }
        static var separator: NSColor { NSColor.labelColor.withAlphaComponent(0.14) }
        static var rim: NSColor { NSColor.labelColor.withAlphaComponent(0.18) }
        static var highlight: NSColor { NSColor.controlAccentColor }
        static var onHighlight: NSColor { .white }
        static var text: NSColor { .labelColor }
        static var secondary: NSColor { .secondaryLabelColor }
        static var hubFill: NSColor { NSColor.textBackgroundColor.withAlphaComponent(0.55) }
        static var cancel: NSColor { .systemRed }
        static var applied: NSColor { .systemGreen }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = center

        if model.isEmpty {
            drawEmptyRing(center: c)
        }

        for slot in model.allSlots {
            drawSlice(slot, center: c, in: ctx)
        }

        // Outer rim of each ring.
        for ring in 0..<max(model.ringCount, 1) {
            let r = model.radii(ring: ring)
            let rim = NSBezierPath(ovalIn: NSRect(x: c.x - r.outer, y: c.y - r.outer, width: r.outer * 2, height: r.outer * 2))
            rim.lineWidth = 1
            Palette.rim.setStroke()
            rim.stroke()
        }

        drawHub(center: c, in: ctx)
    }

    private func drawEmptyRing(center c: CGPoint) {
        let r = model.radii(ring: 0)
        let band = NSBezierPath()
        band.appendOval(in: NSRect(x: c.x - r.outer, y: c.y - r.outer, width: r.outer * 2, height: r.outer * 2))
        band.appendOval(in: NSRect(x: c.x - r.inner, y: c.y - r.inner, width: r.inner * 2, height: r.inner * 2))
        band.windingRule = .evenOdd
        Palette.sliceFill.setFill()
        band.fill()
        let text = "No options for \(inputs.count == 1 ? "this file" : "these files")"
        drawLabel(text, at: CGPoint(x: c.x, y: c.y + (r.inner + r.outer) / 2), maxWidth: r.outer * 1.4,
                  font: .systemFont(ofSize: 11, weight: .medium), color: Palette.secondary, maxLines: 1)
    }

    private func slicePath(_ arc: SliceArc, center c: CGPoint) -> NSBezierPath {
        // NSBezierPath: degrees counter-clockwise from 3 o'clock. Ours: radians clockwise from 12.
        func deg(_ a: CGFloat) -> CGFloat { 90 - a * 180 / .pi }
        let path = NSBezierPath()
        if arc.sweep >= 2 * .pi - 0.0001 {
            path.appendOval(in: NSRect(x: c.x - arc.outerRadius, y: c.y - arc.outerRadius, width: arc.outerRadius * 2, height: arc.outerRadius * 2))
            path.appendOval(in: NSRect(x: c.x - arc.innerRadius, y: c.y - arc.innerRadius, width: arc.innerRadius * 2, height: arc.innerRadius * 2))
            path.windingRule = .evenOdd
            return path
        }
        path.appendArc(withCenter: c, radius: arc.outerRadius, startAngle: deg(arc.startAngle), endAngle: deg(arc.endAngle), clockwise: true)
        path.appendArc(withCenter: c, radius: arc.innerRadius, startAngle: deg(arc.endAngle), endAngle: deg(arc.startAngle), clockwise: false)
        path.close()
        return path
    }

    private func drawSlice(_ slot: WheelSlot, center c: CGPoint, in ctx: CGContext) {
        guard let item = model.item(at: slot) else { return }
        let arc = model.arc(for: slot)
        let selected = model.selection == slot
        let path = slicePath(arc, center: c)

        if selected {
            Palette.highlight.setFill()
        } else {
            (slot.index % 2 == 0 ? Palette.sliceFill : Palette.sliceFillAlt).setFill()
        }
        path.fill()

        // Radial separator at the slice's start edge.
        if model.rings[slot.ring].count > 1 {
            let a = arc.startAngle
            let p0 = WheelModel.point(angle: a, radius: arc.innerRadius)
            let p1 = WheelModel.point(angle: a, radius: arc.outerRadius)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: c.x + p0.x, y: c.y + p0.y))
            line.line(to: NSPoint(x: c.x + p1.x, y: c.y + p1.y))
            line.lineWidth = 1
            Palette.separator.setStroke()
            line.stroke()
        }

        // Icon above, label below, centered on the slice's mid point.
        let mid = arc.point(atRadius: arc.midRadius)
        let anchor = CGPoint(x: c.x + mid.x, y: c.y + mid.y)
        let fg = selected ? Palette.onHighlight : Palette.text
        let iconSide: CGFloat = 20
        if let icon = symbol(item.symbol) {
            let size = fitted(icon.size, into: iconSide)
            let rect = NSRect(x: anchor.x - size.width / 2, y: anchor.y + 2, width: size.width, height: size.height)
            drawTinted(icon, in: rect, color: fg, ctx: ctx)
        }
        let maxWidth = min(arc.midChord - 8, model.geometry.ringWidth * 1.45)
        drawLabel(item.title, at: CGPoint(x: anchor.x, y: anchor.y - 9), maxWidth: maxWidth,
                  font: .systemFont(ofSize: 10.5, weight: selected ? .semibold : .medium), color: fg, maxLines: 2)
    }

    private func drawHub(center c: CGPoint, in ctx: CGContext) {
        let r = model.geometry.hubRadius
        let hubRect = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let hub = NSBezierPath(ovalIn: hubRect.insetBy(dx: 1, dy: 1))
        switch hubState {
        case .normal: Palette.hubFill.setFill()
        case .cancel: Palette.cancel.withAlphaComponent(0.22).setFill()
        case .applied: Palette.applied.withAlphaComponent(0.22).setFill()
        }
        hub.fill()
        hub.lineWidth = 1
        Palette.rim.setStroke()
        hub.stroke()

        let caption: String
        let captionColor: NSColor
        switch hubState {
        case .cancel:
            drawHubSymbol("xmark.circle.fill", color: Palette.cancel, center: c, ctx: ctx)
            caption = "Cancel"
            captionColor = Palette.cancel
        case .applied:
            drawHubSymbol("checkmark.circle.fill", color: Palette.applied, center: c, ctx: ctx)
            caption = "Queued"
            captionColor = Palette.secondary
        case .normal:
            drawHubIcons(center: c)
            if let item = model.selectedItem {
                caption = item.title
                captionColor = Palette.text
            } else {
                caption = inputs.count > 1 ? "\(inputs.count) files" : Self.title(for: model.kind)
                captionColor = Palette.secondary
            }
        }
        drawLabel(caption, at: CGPoint(x: c.x, y: c.y - 15), maxWidth: r * 1.7,
                  font: .systemFont(ofSize: 10, weight: .semibold), color: captionColor, maxLines: 1)
    }

    private func drawHubIcons(center c: CGPoint) {
        let side: CGFloat = 34
        let origin = NSPoint(x: c.x - side / 2, y: c.y - 6)
        guard let icon = hubIcon else {
            if let doc = symbol(FileKind.unknown.symbol) {
                drawTinted(doc, in: NSRect(x: c.x - 10, y: c.y - 2, width: 20, height: 22), color: Palette.secondary,
                           ctx: NSGraphicsContext.current!.cgContext)
            }
            return
        }
        if inputs.count > 1 {
            // Stacked look for batches.
            icon.draw(in: NSRect(x: origin.x + 5, y: origin.y + 3, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 0.55)
        }
        icon.draw(in: NSRect(x: origin.x - (inputs.count > 1 ? 2 : 0), y: origin.y, width: side, height: side))
        if inputs.count > 1 {
            let badge = "\(inputs.count)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = (badge as NSString).size(withAttributes: attrs)
            let w = max(size.width + 8, 16)
            let rect = NSRect(x: c.x + side / 2 - w / 2 + 2, y: origin.y + side - 12, width: w, height: 16)
            Palette.highlight.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            (badge as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
    }

    private func drawHubSymbol(_ name: String, color: NSColor, center c: CGPoint, ctx: CGContext) {
        guard let image = symbol(name, pointSize: 24) else { return }
        let size = fitted(image.size, into: 28)
        drawTinted(image, in: NSRect(x: c.x - size.width / 2, y: c.y - 3, width: size.width, height: size.height), color: color, ctx: ctx)
    }

    private func drawLabel(_ text: String, at point: CGPoint, maxWidth: CGFloat, font: NSFont, color: NSColor, maxLines: Int) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = maxLines == 1 ? .byTruncatingTail : .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let width = max(maxWidth, 24)
        let maxRect = NSSize(width: width, height: lineHeight * CGFloat(maxLines))
        let s = text as NSString
        let bounds = s.boundingRect(with: maxRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        let h = min(ceil(bounds.height), maxRect.height)
        // First line is vertically centered on `point.y`; extra lines grow downward.
        let rect = NSRect(x: point.x - width / 2, y: point.y - h + lineHeight / 2, width: width, height: h)
        s.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    private func symbol(_ name: String, pointSize: CGFloat = 17) -> NSImage? {
        let key = "\(name)@\(pointSize)"
        if let cached = symbolCache[key] { return cached }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        let image = base?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        if let image { symbolCache[key] = image }
        return image
    }

    private func fitted(_ size: NSSize, into side: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: side, height: side) }
        let scale = min(side / size.width, side / size.height, 1.4)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }

    /// Draws a template symbol filled with `color` (resolved in the view's appearance).
    private func drawTinted(_ image: NSImage, in rect: NSRect, color: NSColor, ctx: CGContext) {
        ctx.saveGState()
        ctx.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func title(for kind: WheelKind) -> String {
        switch kind {
        case .convert: "Convert"
        case .tools: "Tools"
        case .actions: "Actions"
        }
    }
}
