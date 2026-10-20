import AppKit
import Foundation
import RondoKit
import Testing
@testable import RondoInteraction

/// AppKit smoke tests: the view lays out, hit-tests in view coordinates, handles keys, and draws
/// in light + dark without crashing. Renders PNGs to fixtures/out/W1/ for eyeballing.
@MainActor
@Suite struct WheelViewTests {
    static let outDir: URL = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("fixtures/out/W1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let sampleItems: [WheelItem] = [
        ("JPEG", "photo"), ("PNG", "photo"), ("HEIC", "photo"), ("WebP", "photo"),
        ("TIFF", "photo"), ("AVIF", "photo"), ("GIF", "photo"), ("BMP", "photo"),
        ("PDF", "doc.richtext"), ("Read QR code", "qrcode"), ("Compress", "arrow.down.right.and.arrow.up.left"),
    ].enumerated().map { i, t in WheelItem(id: "s\(i)", title: t.0, symbol: t.1, payload: .convert(t.0.lowercased())) }

    @Test func viewSizeMatchesModel() {
        let model = WheelModel(items: Self.sampleItems, kind: .convert)
        let view = WheelView(model: model)
        #expect(view.frame.width == model.diameter)
        view.setModel(WheelModel(items: Array(Self.sampleItems.prefix(3)), kind: .tools))
        #expect(view.frame.width == view.model.diameter)
        #expect(view.model.ringCount == 1)
    }

    @Test func viewPointHitTesting() {
        let view = WheelView(model: WheelModel(items: Array(Self.sampleItems.prefix(4)), kind: .convert))
        let c = view.center
        #expect(view.hit(atViewPoint: c) == .hub)
        #expect(view.hit(atViewPoint: NSPoint(x: c.x, y: c.y + 80)) == .slice(WheelSlot(ring: 0, index: 0)))
        #expect(view.hit(atViewPoint: NSPoint(x: c.x - 80, y: c.y)) == .slice(WheelSlot(ring: 0, index: 3)))
        #expect(view.hit(atViewPoint: .zero) == .outside)
    }

    @Test func hubCancelArmsOnlyAfterLeavingHub() {
        let view = WheelView(model: WheelModel(items: Array(Self.sampleItems.prefix(4)), kind: .convert))
        view.highlight(.hub)
        #expect(view.hubState == .normal)
        view.highlight(.slice(WheelSlot(ring: 0, index: 1)))
        #expect(view.model.selection == WheelSlot(ring: 0, index: 1))
        view.highlight(.hub)
        #expect(view.hubState == .cancel)
        #expect(view.model.selection == nil)
    }

    @Test func keyboardActivatesWithInputs() {
        let view = WheelView(model: WheelModel(items: Array(Self.sampleItems.prefix(4)), kind: .convert), mode: .click)
        let inputs = [URL(fileURLWithPath: "/tmp/x.png")]
        view.inputs = inputs
        var picked: (WheelItem, [URL])?
        var cancelled = false
        view.onActivate = { picked = ($0, $1) }
        view.onCancel = { cancelled = true }
        view.handleKey(.left)
        view.handleKey(.enter)
        #expect(picked?.0.id == "s3")
        #expect(picked?.1 == inputs)
        view.handleKey(.escape)
        #expect(cancelled)
    }

    @Test func rendersLightAndDark() throws {
        let png = URL(fileURLWithPath: "/tmp/sample.png")
        let cases: [(String, NSAppearance.Name, [WheelItem], WheelSlot?, [URL])] = [
            ("wheel-light-2rings", .aqua, Self.sampleItems, WheelSlot(ring: 0, index: 2), [png]),
            ("wheel-dark-2rings", .darkAqua, Self.sampleItems, WheelSlot(ring: 1, index: 1), [png, png, png]),
            ("wheel-dark-actions", .darkAqua, ActionID.allCases.map {
                WheelItem(id: $0.rawValue, title: $0.title, symbol: $0.symbol, payload: .action($0))
            }, nil, [png]),
            ("wheel-light-empty", .aqua, [], nil, [png]),
        ]
        for (name, appearance, items, selection, inputs) in cases {
            let model = WheelModel(items: items, kind: items.first.map { if case .action = $0.payload { .actions } else { .convert } } ?? .convert)
            let view = WheelView(model: model)
            view.inputs = inputs
            if let selection { view.highlight(.slice(selection)) }
            let backdrop = Backdrop(frame: view.frame)
            backdrop.addSubview(view)
            backdrop.appearance = NSAppearance(named: appearance)
            let rep = try #require(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            #expect(data.count > 1000)
            try data.write(to: Self.outDir.appendingPathComponent("\(name).png"))
        }
    }
}

/// Stand-in for the blurred disc the panel puts behind the wheel.
private final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
