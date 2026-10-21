import CoreGraphics
import Foundation

/// Crop aspect presets. Fixed ratios are landscape; `portrait` inverts them.
public enum AspectPreset: String, CaseIterable, Identifiable, Sendable {
    case free, original, square, r4x3, r3x2, r16x9, r5x4

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "Square"
        case .r4x3: "4 : 3"
        case .r3x2: "3 : 2"
        case .r16x9: "16 : 9"
        case .r5x4: "5 : 4"
        }
    }

    /// True when `portrait` changes the ratio.
    public var hasOrientation: Bool { [.r4x3, .r3x2, .r16x9, .r5x4].contains(self) }

    /// Width / height, or nil for free-form. `imageSize` is the oriented image size.
    public func ratio(imageSize: CGSize, portrait: Bool) -> CGFloat? {
        let base: CGFloat
        switch self {
        case .free: return nil
        case .original:
            guard imageSize.width > 0, imageSize.height > 0 else { return nil }
            return imageSize.width / imageSize.height
        case .square: return 1
        case .r4x3: base = 4.0 / 3
        case .r3x2: base = 3.0 / 2
        case .r16x9: base = 16.0 / 9
        case .r5x4: base = 5.0 / 4
        }
        return portrait ? 1 / base : base
    }
}

/// The eight resize handles of a crop/selection rect.
public enum RectHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }

    /// Handle position on `r` (top-left coordinates).
    public func point(on r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// Opposite corner (corner handles only).
    public func anchor(on r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.maxX, y: r.maxY)
        case .topRight: CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: CGPoint(x: r.minX, y: r.minY)
        case .bottomLeft: CGPoint(x: r.maxX, y: r.minY)
        default: CGPoint(x: r.midX, y: r.midY)
        }
    }
}

/// Pure crop-rect math in image pixels (top-left origin). Every result lies inside `bounds`.
public enum CropMath {
    public static func full(_ bounds: CGSize) -> CGRect { CGRect(origin: .zero, size: bounds) }

    /// Moves `r` inside `bounds`, shrinking it first if it's larger.
    public static func clamp(_ r: CGRect, to bounds: CGSize) -> CGRect {
        let s = r.standardized
        let w = min(max(s.width, 0), bounds.width), h = min(max(s.height, 0), bounds.height)
        let x = min(max(s.minX, 0), bounds.width - w), y = min(max(s.minY, 0), bounds.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Largest rect of `ratio` that fits `bounds`, centered on `center` and shifted to stay inside.
    public static func maxRect(ratio: CGFloat, in bounds: CGSize, center: CGPoint? = nil) -> CGRect {
        guard ratio > 0, bounds.width > 0, bounds.height > 0 else { return full(bounds) }
        var w = bounds.width, h = w / ratio
        if h > bounds.height { h = bounds.height; w = h * ratio }
        let c = center ?? CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        return clamp(CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), to: bounds)
    }

    /// Rect spanned from fixed corner `anchor` to `p`, optionally aspect-locked, clamped to `bounds`.
    /// Dragging past the anchor flips the rect to that side.
    public static func dragRect(anchor a0: CGPoint, to p: CGPoint, ratio: CGFloat?, bounds: CGSize, minSize: CGFloat = 1) -> CGRect {
        let a = CGPoint(x: min(max(a0.x, 0), bounds.width), y: min(max(a0.y, 0), bounds.height))
        let sx: CGFloat = p.x < a.x ? -1 : 1, sy: CGFloat = p.y < a.y ? -1 : 1
        let availW = sx > 0 ? bounds.width - a.x : a.x
        let availH = sy > 0 ? bounds.height - a.y : a.y
        var w = min(abs(p.x - a.x), availW), h = min(abs(p.y - a.y), availH)
        if let r = ratio, r > 0 {
            w = max(w, h * r)
            h = w / r
            let minH = max(minSize, minSize / r)
            if h < minH { h = minH; w = h * r }
            if w > availW { w = availW; h = w / r }
            if h > availH { h = availH; w = h * r }
        } else {
            w = min(max(w, minSize), availW)
            h = min(max(h, minSize), availH)
        }
        return CGRect(x: sx > 0 ? a.x : a.x - w, y: sy > 0 ? a.y : a.y - h, width: w, height: h)
    }

    /// Resize `r` by dragging `handle` to `p`.
    public static func resize(_ r: CGRect, handle: RectHandle, to p: CGPoint, ratio: CGFloat?, bounds: CGSize, minSize: CGFloat = 1) -> CGRect {
        if handle.isCorner {
            return dragRect(anchor: handle.anchor(on: r), to: p, ratio: ratio, bounds: bounds, minSize: minSize)
        }
        var out = r
        switch handle {
        case .left:
            let x = min(max(p.x, 0), r.maxX - minSize)
            out = CGRect(x: x, y: r.minY, width: r.maxX - x, height: r.height)
        case .right:
            let x = max(min(p.x, bounds.width), r.minX + minSize)
            out = CGRect(x: r.minX, y: r.minY, width: x - r.minX, height: r.height)
        case .top:
            let y = min(max(p.y, 0), r.maxY - minSize)
            out = CGRect(x: r.minX, y: y, width: r.width, height: r.maxY - y)
        case .bottom:
            let y = max(min(p.y, bounds.height), r.minY + minSize)
            out = CGRect(x: r.minX, y: r.minY, width: r.width, height: y - r.minY)
        default: break
        }
        guard let ratio, ratio > 0 else { return clamp(out, to: bounds) }
        // Aspect lock: the dragged edge drives; the other axis grows symmetrically about the old center.
        let horizontal = handle == .left || handle == .right
        var w = out.width, h = out.height
        if horizontal {
            h = w / ratio
            if h > bounds.height { h = bounds.height; w = h * ratio }
        } else {
            w = h * ratio
            if w > bounds.width { w = bounds.width; h = w / ratio }
        }
        let x: CGFloat, y: CGFloat
        if horizontal {
            x = handle == .left ? r.maxX - w : r.minX
            y = r.midY - h / 2
        } else {
            x = r.midX - w / 2
            y = handle == .top ? r.maxY - h : r.minY
        }
        return clamp(CGRect(x: x, y: y, width: w, height: h), to: bounds)
    }

    /// Translate `r` by `delta`, keeping it inside `bounds` (size unchanged).
    public static func move(_ r: CGRect, by delta: CGSize, bounds: CGSize) -> CGRect {
        clamp(r.offsetBy(dx: delta.width, dy: delta.height), to: bounds)
    }

    /// Whole-pixel rect for submission (nearest-pixel edges), clamped to `bounds`. nil when empty.
    public static func pixelRect(_ r: CGRect, bounds: CGSize) -> CGRect? {
        let s = r.standardized
        let x0 = max(0, min(bounds.width, s.minX.rounded())), y0 = max(0, min(bounds.height, s.minY.rounded()))
        let x1 = max(0, min(bounds.width, s.maxX.rounded())), y1 = max(0, min(bounds.height, s.maxY.rounded()))
        guard x1 - x0 >= 1, y1 - y0 >= 1 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Whole-pixel rect that fully covers `r` (floor/ceil edges), clamped to `bounds` — for redaction. nil when empty.
    public static func coveringRect(_ r: CGRect, bounds: CGSize) -> CGRect? {
        let s = r.standardized
        let e: CGFloat = 1e-6   // view↔image float noise must not grow a region by a whole pixel
        let x0 = max(0, min(bounds.width, floor(s.minX + e))), y0 = max(0, min(bounds.height, floor(s.minY + e)))
        let x1 = max(0, min(bounds.width, ceil(s.maxX - e))), y1 = max(0, min(bounds.height, ceil(s.maxY - e)))
        guard x1 - x0 >= 1, y1 - y0 >= 1 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Handle under `p` (image pixels) within `tolerance` pixels, corners first.
    public static func handle(at p: CGPoint, on r: CGRect, tolerance: CGFloat) -> RectHandle? {
        let ordered = RectHandle.allCases.filter(\.isCorner) + RectHandle.allCases.filter { !$0.isCorner }
        return ordered.first { h in
            let q = h.point(on: r)
            return abs(q.x - p.x) <= tolerance && abs(q.y - p.y) <= tolerance
        }
    }
}

/// Everything the Crop panel edits. `rect` is in *oriented* full-resolution pixels (after rotation/flip),
/// exactly what `image.crop` expects.
public struct CropState: Equatable, Sendable {
    public var sourceSize: CGSize
    public private(set) var orientation: Orientation = .identity
    public var rect: CGRect
    public private(set) var aspect: AspectPreset = .free
    public private(set) var portrait = false

    public init(sourceSize: CGSize) {
        self.sourceSize = sourceSize
        self.rect = CGRect(origin: .zero, size: sourceSize)
        if sourceSize.height > sourceSize.width { portrait = true }
    }

    public var bounds: CGSize { orientation.orientedSize(sourceSize) }
    public var ratio: CGFloat? { aspect.ratio(imageSize: bounds, portrait: portrait) }
    public var isFullFrame: Bool { CropMath.pixelRect(rect, bounds: bounds) == CropMath.full(bounds) }
    public var hasChanges: Bool { !orientation.isIdentity || !isFullFrame }

    public mutating func setAspect(_ a: AspectPreset) {
        aspect = a
        applyRatio()
    }

    public mutating func setPortrait(_ p: Bool) {
        portrait = p
        applyRatio()
    }

    private mutating func applyRatio() {
        guard let r = ratio else { return }
        rect = CropMath.maxRect(ratio: r, in: bounds, center: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// Change orientation; the crop rect follows the image so the same pixels stay selected.
    public mutating func setOrientation(_ o: Orientation) {
        let old = orientation
        let sourceRect = old.toSource(rect, sourceSize: sourceSize)
        orientation = o
        rect = CropMath.clamp(o.toOriented(sourceRect, sourceSize: sourceSize), to: bounds)
        if old.swapsAxes != o.swapsAxes && aspect.hasOrientation { portrait.toggle() }
    }

    public mutating func rotateClockwise() { setOrientation(orientation.rotatedClockwise()) }
    public mutating func rotateCounterClockwise() { setOrientation(orientation.rotatedCounterClockwise()) }
    public mutating func flipHorizontal() { setOrientation(orientation.flippedHorizontally()) }
    public mutating func flipVertical() { setOrientation(orientation.flippedVertically()) }

    public mutating func reset() {
        orientation = .identity
        aspect = .free
        portrait = sourceSize.height > sourceSize.width
        rect = CropMath.full(sourceSize)
    }
}
