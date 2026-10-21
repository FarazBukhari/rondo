import CoreGraphics
import Foundation
import RondoKit

// MARK: - Color

/// sRGB color with hex round-tripping in the engine's `#RRGGBB(AA)` format.
public struct RGBAColor: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// "#RGB", "#RRGGBB", "#RRGGBBAA" (leading # optional).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let alpha = s.count == 8
        r = Double((v >> (alpha ? 24 : 16)) & 0xFF) / 255
        g = Double((v >> (alpha ? 16 : 8)) & 0xFF) / 255
        b = Double((v >> (alpha ? 8 : 0)) & 0xFF) / 255
        a = alpha ? Double(v & 0xFF) / 255 : 1
    }

    public init?(cgColor: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 3 else { return nil }
        self.init(r: Double(comps[0]), g: Double(comps[1]), b: Double(comps[2]), a: Double(comps.count > 3 ? comps[3] : 1))
    }

    private static func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }

    /// `#RRGGBB`, or `#RRGGBBAA` when not fully opaque.
    public var hex: String {
        let rgb = String(format: "#%02X%02X%02X", Self.byte(r), Self.byte(g), Self.byte(b))
        return Self.byte(a) < 255 ? rgb + String(format: "%02X", Self.byte(a)) : rgb
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var isOpaque: Bool { Self.byte(a) == 255 }
    public func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: alpha) }

    public static let red = RGBAColor(hex: "#FF3B30")!
    public static let orange = RGBAColor(hex: "#FF9500")!
    public static let yellow = RGBAColor(hex: "#FFD60A")!
    public static let green = RGBAColor(hex: "#34C759")!
    public static let blue = RGBAColor(hex: "#0A84FF")!
    public static let purple = RGBAColor(hex: "#BF5AF2")!
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let swatches: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .purple, .white, .black]
}

// MARK: - Adjust

/// `image.adjust` parameters with the engine's defaults. `options` omits anything at its default.
public struct AdjustSettings: Equatable, Sendable {
    public var exposure = 0.0
    public var brightness = 0.0
    public var contrast = 1.0
    public var gamma = 1.0
    public var saturation = 1.0
    public var vibrance = 0.0
    public var temperature = 6500.0
    public var tint = 0.0
    public var hue = 0.0
    public var sharpness = 0.0
    public var blur = 0.0
    public var filter = "none"

    public init() {}

    public static let filters = ["none", "mono", "noir", "chrome", "fade", "instant", "process", "tonal", "transfer", "sepia", "invert"]

    public struct Slider: Sendable {
        public let key: String
        public let title: String
        public let range: ClosedRange<Double>
        public let step: Double
        public let defaultValue: Double
        public let group: String
    }

    /// Ranges match ImageEngine's `image.adjust` option specs.
    public static let sliders: [Slider] = [
        Slider(key: "exposure", title: "Exposure", range: -3...3, step: 0.05, defaultValue: 0, group: "Light"),
        Slider(key: "brightness", title: "Brightness", range: -1...1, step: 0.01, defaultValue: 0, group: "Light"),
        Slider(key: "contrast", title: "Contrast", range: 0.25...4, step: 0.01, defaultValue: 1, group: "Light"),
        Slider(key: "gamma", title: "Gamma", range: 0.25...4, step: 0.01, defaultValue: 1, group: "Light"),
        Slider(key: "saturation", title: "Saturation", range: 0...2, step: 0.01, defaultValue: 1, group: "Color"),
        Slider(key: "vibrance", title: "Vibrance", range: -1...1, step: 0.01, defaultValue: 0, group: "Color"),
        Slider(key: "temperature", title: "Warmth (K)", range: 2000...12000, step: 50, defaultValue: 6500, group: "Color"),
        Slider(key: "tint", title: "Tint", range: -150...150, step: 1, defaultValue: 0, group: "Color"),
        Slider(key: "hue", title: "Hue (°)", range: -180...180, step: 1, defaultValue: 0, group: "Color"),
        Slider(key: "sharpness", title: "Sharpness", range: 0...2, step: 0.05, defaultValue: 0, group: "Detail"),
        Slider(key: "blur", title: "Blur (px)", range: 0...100, step: 1, defaultValue: 0, group: "Detail"),
    ]

    public subscript(key: String) -> Double {
        get {
            switch key {
            case "exposure": exposure
            case "brightness": brightness
            case "contrast": contrast
            case "gamma": gamma
            case "saturation": saturation
            case "vibrance": vibrance
            case "temperature": temperature
            case "tint": tint
            case "hue": hue
            case "sharpness": sharpness
            case "blur": blur
            default: 0
            }
        }
        set {
            switch key {
            case "exposure": exposure = newValue
            case "brightness": brightness = newValue
            case "contrast": contrast = newValue
            case "gamma": gamma = newValue
            case "saturation": saturation = newValue
            case "vibrance": vibrance = newValue
            case "temperature": temperature = newValue
            case "tint": tint = newValue
            case "hue": hue = newValue
            case "sharpness": sharpness = newValue
            case "blur": blur = newValue
            default: break
            }
        }
    }

    static func isDefault(_ v: Double, _ d: Double) -> Bool { abs(v - d) < 1e-9 }

    public var isDefault: Bool { options.isEmpty }

    public var options: [String: OptionValue] {
        var o: [String: OptionValue] = [:]
        for s in Self.sliders where !Self.isDefault(self[s.key], s.defaultValue) {
            o[s.key] = .double(self[s.key])
        }
        if filter != "none" && !filter.isEmpty { o["filter"] = .string(filter) }
        return o
    }
}

// MARK: - Annotate

public enum AnnotationKind: String, CaseIterable, Sendable {
    case rect, ellipse, line, arrow, freehand, text, highlight

    /// Shapes defined by a rect (drag corner to corner).
    public var isBoxed: Bool { self == .rect || self == .ellipse || self == .highlight }
    public var isPath: Bool { self == .line || self == .arrow || self == .freehand }
}

/// One annotation in full-resolution source pixels (top-left origin).
public struct Annotation: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var kind: AnnotationKind
    /// rect / ellipse / highlight bounds; for text only `origin` (top-left of the first line) is used.
    public var rect: CGRect = .zero
    /// line / arrow: 2 points; freehand: many.
    public var points: [CGPoint] = []
    public var color: RGBAColor = .red
    public var lineWidth: Double = 4
    public var fill = false
    public var text = ""
    public var fontSize: Double = 32
    /// PostScript font name; nil = engine default (bold system font).
    public var font: String?

    public init(kind: AnnotationKind, rect: CGRect = .zero, points: [CGPoint] = [], color: RGBAColor = .red,
                lineWidth: Double = 4, fill: Bool = false, text: String = "", fontSize: Double = 32, font: String? = nil) {
        self.kind = kind
        self.rect = rect
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.fill = fill
        self.text = text
        self.fontSize = fontSize
        self.font = font
    }

    /// Worth sending to the engine (non-degenerate).
    public var isRenderable: Bool {
        switch kind {
        case .rect, .ellipse, .highlight: rect.standardized.width >= 1 && rect.standardized.height >= 1
        case .line, .arrow: points.count >= 2 && hypot(points[0].x - points.last!.x, points[0].y - points.last!.y) >= 1
        case .freehand: points.count >= 2
        case .text: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func translated(by d: CGSize) -> Annotation {
        var a = self
        a.rect = rect.offsetBy(dx: d.width, dy: d.height)
        a.points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        return a
    }
}

/// Serializes annotations to the `shapes` JSON schema `image.annotate` decodes.
public enum AnnotationJSON {
    struct Shape: Encodable {
        var type: String
        var x: Double?
        var y: Double?
        var w: Double?
        var h: Double?
        var points: [[Double]]?
        var color: String
        var lineWidth: Double?
        var fill: Bool?
        var text: String?
        var fontSize: Double?
        var font: String?
    }

    /// 1/100 px is far below what the renderer can show; keeps freehand payloads compact.
    static func round(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }

    static func shape(_ a: Annotation) -> Shape {
        let r = a.rect.standardized
        var s = Shape(type: a.kind.rawValue, color: a.color.hex)
        switch a.kind {
        case .rect, .ellipse:
            (s.x, s.y, s.w, s.h) = (round(r.minX), round(r.minY), round(r.width), round(r.height))
            s.lineWidth = round(a.lineWidth)
            s.fill = a.fill
        case .highlight:
            (s.x, s.y, s.w, s.h) = (round(r.minX), round(r.minY), round(r.width), round(r.height))
            s.fill = true
        case .line, .arrow, .freehand:
            s.points = a.points.map { [round($0.x), round($0.y)] }
            s.lineWidth = round(a.lineWidth)
        case .text:
            (s.x, s.y) = (round(a.rect.minX), round(a.rect.minY))
            s.text = a.text
            s.fontSize = round(a.fontSize)
            s.font = a.font
        }
        return s
    }

    /// JSON array string, keys sorted; degenerate shapes are dropped.
    public static func encode(_ annotations: [Annotation]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let shapes = annotations.filter(\.isRenderable).map(shape)
        guard let data = try? encoder.encode(shapes), let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    public static func options(_ annotations: [Annotation]) -> [String: OptionValue] {
        ["shapes": .string(encode(annotations))]
    }
}

// MARK: - Redact

public enum RedactStyle: String, CaseIterable, Sendable {
    case black, pixelate, blur
    public var title: String {
        switch self {
        case .black: "Solid"
        case .pixelate: "Pixelate"
        case .blur: "Blur"
        }
    }
}

public struct RedactSettings: Equatable, Sendable {
    /// Full-resolution source pixels, top-left origin (unrounded while editing).
    public var regions: [CGRect] = []
    public var style: RedactStyle = .black
    public var color: RGBAColor = .black

    public init(regions: [CGRect] = [], style: RedactStyle = .black, color: RGBAColor = .black) {
        self.regions = regions
        self.style = style
        self.color = color
    }

    /// Whole-pixel regions that fully cover what the user marked, clamped to the image; empty ones dropped.
    public func pixelRegions(bounds: CGSize) -> [CGRect] {
        regions.compactMap { CropMath.coveringRect($0, bounds: bounds) }
    }

    /// Flat `x,y,w,h, x,y,w,h, …` list.
    public static func regionList(_ rects: [CGRect]) -> [Double] {
        rects.flatMap { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
    }

    public func options(bounds: CGSize) -> [String: OptionValue] {
        var o: [String: OptionValue] = [
            "regions": .list(Self.regionList(pixelRegions(bounds: bounds))),
            "style": .string(style.rawValue),
        ]
        if style == .black { o["color"] = .string(color.hex) }
        return o
    }
}

// MARK: - Background

public enum BackgroundMode: String, CaseIterable, Sendable {
    case fill, replace, remove
    public var title: String {
        switch self {
        case .fill: "Fill"
        case .replace: "Replace"
        case .remove: "Remove"
        }
    }

    /// replace/remove lift the subject with Vision (macOS 14+).
    public var needsSubjectLift: Bool { self != .fill }

    public static var available: [BackgroundMode] {
        if #available(macOS 14.0, *) { return allCases }
        return [.fill]
    }
}

public struct BackgroundSettings: Equatable, Sendable {
    public var mode: BackgroundMode = .fill
    /// nil = transparent.
    public var color: RGBAColor? = .white
    public var padding: Int = 0

    public init(mode: BackgroundMode = .fill, color: RGBAColor? = .white, padding: Int = 0) {
        self.mode = mode
        self.color = color
        self.padding = padding
    }

    public static let paddingRange = 0...2000

    public var colorString: String { color?.hex ?? "transparent" }

    public func outputSize(for source: CGSize) -> CGSize {
        let p = CGFloat(max(0, padding))
        return CGSize(width: source.width + 2 * p, height: source.height + 2 * p)
    }

    public var options: [String: OptionValue] {
        ["mode": .string(mode.rawValue), "color": .string(colorString), "padding": .int(max(0, padding))]
    }
}
