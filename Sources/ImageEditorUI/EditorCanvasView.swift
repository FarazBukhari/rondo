import AppKit
import SwiftUI

/// Image canvas: draws the panel's proxy image + overlays and turns mouse/trackpad input into model calls.
/// Flipped (top-left origin) so view points match `CanvasTransform`.
@MainActor
final class EditorCanvasView: NSView {
    var model: ImageEditorModel
    private var spaceDown = false
    private var panningDrag = false

    init(model: ImageEditorModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let size = bounds.size
        guard model.canvasSize != size else { return }
        // Not during SwiftUI's update pass.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.canvasSize != size else { return }
            self.model.canvasSize = size
        }
    }

    // MARK: Drawing

    static let canvasBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.86, green: 0.86, blue: 0.88, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Self.canvasBackground.cgColor)
        ctx.fill(bounds)
        guard let image = model.displayImage else { return }
        let t = model.transform(viewSize: bounds.size)
        let frame = t.imageFrame

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 12, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(frame)
        ctx.restoreGState()
        if model.displayHasAlpha { drawCheckerboard(ctx, frame: frame) }

        ctx.saveGState()
        ctx.clip(to: frame)
        ctx.concatenate(t.bottomLeftImageToView)
        // Past ~2 screen points per proxy pixel, show pixels crisply.
        ctx.interpolationQuality = t.scale / max(model.proxyScale, 0.0001) > 2 ? .none : .high
        ctx.draw(image, in: CGRect(origin: .zero, size: t.imageSize))
        ctx.restoreGState()

        switch model.panel {
        case .crop: drawCrop(ctx, t)
        case .annotate: drawAnnotations(ctx, t)
        case .redact: drawRegions(ctx, t)
        case .adjust, .background: break
        }
    }

    private func drawCheckerboard(_ ctx: CGContext, frame: CGRect) {
        let visible = frame.intersection(bounds)
        guard !visible.isNull else { return }
        let cell: CGFloat = 8
        ctx.saveGState()
        ctx.clip(to: visible)
        ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
        ctx.fill(visible)
        ctx.setFillColor(NSColor(white: 0.80, alpha: 1).cgColor)
        let x0 = frame.minX + floor((visible.minX - frame.minX) / cell) * cell
        let y0 = frame.minY + floor((visible.minY - frame.minY) / cell) * cell
        var y = y0
        while y < visible.maxY {
            var x = x0
            while x < visible.maxX {
                let ix = Int(((x - frame.minX) / cell).rounded()), iy = Int(((y - frame.minY) / cell).rounded())
                if (ix + iy) % 2 == 0 { ctx.fill(CGRect(x: x, y: y, width: cell, height: cell)) }
                x += cell
            }
            y += cell
        }
        ctx.restoreGState()
    }

    private func drawCrop(_ ctx: CGContext, _ t: CanvasTransform) {
        let frame = t.imageFrame
        let r = t.toView(model.crop.rect)
        // Dim outside the selection.
        ctx.saveGState()
        ctx.addRect(frame)
        ctx.addRect(r)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
        // Thirds grid.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(0.75)
        for i in 1...2 {
            let fx = r.minX + r.width * CGFloat(i) / 3, fy = r.minY + r.height * CGFloat(i) / 3
            ctx.strokeLineSegments(between: [CGPoint(x: fx, y: r.minY), CGPoint(x: fx, y: r.maxY),
                                             CGPoint(x: r.minX, y: fy), CGPoint(x: r.maxX, y: fy)])
        }
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(r)
        // Corner brackets + edge ticks.
        ctx.setLineWidth(4)
        ctx.setLineCap(.square)
        let arm = min(18, r.width / 3, r.height / 3)
        for h in RectHandle.allCases {
            let p = h.point(on: r)
            ctx.beginPath()
            switch h {
            case .topLeft: ctx.addLines(between: [CGPoint(x: p.x, y: p.y + arm), p, CGPoint(x: p.x + arm, y: p.y)])
            case .topRight: ctx.addLines(between: [CGPoint(x: p.x - arm, y: p.y), p, CGPoint(x: p.x, y: p.y + arm)])
            case .bottomRight: ctx.addLines(between: [CGPoint(x: p.x, y: p.y - arm), p, CGPoint(x: p.x - arm, y: p.y)])
            case .bottomLeft: ctx.addLines(between: [CGPoint(x: p.x + arm, y: p.y), p, CGPoint(x: p.x, y: p.y - arm)])
            case .top, .bottom: ctx.addLines(between: [CGPoint(x: p.x - arm / 2, y: p.y), CGPoint(x: p.x + arm / 2, y: p.y)])
            case .left, .right: ctx.addLines(between: [CGPoint(x: p.x, y: p.y - arm / 2), CGPoint(x: p.x, y: p.y + arm / 2)])
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawAnnotations(_ ctx: CGContext, _ t: CanvasTransform) {
        ctx.saveGState()
        ctx.concatenate(t.bottomLeftImageToView)
        ShapeRenderer.draw(model.annotations, in: ctx, canvasHeight: t.imageSize.height)
        ctx.restoreGState()
        if let s = model.selectedAnnotation {
            let r = t.toView(ShapeRenderer.bounds(of: s)).insetBy(dx: -4, dy: -4)
            dashedOutline(ctx, r)
        }
    }

    private func drawRegions(_ ctx: CGContext, _ t: CanvasTransform) {
        for (i, region) in model.redact.regions.enumerated() {
            let r = t.toView(region)
            dashedOutline(ctx, r)
            if i == model.selectedRegion { drawHandles(ctx, r) }
        }
    }

    private func dashedOutline(_ ctx: CGContext, _ r: CGRect) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.stroke(r)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(r)
        ctx.restoreGState()
    }

    private func drawHandles(_ ctx: CGContext, _ r: CGRect) {
        ctx.saveGState()
        for h in RectHandle.allCases {
            let p = h.point(on: r)
            let box = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(box)
        }
        ctx.restoreGState()
    }

    // MARK: Mouse

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        panningDrag = spaceDown
        model.pointerDown(at: point(e), viewSize: bounds.size, panning: spaceDown)
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        model.pointerDragged(to: point(e), viewSize: bounds.size)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        model.pointerUp(at: point(e), viewSize: bounds.size)
        panningDrag = false
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func otherMouseDown(with e: NSEvent) {
        model.pointerDown(at: point(e), viewSize: bounds.size, panning: true)
    }

    override func otherMouseDragged(with e: NSEvent) { mouseDragged(with: e) }
    override func otherMouseUp(with e: NSEvent) { mouseUp(with: e) }

    override func scrollWheel(with e: NSEvent) {
        let p = point(e)
        if e.modifierFlags.contains(.command) || !e.hasPreciseScrollingDeltas {
            // Mouse wheel / ⌘-scroll zooms around the pointer.
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
            model.zoom(by: exp(dy * 0.01), anchor: p, viewSize: bounds.size)
        } else {
            model.panBy(CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY))
        }
        needsDisplay = true
    }

    override func magnify(with e: NSEvent) {
        model.zoom(by: 1 + e.magnification, anchor: point(e), viewSize: bounds.size)
        needsDisplay = true
    }

    override func smartMagnify(with e: NSEvent) {
        if abs(model.zoom - 1) < 0.01 {
            model.zoom(by: 2, anchor: point(e), viewSize: bounds.size)
        } else {
            model.zoomToFit()
        }
        needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 49:   // space → hand tool while held
            if !spaceDown { spaceDown = true; window?.invalidateCursorRects(for: self) }
        case 51, 117:   // delete, forward delete
            model.deleteSelection()
            needsDisplay = true
        case 53:   // esc: abort a drag first; otherwise let the window cancel the editor
            if model.isDragging { model.cancelDrag(); needsDisplay = true } else { super.keyDown(with: e) }
        default:
            super.keyDown(with: e)
        }
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 {
            spaceDown = false
            window?.invalidateCursorRects(for: self)
        } else {
            super.keyUp(with: e)
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        if spaceDown || panningDrag || model.panel == .background {
            cursor = .openHand
        } else {
            switch model.panel {
            case .crop, .redact: cursor = .crosshair
            case .annotate: cursor = model.annotateTool == .select ? .arrow : (model.annotateTool == .text ? .iBeam : .crosshair)
            case .adjust, .background: cursor = .arrow
            }
        }
        addCursorRect(bounds, cursor: cursor)
    }
}

/// SwiftUI wrapper. The parent observes the model, so every published change lands in `updateNSView`.
struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var model: ImageEditorModel

    func makeNSView(context: Context) -> EditorCanvasView { EditorCanvasView(model: model) }

    func updateNSView(_ view: EditorCanvasView, context: Context) {
        view.model = model
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}
