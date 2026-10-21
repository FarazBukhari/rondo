import CoreGraphics
import Foundation

/// Maps canvas view points (top-left origin, flipped view) ↔ image pixels (top-left origin) under zoom and pan.
/// `imageSize` is the size of whatever the canvas currently shows, in full-resolution pixels — never the proxy size.
public struct CanvasTransform: Equatable, Sendable {
    public static let zoomRange: ClosedRange<CGFloat> = 0.05...64

    public var viewSize: CGSize
    public var imageSize: CGSize
    /// 1 = the whole image fits the view (minus `inset`).
    public var zoom: CGFloat
    /// Offset of the image center from the view center, in view points.
    public var pan: CGPoint
    public var inset: CGFloat

    public init(viewSize: CGSize, imageSize: CGSize, zoom: CGFloat = 1, pan: CGPoint = .zero, inset: CGFloat = 20) {
        self.viewSize = viewSize
        self.imageSize = imageSize
        self.zoom = zoom
        self.pan = pan
        self.inset = inset
    }

    public var fitScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let w = max(1, viewSize.width - 2 * inset), h = max(1, viewSize.height - 2 * inset)
        return min(w / imageSize.width, h / imageSize.height)
    }

    /// View points per image pixel.
    public var scale: CGFloat { fitScale * zoom }

    /// Zoom at which one image pixel spans one view point.
    public var actualSizeZoom: CGFloat { 1 / fitScale }

    public var imageOrigin: CGPoint {
        let s = scale
        return CGPoint(x: (viewSize.width - imageSize.width * s) / 2 + pan.x,
                       y: (viewSize.height - imageSize.height * s) / 2 + pan.y)
    }

    public var imageFrame: CGRect {
        CGRect(origin: imageOrigin, size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
    }

    public func toImage(_ p: CGPoint) -> CGPoint {
        let o = imageOrigin, s = scale
        return CGPoint(x: (p.x - o.x) / s, y: (p.y - o.y) / s)
    }

    public func toView(_ p: CGPoint) -> CGPoint {
        let o = imageOrigin, s = scale
        return CGPoint(x: o.x + p.x * s, y: o.y + p.y * s)
    }

    public func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
    }

    public func toImage(_ r: CGRect) -> CGRect {
        let o = toImage(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width / scale, height: r.height / scale)
    }

    /// Image-pixel length of `points` view points (hit tolerances, minimum sizes).
    public func imageLength(_ points: CGFloat) -> CGFloat { points / scale }

    /// New zoom (clamped to `zoomRange`) keeping the image point under `anchor` fixed.
    public func zoomed(to z: CGFloat, anchor: CGPoint) -> CanvasTransform {
        let target = toImage(anchor)
        var t = self
        t.zoom = min(max(z, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let s = t.scale
        let centered = CGPoint(x: (viewSize.width - imageSize.width * s) / 2, y: (viewSize.height - imageSize.height * s) / 2)
        t.pan = CGPoint(x: anchor.x - target.x * s - centered.x, y: anchor.y - target.y * s - centered.y)
        return t
    }

    public func zoomed(by factor: CGFloat, anchor: CGPoint) -> CanvasTransform {
        zoomed(to: zoom * factor, anchor: anchor)
    }

    /// CG transform for drawing in *bottom-left-origin image pixels* (the engine's drawing space) inside a flipped view.
    public var bottomLeftImageToView: CGAffineTransform {
        let o = imageOrigin, s = scale
        return CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: o.x, ty: o.y + s * imageSize.height)
    }
}

/// Rotation (clockwise, multiple of 90°) followed by flips — the order `image.crop` applies them.
public struct Orientation: Hashable, Sendable {
    public var rotation: Int
    public var flipH: Bool
    public var flipV: Bool

    public init(rotation: Int = 0, flipH: Bool = false, flipV: Bool = false) {
        self.rotation = ((rotation % 360) + 360) % 360 / 90 * 90
        self.flipH = flipH
        self.flipV = flipV
    }

    public static let identity = Orientation()
    public var isIdentity: Bool { rotation == 0 && !flipH && !flipV }
    public var swapsAxes: Bool { rotation == 90 || rotation == 270 }

    public func orientedSize(_ s: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: s.height, height: s.width) : s
    }

    /// Source pixel (upright, top-left) → oriented pixel (top-left) for a source of `size`.
    public func transform(for size: CGSize) -> CGAffineTransform {
        let W = size.width, H = size.height
        var t: CGAffineTransform
        switch rotation {
        case 90: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: H, ty: 0)      // (x,y) → (H−y, x)
        case 180: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)    // (x,y) → (W−x, H−y)
        case 270: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: W)     // (x,y) → (y, W−x)
        default: t = .identity
        }
        let o = orientedSize(size)
        if flipH { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: o.width, ty: 0)) }
        if flipV { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: o.height)) }
        return t
    }

    public func toOriented(_ p: CGPoint, sourceSize: CGSize) -> CGPoint { p.applying(transform(for: sourceSize)) }
    public func toSource(_ p: CGPoint, sourceSize: CGSize) -> CGPoint { p.applying(transform(for: sourceSize).inverted()) }
    public func toOriented(_ r: CGRect, sourceSize: CGSize) -> CGRect { r.applying(transform(for: sourceSize)).standardized }
    public func toSource(_ r: CGRect, sourceSize: CGSize) -> CGRect { r.applying(transform(for: sourceSize).inverted()).standardized }

    // MARK: Edits relative to what the user sees

    /// Rotates the *displayed* image 90° clockwise. R90∘FH = FV∘R90, so a single flip swaps axis.
    public func rotatedClockwise() -> Orientation {
        var o = Orientation(rotation: rotation + 90, flipH: flipH, flipV: flipV)
        if flipH != flipV { swap(&o.flipH, &o.flipV) }
        return o.normalized()
    }

    public func rotatedCounterClockwise() -> Orientation {
        var o = Orientation(rotation: rotation + 270, flipH: flipH, flipV: flipV)
        if flipH != flipV { swap(&o.flipH, &o.flipV) }
        return o.normalized()
    }

    public func flippedHorizontally() -> Orientation {
        Orientation(rotation: rotation, flipH: !flipH, flipV: flipV).normalized()
    }

    public func flippedVertically() -> Orientation {
        Orientation(rotation: rotation, flipH: flipH, flipV: !flipV).normalized()
    }

    /// FH∘FV = R180: fold a double flip into the rotation so equal results compare equal.
    public func normalized() -> Orientation {
        guard flipH && flipV else { return self }
        return Orientation(rotation: rotation + 180)
    }
}
