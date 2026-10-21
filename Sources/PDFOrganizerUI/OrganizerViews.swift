import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Window-level callbacks shared by every mode.
struct OrganizerActions {
    var cancel: () -> Void = {}
    var submit: () -> Void = {}
}

// MARK: - Chrome

/// Toolbar strip on top, content, then a footer with status + Cancel / primary button.
struct OrganizerChrome<Toolbar: View, Content: View>: View {
    let status: String
    var notice: String? = nil
    let submitTitle: String
    let canSubmit: Bool
    let actions: OrganizerActions
    @ViewBuilder var toolbar: () -> Toolbar
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) { toolbar() }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(.bar)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 12)
                Button("Cancel", action: actions.cancel)
                    .help("Close without saving (Esc)")
                Button(submitTitle, action: actions.submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .help("\(submitTitle) (⌘↩)")
            }
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

struct ToolbarIconButton: View {
    let title: String
    let symbol: String
    let shortcut: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 22, height: 18)
        }
        .disabled(!enabled)
        .help(shortcut.isEmpty ? title : "\(title) (\(shortcut))")
    }
}

struct ZoomSlider: View {
    @Binding var value: CGFloat
    var range: ClosedRange<CGFloat> = 88...220

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
            Slider(value: $value, in: range).frame(width: 110).controlSize(.small)
            Image(systemName: "square.grid.2x2").font(.caption).foregroundStyle(.secondary)
        }
        .help("Thumbnail size")
    }
}

struct LoadErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Can't organize this file").font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

enum GridMetrics {
    static let spacing: CGFloat = 18
}

/// Original palette for split parts (alternates so adjacent parts never share a color).
enum PartPalette {
    static let colors: [Color] = [
        Color(red: 0.13, green: 0.60, blue: 0.62),
        Color(red: 0.93, green: 0.54, blue: 0.16),
        Color(red: 0.50, green: 0.39, blue: 0.86),
        Color(red: 0.86, green: 0.32, blue: 0.47),
        Color(red: 0.33, green: 0.65, blue: 0.30),
        Color(red: 0.21, green: 0.49, blue: 0.88),
    ]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

// MARK: - Page thumbnail

/// A page image aspect-fit in a `side`×`side` square, rotated by the user's added rotation.
struct PageThumb: View {
    let image: CGImage?
    let rotation: Int
    let side: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .overlay(Rectangle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 2.5, x: 0, y: 1)
                    .rotationEffect(.degrees(Double(rotation)))
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: side * 0.72, height: side * 0.93)
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(width: side, height: side)
        .animation(.easeInOut(duration: 0.2), value: rotation)
    }
}

/// Selection ring + background shared by grid cells.
private struct CellHighlight: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2))
    }
}

private struct PageLabel: View {
    let text: String
    let selected: Bool
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? Color.accentColor : Color.clear))
    }
}

// MARK: - Reorder

struct ReorderView: View {
    @ObservedObject var model: ReorderModel
    @ObservedObject var thumbs: ThumbnailStore
    let actions: OrganizerActions

    init(model: ReorderModel, actions: OrganizerActions) {
        self.model = model
        self.thumbs = model.thumbnails
        self.actions = actions
    }

    var body: some View {
        OrganizerChrome(status: model.statusText, submitTitle: "Save Copy", canSubmit: model.canSubmit, actions: actions) {
            let sel = model.hasSelection && model.loadError == nil
            ToolbarIconButton(title: "Rotate Left", symbol: "rotate.left", shortcut: "⇧⌘R", enabled: sel) { model.rotateSelection(by: -90) }
            ToolbarIconButton(title: "Rotate Right", symbol: "rotate.right", shortcut: "⌘R", enabled: sel) { model.rotateSelection(by: 90) }
            ToolbarIconButton(title: "Delete Pages", symbol: "trash", shortcut: "⌫", enabled: sel) { model.deleteSelection() }
            Divider().frame(height: 18)
            ToolbarIconButton(title: "Undo", symbol: "arrow.uturn.backward", shortcut: "⌘Z", enabled: model.history.canUndo) { model.undo() }
            ToolbarIconButton(title: "Redo", symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z", enabled: model.history.canRedo) { model.redo() }
            Spacer()
            Text("Drag to reorder · ⌘-click to select more")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            ZoomSlider(value: $model.thumbSize)
        } content: {
            if let error = model.loadError {
                LoadErrorView(message: error)
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        let side = model.thumbSize
        let target = model.dropTarget
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side + 14, maximum: side + 14), spacing: GridMetrics.spacing)],
                      spacing: 16) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    ReorderCell(item: item, position: index + 1, side: side,
                                image: thumbs.image(ThumbKey(url: model.url, page: item.source)),
                                selected: model.selection.selected.contains(item.id),
                                dropEdge: target?.id == item.id ? (target?.before == true ? .leading : .trailing) : nil)
                        .onAppear { thumbs.request(ThumbKey(url: model.url, page: item.source)) }
                        .onTapGesture { model.click(item.id, kind: ClickKind(NSEvent.modifierFlags)) }
                        .onDrag {
                            model.beginDrag(item.id)
                            return PageDragPayload.provider(for: item.id)
                        }
                        .onDrop(of: [PageDragPayload.type], delegate: PageDropDelegate(model: model, id: item.id, width: side + 14))
                }
            }
            .padding(20)
            .animation(.easeInOut(duration: 0.18), value: model.items)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { model.clearSelection() }
        .onDrop(of: [PageDragPayload.type], delegate: EndDropDelegate(model: model))
    }
}

struct ReorderCell: View {
    let item: PageItem
    let position: Int
    let side: CGFloat
    let image: CGImage?
    let selected: Bool
    let dropEdge: HorizontalEdge?

    var body: some View {
        VStack(spacing: 5) {
            PageThumb(image: image, rotation: item.rotation, side: side)
                .modifier(CellHighlight(selected: selected))
                .overlay(alignment: dropEdge == .trailing ? .trailing : .leading) {
                    if dropEdge != nil {
                        // Centered in the gap between columns.
                        let shift = GridMetrics.spacing / 2 + 2
                        Capsule().fill(Color.accentColor).frame(width: 4).padding(.vertical, 4)
                            .offset(x: dropEdge == .trailing ? shift : -shift)
                    }
                }
            HStack(spacing: 4) {
                PageLabel(text: "\(position)", selected: selected)
                if item.source != position {
                    Text("p. \(item.source)").font(.caption2).foregroundStyle(.secondary)
                }
                if item.rotation != 0 {
                    Label("\(item.rotation)°", systemImage: "arrow.clockwise")
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: side + 14, height: 18)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(position), from source page \(item.source)\(item.rotation != 0 ? ", rotated \(item.rotation) degrees" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// In-app drag payload (never exported to other apps).
enum PageDragPayload {
    static let type = UTType.utf8PlainText

    static func provider(for id: Int) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(Data("rondo-page:\(id)".utf8), nil)
            return nil
        }
        return provider
    }
}

struct PageDropDelegate: DropDelegate {
    let model: ReorderModel
    let id: Int
    let width: CGFloat

    func validateDrop(info: DropInfo) -> Bool { model.dragging != nil && !info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.dropTarget?.id == id { model.dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard model.dragging != nil else { return false }
        model.drop(on: .init(id: id, before: info.location.x < width / 2))
        return true
    }

    private func update(_ info: DropInfo) {
        guard model.dragging != nil else { return }
        let target = ReorderModel.DropTarget(id: id, before: info.location.x < width / 2)
        if model.dropTarget != target { model.dropTarget = target }
    }
}

/// Drop in the empty area after the last page → move to the end.
struct EndDropDelegate: DropDelegate {
    let model: ReorderModel
    func validateDrop(info: DropInfo) -> Bool { model.dragging != nil && !info.hasItemsConforming(to: [.fileURL]) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard model.dragging != nil else { return false }
        model.dropAtEnd()
        return true
    }
}

// MARK: - Split

struct SplitView: View {
    @ObservedObject var model: SplitModel
    @ObservedObject var thumbs: ThumbnailStore
    let actions: OrganizerActions

    init(model: SplitModel, actions: OrganizerActions) {
        self.model = model
        self.thumbs = model.thumbnails
        self.actions = actions
    }

    var body: some View {
        OrganizerChrome(status: model.statusText, submitTitle: "Split", canSubmit: model.canSubmit, actions: actions) {
            Picker("Split", selection: $model.style) {
                ForEach(SplitModel.Style.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.loadError != nil)
            Divider().frame(height: 18)
            if model.style == .ranges {
                Button {
                    model.addPart()
                } label: {
                    Label("Add Part", systemImage: "plus.rectangle.on.rectangle")
                }
                .disabled(model.selection.selected.isEmpty)
                .help("Turn each run of selected pages into its own PDF")
                Toggle("Include remaining pages", isOn: Binding(get: { model.plan.includeRest }, set: { model.setIncludeRest($0) }))
                    .toggleStyle(.checkbox)
                    .help("Pages outside every part are saved as parts too")
                Spacer()
                ToolbarIconButton(title: "Undo", symbol: "arrow.uturn.backward", shortcut: "⌘Z", enabled: model.history.canUndo) { model.undo() }
                ToolbarIconButton(title: "Redo", symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z", enabled: model.history.canRedo) { model.redo() }
            } else {
                Stepper(value: $model.every, in: 1...max(1, model.pageCount)) {
                    Text("Every \(model.every) page\(model.every == 1 ? "" : "s")").monospacedDigit()
                }
                .fixedSize()
                Spacer()
            }
            ZoomSlider(value: $model.thumbSize)
        } content: {
            if let error = model.loadError {
                LoadErrorView(message: error)
            } else {
                VStack(spacing: 0) {
                    if model.style == .ranges && !model.plan.parts.isEmpty { partsStrip; Divider() }
                    grid
                }
            }
        }
    }

    private var partsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Parts").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(model.plan.parts, id: \.self) { range in
                    let index = model.partIndex(of: range.lowerBound) ?? 0
                    HStack(spacing: 5) {
                        Circle().fill(PartPalette.color(index)).frame(width: 8, height: 8)
                        Text(SplitPlan.describe([range])).font(.caption).monospacedDigit()
                        Button {
                            model.removePart(range)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove this part")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(PartPalette.color(index).opacity(0.14)))
                }
                Button("Clear") { model.clearParts() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(.bar)
    }

    private var grid: some View {
        let side = model.thumbSize
        let ranges = model.outputRanges
        let starts = Set(ranges.map(\.lowerBound))
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: side + 14, maximum: side + 14), spacing: GridMetrics.spacing)],
                      spacing: 16) {
                ForEach(model.pages, id: \.self) { page in
                    let part = ranges.firstIndex { $0.contains(page) }
                    SplitCell(page: page, side: side,
                              image: thumbs.image(ThumbKey(url: model.url, page: page)),
                              selected: model.selection.selected.contains(page),
                              part: part,
                              startsPart: part != nil && starts.contains(page))
                        .onAppear { thumbs.request(ThumbKey(url: model.url, page: page)) }
                        .onTapGesture { model.click(page, kind: ClickKind(NSEvent.modifierFlags)) }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { model.selection.clear() }
    }
}

struct SplitCell: View {
    let page: Int
    let side: CGFloat
    let image: CGImage?
    let selected: Bool
    /// Output file this page lands in (nil = not exported).
    let part: Int?
    let startsPart: Bool

    var body: some View {
        VStack(spacing: 5) {
            PageThumb(image: image, rotation: 0, side: side)
                .opacity(part == nil ? 0.4 : 1)
                .modifier(CellHighlight(selected: selected))
                .overlay(alignment: .topLeading) {
                    if let part, startsPart {
                        Text("PDF \(part + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(PartPalette.color(part)))
                            .offset(x: -2, y: -4)
                    }
                }
            Capsule()
                .fill(part.map(PartPalette.color) ?? Color.secondary.opacity(0.18))
                .frame(height: 4)
                .padding(.horizontal, 6)
            PageLabel(text: "\(page)", selected: selected)
                .frame(height: 16)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(page)\(part.map { ", in PDF \($0 + 1)" } ?? ", not exported")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Merge

struct MergeView: View {
    @ObservedObject var model: MergeModel
    @ObservedObject var thumbs: ThumbnailStore
    let actions: OrganizerActions
    @State private var dropTargeted = false

    init(model: MergeModel, actions: OrganizerActions) {
        self.model = model
        self.thumbs = model.thumbnails
        self.actions = actions
    }

    var body: some View {
        OrganizerChrome(status: model.statusText, notice: model.notice, submitTitle: "Merge", canSubmit: model.canSubmit, actions: actions) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Add PDFs…", systemImage: "plus")
            }
            ToolbarIconButton(title: "Remove from List", symbol: "minus.circle", shortcut: "⌫", enabled: !model.selection.isEmpty) { model.removeSelection() }
            Divider().frame(height: 18)
            ToolbarIconButton(title: "Move Up", symbol: "arrow.up", shortcut: "", enabled: !model.selection.isEmpty) { model.shiftSelection(by: -1) }
            ToolbarIconButton(title: "Move Down", symbol: "arrow.down", shortcut: "", enabled: !model.selection.isEmpty) { model.shiftSelection(by: 1) }
            ToolbarIconButton(title: "Sort by Name", symbol: "textformat.abc", shortcut: "", enabled: model.entries.count > 1) { model.sortByName() }
            Spacer()
            ToolbarIconButton(title: "Undo", symbol: "arrow.uturn.backward", shortcut: "⌘Z", enabled: model.history.canUndo) { _ = model.perform(.undo) }
            ToolbarIconButton(title: "Redo", symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z", enabled: model.history.canRedo) { _ = model.perform(.redo) }
        } content: {
            ZStack {
                if model.entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.on.doc").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                        Text("Drop PDFs here").font(.title3.weight(.semibold))
                        Text("They're merged top to bottom.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                } else {
                    list
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                FileDrop.loadURLs(providers) { urls in model.add(urls) }
                return true
            }
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                MergeRow(index: index + 1, entry: entry, image: thumbs.image(ThumbKey(url: entry.url, page: 1))) {
                    model.remove(entry.id)
                }
                .tag(entry.id)
                .onAppear { thumbs.request(ThumbKey(url: entry.url, page: 1)) }
            }
            .onMove { model.move(fromOffsets: $0, toOffset: $1) }
            .onInsert(of: [.fileURL]) { index, providers in
                FileDrop.loadURLs(providers) { urls in model.add(urls, at: index) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }
}

struct MergeRow: View {
    let index: Int
    let entry: MergeEntry
    let image: CGImage?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            PageThumb(image: image, rotation: 0, side: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(entry.pageCount) page\(entry.pageCount == 1 ? "" : "s") · \(entry.url.deletingLastPathComponent().lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove from list (the file isn't touched)")
        }
        .padding(.vertical, 4)
    }
}

enum FileDrop {
    /// Resolves file URLs from drop providers, then calls `done` on the main actor.
    static func loadURLs(_ providers: [NSItemProvider], done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (i, provider) in providers.enumerated() where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    urls.append((i, url))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ordered = urls.sorted { $0.0 < $1.0 }.map(\.1)
            Task { @MainActor in done(ordered) }
        }
    }
}
