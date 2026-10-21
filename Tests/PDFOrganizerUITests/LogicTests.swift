import AppKit
import Foundation
import RondoKit
import Testing
@testable import PDFOrganizerUI

private func pages(_ v: OptionValue?) -> [Int]? {
    if case .list(let l)? = v { return l.map { Int($0) } }
    return nil
}

@Suite struct UndoAndMoveTests {
    @Test func undoableRecordsOnlyRealChanges() {
        var u = Undoable(1)
        #expect(!u.apply { $0 = 1 })
        #expect(!u.canUndo)
        #expect(u.apply { $0 += 1 })
        #expect(u.apply { $0 += 1 })
        #expect(u.current == 3)
        #expect(u.undo() && u.current == 2)
        #expect(u.redo() && u.current == 3)
        u.undo(); u.undo()
        #expect(u.current == 1 && !u.canUndo && !u.undo())
        u.apply { $0 = 9 }
        #expect(!u.canRedo)   // a new edit clears redo
    }

    @Test func undoLimit() {
        var u = Undoable(0, limit: 3)
        for _ in 0..<10 { u.apply { $0 += 1 } }
        var steps = 0
        while u.undo() { steps += 1 }
        #expect(steps == 3 && u.current == 7)
    }

    struct Box: Identifiable, Equatable { let id: Int }

    @Test func movingKeepsRelativeOrder() {
        let a = (1...6).map(Box.init)
        #expect(a.moving([5], to: 0).map(\.id) == [5, 1, 2, 3, 4, 6])
        #expect(a.moving([1], to: 6).map(\.id) == [2, 3, 4, 5, 6, 1])
        #expect(a.moving([1], to: 3).map(\.id) == [2, 3, 1, 4, 5, 6])          // before original index 3 (id 4)
        #expect(a.moving([2, 5], to: 0).map(\.id) == [2, 5, 1, 3, 4, 6])
        #expect(a.moving([5, 2], to: 6).map(\.id) == [1, 3, 4, 6, 2, 5])       // relative order kept, not set order
        #expect(a.moving([3], to: 3).map(\.id) == [1, 2, 3, 4, 5, 6])          // onto itself
        #expect(a.moving([3], to: 99).map(\.id) == [1, 2, 4, 5, 6, 3])         // clamped
        #expect(a.moving([42], to: 0).map(\.id) == [1, 2, 3, 4, 5, 6])         // unknown id
    }
}

@Suite struct PageArrangementTests {
    @Test func initialIsIdentityAndOptionsEmpty() {
        let a = PageArrangement(pageCount: 4)
        #expect(a.items.map(\.source) == [1, 2, 3, 4])
        #expect(a.isUnchanged)
        #expect(a.options.isEmpty)
        #expect(PageArrangement(pageCount: 0).items.isEmpty)
    }

    @Test func rotationAccumulatesMod360() {
        var a = PageArrangement(pageCount: 3)
        a.rotate([2], by: 90)
        a.rotate([2], by: 90)
        a.rotate([2], by: 90)
        #expect(a.items[1].rotation == 270)
        a.rotate([2], by: 90)
        #expect(a.items[1].rotation == 0)
        #expect(a.isUnchanged)
        a.rotate([1, 3], by: -90)
        #expect(a.items.map(\.rotation) == [270, 0, 270])
        #expect(PageArrangement.normalized(-450) == 270)
        #expect(PageArrangement.normalized(100) == 90)       // snapped to 90° steps
    }

    @Test func rotationOnlyOptions() {
        var a = PageArrangement(pageCount: 4)
        a.rotate([3], by: 90)
        #expect(a.options.keys.sorted() == ["rotations"])
        #expect(pages(a.options["rotations"]) == [0, 0, 90, 0])
    }

    @Test func deleteOnlyUsesDeletionsWithParallelRotations() {
        var a = PageArrangement(pageCount: 5)
        a.delete([2, 4])
        #expect(a.items.map(\.source) == [1, 3, 5])
        #expect(a.deletedSources == [2, 4])
        #expect(a.options.keys.sorted() == ["deletions"])
        #expect(pages(a.options["deletions"]) == [2, 4])
        a.rotate([5], by: 180)
        // Engine walks 1…N when `order` is absent, so rotations are parallel to all source pages.
        #expect(pages(a.options["rotations"]) == [0, 0, 0, 0, 180])
        #expect(a.options["order"] == nil)
    }

    @Test func reorderEmitsOrderWithoutDeletedPages() {
        var a = PageArrangement(pageCount: 4)
        a.move([4], to: 0)          // 4 1 2 3
        a.delete([2])               // 4 1 3
        a.rotate([1], by: 90)
        let o = a.options
        #expect(pages(o["order"]) == [4, 1, 3])
        #expect(pages(o["rotations"]) == [0, 90, 0])       // parallel to order
        #expect(o["deletions"] == nil)                     // implied by order
    }

    @Test func moveBackToOriginalIsUnchanged() {
        var a = PageArrangement(pageCount: 3)
        a.move([1], to: 3)
        #expect(!a.isUnchanged)
        a.move([1], to: 0)
        #expect(a.isUnchanged && a.options.isEmpty)
    }

    @Test func deleteAndUndoRestoresExactly() {
        var u = Undoable(PageArrangement(pageCount: 3))
        u.apply { $0.rotate([3], by: 90) }
        u.apply { $0.delete([3]) }
        #expect(u.current.items.map(\.source) == [1, 2])
        u.undo()
        #expect(u.current.items.map(\.source) == [1, 2, 3])
        #expect(u.current.items[2].rotation == 90)
        u.undo()
        #expect(u.current.isUnchanged)
    }

    @Test func deletingEverythingLeavesNothing() {
        var a = PageArrangement(pageCount: 2)
        a.delete([1, 2])
        #expect(a.items.isEmpty)
        #expect(pages(a.options["deletions"]) == [1, 2])
    }
}

@Suite struct SplitPlanTests {
    @Test func runsAreSortedContiguousAndClamped() {
        #expect(SplitPlan.runs([7, 1, 2, 3, 5, 8], pageCount: 10) == [1...3, 5...5, 7...8])
        #expect(SplitPlan.runs([], pageCount: 10) == [])
        #expect(SplitPlan.runs([0, 1, 11, 10], pageCount: 10) == [1...1, 10...10])
        #expect(SplitPlan.runs([4], pageCount: 4) == [4...4])
    }

    @Test func addPartsKeepsAdjacentPartsSeparate() {
        var p = SplitPlan(pageCount: 10)
        p.addParts(from: [1, 2, 3])
        p.addParts(from: [4, 5, 6])
        #expect(p.parts == [1...3, 4...6])          // not merged into 1…6
        p.addParts(from: [9, 7])
        #expect(p.parts == [1...3, 4...6, 7...7, 9...9])
    }

    @Test func newPartWinsOverlaps() {
        var p = SplitPlan(pageCount: 10, parts: [1...6])
        p.addParts(from: [3, 4])
        #expect(p.parts == [1...2, 3...4, 5...6])
        p.addParts(from: [2, 3, 4, 5])
        #expect(p.parts == [1...1, 2...5, 6...6])
        // no overlaps, sorted
        let flat = p.parts.flatMap { $0 }
        #expect(flat == flat.sorted() && Set(flat).count == flat.count)
    }

    @Test func removePagesAndParts() {
        var p = SplitPlan(pageCount: 8, parts: [1...4, 6...8])
        p.remove(pages: [2])
        #expect(p.parts == [1...1, 3...4, 6...8])
        p.removePart(6...8)
        #expect(p.parts == [1...1, 3...4])
        p.clear()
        #expect(p.parts.isEmpty)
    }

    @Test func includeRestFillsGaps() {
        var p = SplitPlan(pageCount: 10, parts: [3...4, 8...8])
        #expect(p.uncovered == [1...2, 5...7, 9...10])
        #expect(p.outputRanges == [3...4, 8...8])
        p.includeRest = true
        #expect(p.outputRanges == [1...2, 3...4, 5...7, 8...8, 9...10])
        // "split after page 3" workflow
        var q = SplitPlan(pageCount: 10)
        q.addParts(from: [1, 2, 3])
        q.includeRest = true
        #expect(q.outputRanges == [1...3, 4...10])
    }

    @Test func normalizeClampsAndResolvesOverlaps() {
        let p = SplitPlan(pageCount: 5, parts: [0...2, 4...9, 2...3, 7...8])
        #expect(p.parts == [1...1, 2...3, 4...5])
    }

    @Test func addingIsNonMutating() {
        let p = SplitPlan(pageCount: 6, parts: [1...2])
        #expect(p.adding([5, 6]).outputRanges == [1...2, 5...6])
        #expect(p.parts == [1...2])
        #expect(p.adding([]).parts == [1...2])
    }

    @Test func everyAndOptions() {
        #expect(SplitPlan.every(2, pageCount: 5) == [1...2, 3...4, 5...5])
        #expect(SplitPlan.every(0, pageCount: 2) == [1...1, 2...2])
        #expect(SplitPlan.every(9, pageCount: 3) == [1...3])
        #expect(SplitPlan.options(every: 3) == ["every": .int(3)])
        #expect(SplitPlan.options(ranges: [1...3, 5...5]) == ["ranges": .ranges([1...3, 5...5])])
        #expect(SplitPlan.describe([1...3, 5...5, 7...8]) == "1–3, 5, 7–8")
    }
}

@Suite struct MergeListTests {
    func entry(_ name: String, _ n: Int = 1) -> MergeEntry {
        MergeEntry(url: URL(fileURLWithPath: "/tmp/w8/\(name)"), pageCount: n)
    }

    @Test func addDedupesAndInserts() {
        var l = MergeList([entry("a.pdf", 2), entry("b.pdf", 3)])
        #expect(l.add([entry("a.pdf"), entry("c.pdf")]) == 1)
        #expect(l.inputs.map(\.lastPathComponent) == ["a.pdf", "b.pdf", "c.pdf"])
        l.add([entry("z.pdf")], at: 0)
        #expect(l.inputs.first?.lastPathComponent == "z.pdf")
        #expect(MergeList([entry("x.pdf"), entry("./x.pdf")]).entries.count == 1)
        #expect(l.totalPages == 2 + 3 + 1 + 1)
    }

    @Test func moveShiftRemoveSort() {
        var l = MergeList(["c.pdf", "a.pdf", "b.pdf", "d.pdf"].map { entry($0) })
        let ids = l.entries.map(\.id)
        l.move([ids[3]], to: 0)
        #expect(l.inputs.map(\.lastPathComponent) == ["d.pdf", "c.pdf", "a.pdf", "b.pdf"])
        l.shift([ids[1], ids[2]], by: -1)                     // a, b up one as a block
        #expect(l.inputs.map(\.lastPathComponent) == ["d.pdf", "a.pdf", "b.pdf", "c.pdf"])
        l.shift([ids[1]], by: 1)                              // a down one
        #expect(l.inputs.map(\.lastPathComponent) == ["d.pdf", "b.pdf", "a.pdf", "c.pdf"])
        l.shift([ids[1], ids[0]], by: 1)                      // a + c block already at the end: no-op
        #expect(l.inputs.map(\.lastPathComponent) == ["d.pdf", "b.pdf", "a.pdf", "c.pdf"])
        l.shift([ids[3]], by: -1)                             // already first: no-op
        #expect(l.inputs.first?.lastPathComponent == "d.pdf")
        l.sortByName()
        #expect(l.inputs.map(\.lastPathComponent) == ["a.pdf", "b.pdf", "c.pdf", "d.pdf"])
        l.remove([ids[0], ids[3]])
        #expect(l.inputs.map(\.lastPathComponent) == ["a.pdf", "b.pdf"])
        #expect(l.canSubmit)
        l.remove([ids[1]])
        #expect(!l.canSubmit)
    }

    @Test func sortIsNumericAware() {
        var l = MergeList(["part 10.pdf", "part 2.pdf", "part 1.pdf"].map { entry($0) })
        l.sortByName()
        #expect(l.inputs.map(\.lastPathComponent) == ["part 1.pdf", "part 2.pdf", "part 10.pdf"])
    }
}

@Suite struct SelectionAndKeyTests {
    @Test func finderStyleClicks() {
        var s = SelectionState<Int>()
        let order = [10, 20, 30, 40, 50]
        s.click(20, kind: .plain, order: order)
        #expect(s.selected == [20])
        s.click(40, kind: .extend, order: order)
        #expect(s.selected == [20, 30, 40])
        s.click(30, kind: .toggle, order: order)
        #expect(s.selected == [20, 40])
        s.click(10, kind: .toggle, order: order)
        #expect(s.selected == [10, 20, 40])
        s.click(50, kind: .plain, order: order)
        #expect(s.selected == [50])
        s.step(-1, order: order)
        #expect(s.selected == [40])
        s.step(5, order: order)
        #expect(s.selected == [50])
        s.selectAll(order)
        #expect(s.selected.count == 5)
        s.prune(to: [10, 20])
        #expect(s.selected == [10, 20])
        s.clear()
        s.step(1, order: order)
        #expect(s.selected == [10])
    }

    @Test func clickKindFromModifiers() {
        #expect(ClickKind([]) == .plain)
        #expect(ClickKind(.command) == .toggle)
        #expect(ClickKind([.shift, .command]) == .extend)
    }

    @Test func keyMapping() {
        func cmd(_ code: UInt16, _ chars: String?, _ mods: NSEvent.ModifierFlags, editing: Bool = false) -> OrganizerCommand? {
            OrganizerCommand.from(keyCode: code, characters: chars, modifiers: mods, editingText: editing)
        }
        #expect(cmd(51, "\u{7f}", []) == .deleteSelection)
        #expect(cmd(117, nil, []) == .deleteSelection)
        #expect(cmd(51, nil, [], editing: true) == nil)            // text field gets ⌫
        #expect(cmd(15, "r", .command) == .rotateRight)
        #expect(cmd(15, "R", [.command, .shift]) == .rotateLeft)
        #expect(cmd(37, "l", .command) == .rotateLeft)
        #expect(cmd(6, "z", .command) == .undo)
        #expect(cmd(6, "Z", [.command, .shift]) == .redo)
        #expect(cmd(0, "a", .command) == .selectAll)
        #expect(cmd(53, "\u{1b}", []) == .cancel)
        #expect(cmd(53, nil, [], editing: true) == .cancel)
        #expect(cmd(13, "w", .command) == .cancel)
        #expect(cmd(36, "\r", .command) == .submit)
        #expect(cmd(36, "\r", []) == nil)                         // plain Return never submits
        #expect(cmd(123, nil, .function) == .step(-1))           // arrows carry .function — ignored
        #expect(cmd(124, nil, []) == .step(1))
        #expect(cmd(15, "r", []) == nil)
        #expect(cmd(15, "r", [.command, .option]) == nil)
    }
}
