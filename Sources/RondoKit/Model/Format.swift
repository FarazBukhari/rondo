import Foundation

public enum FileKind: String, Codable, CaseIterable, Sendable {
    case image, video, audio, pdf, document, slides, spreadsheet, subtitle, archive, folder, unknown

    /// SF Symbol used for wheel slices and HUD rows.
    public var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .slides: "rectangle.on.rectangle.angled"
        case .spreadsheet: "tablecells"
        case .subtitle: "captions.bubble"
        case .archive: "archivebox"
        case .folder: "folder"
        case .unknown: "doc"
        }
    }

    /// Video jobs are CPU/GPU heavy; JobQueue limits how many run at once.
    public var isHeavy: Bool { self == .video }
}

public struct Format: Hashable, Codable, Sendable, Identifiable {
    /// Canonical lowercase id, e.g. "jpg", "heic", "mp4", "tar.gz". Also the default output extension.
    public let id: String
    public let displayName: String
    public let kind: FileKind
    /// Lowercase extensions without dot; first is preferred. Empty for pseudo-formats (folder).
    public let extensions: [String]
    public let utType: String?

    public init(id: String, displayName: String, kind: FileKind, extensions: [String], utType: String?) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.extensions = extensions
        self.utType = utType
    }

    /// Extension written for outputs of this format.
    public var preferredExtension: String { extensions.first ?? id }
}
