import AppKit
import SwiftUI

/// Root view of an editor window.
struct MediaEditorView: View {
    @ObservedObject var model: MediaEditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isVideo ? "film" : "waveform")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            Text(model.detailsLine)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Picker("Tool", selection: $model.panel) {
                ForEach(EditorPanel.panels(isVideo: model.isVideo)) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.load != .ready)
            panelShortcuts
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// ⌘1…⌘5 switch panels.
    private var panelShortcuts: some View {
        ZStack {
            ForEach(Array(EditorPanel.panels(isVideo: model.isVideo).enumerated()), id: \.offset) { i, p in
                Button("") { model.panel = p }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.load {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading \(model.url.lastPathComponent)…").foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundColor(.secondary)
                Text("Can't edit this file").font(.headline)
                Text(message).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            editor
        }
    }

    private var editor: some View {
        VStack(spacing: 12) {
            if model.isVideo {
                PreviewStage(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TransportBar(model: model)
                TimelineView(model: model)
                    .frame(height: 56)
            } else {
                TimelineView(model: model)
                    .frame(minHeight: 120, maxHeight: .infinity)
                    .padding(.top, 6)
                TransportBar(model: model)
            }
            PanelControls(model: model)
                .frame(minHeight: 28)
        }
        .padding(16)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: model.problem == nil ? "checkmark.circle" : "info.circle")
                .foregroundColor(.secondary)
            Text(model.statusText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button(model.panel.actionTitle) { model.submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Play/pause, frame step, time readout, preview status.
struct TransportBar: View {
    @ObservedObject var model: MediaEditorModel

    var body: some View {
        HStack(spacing: 6) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .disabled(!model.canPlay)
            .help("Play / Pause (Space)")

            Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Previous frame (←)")
            Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Next frame (→)")

            Text("\(TimeFormat.string(model.currentTime)) / \(TimeFormat.string(model.duration))")
                .font(.system(size: 12, design: .monospaced))
                .padding(.leading, 6)

            Spacer()

            if !model.isVideo {
                switch model.preview {
                case .preparing(let p):
                    Text(verbatim: "Preparing playback \(Int(p * 100))%").font(.caption).foregroundColor(.secondary)
                case .unavailable(let why):
                    Text(why).font(.caption).foregroundColor(.secondary)
                default:
                    EmptyView()
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }
}

/// Per-panel controls under the timeline.
struct PanelControls: View {
    @ObservedObject var model: MediaEditorModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.panel {
            case .trim: trim
            case .bleep: bleep
            case .split: split
            case .crop: crop
            case .snapshot: snapshot
            case .speed: speed
            }
        }
        .controlSize(.regular)
    }

    // MARK: Trim / Bleep

    @ViewBuilder
    private var inOut: some View {
        Button { model.setInPoint() } label: { Label("Start", systemImage: "arrow.right.to.line") }
            .help("Set the start to the playhead (I)")
        Button { model.setOutPoint() } label: { Label("End", systemImage: "arrow.left.to.line") }
            .help("Set the end to the playhead (O)")
    }

    @ViewBuilder
    private var trim: some View {
        inOut
        Divider().frame(height: 18)
        Button { model.addRange() } label: { Label("Add Section", systemImage: "plus") }
            .help("Keep another section, starting at the playhead")
        Button { model.removeSection() } label: { Label("Cut Here", systemImage: "scissors") }
            .help("Remove a short section around the playhead, then drag its edges")
        Button { model.removeSelectedRange() } label: { Label("Delete", systemImage: "trash") }
            .disabled(model.selectedRange == nil)
            .help("Delete the selected section (⌫)")
        Spacer()
        if model.isVideo {
            Toggle("Frame-accurate", isOn: $model.draft.precise)
                .help("Re-encode for exact cut points. Off: faster keyframe cut (single section only).")
        }
    }

    @ViewBuilder
    private var bleep: some View {
        Button { model.addRange() } label: { Label("Add Bleep", systemImage: "plus") }
            .help("Mark half a second at the playhead (B)")
        inOut
        Button { model.removeSelectedRange() } label: { Label("Delete", systemImage: "trash") }
            .disabled(model.selectedRange == nil)
        Spacer()
        Toggle("Tone", isOn: $model.draft.tone)
            .help("Off: silence instead of a beep")
        Slider(value: $model.draft.frequency, in: EditorDraft.frequencyRange, step: 50)
            .frame(width: 140)
            .disabled(!model.draft.tone)
        Text(verbatim: "\(Int(model.draft.frequency)) Hz")
            .font(.system(size: 12).monospacedDigit())
            .frame(width: 58, alignment: .leading)
            .foregroundColor(model.draft.tone ? .primary : .secondary)
    }

    // MARK: Split

    @ViewBuilder
    private var split: some View {
        Button { model.addMarker() } label: { Label("Split at Playhead", systemImage: "plus") }
            .disabled(!model.draft.markers.canAdd(model.currentTime))
            .help("Add a split point (M)")
        Button { model.removeMarker() } label: { Label("Remove", systemImage: "minus") }
            .disabled(model.draft.markers.isEmpty)
        Divider().frame(height: 18)
        Stepper("Equal parts: \(model.equalParts)", value: $model.equalParts, in: 2...50)
            .fixedSize()
        Button("Apply") { model.applyEqualParts() }
        Spacer()
        Toggle("Frame-accurate", isOn: $model.draft.precise)
            .help("Re-encode for exact cut points. Off: faster keyframe cuts.")
    }

    // MARK: Crop

    private var aspectBinding: Binding<AspectPreset> {
        Binding(get: { model.draft.aspect }, set: { model.draft.setAspect($0) })
    }

    @ViewBuilder
    private var crop: some View {
        Picker("Aspect", selection: aspectBinding) {
            ForEach(AspectPreset.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        Button { model.draft.resetCrop() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
        Spacer()
        let e = CropGeometry.engineRect(model.draft.crop, videoSize: model.draft.videoSize ?? .zero)
        Text(verbatim: "x \(Int(e[0]))  y \(Int(e[1]))  ·  \(Int(e[2])) × \(Int(e[3])) px")
            .font(.system(size: 12).monospacedDigit())
            .foregroundColor(.secondary)
    }

    // MARK: Snapshot

    @ViewBuilder
    private var snapshot: some View {
        Image(systemName: "camera").foregroundColor(.secondary)
        Text("Saves the frame under the playhead as a PNG. Use ← → to step one frame.")
            .foregroundColor(.secondary)
            .lineLimit(1)
        Spacer()
        Text(verbatim: "Frame \(Int((EditorDraft.clampSnapshot(model.currentTime, duration: model.duration) * model.draft.frameRate).rounded()) + 1)")
            .font(.system(size: 12).monospacedDigit())
            .foregroundColor(.secondary)
    }

    // MARK: Speed

    /// Slider position is log2(speed) so 0.25×…4× is symmetric around 1×.
    private var logSpeed: Binding<Double> {
        Binding(get: { log2(max(0.01, model.draft.speed)) },
                set: { model.draft.speed = (pow(2, $0) * 20).rounded() / 20 })
    }

    @ViewBuilder
    private var speed: some View {
        Image(systemName: "tortoise").foregroundColor(.secondary)
        Slider(value: logSpeed, in: log2(EditorDraft.speedRange.lowerBound)...log2(EditorDraft.speedRange.upperBound))
            .frame(minWidth: 180, maxWidth: 280)
        Image(systemName: "hare").foregroundColor(.secondary)
        Text(SpeedFormat.label(model.draft.speed))
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .frame(width: 52)
        Spacer()
        ForEach([0.5, 1.5, 2, 4], id: \.self) { s in
            Button(SpeedFormat.label(s)) { model.draft.speed = s }
        }
    }
}
