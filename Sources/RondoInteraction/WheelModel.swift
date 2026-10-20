import CoreGraphics
import Foundation
import RondoKit

// Pure wheel logic: ring layout, slice geometry, hit testing, keyboard navigation.
// No AppKit — everything here is unit-tested.
//
// Coordinates: points relative to the wheel center, y up (AppKit non-flipped).
// Angles: radians clockwise from 12 o'clock, in [0, 2π). Slice 0 of every ring is centered at 12 o'clock.

/// Address of one slice: ring 0 is the inner ring, higher rings are overflow rings outside it.
public struct WheelSlot: Hashable, Sendable, CustomStringConvertible {
    public var ring: Int
    public var index: Int

    public init(ring: Int, index: Int) {
        self.ring = ring
        self.index = index
    }

    public var description: String { "(\(ring),\(index))" }
}

public enum WheelHit: Equatable, Sendable {
    /// Center hub — cancels.
    case hub
    case slice(WheelSlot)
    /// Outside every ring.
    case outside
}

/// Keys the wheel understands (arrows cycle/ring-hop, Enter applies, Esc cancels).
public enum WheelKey: Equatable, Sendable {
    case left, right, up, down, enter, escape

    /// Maps a macOS virtual key code (`NSEvent.keyCode`).
    public init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        case 36, 76: self = .enter   // Return, keypad Enter
        case 53: self = .escape
        default: return nil
        }
    }
}

public enum WheelNavResult: Equatable, Sendable {
    case ignored
    case moved(WheelSlot)
    case apply(WheelItem)
    case cancel
}

/// Size knobs for the wheel. All in points.
public struct WheelGeometry: Equatable, Sendable {
    public var hubRadius: CGFloat
    public var ringWidth: CGFloat
    public var ringGap: CGFloat
    /// Max slices per ring; extra items spill into overflow rings outside.
    public var maxPerRing: Int
    /// Transparent border around the outer ring (shadow + edge slop).
    public var margin: CGFloat
    /// A point this far beyond the outer edge still hits the outer ring (forgiving drops).
    public var edgeSlop: CGFloat

    public init(
        hubRadius: CGFloat = 46,
        ringWidth: CGFloat = 66,
        ringGap: CGFloat = 3,
        maxPerRing: Int = 8,
        margin: CGFloat = 14,
        edgeSlop: CGFloat = 8
    ) {
        self.hubRadius = hubRadius
        self.ringWidth = ringWidth
        self.ringGap = ringGap
        self.maxPerRing = max(1, maxPerRing)
        self.margin = margin
        self.edgeSlop = edgeSlop
    }
}

/// One annular sector. Angles clockwise from 12 o'clock; `endAngle > startAngle` (start may be negative).
public struct SliceArc: Equatable, Sendable {
    public var innerRadius: CGFloat
    public var outerRadius: CGFloat
    public var startAngle: CGFloat
    public var endAngle: CGFloat

    public var midAngle: CGFloat { (startAngle + endAngle) / 2 }
    public var midRadius: CGFloat { (innerRadius + outerRadius) / 2 }
    public var sweep: CGFloat { endAngle - startAngle }

    /// Point on the arc's mid-angle at `radius`, relative to the wheel center.
    public func point(atRadius radius: CGFloat) -> CGPoint {
        WheelModel.point(angle: midAngle, radius: radius)
    }

    /// Chord length across the slice at its mid radius — usable label width.
    public var midChord: CGFloat {
        sweep >= .pi ? .greatestFiniteMagnitude : 2 * midRadius * sin(sweep / 2)
    }
}

public struct WheelModel: Equatable, Sendable {
    public let kind: WheelKind
    public let items: [WheelItem]
    public let geometry: WheelGeometry
    /// Item indices per ring, inner ring first.
    public let rings: [[Int]]
    public private(set) var selection: WheelSlot?

    public init(items: [WheelItem], kind: WheelKind, geometry: WheelGeometry = WheelGeometry()) {
        self.kind = kind
        self.items = items
        self.geometry = geometry
        var rings: [[Int]] = []
        var start = 0
        for size in Self.ringSizes(count: items.count, maxPerRing: geometry.maxPerRing) {
            rings.append(Array(start..<(start + size)))
            start += size
        }
        self.rings = rings
    }

    /// Builds the model from a provider (convert targets / tools / actions for `inputs`).
    public init(provider: WheelItemProvider, inputs: [URL], kind: WheelKind, geometry: WheelGeometry = WheelGeometry()) {
        self.init(items: provider.items(for: inputs, wheel: kind), kind: kind, geometry: geometry)
    }

    /// Ring fill: inner ring takes up to `maxPerRing`, each overflow ring the next `maxPerRing`.
    public static func ringSizes(count: Int, maxPerRing: Int) -> [Int] {
        guard count > 0 else { return [] }
        let cap = max(1, maxPerRing)
        var sizes: [Int] = []
        var left = count
        while left > 0 {
            sizes.append(min(cap, left))
            left -= cap
        }
        return sizes
    }

    public var isEmpty: Bool { items.isEmpty }
    public var ringCount: Int { rings.count }

    /// Radial band of `ring`. An empty wheel still reserves one ring (for its "no options" message).
    public func radii(ring: Int) -> (inner: CGFloat, outer: CGFloat) {
        let g = geometry
        let inner = g.hubRadius + g.ringGap + CGFloat(ring) * (g.ringWidth + g.ringGap)
        return (inner, inner + g.ringWidth)
    }

    /// Outer edge of the outermost ring.
    public var outerRadius: CGFloat { radii(ring: max(ringCount, 1) - 1).outer }

    /// Side of the square panel/view that fits the wheel plus margin.
    public var diameter: CGFloat { ceil(2 * (outerRadius + geometry.margin)) }

    public func item(at slot: WheelSlot) -> WheelItem? {
        guard rings.indices.contains(slot.ring), rings[slot.ring].indices.contains(slot.index) else { return nil }
        return items[rings[slot.ring][slot.index]]
    }

    public func slot(ofItem id: WheelItem.ID) -> WheelSlot? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        for (r, ring) in rings.enumerated() {
            if let j = ring.firstIndex(of: i) { return WheelSlot(ring: r, index: j) }
        }
        return nil
    }

    public var allSlots: [WheelSlot] {
        rings.enumerated().flatMap { r, ring in ring.indices.map { WheelSlot(ring: r, index: $0) } }
    }

    public func arc(for slot: WheelSlot) -> SliceArc {
        let n = max(rings.indices.contains(slot.ring) ? rings[slot.ring].count : 1, 1)
        let step = 2 * CGFloat.pi / CGFloat(n)
        let mid = CGFloat(slot.index) * step
        let (inner, outer) = radii(ring: slot.ring)
        return SliceArc(innerRadius: inner, outerRadius: outer, startAngle: mid - step / 2, endAngle: mid + step / 2)
    }

    // MARK: Hit testing

    /// `point` relative to the wheel center, y up.
    public func hitTest(_ point: CGPoint) -> WheelHit {
        let r = hypot(point.x, point.y)
        if r <= geometry.hubRadius { return .hub }
        guard !rings.isEmpty else { return .outside }
        // Ring bands are contiguous (gaps belong to the ring outside them) so there are no dead zones.
        var ring: Int?
        for k in rings.indices where r <= radii(ring: k).outer {
            ring = k
            break
        }
        if ring == nil, r <= outerRadius + geometry.edgeSlop { ring = rings.count - 1 }
        guard let ring else { return .outside }
        return .slice(WheelSlot(ring: ring, index: Self.sliceIndex(angle: Self.angle(of: point), count: rings[ring].count)))
    }

    /// Clockwise angle from 12 o'clock in [0, 2π).
    public static func angle(of point: CGPoint) -> CGFloat {
        var a = atan2(point.x, point.y)
        if a < 0 { a += 2 * .pi }
        return a
    }

    public static func point(angle: CGFloat, radius: CGFloat) -> CGPoint {
        CGPoint(x: sin(angle) * radius, y: cos(angle) * radius)
    }

    /// Slice under `angle` for a ring of `count` slices centered on multiples of 2π/count.
    public static func sliceIndex(angle: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let step = 2 * CGFloat.pi / CGFloat(count)
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return Int(floor((a + step / 2) / step)) % count
    }

    // MARK: Selection + keyboard

    public mutating func select(_ slot: WheelSlot?) {
        if let slot, item(at: slot) == nil { return }
        selection = slot
    }

    public var selectedItem: WheelItem? { selection.flatMap(item(at:)) }

    /// ←/→ cycle within the ring (→ = clockwise, wraps), ↑ = outer ring, ↓ = inner ring (nearest slice by
    /// angle, clamped), Enter applies the selection, Esc cancels.
    public mutating func handle(_ key: WheelKey) -> WheelNavResult {
        switch key {
        case .escape:
            return .cancel
        case .enter:
            guard let item = selectedItem else { return .ignored }
            return .apply(item)
        case .left, .right, .up, .down:
            guard !rings.isEmpty else { return .ignored }
            guard let current = selection else {
                let first = WheelSlot(ring: 0, index: key == .left ? rings[0].count - 1 : 0)
                selection = first
                return .moved(first)
            }
            var next = current
            switch key {
            case .right:
                next.index = (current.index + 1) % rings[current.ring].count
            case .left:
                let n = rings[current.ring].count
                next.index = (current.index - 1 + n) % n
            case .up, .down:
                let target = current.ring + (key == .up ? 1 : -1)
                guard rings.indices.contains(target) else { return .ignored }
                next = WheelSlot(
                    ring: target,
                    index: Self.sliceIndex(angle: arc(for: current).midAngle, count: rings[target].count)
                )
            default:
                break
            }
            guard next != current else { return .ignored }
            selection = next
            return .moved(next)
        }
    }
}

/// Where the wheel window goes: centered on the cursor, clamped inside the screen's visible frame.
public enum WheelPlacement {
    public static func frame(centeredOn point: CGPoint, side: CGFloat, within visible: CGRect) -> CGRect {
        var origin = CGPoint(x: point.x - side / 2, y: point.y - side / 2)
        if visible.width >= side {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - side)
        }
        if visible.height >= side {
            origin.y = min(max(origin.y, visible.minY), visible.maxY - side)
        }
        return CGRect(origin: origin, size: CGSize(width: side, height: side))
    }
}
