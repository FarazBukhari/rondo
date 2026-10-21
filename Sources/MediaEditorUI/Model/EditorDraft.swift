import CoreGraphics
import Foundation
import MediaEngine
import RondoKit

/// One editor panel = one engine tool.
public enum EditorPanel: String, CaseIterable, Identifiable, Sendable {
    case trim, split, crop, snapshot, speed, bleep

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .trim: "Trim"
        case .split: "Split"
        case .crop: "Crop"
        case .snapshot: "Snapshot"
        case .speed: "Speed"
        case .bleep: "Bleep"
        }
    }

    public var symbol: String {
        switch self {
        case .trim: "timeline.selection"
        case .split: "scissors"
        case .crop: "crop"
        case .snapshot: "camera"
        case .speed: "speedometer"
        case .bleep: "speaker.slash"
        }
    }

    /// Label of the window's primary button.
    public var actionTitle: String {
        switch self {
        case .trim: "Trim"
        case .split: "Split"
        case .crop: "Crop"
        case .snapshot: "Save Snapshot"
        case .speed: "Change Speed"
        case .bleep: "Bleep"
        }
    }

    public static func panels(isVideo: Bool) -> [EditorPanel] {
        isVideo ? [.trim, .split, .crop, .snapshot, .speed] : [.trim, .bleep]
    }

    public func toolID(isVideo: Bool) -> ToolID {
        typealias T = FFmpegEngine.ToolIDs
        switch self {
        case .trim: return isVideo ? T.videoTrim : T.audioTrim
        case .split: return T.videoSplit
        case .crop: return T.videoCrop
        case .snapshot: return T.videoSnapshot
        case .speed: return T.videoSpeed
        case .bleep: return T.audioBleep
        }
    }

    /// Panel + media kind for a tool id; nil for tools without an editor panel.
    public static func panel(for tool: ToolID) -> (panel: EditorPanel, isVideo: Bool)? {
        typealias T = FFmpegEngine.ToolIDs
        switch tool {
        case T.videoTrim: return (.trim, true)
        case T.videoSplit: return (.split, true)
        case T.videoCrop: return (.crop, true)
        case T.videoSnapshot: return (.snapshot, true)
        case T.videoSpeed: return (.speed, true)
        case T.audioTrim: return (.trim, false)
        case T.audioBleep: return (.bleep, false)
        default: return nil
        }
    }
}

/// Everything the user has set in the editor, independent of views. Builds the engine's option dictionary.
public struct EditorDraft: Equatable, Sendable {
    public var isVideo: Bool
    public var duration: Double
    /// Displayed (post-rotation) frame size; nil for audio.
    public var videoSize: CGSize?
    public var frameRate: Double

    public var keep: TimeRangeList
    public var bleeps: TimeRangeList
    public var markers: SplitMarkers
    public var crop: CGRect
    public var aspect: AspectPreset = .free
    public var speed: Double = 2
    public var precise = true
    public var tone = true
    public var frequency: Double = 1000

    public static let minRangeLength = 0.1
    public static let speedRange: ClosedRange<Double> = 0.25...4
    public static let frequencyRange: ClosedRange<Double> = 200...4000

    public init(isVideo: Bool, duration: Double, videoSize: CGSize?, frameRate: Double = 30) {
        let d = max(0, duration)
        self.isVideo = isVideo
        self.duration = d
        self.videoSize = videoSize
        self.frameRate = frameRate > 0 && frameRate < 1000 ? frameRate : 30
        keep = .whole(duration: d, minLength: Self.minRangeLength)
        bleeps = TimeRangeList(duration: d, minLength: Self.minRangeLength)
        markers = SplitMarkers(duration: d, minGap: Self.minRangeLength)
        crop = CGRect(origin: .zero, size: videoSize ?? .zero)
    }

    /// The engine snapshots at most 50 ms before the end (the last frame may not decode exactly at `duration`).
    public static func clampSnapshot(_ t: Double, duration: Double) -> Double {
        guard t.isFinite else { return 0 }
        return min(max(0, t), max(0, duration - 0.05))
    }

    /// Clip length after the edit (for the footer summary).
    public func outputLength(for panel: EditorPanel) -> Double? {
        switch panel {
        case .trim: keep.totalLength
        case .speed: speed > 0 ? duration / speed : nil
        default: nil
        }
    }

    /// Why the panel can't be applied yet, or nil when it can.
    public func problem(for panel: EditorPanel) -> String? {
        guard duration > 0 else { return "This file has no playable duration." }
        switch panel {
        case .trim:
            if keep.isEmpty { return "Keep at least one section." }
            if keep.coversWholeClip { return "Drag the handles to choose what to keep." }
        case .split:
            if markers.isEmpty { return "Add at least one split point." }
        case .crop:
            guard let size = videoSize, size.width >= 2, size.height >= 2 else { return "This file has no video picture to crop." }
            if CropGeometry.isFullFrame(crop, videoSize: size) { return "Drag the corners to choose an area." }
        case .snapshot:
            if videoSize == nil { return "This file has no video picture." }
        case .speed:
            if abs(speed - 1) < 0.001 { return "Pick a speed other than 1×." }
        case .bleep:
            if bleeps.isEmpty { return "Mark at least one section to bleep." }
        }
        return nil
    }

    /// Engine options for `panel` (keys from MediaEngine; times in seconds). `playhead` feeds Snapshot.
    public func options(for panel: EditorPanel, playhead: Double) -> [String: OptionValue] {
        switch panel {
        case .trim:
            var o: [String: OptionValue] = ["ranges": .ranges(keep.ranges)]
            if isVideo { o["precise"] = .bool(precise) }
            return o
        case .split:
            return ["ranges": .ranges(markers.parts), "precise": .bool(precise)]
        case .crop:
            return ["rect": .list(CropGeometry.engineRect(crop, videoSize: videoSize ?? .zero))]
        case .snapshot:
            return ["time": .double(Self.clampSnapshot(playhead, duration: duration))]
        case .speed:
            let s = min(100, max(0.1, (speed * 100).rounded() / 100))
            return ["speed": .double(s)]
        case .bleep:
            return ["ranges": .ranges(bleeps.ranges),
                    "frequency": .double(min(Self.frequencyRange.upperBound, max(Self.frequencyRange.lowerBound, frequency.rounded()))),
                    "tone": .bool(tone)]
        }
    }

    // MARK: Crop helpers

    public mutating func setAspect(_ preset: AspectPreset) {
        aspect = preset
        guard let size = videoSize, let ratio = preset.ratio(original: size) else { return }
        crop = CropGeometry.isFullFrame(crop, videoSize: size)
            ? CropGeometry.largest(aspect: ratio, in: size)
            : CropGeometry.conform(crop, aspect: ratio, in: size)
    }

    public mutating func resetCrop() {
        aspect = .free
        crop = CGRect(origin: .zero, size: videoSize ?? .zero)
    }

    public var aspectRatio: Double? {
        guard let size = videoSize else { return nil }
        return aspect.ratio(original: size)
    }
}
