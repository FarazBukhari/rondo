import Combine
import CoreGraphics
import Foundation
import RondoKit

/// Editor panels, one per editor-backed image tool.
public enum EditorPanel: String, CaseIterable, Identifiable, Sendable {
    case crop, adjust, annotate, redact, background

    public var id: String { rawValue }
    public var toolID: ToolID { ToolID("image.\(rawValue)") }

    public init?(tool: ToolID) {
        guard tool.rawValue.hasPrefix("image.") else { return nil }
        self.init(rawValue: String(tool.rawValue.dropFirst("image.".count)))
    }

    public var title: String {
        switch self {
        case .crop: "Crop"
        case .adjust: "Adjust"
        case .annotate: "Annotate"
        case .redact: "Redact"
        case .background: "Background"
        }
    }

    public var symbol: String {
        switch self {
        case .crop: "crop"
        case .adjust: "slider.horizontal.3"
        case .annotate: "pencil.tip.crop.circle"
        case .redact: "eye.slash"
        case .background: "square.fill.on.square"
        }
    }
}

public enum AnnotateTool: String, CaseIterable, Identifiable, Sendable {
    case select, arrow, line, rect, ellipse, freehand, highlight, text

    public var id: String { rawValue }

    public var kind: AnnotationKind? {
        switch self {
        case .select: nil
        case .arrow: .arrow
        case .line: .line
        case .rect: .rect
        case .ellipse: .ellipse
        case .freehand: .freehand
        case .highlight: .highlight
        case .text: .text
        }
    }

    public var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rect: "Box"
        case .ellipse: "Oval"
        case .freehand: "Pen"
        case .highlight: "Highlight"
        case .text: "Text"
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .freehand: "scribble"
        case .highlight: "highlighter"
        case .text: "textformat"
        }
    }
}

/// What the editor hands back: one tool + its explicit options.
public struct EditorSubmission: Equatable, Sendable {
    public let tool: ToolID
    public let options: [String: OptionValue]
}

/// All editor state. Geometry is kept in full-resolution source pixels; the proxy is only for drawing.
@MainActor
public final class ImageEditorModel: ObservableObject {
    public enum LoadState: Equatable { case loading, ready, failed(String) }

    enum Drag {
        case cropNew(anchor: CGPoint, previous: CGRect, fromView: CGPoint)
        case cropResize(RectHandle, start: CGRect)
        case cropMove(start: CGRect, from: CGPoint)
        case annotationNew(UUID, anchor: CGPoint, fromView: CGPoint)
        case annotationMove(UUID, start: Annotation, from: CGPoint, created: Bool)
        case regionNew(Int, anchor: CGPoint, fromView: CGPoint)
        case regionResize(Int, RectHandle, start: CGRect)
        case regionMove(Int, start: CGRect, from: CGPoint)
        case pan(start: CGPoint, fromView: CGPoint)
        case compare
    }

    struct UndoState { var annotations: [Annotation]; var regions: [CGRect] }

    /// Handle / hit tolerance and minimum new-shape size, in view points.
    static let handleTolerance: CGFloat = 8
    static let minDrag: CGFloat = 3

    public let url: URL
    @Published public var panel: EditorPanel { didSet { if oldValue != panel { drag = nil; schedulePreview() } } }
    @Published public private(set) var loadState: LoadState = .loading
    @Published public private(set) var proxy: ImageProxy?

    // View
    @Published public var zoom: CGFloat = 1
    @Published public var pan: CGPoint = .zero
    /// Last canvas size reported by the canvas view (zoom buttons need it).
    @Published public var canvasSize = CGSize(width: 760, height: 560)

    // Crop
    @Published public var crop = CropState(sourceSize: .zero) {
        didSet { if crop.orientation != oldValue.orientation { updateOrientedPreview() } }
    }
    @Published public private(set) var orientedPreview: CGImage?

    // Adjust
    @Published public var adjust = AdjustSettings() { didSet { if adjust != oldValue { schedulePreview() } } }
    @Published public var showOriginal = false
    @Published public private(set) var adjustPreview: CGImage?
    private var adjustPreviewFor: AdjustSettings?

    // Annotate
    @Published public var annotations: [Annotation] = []
    @Published public var selectedAnnotationID: UUID?
    @Published public var annotateTool: AnnotateTool = .arrow { didSet { if annotateTool != oldValue { selectedAnnotationID = nil } } }
    /// Template for new shapes (color, line width, fill, font size).
    @Published public var annotationStyle = Annotation(kind: .rect)
    /// Bumped when a new text shape wants keyboard focus in the inspector.
    @Published public private(set) var focusTextRequest = 0

    // Redact
    @Published public var redact = RedactSettings() { didSet { if redact != oldValue { schedulePreview() } } }
    @Published public var selectedRegion: Int?
    @Published public private(set) var redactPreview: CGImage?
    private var redactPreviewFor: RedactSettings?

    // Background
    @Published public var background = BackgroundSettings() { didSet { if background != oldValue { schedulePreview() } } }
    @Published public private(set) var backgroundPreview: CGImage?
    @Published public private(set) var backgroundError: String?
    private var backgroundPreviewFor: BackgroundSettings?
    private var liftedSubject: CGImage?

    @Published private var undoStack: [UndoState] = []
    @Published public private(set) var finished = false
    /// Called exactly once: with a submission on Save, nil on cancel/close.
    public var onFinish: ((EditorSubmission?) -> Void)?

    private var drag: Drag?
    private var renderTask: Task<Void, Never>?
    private var renderDirty = false

    public init(url: URL, tool: ToolID) {
        self.url = url
        self.panel = EditorPanel(tool: tool) ?? .crop
        if EditorPanel(tool: tool) == nil { editorLog.notice("unknown tool \(tool.rawValue, privacy: .public); opening Crop") }
    }

    /// Ready-to-edit model (tests, snapshots).
    public convenience init(url: URL, tool: ToolID, proxy: ImageProxy) {
        self.init(url: url, tool: tool)
        setProxy(proxy)
    }

    public func load(tools: ToolLocator = ToolLocator()) async {
        do {
            setProxy(try await ProxyLoader.load(url, tools: tools))
        } catch {
            editorLog.error("load failed for \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            loadState = .failed(error.localizedDescription)
        }
    }

    public func setProxy(_ p: ImageProxy) {
        proxy = p
        crop = CropState(sourceSize: p.sourceSize)
        orientedPreview = p.image
        let long = max(p.sourceSize.width, p.sourceSize.height)
        annotationStyle.lineWidth = Double(max(2, (long / 200).rounded()))
        annotationStyle.fontSize = Double(max(14, (long / 16).rounded()))
        loadState = .ready
        schedulePreview()
    }

    public var sourceSize: CGSize { proxy?.sourceSize ?? .zero }
    public var proxyScale: CGFloat { proxy?.scale ?? 1 }

    // MARK: Display

    /// Full-resolution size of what the canvas shows for the current panel.
    public var canvasImageSize: CGSize {
        switch panel {
        case .crop: crop.bounds
        case .background: background.outputSize(for: sourceSize)
        default: sourceSize
        }
    }

    /// Proxy-resolution image for the current panel (stretched over `canvasImageSize` when drawn).
    public var displayImage: CGImage? {
        guard let proxy else { return nil }
        switch panel {
        case .crop: return orientedPreview ?? proxy.image
        case .adjust: return showOriginal ? proxy.image : (adjustPreview ?? proxy.image)
        case .annotate: return proxy.image
        case .redact: return redactPreview ?? proxy.image
        case .background: return backgroundPreview ?? proxy.image
        }
    }

    /// Whether the canvas should paint a transparency checkerboard under the image.
    public var displayHasAlpha: Bool {
        if panel == .background { return background.color == nil || background.mode == .remove || (background.color?.isOpaque == false) }
        return proxy?.hasAlpha ?? false
    }

    public func transform(viewSize: CGSize) -> CanvasTransform {
        CanvasTransform(viewSize: viewSize, imageSize: canvasImageSize, zoom: zoom, pan: pan)
    }

    public var transform: CanvasTransform { transform(viewSize: canvasSize) }

    /// View points per full-resolution pixel ×100.
    public var zoomPercent: Int { Int((transform.scale * 100).rounded()) }

    public func zoom(by factor: CGFloat, anchor: CGPoint? = nil, viewSize: CGSize? = nil) {
        let size = viewSize ?? canvasSize
        let t = transform(viewSize: size).zoomed(by: factor, anchor: anchor ?? CGPoint(x: size.width / 2, y: size.height / 2))
        zoom = t.zoom
        pan = t.pan
    }

    public func zoomToFit() { zoom = 1; pan = .zero }

    public func zoomToActualSize() {
        zoom = min(max(transform.actualSizeZoom, CanvasTransform.zoomRange.lowerBound), CanvasTransform.zoomRange.upperBound)
        pan = .zero
    }

    public func panBy(_ d: CGSize) { pan = CGPoint(x: pan.x + d.width, y: pan.y + d.height) }

    // MARK: Pointer (view coordinates, top-left origin)

    public var isDragging: Bool { drag != nil }

    public func pointerDown(at v: CGPoint, viewSize: CGSize, panning: Bool = false) {
        guard proxy != nil, !finished else { return }
        let t = transform(viewSize: viewSize)
        let p = t.toImage(v), tol = t.imageLength(Self.handleTolerance)
        if panning || panel == .background {
            drag = .pan(start: pan, fromView: v)
            return
        }
        switch panel {
        case .crop:
            if let h = CropMath.handle(at: p, on: crop.rect, tolerance: tol) {
                drag = .cropResize(h, start: crop.rect)
            } else if crop.rect.contains(p) && !crop.isFullFrame {
                drag = .cropMove(start: crop.rect, from: p)
            } else {
                drag = .cropNew(anchor: clamped(p, to: crop.bounds), previous: crop.rect, fromView: v)
            }
        case .adjust:
            showOriginal = true
            drag = .compare
        case .annotate:
            annotateDown(p, view: v, tolerance: tol)
        case .redact:
            redactDown(p, view: v, tolerance: tol)
        case .background:
            break
        }
    }

    public func pointerDragged(to v: CGPoint, viewSize: CGSize) {
        guard let drag else { return }
        let t = transform(viewSize: viewSize)
        let p = t.toImage(v), tol = t.imageLength(Self.handleTolerance)
        switch drag {
        case .cropNew(let a, _, _):
            crop.rect = CropMath.dragRect(anchor: a, to: p, ratio: crop.ratio, bounds: crop.bounds, minSize: 1)
        case .cropResize(let h, let start):
            crop.rect = CropMath.resize(start, handle: h, to: p, ratio: crop.ratio, bounds: crop.bounds, minSize: min(tol * 2, 16))
        case .cropMove(let start, let from):
            crop.rect = CropMath.move(start, by: CGSize(width: p.x - from.x, height: p.y - from.y), bounds: crop.bounds)
        case .annotationNew(let id, let a, _):
            guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
            switch annotations[i].kind {
            case .rect, .ellipse, .highlight:
                annotations[i].rect = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(p.x - a.x), height: abs(p.y - a.y))
            case .line, .arrow:
                annotations[i].points = [a, p]
            case .freehand:
                if let last = annotations[i].points.last, hypot(p.x - last.x, p.y - last.y) >= tol / 4 {
                    annotations[i].points.append(p)
                }
            case .text:
                break
            }
        case .annotationMove(let id, let start, let from, _):
            guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
            annotations[i] = start.translated(by: CGSize(width: p.x - from.x, height: p.y - from.y))
        case .regionNew(let i, let a, _):
            guard redact.regions.indices.contains(i) else { return }
            redact.regions[i] = CropMath.dragRect(anchor: a, to: p, ratio: nil, bounds: sourceSize, minSize: 0)
        case .regionResize(let i, let h, let start):
            guard redact.regions.indices.contains(i) else { return }
            redact.regions[i] = CropMath.resize(start, handle: h, to: p, ratio: nil, bounds: sourceSize, minSize: tol)
        case .regionMove(let i, let start, let from):
            guard redact.regions.indices.contains(i) else { return }
            redact.regions[i] = CropMath.move(start, by: CGSize(width: p.x - from.x, height: p.y - from.y), bounds: sourceSize)
        case .pan(let start, let fromView):
            pan = CGPoint(x: start.x + v.x - fromView.x, y: start.y + v.y - fromView.y)
        case .compare:
            break
        }
    }

    public func pointerUp(at v: CGPoint, viewSize: CGSize) {
        guard let current = drag else { return }
        pointerDragged(to: v, viewSize: viewSize)
        let scale = transform(viewSize: viewSize).scale
        switch current {
        case .cropNew(_, let previous, let fromView):
            if hypot(v.x - fromView.x, v.y - fromView.y) < Self.minDrag { crop.rect = previous }
        case .annotationNew(let id, _, let fromView):
            if let i = annotations.firstIndex(where: { $0.id == id }) {
                let small = hypot(v.x - fromView.x, v.y - fromView.y) < Self.minDrag
                if small || !annotations[i].isRenderable {
                    annotations.remove(at: i)
                    selectedAnnotationID = nil
                    _ = undoStack.popLast()
                } else if annotations[i].kind == .freehand {
                    annotations[i].points = ShapeRenderer.simplify(annotations[i].points, minDistance: 1.5 / scale)
                }
            }
        case .annotationMove(let id, let start, _, let created):
            if !created, annotations.first(where: { $0.id == id }) == start { _ = undoStack.popLast() }
        case .regionNew(let i, _, let fromView):
            if redact.regions.indices.contains(i) {
                let tooSmall = hypot(v.x - fromView.x, v.y - fromView.y) < Self.minDrag
                    || CropMath.coveringRect(redact.regions[i], bounds: sourceSize) == nil
                if tooSmall {
                    redact.regions.remove(at: i)
                    selectedRegion = nil
                    _ = undoStack.popLast()
                }
            }
        case .regionMove(let i, let start, _), .regionResize(let i, _, let start):
            if redact.regions.indices.contains(i), redact.regions[i] == start { _ = undoStack.popLast() }
        case .compare:
            showOriginal = false
        default:
            break
        }
        drag = nil
    }

    /// Esc during a drag: put everything back the way it was before the drag.
    public func cancelDrag() {
        guard let current = drag else { return }
        drag = nil
        switch current {
        case .cropNew(_, let previous, _): crop.rect = previous
        case .cropResize(_, let start), .cropMove(let start, _): crop.rect = start
        case .annotationNew, .annotationMove, .regionNew, .regionMove, .regionResize: undo()
        case .pan(let start, _): pan = start
        case .compare: showOriginal = false
        }
    }

    private func clamped(_ p: CGPoint, to s: CGSize) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), s.width), y: min(max(p.y, 0), s.height))
    }

    private func annotateDown(_ p: CGPoint, view v: CGPoint, tolerance tol: CGFloat) {
        // The selected shape can be grabbed with any tool; Select/Text also pick up any shape under the pointer.
        if let id = selectedAnnotationID, let a = annotations.first(where: { $0.id == id }),
           ShapeRenderer.hitTest(a, at: p, tolerance: tol) {
            pushUndo()
            drag = .annotationMove(id, start: a, from: p, created: false)
            return
        }
        if annotateTool == .select || annotateTool == .text,
           let hit = annotations.last(where: { ($0.kind == .text || annotateTool == .select) && ShapeRenderer.hitTest($0, at: p, tolerance: tol) }) {
            selectedAnnotationID = hit.id
            pushUndo()
            drag = .annotationMove(hit.id, start: hit, from: p, created: false)
            return
        }
        guard let kind = annotateTool.kind else {
            selectedAnnotationID = nil
            return
        }
        pushUndo()
        var a = annotationStyle
        a.id = UUID()
        a.kind = kind
        if kind == .highlight && a.color.isOpaque { a.color = a.color.withAlpha(0.4) }
        switch kind {
        case .text:
            a.rect = CGRect(origin: p, size: .zero)
            a.text = "Text"
            annotations.append(a)
            selectedAnnotationID = a.id
            focusTextRequest += 1
            drag = .annotationMove(a.id, start: a, from: p, created: true)
            return
        case .rect, .ellipse, .highlight:
            a.rect = CGRect(origin: p, size: .zero)
        case .line, .arrow, .freehand:
            a.points = [p, p]
        }
        annotations.append(a)
        selectedAnnotationID = a.id
        drag = .annotationNew(a.id, anchor: p, fromView: v)
    }

    private func redactDown(_ p: CGPoint, view v: CGPoint, tolerance tol: CGFloat) {
        if let i = selectedRegion, redact.regions.indices.contains(i),
           let h = CropMath.handle(at: p, on: redact.regions[i], tolerance: tol) {
            pushUndo()
            drag = .regionResize(i, h, start: redact.regions[i])
            return
        }
        if let i = redact.regions.lastIndex(where: { $0.insetBy(dx: -tol / 2, dy: -tol / 2).contains(p) }) {
            selectedRegion = i
            pushUndo()
            drag = .regionMove(i, start: redact.regions[i], from: p)
            return
        }
        let a = clamped(p, to: sourceSize)
        pushUndo()
        redact.regions.append(CGRect(origin: a, size: .zero))
        selectedRegion = redact.regions.count - 1
        drag = .regionNew(redact.regions.count - 1, anchor: a, fromView: v)
    }

    // MARK: Annotation style / selection

    public var selectedAnnotation: Annotation? {
        selectedAnnotationID.flatMap { id in annotations.first { $0.id == id } }
    }

    /// Style shown in the inspector: the selected shape's, else the template for new shapes.
    public var currentStyle: Annotation { selectedAnnotation ?? annotationStyle }

    /// Applies a style change to the template and to the selected shape.
    public func updateStyle(_ change: (inout Annotation) -> Void) {
        change(&annotationStyle)
        guard let id = selectedAnnotationID, let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&annotations[i])
        if annotations[i].kind == .highlight && annotations[i].color.isOpaque {
            annotations[i].color = annotations[i].color.withAlpha(0.4)
        }
    }

    public func setSelectedText(_ text: String) {
        guard let id = selectedAnnotationID, let i = annotations.firstIndex(where: { $0.id == id }), annotations[i].kind == .text else { return }
        annotations[i].text = text
    }

    public var hasSelection: Bool {
        switch panel {
        case .annotate: selectedAnnotation != nil
        case .redact: selectedRegion.map { redact.regions.indices.contains($0) } ?? false
        default: false
        }
    }

    public func deleteSelection() {
        switch panel {
        case .annotate:
            guard let id = selectedAnnotationID, let i = annotations.firstIndex(where: { $0.id == id }) else { return }
            pushUndo()
            annotations.remove(at: i)
            selectedAnnotationID = nil
        case .redact:
            guard let i = selectedRegion, redact.regions.indices.contains(i) else { return }
            pushUndo()
            redact.regions.remove(at: i)
            selectedRegion = nil
        default:
            break
        }
    }

    public func clearAll() {
        switch panel {
        case .annotate where !annotations.isEmpty:
            pushUndo()
            annotations.removeAll()
            selectedAnnotationID = nil
        case .redact where !redact.regions.isEmpty:
            pushUndo()
            redact.regions.removeAll()
            selectedRegion = nil
        default:
            break
        }
    }

    // MARK: Undo (annotations + redact regions)

    public var canUndo: Bool { !undoStack.isEmpty }

    private func pushUndo() {
        undoStack.append(UndoState(annotations: annotations, regions: redact.regions))
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    public func undo() {
        guard let s = undoStack.popLast() else { return }
        annotations = s.annotations
        redact.regions = s.regions
        if let id = selectedAnnotationID, !annotations.contains(where: { $0.id == id }) { selectedAnnotationID = nil }
        if let i = selectedRegion, !redact.regions.indices.contains(i) { selectedRegion = nil }
    }

    // MARK: Submission

    /// Does `panel` hold edits that would produce a different image?
    public func hasEdits(_ panel: EditorPanel) -> Bool {
        switch panel {
        case .crop: crop.hasChanges
        case .adjust: !adjust.isDefault
        case .annotate: annotations.contains(where: \.isRenderable)
        case .redact: !redact.pixelRegions(bounds: sourceSize).isEmpty
        case .background:
            // Subject lift failed in the preview → it would fail in the engine too.
            background.mode.needsSubjectLift ? BackgroundMode.available.contains(background.mode) && backgroundError == nil
                : (background.padding > 0 || (proxy?.hasAlpha ?? false))
        }
    }

    /// Explicit options for `panel` (default: the current one); nil when there's nothing to apply.
    public func submission(for p: EditorPanel? = nil) -> EditorSubmission? {
        let panel = p ?? self.panel
        guard proxy != nil, hasEdits(panel) else { return nil }
        let options: [String: OptionValue]
        switch panel {
        case .crop:
            var o: [String: OptionValue] = [
                "rotation": .int(crop.orientation.rotation),
                "flipH": .bool(crop.orientation.flipH),
                "flipV": .bool(crop.orientation.flipV),
            ]
            if !crop.isFullFrame, let r = CropMath.pixelRect(crop.rect, bounds: crop.bounds) {
                o["rect"] = .list([Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)])
            }
            options = o
        case .adjust:
            options = adjust.options
        case .annotate:
            options = AnnotationJSON.options(annotations)
        case .redact:
            options = redact.options(bounds: sourceSize)
        case .background:
            options = background.options
        }
        return EditorSubmission(tool: panel.toolID, options: options)
    }

    public var canSave: Bool { loadState == .ready && !finished && submission() != nil }

    /// One-line guidance for the footer.
    public var statusHint: String {
        guard loadState == .ready else { return "" }
        if canSave {
            let others = otherEditedPanels
            if !others.isEmpty {
                return "Saves only the \(panel.title) edit — \(others.map(\.title).joined(separator: ", ")) changes are discarded."
            }
            switch panel {
            case .crop: return "Saves a cropped copy; the original isn't touched."
            case .adjust: return "Saves an adjusted copy; the original isn't touched."
            case .annotate: return "Saves a copy with \(annotations.filter(\.isRenderable).count) annotation(s)."
            case .redact: return "Saves a copy with \(redact.pixelRegions(bounds: sourceSize).count) region(s) hidden."
            case .background: return "Saves a copy with the new background."
            }
        }
        switch panel {
        case .crop: return "Drag to select an area, or rotate / flip."
        case .adjust: return "Move a slider or pick a filter."
        case .annotate: return "Pick a tool and drag on the image."
        case .redact: return "Drag over areas to hide."
        case .background:
            if background.mode.needsSubjectLift {
                return backgroundError == nil ? "Subject detection needs macOS 14." : "Subject detection failed here — use Fill."
            }
            return "No transparent areas — add padding."
        }
    }

    /// Panels other than the current one that hold edits (they're discarded on Save — one tool per save).
    public var otherEditedPanels: [EditorPanel] { EditorPanel.allCases.filter { $0 != panel && hasEdits($0) } }

    public func save() {
        guard !finished, let s = submission() else { return }
        finished = true
        editorLog.notice("save \(s.tool.rawValue, privacy: .public) for \(self.url.lastPathComponent, privacy: .public)")
        let finish = onFinish
        onFinish = nil
        finish?(s)
    }

    public func cancel() {
        guard !finished else { return }
        finished = true
        renderTask?.cancel()
        let finish = onFinish
        onFinish = nil
        finish?(nil)
    }

    // MARK: Previews

    private func updateOrientedPreview() {
        guard let proxy else { return }
        orientedPreview = PreviewRenderer.oriented(proxy.image, crop.orientation)
    }

    struct PreviewJob: @unchecked Sendable {
        let panel: EditorPanel
        let proxy: ImageProxy
        let adjust: AdjustSettings
        let redact: RedactSettings
        let background: BackgroundSettings
        let subject: CGImage?

        struct Result: @unchecked Sendable {
            var image: CGImage?
            var subject: CGImage?
            var error: String?
        }

        func run() -> Result {
            let scale = proxy.scale
            switch panel {
            case .adjust:
                return Result(image: PreviewRenderer.adjusted(proxy.image, adjust, scale: scale))
            case .redact:
                return Result(image: PreviewRenderer.redacted(proxy.image, redact, sourceSize: proxy.sourceSize, scale: scale))
            case .background:
                var subject = proxy.image
                if background.mode.needsSubjectLift {
                    if let s = self.subject {
                        subject = s
                    } else if #available(macOS 14.0, *) {
                        do { subject = try PreviewRenderer.liftSubject(proxy.image) } catch {
                            return Result(image: PreviewRenderer.backgrounded(proxy.image, BackgroundSettings(mode: .fill, color: background.color, padding: background.padding), scale: scale),
                                          error: "Subject detection isn't available here (\(error.localizedDescription)). Fill works everywhere.")
                        }
                    }
                }
                return Result(image: PreviewRenderer.backgrounded(subject, background, scale: scale),
                              subject: background.mode.needsSubjectLift ? subject : nil)
            default:
                return Result()
            }
        }
    }

    private func previewJob() -> PreviewJob? {
        guard let proxy else { return nil }
        let needed: Bool
        switch panel {
        case .adjust: needed = adjustPreviewFor != adjust
        case .redact: needed = redactPreviewFor != redact
        case .background: needed = backgroundPreviewFor != background
        default: needed = false
        }
        guard needed else { return nil }
        return PreviewJob(panel: panel, proxy: proxy, adjust: adjust, redact: redact, background: background, subject: liftedSubject)
    }

    private func apply(_ result: PreviewJob.Result, for job: PreviewJob) {
        switch job.panel {
        case .adjust:
            adjustPreview = result.image
            adjustPreviewFor = job.adjust
        case .redact:
            redactPreview = result.image
            redactPreviewFor = job.redact
        case .background:
            backgroundPreview = result.image
            backgroundPreviewFor = job.background
            backgroundError = result.error
            if let s = result.subject { liftedSubject = s }
        default:
            break
        }
    }

    /// Latest-wins preview rendering off the main thread.
    func schedulePreview() {
        guard !finished else { return }
        if renderTask != nil { renderDirty = true; return }
        guard let job = previewJob() else { return }
        renderTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { job.run() }.value
            guard let self else { return }
            self.renderTask = nil
            guard !Task.isCancelled, !self.finished else { return }
            self.apply(result, for: job)
            if self.renderDirty {
                self.renderDirty = false
                self.schedulePreview()
            }
        }
    }

    /// Synchronous render of the current panel's preview (tests, snapshots).
    public func renderPreviewNow() {
        guard let job = previewJob() else { return }
        apply(job.run(), for: job)
    }

    /// Waits until queued preview renders have landed (tests).
    public func waitForPreviews() async {
        while let task = renderTask { await task.value }
    }
}
