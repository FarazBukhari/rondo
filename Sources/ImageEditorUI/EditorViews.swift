import RondoKit
import SwiftUI

/// Root of the editor window: panel tabs + zoom on top, canvas + inspector, file info + Cancel/Save below.
struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(model: model)
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    EditorCanvas(model: model)
                    switch model.loadState {
                    case .loading:
                        ProgressView("Opening image…")
                            .padding(18)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                    case .failed(let message):
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 28))
                            Text("Can't open this image").font(.headline)
                            Text(message).font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
                        }
                        .padding(20)
                        .frame(maxWidth: 360)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
                    case .ready:
                        EmptyView()
                    }
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    InspectorContent(model: model)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 276)
                .disabled(model.loadState != .ready)
            }
            Divider()
            EditorFooter(model: model)
        }
        .frame(minWidth: 780, idealWidth: 1040, maxWidth: .infinity, minHeight: 500, idealHeight: 700, maxHeight: .infinity)
    }
}

// MARK: - Top bar

struct EditorTopBar: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(EditorPanel.allCases.enumerated()), id: \.element) { index, panel in
                PanelTab(panel: panel, selected: model.panel == panel, edited: model.hasEdits(panel)) {
                    model.panel = panel
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                Button { model.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command)
                    .help("Zoom out")
                Text("\(model.zoomPercent)%")
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 50)
                Button { model.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command)
                    .help("Zoom in")
                Divider().frame(height: 16).padding(.horizontal, 4)
                Button("Fit") { model.zoomToFit() }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("Fit the image in the window")
                Button("1:1") { model.zoomToActualSize() }
                    .help("One image pixel per screen point")
            }
            .buttonStyle(.borderless)
            .disabled(model.loadState != .ready)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct PanelTab: View {
    let panel: EditorPanel
    let selected: Bool
    let edited: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: panel.symbol)
                Text(panel.title)
                if edited && !selected {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                }
            }
            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundColor(selected ? .white : .primary)
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(edited ? "\(panel.title) (edited)" : panel.title)
    }
}

// MARK: - Footer

struct EditorFooter: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo").foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if model.loadState == .ready {
                    Text("\(Int(model.sourceSize.width)) × \(Int(model.sourceSize.height)) px")
                        .font(.caption).foregroundColor(.secondary).monospacedDigit()
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            Spacer(minLength: 8)
            Text(model.statusHint)
                .font(.callout)
                .foregroundColor(model.otherEditedPanels.isEmpty || !model.canSave ? .secondary : .orange)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button("Save Copy") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Inspector

struct InspectorContent: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        switch model.panel {
        case .crop: CropInspector(model: model)
        case .adjust: AdjustInspector(model: model)
        case .annotate: AnnotateInspector(model: model)
        case .redact: RedactInspector(model: model)
        case .background: BackgroundInspector(model: model)
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundColor(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 34, height: 26)
        }
        .help(help)
    }
}

/// Color swatches + system picker; `allowsClear` adds a "none" (transparent) swatch.
struct SwatchPicker: View {
    let color: RGBAColor?
    var swatches: [RGBAColor] = RGBAColor.swatches
    var allowsClear = false
    var supportsOpacity = false
    let onChange: (RGBAColor?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if allowsClear {
                swatch(nil)
            }
            ForEach(swatches, id: \.self) { swatch($0) }
            Spacer(minLength: 0)
            ColorPicker("", selection: Binding(
                get: { (color ?? .white).cgColor },
                set: { onChange(RGBAColor(cgColor: $0)) }
            ), supportsOpacity: supportsOpacity)
            .labelsHidden()
        }
    }

    private func same(_ a: RGBAColor?, _ b: RGBAColor?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x?, y?): x.withAlpha(1).hex == y.withAlpha(1).hex
        default: false
        }
    }

    @ViewBuilder private func swatch(_ c: RGBAColor?) -> some View {
        let selected = same(color, c)
        Button { onChange(c) } label: {
            ZStack {
                if let c {
                    Circle().fill(Color(cgColor: c.withAlpha(1).cgColor))
                } else {
                    Circle().fill(Color.white)
                    Path { p in p.move(to: CGPoint(x: 3, y: 15)); p.addLine(to: CGPoint(x: 15, y: 3)) }
                        .stroke(Color.red, lineWidth: 1.5)
                }
                Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-3) }
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(c?.hex ?? "Transparent")
    }
}

// MARK: Crop

struct CropInspector: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        let crop = model.crop
        let r = CropMath.pixelRect(crop.rect, bounds: crop.bounds) ?? .zero
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("Aspect ratio") {
                Picker("", selection: Binding(get: { model.crop.aspect }, set: { model.crop.setAspect($0) })) {
                    ForEach(AspectPreset.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                if crop.aspect.hasOrientation {
                    Picker("", selection: Binding(get: { model.crop.portrait }, set: { model.crop.setPortrait($0) })) {
                        Text("Landscape").tag(false)
                        Text("Portrait").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            InspectorSection("Rotate & flip") {
                HStack(spacing: 6) {
                    IconButton(symbol: "rotate.left", help: "Rotate left") { model.crop.rotateCounterClockwise() }
                    IconButton(symbol: "rotate.right", help: "Rotate right") { model.crop.rotateClockwise() }
                    IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontally") { model.crop.flipHorizontal() }
                    IconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertically") { model.crop.flipVertical() }
                }
            }
            InspectorSection("Selection") {
                InfoRow(label: "Size", value: "\(Int(r.width)) × \(Int(r.height)) px")
                InfoRow(label: "Origin", value: "\(Int(r.minX)), \(Int(r.minY))")
                InfoRow(label: "Rotation", value: rotationText(crop.orientation))
                HStack {
                    Button("Select All") { model.crop.rect = CropMath.full(model.crop.bounds) }
                        .disabled(crop.isFullFrame)
                    Button("Reset") { model.crop.reset() }
                        .disabled(!crop.hasChanges && crop.aspect == .free)
                }
            }
            Hint("Drag on the image to draw a selection; drag its corners or edges to resize, or inside it to move. Scroll or Space-drag to pan, pinch or ⌘-scroll to zoom.")
        }
    }

    private func rotationText(_ o: Orientation) -> String {
        var parts = ["\(o.rotation)°"]
        if o.flipH { parts.append("flipped ↔") }
        if o.flipV { parts.append("flipped ↕") }
        return parts.joined(separator: ", ")
    }
}

// MARK: Adjust

struct AdjustInspector: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("Filter") {
                Picker("", selection: $model.adjust.filter) {
                    ForEach(AdjustSettings.filters, id: \.self) { Text($0 == "none" ? "None" : $0.capitalized).tag($0) }
                }
                .labelsHidden()
            }
            ForEach(["Light", "Color", "Detail"], id: \.self) { group in
                InspectorSection(group) {
                    ForEach(AdjustSettings.sliders.filter { $0.group == group }, id: \.key) { spec in
                        AdjustSliderRow(spec: spec, value: Binding(
                            get: { model.adjust[spec.key] },
                            set: { model.adjust[spec.key] = ($0 / spec.step).rounded() * spec.step }
                        ))
                    }
                }
            }
            Button("Reset All") { model.adjust = AdjustSettings() }
                .disabled(model.adjust.isDefault)
            Hint("Press and hold on the image to compare with the original. Double-click a slider's name to reset it.")
        }
    }
}

struct AdjustSliderRow: View {
    let spec: AdjustSettings.Slider
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(spec.title)
                Spacer()
                Text(formatted).monospacedDigit().foregroundColor(.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = spec.defaultValue }
            Slider(value: $value, in: spec.range)
                .controlSize(.small)
        }
    }

    private var formatted: String {
        spec.step >= 1 ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }
}

// MARK: Annotate

struct AnnotateInspector: View {
    @ObservedObject var model: ImageEditorModel
    @FocusState private var textFocused: Bool

    private var activeKind: AnnotationKind? { model.selectedAnnotation?.kind ?? model.annotateTool.kind }

    var body: some View {
        let style = model.currentStyle
        let longEdge = max(model.sourceSize.width, model.sourceSize.height)
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("Tool") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(AnnotateTool.allCases) { tool in
                        Button { model.annotateTool = tool } label: {
                            VStack(spacing: 3) {
                                Image(systemName: tool.symbol).font(.system(size: 14))
                                Text(tool.title).font(.system(size: 10))
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .foregroundColor(model.annotateTool == tool ? .white : .primary)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(model.annotateTool == tool ? Color.accentColor : Color.primary.opacity(0.06)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tool.title)
                    }
                }
            }
            InspectorSection("Color") {
                SwatchPicker(color: style.color.withAlpha(1)) { c in
                    if let c { model.updateStyle { $0.color = c } }
                }
            }
            if let kind = activeKind, kind != .text, kind != .highlight {
                InspectorSection("Line width") {
                    HStack {
                        Slider(value: Binding(get: { style.lineWidth }, set: { v in model.updateStyle { $0.lineWidth = v.rounded() } }),
                               in: 1...Double(max(40, (longEdge / 20).rounded())))
                            .controlSize(.small)
                        Text("\(Int(style.lineWidth)) px").monospacedDigit().font(.callout).frame(width: 52, alignment: .trailing)
                    }
                }
            }
            if let kind = activeKind, kind == .rect || kind == .ellipse {
                Toggle("Filled", isOn: Binding(get: { style.fill }, set: { v in model.updateStyle { $0.fill = v } }))
            }
            if activeKind == .text {
                InspectorSection("Text") {
                    TextField("Type text", text: Binding(get: { model.selectedAnnotation?.text ?? "" }, set: { model.setSelectedText($0) }),
                              axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($textFocused)
                        .disabled(model.selectedAnnotation?.kind != .text)
                    HStack {
                        Slider(value: Binding(get: { style.fontSize }, set: { v in model.updateStyle { $0.fontSize = v.rounded() } }),
                               in: 8...Double(max(200, (longEdge / 4).rounded())))
                            .controlSize(.small)
                        Text("\(Int(style.fontSize)) px").monospacedDigit().font(.callout).frame(width: 52, alignment: .trailing)
                    }
                }
            }
            InspectorSection("Shapes") {
                InfoRow(label: "On image", value: "\(model.annotations.count)")
                HStack {
                    Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(!model.canUndo)
                    Button { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                        .disabled(!model.hasSelection)
                    Button("Clear") { model.clearAll() }
                        .disabled(model.annotations.isEmpty)
                }
            }
            Hint("Drag on the image to draw. Click a shape with Select to move it; Delete removes it. Text: click where it should start, then type here.")
        }
        .onChange(of: model.focusTextRequest) { _ in textFocused = true }
    }
}

// MARK: Redact

struct RedactInspector: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("Style") {
                Picker("", selection: $model.redact.style) {
                    ForEach(RedactStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if model.redact.style == .black {
                InspectorSection("Fill color") {
                    SwatchPicker(color: model.redact.color,
                                 swatches: [.black, .white, RGBAColor(r: 0.5, g: 0.5, b: 0.5), .red, .blue]) { c in
                        if let c { model.redact.color = c.withAlpha(1) }
                    }
                }
            }
            InspectorSection("Regions") {
                InfoRow(label: "Marked", value: "\(model.redact.regions.count)")
                HStack {
                    Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(!model.canUndo)
                    Button { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                        .disabled(!model.hasSelection)
                    Button("Clear") { model.clearAll() }
                        .disabled(model.redact.regions.isEmpty)
                }
            }
            Hint("Drag over anything that should be hidden. Regions are rounded outward to whole pixels and burned into the saved copy at full resolution.")
        }
    }
}

// MARK: Background

struct BackgroundInspector: View {
    @ObservedObject var model: ImageEditorModel

    var body: some View {
        let out = model.background.outputSize(for: model.sourceSize)
        let maxPadding = Double(min(BackgroundSettings.paddingRange.upperBound,
                                    max(50, Int(max(model.sourceSize.width, model.sourceSize.height) / 2))))
        VStack(alignment: .leading, spacing: 18) {
            if BackgroundMode.available.count > 1 {
                InspectorSection("Mode") {
                    Picker("", selection: $model.background.mode) {
                        ForEach(BackgroundMode.available, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            if model.background.mode != .remove {
                InspectorSection("Color") {
                    SwatchPicker(color: model.background.color, swatches: [.white, .black, RGBAColor(r: 0.93, g: 0.93, b: 0.95), .yellow, .blue],
                                 allowsClear: true, supportsOpacity: true) { model.background.color = $0 }
                }
            }
            InspectorSection("Padding") {
                HStack {
                    Slider(value: Binding(get: { Double(model.background.padding) }, set: { model.background.padding = Int($0.rounded()) }),
                           in: 0...maxPadding)
                        .controlSize(.small)
                    Text("\(model.background.padding) px").monospacedDigit().font(.callout).frame(width: 60, alignment: .trailing)
                }
                InfoRow(label: "Output", value: "\(Int(out.width)) × \(Int(out.height)) px")
            }
            if let error = model.backgroundError {
                Text(error).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Hint(hint)
        }
    }

    private var hint: String {
        switch model.background.mode {
        case .fill: "Fills transparent areas with the color and adds even padding on every side."
        case .replace: "Finds the main subject and puts it on the color. Needs macOS 14 subject detection."
        case .remove: "Finds the main subject and makes everything else transparent (saved as PNG when needed)."
        }
    }
}
