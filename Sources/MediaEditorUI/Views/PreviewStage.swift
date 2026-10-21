import AppKit
import AVKit
import SwiftUI

/// Video picture (player, or still frame while no player exists) with the crop overlay on top.
struct PreviewStage: View {
    @ObservedObject var model: MediaEditorModel

    static let space = "stage"
    static let inset: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: Self.inset, dy: Self.inset)
            let videoSize = model.draft.videoSize ?? CGSize(width: 16, height: 9)
            let frame = CropGeometry.aspectFit(videoSize, in: bounds)
            ZStack(alignment: .topLeading) {
                EditorStyle.stage
                picture
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                if model.panel == .crop, model.draft.videoSize != nil {
                    CropOverlay(model: model, frame: frame, videoSize: videoSize)
                }
                if model.panel == .snapshot {
                    Rectangle()
                        .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .frame(width: frame.width + 6, height: frame.height + 6)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                }
                badge.padding(10)
            }
            .coordinateSpace(name: Self.space)
        }
        .clipShape(RoundedRectangle(cornerRadius: EditorStyle.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var picture: some View {
        if let player = model.player {
            PlayerSurface(player: player)
        } else if let image = model.stillFrame ?? model.nearestFilmFrame {
            Image(nsImage: image).resizable().interpolation(.medium)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch model.preview {
        case .preparing(let p):
            Label("Preparing preview \(Int(p * 100))%", systemImage: "hourglass")
                .modifier(BadgeStyle())
        case .unavailable(let why):
            Label(why, systemImage: "play.slash")
                .modifier(BadgeStyle())
        default:
            EmptyView()
        }
    }
}

struct BadgeStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.6)))
    }
}

/// AVPlayerView without controls (the editor draws its own transport).
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

/// Crop rectangle over the picture: dimmed outside, thirds grid, 8 handles, drag inside to move.
/// Edits `model.draft.crop` in displayed video pixels.
struct CropOverlay: View {
    @ObservedObject var model: MediaEditorModel
    let frame: CGRect
    let videoSize: CGSize
    @State private var dragStart: CGRect?

    private var scale: CGFloat { frame.width > 0 ? videoSize.width / frame.width : 1 }

    var body: some View {
        let r = CropGeometry.videoToView(model.draft.crop, frame: frame, videoSize: videoSize)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(frame)
                p.addRect(r)
            }
            .fill(EditorStyle.dim, style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { p in
                for i in 1...2 {
                    let fx = r.minX + r.width * CGFloat(i) / 3
                    let fy = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: fx, y: r.minY)); p.addLine(to: CGPoint(x: fx, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: fy)); p.addLine(to: CGPoint(x: r.maxX, y: fy))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
            .allowsHitTesting(false)

            Rectangle()
                .fill(Color.white.opacity(0.001))
                .overlay(Rectangle().stroke(Color.white, lineWidth: 1.5))
                .frame(width: max(1, r.width), height: max(1, r.height))
                .position(x: r.midX, y: r.midY)
                .gesture(moveGesture)

            ForEach(CropHandle.allCases, id: \.self) { handle in
                let p = handle.point(in: r)
                handleShape(handle)
                    .position(x: p.x, y: p.y)
                    .gesture(resizeGesture(handle))
            }

            sizeLabel(r)
        }
    }

    @ViewBuilder
    private func handleShape(_ handle: CropHandle) -> some View {
        let size: CGSize = handle.isCorner ? CGSize(width: 14, height: 14)
            : (handle.movesX ? CGSize(width: 6, height: 22) : CGSize(width: 22, height: 6))
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .frame(width: size.width, height: size.height)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }

    private func sizeLabel(_ r: CGRect) -> some View {
        let e = CropGeometry.engineRect(model.draft.crop, videoSize: videoSize)
        let y = r.maxY + 16 <= frame.maxY + PreviewStage.inset ? r.maxY + 14 : r.maxY - 14
        return Text(verbatim: "\(Int(e[2])) × \(Int(e[3]))")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.65)))
            .position(x: r.midX, y: y)
            .allowsHitTesting(false)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(PreviewStage.space))
            .onChanged { value in
                if dragStart == nil { dragStart = model.draft.crop }
                guard let start = dragStart else { return }
                let delta = CGSize(width: value.translation.width * scale, height: value.translation.height * scale)
                model.draft.crop = CropGeometry.moved(start, by: delta, in: videoSize)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(PreviewStage.space))
            .onChanged { value in
                if dragStart == nil { dragStart = model.draft.crop }
                guard let start = dragStart else { return }
                let origin = handle.point(in: start)
                let p = CGPoint(x: origin.x + value.translation.width * scale, y: origin.y + value.translation.height * scale)
                let minSize = max(16, min(videoSize.width, videoSize.height) * 0.04)
                model.draft.crop = CropGeometry.resized(start, handle: handle, to: p, aspect: model.draft.aspectRatio,
                                                        in: videoSize, minSize: minSize)
            }
            .onEnded { _ in dragStart = nil }
    }
}
