import Foundation
import RondoKit

extension FFmpegEngine {
    // MARK: video.compress

    /// `percent` (0…100 size reduction, default 50) → single-pass ABR at that fraction of the
    /// source bitrate. `targetBytes` (> 0, wins over percent) → two-pass bitrate from duration
    /// minus the audio budget. Output keeps the input's container. Very low budgets downscale.
    func videoCompress(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let (srcFmt, container) = try videoContainer(of: input)
        let info = try await ff.probe(input)
        try requireVideo(info, input)
        guard let duration = info.duration, duration > 0 else {
            throw EngineError.invalidInput("\(input.lastPathComponent) has no known duration")
        }
        let srcBytes = Double(info.fileSize)
        let targetBytes = job.int("targetBytes", default: 0)
        let twoPass = targetBytes > 0
        let totalBits: Double
        if twoPass {
            guard Double(targetBytes) < srcBytes else {
                throw EngineError.invalidInput("\(input.lastPathComponent) is already smaller than the target size")
            }
            totalBits = Double(targetBytes) * 8 * 0.96   // container overhead
        } else {
            let p = min(95, max(1, job.double("percent", default: 50)))
            totalBits = srcBytes * 8 * (1 - p / 100) * 0.97
        }
        let totalRate = totalBits / duration

        var audioRate = 0
        if let a = info.audio {
            audioRate = min(128_000, max(48_000, a.bitRate ?? 128_000))
            if totalRate < 400_000 { audioRate = min(audioRate, 64_000) }
            if totalRate < 160_000 { audioRate = 32_000 }
        }
        let videoRate = max(30_000, Int(totalRate) - audioRate)

        // Downscale when the budget is far too small for the frame size (< 0.03 bit/pixel).
        var filters: [String] = []
        if let size = info.displaySize, size.height > 240 {
            let bpp = Double(videoRate) / (Double(size.width * size.height) * info.frameRate)
            if bpp < 0.03 {
                let scale = (bpp / 0.05).squareRoot()
                let h = max(240, Int(Double(size.height) * scale) / 2 * 2)
                filters.append("scale=-2:\(h)")
            }
        }

        guard let enc = container.videoEncoder(ff.encoders, preferSoftware: twoPass) else {
            throw EngineError.missingTool("a \(srcFmt.displayName) video encoder in ffmpeg")
        }
        let audioEnc = info.audio == nil ? nil : container.audioEncoder(ff.encoders, needsBitrateControl: true)
        if info.audio != nil && audioEnc == nil { throw EngineError.missingTool("a \(srcFmt.displayName) audio encoder in ffmpeg") }
        let out = ctx.tempFile(named: "out.\(srcFmt.preferredExtension)")
        let vf = ["-vf", (filters + [evenScale]).joined(separator: ",")]
        let audioArgs = audioEnc.map { $0.args(bitrate: audioRate, source: info.audio) } ?? ["-an"]

        if twoPass && enc.supportsTwoPass {
            let passlog = ctx.tempFile(named: "pass").path
            let videoArgs = vf + enc.args(rate: .bitrate(videoRate), info: info)
            _ = try await ff.run(["-i", input.path, "-map", "0:V:0"] + videoArgs
                                 + ["-pass", "1", "-passlogfile", passlog, "-an", "-f", "null", "-"],
                                 duration: duration, progress: progress.sub(0, 0.45))
            try Task.checkCancellation()
            _ = try await ff.run(["-i", input.path] + videoMaps(info) + videoArgs
                                 + ["-pass", "2", "-passlogfile", passlog] + audioArgs + container.mux + [out.path],
                                 duration: duration, progress: progress.sub(0.45, 0.55))
        } else {
            var encoders = [enc]
            if enc.isHardware, let sw = container.videoEncoders.first(where: { !$0.isHardware && ff.encoders.has($0.rawValue) }) {
                encoders.append(sw)
            }
            try await ff.runFirstSuccessful(encoders, build: { e in
                ["-i", input.path] + videoMaps(info) + vf + e.args(rate: .bitrate(videoRate), info: info)
                    + audioArgs + container.mux + [out.path]
            }, duration: duration, progress: progress)
        }
        return try commit(out, to: ctx.outputURL(for: input, ext: srcFmt.preferredExtension, suffix: "compressed"), ctx: ctx)
    }

    // MARK: video.trim

    /// `ranges` (seconds, required): kept spans; several ranges are joined in order.
    /// `precise` (Bool, default true): re-encode for frame accuracy; false = keyframe stream copy (single range only).
    func videoTrim(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let (srcFmt, container) = try videoContainer(of: input)
        let info = try await ff.probe(input)
        try requireVideo(info, input)
        let ranges = TimeRanges.normalize(job.ranges("ranges"), duration: info.duration)
        guard !ranges.isEmpty else { throw EngineError.invalidInput("Trim needs at least one time range inside the clip") }
        let out = ctx.tempFile(named: "out.\(srcFmt.preferredExtension)")
        if ranges.count == 1 {
            try await cutVideo(input, info: info, container: container, range: ranges[0],
                               precise: job.bool("precise", default: true), out: out, ff: ff, progress: progress)
        } else {
            try await joinRanges(input, info: info, container: container, ranges: ranges, out: out, ff: ff, progress: progress)
        }
        return try commit(out, to: ctx.outputURL(for: input, ext: srcFmt.preferredExtension, suffix: "trimmed"), ctx: ctx)
    }

    /// One contiguous span into `out` (re-encoded when `precise`, else stream copy with re-encode fallback).
    func cutVideo(_ input: URL, info: MediaInfo, container: VideoContainer, range: ClosedRange<Double>,
                  precise: Bool, out: URL, ff: FFmpeg, progress: ProgressSlice) async throws {
        let length = range.upperBound - range.lowerBound
        let plans = try container.plans(info: info, encoders: ff.encoders, allowVideoCopy: !precise, allowAudioCopy: !precise)
        try await ff.runFirstSuccessful(plans, build: { plan in
            var args = ["-ss", fmt(range.lowerBound), "-i", input.path, "-t", fmt(length)] + videoMaps(info) + ["-map_metadata", "0"]
            args += container.codecArgs(plan, info: info)
            if plan.video == .copy || plan.audio == .copy { args += ["-avoid_negative_ts", "make_zero"] }
            return args + [out.path]
        }, duration: length, progress: progress)
    }

    /// Several spans of one input, concatenated (always re-encoded).
    func joinRanges(_ input: URL, info: MediaInfo, container: VideoContainer, ranges: [ClosedRange<Double>],
                    out: URL, ff: FFmpeg, progress: ProgressSlice) async throws {
        let n = ranges.count
        let hasAudio = info.audio != nil
        var g = "[0:V:0]split=\(n)" + (0..<n).map { "[vs\($0)]" }.joined() + ";"
        if hasAudio { g += "[0:a:0]asplit=\(n)" + (0..<n).map { "[as\($0)]" }.joined() + ";" }
        var pads = ""
        for (i, r) in ranges.enumerated() {
            g += "[vs\(i)]trim=start=\(fmt(r.lowerBound)):end=\(fmt(r.upperBound)),setpts=PTS-STARTPTS[v\(i)];"
            pads += "[v\(i)]"
            if hasAudio {
                g += "[as\(i)]atrim=start=\(fmt(r.lowerBound)):end=\(fmt(r.upperBound)),asetpts=PTS-STARTPTS[a\(i)];"
                pads += "[a\(i)]"
            }
        }
        g += "\(pads)concat=n=\(n):v=1:a=\(hasAudio ? 1 : 0)[vc]" + (hasAudio ? "[aout]" : "") + ";[vc]\(evenScale)[vout]"
        let plans = try container.plans(info: info, encoders: ff.encoders, allowVideoCopy: false, allowAudioCopy: false)
        try await ff.runFirstSuccessful(plans, build: { plan in
            ["-i", input.path, "-filter_complex", g, "-map", "[vout]"] + (hasAudio ? ["-map", "[aout]"] : [])
                + ["-map_metadata", "0"] + container.codecArgs(plan, info: info, complexGraph: true) + [out.path]
        }, duration: TimeRanges.totalLength(ranges), progress: progress)
    }

    // MARK: video.crop

    /// `rect` (list x,y,w,h in displayed source pixels, top-left origin; required). Size rounds down to even.
    func videoCrop(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let (srcFmt, container) = try videoContainer(of: input)
        let info = try await ff.probe(input)
        try requireVideo(info, input)
        let rect = job.list("rect")
        guard rect.count == 4, let size = info.displaySize else {
            throw EngineError.invalidInput("Crop needs rect = x,y,w,h")
        }
        let x = min(max(0, Int(rect[0].rounded())), size.width - 2)
        let y = min(max(0, Int(rect[1].rounded())), size.height - 2)
        let w = min(Int(rect[2].rounded()), size.width - x) / 2 * 2
        let h = min(Int(rect[3].rounded()), size.height - y) / 2 * 2
        guard w >= 2, h >= 2 else { throw EngineError.invalidInput("Crop rectangle is empty") }
        let out = ctx.tempFile(named: "out.\(srcFmt.preferredExtension)")
        let plans = try container.plans(info: info, encoders: ff.encoders, allowVideoCopy: false, allowAudioCopy: true)
        try await ff.runFirstSuccessful(plans, build: { plan in
            ["-i", input.path] + videoMaps(info) + ["-map_metadata", "0"]
                + container.codecArgs(plan, info: info, videoFilters: ["crop=\(w):\(h):\(x):\(y)"]) + [out.path]
        }, duration: info.duration, progress: progress)
        return try commit(out, to: ctx.outputURL(for: input, ext: srcFmt.preferredExtension, suffix: "cropped"), ctx: ctx)
    }

    // MARK: video.speed

    /// `speed` (Double multiplier, default 2, 0.1…100): setpts for video, chained atempo for audio.
    func videoSpeed(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let (srcFmt, container) = try videoContainer(of: input)
        let speed = job.double("speed", default: 2)
        guard speed >= 0.1, speed <= 100, abs(speed - 1) > 0.001 else {
            throw EngineError.invalidInput("Speed must be between 0.1× and 100× and not 1×")
        }
        let info = try await ff.probe(input)
        try requireVideo(info, input)
        let out = ctx.tempFile(named: "out.\(srcFmt.preferredExtension)")
        let plans = try container.plans(info: info, encoders: ff.encoders, allowVideoCopy: false, allowAudioCopy: false)
        try await ff.runFirstSuccessful(plans, build: { plan in
            ["-i", input.path] + videoMaps(info) + ["-map_metadata", "0"]
                + container.codecArgs(plan, info: info,
                                      videoFilters: ["setpts=PTS/\(fmtRatio(speed))"],
                                      audioFilters: TimeRanges.atempoChain(speed)) + [out.path]
        }, duration: info.duration.map { $0 / speed }, progress: progress)
        let label = speed == speed.rounded() ? String(Int(speed)) : String(format: "%g", speed)
        return try commit(out, to: ctx.outputURL(for: input, ext: srcFmt.preferredExtension, suffix: "\(label)x"), ctx: ctx)
    }

    // MARK: video.split

    /// `ranges` (seconds) → one file per range; else `parts` (Int, default 2) equal parts.
    /// `precise` (Bool, default true). Output: folder "<name> (parts)" with "<name> 1.ext", …
    func videoSplit(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let (srcFmt, container) = try videoContainer(of: input)
        let info = try await ff.probe(input)
        try requireVideo(info, input)
        guard let duration = info.duration, duration > 0 else {
            throw EngineError.invalidInput("\(input.lastPathComponent) has no known duration")
        }
        var ranges = TimeRanges.clamp(job.ranges("ranges"), duration: duration)
        if ranges.isEmpty {
            let parts = job.int("parts", default: 2)
            guard parts >= 2, duration / Double(parts) >= 0.1 else { throw EngineError.invalidInput("Split needs ranges or parts ≥ 2") }
            ranges = TimeRanges.equalParts(parts, duration: duration)
        }
        let precise = job.bool("precise", default: true)
        let base = OutputNamer.baseName(of: input)
        let folder = ctx.tempFile(named: "\(base) (parts)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let width = String(ranges.count).count
        let slices = progress.split(ranges.map { $0.upperBound - $0.lowerBound })
        for (i, r) in ranges.enumerated() {
            try Task.checkCancellation()
            let number = String(repeating: "0", count: width - String(i + 1).count) + String(i + 1)
            let out = folder.appendingPathComponent("\(base) \(number).\(srcFmt.preferredExtension)")
            try await cutVideo(input, info: info, container: container, range: r, precise: precise, out: out, ff: ff, progress: slices[i])
        }
        let final = ctx.namer.folder(for: input, suffix: "parts", destination: ctx.destination)
        return try commit(folder, to: final, ctx: ctx)
    }

    // MARK: video.join

    /// Concatenates inputs in order into "<first> joined.<first ext>". Stream-copies with the concat
    /// demuxer when every input shares codecs/size/audio layout; otherwise re-encodes, letterboxing
    /// to the first clip's size and frame rate (silence fills clips without audio).
    func videoJoin(_ inputs: [URL], ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        guard inputs.count >= 2, let first = inputs.first else { throw EngineError.invalidInput("Join needs at least 2 videos") }
        let (srcFmt, container) = try videoContainer(of: first)
        let probeSlice = progress.sub(0, 0.05)
        var infos: [MediaInfo] = []
        for (i, url) in inputs.enumerated() {
            let info = try await ff.probe(url)
            try requireVideo(info, url)
            infos.append(info)
            probeSlice(Double(i + 1) / Double(inputs.count))
        }
        let total = infos.reduce(0) { $0 + ($1.duration ?? 0) }
        let work = progress.sub(0.05, 0.95)
        let out = ctx.tempFile(named: "out.\(srcFmt.preferredExtension)")

        if Self.canConcatCopy(infos, container: container) {
            let list = ctx.tempFile(named: "list.ffconcat")
            let body = "ffconcat version 1.0\n" + inputs.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'\n" }.joined()
            try body.write(to: list, atomically: true, encoding: .utf8)
            do {
                _ = try await ff.run(["-f", "concat", "-safe", "0", "-i", list.path] + videoMaps(infos[0])
                                     + ["-c", "copy"] + container.copyTagArgs(videoCodec: infos[0].video?.codec ?? "")
                                     + container.mux + [out.path],
                                     duration: total, progress: work)
                return try commit(out, to: ctx.outputURL(for: first, ext: srcFmt.preferredExtension, suffix: "joined"), ctx: ctx)
            } catch let e as EngineError {
                ctx.log("concat copy failed, re-encoding: \(e.localizedDescription)")
            }
        }

        // Re-encode through the concat filter.
        let size = infos[0].displaySize ?? (1280, 720)
        let W = max(2, size.width / 2 * 2), H = max(2, size.height / 2 * 2)
        let fps = fmtRatio(min(120, max(1, infos[0].frameRate)))
        let anyAudio = infos.contains { $0.audio != nil }
        var inputArgs: [String] = []
        for url in inputs { inputArgs += ["-i", url.path] }
        var g = "", pads = ""
        var extra = inputs.count
        for (i, info) in infos.enumerated() {
            g += "[\(i):V:0]scale=\(W):\(H):force_original_aspect_ratio=decrease,pad=\(W):\(H):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(fps),format=yuv420p[v\(i)];"
            pads += "[v\(i)]"
            if anyAudio {
                let src: String
                if info.audio != nil {
                    src = "[\(i):a:0]"
                } else {
                    inputArgs += ["-f", "lavfi", "-t", fmt(info.duration ?? 0.1), "-i", "anullsrc=r=48000:cl=stereo"]
                    src = "[\(extra):a:0]"
                    extra += 1
                }
                g += "\(src)aformat=sample_rates=48000:channel_layouts=stereo[a\(i)];"
                pads += "[a\(i)]"
            }
        }
        g += "\(pads)concat=n=\(inputs.count):v=1:a=\(anyAudio ? 1 : 0)[vout]" + (anyAudio ? "[aout]" : "")

        guard let ve = container.videoEncoder(ff.encoders) else { throw EngineError.missingTool("a \(srcFmt.displayName) video encoder in ffmpeg") }
        let ae = container.audioEncoder(ff.encoders)
        if anyAudio && ae == nil { throw EngineError.missingTool("a \(srcFmt.displayName) audio encoder in ffmpeg") }
        let audio: AudioChoice = anyAudio ? .encode(ae!, bitrate: nil) : .none
        var plans = [StreamPlan(video: .encode(ve, .auto), audio: audio)]
        if ve.isHardware, let sw = container.videoEncoders.first(where: { !$0.isHardware && ff.encoders.has($0.rawValue) }) {
            plans.append(StreamPlan(video: .encode(sw, .auto), audio: audio))
        }
        try await ff.runFirstSuccessful(plans, build: { plan in
            inputArgs + ["-filter_complex", g, "-map", "[vout]"] + (anyAudio ? ["-map", "[aout]"] : [])
                + container.codecArgs(plan, info: infos[0], complexGraph: true) + [out.path]
        }, duration: total, progress: work)
        return try commit(out, to: ctx.outputURL(for: first, ext: srcFmt.preferredExtension, suffix: "joined"), ctx: ctx)
    }

    static func canConcatCopy(_ infos: [MediaInfo], container: VideoContainer) -> Bool {
        guard let v0 = infos.first?.video, container.copyVideo.contains(v0.codec) else { return false }
        let a0 = infos[0].audio
        if let a0, !container.copyAudio.contains(a0.codec) { return false }
        return infos.allSatisfy { info in
            guard let v = info.video,
                  v.codec == v0.codec, v.width == v0.width, v.height == v0.height, v.pixFmt == v0.pixFmt
            else { return false }
            switch (info.audio, a0) {
            case (nil, nil): return true
            case (let a?, let b?): return a.codec == b.codec && a.sampleRate == b.sampleRate && a.channels == b.channels
            default: return false
            }
        }
    }

    // MARK: video.snapshot

    /// `time` (seconds, default: middle of the clip) → PNG "<name> snapshot.png".
    func videoSnapshot(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let info = try await ff.probe(input)
        try requireVideo(info, input)
        let duration = info.duration ?? 0
        let t = min(max(0, job.double("time", default: duration / 2)), max(0, duration - 0.05))
        let out = ctx.tempFile(named: "out.png")
        for seek in t > 0 ? [t, 0] : [0] {
            do {
                _ = try await ff.run(["-ss", fmt(seek), "-i", input.path, "-map", "0:V:0", "-frames:v", "1",
                                      "-update", "1", "-c:v", "png", out.path], duration: nil, progress: nil)
            } catch let e as EngineError where seek > 0 {
                ctx.log("snapshot at \(seek)s failed, retrying at 0: \(e.localizedDescription)")
            }
            if FileManager.default.fileExists(atPath: out.path) { break }
        }
        progress(1)
        return try commit(out, to: ctx.outputURL(for: input, ext: "png", suffix: "snapshot"), ctx: ctx)
    }

    // MARK: video.audio.extract

    /// `format`: "auto" (default — keep the original codec losslessly in its natural container,
    /// re-encode to AAC/M4A when there is none) or an audio format id (mp3, m4a, wav, flac, ogg, opus, aiff, wma).
    func videoExtractAudio(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let info = try await ff.probe(input)
        let a = try requireAudio(info, input)
        let requested = (job.string("format") ?? "auto").lowercased()
        let targetID: String
        if requested == "auto" {
            switch a.codec {
            case "aac", "alac": targetID = "m4a"
            case "mp3": targetID = "mp3"
            case "opus": targetID = "opus"
            case "vorbis": targetID = "ogg"
            case "flac": targetID = "flac"
            case "wmav1", "wmav2": targetID = "wma"
            case let c where c.hasPrefix("pcm_"): targetID = c.hasSuffix("be") ? "aiff" : "wav"
            default: targetID = "m4a"
            }
        } else {
            targetID = requested
        }
        guard let target = AudioTarget.forFormat(targetID), let dst = FormatCatalog.format(id: targetID) else {
            throw EngineError.invalidInput("unknown audio format \(requested)")
        }
        let out = try await audioTranscode(input, info: info, target: target, ext: dst.preferredExtension,
                                           allowCopy: true, ff: ff, ctx: ctx, progress: progress)
        return try commit(out, to: ctx.outputURL(for: input, ext: dst.preferredExtension, suffix: "audio"), ctx: ctx)
    }

    // MARK: media.metadata.strip

    /// Stream copy with global/stream metadata, chapters and cover art dropped → "<name> stripped.<ext>".
    func stripMetadata(_ input: URL, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let srcFmt = try format(of: input)
        guard srcFmt.kind == .video || srcFmt.kind == .audio else { throw EngineError.unsupported("\(srcFmt.displayName) metadata") }
        let info = try await ff.probe(input)
        let out = ctx.tempFile(named: "out.\(srcFmt.preferredExtension)")
        var args = ["-i", input.path, "-map", "0:V?", "-map", "0:a?", "-map", "0:s?",
                    "-map_metadata", "-1", "-map_metadata:s", "-1", "-map_chapters", "-1",
                    "-fflags", "+bitexact", "-c", "copy"]
        if ["mp4", "m4v", "mov", "m4a"].contains(srcFmt.id) { args += ["-movflags", "+faststart"] }
        if srcFmt.id == "mp3" { args += ["-id3v2_version", "0"] }
        _ = try await ff.run(args + [out.path], duration: info.duration, progress: progress)
        return try commit(out, to: ctx.outputURL(for: input, ext: srcFmt.preferredExtension, suffix: "stripped"), ctx: ctx)
    }
}
