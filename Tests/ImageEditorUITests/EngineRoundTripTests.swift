import CoreGraphics
import Foundation
import RondoKit
import Testing
@testable import ImageEditorUI

/// Editor → submission → real ImageEngine run → compare with what the editor previewed.
/// Proves the option semantics (coordinates, orientation, colors, defaults) match the engine exactly.
@MainActor
@Suite struct EngineRoundTripTests {
    static let view = CGSize(width: 1040, height: 840)

    static func file(_ name: String, _ image: CGImage, orientation: Int? = nil, type: String = "public.png") throws -> URL {
        try W6.writePNG(image, to: W6.dir("src").appendingPathComponent(name), orientation: orientation, type: type)
    }

    static func loaded(_ url: URL, _ tool: ToolID) async throws -> ImageEditorModel {
        let m = ImageEditorModel(url: url, tool: tool)
        await m.load()
        #expect(m.loadState == .ready)
        return m
    }

    static func drag(_ m: ImageEditorModel, _ a: CGPoint, _ b: CGPoint) {
        let t = m.transform(viewSize: view)
        m.pointerDown(at: t.toView(a), viewSize: view)
        m.pointerDragged(to: t.toView(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)), viewSize: view)
        m.pointerUp(at: t.toView(b), viewSize: view)
    }

    @Test func cropEveryOrientationMatchesPreview() async throws {
        let src = W6.quadrants(40, 20)
        let url = try Self.file("quad.png", src)
        let out = W6.cleanDir("e2e-crop")
        let orientations: [(String, (inout CropState) -> Void)] = [
            ("none", { _ in }), ("cw", { $0.rotateClockwise() }), ("180", { $0.rotateClockwise(); $0.rotateClockwise() }),
            ("ccw", { $0.rotateCounterClockwise() }), ("flipH", { $0.flipHorizontal() }), ("flipV", { $0.flipVertical() }),
            ("cw+flipH", { $0.rotateClockwise(); $0.flipHorizontal() }), ("ccw+flipH", { $0.rotateCounterClockwise(); $0.flipHorizontal() }),
        ]
        for (name, apply) in orientations {
            let m = try await Self.loaded(url, "image.crop")
            apply(&m.crop)
            let b = m.crop.bounds
            Self.drag(m, CGPoint(x: 3, y: 2), CGPoint(x: b.width - 4, y: b.height - 5))
            let s = try #require(m.submission(), "\(name)")
            let rect = try #require(CropMath.pixelRect(m.crop.rect, bounds: b))
            let result = try await W6.runEngine(s, input: url, outDir: out)
            let img = try #require(W6.load(result))
            #expect(img.width == Int(rect.width) && img.height == Int(rect.height), "\(name)")
            let expected = try #require(PreviewRenderer.oriented(src, m.crop.orientation).cropping(to: rect))
            #expect(W6.meanDifference(img, expected) < 0.5, "\(name): engine output differs from preview")
        }
    }

    /// EXIF-rotated source: the editor works on the upright image, like the engine.
    @Test func exifOrientationIsHonored() async throws {
        let src = W6.quadrants(40, 20)
        let url = try Self.file("quad-exif6.tiff", src, orientation: 6, type: "public.tiff")
        let m = try await Self.loaded(url, "image.crop")
        #expect(m.sourceSize == CGSize(width: 20, height: 40))   // upright
        // Orientation 6 displays the stored pixels rotated 90° clockwise: stored TL (red) → upright TR.
        #expect(W6.pixel(m.proxy!.image, 15, 5).close(to: .red))
        Self.drag(m, CGPoint(x: 11, y: 1), CGPoint(x: 19, y: 19))   // inside the upright top-right (red) quadrant
        let s = try #require(m.submission())
        #expect(s.options["rect"] == .list([11, 1, 8, 18]))
        let img = try #require(W6.load(try await W6.runEngine(s, input: url, outDir: W6.cleanDir("e2e-exif"))))
        #expect(img.width == 8 && img.height == 18)
        #expect(W6.pixel(img, 0, 0).close(to: .red) && W6.pixel(img, 7, 17).close(to: .red))
    }

    /// Big file: proxy capped at 2048 px, submitted rect in full-resolution pixels, engine output to match.
    @Test func largeFileCropsAtFullResolution() async throws {
        let url = try Self.file("big.png", W6.quadrants(3000, 1500))
        let m = try await Self.loaded(url, "image.crop")
        #expect(m.proxy!.image.width == 2048 && m.proxy!.image.height == 1024)
        #expect(m.sourceSize == CGSize(width: 3000, height: 1500))
        Self.drag(m, CGPoint(x: 1400, y: 700), CGPoint(x: 1700, y: 950))
        let s = try #require(m.submission())
        #expect(s.options["rect"] == .list([1400, 700, 300, 250]))
        let img = try #require(W6.load(try await W6.runEngine(s, input: url, outDir: W6.cleanDir("e2e-big"))))
        #expect(img.width == 300 && img.height == 250)
        #expect(W6.pixel(img, 50, 25).close(to: .red))      // (1450, 725): top-left quadrant
        #expect(W6.pixel(img, 250, 225).close(to: .white))  // (1650, 925): bottom-right quadrant
    }

    @Test func redactMatchesPreview() async throws {
        let src = W6.scene(320, 200)
        let url = try Self.file("scene-small.png", src)
        let out = W6.cleanDir("e2e-redact")
        for style in RedactStyle.allCases {
            let m = try await Self.loaded(url, "image.redact")
            Self.drag(m, CGPoint(x: 20.3, y: 30.6), CGPoint(x: 120.2, y: 90.4))
            Self.drag(m, CGPoint(x: 200, y: 120), CGPoint(x: 300, y: 190))
            m.redact.style = style
            m.redact.color = RGBAColor(hex: "#203040")!
            let s = try #require(m.submission())
            #expect(s.options["regions"] == .list([20, 30, 101, 61, 200, 120, 100, 70]))
            let img = try #require(W6.load(try await W6.runEngine(s, input: url, outDir: out)))
            let preview = PreviewRenderer.redacted(src, m.redact, sourceSize: m.sourceSize, scale: 1)
            let diff = W6.meanDifference(img, preview)
            #expect(diff < 1.0, "\(style): mean diff \(diff)")
            if style == .black {
                #expect(W6.pixel(img, 20, 30) == W6.RGBA(r: 0x20, g: 0x30, b: 0x40, a: 255))
                #expect(W6.pixel(img, 120, 90) == W6.RGBA(r: 0x20, g: 0x30, b: 0x40, a: 255))
                #expect(W6.pixel(img, 19, 30).close(to: W6.pixel(src, 19, 30), tolerance: 2))
            }
        }
    }

    @Test func annotateMatchesPreview() async throws {
        let src = W6.scene(400, 260)
        let url = try Self.file("scene-annotate.png", src)
        let m = try await Self.loaded(url, "image.annotate")
        m.updateStyle { $0.color = .red; $0.lineWidth = 5 }
        for (tool, a, b) in [(AnnotateTool.rect, CGPoint(x: 20, y: 20), CGPoint(x: 140, y: 100)),
                             (.ellipse, CGPoint(x: 200, y: 40), CGPoint(x: 300, y: 120)),
                             (.arrow, CGPoint(x: 60, y: 220), CGPoint(x: 220, y: 150)),
                             (.line, CGPoint(x: 300, y: 200), CGPoint(x: 380, y: 240)),
                             (.highlight, CGPoint(x: 160, y: 180), CGPoint(x: 280, y: 205))] {
            m.annotateTool = tool
            Self.drag(m, a, b)
        }
        m.annotateTool = .freehand
        let t = m.transform(viewSize: Self.view)
        m.pointerDown(at: t.toView(CGPoint(x: 330, y: 30)), viewSize: Self.view)
        for i in 1...20 { m.pointerDragged(to: t.toView(CGPoint(x: 330 + Double(i) * 3, y: 30 + sin(Double(i) / 2) * 15)), viewSize: Self.view) }
        m.pointerUp(at: t.toView(CGPoint(x: 395, y: 40)), viewSize: Self.view)
        m.annotateTool = .text
        m.updateStyle { $0.color = .white; $0.fontSize = 28 }
        m.pointerDown(at: t.toView(CGPoint(x: 30, y: 120)), viewSize: Self.view)
        m.pointerUp(at: t.toView(CGPoint(x: 30, y: 120)), viewSize: Self.view)
        m.setSelectedText("Rondo\nnote")
        #expect(m.annotations.count == 7)

        let s = try #require(m.submission())
        let img = try #require(W6.load(try await W6.runEngine(s, input: url, outDir: W6.cleanDir("e2e-annotate"))))
        // The engine decoded our JSON (not the raw options) — compare against the editor's own renderer.
        let preview = PreviewRenderer.annotated(src, m.annotations, scale: 1)
        let diff = W6.meanDifference(img, preview)
        #expect(diff < 0.5, "mean diff \(diff)")
        #expect(W6.pixel(img, 20, 60).close(to: W6.RGBA(r: 0xFF, g: 0x3B, b: 0x30, a: 255), tolerance: 3))   // rect's left edge, #FF3B30
    }

    @Test func adjustMatchesPreview() async throws {
        let src = W6.scene(320, 200)
        let url = try Self.file("scene-adjust.png", src)
        let out = W6.cleanDir("e2e-adjust")
        var cases: [AdjustSettings] = []
        var a = AdjustSettings(); a.exposure = 0.6; a.contrast = 1.3; a.saturation = 0.4; cases.append(a)
        a = AdjustSettings(); a.temperature = 9000; a.tint = 20; a.vibrance = 0.5; a.hue = 30; cases.append(a)
        a = AdjustSettings(); a.gamma = 1.6; a.brightness = -0.1; a.filter = "chrome"; cases.append(a)
        a = AdjustSettings(); a.blur = 4; a.sharpness = 0.8; a.filter = "noir"; cases.append(a)
        for settings in cases {
            let m = try await Self.loaded(url, "image.adjust")
            m.adjust = settings
            let s = try #require(m.submission())
            let img = try #require(W6.load(try await W6.runEngine(s, input: url, outDir: out)))
            let diff = W6.meanDifference(img, PreviewRenderer.adjusted(src, settings, scale: 1))
            #expect(diff < 2.0, "\(s.options): mean diff \(diff)")
            #expect(W6.meanDifference(img, src) > 3, "adjustment had no visible effect")
        }
    }

    @Test func backgroundMatchesPreview() async throws {
        let src = W6.badge(300, 200)
        let url = try Self.file("badge.png", src)
        let m = try await Self.loaded(url, "image.background")
        #expect(m.proxy!.hasAlpha)
        m.background.color = RGBAColor(hex: "#FFD60A")
        m.background.padding = 20
        let s = try #require(m.submission())
        let img = try #require(W6.load(try await W6.runEngine(s, input: url, outDir: W6.cleanDir("e2e-background"))))
        #expect(img.width == 340 && img.height == 240)
        #expect(W6.pixel(img, 2, 2).close(to: W6.RGBA(r: 0xFF, g: 0xD6, b: 0x0A, a: 255), tolerance: 1))
        let diff = W6.meanDifference(img, PreviewRenderer.backgrounded(src, m.background, scale: 1))
        #expect(diff < 0.5, "mean diff \(diff)")
    }

    /// Every P4 fixture format previews at its true upright size (read-only use of fixtures/out/src).
    @Test func fixtureFormatsLoad() async throws {
        let src = W6.root.appendingPathComponent("fixtures/out/src")
        var names = ["sample.jpg", "sample.png", "sample.heic", "sample.webp", "sample.avif", "sample.tiff", "sample.gif", "sample.bmp"]
        if ToolLocator().has("magick") { names.append("sample.svg") }
        for name in names {
            let url = src.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let p = try await ProxyLoader.load(url)
            #expect(p.sourceSize == CGSize(width: 160, height: 120), "\(name): \(p.sourceSize)")
            #expect(p.image.width == 160, "\(name)")
        }
    }

    /// SVG goes through magick at the engine's 96 DPI, so editor pixels == engine pixels.
    @Test func svgCropMatchesEngineSize() async throws {
        guard ToolLocator().has("magick") else { return }
        let url = W6.root.appendingPathComponent("fixtures/out/src/sample.svg")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let m = try await Self.loaded(url, "image.crop")
        Self.drag(m, CGPoint(x: 20, y: 10), CGPoint(x: 100, y: 70))
        let s = try #require(m.submission())
        let img = try #require(W6.load(try await W6.runEngine(s, input: url, outDir: W6.cleanDir("e2e-svg"))))
        #expect(img.width == 80 && img.height == 60)
    }

    @Test func missingAndGarbageFilesGiveReadableErrors() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/nope.png")
        await #expect(throws: ProxyLoaderError.missing("nope.png")) { try await ProxyLoader.load(missing) }
        let junk = W6.dir("src").appendingPathComponent("junk.png")
        try Data("not a png".utf8).write(to: junk)
        await #expect(throws: ProxyLoaderError.unreadable("junk.png")) { try await ProxyLoader.load(junk) }
    }
}
