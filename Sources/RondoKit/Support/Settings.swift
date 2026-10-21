import Foundation

public enum ModifierKey: String, Codable, Sendable, CaseIterable {
    case shift, option, control, command

    public var symbol: String {
        switch self {
        case .shift: "⇧"
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        }
    }
}

/// When a modifier opens a wheel during a file drag.
public enum WheelTrigger: String, Codable, Sendable, CaseIterable {
    /// On key-down: fastest. Holding ⌥ to force a Finder copy also opens a wheel.
    case press
    /// On a quick press-and-release: holding a modifier (e.g. ⌥ for Finder copy) never opens a wheel.
    case tap
}

public struct Hotkey: Codable, Equatable, Sendable {
    /// Carbon virtual key code (49 = Space).
    public var keyCode: UInt32
    public var modifiers: [ModifierKey]

    public init(keyCode: UInt32, modifiers: [ModifierKey]) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// User preferences, persisted as JSON in UserDefaults. Missing/unknown keys fall back to
/// defaults, so adding fields never wipes a user's settings.
public struct Settings: Codable, Equatable, Sendable {
    public var convertModifier: ModifierKey = .shift
    public var toolsModifier: ModifierKey = .option
    public var actionsModifier: ModifierKey = .control
    public var wheelTrigger: WheelTrigger = .press

    public var imageQuality: Double = 0.85        // 0...1 for JPEG/HEIC/WebP/AVIF
    public var videoCRF: Int = 23                 // x264-style CRF
    public var videoPreset: String = "medium"
    public var audioBitrateKbps: Int = 192
    public var pdfRenderDPI: Int = 300

    public var destination: Destination = .besideOriginal
    public var revealInFinder: Bool = true
    public var hotkey: Hotkey? = Hotkey(keyCode: 49, modifiers: [.control, .option])
    public var launchAtLogin: Bool = false
    /// Tool name → absolute path override (e.g. "ffmpeg": "/custom/ffmpeg").
    public var toolPaths: [String: String] = [:]

    public init() {}

    public static let defaultsKey = "settings.v1"

    public static func load(from defaults: UserDefaults = .standard) -> Settings {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Wheel opened by a modifier, if any.
    public func wheel(for modifier: ModifierKey) -> WheelKind? {
        if modifier == convertModifier { return .convert }
        if modifier == toolsModifier { return .tools }
        if modifier == actionsModifier { return .actions }
        return nil
    }

    // MARK: Lenient decoding

    private enum CodingKeys: String, CodingKey {
        case convertModifier, toolsModifier, actionsModifier, wheelTrigger
        case imageQuality, videoCRF, videoPreset, audioBitrateKbps, pdfRenderDPI
        case destination, revealInFinder, hotkey, launchAtLogin, toolPaths
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? current
        }
        convertModifier = get(.convertModifier, convertModifier)
        toolsModifier = get(.toolsModifier, toolsModifier)
        actionsModifier = get(.actionsModifier, actionsModifier)
        wheelTrigger = get(.wheelTrigger, wheelTrigger)
        imageQuality = get(.imageQuality, imageQuality)
        videoCRF = get(.videoCRF, videoCRF)
        videoPreset = get(.videoPreset, videoPreset)
        audioBitrateKbps = get(.audioBitrateKbps, audioBitrateKbps)
        pdfRenderDPI = get(.pdfRenderDPI, pdfRenderDPI)
        destination = get(.destination, destination)
        revealInFinder = get(.revealInFinder, revealInFinder)
        if c.contains(.hotkey) { hotkey = try? c.decodeIfPresent(Hotkey.self, forKey: .hotkey) }
        launchAtLogin = get(.launchAtLogin, launchAtLogin)
        toolPaths = get(.toolPaths, toolPaths)
    }

    /// Explicit so a cleared hotkey is written as `null` (synthesized encoding omits nil,
    /// which would bring the default hotkey back on next load).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(convertModifier, forKey: .convertModifier)
        try c.encode(toolsModifier, forKey: .toolsModifier)
        try c.encode(actionsModifier, forKey: .actionsModifier)
        try c.encode(wheelTrigger, forKey: .wheelTrigger)
        try c.encode(imageQuality, forKey: .imageQuality)
        try c.encode(videoCRF, forKey: .videoCRF)
        try c.encode(videoPreset, forKey: .videoPreset)
        try c.encode(audioBitrateKbps, forKey: .audioBitrateKbps)
        try c.encode(pdfRenderDPI, forKey: .pdfRenderDPI)
        try c.encode(destination, forKey: .destination)
        try c.encode(revealInFinder, forKey: .revealInFinder)
        try c.encode(hotkey, forKey: .hotkey)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(toolPaths, forKey: .toolPaths)
    }
}
