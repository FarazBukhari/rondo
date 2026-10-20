import Foundation
import RondoKit

extension FFmpegEngine {
    func convert(_ input: URL, to target: String, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let src = try format(of: input)
        guard let dst = FormatCatalog.format(id: target) else { throw EngineError.unsupported("format \(target)") }
        switch src.kind {
        case .video where target == "gif":
            return try await videoToGIF(input, job: job, ff: ff, ctx: ctx, progress: progress)
        case .video where VideoContainer.outputIDs.contains(target):
            return try await videoToVideo(input, to: dst, ff: ff, ctx: ctx, progress: progress)
        case .video where target == "mp3":
            return try await mediaToAudio(input, to: dst, ff: ff, ctx: ctx, progress: progress)
        case .audio where AudioTarget.forFormat(target) != nil:
            return try await mediaToAudio(input, to: dst, ff: ff, ctx: ctx, progress: progress)
        default:
            throw EngineError.unsupported("\(src.displayName) → \(dst.displayName)")
        }
    }

    // MARK: Video → video

    func videoToVideo(_ input: URL, to dst: Format, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        guard let container = VideoContainer.forFormat(dst.id) else { throw EngineError.unsupported(dst.displayName) }
        let info = try await ff.probe(input)
        try requireVideo(info, input)
        let out = ctx.tempFile(named: "out.\(dst.preferredExtension)")
        let plans = try container.plans(info: info, encoders: ff.encoders, allowVideoCopy: true, allowAudioCopy: true)
        try await ff.runFirstSuccessful(plans, build: { plan in
            ["-i", input.path] + videoMaps(info) + ["-map_metadata", "0"]
                + container.codecArgs(plan, info: info) + [out.path]
        }, duration: info.duration, progress: progress)
        return try commit(out, to: ctx.outputURL(for: input, ext: dst.preferredExtension), ctx: ctx)
    }

    // MARK: Video → GIF (palettegen two-pass)

    /// Options: `fps` (Double, default 12, 1…50), `width` (Int px, default 480, never upscales).
    func videoToGIF(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let info = try await ff.probe(input)
        try requireVideo(info, input)
        let fps = min(50, max(1, job.double("fps", default: 12)))
        let width = min(4096, max(16, job.int("width", default: 480)))
        let base = "fps=\(fmtRatio(fps)),scale='min(\(width),iw)':-1:flags=lanczos"
        let palette = ctx.tempFile(named: "palette.png")
        let out = ctx.tempFile(named: "out.gif")

        _ = try await ff.run(["-i", input.path, "-map", "0:V:0", "-vf", base + ",palettegen=stats_mode=diff",
                              "-frames:v", "1", "-update", "1", palette.path],
                             duration: info.duration, progress: progress.sub(0, 0.3))
        try Task.checkCancellation()
        _ = try await ff.run(["-i", input.path, "-i", palette.path,
                              "-filter_complex", "[0:V:0]\(base)[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
                              "-an", "-loop", "0", out.path],
                             duration: info.duration, progress: progress.sub(0.3, 0.7))
        return try commit(out, to: ctx.outputURL(for: input, ext: "gif"), ctx: ctx)
    }

    // MARK: Audio / video → audio

    func mediaToAudio(_ input: URL, to dst: Format, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        guard let target = AudioTarget.forFormat(dst.id) else { throw EngineError.unsupported(dst.displayName) }
        let info = try await ff.probe(input)
        _ = try requireAudio(info, input)
        let out = try await audioTranscode(input, info: info, target: target, ext: dst.preferredExtension,
                                           allowCopy: true, ff: ff, ctx: ctx, progress: progress)
        return try commit(out, to: ctx.outputURL(for: input, ext: dst.preferredExtension), ctx: ctx)
    }

    /// Transcodes the first audio stream to `target` into a temp file and returns it.
    /// `filterComplex` must expose an `[aout]` pad. Copy is tried first when allowed and no filters apply.
    func audioTranscode(
        _ input: URL,
        info: MediaInfo,
        target: AudioTarget,
        ext: String,
        allowCopy: Bool,
        encoder: AudioEncoder? = nil,
        bitrate: Int? = nil,
        filters: [String] = [],
        filterComplex: String? = nil,
        preInput: [String] = [],
        postInput: [String] = [],
        extraOutput: [String] = [],
        duration: Double? = nil,
        ff: FFmpeg,
        ctx: JobContext,
        progress: ProgressSlice
    ) async throws -> URL {
        let a = try requireAudio(info, input)
        guard let enc = encoder ?? target.encoder(ff.encoders, source: a, needsBitrateControl: bitrate != nil) else {
            throw EngineError.missingTool("an \(target.id.uppercased()) audio encoder in ffmpeg")
        }
        let out = ctx.tempFile(named: "out.\(ext)")
        var choices: [AudioChoice] = []
        if allowCopy, filters.isEmpty, filterComplex == nil, extraOutput.isEmpty, target.copyable.contains(a.codec) {
            choices.append(.copy)
        }
        choices.append(.encode(enc, bitrate: bitrate))
        if let fb = enc.fallback(ff.encoders) { choices.append(.encode(fb, bitrate: bitrate)) }
        try await ff.runFirstSuccessful(choices, build: { choice in
            var args = preInput + ["-i", input.path] + postInput
            var required: [String] = []
            if case .encode(let e, _) = choice { required = e.requiredFilters }
            if let filterComplex {
                let graph = required.isEmpty ? filterComplex : filterComplex + ";[aout]\(required.joined(separator: ","))[aenc]"
                args += ["-filter_complex", graph, "-map", required.isEmpty ? "[aout]" : "[aenc]"]
            } else {
                args += ["-map", "0:a:0"]
            }
            args += ["-vn", "-map_metadata", "0"]
            switch choice {
            case .copy:
                args += ["-c:a", "copy"]
            case .encode(let e, let b):
                let af = filterComplex == nil ? filters + e.requiredFilters : filters
                if !af.isEmpty { args += ["-af", af.joined(separator: ",")] }
                args += e.args(bitrate: b, source: a)
            case .none:
                break
            }
            return args + extraOutput + [out.path]
        }, duration: duration ?? info.duration, progress: progress)
        return out
    }
}
