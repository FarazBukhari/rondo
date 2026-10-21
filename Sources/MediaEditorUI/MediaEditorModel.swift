import AppKit
import AVFoundation
import Foundation
import RondoKit

/// State + behaviour behind one editor window. Owns the preview work (probe, filmstrip/waveform,
/// playback or proxy) and tears it all down in `shutdown()`. Never writes beside the user's file.
@MainActor
public final class MediaEditorModel: ObservableObject {
    public enum LoadState: Equatable { case loading, ready, failed(String) }

    public enum PreviewState: Equatable {
        case none
        /// AVFoundation plays the file itself.
        case native
        /// Building a playable proxy (fraction done).
        case preparing(Double)
        /// Playing a proxy copy from TempDir.
        case proxy
        /// No live playback; scrubbing shows still frames.
        case unavailable(String)
    }

    struct FilmFrame: Identifiable {
        let id: Int
        let time: Double
        let image: NSImage
    }

    public let url: URL
    public let isVideo: Bool
    let tools: ToolLocator

    @Published public var panel: EditorPanel {
        didSet { if panel != oldValue { panelChanged() } }
    }
    @Published public private(set) var load: LoadState = .loading
    @Published public private(set) var details: MediaDetails?
    @Published public var draft: EditorDraft
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var preview: PreviewState = .none
    @Published var selectedRange: Int?
    @Published var selectedMarker: Int?
    @Published var equalParts = 2
    @Published private(set) var filmstrip: [FilmFrame] = []
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var player: AVPlayer?
    /// Frame at the playhead while there is no player (proxy building or unavailable).
    @Published private(set) var stillFrame: NSImage?

    var submitHandler: (([URL], ToolID, [String: OptionValue]) -> Void)?
    var closeHandler: (() -> Void)?
    public private(set) var didSubmit = false
    public private(set) var isShutDown = false
    /// Scratch dir for previews (removed on shutdown).
    public private(set) var workDir: URL?

    static let filmstripCount = 12
    static let waveformBuckets = 800

    private var tasks: [Task<Void, Never>] = []
    /// Still-frame jobs by request number. Superseded ones are cancelled but stay here until they
    /// finish, so `shutdown()` waits for their ffmpeg children too.
    private var stillTasks: [Int: Task<Void, Never>] = [:]
    private var stillCounter = 0
    private var cleanupTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isSeeking = false
    private var seekGeneration = 0
    private var wasPlayingBeforeScrub = false
    private var lastProxyProgress = -1.0

    public init(url: URL, panel: EditorPanel, isVideo: Bool, tools: ToolLocator = ToolLocator()) {
        self.url = url
        self.isVideo = isVideo
        self.tools = tools
        let panels = EditorPanel.panels(isVideo: isVideo)
        self.panel = panels.contains(panel) ? panel : panels[0]
        self.draft = EditorDraft(isVideo: isVideo, duration: 0, videoSize: nil)
    }

    // MARK: Lifecycle

    /// Probes the file, then builds the filmstrip/waveform and playback in the background.
    public func start() {
        guard tasks.isEmpty, !isShutDown, load == .loading else { return }
        do {
            workDir = try TempDir.make(prefix: "media-editor")
        } catch {
            editorLog.error("no scratch dir: \(error.localizedDescription, privacy: .public)")
        }
        tasks.append(Task { [weak self] in await self?.loadAll() })
    }

    private func loadAll() async {
        let details: MediaDetails
        do {
            details = try await MediaDetails.probe(url, tools: tools)
            try Task.checkCancellation()
            guard details.duration > 0 else {
                throw EngineError.invalidInput("\(url.lastPathComponent) has no duration.")
            }
            if isVideo && !details.hasVideo { throw EngineError.invalidInput("\(url.lastPathComponent) has no video track.") }
            if !isVideo && !details.hasAudio { throw EngineError.invalidInput("\(url.lastPathComponent) has no audio track.") }
        } catch is CancellationError {
            return
        } catch {
            guard !isShutDown else { return }
            load = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        guard !isShutDown, !Task.isCancelled else { return }
        apply(details)
        guard let work = workDir else {
            preview = .unavailable("No scratch space for previews")
            return
        }
        let gen = PreviewGenerator(source: url, workDir: work, tools: tools)
        let native = await PreviewGenerator.canPlayNatively(url, needsVideo: isVideo)
        guard !isShutDown, !Task.isCancelled else { return }
        tasks.append(Task { [weak self] in await self?.preparePlayback(gen, details: details, native: native) })
        if isVideo {
            tasks.append(Task { [weak self] in await self?.buildFilmstrip(gen, duration: details.duration, native: native) })
        } else {
            tasks.append(Task { [weak self] in await self?.buildWaveform(gen, details: details) })
        }
    }

    private func apply(_ d: MediaDetails) {
        details = d
        draft = EditorDraft(isVideo: isVideo, duration: d.duration, videoSize: isVideo ? d.displaySize : nil,
                            frameRate: d.frameRate ?? 30)
        selectedRange = panel == .trim ? 0 : nil
        currentTime = panel == .snapshot ? d.duration / 2 : 0
        load = .ready
    }

    /// Stops playback, cancels every preview process, and removes the scratch dir once they exit.
    /// Never submits. Safe to call more than once.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        if let player {
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.replaceCurrentItem(with: nil)
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        isPlaying = false
        player = nil
        let running = tasks + Array(stillTasks.values)
        tasks.removeAll()
        stillTasks.removeAll()
        running.forEach { $0.cancel() }
        let dir = workDir
        // Remove the scratch dir only after every preview task has returned: ProcessRunner returns
        // from a cancelled run only once its ffmpeg child has exited, so nothing can write into it later.
        cleanupTask = Task.detached {
            for t in running { await t.value }
            if let dir { TempDir.remove(dir) }
        }
        editorLog.notice("editor closed for \(self.url.lastPathComponent, privacy: .public)")
    }

    /// Waits until cancelled preview processes have exited and the scratch dir is gone.
    public func waitForCleanup() async {
        await cleanupTask?.value
    }

    /// Last resort when cleanup didn't finish in time (app quitting): delete the scratch dir now.
    func removeWorkDirNow() {
        if let workDir { TempDir.remove(workDir) }
    }

    // MARK: Submit / cancel

    public var toolID: ToolID { panel.toolID(isVideo: isVideo) }

    public var problem: String? {
        switch load {
        case .loading: return "Loading…"
        case .failed(let message): return message
        case .ready: return draft.problem(for: panel)
        }
    }

    public var canSubmit: Bool { problem == nil && !didSubmit && !isShutDown }

    public var options: [String: OptionValue] { draft.options(for: panel, playhead: currentTime) }

    /// Calls the submit handler once with this panel's tool and options, then closes the window.
    public func submit() {
        guard canSubmit else { return }
        didSubmit = true
        let tool = toolID, opts = options
        editorLog.notice("submit \(tool.rawValue, privacy: .public) for \(self.url.lastPathComponent, privacy: .public)")
        player?.pause()
        submitHandler?([url], tool, opts)
        closeHandler?()
    }

    /// Closes without submitting.
    public func cancel() {
        closeHandler?()
    }

    // MARK: Playback

    var duration: Double { draft.duration }
    var frameDuration: Double { 1 / max(1, draft.frameRate) }
    var canPlay: Bool { player != nil }

    public func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    public func pause() {
        player?.pause()
        isPlaying = false
    }

    /// Moves the playhead (and the player, frame-accurately). Without a player, refreshes the still frame.
    public func seek(to t: Double) {
        let v = min(max(0, t.isFinite ? t : 0), duration)
        currentTime = v
        if let player {
            seekGeneration += 1
            let generation = seekGeneration
            isSeeking = true
            player.seek(to: CMTime(seconds: v, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.seekGeneration == generation else { return }
                    self.isSeeking = false
                }
            }
        } else if isVideo {
            requestStillFrame()
        }
    }

    public func step(frames: Int) {
        pause()
        seek(to: currentTime + Double(frames) * frameDuration)
    }

    func beginScrub() {
        if isPlaying {
            wasPlayingBeforeScrub = true
            pause()
        }
    }

    func endScrub() {
        if wasPlayingBeforeScrub {
            wasPlayingBeforeScrub = false
            togglePlay()
        }
    }

    private func attachPlayer(_ p: AVPlayer) {
        guard !isShutDown else { return }
        p.actionAtItemEnd = .pause
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.playerTick(seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.playbackEnded() }
        }
        player = p
        seek(to: currentTime)
    }

    private func playerTick(_ seconds: Double) {
        guard isPlaying, !isSeeking, seconds.isFinite else { return }
        currentTime = min(max(0, seconds), duration)
    }

    private func playbackEnded() {
        isPlaying = false
        currentTime = duration
    }

    // MARK: Background preview work

    private func preparePlayback(_ gen: PreviewGenerator, details: MediaDetails, native: Bool) async {
        if native {
            guard !Task.isCancelled, !isShutDown else { return }
            preview = .native
            attachPlayer(AVPlayer(url: url))
            return
        }
        guard !Task.isCancelled, !isShutDown else { return }
        guard gen.ffmpeg != nil else {
            preview = .unavailable("Playback needs ffmpeg for this format")
            return
        }
        preview = .preparing(0)
        if isVideo { requestStillFrame() }
        do {
            let proxy = try await gen.proxy(hasVideo: isVideo, hasAudio: details.hasAudio, duration: details.duration) { p in
                Task { @MainActor [weak self] in self?.proxyProgress(p) }
            }
            try Task.checkCancellation()
            guard !isShutDown else { return }
            preview = .proxy
            attachPlayer(AVPlayer(url: proxy))
        } catch is CancellationError {
            return
        } catch {
            guard !isShutDown else { return }
            editorLog.error("proxy failed: \(error.localizedDescription, privacy: .public)")
            preview = .unavailable("Live preview unavailable for this file")
        }
    }

    private func proxyProgress(_ p: Double) {
        guard case .preparing = preview, p - lastProxyProgress >= 0.01 || p >= 1 else { return }
        lastProxyProgress = p
        preview = .preparing(p)
    }

    /// Native formats: one AVAssetImageGenerator (no child processes; results hop straight to the
    /// main queue). Anything it couldn't produce — or non-native formats — via ffmpeg, 3 at a time.
    private func buildFilmstrip(_ gen: PreviewGenerator, duration: Double, native: Bool) async {
        let times = PreviewGenerator.thumbnailTimes(count: Self.filmstripCount, duration: duration)
        let height = 108
        if native {
            await PreviewGenerator.avFrames(url: url, times: times, height: CGFloat(height)) { [weak self] i, image in
                self?.addFilmFrame(i, time: times[i], image: image)
            }
        }
        let missing = times.indices.filter { i in !filmstrip.contains { $0.id == i } }
        guard !missing.isEmpty, gen.ffmpeg != nil, !Task.isCancelled, !isShutDown else { return }
        await withTaskGroup(of: (Int, URL?).self) { group in
            var queue = missing[...]
            func enqueue() {
                guard let i = queue.popFirst() else { return }
                let t = times[i]
                group.addTask { (i, try? await gen.frame(at: t, height: height, name: "thumb-\(i).png")) }
            }
            for _ in 0..<3 { enqueue() }
            while let (i, file) = await group.next() {
                guard !Task.isCancelled, !isShutDown else { group.cancelAll(); return }
                if let file, let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
                    addFilmFrame(i, time: times[i], image: image)
                }
                enqueue()
            }
        }
    }

    private func addFilmFrame(_ i: Int, time: Double, image: NSImage) {
        guard !isShutDown, !filmstrip.contains(where: { $0.id == i }) else { return }
        filmstrip.append(FilmFrame(id: i, time: time, image: image))
    }

    private func buildWaveform(_ gen: PreviewGenerator, details: MediaDetails) async {
        do {
            let levels = try await gen.waveform(duration: details.duration, sampleRate: details.sampleRate, buckets: Self.waveformBuckets)
            guard !isShutDown, !Task.isCancelled else { return }
            waveform = levels
        } catch {
            if !(error is CancellationError) {
                editorLog.notice("waveform failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Debounced ffmpeg frame at the playhead, shown while there is no player.
    private func requestStillFrame() {
        guard isVideo, player == nil, !isShutDown, let work = workDir else { return }
        stillTasks.values.forEach { $0.cancel() }
        stillCounter += 1
        let n = stillCounter
        let t = EditorDraft.clampSnapshot(currentTime, duration: duration)
        let height = Int(min(720, details?.displaySize?.height ?? 720))
        let gen = PreviewGenerator(source: url, workDir: work, tools: tools)
        stillTasks[n] = Task { [weak self] in
            await self?.loadStill(gen, at: t, height: height, name: "still-\(n).png")
            self?.stillTasks[n] = nil
        }
    }

    private func loadStill(_ gen: PreviewGenerator, at t: Double, height: Int, name: String) async {
        try? await Task.sleep(nanoseconds: 120_000_000)   // debounce scrubbing
        guard !Task.isCancelled, !isShutDown else { return }
        guard let file = try? await gen.frame(at: t, height: height, name: name) else { return }
        let image = (try? Data(contentsOf: file)).flatMap(NSImage.init(data:))
        try? FileManager.default.removeItem(at: file)
        guard let image, !Task.isCancelled, !isShutDown, player == nil else { return }
        stillFrame = image
    }

    /// Filmstrip frame closest to the playhead (instant feedback before the still frame arrives).
    var nearestFilmFrame: NSImage? {
        filmstrip.min { abs($0.time - currentTime) < abs($1.time - currentTime) }?.image
    }

    // MARK: Panels

    private func panelChanged() {
        selectedMarker = nil
        switch panel {
        case .trim: selectedRange = draft.keep.isEmpty ? nil : (draft.keep.index(containing: currentTime) ?? 0)
        case .bleep: selectedRange = draft.bleeps.index(containing: currentTime)
        default: selectedRange = nil
        }
    }

    /// The range list the current panel edits (Trim → keep, Bleep → bleeps).
    var rangesKeyPath: WritableKeyPath<EditorDraft, TimeRangeList>? {
        switch panel {
        case .trim: \.keep
        case .bleep: \.bleeps
        default: nil
        }
    }

    var activeRanges: TimeRangeList? { rangesKeyPath.map { draft[keyPath: $0] } }

    private func targetRange(in list: TimeRangeList) -> Int? {
        if let s = selectedRange, list.ranges.indices.contains(s) { return s }
        if let i = list.index(containing: currentTime) { return i }
        if let i = list.ranges.lastIndex(where: { $0.upperBound <= currentTime }) { return i }
        return list.isEmpty ? nil : 0
    }

    /// Start of the selected (or playhead) range → playhead. Creates a range if there is none.
    public func setInPoint() {
        guard let kp = rangesKeyPath else { return }
        if let i = targetRange(in: draft[keyPath: kp]) {
            draft[keyPath: kp].setLowerBound(of: i, to: currentTime)
            selectedRange = i
        } else {
            selectedRange = draft[keyPath: kp].add(currentTime...duration)
        }
    }

    /// End of the selected (or playhead) range → playhead. Creates a range if there is none.
    public func setOutPoint() {
        guard let kp = rangesKeyPath else { return }
        if let i = targetRange(in: draft[keyPath: kp]) {
            draft[keyPath: kp].setUpperBound(of: i, to: currentTime)
            selectedRange = i
        } else {
            selectedRange = draft[keyPath: kp].add(0...currentTime)
        }
    }

    /// New range at the playhead (in the free gap there).
    public func addRange() {
        guard let kp = rangesKeyPath else { return }
        let length = panel == .bleep ? 0.5 : min(2, max(EditorDraft.minRangeLength, duration / 10))
        if let i = draft[keyPath: kp].insert(at: currentTime, length: length) { selectedRange = i }
    }

    public func removeSelectedRange() {
        guard let kp = rangesKeyPath, let i = selectedRange ?? draft[keyPath: kp].index(containing: currentTime) else { return }
        draft[keyPath: kp].remove(at: i)
        selectedRange = nil
    }

    /// Trim: cuts a short section around the playhead out of the kept ranges (then drag to adjust).
    public func removeSection() {
        guard panel == .trim else { return }
        let w = max(EditorDraft.minRangeLength * 2, min(2, duration / 10))
        draft.keep.subtract(max(0, currentTime - w / 2)...min(duration, currentTime + w / 2))
        selectedRange = draft.keep.index(containing: currentTime)
    }

    func selectRange(at t: Double) {
        guard let list = activeRanges else { return }
        selectedRange = list.index(containing: t)
    }

    func commitRangeDrag() {
        guard let kp = rangesKeyPath else { return }
        let before = draft[keyPath: kp].count
        draft[keyPath: kp].normalize()
        if draft[keyPath: kp].count != before { selectedRange = draft[keyPath: kp].index(containing: currentTime) }
    }

    public func addMarker() {
        if let i = draft.markers.add(currentTime) { selectedMarker = i }
    }

    public func removeMarker() {
        if let i = selectedMarker {
            draft.markers.remove(at: i)
        } else {
            draft.markers.removeNearest(to: currentTime, within: max(0.25, duration / 50))
        }
        selectedMarker = nil
    }

    func selectMarker(near t: Double, tolerance: Double) {
        selectedMarker = draft.markers.nearest(to: t, within: tolerance)
    }

    public func applyEqualParts() {
        draft.markers.setEqualParts(equalParts)
        selectedMarker = nil
    }

    /// Delete key: remove whatever the panel has selected.
    public func deleteSelection() {
        switch panel {
        case .trim, .bleep: removeSelectedRange()
        case .split: removeMarker()
        case .crop: draft.resetCrop()
        default: break
        }
    }

    // MARK: Keyboard

    /// Plain (unmodified) keys the editor window handles. Returns true when consumed.
    @discardableResult
    public func handle(_ key: EditorKey) -> Bool {
        guard load == .ready else { return false }
        switch key {
        case .space:
            guard canPlay else { return false }
            togglePlay()
        case .left: step(frames: -1)
        case .right: step(frames: 1)
        case .shiftLeft: pause(); seek(to: currentTime - 1)
        case .shiftRight: pause(); seek(to: currentTime + 1)
        case .home: pause(); seek(to: 0)
        case .end: pause(); seek(to: duration)
        case .delete:
            deleteSelection()
        case .character(let c):
            switch (c, panel) {
            case ("i", .trim), ("i", .bleep): setInPoint()
            case ("o", .trim), ("o", .bleep): setOutPoint()
            case ("m", .split): addMarker()
            case ("b", .bleep): addRange()
            default: return false
            }
        }
        return true
    }

    // MARK: Summary

    var detailsLine: String {
        guard let d = details else { return url.lastPathComponent }
        var parts = [TimeFormat.string(d.duration)]
        if isVideo, let s = d.displaySize { parts.append("\(Int(s.width)) × \(Int(s.height))") }
        if isVideo, let f = d.frameRate { parts.append(String(format: "%g fps", locale: Locale(identifier: "en_US_POSIX"), (f * 100).rounded() / 100)) }
        if !isVideo, let sr = d.sampleRate { parts.append(String(format: "%g kHz", locale: Locale(identifier: "en_US_POSIX"), Double(sr) / 1000)) }
        return parts.joined(separator: " · ")
    }

    var statusText: String {
        if let problem { return problem }
        switch panel {
        case .trim:
            let n = draft.keep.count
            return "Keeps \(TimeFormat.string(draft.keep.totalLength)) of \(TimeFormat.string(duration))" + (n > 1 ? " in \(n) sections, joined" : "")
        case .split:
            return "\(draft.markers.partCount) parts, saved into a folder"
        case .crop:
            let e = CropGeometry.engineRect(draft.crop, videoSize: draft.videoSize ?? .zero)
            return "\(Int(e[2])) × \(Int(e[3])) from \(Int(e[0])), \(Int(e[1]))"
        case .snapshot:
            let t = EditorDraft.clampSnapshot(currentTime, duration: duration)
            let size = draft.videoSize.map { " · \(Int($0.width)) × \(Int($0.height))" } ?? ""
            return "PNG of the frame at \(TimeFormat.string(t))" + size
        case .speed:
            return "\(SpeedFormat.label(draft.speed)) · new length \(TimeFormat.string(duration / max(0.01, draft.speed)))"
        case .bleep:
            let n = draft.bleeps.count
            let what = draft.tone ? "\(Int(draft.frequency.rounded())) Hz tone" : "silence"
            return "\(n) section\(n == 1 ? "" : "s") replaced with \(what)"
        }
    }

    // MARK: Test / render hook

    /// Puts the model into a loaded state without running ffmpeg or AVFoundation (renders, tests).
    func loadForPreview(details d: MediaDetails, filmstrip frames: [NSImage] = [], waveform levels: [Float] = [],
                        still: NSImage? = nil, preview state: PreviewState = .native) {
        apply(d)
        let times = PreviewGenerator.thumbnailTimes(count: frames.count, duration: d.duration)
        filmstrip = zip(times, frames).enumerated().map { FilmFrame(id: $0.offset, time: $0.element.0, image: $0.element.1) }
        waveform = levels
        stillFrame = still
        preview = state
    }

    /// Moves the playhead without touching a player (renders, tests).
    func setPlayheadForPreview(_ t: Double) {
        currentTime = min(max(0, t), duration)
    }
}

/// Keys handled by `MediaEditorModel.handle(_:)`.
public enum EditorKey: Equatable, Sendable {
    case space, left, right, shiftLeft, shiftRight, home, end, delete
    case character(Character)

    /// Maps a key-down event; nil for anything with ⌘/⌃/⌥ or keys the editor ignores.
    static func from(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> EditorKey? {
        let mods = modifiers.intersection([.command, .control, .option])
        guard mods.isEmpty else { return nil }
        let shift = modifiers.contains(.shift)
        switch keyCode {
        case 49: return .space
        case 123: return shift ? .shiftLeft : .left
        case 124: return shift ? .shiftRight : .right
        case 115: return .home
        case 119: return .end
        case 51, 117: return .delete
        default:
            guard !shift, let c = characters?.lowercased(), c.count == 1, let ch = c.first, ch.isLetter else { return nil }
            return .character(ch)
        }
    }
}

enum SpeedFormat {
    static func label(_ speed: Double) -> String {
        let r = (speed * 100).rounded() / 100
        return String(format: "%g×", locale: Locale(identifier: "en_US_POSIX"), r)
    }
}
