import Foundation
import RondoKit

/// Video + audio conversions and tools, backed by ffmpeg/ffprobe.
///
/// Capabilities are gated on ffmpeg + ffprobe presence and on the encoders ffmpeg lists
/// (`ffmpeg -encoders`, cached per binary path). See `ToolIDs` for every tool and option key.
public struct FFmpegEngine: Engine {
    public let id = "media"
    let locator: ToolLocator

    public init(tools: ToolLocator = ToolLocator()) {
        self.locator = tools
    }

    public enum ToolIDs {
        public static let videoCompress: ToolID = "video.compress"
        public static let videoTrim: ToolID = "video.trim"
        public static let videoCrop: ToolID = "video.crop"
        public static let videoSpeed: ToolID = "video.speed"
        public static let videoSplit: ToolID = "video.split"
        public static let videoJoin: ToolID = "video.join"
        public static let videoSnapshot: ToolID = "video.snapshot"
        public static let videoExtractAudio: ToolID = "video.audio.extract"
        public static let stripMetadata: ToolID = "media.metadata.strip"
        public static let audioCompress: ToolID = "audio.compress"
        public static let audioNormalize: ToolID = "audio.normalize"
        public static let audioTrim: ToolID = "audio.trim"
        public static let audioBleep: ToolID = "audio.bleep"
        public static let audioChannels: ToolID = "audio.channels"
    }

    static let audioInputIDs = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]

    // MARK: Capabilities

    /// Encoders of the locator's ffmpeg, or nil when ffmpeg/ffprobe are missing.
    func availableEncoders() -> EncoderSet? {
        guard let ff = locator.url(for: "ffmpeg"), locator.has("ffprobe") else { return nil }
        return EncoderSet(EncoderProbe.encodersBlocking(ffmpeg: ff))
    }

    public func conversions() -> [ConversionDescriptor] {
        guard let enc = availableEncoders() else { return [] }
        var videoTargets = VideoContainer.outputIDs.filter { VideoContainer.forFormat($0)?.isAvailable(enc) == true }
        if enc.has("gif") && enc.has("png") { videoTargets.append("gif") }
        if AudioTarget.forFormat("mp3")?.isAvailable(enc) == true { videoTargets.append("mp3") }
        let audioTargets = AudioTarget.all.filter { $0.isAvailable(enc) }.map(\.id)
        return RondoKit.conversions(from: VideoContainer.inputIDs, to: videoTargets)
            + RondoKit.conversions(from: Self.audioInputIDs, to: audioTargets)
    }

    public func tools() -> [ToolDescriptor] {
        guard let enc = availableEncoders() else { return [] }
        let h264 = enc.has(VideoEncoder.h264VT.rawValue) || enc.has(VideoEncoder.x264.rawValue)
        let anyAudio = AudioTarget.all.contains { $0.isAvailable(enc) }
        return Self.descriptors.filter { d in
            switch d.id {
            case ToolIDs.videoSnapshot: return enc.has("png")
            case ToolIDs.videoExtractAudio: return enc.has("aac")
            case ToolIDs.stripMetadata: return true
            case _ where d.id.rawValue.hasPrefix("video."): return h264
            default: return anyAudio
            }
        }
    }

    static let descriptors: [ToolDescriptor] = [
        ToolDescriptor(
            id: ToolIDs.videoCompress, title: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
            accepts: [.video], multiInput: .each,
            options: [
                OptionSpec(key: "percent", title: "Reduce size by", control: .slider(min: 10, max: 90, step: 5), defaultValue: .double(50)),
                OptionSpec(key: "targetBytes", title: "Target size", control: .bytes, defaultValue: nil),
            ]),
        ToolDescriptor(
            id: ToolIDs.videoTrim, title: "Trim", symbol: "scissors",
            accepts: [.video], multiInput: .each, needsUI: true,
            options: [
                OptionSpec(key: "ranges", title: "Keep", control: .ranges, defaultValue: nil),
                OptionSpec(key: "precise", title: "Frame-accurate (re-encode)", control: .toggle, defaultValue: .bool(true)),
            ]),
        ToolDescriptor(
            id: ToolIDs.videoCrop, title: "Crop", symbol: "crop",
            accepts: [.video], multiInput: .each, needsUI: true,
            options: [
                OptionSpec(key: "rect", title: "Crop rectangle (x, y, w, h)", control: .rect, defaultValue: nil),
            ]),
        ToolDescriptor(
            id: ToolIDs.videoSpeed, title: "Change Speed", symbol: "speedometer",
            accepts: [.video], multiInput: .each,
            options: [
                OptionSpec(key: "speed", title: "Speed", control: .slider(min: 0.25, max: 4, step: 0.25), defaultValue: .double(2)),
            ]),
        ToolDescriptor(
            id: ToolIDs.videoSplit, title: "Split", symbol: "square.split.2x1",
            accepts: [.video], multiInput: .each, needsUI: true,
            options: [
                OptionSpec(key: "ranges", title: "Parts", control: .ranges, defaultValue: nil),
                OptionSpec(key: "parts", title: "Equal parts", control: .integer(min: 2, max: 100), defaultValue: .int(2)),
                OptionSpec(key: "precise", title: "Frame-accurate (re-encode)", control: .toggle, defaultValue: .bool(true)),
            ]),
        ToolDescriptor(
            id: ToolIDs.videoJoin, title: "Join", symbol: "rectangle.stack.badge.plus",
            accepts: [.video], multiInput: .combine(minimum: 2)),
        ToolDescriptor(
            id: ToolIDs.videoSnapshot, title: "Snapshot", symbol: "camera",
            accepts: [.video], multiInput: .each, needsUI: true,
            options: [
                OptionSpec(key: "time", title: "Time (s)", control: .slider(min: 0, max: 86_400, step: 0.04), defaultValue: nil),
            ]),
        ToolDescriptor(
            id: ToolIDs.videoExtractAudio, title: "Extract Audio", symbol: "waveform",
            accepts: [.video], multiInput: .each,
            options: [
                OptionSpec(key: "format", title: "Format", control: .choice(["auto", "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]), defaultValue: .string("auto")),
            ]),
        ToolDescriptor(
            id: ToolIDs.stripMetadata, title: "Remove Metadata", symbol: "tag.slash",
            accepts: [.video, .audio], multiInput: .each),
        ToolDescriptor(
            id: ToolIDs.audioCompress, title: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
            accepts: [.audio], multiInput: .each,
            options: [
                OptionSpec(key: "percent", title: "Reduce size by", control: .slider(min: 10, max: 90, step: 5), defaultValue: .double(50)),
                OptionSpec(key: "targetBytes", title: "Target size", control: .bytes, defaultValue: nil),
            ]),
        ToolDescriptor(
            id: ToolIDs.audioNormalize, title: "Normalize", symbol: "speaker.wave.3",
            accepts: [.audio], multiInput: .each,
            options: [
                OptionSpec(key: "lufs", title: "Loudness (LUFS)", control: .slider(min: -30, max: -5, step: 1), defaultValue: .double(-16)),
                OptionSpec(key: "truePeak", title: "True peak (dBTP)", control: .slider(min: -9, max: 0, step: 0.5), defaultValue: .double(-1.5)),
            ]),
        ToolDescriptor(
            id: ToolIDs.audioTrim, title: "Trim", symbol: "scissors",
            accepts: [.audio], multiInput: .each, needsUI: true,
            options: [
                OptionSpec(key: "ranges", title: "Keep", control: .ranges, defaultValue: nil),
            ]),
        ToolDescriptor(
            id: ToolIDs.audioBleep, title: "Bleep", symbol: "speaker.slash",
            accepts: [.audio], multiInput: .each, needsUI: true,
            options: [
                OptionSpec(key: "ranges", title: "Bleep", control: .ranges, defaultValue: nil),
                OptionSpec(key: "frequency", title: "Tone (Hz)", control: .slider(min: 200, max: 4000, step: 50), defaultValue: .double(1000)),
                OptionSpec(key: "tone", title: "Play tone (off = silence)", control: .toggle, defaultValue: .bool(true)),
            ]),
        ToolDescriptor(
            id: ToolIDs.audioChannels, title: "Change Channels", symbol: "hifispeaker.2",
            accepts: [.audio], multiInput: .each,
            options: [
                OptionSpec(key: "channels", title: "Channels", control: .choice(["mono", "stereo", "swap"]), defaultValue: .string("mono")),
            ]),
    ]

    // MARK: Run

    public func run(_ job: JobSpec, context: JobContext) async throws -> [URL] {
        guard !job.inputs.isEmpty else { throw EngineError.invalidInput("no input files") }
        let sink = ProgressSink(context.progress)
        sink.send(0)
        let ff = try await FFmpeg.make(tools: context.tools, log: context.log)
        let outputs: [URL]
        switch job.operation {
        case .convert(let target):
            outputs = try await eachInput(job.inputs, progress: sink.root) { input, slice in
                [try await convert(input, to: target, job: job, ff: ff, ctx: context, progress: slice)]
            }
        case .tool(let tool):
            outputs = try await runTool(tool, job: job, ff: ff, ctx: context, progress: sink.root)
        }
        sink.send(1)
        return outputs
    }

    func runTool(_ tool: ToolID, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> [URL] {
        if tool == ToolIDs.videoJoin {
            return [try await videoJoin(job.inputs, ff: ff, ctx: ctx, progress: progress)]
        }
        return try await eachInput(job.inputs, progress: progress) { input, slice in
            switch tool {
            case ToolIDs.videoCompress: [try await videoCompress(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.videoTrim: [try await videoTrim(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.videoCrop: [try await videoCrop(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.videoSpeed: [try await videoSpeed(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.videoSplit: [try await videoSplit(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.videoSnapshot: [try await videoSnapshot(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.videoExtractAudio: [try await videoExtractAudio(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.stripMetadata: [try await stripMetadata(input, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.audioCompress: [try await audioCompress(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.audioNormalize: [try await audioNormalize(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.audioTrim: [try await audioTrim(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.audioBleep: [try await audioBleep(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            case ToolIDs.audioChannels: [try await audioChannels(input, job: job, ff: ff, ctx: ctx, progress: slice)]
            default: throw EngineError.unsupported("tool \(tool.rawValue)")
            }
        }
    }

    /// Runs `body` per input with progress split evenly; the queue normally sends one input per job.
    func eachInput(_ inputs: [URL], progress: ProgressSlice, _ body: (URL, ProgressSlice) async throws -> [URL]) async throws -> [URL] {
        let slices = progress.split(inputs.map { _ in 1 })
        var out: [URL] = []
        for (input, slice) in zip(inputs, slices) {
            try Task.checkCancellation()
            out += try await body(input, slice)
        }
        return out
    }

    // MARK: Shared helpers

    /// Moves a finished temp output into place. Checks cancellation first so a cancelled job
    /// never leaves a file beside the original.
    func commit(_ temp: URL, to final: URL, ctx: JobContext) throws -> URL {
        try Task.checkCancellation()
        let attrs = try? FileManager.default.attributesOfItem(atPath: temp.path)
        let isDir = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        guard attrs != nil, isDir || ((attrs?[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
            throw EngineError.failed("ffmpeg produced no output")
        }
        return try ctx.namer.commit(temp, to: final)
    }

    func format(of input: URL) throws -> Format {
        guard let f = FormatCatalog.format(for: input) else {
            throw EngineError.invalidInput("unrecognized file type: \(input.lastPathComponent)")
        }
        return f
    }

    func videoContainer(of input: URL) throws -> (Format, VideoContainer) {
        let f = try format(of: input)
        guard let c = VideoContainer.forFormat(f.id) else { throw EngineError.unsupported("\(f.displayName) video") }
        return (f, c)
    }

    func requireVideo(_ info: MediaInfo, _ input: URL) throws {
        guard info.video != nil else { throw EngineError.invalidInput("\(input.lastPathComponent) has no video track") }
    }

    func requireAudio(_ info: MediaInfo, _ input: URL) throws -> MediaInfo.Stream {
        guard let a = info.audio else { throw EngineError.invalidInput("\(input.lastPathComponent) has no audio track") }
        return a
    }

    /// `-map` arguments for the first real video stream and (if present) the first audio stream.
    func videoMaps(_ info: MediaInfo) -> [String] {
        ["-map", "0:V:0"] + (info.audio != nil ? ["-map", "0:a:0"] : [])
    }
}
