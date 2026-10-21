import AppKit
import Foundation
import RondoKit
import SwiftUI
import Testing
@testable import ImageEditorUI

/// Renders editor states (light + dark) to fixtures/out/W6/*.png for eyeballing, and checks the canvas drew.
@MainActor
@Suite(.serialized) struct SnapshotTests {
    static let size = NSSize(width: 1040, height: 700)
    static let sceneURL = URL(fileURLWithPath: "/tmp/sunset-hills.png")

    /// Hosts the real SwiftUI editor in an off-screen window and caches its display at 1×.
    static func render(_ model: ImageEditorModel, appearance: NSAppearance.Name, name: String) async throws -> NSBitmapImageRep {
        await model.waitForPreviews()
        model.renderPreviewNow()
        let host = NSHostingView(rootView: ImageEditorView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        // cacheDisplay skips the window frame, so paint the window background ourselves.
        let backdrop = Backdrop(frame: host.frame)
        backdrop.addSubview(host)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = backdrop
        model.canvasSize = CGSize(width: size.width - 277, height: size.height - 100)
        // Let SwiftUI settle by yielding the main actor (no nested run loop).
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: W6.dir(".").appendingPathComponent("\(name).png"))
        window.close()
        return rep
    }

    static func color(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
    }

    static func make(_ tool: ToolID, image: CGImage = W6.scene()) -> ImageEditorModel {
        ImageEditorModel(url: sceneURL, tool: tool, proxy: ProxyLoader.proxy(for: image))
    }

    /// Canvas center must show image content, not the empty canvas color.
    static func expectCanvasDrew(_ rep: NSBitmapImageRep, _ name: String) {
        let probe = color(rep, 380, 330)
        let bg = color(rep, 4, 64)   // top-left corner of the canvas area: canvas background
        let differs = abs(probe.redComponent - bg.redComponent) + abs(probe.greenComponent - bg.greenComponent)
            + abs(probe.blueComponent - bg.blueComponent) > 0.05
        #expect(differs, "\(name): canvas looks empty (probe \(probe), bg \(bg))")
    }

    @Test func cropStates() async throws {
        let light = Self.make("image.crop")
        light.crop.setAspect(.r16x9)
        light.crop.rect = CropMath.maxRect(ratio: 16.0 / 9, in: CGSize(width: 1200, height: 900), center: CGPoint(x: 820, y: 520))
        Self.expectCanvasDrew(try await Self.render(light, appearance: .aqua, name: "crop-light"), "crop-light")

        let dark = Self.make("image.crop")
        dark.crop.rotateClockwise()
        dark.crop.flipHorizontal()
        dark.crop.rect = CGRect(x: 120, y: 260, width: 640, height: 900)
        Self.expectCanvasDrew(try await Self.render(dark, appearance: .darkAqua, name: "crop-dark"), "crop-dark")
    }

    @Test func adjustStates() async throws {
        let light = Self.make("image.adjust")
        light.adjust.exposure = 0.35
        light.adjust.saturation = 1.5
        light.adjust.temperature = 8200
        light.renderPreviewNow()
        Self.expectCanvasDrew(try await Self.render(light, appearance: .aqua, name: "adjust-light"), "adjust-light")

        let dark = Self.make("image.adjust")
        dark.adjust.filter = "noir"
        dark.adjust.contrast = 1.4
        dark.renderPreviewNow()
        Self.expectCanvasDrew(try await Self.render(dark, appearance: .darkAqua, name: "adjust-dark"), "adjust-dark")
    }

    static func annotated() -> ImageEditorModel {
        let m = make("image.annotate")
        m.annotations = [
            Annotation(kind: .rect, rect: CGRect(x: 980, y: 520, width: 330, height: 300), color: .red, lineWidth: 10),
            Annotation(kind: .arrow, points: [CGPoint(x: 560, y: 260), CGPoint(x: 950, y: 520)], color: .yellow, lineWidth: 12),
            Annotation(kind: .ellipse, rect: CGRect(x: 110, y: 760, width: 520, height: 160), color: .blue, lineWidth: 8),
            Annotation(kind: .highlight, rect: CGRect(x: 100, y: 90, width: 700, height: 90), color: RGBAColor.yellow.withAlpha(0.4)),
            Annotation(kind: .freehand, points: (0..<40).map { CGPoint(x: 1250 + Double($0) * 8, y: 180 + sin(Double($0) / 3) * 40) },
                       color: .green, lineWidth: 8),
            Annotation(kind: .text, rect: CGRect(x: 110, y: 100, width: 0, height: 0), color: .white, text: "Sunset over the hills", fontSize: 64),
        ]
        m.selectedAnnotationID = m.annotations[0].id
        return m
    }

    @Test func annotateStates() async throws {
        let light = Self.annotated()
        light.annotateTool = .rect
        light.selectedAnnotationID = light.annotations[0].id
        Self.expectCanvasDrew(try await Self.render(light, appearance: .aqua, name: "annotate-light"), "annotate-light")
        let dark = Self.annotated()
        dark.annotateTool = .text
        dark.selectedAnnotationID = dark.annotations[5].id
        Self.expectCanvasDrew(try await Self.render(dark, appearance: .darkAqua, name: "annotate-dark"), "annotate-dark")
    }

    @Test func redactStates() async throws {
        let light = Self.make("image.redact")
        light.redact.regions = [CGRect(x: 120, y: 780, width: 560, height: 160), CGRect(x: 980, y: 540, width: 300, height: 260)]
        light.redact.style = .pixelate
        light.selectedRegion = 1
        light.renderPreviewNow()
        Self.expectCanvasDrew(try await Self.render(light, appearance: .aqua, name: "redact-light"), "redact-light")

        let dark = Self.make("image.redact")
        dark.redact.regions = [CGRect(x: 100, y: 80, width: 640, height: 120)]
        dark.redact.style = .black
        dark.selectedRegion = 0
        dark.renderPreviewNow()
        Self.expectCanvasDrew(try await Self.render(dark, appearance: .darkAqua, name: "redact-dark"), "redact-dark")
    }

    @Test func backgroundStates() async throws {
        let light = Self.make("image.background", image: W6.badge(900, 600))
        light.background.color = nil
        light.background.padding = 80
        light.renderPreviewNow()
        Self.expectCanvasDrew(try await Self.render(light, appearance: .aqua, name: "background-light"), "background-light")

        let dark = Self.make("image.background", image: W6.badge(900, 600))
        dark.background.color = .yellow
        dark.background.padding = 60
        dark.renderPreviewNow()
        Self.expectCanvasDrew(try await Self.render(dark, appearance: .darkAqua, name: "background-dark"), "background-dark")
    }

    @Test func loadingAndFailedStates() async throws {
        let loading = ImageEditorModel(url: Self.sceneURL, tool: "image.crop")
        _ = try await Self.render(loading, appearance: .aqua, name: "loading-light")
        let failed = ImageEditorModel(url: URL(fileURLWithPath: "/nonexistent/missing.png"), tool: "image.crop")
        await failed.load()
        _ = try await Self.render(failed, appearance: .darkAqua, name: "failed-dark")
        if case .failed = failed.loadState {} else { Issue.record("expected failed state") }
    }
}

/// Window-background fill behind the hosted editor (what the real window's frame view draws).
private final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
