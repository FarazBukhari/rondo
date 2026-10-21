import Foundation
import RondoKit

/// Same-format re-encode settings for an audio input.
struct SameFormat {
    let format: Format
    let target: AudioTarget
    let encoder: AudioEncoder
    /// Lossy encoders reuse the source bitrate so tools don't inflate files.
    let bitrate: Int?
}

extension FFmpegEngine {
    /// `job`'s `audioBitrate` (kbps), when given, overrides the source bitrate for lossy encoders.
    func sameFormat(_ input: URL, info: MediaInfo, ff: FFmpeg, job: JobSpec) throws -> SameFormat {
        let f = try format(of: input)
        guard let target = AudioTarget.forFormat(f.id) else { throw EngineError.unsupported("\(f.displayName) audio") }
        let a = info.audio
        var enc: AudioEncoder?
        if f.id == "m4a", a?.codec == "alac", ff.encoders.has("alac") { enc = .alac }
        enc = enc ?? target.encoder(ff.encoders, source: a)
        guard let enc else { throw EngineError.missingTool("an \(f.displayName) audio encoder in ffmpeg") }
        var bitrate: Int?
        if target.isLossy, enc.honorsBitrate {
            if let user = Quality(job).audioBitrate {
                bitrate = user
            } else if let src = a?.bitRate ?? info.totalBitRate {
                bitrate = min(320_000, max(64_000, src / 1000 * 1000))
            }
        }
        return SameFormat(format: f, target: target, encoder: enc, bitrate: bitrate)
    }

    // MARK: audio.compress

    /// `percent` (default 50) or `targetBytes` (wins when > 0) → target bitrate. With neither but an
    /// `audioBitrate` (kbps) quality setting, that bitrate is the target.
    /// Lossy inputs keep their format; lossless inputs (WAV, AIFF, FLAC, ALAC) become AAC .m4a.
    func audioCompress(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let info = try await ff.probe(input)
        let a = try requireAudio(info, input)
        guard let duration = info.duration, duration > 0 else {
            throw EngineError.invalidInput("\(input.lastPathComponent) has no known duration")
        }
        let f = try format(of: input)
        let srcRate = a.bitRate ?? info.totalBitRate ?? 0
        let targetBytes = job.int("targetBytes", default: 0)
        var rate: Int
        let userRate = Quality(job).audioBitrate
        if targetBytes > 0 {
            guard Int64(targetBytes) < info.fileSize else {
                throw EngineError.invalidInput("\(input.lastPathComponent) is already smaller than the target size")
            }
            rate = Int(Double(targetBytes) * 8 * 0.97 / duration)
        } else if job.options["percent"] == nil, let userRate {
            rate = userRate
        } else {
            let p = min(95, max(1, job.double("percent", default: 50)))
            rate = Int(Double(srcRate) * (1 - p / 100))
        }
        rate = min(320_000, max(24_000, rate / 1000 * 1000))

        var target = AudioTarget.forFormat(f.id)
        var ext = f.preferredExtension
        let keep = target?.isLossy == true && a.codec != "alac"
            && target?.encoder(ff.encoders, source: a, needsBitrateControl: true) != nil
        if !keep {
            target = AudioTarget.forFormat("m4a")
            ext = "m4a"
        } else if rate >= srcRate, srcRate > 0 {
            throw EngineError.invalidInput("\(input.lastPathComponent) is already at or below that bitrate")
        }
        guard let target else { throw EngineError.unsupported("\(f.displayName) compression") }
        let out = try await audioTranscode(input, info: info, target: target, ext: ext, allowCopy: false,
                                           bitrate: rate, strictBitrate: true, ff: ff, ctx: ctx, progress: progress)
        return try commit(out, to: ctx.outputURL(for: input, ext: ext, suffix: "compressed"), ctx: ctx)
    }

    // MARK: audio.normalize

    /// Two-pass EBU R128 `loudnorm`. `lufs` (default -16), `truePeak` (dBTP, default -1.5). Same format out.
    func audioNormalize(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let info = try await ff.probe(input)
        let a = try requireAudio(info, input)
        let same = try sameFormat(input, info: info, ff: ff, job: job)
        let I = min(-5, max(-70, job.double("lufs", default: -16)))
        let TP = min(0, max(-9, job.double("truePeak", default: -1.5)))
        let base = "loudnorm=I=\(fmtRatio(I)):TP=\(fmtRatio(TP)):LRA=11"

        let pass1 = try await ff.run(["-i", input.path, "-map", "0:a:0", "-vn", "-af", base + ":print_format=json", "-f", "null", "-"],
                                     duration: info.duration, progress: progress.sub(0, 0.45), loglevel: "info")
        let m = try Self.parseLoudnorm(pass1.stderrTail)
        guard let inI = Double(m["input_i"] ?? ""), inI.isFinite else {
            throw EngineError.invalidInput("\(input.lastPathComponent) is silent; nothing to normalize")
        }
        let filter = base + ":measured_I=\(m["input_i"]!):measured_TP=\(m["input_tp"] ?? "0"):measured_LRA=\(m["input_lra"] ?? "0")"
            + ":measured_thresh=\(m["input_thresh"] ?? "-70"):offset=\(m["target_offset"] ?? "0"):linear=true"
        // loudnorm resamples to 192 kHz internally; write the source rate back (Opus only takes 48 kHz).
        let rate = same.target.id == "opus" ? 48_000 : (a.sampleRate ?? 48_000)
        try Task.checkCancellation()
        let out = try await audioTranscode(input, info: info, target: same.target, ext: same.format.preferredExtension,
                                           allowCopy: false, encoder: same.encoder, bitrate: same.bitrate,
                                           filters: [filter], extraOutput: ["-ar", "\(rate)"],
                                           ff: ff, ctx: ctx, progress: progress.sub(0.45, 0.55))
        return try commit(out, to: ctx.outputURL(for: input, ext: same.format.preferredExtension, suffix: "normalized"), ctx: ctx)
    }

    /// Extracts the loudnorm JSON block (`"input_i" : "-21.75"`, …) from ffmpeg's stderr.
    static func parseLoudnorm(_ stderr: String) throws -> [String: String] {
        guard let open = stderr.range(of: "{", options: .backwards),
              let close = stderr.range(of: "}", options: .backwards, range: open.upperBound..<stderr.endIndex),
              let obj = try? JSONSerialization.jsonObject(with: Data(stderr[open.lowerBound..<close.upperBound].utf8)) as? [String: Any]
        else {
            throw EngineError.failed("loudnorm analysis produced no measurements")
        }
        return obj.compactMapValues { v in (v as? String) ?? (v as? NSNumber)?.stringValue }
    }

    // MARK: audio.trim

    /// `ranges` (seconds, required): kept spans, joined in order. Same format out.
    func audioTrim(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let info = try await ff.probe(input)
        _ = try requireAudio(info, input)
        let same = try sameFormat(input, info: info, ff: ff, job: job)
        let ranges = TimeRanges.normalize(job.ranges("ranges"), duration: info.duration)
        guard !ranges.isEmpty else { throw EngineError.invalidInput("Trim needs at least one time range inside the clip") }
        let ext = same.format.preferredExtension
        let out: URL
        if ranges.count == 1 {
            let r = ranges[0]
            out = try await audioTranscode(input, info: info, target: same.target, ext: ext, allowCopy: false,
                                           encoder: same.encoder, bitrate: same.bitrate,
                                           preInput: ["-ss", fmt(r.lowerBound)], postInput: ["-t", fmt(r.upperBound - r.lowerBound)],
                                           duration: r.upperBound - r.lowerBound, ff: ff, ctx: ctx, progress: progress)
        } else {
            let n = ranges.count
            var g = "[0:a:0]asplit=\(n)" + (0..<n).map { "[s\($0)]" }.joined() + ";"
            for (i, r) in ranges.enumerated() {
                g += "[s\(i)]atrim=start=\(fmt(r.lowerBound)):end=\(fmt(r.upperBound)),asetpts=PTS-STARTPTS[p\(i)];"
            }
            g += (0..<n).map { "[p\($0)]" }.joined() + "concat=n=\(n):v=0:a=1[aout]"
            out = try await audioTranscode(input, info: info, target: same.target, ext: ext, allowCopy: false,
                                           encoder: same.encoder, bitrate: same.bitrate, filterComplex: g,
                                           duration: TimeRanges.totalLength(ranges), ff: ff, ctx: ctx, progress: progress)
        }
        return try commit(out, to: ctx.outputURL(for: input, ext: ext, suffix: "trimmed"), ctx: ctx)
    }

    // MARK: audio.bleep

    /// `ranges` (seconds, required): muted spans. `tone` (Bool, default true) overlays a sine at
    /// `frequency` (Hz, default 1000) inside them; false = silence only. Same format out.
    func audioBleep(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let info = try await ff.probe(input)
        let a = try requireAudio(info, input)
        let same = try sameFormat(input, info: info, ff: ff, job: job)
        let ranges = TimeRanges.normalize(job.ranges("ranges"), duration: info.duration)
        guard !ranges.isEmpty else { throw EngineError.invalidInput("Bleep needs at least one time range inside the clip") }
        let expr = TimeRanges.betweenExpr(ranges)
        let ext = same.format.preferredExtension
        let out: URL
        if job.bool("tone", default: true) {
            let freq = min(20_000, max(20, job.double("frequency", default: 1000)))
            let sr = a.sampleRate ?? 48_000
            let dur = info.duration ?? (ranges.last!.upperBound)
            // Small frames so the mute/tone edges land within ~6 ms (enable= is evaluated per frame).
            let g = "[0:a:0]asetnsamples=n=256:p=0,volume=0:enable='\(expr)'[m];"
                + "sine=frequency=\(fmtRatio(freq)):sample_rate=\(sr):duration=\(fmt(dur)):samples_per_frame=256,"
                + "volume=0:enable='not(\(expr))'[b];"
                + "[m][b]amix=inputs=2:duration=first:normalize=0[aout]"
            out = try await audioTranscode(input, info: info, target: same.target, ext: ext, allowCopy: false,
                                           encoder: same.encoder, bitrate: same.bitrate, filterComplex: g,
                                           ff: ff, ctx: ctx, progress: progress)
        } else {
            out = try await audioTranscode(input, info: info, target: same.target, ext: ext, allowCopy: false,
                                           encoder: same.encoder, bitrate: same.bitrate,
                                           filters: ["asetnsamples=n=256:p=0", "volume=0:enable='\(expr)'"],
                                           ff: ff, ctx: ctx, progress: progress)
        }
        return try commit(out, to: ctx.outputURL(for: input, ext: ext, suffix: "bleeped"), ctx: ctx)
    }

    // MARK: audio.channels

    /// `channels`: "mono" (downmix, default) | "stereo" (upmix/downmix to 2) | "swap" (L↔R, stereo input only).
    func audioChannels(_ input: URL, job: JobSpec, ff: FFmpeg, ctx: JobContext, progress: ProgressSlice) async throws -> URL {
        let info = try await ff.probe(input)
        let a = try requireAudio(info, input)
        let same = try sameFormat(input, info: info, ff: ff, job: job)
        let mode = (job.string("channels") ?? "mono").lowercased()
        var filters: [String] = []
        var extra: [String] = []
        let suffix: String
        switch mode {
        case "mono", "1":
            extra = ["-ac", "1"]
            suffix = "mono"
        case "stereo", "2":
            extra = ["-ac", "2"]
            suffix = "stereo"
        case "swap":
            guard a.channels == 2 else { throw EngineError.invalidInput("Swapping channels needs a stereo file") }
            filters = ["pan=stereo|c0=c1|c1=c0"]
            suffix = "swapped"
        default:
            throw EngineError.invalidInput("channels must be mono, stereo or swap")
        }
        var encoder = same.encoder
        var bitrate = same.bitrate
        if encoder == .vorbisNative || encoder == .opusNative, suffix == "mono" {
            // The experimental native encoders are stereo-only; Opus-in-Ogg keeps a true mono file.
            guard ff.encoders.has(AudioEncoder.libopus.ffmpegName) else {
                throw EngineError.missingTool("a mono-capable \(same.format.displayName) encoder (libopus) in ffmpeg")
            }
            encoder = .libopus
            bitrate = 96_000
        }
        let ext = same.format.preferredExtension
        let out = try await audioTranscode(input, info: info, target: same.target, ext: ext, allowCopy: false,
                                           encoder: encoder, bitrate: bitrate, filters: filters,
                                           extraOutput: extra, ff: ff, ctx: ctx, progress: progress)
        return try commit(out, to: ctx.outputURL(for: input, ext: ext, suffix: suffix), ctx: ctx)
    }
}
