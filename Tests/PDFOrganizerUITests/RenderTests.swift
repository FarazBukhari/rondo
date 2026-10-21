import AppKit
import Foundation
import RondoKit
import SwiftUI
import Testing
@testable import PDFOrganizerUI

/// Renders organizer states to PNG (light + dark) under fixtures/out/W8/render/ for a visual check.
@MainActor
@Suite(.serialized) struct RenderTests {
    static let out = W8Fixtures.dir("render")
    let seven = W8Fixtures.makePDF("seven.pdf", pages: 7, landscape: [5])

    func snapshot<V: View>(_ view: V, name: String, size: CGSize = CGSize(width: 880, height: 620)) throws {
        _ = NSApplication.shared
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            #expect(data.count > 5_000)
            try data.write(to: Self.out.appendingPathComponent("\(name)-\(suffix).png"))
            window.close()
        }
    }

    func preload(_ store: ThumbnailStore, _ url: URL, pages: Int) {
        store.loadNow((1...pages).map { ThumbKey(url: url, page: $0) })
    }

    @Test func reorderStates() throws {
        let m = ReorderModel(url: seven)
        preload(m.thumbnails, seven, pages: 7)
        try snapshot(ReorderView(model: m, actions: .init()), name: "reorder-initial")

        m.click(2, kind: .plain)
        m.deleteSelection()                       // delete page 2
        m.click(5, kind: .plain)
        m.rotateSelection(by: 90)                 // landscape page turned upright
        m.move([7], to: 0)                        // last page first
        m.click(3, kind: .plain)
        m.click(4, kind: .toggle)
        m.dropTarget = .init(id: 6, before: true)
        try snapshot(ReorderView(model: m, actions: .init()), name: "reorder-edited")
    }

    @Test func splitStates() throws {
        let m = SplitModel(url: seven)
        preload(m.thumbnails, seven, pages: 7)
        m.click(1, kind: .plain); m.click(3, kind: .extend); m.addPart()
        m.click(4, kind: .plain); m.addPart()
        m.click(6, kind: .plain)                  // pending selection previews as PDF 3
        try snapshot(SplitView(model: m, actions: .init()), name: "split-parts")
        m.style = .every
        m.every = 3
        m.selection.clear()
        try snapshot(SplitView(model: m, actions: .init()), name: "split-every")
    }

    @Test func mergeStates() throws {
        let a = W8Fixtures.makePDF("merge-a.pdf", pages: 2, label: "A")
        let b = W8Fixtures.makePDF("merge-b.pdf", pages: 1, label: "B")
        let m = MergeModel(urls: [b, seven, a, W8Fixtures.dir("src").appendingPathComponent("note.txt")])
        m.thumbnails.loadNow(m.entries.map { ThumbKey(url: $0.url, page: 1) })
        m.selection = [m.entries[1].id]
        try snapshot(MergeView(model: m, actions: .init()), name: "merge-list", size: CGSize(width: 640, height: 480))
        try snapshot(MergeView(model: MergeModel(urls: []), actions: .init()), name: "merge-empty", size: CGSize(width: 640, height: 480))
    }

    @Test func errorState() throws {
        let m = ReorderModel(url: URL(fileURLWithPath: "/nonexistent/locked.pdf"))
        try snapshot(ReorderView(model: m, actions: .init()), name: "reorder-error", size: CGSize(width: 640, height: 440))
    }
}
