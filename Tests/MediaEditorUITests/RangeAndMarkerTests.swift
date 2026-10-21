import Foundation
import Testing
@testable import MediaEditorUI

@Suite struct TimeRangeListTests {
    @Test func normalizesClampsSortsMergesAndDropsShort() {
        let list = TimeRangeList(duration: 10, minLength: 0.1, ranges: [
            8...12,        // clamped to 8...10
            -1...1,        // clamped to 0...1
            0.5...2,       // overlaps 0...1 → 0...2
            2.0005...3,    // touches (within tolerance) → 0...3
            5...5.05,      // shorter than minLength → dropped
            4...4,         // empty → dropped
        ])
        #expect(approx(list.ranges, [0...3, 8...10]))
        #expect(approx(list.totalLength, 5))
        #expect(approx(list.complement, [3...8]))
    }

    @Test func wholeClipAndQueries() {
        var list = TimeRangeList.whole(duration: 4)
        #expect(list.coversWholeClip)
        #expect(list.index(containing: 2) == 0)
        #expect(list.complement.isEmpty)
        list.setLowerBound(of: 0, to: 0.5)
        #expect(!list.coversWholeClip)
        #expect(approx(list.gap(containing: 0.2).map { [$0] } ?? [], [0...0.5]))
        #expect(list.gap(containing: 1) == nil)
    }

    @Test func addStretchesToMinLengthAndMerges() {
        var list = TimeRangeList(duration: 5, minLength: 0.5)
        let i = list.add(1...1.1)
        #expect(i == 0)
        #expect(approx(list.ranges, [1...1.5]))
        list.add(4.9...5)   // stretched backwards to stay inside the clip
        #expect(approx(list.ranges, [1...1.5, 4.5...5]))
        list.add(1.4...2)   // overlaps the first → merged
        #expect(approx(list.ranges, [1...2, 4.5...5]))
    }

    @Test func insertFitsInsideTheGapAroundThePlayhead() {
        var list = TimeRangeList(duration: 10, minLength: 0.1, ranges: [0...2, 6...10])
        // Inside an existing range → returns it, no change.
        #expect(list.insert(at: 1, length: 1) == 0)
        #expect(list.count == 2)
        // Too long for the gap end → shifted back, still separate from the neighbour after normalize.
        let i = list.insert(at: 5.5, length: 2)
        #expect(i == 1)
        list.normalize()
        #expect(list.count == 3)
        #expect(list.ranges[1].upperBound < 6)
        #expect(approx(list.ranges[1].upperBound - list.ranges[1].lowerBound, 2))
        // Gap narrower than minLength → nothing added.
        var tight = TimeRangeList(duration: 1, minLength: 0.1, ranges: [0...0.5, 0.55...1])
        #expect(tight.insert(at: 0.52, length: 1) == nil)
        #expect(tight.count == 2)
    }

    @Test func subtractSplitsAndDropsSlivers() {
        var list = TimeRangeList.whole(duration: 10, minLength: 0.5)
        list.subtract(4...6)
        #expect(approx(list.ranges, [0...4, 6...10]))
        list.subtract(3.8...9.7)   // leaves 0...3.8 and a 0.3 s sliver (dropped)
        #expect(approx(list.ranges, [0...3.8]))
        list.subtract(-5...20)
        #expect(list.isEmpty)
    }

    @Test func boundEditsClampToNeighboursAndMinLength() {
        var list = TimeRangeList(duration: 10, minLength: 0.5, ranges: [1...3, 5...7])
        #expect(approx(list.setLowerBound(of: 1, to: 2), 3))      // can't pass the previous end
        #expect(approx(list.setLowerBound(of: 1, to: 6.9), 6.5))  // keeps minLength
        #expect(approx(list.setUpperBound(of: 0, to: 9), 6.5))    // can't pass the next start (now 6.5)
        #expect(approx(list.setUpperBound(of: 0, to: 0), 1.5))    // keeps minLength
        #expect(approx(list.setLowerBound(of: 0, to: -3), 0))
        #expect(approx(list.setUpperBound(of: 1, to: 30), 10))
        // Touching after a drag → merged by normalize.
        list.setUpperBound(of: 0, to: 6.5)
        list.normalize()
        #expect(approx(list.ranges, [0...10]))
    }

    @Test func moveKeepsLengthBetweenNeighbours() {
        var list = TimeRangeList(duration: 10, minLength: 0.1, ranges: [0...1, 3...4, 8...9])
        list.move(1, by: 10)
        #expect(approx(list.ranges[1], 7...8))
        list.move(1, by: -10)
        #expect(approx(list.ranges[1], 1...2))
    }

    @Test func removeAndBadIndicesAreSafe() {
        var list = TimeRangeList(duration: 3, ranges: [0...1, 2...3])
        list.remove(at: 5)
        list.setLowerBound(of: 9, to: 1)
        #expect(list.count == 2)
        list.remove(at: 0)
        #expect(approx(list.ranges, [2...3]))
    }

    @Test func zeroDurationIsInert() {
        var list = TimeRangeList.whole(duration: 0)
        #expect(list.isEmpty)
        #expect(list.add(0...1) == nil)
    }
}

private func approx(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Bool {
    approx([a], [b])
}

@Suite struct SplitMarkerTests {
    @Test func markersBecomeConsecutiveParts() {
        var m = SplitMarkers(duration: 10, minGap: 0.5)
        #expect(approx(m.parts, [0...10]))
        #expect(m.add(7) == 0)
        #expect(m.add(3) == 0)
        #expect(m.partCount == 3)
        #expect(approx(m.parts, [0...3, 3...7, 7...10]))
    }

    @Test func rejectsMarkersTooCloseToEndsOrEachOther() {
        var m = SplitMarkers(duration: 10, minGap: 0.5, times: [5])
        #expect(m.add(0.2) == nil)
        #expect(m.add(9.8) == nil)
        #expect(m.add(5.3) == nil)
        #expect(!m.canAdd(.nan))
        #expect(m.add(5.6) == 1)
        #expect(m.times == [5, 5.6])
        // Init drops invalid times too.
        let n = SplitMarkers(duration: 2, minGap: 0.5, times: [1, 1.2, 0.1, 1.9, 1.5])
        #expect(n.times == [1, 1.5])
    }

    @Test func moveClampsBetweenNeighbours() {
        var m = SplitMarkers(duration: 10, minGap: 1, times: [3, 6])
        let a = m.move(0, to: 8), b = m.move(0, to: -2), c = m.move(1, to: 9.9)
        #expect(approx(a, 5))
        #expect(approx(b, 1))
        #expect(approx(c, 9))
        #expect(m.times == [1, 9])
    }

    @Test func equalPartsAndRemoval() {
        var m = SplitMarkers(duration: 9, minGap: 0.5)
        m.setEqualParts(3)
        #expect(approx(m.parts, [0...3, 3...6, 6...9]))
        m.setEqualParts(1000)   // capped so parts stay ≥ minGap
        #expect(m.partCount == 18)
        m.setEqualParts(1)
        #expect(m.isEmpty)
        m.setEqualParts(2)
        let far = m.removeNearest(to: 3, within: 0.5)
        let near = m.removeNearest(to: 4.7, within: 0.5)
        #expect(!far)
        #expect(near)
        #expect(m.isEmpty)
    }
}
