import CoreGraphics
import Foundation
import Testing
@testable import ImageEditorUI

private func near(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-6) -> Bool {
    abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps && abs(a.width - b.width) < eps && abs(a.height - b.height) < eps
}

private func inside(_ r: CGRect, _ s: CGSize) -> Bool {
    r.minX >= -1e-9 && r.minY >= -1e-9 && r.maxX <= s.width + 1e-9 && r.maxY <= s.height + 1e-9
}

@Suite struct CropMathTests {
    let bounds = CGSize(width: 400, height: 300)

    @Test func aspectPresets() {
        #expect(AspectPreset.free.ratio(imageSize: bounds, portrait: false) == nil)
        #expect(AspectPreset.original.ratio(imageSize: bounds, portrait: true) == 400.0 / 300)
        #expect(AspectPreset.square.ratio(imageSize: bounds, portrait: true) == 1)
        #expect(AspectPreset.r16x9.ratio(imageSize: bounds, portrait: false) == 16.0 / 9)
        #expect(AspectPreset.r16x9.ratio(imageSize: bounds, portrait: true) == 9.0 / 16)
    }

    @Test func maxRectFitsAndCenters() {
        #expect(near(CropMath.maxRect(ratio: 16.0 / 9, in: bounds), CGRect(x: 0, y: 37.5, width: 400, height: 225)))
        #expect(near(CropMath.maxRect(ratio: 1, in: bounds), CGRect(x: 50, y: 0, width: 300, height: 300)))
        // Off-center request is shifted back inside.
        #expect(near(CropMath.maxRect(ratio: 1, in: bounds, center: CGPoint(x: 390, y: 10)), CGRect(x: 100, y: 0, width: 300, height: 300)))
    }

    @Test func freeDragFlipsAndClamps() {
        #expect(CropMath.dragRect(anchor: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 40), ratio: nil, bounds: bounds) == CGRect(x: 10, y: 10, width: 40, height: 30))
        #expect(CropMath.dragRect(anchor: CGPoint(x: 50, y: 40), to: CGPoint(x: 10, y: 10), ratio: nil, bounds: bounds) == CGRect(x: 10, y: 10, width: 40, height: 30))
        #expect(CropMath.dragRect(anchor: CGPoint(x: 350, y: 250), to: CGPoint(x: 900, y: -80), ratio: nil, bounds: bounds) == CGRect(x: 350, y: 0, width: 50, height: 250))
    }

    @Test func lockedDragKeepsRatioInsideBounds() {
        #expect(near(CropMath.dragRect(anchor: .zero, to: CGPoint(x: 100, y: 10), ratio: 2, bounds: bounds), CGRect(x: 0, y: 0, width: 100, height: 50)))
        #expect(near(CropMath.dragRect(anchor: .zero, to: CGPoint(x: 10, y: 100), ratio: 2, bounds: bounds), CGRect(x: 0, y: 0, width: 200, height: 100)))
        #expect(near(CropMath.dragRect(anchor: CGPoint(x: 350, y: 100), to: CGPoint(x: 400, y: 300), ratio: 2, bounds: bounds), CGRect(x: 350, y: 100, width: 50, height: 25)))
        // Pseudo-random sweep: always the right ratio, always inside.
        var seed: UInt64 = 42
        func rnd(_ m: CGFloat) -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) * m }
        for _ in 0..<500 {
            let ratio = [0.5, 1, 4.0 / 3, 16.0 / 9][Int(rnd(4)) % 4]
            let a = CGPoint(x: rnd(400), y: rnd(300)), p = CGPoint(x: rnd(600) - 100, y: rnd(500) - 100)
            let r = CropMath.dragRect(anchor: a, to: p, ratio: ratio, bounds: bounds)
            #expect(inside(r, bounds))
            if r.height > 0.01 { #expect(abs(r.width / r.height - ratio) < 1e-6) }
            for handle in RectHandle.allCases where r.width > 1 && r.height > 1 {
                let q = CropMath.resize(r, handle: handle, to: CGPoint(x: rnd(600) - 100, y: rnd(500) - 100), ratio: ratio, bounds: bounds)
                #expect(inside(q, bounds))
                if q.height > 0.01 { #expect(abs(q.width / q.height - ratio) < 1e-6, "\(handle) \(q)") }
            }
        }
    }

    @Test func edgeResize() {
        let r = CGRect(x: 100, y: 100, width: 100, height: 50)
        #expect(CropMath.resize(r, handle: .right, to: CGPoint(x: 260, y: 0), ratio: nil, bounds: bounds) == CGRect(x: 100, y: 100, width: 160, height: 50))
        #expect(CropMath.resize(r, handle: .top, to: CGPoint(x: 0, y: -50), ratio: nil, bounds: bounds) == CGRect(x: 100, y: 0, width: 100, height: 150))
        // Can't drag an edge past the opposite edge (min size).
        #expect(CropMath.resize(r, handle: .left, to: CGPoint(x: 500, y: 0), ratio: nil, bounds: bounds, minSize: 4) == CGRect(x: 196, y: 100, width: 4, height: 50))
        // Locked: right edge drives width; height follows, centered on the old middle.
        let locked = CropMath.resize(r, handle: .right, to: CGPoint(x: 300, y: 0), ratio: 2, bounds: bounds)
        #expect(near(locked, CGRect(x: 100, y: 75, width: 200, height: 100)))
        // Corner: anchored at the opposite corner.
        #expect(CropMath.resize(r, handle: .topLeft, to: CGPoint(x: 50, y: 60), ratio: nil, bounds: bounds) == CGRect(x: 50, y: 60, width: 150, height: 90))
    }

    @Test func moveClampsWithoutResizing() {
        let r = CGRect(x: 100, y: 100, width: 100, height: 50)
        #expect(CropMath.move(r, by: CGSize(width: 1000, height: -1000), bounds: bounds) == CGRect(x: 300, y: 0, width: 100, height: 50))
        #expect(CropMath.clamp(CGRect(x: -20, y: 10, width: 900, height: 20), to: bounds) == CGRect(x: 0, y: 10, width: 400, height: 20))
    }

    @Test func pixelRounding() {
        #expect(CropMath.pixelRect(CGRect(x: 10.4, y: 9.6, width: 20.2, height: 30.3), bounds: bounds) == CGRect(x: 10, y: 10, width: 21, height: 30))
        #expect(CropMath.pixelRect(CGRect(x: 395.2, y: 0, width: 50, height: 10), bounds: bounds) == CGRect(x: 395, y: 0, width: 5, height: 10))
        #expect(CropMath.pixelRect(CGRect(x: 10, y: 10, width: 0.3, height: 5), bounds: bounds) == nil)
        // Covering: floor/ceil so redaction never leaves a sliver.
        #expect(CropMath.coveringRect(CGRect(x: 10.6, y: 9.4, width: 20.2, height: 30.2), bounds: bounds) == CGRect(x: 10, y: 9, width: 21, height: 31))
        #expect(CropMath.coveringRect(CGRect(x: -5, y: 290.5, width: 20, height: 40), bounds: bounds) == CGRect(x: 0, y: 290, width: 15, height: 10))
        #expect(CropMath.coveringRect(CGRect(x: 500, y: 10, width: 20, height: 20), bounds: bounds) == nil)
    }

    @Test func handleHitTesting() {
        let r = CGRect(x: 100, y: 100, width: 100, height: 50)
        #expect(CropMath.handle(at: CGPoint(x: 103, y: 98), on: r, tolerance: 5) == .topLeft)
        #expect(CropMath.handle(at: CGPoint(x: 150, y: 152), on: r, tolerance: 5) == .bottom)
        #expect(CropMath.handle(at: CGPoint(x: 150, y: 125), on: r, tolerance: 5) == nil)
    }
}

@Suite struct CropStateTests {
    @Test func rotationCarriesTheSelection() {
        var c = CropState(sourceSize: CGSize(width: 100, height: 80))
        #expect(!c.hasChanges)
        c.rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        c.rotateClockwise()
        #expect(c.bounds == CGSize(width: 80, height: 100))
        #expect(near(c.rect, CGRect(x: 20, y: 10, width: 40, height: 30)))
        c.flipHorizontal()
        #expect(near(c.rect, CGRect(x: 20, y: 10, width: 40, height: 30)))   // symmetric about x=40 in an 80-wide space
        c.rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        c.flipHorizontal()
        #expect(near(c.rect, CGRect(x: 70, y: 0, width: 10, height: 10)))
        // Four clockwise turns return to the start, same pixels selected.
        var d = CropState(sourceSize: CGSize(width: 100, height: 80))
        d.rect = CGRect(x: 5, y: 6, width: 7, height: 8)
        for _ in 0..<4 { d.rotateClockwise() }
        #expect(d.orientation == .identity)
        #expect(near(d.rect, CGRect(x: 5, y: 6, width: 7, height: 8)))
    }

    @Test func aspectLockAndPortraitFollowRotation() {
        var c = CropState(sourceSize: CGSize(width: 400, height: 300))
        c.setAspect(.square)
        #expect(near(c.rect, CGRect(x: 50, y: 0, width: 300, height: 300)))
        c.setAspect(.r4x3)
        #expect(!c.portrait)
        #expect(abs(c.rect.width / c.rect.height - 4.0 / 3) < 1e-9)
        c.rotateClockwise()
        #expect(c.portrait)   // the selection turned with the image
        #expect(abs(c.rect.width / c.rect.height - 3.0 / 4) < 1e-9)
        #expect(abs(c.ratio! - 3.0 / 4) < 1e-9)
        c.reset()
        #expect(c.orientation == .identity && c.aspect == .free && c.isFullFrame && !c.hasChanges)
    }

    @Test func fullFrameDetectionUsesWholePixels() {
        var c = CropState(sourceSize: CGSize(width: 400, height: 300))
        c.rect = CGRect(x: 0.2, y: 0, width: 399.9, height: 300)
        #expect(c.isFullFrame)
        c.rect = CGRect(x: 1, y: 0, width: 399, height: 300)
        #expect(!c.isFullFrame && c.hasChanges)
    }
}
