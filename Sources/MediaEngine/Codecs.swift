import Foundation
import RondoKit

// MARK: - User quality settings

/// Quality settings the app passes from preferences. Absent keys → engine defaults.
///
/// Keys: `crf` (Int, x264 scale 0…51), `preset` (String, x264 preset name),
/// `audioBitrate` (Int, kbps) for lossy audio encoders.
struct Quality: Hashable, Sendable {
    var crf: Int?
    var preset: String?
    /// Bits per second.
    var audioBitrate: Int?

    static let x264Presets: Set<String> = ["ultrafast", "superfast", "veryfast", "faster", "fast",
                                           "medium", "slow", "slower", "veryslow", "placebo"]

    init(crf: Int? = nil, preset: String? = nil, audioBitrate: Int? = nil) {
        self.crf = crf.map { min(51, max(0, $0)) }
        self.preset = preset.map { $0.lowercased() }.flatMap { Self.x264Presets.contains($0) ? $0 : nil }
        self.audioBitrate = audioBitrate
    }

    init(_ job: JobSpec) {
        self.init(
            crf: job.options["crf"] == nil ? nil : job.int("crf", default: 23),
            preset: job.string("preset"),
            audioBitrate: job.options["audioBitrate"] == nil ? nil : min(512, max(8, job.int("audioBitrate", default: 192))) * 1000
        )
    }

    var isEmpty: Bool { crf == nil && preset == nil && audioBitrate == nil }

    /// Scales a bitrate chosen for CRF 23 the way x264 CRF behaves (+6 ≈ half the bits).
    func scaled(_ bitrate: Int) -> Int {
        guard let crf else { return bitrate }
        return max(32_000, Int(Double(bitrate) * pow(2, Double(23 - crf) / 6)))
    }

    /// libvpx `-cpu-used` for an x264 preset name (medium → 4, the default).
    var vpxCPUUsed: Int {
        switch preset {
        case "ultrafast", "superfast", "veryfast", "faster": 5
        case "slow": 2
        case "slower": 1
        case "veryslow", "placebo": 0
        default: 4
        }
    }
}

// MARK: - Video encoders

enum VideoRate: Sendable, Hashable {
    /// Sensible quality for a format conversion (honors `Quality.crf` when given).
    case auto
    /// Average bitrate in bits/s (compression).
    case bitrate(Int)
}

enum VideoEncoder: String, Sendable, Hashable, CaseIterable {
    case h264VT = "h264_videotoolbox"
    case x264 = "libx264"
    case vp9 = "libvpx-vp9"
    case vp8 = "libvpx"
    case mpeg4 = "mpeg4"
    case wmv2 = "wmv2"

    /// ffprobe `codec_name` of the result.
    var codecName: String {
        switch self {
        case .h264VT, .x264: "h264"
        case .vp9: "vp9"
        case .vp8: "vp8"
        case .mpeg4: "mpeg4"
        case .wmv2: "wmv2"
        }
    }

    var isHardware: Bool { self == .h264VT }
    var supportsTwoPass: Bool { !isHardware }

    /// CRF maps: x264 as given; VP9 = crf + 9 (23 → 32); VP8 = crf − 13 (23 → 10);
    /// MPEG-4 qscale = crf ÷ 7 (23 → 3); bitrate encoders (VideoToolbox, WMV2) scale their
    /// estimate by 2^((23 − crf) / 6). `preset` drives x264 and libvpx `-cpu-used`.
    func args(rate: VideoRate, info: MediaInfo, quality q: Quality = Quality()) -> [String] {
        let est = Self.estimateBitrate(info)
        let preset = q.preset ?? "medium"
        var a = ["-c:v", rawValue]
        switch (self, rate) {
        case (.h264VT, .auto):
            a += ["-b:v", "\(q.scaled(est))"]
        case (.h264VT, .bitrate(let b)):
            a += ["-b:v", "\(b)"]
        case (.x264, .auto):
            a += ["-preset", preset, "-crf", "\(q.crf ?? 20)"]
        case (.x264, .bitrate(let b)):
            a += ["-preset", preset, "-b:v", "\(b)", "-maxrate", "\(b * 3 / 2)", "-bufsize", "\(b * 2)"]
        case (.vp9, .auto):
            a += ["-crf", "\(q.crf.map { min(63, $0 + 9) } ?? 32)", "-b:v", "0"]
        case (.vp9, .bitrate(let b)):
            a += ["-b:v", "\(b)"]
        case (.vp8, .auto):
            a += ["-crf", "\(q.crf.map { min(63, max(4, $0 - 13)) } ?? 10)", "-b:v", "\(q.scaled(est * 6 / 5))"]
        case (.vp8, .bitrate(let b)):
            a += ["-b:v", "\(b)"]
        case (.mpeg4, .auto):
            a += ["-q:v", "\(q.crf.map { min(31, max(1, Int((Double($0) / 7).rounded()))) } ?? 3)"]
        case (.mpeg4, .bitrate(let b)):
            a += ["-b:v", "\(b)"]
        case (.wmv2, .auto):
            a += ["-b:v", "\(q.scaled(est * 3 / 2))"]
        case (.wmv2, .bitrate(let b)):
            a += ["-b:v", "\(b)"]
        }
        switch self {
        case .h264VT: a += ["-allow_sw", "1"]
        case .vp9: a += ["-deadline", "good", "-cpu-used", "\(q.vpxCPUUsed)", "-row-mt", "1"]
        case .vp8: a += ["-deadline", "good", "-cpu-used", "\(q.vpxCPUUsed)"]
        case .mpeg4: a += ["-vtag", "xvid"]
        default: break
        }
        return a + ["-pix_fmt", "yuv420p"]
    }

    /// Target bitrate for "same quality" re-encodes: ~0.1 bit/pixel, never above the source's own rate.
    static func estimateBitrate(_ info: MediaInfo) -> Int {
        let w = Double(info.video?.width ?? 1280), h = Double(info.video?.height ?? 720)
        let heuristic = Int(w * h * info.frameRate * 0.1)
        let src = info.videoBitRate.map { Int(Double($0) * 1.1) }
        return max(250_000, min(heuristic, src ?? heuristic))
    }
}

// MARK: - Audio encoders

enum AudioEncoder: Sendable, Hashable {
    case aac, alac, mp3, libopus, opusNative, libvorbis, vorbisNative, flac, wmav2
    case pcm(String)   // pcm_s16le, pcm_s24le, pcm_s16be, pcm_s24be

    var ffmpegName: String {
        switch self {
        case .aac: "aac"
        case .alac: "alac"
        case .mp3: "libmp3lame"
        case .libopus: "libopus"
        case .opusNative: "opus"
        case .libvorbis: "libvorbis"
        case .vorbisNative: "vorbis"
        case .flac: "flac"
        case .wmav2: "wmav2"
        case .pcm(let n): n
        }
    }

    var codecName: String {
        switch self {
        case .aac: "aac"
        case .alac: "alac"
        case .mp3: "mp3"
        case .libopus, .opusNative: "opus"
        case .libvorbis, .vorbisNative: "vorbis"
        case .flac: "flac"
        case .wmav2: "wmav2"
        case .pcm(let n): n
        }
    }

    var isLossless: Bool {
        switch self {
        case .flac, .pcm, .alac: true
        default: false
        }
    }

    /// Whether `-b:a` actually controls size (the native vorbis encoder ignores it).
    var honorsBitrate: Bool {
        switch self {
        case .flac, .pcm, .alac, .vorbisNative: false
        default: true
        }
    }

    /// Filters that must run right before this encoder. ffmpeg's experimental native Vorbis
    /// encoder aborts (`floor_encode` assertion) on some float input — e.g. decoded Vorbis or
    /// gain-changed audio; quantizing through s16 first avoids it.
    var requiredFilters: [String] {
        self == .vorbisNative ? ["aformat=sample_fmts=s16", "aformat=sample_fmts=fltp"] : []
    }

    /// Filter chain for a `-filter_complex` audio tail (`[x]<tail>[y]`); never empty.
    var graphTail: String {
        requiredFilters.isEmpty ? "anull" : requiredFilters.joined(separator: ",")
    }

    /// Encoder to retry with when this one fails (Opus-in-Ogg for the fragile native Vorbis).
    func fallback(_ enc: EncoderSet) -> AudioEncoder? {
        self == .vorbisNative && enc.has(AudioEncoder.libopus.ffmpegName) ? .libopus : nil
    }

    /// `bitrate` nil → encoder default quality.
    func args(bitrate: Int?, source: MediaInfo.Stream?) -> [String] {
        var a = ["-c:a", ffmpegName]
        let channels = source?.channels ?? 2
        switch self {
        case .aac:
            a += ["-b:a", "\(bitrate ?? 192_000)"]
        case .mp3:
            if let bitrate { a += ["-b:a", "\(bitrate)"] } else { a += ["-q:a", "2"] }
            if channels > 2 { a += ["-ac", "2"] }
        case .libopus:
            a += ["-b:a", "\(bitrate ?? 128_000)"]
            // Unconstrained VBR can overshoot an explicit size budget by ~2× on simple material.
            if bitrate != nil { a += ["-vbr", "constrained"] }
        case .opusNative:
            a += ["-strict", "-2", "-b:a", "\(bitrate ?? 128_000)", "-ac", "2", "-ar", "48000"]
        case .libvorbis:
            if let bitrate { a += ["-b:a", "\(bitrate)"] } else { a += ["-q:a", "5"] }
        case .vorbisNative:
            a += ["-strict", "-2", "-ac", "2"]
        case .flac, .alac:
            break
        case .wmav2:
            a += ["-b:a", "\(bitrate ?? 192_000)"]
            if channels > 2 { a += ["-ac", "2"] }
        case .pcm:
            break
        }
        return a
    }

    /// Source carries more than 16 bits → keep 24-bit PCM.
    static func wantsHighBitDepth(_ s: MediaInfo.Stream?) -> Bool {
        guard let s else { return false }
        if let b = s.bitsPerRawSample, b > 16 { return true }
        if s.codec.hasPrefix("pcm_s24") || s.codec.hasPrefix("pcm_s32") || s.codec.hasPrefix("pcm_f") { return true }
        return false
    }
}

// MARK: - Audio targets (audio → audio, extract, same-format audio tools)

struct AudioTarget: Sendable {
    let id: String              // Format.id
    let copyable: Set<String>   // source codec names that can be stream-copied
    let isLossy: Bool

    static let all: [AudioTarget] = [
        AudioTarget(id: "mp3", copyable: ["mp3"], isLossy: true),
        AudioTarget(id: "m4a", copyable: ["aac", "alac"], isLossy: true),
        AudioTarget(id: "wav", copyable: ["pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_u8"], isLossy: false),
        AudioTarget(id: "flac", copyable: ["flac"], isLossy: false),
        AudioTarget(id: "ogg", copyable: ["vorbis", "opus"], isLossy: true),
        AudioTarget(id: "opus", copyable: ["opus"], isLossy: true),
        AudioTarget(id: "aiff", copyable: ["pcm_s16be", "pcm_s24be"], isLossy: false),
        AudioTarget(id: "wma", copyable: ["wmav1", "wmav2"], isLossy: true),
    ]

    static func forFormat(_ id: String) -> AudioTarget? { all.first { $0.id == id } }

    /// Best available encoder. `needsBitrateControl` skips encoders that ignore `-b:a`.
    func encoder(_ enc: EncoderSet, source: MediaInfo.Stream?, needsBitrateControl: Bool = false) -> AudioEncoder? {
        let hi = AudioEncoder.wantsHighBitDepth(source)
        let prefs: [AudioEncoder]
        switch id {
        case "mp3": prefs = [.mp3]
        case "m4a": prefs = [.aac]
        case "wav": prefs = hi ? [.pcm("pcm_s24le"), .pcm("pcm_s16le")] : [.pcm("pcm_s16le")]
        case "flac": prefs = [.flac]
        case "ogg": prefs = needsBitrateControl ? [.libvorbis, .libopus] : [.libvorbis, .vorbisNative, .libopus]
        case "opus": prefs = [.libopus, .opusNative]
        case "aiff": prefs = hi ? [.pcm("pcm_s24be"), .pcm("pcm_s16be")] : [.pcm("pcm_s16be")]
        case "wma": prefs = [.wmav2]
        default: prefs = []
        }
        return prefs.first { enc.has($0.ffmpegName) }
    }

    func isAvailable(_ enc: EncoderSet) -> Bool { encoder(enc, source: nil) != nil }
}

// MARK: - Video containers

struct VideoContainer: Sendable {
    let id: String
    let copyVideo: Set<String>
    let copyAudio: Set<String>
    let videoEncoders: [VideoEncoder]
    let audioEncoders: [AudioEncoder]
    let mux: [String]

    static let all: [VideoContainer] = [
        VideoContainer(id: "mp4", copyVideo: ["h264", "hevc", "mpeg4", "av1"],
                       copyAudio: ["aac", "mp3", "alac", "ac3", "eac3"],
                       videoEncoders: [.h264VT, .x264], audioEncoders: [.aac], mux: ["-movflags", "+faststart"]),
        VideoContainer(id: "m4v", copyVideo: ["h264"],
                       copyAudio: ["aac", "alac"],
                       videoEncoders: [.h264VT, .x264], audioEncoders: [.aac], mux: ["-movflags", "+faststart"]),
        VideoContainer(id: "mov", copyVideo: ["h264", "hevc", "mpeg4", "prores", "mjpeg"],
                       copyAudio: ["aac", "alac", "mp3", "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be"],
                       videoEncoders: [.h264VT, .x264], audioEncoders: [.aac], mux: ["-movflags", "+faststart"]),
        VideoContainer(id: "mkv", copyVideo: ["h264", "hevc", "vp8", "vp9", "av1", "mpeg4", "mpeg2video", "mjpeg", "prores", "theora", "ffv1"],
                       copyAudio: ["aac", "mp3", "opus", "vorbis", "flac", "ac3", "eac3", "dts", "alac", "truehd", "pcm_s16le", "pcm_s24le", "pcm_f32le"],
                       videoEncoders: [.h264VT, .x264], audioEncoders: [.aac], mux: []),
        VideoContainer(id: "webm", copyVideo: ["vp8", "vp9", "av1"],
                       copyAudio: ["opus", "vorbis"],
                       videoEncoders: [.vp9, .vp8], audioEncoders: [.libopus, .libvorbis, .vorbisNative], mux: []),
        VideoContainer(id: "avi", copyVideo: ["mpeg4", "mjpeg", "msmpeg4v3"],
                       copyAudio: ["mp3", "ac3", "pcm_s16le"],
                       videoEncoders: [.mpeg4], audioEncoders: [.mp3], mux: []),
        VideoContainer(id: "wmv", copyVideo: ["wmv1", "wmv2", "wmv3", "vc1"],
                       copyAudio: ["wmav1", "wmav2", "wmapro"],
                       videoEncoders: [.wmv2], audioEncoders: [.wmav2], mux: []),
    ]

    /// Containers offered as conversion targets (m4v is input-only).
    static let outputIDs = ["mp4", "mov", "mkv", "webm", "avi", "wmv"]
    static let inputIDs = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v"]

    static func forFormat(_ id: String) -> VideoContainer? { all.first { $0.id == id } }

    func videoEncoder(_ enc: EncoderSet, preferSoftware: Bool = false) -> VideoEncoder? {
        let available = videoEncoders.filter { enc.has($0.rawValue) }
        if preferSoftware, let sw = available.first(where: { !$0.isHardware }) { return sw }
        return available.first
    }

    func audioEncoder(_ enc: EncoderSet, needsBitrateControl: Bool = false) -> AudioEncoder? {
        audioEncoders.first { enc.has($0.ffmpegName) && (!needsBitrateControl || $0.honorsBitrate) }
            ?? audioEncoders.first { enc.has($0.ffmpegName) }
    }

    func isAvailable(_ enc: EncoderSet) -> Bool {
        videoEncoder(enc) != nil && audioEncoder(enc) != nil
    }

    /// Extra flags when a stream is copied (HEVC needs the hvc1 tag for QuickTime).
    func copyTagArgs(videoCodec: String) -> [String] {
        (["mp4", "m4v", "mov"].contains(id) && videoCodec == "hevc") ? ["-tag:v", "hvc1"] : []
    }
}

// MARK: - Stream plans

enum VideoChoice: Hashable, Sendable {
    case copy
    case encode(VideoEncoder, VideoRate)
    case none
}

enum AudioChoice: Hashable, Sendable {
    case copy
    case encode(AudioEncoder, bitrate: Int?)
    case none
}

struct StreamPlan: Hashable, Sendable {
    var video: VideoChoice
    var audio: AudioChoice
}

extension VideoContainer {
    /// Ordered attempts: copy what the container accepts → full re-encode → software encoder.
    func plans(
        info: MediaInfo,
        encoders: EncoderSet,
        allowVideoCopy: Bool,
        allowAudioCopy: Bool,
        rate: VideoRate = .auto,
        audioBitrate: Int? = nil,
        includeVideo: Bool = true,
        preferSoftware: Bool = false
    ) throws -> [StreamPlan] {
        let hasAudio = info.audio != nil
        let ve = videoEncoder(encoders, preferSoftware: preferSoftware)
        let ae = audioEncoder(encoders, needsBitrateControl: audioBitrate != nil)
        if includeVideo && ve == nil { throw EngineError.missingTool("a \(id.uppercased()) video encoder in ffmpeg") }
        if hasAudio && ae == nil { throw EngineError.missingTool("a \(id.uppercased()) audio encoder in ffmpeg") }

        let encV: VideoChoice = includeVideo ? .encode(ve!, rate) : .none
        let encA: AudioChoice = hasAudio ? .encode(ae!, bitrate: audioBitrate) : .none

        var plans: [StreamPlan] = []
        let canCopyV = includeVideo && allowVideoCopy && copyVideo.contains(info.video?.codec ?? "")
        let canCopyA = hasAudio && allowAudioCopy && copyAudio.contains(info.audio?.codec ?? "")
        if canCopyV || canCopyA {
            plans.append(StreamPlan(video: canCopyV ? .copy : encV, audio: canCopyA ? .copy : encA))
        }
        plans.append(StreamPlan(video: encV, audio: encA))
        if case .encode(let v, let r) = encV, v.isHardware,
           let sw = videoEncoders.first(where: { !$0.isHardware && encoders.has($0.rawValue) }) {
            plans.append(StreamPlan(video: .encode(sw, r), audio: encA))
        }
        var seen = Set<StreamPlan>()
        return plans.filter { seen.insert($0).inserted }
    }

    /// Codec arguments for a plan. `videoFilters`/`audioFilters` apply only to encoded streams.
    /// `complexGraph` → filters live in `-filter_complex` (caller adds the even-size scale there).
    func codecArgs(_ plan: StreamPlan, info: MediaInfo, quality: Quality = Quality(), videoFilters: [String] = [], audioFilters: [String] = [], complexGraph: Bool = false) -> [String] {
        var a: [String] = []
        switch plan.video {
        case .copy:
            a += ["-c:v", "copy"] + copyTagArgs(videoCodec: info.video?.codec ?? "")
        case .encode(let enc, let rate):
            if !complexGraph { a += ["-vf", (videoFilters + [evenScale]).joined(separator: ",")] }
            a += enc.args(rate: rate, info: info, quality: quality)
        case .none:
            a += ["-vn"]
        }
        switch plan.audio {
        case .copy:
            a += ["-c:a", "copy"]
        case .encode(let enc, let bitrate):
            let af = audioFilters + enc.requiredFilters
            if !complexGraph && !af.isEmpty { a += ["-af", af.joined(separator: ",")] }
            a += enc.args(bitrate: bitrate, source: info.audio)
        case .none:
            a += ["-an"]
        }
        return a + mux
    }
}

/// yuv420p needs even dimensions.
let evenScale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
