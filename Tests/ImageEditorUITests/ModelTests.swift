import CoreGraphics
import Foundation
import RondoKit
import Testing
@testable import ImageEditorUI

@MainActor
@Suite struct ModelTests {
    static let url = URL(fileURLWithPath: "/tmp/w6-model-test.png")
    static let view = CGSize(width: 1040, height: 840)

    static func model(_ tool: ToolID = "image.crop", w: Int = 400, h: Int = 300) -> ImageEditorModel {
        ImageEditorModel(url: url, tool: tool, proxy: ProxyLoader.proxy(for: W6.quadrants(w, h)))
    }

    /// Drag in *view* coordinates, like the canvas does.
    static func drag(_ m: ImageEditorModel, from a: CGPoint, to b: CGPoint, steps: Int = 4) {
        m.pointerDown(at: a, viewSize: view)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            m.pointerDragged(to: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), viewSize: view)
        }
        m.pointerUp(at: b, viewSize: view)
    }

    /// View point over a full-resolution image pixel.
    static func at(_ m: ImageEditorModel, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        m.transform(viewSize: view).toView(CGPoint(x: x, y: y))
    }

    @Test func panelFromTool() {
        #expect(EditorPanel(tool: "image.redact") == .redact)
        #expect(EditorPanel(tool: "image.background")?.toolID == "image.background")
        #expect(EditorPanel(tool: "video.trim") == nil)
        #expect(ImageEditorModel(url: Self.url, tool: "image.collage").panel == .crop)
        #expect(Self.model("image.annotate").panel == .annotate)
    }

    @Test func nothingToSaveUntilEdited() {
        let m = Self.model("image.crop")
        for p in EditorPanel.allCases {
            m.panel = p
            #expect(m.submission() == nil, "\(p)")
            #expect(!m.canSave)
            #expect(!m.statusHint.isEmpty)
        }
    }

    /// The big one: a drag on a downsampled proxy submits full-resolution source pixels.
    @Test func largeImageSubmitsFullResolutionCoordinates() {
        let big = ImageEditorModel(url: Self.url, tool: "image.crop", proxy: ProxyLoader.proxy(for: W6.quadrants(5000, 2500)))
        #expect(big.proxy!.image.width == 2048 && big.proxy!.image.height == 1024)
        #expect(big.sourceSize == CGSize(width: 5000, height: 2500))
        Self.drag(big, from: Self.at(big, 500, 500), to: Self.at(big, 3000, 1750))
        #expect(big.submission()?.options["rect"] == .list([500, 500, 2500, 1250]))

        // Same under zoom + pan.
        big.zoom(by: 3, anchor: CGPoint(x: 300, y: 200), viewSize: Self.view)
        big.panBy(CGSize(width: -40, height: 25))
        big.crop.rect = CropMath.full(big.crop.bounds)
        Self.drag(big, from: Self.at(big, 1000, 700), to: Self.at(big, 1200, 760))
        #expect(big.submission()?.options["rect"] == .list([1000, 700, 200, 60]))

        // Redact on the same proxy: regions in source pixels too.
        big.panel = .redact
        Self.drag(big, from: Self.at(big, 1010, 705), to: Self.at(big, 1110, 805))
        #expect(big.submission()?.options["regions"] == .list([1010, 705, 100, 100]))
    }

    @Test func cropSubmissionAfterRotateAndFlip() throws {
        let m = Self.model("image.crop", w: 400, h: 300)
        m.crop.rotateClockwise()
        m.crop.flipHorizontal()
        var s = try #require(m.submission())
        #expect(s.tool == "image.crop")
        #expect(s.options == ["rotation": .int(90), "flipH": .bool(true), "flipV": .bool(false)])   // no rect: full frame
        // Rect is in the rotated (300×400) space.
        Self.drag(m, from: Self.at(m, 10, 20), to: Self.at(m, 110, 220))
        s = try #require(m.submission())
        #expect(s.options["rect"] == .list([10, 20, 100, 200]))
        #expect(m.crop.bounds == CGSize(width: 300, height: 400))
        // A click (no drag) keeps the previous selection.
        m.pointerDown(at: Self.at(m, 250, 380), viewSize: Self.view)
        m.pointerUp(at: Self.at(m, 250, 380), viewSize: Self.view)
        #expect(m.submission()?.options["rect"] == .list([10, 20, 100, 200]))
        // Drag inside moves; a handle resizes.
        Self.drag(m, from: Self.at(m, 50, 50), to: Self.at(m, 60, 70))
        #expect(m.submission()?.options["rect"] == .list([20, 40, 100, 200]))
        Self.drag(m, from: Self.at(m, 120, 240), to: Self.at(m, 150, 300))
        #expect(m.submission()?.options["rect"] == .list([20, 40, 130, 260]))
    }

    @Test func annotateDrawSelectMoveDeleteUndo() throws {
        let m = Self.model("image.annotate")
        m.annotateTool = .rect
        m.updateStyle { $0.color = .blue; $0.lineWidth = 6 }
        Self.drag(m, from: Self.at(m, 20, 30), to: Self.at(m, 120, 90))
        #expect(m.annotations.count == 1)
        let a = m.annotations[0]
        #expect(a.kind == .rect && a.color == .blue && a.lineWidth == 6)
        #expect(abs(a.rect.minX - 20) < 1e-6 && abs(a.rect.width - 100) < 1e-6 && abs(a.rect.height - 60) < 1e-6)
        // A tiny click with a drawing tool doesn't leave a dot behind.
        m.selectedAnnotationID = nil
        m.pointerDown(at: Self.at(m, 300, 250), viewSize: Self.view)
        m.pointerUp(at: Self.at(m, 300, 250), viewSize: Self.view)
        #expect(m.annotations.count == 1)
        // Arrow: two points in source px.
        m.annotateTool = .arrow
        Self.drag(m, from: Self.at(m, 200, 200), to: Self.at(m, 250, 150))
        #expect(m.annotations.count == 2)
        #expect(m.annotations[1].points.count == 2)
        // Select tool: click the rect's edge and move it.
        m.annotateTool = .select
        Self.drag(m, from: Self.at(m, 20, 60), to: Self.at(m, 40, 70))
        #expect(m.selectedAnnotationID == a.id)
        #expect(abs(m.annotations[0].rect.minX - 40) < 1e-6 && abs(m.annotations[0].rect.minY - 40) < 1e-6)
        // Style edits apply to the selection.
        m.updateStyle { $0.fill = true }
        #expect(m.annotations[0].fill)
        m.deleteSelection()
        #expect(m.annotations.count == 1 && m.annotations[0].kind == .arrow)
        m.undo()
        #expect(m.annotations.count == 2)
        let s = try #require(m.submission())
        #expect(s.tool == "image.annotate")
        guard case .string(let json)? = s.options["shapes"] else { Issue.record("no shapes"); return }
        #expect(json.contains(#""type":"rect""#) && json.contains(#""type":"arrow""#))
    }

    @Test func freehandAndTextAndHighlight() {
        let m = Self.model("image.annotate")
        m.annotateTool = .freehand
        m.pointerDown(at: Self.at(m, 10, 10), viewSize: Self.view)
        for i in 1...40 { m.pointerDragged(to: Self.at(m, 10 + CGFloat(i) * 2, 10 + CGFloat(i % 5)), viewSize: Self.view) }
        m.pointerUp(at: Self.at(m, 90, 12), viewSize: Self.view)
        #expect(m.annotations.count == 1 && m.annotations[0].points.count >= 10)

        let before = m.focusTextRequest
        m.annotateTool = .text
        m.pointerDown(at: Self.at(m, 50, 200), viewSize: Self.view)
        m.pointerUp(at: Self.at(m, 50, 200), viewSize: Self.view)
        #expect(m.focusTextRequest == before + 1)
        #expect(m.selectedAnnotation?.kind == .text)
        m.setSelectedText("Look here")
        #expect(m.selectedAnnotation?.text == "Look here")
        #expect(abs(m.selectedAnnotation!.rect.minX - 50) < 1e-6 && abs(m.selectedAnnotation!.rect.minY - 200) < 1e-6)
        let count = m.annotations.count
        m.undo()   // creating the text is undoable
        #expect(m.annotations.count == count - 1)
        m.annotateTool = .text
        m.pointerDown(at: Self.at(m, 50, 200), viewSize: Self.view)
        m.pointerUp(at: Self.at(m, 50, 200), viewSize: Self.view)
        m.setSelectedText("Look here")

        m.annotateTool = .highlight
        m.updateStyle { $0.color = .yellow }
        Self.drag(m, from: Self.at(m, 100, 100), to: Self.at(m, 200, 120))
        #expect(m.annotations.last?.kind == .highlight)
        #expect(m.annotations.last?.color.hex == "#FFD60A66")
    }

    @Test func redactRegionsMoveResizeDelete() throws {
        let m = Self.model("image.redact")
        Self.drag(m, from: Self.at(m, 10, 10), to: Self.at(m, 60, 40))
        Self.drag(m, from: Self.at(m, 200, 100), to: Self.at(m, 260, 160))
        #expect(m.redact.regions.count == 2 && m.selectedRegion == 1)
        #expect(m.submission()?.options["regions"] == .list([10, 10, 50, 30, 200, 100, 60, 60]))
        // Drag the selected region's bottom-right handle.
        Self.drag(m, from: Self.at(m, 260, 160), to: Self.at(m, 280, 170))
        #expect(m.redact.pixelRegions(bounds: m.sourceSize)[1] == CGRect(x: 200, y: 100, width: 80, height: 70))
        // Move the first region; it stays inside the image.
        Self.drag(m, from: Self.at(m, 30, 20), to: Self.at(m, -100, -100))
        #expect(m.selectedRegion == 0)
        #expect(m.redact.pixelRegions(bounds: m.sourceSize)[0] == CGRect(x: 0, y: 0, width: 50, height: 30))
        m.redact.style = .pixelate
        let s = try #require(m.submission())
        #expect(s.options["style"] == .string("pixelate") && s.options["color"] == nil)
        m.deleteSelection()
        #expect(m.redact.regions.count == 1)
        m.clearAll()
        #expect(m.submission() == nil)
        m.undo()
        #expect(m.redact.regions.count == 1)
        // Esc mid-drag removes the half-drawn region.
        m.pointerDown(at: Self.at(m, 300, 200), viewSize: Self.view)
        m.pointerDragged(to: Self.at(m, 350, 250), viewSize: Self.view)
        #expect(m.redact.regions.count == 2)
        m.cancelDrag()
        #expect(m.redact.regions.count == 1 && !m.isDragging)
    }

    @Test func adjustAndBackgroundSubmissions() throws {
        let m = Self.model("image.adjust")
        m.adjust.exposure = 0.75
        m.adjust.filter = "sepia"
        #expect(try #require(m.submission()) == EditorSubmission(tool: "image.adjust", options: ["exposure": .double(0.75), "filter": .string("sepia")]))
        // Hold-to-compare.
        m.pointerDown(at: CGPoint(x: 500, y: 400), viewSize: Self.view)
        #expect(m.showOriginal && m.displayImage === m.proxy?.image)
        m.pointerUp(at: CGPoint(x: 500, y: 400), viewSize: Self.view)
        #expect(!m.showOriginal)

        m.panel = .background
        #expect(m.submission() == nil)   // opaque image, no padding: nothing would change
        m.background.padding = 12
        m.background.color = RGBAColor(hex: "#102030")
        #expect(try #require(m.submission()).options == ["mode": .string("fill"), "color": .string("#102030"), "padding": .int(12)])
        #expect(m.canvasImageSize == CGSize(width: 424, height: 324))
        // Switching panels keeps both edits, saves only the current one, and says so.
        #expect(m.otherEditedPanels == [.adjust])
        #expect(m.statusHint.contains("Adjust"))

        let alpha = ImageEditorModel(url: Self.url, tool: "image.background", proxy: ProxyLoader.proxy(for: W6.badge()))
        #expect(alpha.submission()?.options == ["mode": .string("fill"), "color": .string("#FFFFFF"), "padding": .int(0)])
    }

    @Test func saveAndCancelFinishExactlyOnce() {
        var calls: [EditorSubmission?] = []
        let m = Self.model("image.crop")
        m.onFinish = { calls.append($0) }
        m.save()                                  // nothing to save
        #expect(calls.isEmpty && !m.finished)
        m.crop.rotateClockwise()
        m.save()
        m.save()
        m.cancel()
        #expect(calls.count == 1)
        #expect(calls.first??.tool == "image.crop")
        #expect(m.finished && !m.canSave)

        var cancelled: [EditorSubmission?] = []
        let c = Self.model("image.redact")
        c.onFinish = { cancelled.append($0) }
        Self.drag(c, from: Self.at(c, 10, 10), to: Self.at(c, 60, 40))
        c.cancel()
        c.save()
        #expect(cancelled.count == 1 && cancelled[0] == nil)
        // Finished editors ignore input.
        c.pointerDown(at: Self.at(c, 100, 100), viewSize: Self.view)
        #expect(!c.isDragging)
    }

    @Test func zoomCommands() {
        let m = Self.model("image.crop", w: 400, h: 300)
        m.canvasSize = Self.view
        let anchor = CGPoint(x: 400, y: 300)
        let before = m.transform.toImage(anchor)
        m.zoom(by: 2, anchor: anchor)
        #expect(abs(m.zoom - 2) < 1e-9)
        let after = m.transform.toImage(anchor)
        #expect(abs(after.x - before.x) < 1e-6 && abs(after.y - before.y) < 1e-6)
        m.zoomToActualSize()
        #expect(m.zoomPercent == 100)
        m.zoomToFit()
        #expect(m.zoom == 1 && m.pan == .zero)
        // Space/middle-drag pans in view points.
        m.pointerDown(at: CGPoint(x: 10, y: 10), viewSize: Self.view, panning: true)
        m.pointerDragged(to: CGPoint(x: 40, y: -10), viewSize: Self.view)
        m.pointerUp(at: CGPoint(x: 40, y: -10), viewSize: Self.view)
        #expect(m.pan == CGPoint(x: 30, y: -20))
        #expect(m.crop.isFullFrame)
    }

    @Test func previewsRenderOffMainAndLand() async {
        let m = Self.model("image.adjust")
        m.adjust.exposure = 1
        m.adjust.filter = "invert"   // coalesced with the first render
        await m.waitForPreviews()
        #expect(m.adjustPreview != nil)
        #expect(W6.pixel(m.displayImage!, 50, 50).close(to: W6.RGBA(r: 0, g: 255, b: 255, a: 255), tolerance: 40))   // red → cyan
        m.panel = .redact
        m.redact.regions = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        await m.waitForPreviews()
        #expect(W6.pixel(m.displayImage!, 50, 50) == .black)
        #expect(W6.pixel(m.displayImage!, 150, 50).close(to: .red))
    }

    /// replace/remove use Vision on the proxy; on Macs where that fails, Save is disabled with a message.
    @Test func subjectLiftPreviewDegradesGracefully() async {
        let m = ImageEditorModel(url: Self.url, tool: "image.background", proxy: ProxyLoader.proxy(for: W6.badge()))
        guard BackgroundMode.available.contains(.replace) else { return }
        m.background.mode = .replace
        m.background.color = .yellow
        await m.waitForPreviews()
        #expect(m.backgroundPreview != nil)
        if let error = m.backgroundError {
            #expect(!m.canSave && m.submission() == nil && !error.isEmpty)
            print("W6: subject lift unavailable here: \(error)")
        } else {
            #expect(m.submission()?.options["mode"] == .string("replace"))
        }
    }

    /// A slow render of an older state must never replace a newer preview.
    @Test func stalePreviewNeverOverwritesNewer() async {
        let m = Self.model("image.redact")
        m.redact.regions = [CGRect(x: 0, y: 0, width: 100, height: 100)]   // async job in flight
        m.redact.style = .black
        m.redact.color = .white
        m.renderPreviewNow()                                                 // newer, synchronous
        await m.waitForPreviews()
        #expect(W6.pixel(m.displayImage!, 50, 50) == .white)
    }
}
