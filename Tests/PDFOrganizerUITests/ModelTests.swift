import AppKit
import Foundation
import PDFKit
import RondoKit
import Testing
@testable import PDFOrganizerUI

@MainActor
@Suite struct OrganizerModelTests {
    let five = W8Fixtures.makePDF("five.pdf", pages: 5, landscape: [4])

    @Test func reorderModelDeleteUndoAndPayload() throws {
        let m = ReorderModel(url: five)
        #expect(m.loadError == nil && m.items.count == 5)
        #expect(!m.canSubmit)                                  // unchanged → nothing to save
        #expect(m.payload() == nil)
        m.click(2, kind: .plain)
        m.click(3, kind: .toggle)
        #expect(m.perform(.deleteSelection))
        #expect(m.items.map(\.source) == [1, 4, 5])
        #expect(m.selection.selected == [4])                   // neighbor stays selected for repeated ⌫
        #expect(m.perform(.undo))
        #expect(m.items.map(\.source) == [1, 2, 3, 4, 5])
        #expect(m.selection.selected == [2, 3])                // restored pages reselected
        #expect(m.perform(.rotateRight))
        #expect(m.perform(.rotateRight))
        #expect(m.perform(.rotateLeft))
        #expect(m.items.map(\.rotation) == [0, 90, 90, 0, 0])
        let payload = try #require(m.payload())
        #expect(payload.inputs == [five])
        #expect(payload.options == ["rotations": .list([0, 90, 90, 0, 0])])
        #expect(m.perform(.redo) == true)                     // nothing to redo: handled, no change
        #expect(m.perform(.cancel) == false && m.perform(.submit) == false)
    }

    @Test func reorderDragDrop() {
        let m = ReorderModel(url: five)
        m.click(1, kind: .plain)
        m.click(2, kind: .extend)
        m.beginDrag(2)                                         // dragging a selected page drags the selection
        #expect(m.dragging == [1, 2])
        m.drop(on: .init(id: 5, before: false))
        #expect(m.items.map(\.source) == [3, 4, 5, 1, 2])
        #expect(m.dragging == nil)
        m.beginDrag(4)                                         // unselected page → drags just that page
        #expect(m.selection.selected == [4])
        m.drop(on: .init(id: 3, before: true))
        #expect(m.items.map(\.source) == [4, 3, 5, 1, 2])
        m.beginDrag(4)
        m.drop(on: .init(id: 4, before: true))                 // onto itself: no-op
        #expect(m.items.map(\.source) == [4, 3, 5, 1, 2])
        m.beginDrag(3)
        m.dropAtEnd()
        #expect(m.items.map(\.source) == [4, 5, 1, 2, 3])
        #expect(m.payload()?.options == ["order": .list([4, 5, 1, 2, 3])])
    }

    @Test func deletingAllPagesBlocksSubmit() {
        let m = ReorderModel(url: five)
        m.selectAll()
        m.deleteSelection()
        #expect(m.items.isEmpty && !m.canSubmit && m.payload() == nil)
        #expect(m.statusText.contains("nothing left"))
    }

    @Test func unreadableFileShowsError() throws {
        let bogus = W8Fixtures.dir("src").appendingPathComponent("not-a.pdf")
        try Data("hello".utf8).write(to: bogus)
        let m = ReorderModel(url: bogus)
        #expect(m.loadError != nil && !m.canSubmit)
        #expect(m.perform(.selectAll) == false)
        let s = SplitModel(url: URL(fileURLWithPath: "/nonexistent/x.pdf"))
        #expect(s.loadError != nil && !s.canSubmit)
    }

    @Test func splitModelSelectionAndParts() throws {
        let m = SplitModel(url: five)
        #expect(m.pageCount == 5 && !m.canSubmit)
        m.click(1, kind: .plain)
        m.click(2, kind: .extend)
        #expect(m.outputRanges == [1...2])                     // live selection previews as a part
        m.addPart()
        #expect(m.plan.parts == [1...2] && m.selection.selected.isEmpty)
        m.click(3, kind: .plain)
        m.addPart()
        m.setIncludeRest(true)
        #expect(m.outputRanges == [1...2, 3...3, 4...5])
        #expect(m.partIndex(of: 4) == 2)
        let p = try #require(m.payload())
        #expect(p.options == ["ranges": .ranges([1...2, 3...3, 4...5])])
        #expect(m.perform(.undo))                              // undo includeRest
        #expect(m.outputRanges == [1...2, 3...3])
        #expect(m.partIndex(of: 5) == nil)
        m.click(2, kind: .plain)
        #expect(m.perform(.deleteSelection))                   // ⌫ takes page 2 out of its part
        m.selection.clear()
        #expect(m.plan.parts == [1...1, 3...3])
        #expect(m.perform(.rotateRight) == false)              // not a split command
        m.style = .every
        m.every = 2
        #expect(m.outputRanges == [1...2, 3...4, 5...5])
        #expect(m.payload()?.options == ["every": .int(2)])
        #expect(m.statusText.contains("3 PDFs"))
    }

    @Test func mergeModelFiltersAndOrders() throws {
        let a = W8Fixtures.makePDF("merge-a.pdf", pages: 2, label: "A")
        let b = W8Fixtures.makePDF("merge-b.pdf", pages: 1, label: "B")
        let txt = W8Fixtures.dir("src").appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: txt)
        let m = MergeModel(urls: [a, txt, b])
        #expect(m.entries.map(\.url) == [a, b])
        #expect(m.notice?.contains("note.txt") == true)
        #expect(m.list.totalPages == 3)
        m.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(m.payload()?.inputs == [b, a])
        #expect(m.payload()?.options == [:])
        m.add([a])                                             // duplicate
        #expect(m.entries.count == 2 && m.notice?.contains("already") == true)
        m.selection = [m.entries[0].id]
        #expect(m.perform(.deleteSelection))
        #expect(!m.canSubmit && m.payload() == nil)
        #expect(m.perform(.undo))
        #expect(m.payload()?.inputs == [b, a])
        #expect(m.perform(.step(1)) == false)
    }

    @Test func controllerRouting() {
        #expect(PDFOrganizer.makeController(urls: [five], tool: "pdf.reorder") is ReorderModel)
        #expect(PDFOrganizer.makeController(urls: [five, five], tool: "pdf.split") is SplitModel)
        #expect(PDFOrganizer.makeController(urls: [five], tool: "pdf.merge") is MergeModel)
        #expect(PDFOrganizer.makeController(urls: [five], tool: "pdf.compress") == nil)
        #expect(PDFOrganizer.makeController(urls: [], tool: "pdf.reorder") == nil)
        #expect(PDFOrganizer.supportedTools.count == 3)
    }

    @Test func windowSubmitsOnceThenCloses() throws {
        _ = NSApplication.shared
        let m = ReorderModel(url: five)
        var calls: [([URL], ToolID, [String: OptionValue])] = []
        let wc = OrganizerWindowController(controller: m) { calls.append(($0, $1, $2)) }
        wc.commit()                                            // nothing changed → beep, stays open
        #expect(calls.isEmpty && !wc.finished)
        m.click(1, kind: .plain)
        #expect(wc.route(.rotateRight))
        #expect(wc.route(.submit))
        wc.commit()                                            // second submit ignored
        #expect(calls.count == 1)
        #expect(calls.first?.0 == [five] && calls.first?.1 == "pdf.reorder")
        #expect(calls.first?.2 == ["rotations": .list([90, 0, 0, 0, 0])])
        #expect(wc.finished)

        let wc2 = OrganizerWindowController(controller: ReorderModel(url: five)) { _, _, _ in Issue.record("cancel must not submit") }
        #expect(wc2.route(.cancel))
        #expect(wc2.finished)
    }

    @Test func windowKeyEventsRouteToModel() throws {
        _ = NSApplication.shared
        let m = ReorderModel(url: five)
        var submitted: [String: OptionValue]?
        let wc = OrganizerWindowController(controller: m) { submitted = $2 }
        func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) throws -> Bool {
            let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                                  windowNumber: wc.window.windowNumber, context: nil, characters: chars,
                                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
            return wc.handle(e)
        }
        #expect(try key(124, ""))                         // → selects first page
        #expect(m.selection.selected == [1])
        #expect(try key(51, "\u{7f}"))                    // ⌫
        #expect(m.items.count == 4)
        #expect(try key(6, "z", .command))                // ⌘Z
        #expect(m.items.count == 5)
        #expect(try key(15, "R", [.command, .shift]))     // ⇧⌘R
        #expect(m.items.first?.rotation == 270)
        #expect(try !key(3, "f", .command))               // unmapped → passes through
        #expect(try key(36, "\r", .command))              // ⌘↩ submits
        #expect(submitted == ["rotations": .list([270, 0, 0, 0, 0])])
        #expect(wc.finished)
    }

    @Test func thumbnailsRender() {
        let store = ThumbnailStore(maxPixels: 120)
        store.loadNow([ThumbKey(url: five, page: 1), ThumbKey(url: five, page: 4), ThumbKey(url: five, page: 99)])
        let portrait = store.image(ThumbKey(url: five, page: 1))
        let landscape = store.image(ThumbKey(url: five, page: 4))
        #expect(portrait.map { $0.height == 120 && $0.width < 120 } == true)
        #expect(landscape.map { $0.width == 120 && $0.height < 120 } == true)
        #expect(store.image(ThumbKey(url: five, page: 99)) == nil)
    }
}
