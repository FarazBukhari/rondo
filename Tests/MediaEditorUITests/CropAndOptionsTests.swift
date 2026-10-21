import CoreGraphics
import Foundation
import RondoKit
import Testing
@testable import MediaEditorUI

@Suite struct CropGeometryTests {
    @Test func rotationFromTransformsAndAngles() {
        #expect(CropGeometry.rotationDegrees(of: .identity) == 0)
        #expect(CropGeometry.rotationDegrees(of: CGAffineTransform(rotationAngle: .pi / 2)) == 90)
        #expect(CropGeometry.rotationDegrees(of: CGAffineTransform(rotationAngle: -.pi / 2)) == 270)
        #expect(CropGeometry.rotationDegrees(of: CGAffineTransform(rotationAngle: .pi)) == 180)
        // Typical phone-portrait track transform (rotate + translate).
        let phone = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        #expect(CropGeometry.rotationDegrees(of: phone) == 90)
        #expect(CropGeometry.normalizedRotation(-90) == 270)
        #expect(CropGeometry.normalizedRotation(450) == 90)
        #expect(CropGeometry.normalizedRotation(.nan) == 0)
    }

    @Test func displaySizeSwapsOnQuarterTurns() {
        let natural = CGSize(width: 1920, height: 1080)
        #expect(CropGeometry.displaySize(natural: natural, rotation: 0) == natural)
        #expect(CropGeometry.displaySize(natural: natural, rotation: 180) == natural)
        #expect(CropGeometry.displaySize(natural: natural, rotation: 90) == CGSize(width: 1080, height: 1920))
        #expect(CropGeometry.displaySize(natural: natural, rotation: -90) == CGSize(width: 1080, height: 1920))
        let phone = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        #expect(CropGeometry.displaySize(natural: natural, transform: phone) == CGSize(width: 1080, height: 1920))
    }

    @Test func aspectFitLetterboxesAndPillarboxes() {
        let wide = CropGeometry.aspectFit(CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(approx(wide, CGRect(x: 0, y: 75, width: 800, height: 450)))
        let tall = CropGeometry.aspectFit(CGSize(width: 1080, height: 1920), in: CGRect(x: 10, y: 10, width: 800, height: 600))
        #expect(approx(tall, CGRect(x: 241.25, y: 10, width: 337.5, height: 600)))
        #expect(CropGeometry.aspectFit(.zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)) == .zero)
    }

    @Test func viewVideoMappingRoundTrips() {
        let video = CGSize(width: 1920, height: 1080)
        let frame = CropGeometry.aspectFit(video, in: CGRect(x: 0, y: 0, width: 800, height: 600))   // 0,75 800×450
        let view = CGRect(x: 200, y: 75 + 112.5, width: 400, height: 225)
        let px = CropGeometry.viewToVideo(view, frame: frame, videoSize: video)
        #expect(approx(px, CGRect(x: 480, y: 270, width: 960, height: 540)))
        #expect(approx(CropGeometry.videoToView(px, frame: frame, videoSize: video), view))
        let p = CropGeometry.viewToVideo(CGPoint(x: 800, y: 525), frame: frame, videoSize: video)
        #expect(abs(p.x - 1920) < 1e-9 && abs(p.y - 1080) < 1e-9)
    }

    @Test func rotatedVideoMapsInDisplayedPixels() {
        // 1920×1080 coded, rotated 90° → shown as 1080×1920 portrait; the engine's rect is in that space.
        let display = CropGeometry.displaySize(natural: CGSize(width: 1920, height: 1080), rotation: 90)
        let frame = CropGeometry.aspectFit(display, in: CGRect(x: 0, y: 0, width: 900, height: 640))
        #expect(approx(frame, CGRect(x: 270, y: 0, width: 360, height: 640)))
        // Top half of the portrait picture.
        let view = CGRect(x: frame.minX, y: 0, width: frame.width, height: 320)
        let px = CropGeometry.viewToVideo(view, frame: frame, videoSize: display)
        #expect(CropGeometry.engineRect(px, videoSize: display) == [0, 0, 1080, 960])
    }

    @Test func clampMovesInsideAndShrinks() {
        let size = CGSize(width: 100, height: 50)
        #expect(CropGeometry.clamp(CGRect(x: 90, y: -10, width: 30, height: 20), to: size) == CGRect(x: 70, y: 0, width: 30, height: 20))
        #expect(CropGeometry.clamp(CGRect(x: -5, y: 0, width: 300, height: 80), to: size) == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(CropGeometry.moved(CGRect(x: 10, y: 10, width: 20, height: 20), by: CGSize(width: 500, height: -500), in: size)
                == CGRect(x: 80, y: 0, width: 20, height: 20))
    }

    @Test func freeResizeKeepsTheOppositeCorner() {
        let size = CGSize(width: 1000, height: 500)
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        let br = CropGeometry.resized(r, handle: .bottomRight, to: CGPoint(x: 600, y: 450), aspect: nil, in: size)
        #expect(br == CGRect(x: 100, y: 100, width: 500, height: 350))
        let tl = CropGeometry.resized(r, handle: .topLeft, to: CGPoint(x: -50, y: 50), aspect: nil, in: size)
        #expect(tl == CGRect(x: 0, y: 50, width: 300, height: 150))
        // Dragging past the anchor stops at the minimum size instead of flipping.
        let tiny = CropGeometry.resized(r, handle: .right, to: CGPoint(x: 0, y: 0), aspect: nil, in: size, minSize: 16)
        #expect(tiny == CGRect(x: 100, y: 100, width: 16, height: 100))
        let top = CropGeometry.resized(r, handle: .top, to: CGPoint(x: 999, y: 20), aspect: nil, in: size)
        #expect(top == CGRect(x: 100, y: 20, width: 200, height: 180))
    }

    @Test func aspectResizeKeepsTheRatioInsideTheFrame() {
        let size = CGSize(width: 1000, height: 500)
        let r = CGRect(x: 100, y: 100, width: 160, height: 90)
        let br = CropGeometry.resized(r, handle: .bottomRight, to: CGPoint(x: 900, y: 200), aspect: 16.0 / 9, in: size)
        // Width wins (800) but height would be 450 > 400 available below y=100 → limited by height.
        #expect(abs(br.width / br.height - 16.0 / 9) < 1e-9)
        #expect(br.minX == 100 && br.minY == 100)
        #expect(br.maxY <= 500 + 1e-9 && br.maxX <= 1000 + 1e-9)
        #expect(abs(br.height - 400) < 1e-9)
        // Edge handle with aspect grows the other axis around its centre line.
        let right = CropGeometry.resized(r, handle: .right, to: CGPoint(x: 420, y: 0), aspect: 1, in: size)
        #expect(right.width == 320 && right.height == 320)
        #expect(abs(right.midY - r.midY) < 1e-9 || right.minY == 0)
    }

    @Test func aspectPresetsFitLargestCenteredRect() {
        let size = CGSize(width: 1920, height: 1080)
        let sq = CropGeometry.largest(aspect: 1, in: size)
        #expect(sq == CGRect(x: 420, y: 0, width: 1080, height: 1080))
        let tall = CropGeometry.largest(aspect: 9.0 / 16, in: size, centeredAt: CGPoint(x: 100, y: 540))
        #expect(tall.minX == 0 && tall.height == 1080)
        #expect(AspectPreset.original.ratio(original: size) == 1920.0 / 1080)
        #expect(AspectPreset.free.ratio(original: size) == nil)
        let conformed = CropGeometry.conform(CGRect(x: 0, y: 0, width: 400, height: 100), aspect: 1, in: size)
        #expect(conformed.width == conformed.height && abs(conformed.width - 200) < 1e-9)
    }

    @Test func engineRectIsWholeEvenAndInside() {
        let size = CGSize(width: 320, height: 180)
        #expect(CropGeometry.engineRect(CGRect(x: 10.4, y: 20.6, width: 101.7, height: 51.2), videoSize: size) == [10, 21, 102, 50])
        #expect(CropGeometry.engineRect(CGRect(x: 300, y: 170, width: 100, height: 100), videoSize: size) == [300, 170, 20, 10])
        #expect(CropGeometry.engineRect(CGRect(x: -3, y: -3, width: 999, height: 999), videoSize: size) == [0, 0, 320, 180])
        #expect(CropGeometry.isFullFrame(CGRect(x: 0, y: 0, width: 320, height: 180), videoSize: size))
        #expect(CropGeometry.isFullFrame(CGRect(x: 0.2, y: 0, width: 319.9, height: 180), videoSize: size))
        #expect(!CropGeometry.isFullFrame(CGRect(x: 0, y: 0, width: 300, height: 180), videoSize: size))
        // Odd frame: full width rounds down to even, still "full".
        #expect(CropGeometry.isFullFrame(CGRect(x: 0, y: 0, width: 321, height: 181), videoSize: CGSize(width: 321, height: 181)))
    }
}

@Suite struct EditorDraftTests {
    typealias T = ToolID

    @Test func panelsMapToEngineTools() {
        #expect(EditorPanel.panels(isVideo: true) == [.trim, .split, .crop, .snapshot, .speed])
        #expect(EditorPanel.panels(isVideo: false) == [.trim, .bleep])
        let pairs: [(String, EditorPanel, Bool)] = [
            ("video.trim", .trim, true), ("video.split", .split, true), ("video.crop", .crop, true),
            ("video.snapshot", .snapshot, true), ("video.speed", .speed, true),
            ("audio.trim", .trim, false), ("audio.bleep", .bleep, false),
        ]
        for (id, panel, isVideo) in pairs {
            let mapped = EditorPanel.panel(for: ToolID(id))
            #expect(mapped?.panel == panel && mapped?.isVideo == isVideo, "\(id)")
            #expect(panel.toolID(isVideo: isVideo) == ToolID(id))
        }
        #expect(EditorPanel.panel(for: "video.compress") == nil)
    }

    @Test func trimOptionsAndValidation() {
        var d = EditorDraft(isVideo: true, duration: 10, videoSize: CGSize(width: 320, height: 180))
        #expect(d.problem(for: .trim) != nil)   // whole clip = nothing to trim
        d.keep.setLowerBound(of: 0, to: 1)
        d.keep.setUpperBound(of: 0, to: 4)
        d.keep.add(6...8)
        d.precise = false
        #expect(d.problem(for: .trim) == nil)
        #expect(d.options(for: .trim, playhead: 0) == ["ranges": .ranges([1...4, 6...8]), "precise": .bool(false)])
        #expect(d.outputLength(for: .trim) == 5)
        d.keep.reset(to: [])
        #expect(d.problem(for: .trim) == "Keep at least one section.")

        var a = EditorDraft(isVideo: false, duration: 5, videoSize: nil)
        a.keep.setUpperBound(of: 0, to: 2.5)
        #expect(a.options(for: .trim, playhead: 0) == ["ranges": .ranges([0...2.5])])   // audio: no `precise`
    }

    @Test func splitOptionsComeFromMarkers() {
        var d = EditorDraft(isVideo: true, duration: 9, videoSize: CGSize(width: 320, height: 180))
        #expect(d.problem(for: .split) == "Add at least one split point.")
        d.markers.add(3)
        d.markers.add(6)
        #expect(d.options(for: .split, playhead: 0) == ["ranges": .ranges([0...3, 3...6, 6...9]), "precise": .bool(true)])
    }

    @Test func cropOptionsAreEngineRect() {
        var d = EditorDraft(isVideo: true, duration: 3, videoSize: CGSize(width: 320, height: 180))
        #expect(d.problem(for: .crop) != nil)   // full frame
        d.crop = CGRect(x: 10.2, y: 5.7, width: 99.4, height: 81)
        #expect(d.problem(for: .crop) == nil)
        #expect(d.options(for: .crop, playhead: 0) == ["rect": .list([10, 6, 98, 80])])
        d.setAspect(.square)
        #expect(d.aspect == .square)
        #expect(abs(d.crop.width - d.crop.height) < 1e-9)
        d.resetCrop()
        #expect(d.crop == CGRect(x: 0, y: 0, width: 320, height: 180) && d.aspect == .free)
        d.setAspect(.sixteenNine)   // full frame → largest 16:9 (the whole 320×180 frame)
        #expect(approx(d.crop, CGRect(x: 0, y: 0, width: 320, height: 180), 1e-6))
        let audio = EditorDraft(isVideo: false, duration: 3, videoSize: nil)
        #expect(audio.problem(for: .crop) != nil)
    }

    @Test func snapshotTimeIsClamped() {
        #expect(EditorDraft.clampSnapshot(-4, duration: 10) == 0)
        #expect(approx(EditorDraft.clampSnapshot(10, duration: 10), 9.95))
        #expect(EditorDraft.clampSnapshot(4.2, duration: 10) == 4.2)
        #expect(EditorDraft.clampSnapshot(1, duration: 0.01) == 0)
        #expect(EditorDraft.clampSnapshot(.infinity, duration: 3) == 0)
        let d = EditorDraft(isVideo: true, duration: 2, videoSize: CGSize(width: 160, height: 120))
        guard case .double(let t)? = d.options(for: .snapshot, playhead: 5)["time"] else { Issue.record("no time"); return }
        #expect(approx(t, 1.95))
        #expect(d.problem(for: .snapshot) == nil)
    }

    @Test func speedAndBleepOptions() {
        var d = EditorDraft(isVideo: true, duration: 10, videoSize: CGSize(width: 320, height: 180))
        #expect(d.options(for: .speed, playhead: 0) == ["speed": .double(2)])
        d.speed = 1
        #expect(d.problem(for: .speed) != nil)
        d.speed = 0.333333
        #expect(d.options(for: .speed, playhead: 0) == ["speed": .double(0.33)])
        #expect(d.outputLength(for: .speed).map { abs($0 - 30.00003) < 0.001 } == true)

        var b = EditorDraft(isVideo: false, duration: 5, videoSize: nil)
        #expect(b.problem(for: .bleep) == "Mark at least one section to bleep.")
        b.bleeps.add(1...1.5)
        b.bleeps.add(3...3.2)
        b.frequency = 1234.4
        b.tone = false
        #expect(b.problem(for: .bleep) == nil)
        #expect(b.options(for: .bleep, playhead: 0) == [
            "ranges": .ranges([1...1.5, 3...3.2]), "frequency": .double(1234), "tone": .bool(false),
        ])
        b.frequency = 99_999
        #expect(b.options(for: .bleep, playhead: 0)["frequency"] == .double(4000))
    }

    @Test func zeroDurationIsNeverSubmittable() {
        let d = EditorDraft(isVideo: true, duration: 0, videoSize: CGSize(width: 2, height: 2))
        for p in EditorPanel.allCases { #expect(d.problem(for: p) != nil) }
    }
}

@Suite struct TimeFormatTests {
    @Test func formats() {
        #expect(TimeFormat.string(0) == "0:00.00")
        #expect(TimeFormat.string(1.255) == "0:01.26" || TimeFormat.string(1.255) == "0:01.25")
        #expect(TimeFormat.string(62.5) == "1:02.50")
        #expect(TimeFormat.string(3723, fractionDigits: 0) == "1:02:03")
        #expect(TimeFormat.string(59.999) == "1:00.00")
        #expect(TimeFormat.string(5, fractionDigits: 3, forceHours: true) == "0:00:05.000")
        #expect(TimeFormat.string(-3) == "0:00.00")
        #expect(TimeFormat.length(1.5) == "1.5 s")
        #expect(TimeFormat.length(125) == "2:05")
    }

    @Test func parses() {
        #expect(TimeFormat.parse("62.5") == 62.5)
        #expect(TimeFormat.parse("1:02.5") == 62.5)
        #expect(TimeFormat.parse(" 1:02:03 ") == 3723)
        #expect(TimeFormat.parse("1:75") == nil)
        #expect(TimeFormat.parse("-1") == nil)
        #expect(TimeFormat.parse("abc") == nil)
        #expect(TimeFormat.parse("1:2:3:4") == nil)
    }
}
