import CoreGraphics
import Foundation

/// Eight drag handles around the crop rectangle.
public enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Position on the rect as fractions of width/height (top-left origin).
    var unit: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomRight: CGPoint(x: 1, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .left: CGPoint(x: 0, y: 0.5)
        }
    }

    var isCorner: Bool { unit.x != 0.5 && unit.y != 0.5 }
    var movesX: Bool { unit.x != 0.5 }
    var movesY: Bool { unit.y != 0.5 }

    func point(in r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + r.width * unit.x, y: r.minY + r.height * unit.y)
    }
}

/// Crop aspect presets. Ratios are width ÷ height of the displayed (post-rotation) frame.
public enum AspectPreset: String, CaseIterable, Identifiable, Sendable {
    case free, original, square, fourThree, threeFour, sixteenNine, nineSixteen

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeFour: "3:4"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        }
    }

    public func ratio(original: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original: original.height > 0 ? Double(original.width / original.height) : nil
        case .square: 1
        case .fourThree: 4.0 / 3
        case .threeFour: 3.0 / 4
        case .sixteenNine: 16.0 / 9
        case .nineSixteen: 9.0 / 16
        }
    }
}

/// Pure geometry for the crop overlay. Video coordinates are displayed (post-rotation) pixels with a
/// top-left origin — the same space the engine's `rect` option uses. View coordinates are SwiftUI
/// points, also top-left origin, with the video aspect-fitted into a frame inside the view.
public enum CropGeometry {
    // MARK: Rotation

    /// Clockwise-or-not doesn't matter for sizing: returns the transform's rotation snapped to 0/90/180/270.
    public static func rotationDegrees(of t: CGAffineTransform) -> Int {
        let radians = atan2(Double(t.b), Double(t.a))
        return normalizedRotation(radians * 180 / .pi)
    }

    /// Snaps any angle (e.g. ffprobe's -90) to 0, 90, 180 or 270.
    public static func normalizedRotation(_ degrees: Double) -> Int {
        guard degrees.isFinite else { return 0 }
        let snapped = Int((degrees / 90).rounded()) * 90
        return ((snapped % 360) + 360) % 360
    }

    /// Size as displayed: width/height swap for quarter turns.
    public static func displaySize(natural: CGSize, rotation: Int) -> CGSize {
        let r = normalizedRotation(Double(rotation))
        return r == 90 || r == 270 ? CGSize(width: natural.height, height: natural.width) : natural
    }

    public static func displaySize(natural: CGSize, transform: CGAffineTransform) -> CGSize {
        displaySize(natural: natural, rotation: rotationDegrees(of: transform))
    }

    // MARK: View ↔ video

    /// Largest rect with `content`'s aspect, centred in `bounds` (resizeAspect).
    public static func aspectFit(_ content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// View rect (inside `frame`, where the whole video is drawn) → video pixels.
    public static func viewToVideo(_ r: CGRect, frame: CGRect, videoSize: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let sx = videoSize.width / frame.width, sy = videoSize.height / frame.height
        return CGRect(x: (r.minX - frame.minX) * sx, y: (r.minY - frame.minY) * sy, width: r.width * sx, height: r.height * sy)
    }

    public static func viewToVideo(_ p: CGPoint, frame: CGRect, videoSize: CGSize) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: (p.x - frame.minX) * videoSize.width / frame.width,
                       y: (p.y - frame.minY) * videoSize.height / frame.height)
    }

    /// Video pixels → view rect inside `frame`.
    public static func videoToView(_ r: CGRect, frame: CGRect, videoSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let sx = frame.width / videoSize.width, sy = frame.height / videoSize.height
        return CGRect(x: frame.minX + r.minX * sx, y: frame.minY + r.minY * sy, width: r.width * sx, height: r.height * sy)
    }

    // MARK: Constraints

    /// Shrinks `r` to fit `size` (at least `minSize`), then moves it inside.
    public static func clamp(_ r: CGRect, to size: CGSize, minSize: CGFloat = 2) -> CGRect {
        let w = min(max(r.width, min(minSize, size.width)), size.width)
        let h = min(max(r.height, min(minSize, size.height)), size.height)
        let x = min(max(0, r.minX), size.width - w)
        let y = min(max(0, r.minY), size.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Largest rect of `aspect` (w ÷ h) inside `size`, centred on `center` (default: frame centre) and kept inside.
    public static func largest(aspect: Double, in size: CGSize, centeredAt center: CGPoint? = nil) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        let c = center ?? CGPoint(x: size.width / 2, y: size.height / 2)
        return clamp(CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), to: size)
    }

    /// Re-shapes `r` to `aspect`, keeping its centre and roughly its area, inside `size`.
    public static func conform(_ r: CGRect, aspect: Double, in size: CGSize) -> CGRect {
        guard aspect > 0, r.width > 0, r.height > 0 else { return largest(aspect: aspect, in: size) }
        let area = r.width * r.height
        var h = (area / aspect).squareRoot(), w = h * aspect
        let fit = largest(aspect: aspect, in: size)
        if w > fit.width || h > fit.height { w = fit.width; h = fit.height }
        return clamp(CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), to: size)
    }

    /// Translates `r` by `delta`, kept inside `size`.
    public static func moved(_ r: CGRect, by delta: CGSize, in size: CGSize) -> CGRect {
        clamp(r.offsetBy(dx: delta.width, dy: delta.height), to: size)
    }

    /// Drags `handle` of `r` to `p` (video coordinates). The opposite corner/edge stays put; size never
    /// drops below `minSize` and the rect never leaves `size`. With `aspect`, the ratio is preserved.
    public static func resized(_ r: CGRect, handle: CropHandle, to p: CGPoint, aspect: Double?,
                               in size: CGSize, minSize: CGFloat = 16) -> CGRect {
        let minW = min(minSize, size.width), minH = min(minSize, size.height)
        let u = handle.unit
        // Fixed edges (anchors) on each axis.
        let ax = u.x == 0 ? r.maxX : r.minX
        let ay = u.y == 0 ? r.maxY : r.minY
        let maxW = u.x == 0 ? ax : (u.x == 1 ? size.width - ax : size.width)
        let maxH = u.y == 0 ? ay : (u.y == 1 ? size.height - ay : size.height)

        var w = handle.movesX ? min(max(u.x == 0 ? ax - p.x : p.x - ax, minW), maxW) : r.width
        var h = handle.movesY ? min(max(u.y == 0 ? ay - p.y : p.y - ay, minH), maxH) : r.height

        if let aspect, aspect > 0 {
            if handle.isCorner {
                // Follow whichever axis the pointer pulled further, then fit.
                if w / aspect >= h { h = w / aspect } else { w = h * aspect }
            } else if handle.movesX {
                h = w / aspect
            } else {
                w = h * aspect
            }
            // Limits on each axis (edge handles grow symmetrically around the centre line).
            let limW = handle.movesX ? maxW : size.width
            let limH = handle.movesY ? maxH : size.height
            if w > limW { w = limW; h = w / aspect }
            if h > limH { h = limH; w = h * aspect }
            if w < minW { w = minW; h = w / aspect }
            if h < minH { h = minH; w = h * aspect }
        }

        let x: CGFloat
        if u.x == 0 { x = ax - w } else if u.x == 1 { x = ax } else { x = r.midX - w / 2 }
        let y: CGFloat
        if u.y == 0 { y = ay - h } else if u.y == 1 { y = ay } else { y = r.midY - h / 2 }
        return clamp(CGRect(x: x, y: y, width: w, height: h), to: size, minSize: 2)
    }

    // MARK: Engine

    /// `[x, y, w, h]` in whole pixels as the engine will apply it: inside the frame, w/h even, ≥ 2.
    public static func engineRect(_ r: CGRect, videoSize: CGSize) -> [Double] {
        let W = Int(videoSize.width.rounded()), H = Int(videoSize.height.rounded())
        guard W >= 2, H >= 2 else { return [0, 0, Double(max(0, W)), Double(max(0, H))] }
        let x = min(max(0, Int(r.minX.rounded())), W - 2)
        let y = min(max(0, Int(r.minY.rounded())), H - 2)
        let w = max(2, min(Int(r.width.rounded()), W - x) / 2 * 2)
        let h = max(2, min(Int(r.height.rounded()), H - y) / 2 * 2)
        return [Double(x), Double(y), Double(w), Double(h)]
    }

    /// True when cropping to `r` would keep (almost) the whole frame.
    public static func isFullFrame(_ r: CGRect, videoSize: CGSize) -> Bool {
        let e = engineRect(r, videoSize: videoSize)
        let W = Double(Int(videoSize.width.rounded()) / 2 * 2), H = Double(Int(videoSize.height.rounded()) / 2 * 2)
        return e[0] == 0 && e[1] == 0 && e[2] >= W && e[3] >= H
    }
}
