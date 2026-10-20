import CoreGraphics
import Foundation
import RondoKit
import Testing
@testable import RondoInteraction

func makeItems(_ n: Int) -> [WheelItem] {
    (0..<n).map { WheelItem(id: "i\($0)", title: "Item \($0)", symbol: "doc", payload: .convert("f\($0)")) }
}

@Suite struct WheelLayoutTests {
    @Test func ringSizesOverflow() {
        #expect(WheelModel.ringSizes(count: 0, maxPerRing: 8) == [])
        #expect(WheelModel.ringSizes(count: 1, maxPerRing: 8) == [1])
        #expect(WheelModel.ringSizes(count: 8, maxPerRing: 8) == [8])
        #expect(WheelModel.ringSizes(count: 9, maxPerRing: 8) == [8, 1])
        #expect(WheelModel.ringSizes(count: 16, maxPerRing: 8) == [8, 8])
        #expect(WheelModel.ringSizes(count: 20, maxPerRing: 8) == [8, 8, 4])
        #expect(WheelModel.ringSizes(count: 3, maxPerRing: 0) == [1, 1, 1])  // clamped to ≥1
    }

    @Test func ringsKeepProviderOrder() {
        let m = WheelModel(items: makeItems(11), kind: .convert)
        #expect(m.rings == [Array(0..<8), Array(8..<11)])
        #expect(m.item(at: WheelSlot(ring: 1, index: 2))?.id == "i10")
        #expect(m.item(at: WheelSlot(ring: 1, index: 3)) == nil)
        #expect(m.slot(ofItem: "i9") == WheelSlot(ring: 1, index: 1))
        #expect(m.allSlots.count == 11)
    }

    @Test func radiiAndDiameterGrowWithRings() {
        let g = WheelGeometry(hubRadius: 40, ringWidth: 60, ringGap: 4, maxPerRing: 8, margin: 10)
        let one = WheelModel(items: makeItems(5), kind: .tools, geometry: g)
        #expect(one.radii(ring: 0).inner == 44)
        #expect(one.radii(ring: 0).outer == 104)
        #expect(one.outerRadius == 104)
        #expect(one.diameter == 228)
        let two = WheelModel(items: makeItems(12), kind: .tools, geometry: g)
        #expect(two.radii(ring: 1).inner == 108)
        #expect(two.outerRadius == 168)
        // Empty wheel still reserves one ring for its message.
        #expect(WheelModel(items: [], kind: .tools, geometry: g).outerRadius == 104)
    }

    @Test func arcsAreCenteredOnTwelveOClock() {
        let m = WheelModel(items: makeItems(4), kind: .convert)
        let a0 = m.arc(for: WheelSlot(ring: 0, index: 0))
        #expect(abs(a0.midAngle) < 1e-9)
        #expect(abs(a0.sweep - .pi / 2) < 1e-9)
        let a1 = m.arc(for: WheelSlot(ring: 0, index: 1))
        #expect(abs(a1.midAngle - .pi / 2) < 1e-9)   // 3 o'clock
        let p = a1.point(atRadius: 10)
        #expect(abs(p.x - 10) < 1e-9 && abs(p.y) < 1e-9)
    }

    @Test func placementCentersAndClamps() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let mid = WheelPlacement.frame(centeredOn: CGPoint(x: 700, y: 400), side: 200, within: visible)
        #expect(mid == CGRect(x: 600, y: 300, width: 200, height: 200))
        let corner = WheelPlacement.frame(centeredOn: CGPoint(x: 5, y: 890), side: 200, within: visible)
        #expect(corner == CGRect(x: 0, y: 700, width: 200, height: 200))
        let br = WheelPlacement.frame(centeredOn: CGPoint(x: 1439, y: 0), side: 200, within: visible)
        #expect(br == CGRect(x: 1240, y: 25, width: 200, height: 200))
    }
}

@Suite struct WheelHitTestTests {
    let g = WheelGeometry(hubRadius: 40, ringWidth: 60, ringGap: 4, maxPerRing: 8, margin: 10, edgeSlop: 6)

    @Test func hubAndOutside() {
        let m = WheelModel(items: makeItems(4), kind: .convert, geometry: g)
        #expect(m.hitTest(.zero) == .hub)
        #expect(m.hitTest(CGPoint(x: 0, y: 40)) == .hub)
        #expect(m.hitTest(CGPoint(x: 0, y: 104 + 6)) == .slice(WheelSlot(ring: 0, index: 0)))  // edge slop
        #expect(m.hitTest(CGPoint(x: 0, y: 104 + 6.5)) == .outside)
        #expect(m.hitTest(CGPoint(x: 200, y: 200)) == .outside)
    }

    @Test func gapBelongsToRingOutside() {
        let m = WheelModel(items: makeItems(4), kind: .convert, geometry: g)
        #expect(m.hitTest(CGPoint(x: 0, y: 42)) == .slice(WheelSlot(ring: 0, index: 0)))
    }

    @Test func fourSlicesByCompassDirection() {
        let m = WheelModel(items: makeItems(4), kind: .convert, geometry: g)
        let r: CGFloat = 70
        #expect(m.hitTest(CGPoint(x: 0, y: r)) == .slice(WheelSlot(ring: 0, index: 0)))    // N
        #expect(m.hitTest(CGPoint(x: r, y: 0)) == .slice(WheelSlot(ring: 0, index: 1)))    // E
        #expect(m.hitTest(CGPoint(x: 0, y: -r)) == .slice(WheelSlot(ring: 0, index: 2)))   // S
        #expect(m.hitTest(CGPoint(x: -r, y: 0)) == .slice(WheelSlot(ring: 0, index: 3)))   // W
        // Just either side of the N slice's left edge (−45°).
        let left = WheelModel.point(angle: -.pi / 4 + 0.01, radius: r)
        let right = WheelModel.point(angle: -.pi / 4 - 0.01, radius: r)
        #expect(m.hitTest(left) == .slice(WheelSlot(ring: 0, index: 0)))
        #expect(m.hitTest(right) == .slice(WheelSlot(ring: 0, index: 3)))
    }

    @Test func overflowRingHit() {
        let m = WheelModel(items: makeItems(10), kind: .convert, geometry: g)   // rings [8, 2]
        #expect(m.hitTest(CGPoint(x: 0, y: 70)) == .slice(WheelSlot(ring: 0, index: 0)))
        #expect(m.hitTest(CGPoint(x: 0, y: 140)) == .slice(WheelSlot(ring: 1, index: 0)))
        #expect(m.hitTest(CGPoint(x: 10, y: -140)) == .slice(WheelSlot(ring: 1, index: 1)))
        #expect(m.hitTest(CGPoint(x: 0, y: 106)) == .slice(WheelSlot(ring: 1, index: 0)))  // gap → outer ring
        #expect(m.hitTest(CGPoint(x: 0, y: 175)) == .outside)
    }

    @Test func emptyWheelHasOnlyHub() {
        let m = WheelModel(items: [], kind: .convert, geometry: g)
        #expect(m.hitTest(.zero) == .hub)
        #expect(m.hitTest(CGPoint(x: 0, y: 70)) == .outside)
    }

    @Test func sliceIndexNormalizesAngles() {
        #expect(WheelModel.sliceIndex(angle: 0, count: 8) == 0)
        #expect(WheelModel.sliceIndex(angle: 2 * .pi - 0.01, count: 8) == 0)
        #expect(WheelModel.sliceIndex(angle: -0.01, count: 8) == 0)
        #expect(WheelModel.sliceIndex(angle: .pi, count: 8) == 4)
        #expect(WheelModel.sliceIndex(angle: 5 * .pi, count: 8) == 4)
        #expect(WheelModel.sliceIndex(angle: 1, count: 1) == 0)
    }
}

@Suite struct WheelNavigationTests {
    @Test func firstPressSelects() {
        var m = WheelModel(items: makeItems(5), kind: .tools)
        #expect(m.handle(.right) == .moved(WheelSlot(ring: 0, index: 0)))
        var n = WheelModel(items: makeItems(5), kind: .tools)
        #expect(n.handle(.left) == .moved(WheelSlot(ring: 0, index: 4)))
    }

    @Test func leftRightWrapAround() {
        var m = WheelModel(items: makeItems(3), kind: .tools)
        m.select(WheelSlot(ring: 0, index: 2))
        #expect(m.handle(.right) == .moved(WheelSlot(ring: 0, index: 0)))
        #expect(m.handle(.left) == .moved(WheelSlot(ring: 0, index: 2)))
        #expect(m.handle(.left) == .moved(WheelSlot(ring: 0, index: 1)))
    }

    @Test func wrapStaysInsideOverflowRing() {
        var m = WheelModel(items: makeItems(11), kind: .tools)   // [8, 3]
        m.select(WheelSlot(ring: 1, index: 2))
        #expect(m.handle(.right) == .moved(WheelSlot(ring: 1, index: 0)))
    }

    @Test func singleSliceRingIgnoresCycling() {
        var m = WheelModel(items: makeItems(1), kind: .tools)
        #expect(m.handle(.right) == .moved(WheelSlot(ring: 0, index: 0)))
        #expect(m.handle(.right) == .ignored)
    }

    @Test func upDownHopRingsByNearestAngle() {
        var m = WheelModel(items: makeItems(12), kind: .convert)   // [8, 4]
        m.select(WheelSlot(ring: 0, index: 2))                      // 3 o'clock
        #expect(m.handle(.up) == .moved(WheelSlot(ring: 1, index: 1)))   // outer 3 o'clock
        #expect(m.handle(.up) == .ignored)                               // no ring 2: clamped
        #expect(m.handle(.down) == .moved(WheelSlot(ring: 0, index: 2)))
        #expect(m.handle(.down) == .ignored)
    }

    @Test func enterAppliesAndEscapeCancels() {
        var m = WheelModel(items: makeItems(4), kind: .actions)
        #expect(m.handle(.enter) == .ignored)   // nothing selected yet
        _ = m.handle(.right)
        _ = m.handle(.right)
        #expect(m.handle(.enter) == .apply(makeItems(4)[1]))
        #expect(m.handle(.escape) == .cancel)
    }

    @Test func emptyWheelOnlyCancels() {
        var m = WheelModel(items: [], kind: .actions)
        #expect(m.handle(.right) == .ignored)
        #expect(m.handle(.up) == .ignored)
        #expect(m.handle(.enter) == .ignored)
        #expect(m.handle(.escape) == .cancel)
    }

    @Test func selectRejectsMissingSlot() {
        var m = WheelModel(items: makeItems(2), kind: .actions)
        m.select(WheelSlot(ring: 0, index: 1))
        m.select(WheelSlot(ring: 3, index: 0))
        #expect(m.selection == WheelSlot(ring: 0, index: 1))
        m.select(nil)
        #expect(m.selection == nil)
    }

    @Test func keyCodes() {
        #expect(WheelKey(keyCode: 123) == .left)
        #expect(WheelKey(keyCode: 124) == .right)
        #expect(WheelKey(keyCode: 125) == .down)
        #expect(WheelKey(keyCode: 126) == .up)
        #expect(WheelKey(keyCode: 36) == .enter)
        #expect(WheelKey(keyCode: 76) == .enter)
        #expect(WheelKey(keyCode: 53) == .escape)
        #expect(WheelKey(keyCode: 0) == nil)
    }

    @Test func providerFeedsModel() {
        struct Fixed: WheelItemProvider {
            func items(for inputs: [URL], wheel: WheelKind) -> [WheelItem] {
                wheel == .actions ? makeItems(inputs.count + 1) : []
            }
        }
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
        #expect(WheelModel(provider: Fixed(), inputs: urls, kind: .actions).items.count == 3)
        #expect(WheelModel(provider: Fixed(), inputs: urls, kind: .convert).isEmpty)
    }
}
