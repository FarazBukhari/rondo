import CoreGraphics
import Foundation
import RondoKit
import Testing
@testable import ImageEditorUI

private func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 1e-6) -> Bool { abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }
private func near(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-6) -> Bool {
    abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps && abs(a.width - b.width) < eps && abs(a.height - b.height) < eps
}

@Suite struct CanvasTransformTests {
    @Test func fitsAndCenters() {
        let t = CanvasTransform(viewSize: CGSize(width: 840, height: 640), imageSize: CGSize(width: 400, height: 300))
        #expect(t.fitScale == 2)
        #expect(t.imageFrame == CGRect(x: 20, y: 20, width: 800, height: 600))
        // Tall image in a wide view: height-limited, horizontally centered.
        let tall = CanvasTransform(viewSize: CGSize(width: 1000, height: 540), imageSize: CGSize(width: 100, height: 500))
        #expect(tall.fitScale == 1)
        #expect(tall.imageFrame.midX == 500)
    }

    @Test func viewImageRoundTripUnderZoomAndPan() {
        let t = CanvasTransform(viewSize: CGSize(width: 900, height: 700), imageSize: CGSize(width: 4000, height: 3000),
                                zoom: 2.5, pan: CGPoint(x: 13, y: -7))
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 1234.5, y: 99), CGPoint(x: 4000, y: 3000)] {
            #expect(near(t.toImage(t.toView(p)), p, 1e-6))
        }
        let r = CGRect(x: 100, y: 200, width: 300, height: 50)
        #expect(near(t.toImage(t.toView(r)), r, 1e-6))
        // Image origin lands at imageOrigin; scale is view points per image pixel.
        #expect(near(t.toView(.zero), t.imageOrigin))
        #expect(abs(t.toView(CGPoint(x: 10, y: 0)).x - t.imageOrigin.x - 10 * t.scale) < 1e-9)
        #expect(abs(t.imageLength(8) * t.scale - 8) < 1e-9)
    }

    @Test func zoomKeepsAnchorFixedAndClamps() {
        let t = CanvasTransform(viewSize: CGSize(width: 800, height: 600), imageSize: CGSize(width: 1600, height: 1200), pan: CGPoint(x: 30, y: 10))
        let anchor = CGPoint(x: 612, y: 141)
        let before = t.toImage(anchor)
        let z = t.zoomed(by: 3.7, anchor: anchor)
        #expect(abs(z.zoom - 3.7) < 1e-9)
        #expect(near(z.toImage(anchor), before, 1e-6))
        let out = z.zoomed(by: 0.2, anchor: CGPoint(x: 5, y: 590))
        #expect(near(out.toImage(CGPoint(x: 5, y: 590)), z.toImage(CGPoint(x: 5, y: 590)), 1e-6))
        #expect(t.zoomed(to: 1_000, anchor: anchor).zoom == CanvasTransform.zoomRange.upperBound)
        #expect(t.zoomed(to: 0, anchor: anchor).zoom == CanvasTransform.zoomRange.lowerBound)
        // Actual size: one image pixel per point.
        #expect(abs(t.zoomed(to: t.actualSizeZoom, anchor: anchor).scale - 1) < 1e-9)
    }

    @Test func bottomLeftDrawingSpaceMapsToFlippedView() {
        let t = CanvasTransform(viewSize: CGSize(width: 840, height: 640), imageSize: CGSize(width: 400, height: 300), zoom: 1.5, pan: CGPoint(x: 9, y: 4))
        let m = t.bottomLeftImageToView
        // Bottom-left image corner (0,0) → bottom-left of the frame in view (top-left) coordinates.
        #expect(near(CGPoint.zero.applying(m), CGPoint(x: t.imageFrame.minX, y: t.imageFrame.maxY)))
        // Any point: bottom-left (x, H−y) equals top-left (x, y) through toView.
        let p = CGPoint(x: 123, y: 77)
        #expect(near(CGPoint(x: p.x, y: 300 - p.y).applying(m), t.toView(p)))
    }
}

@Suite struct OrientationTests {
    static let size = CGSize(width: 100, height: 80)

    static var all: [Orientation] {
        [0, 90, 180, 270].flatMap { r in [false, true].flatMap { h in [false, true].map { v in Orientation(rotation: r, flipH: h, flipV: v) } } }
    }

    @Test func sizesAndCornerMapping() {
        let s = Self.size
        #expect(Orientation(rotation: 90).orientedSize(s) == CGSize(width: 80, height: 100))
        #expect(Orientation(rotation: 180).orientedSize(s) == s)
        // Clockwise 90°: source top-left → oriented top-right.
        #expect(near(Orientation(rotation: 90).toOriented(.zero, sourceSize: s), CGPoint(x: 80, y: 0)))
        #expect(near(Orientation(rotation: 180).toOriented(.zero, sourceSize: s), CGPoint(x: 100, y: 80)))
        // 270° (= 90° counter-clockwise): source top-left → oriented bottom-left.
        #expect(near(Orientation(rotation: 270).toOriented(.zero, sourceSize: s), CGPoint(x: 0, y: 100)))
        #expect(near(Orientation(flipH: true).toOriented(CGPoint(x: 10, y: 5), sourceSize: s), CGPoint(x: 90, y: 5)))
        #expect(near(Orientation(flipV: true).toOriented(CGPoint(x: 10, y: 5), sourceSize: s), CGPoint(x: 10, y: 75)))
        // Rotation first, then flip in the rotated space.
        #expect(near(Orientation(rotation: 90, flipH: true).toOriented(.zero, sourceSize: s), CGPoint(x: 0, y: 0)))
        #expect(Orientation(rotation: -90).rotation == 270)
        #expect(Orientation(rotation: 450).rotation == 90)
    }

    @Test func roundTripsForEveryOrientation() {
        let s = Self.size
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 13, y: 71), CGPoint(x: 100, y: 80), CGPoint(x: 55.5, y: 2.25)]
        for o in Self.all {
            let osz = o.orientedSize(s)
            for p in pts {
                let q = o.toOriented(p, sourceSize: s)
                #expect(q.x >= -1e-9 && q.x <= osz.width + 1e-9 && q.y >= -1e-9 && q.y <= osz.height + 1e-9)
                #expect(near(o.toSource(q, sourceSize: s), p, 1e-9))
            }
            let r = CGRect(x: 10, y: 20, width: 30, height: 40)
            #expect(near(o.toSource(o.toOriented(r, sourceSize: s), sourceSize: s), r, 1e-9))
        }
    }

    /// Display-relative edits: the new orientation equals "apply the visual op to what's on screen".
    @Test func displayRelativeRotateAndFlip() {
        let s = Self.size
        let pts = [CGPoint(x: 1, y: 2), CGPoint(x: 70, y: 9), CGPoint(x: 33, y: 64)]
        for o in Self.all.map({ $0.normalized() }) {
            let shown = o.orientedSize(s)
            for p in pts {
                let q = o.toOriented(p, sourceSize: s)
                let cw = o.rotatedClockwise()
                #expect(near(cw.toOriented(p, sourceSize: s), CGPoint(x: shown.height - q.y, y: q.x), 1e-9))
                let ccw = o.rotatedCounterClockwise()
                #expect(near(ccw.toOriented(p, sourceSize: s), CGPoint(x: q.y, y: shown.width - q.x), 1e-9))
                #expect(near(o.flippedHorizontally().toOriented(p, sourceSize: s), CGPoint(x: shown.width - q.x, y: q.y), 1e-9))
                #expect(near(o.flippedVertically().toOriented(p, sourceSize: s), CGPoint(x: q.x, y: shown.height - q.y), 1e-9))
            }
            #expect(!(o.rotatedClockwise().flipH && o.rotatedClockwise().flipV))
            #expect(o.rotatedClockwise().rotatedCounterClockwise() == o)
        }
        #expect(Orientation(rotation: 90, flipH: true, flipV: true).normalized() == Orientation(rotation: 270))
    }

    /// Pixel-level: the preview's rotated proxy puts each pixel where `toOriented` says.
    @Test func previewPixelsFollowTheMapping() {
        let img = W6.quadrants(40, 20)   // TL red, TR green, BL blue, BR white
        let s = CGSize(width: 40, height: 20)
        for o in Self.all {
            let out = PreviewRenderer.oriented(img, o)
            let osz = o.orientedSize(s)
            #expect(out.width == Int(osz.width) && out.height == Int(osz.height))
            for (src, color) in [(CGPoint(x: 5, y: 5), W6.RGBA.red), (CGPoint(x: 35, y: 5), .green),
                                 (CGPoint(x: 5, y: 15), .blue), (CGPoint(x: 35, y: 15), .white)] {
                let q = o.toOriented(CGPoint(x: src.x + 0.5, y: src.y + 0.5), sourceSize: s)
                let got = W6.pixel(out, Int(q.x), Int(q.y))
                #expect(got.close(to: color), "\(o): \(src) → \(q) is \(got)")
            }
        }
    }
}
