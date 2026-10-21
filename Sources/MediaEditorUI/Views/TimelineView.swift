import AppKit
import SwiftUI

/// Filmstrip (video) or waveform (audio) with the active panel's overlay: kept/bleeped ranges with
/// drag handles, split markers, and the playhead. Click or drag anywhere on the track to scrub.
/// Size it from outside (`.frame(height:)`); the track fills whatever height it gets.
struct TimelineView: View {
    @ObservedObject var model: MediaEditorModel

    static let space = "timeline"

    var body: some View {
        GeometryReader { geo in
            TimelineContent(model: model, width: max(1, geo.size.width), height: max(1, geo.size.height))
        }
        .padding(.horizontal, EditorStyle.handleWidth)
    }
}

private struct TimelineContent: View {
    @ObservedObject var model: MediaEditorModel
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            track(width: width)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .gesture(scrub(width: width))
            overlay(width: width)
            Playhead(height: height, color: model.isVideo ? EditorStyle.playhead : Color(nsColor: .labelColor))
                .position(x: x(model.currentTime, width), y: height / 2)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .coordinateSpace(name: TimelineView.space)
    }

    func x(_ t: Double, _ width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(t / model.duration) * width
    }

    func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        min(max(0, Double(x / width) * model.duration), model.duration)
    }

    // MARK: Track

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        if model.isVideo {
            Filmstrip(frames: model.filmstrip, count: MediaEditorModel.filmstripCount, height: height)
        } else {
            WaveformTrack(levels: model.waveform, highlight: highlightRanges, highlightColor: highlightColor,
                          dimOutside: model.panel == .trim, duration: model.duration)
        }
    }

    private var highlightRanges: [ClosedRange<Double>] {
        model.activeRanges?.ranges ?? []
    }

    private var highlightColor: Color {
        model.panel == .bleep ? EditorStyle.bleep : EditorStyle.keep
    }

    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(TimelineView.space))
            .onChanged { value in
                model.beginScrub()   // no-op unless playing; endScrub resumes
                model.seek(to: time(value.location.x, width))
            }
            .onEnded { value in
                let t = time(value.location.x, width)
                if abs(value.translation.width) < 3 {
                    model.selectRange(at: t)
                    if model.panel == .split { model.selectMarker(near: t, tolerance: Double(8 / width) * model.duration) }
                }
                model.endScrub()
            }
    }

    // MARK: Overlay

    @ViewBuilder
    private func overlay(width: CGFloat) -> some View {
        switch model.panel {
        case .trim, .bleep:
            rangesOverlay(width: width)
        case .split:
            markersOverlay(width: width)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func rangesOverlay(width: CGFloat) -> some View {
        let list = model.activeRanges
        let ranges = list?.ranges ?? []
        let isTrim = model.panel == .trim
        let color = highlightColor
        // Dim what Trim throws away (the filmstrip; the waveform colours itself).
        if isTrim, model.isVideo {
            ForEach(Array((list?.complement ?? []).enumerated()), id: \.offset) { _, gap in
                Rectangle().fill(EditorStyle.dim)
                    .frame(width: max(0, x(gap.upperBound, width) - x(gap.lowerBound, width)), height: height)
                    .offset(x: x(gap.lowerBound, width))
                    .allowsHitTesting(false)
            }
        }
        ForEach(Array(ranges.enumerated()), id: \.offset) { i, r in
            let x0 = x(r.lowerBound, width), x1 = x(r.upperBound, width)
            let selected = model.selectedRange == i
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isTrim ? Color.clear : color.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(color, lineWidth: selected ? 3 : 2))
                .frame(width: max(2, x1 - x0), height: height)
                .offset(x: x0)
                .allowsHitTesting(false)
            RangeHandle(model: model, index: i, isLower: true, color: color, height: height, width: width)
                .offset(x: x0 - EditorStyle.handleWidth)
            RangeHandle(model: model, index: i, isLower: false, color: color, height: height, width: width)
                .offset(x: x1)
        }
    }

    @ViewBuilder
    private func markersOverlay(width: CGFloat) -> some View {
        let parts = model.draft.markers.parts
        ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
            let mid = x((part.lowerBound + part.upperBound) / 2, width)
            Text(verbatim: "\(i + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .position(x: mid, y: height - 10)
                .allowsHitTesting(false)
        }
        ForEach(Array(model.draft.markers.times.enumerated()), id: \.offset) { i, t in
            MarkerHandle(model: model, index: i, height: height, width: width)
                .position(x: x(t, width), y: height / 2)
        }
    }
}

// MARK: - Pieces

private struct Playhead: View {
    let height: CGFloat
    let color: Color

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(color).frame(width: 2, height: height + 8)
            Circle().fill(color).frame(width: 9, height: 9).offset(y: -5)
        }
        .shadow(color: .black.opacity(0.45), radius: 1.5)
        .frame(width: 12, height: height + 8)
    }
}

/// One end of a range: a tab outside the range, dragged to move that bound (and seek there).
private struct RangeHandle: View {
    @ObservedObject var model: MediaEditorModel
    let index: Int
    let isLower: Bool
    let color: Color
    let height: CGFloat
    let width: CGFloat
    @State private var start: Double?

    var body: some View {
        let shape = UnevenCorners(left: isLower ? 4 : 0, right: isLower ? 0 : 4)
        shape.fill(color)
            .overlay(
                VStack(spacing: 3) {
                    ForEach(0..<3) { _ in Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: 2) }
                }
            )
            .frame(width: EditorStyle.handleWidth, height: height)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineView.space))
                    .onChanged { value in
                        guard let kp = model.rangesKeyPath, model.draft[keyPath: kp].ranges.indices.contains(index) else { return }
                        model.pause()
                        let r = model.draft[keyPath: kp].ranges[index]
                        if start == nil { start = isLower ? r.lowerBound : r.upperBound }
                        let t = (start ?? 0) + Double(value.translation.width / width) * model.duration
                        let applied = isLower
                            ? model.draft[keyPath: kp].setLowerBound(of: index, to: t)
                            : model.draft[keyPath: kp].setUpperBound(of: index, to: t)
                        model.selectedRange = index
                        model.seek(to: applied)
                    }
                    .onEnded { _ in
                        start = nil
                        model.commitRangeDrag()
                    }
            )
            .help(isLower ? "Drag to set the start" : "Drag to set the end")
    }
}

/// A split point: line across the track with a grab tab on top.
private struct MarkerHandle: View {
    @ObservedObject var model: MediaEditorModel
    let index: Int
    let height: CGFloat
    let width: CGFloat
    @State private var start: Double?

    var body: some View {
        let selected = model.selectedMarker == index
        ZStack(alignment: .top) {
            Rectangle().fill(EditorStyle.marker).frame(width: selected ? 3 : 2, height: height)
            Image(systemName: "scissors")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 16, height: 14)
                .background(RoundedRectangle(cornerRadius: 3).fill(EditorStyle.marker))
                .offset(y: -7)
        }
        .frame(width: 16, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(TimelineView.space))
                .onChanged { value in
                    guard model.draft.markers.times.indices.contains(index) else { return }
                    model.pause()
                    if start == nil { start = model.draft.markers.times[index] }
                    let t = (start ?? 0) + Double(value.translation.width / width) * model.duration
                    model.selectedMarker = index
                    model.seek(to: model.draft.markers.move(index, to: t))
                }
                .onEnded { _ in start = nil }
        )
        .simultaneousGesture(TapGesture().onEnded { model.selectedMarker = index })
        .help("Drag to move the split point")
    }
}

/// Rect with independently rounded left/right corners (UnevenRoundedRectangle is macOS 14+).
private struct UnevenCorners: Shape {
    let left: CGFloat
    let right: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + left, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - right, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + right), radius: right)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - right))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - right, y: r.maxY), radius: right)
        p.addLine(to: CGPoint(x: r.minX + left, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - left), radius: left)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + left))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + left, y: r.minY), radius: left)
        p.closeSubpath()
        return p
    }
}

/// Thumbnails stretched across the track; a soft placeholder until they arrive.
struct Filmstrip: View {
    let frames: [MediaEditorModel.FilmFrame]
    let count: Int
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let cell = geo.size.width / CGFloat(max(1, count))
            ZStack(alignment: .leading) {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                ForEach(frames) { f in
                    Image(nsImage: f.image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cell, height: height)
                        .clipped()
                        .offset(x: cell * CGFloat(f.id))
                }
                if frames.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: height)
    }
}

/// Peak bars, coloured inside the highlighted ranges.
struct WaveformTrack: View {
    let levels: [Float]
    let highlight: [ClosedRange<Double>]
    let highlightColor: Color
    let dimOutside: Bool
    let duration: Double

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(EditorStyle.trackBackground))
            let mid = size.height / 2
            ctx.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(EditorStyle.waveform.opacity(0.4)))
            let barStep: CGFloat = 3
            let bars = max(1, Int(size.width / barStep))
            let values = PreviewGenerator.resample(levels, to: bars)
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * barStep
                let t = duration * Double((x + 1) / size.width)
                let inside = highlight.contains { $0.contains(t) }
                let color: Color = inside ? highlightColor : (dimOutside ? EditorStyle.waveform.opacity(0.35) : EditorStyle.waveform)
                let h = max(1, CGFloat(v) * (size.height - 8))
                ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - h / 2, width: 2, height: h), cornerRadius: 1), with: .color(color))
            }
        }
    }
}
