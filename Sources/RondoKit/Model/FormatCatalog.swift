import Foundation

/// Single source of truth for format ids, extensions and kinds. Order = wheel preference order.
public enum FormatCatalog {
    public static let all: [Format] = [
        // Images
        Format(id: "jpg", displayName: "JPEG", kind: .image, extensions: ["jpg", "jpeg", "jpe"], utType: "public.jpeg"),
        Format(id: "png", displayName: "PNG", kind: .image, extensions: ["png"], utType: "public.png"),
        Format(id: "heic", displayName: "HEIC", kind: .image, extensions: ["heic", "heif"], utType: "public.heic"),
        Format(id: "webp", displayName: "WebP", kind: .image, extensions: ["webp"], utType: "org.webmproject.webp"),
        Format(id: "avif", displayName: "AVIF", kind: .image, extensions: ["avif"], utType: "public.avif"),
        Format(id: "tiff", displayName: "TIFF", kind: .image, extensions: ["tiff", "tif"], utType: "public.tiff"),
        Format(id: "gif", displayName: "GIF", kind: .image, extensions: ["gif"], utType: "com.compuserve.gif"),
        Format(id: "bmp", displayName: "BMP", kind: .image, extensions: ["bmp"], utType: "com.microsoft.bmp"),
        Format(id: "svg", displayName: "SVG", kind: .image, extensions: ["svg"], utType: "public.svg-image"),

        // Video
        Format(id: "mp4", displayName: "MP4", kind: .video, extensions: ["mp4"], utType: "public.mpeg-4"),
        Format(id: "mov", displayName: "MOV", kind: .video, extensions: ["mov", "qt"], utType: "com.apple.quicktime-movie"),
        Format(id: "mkv", displayName: "MKV", kind: .video, extensions: ["mkv"], utType: "org.matroska.mkv"),
        Format(id: "webm", displayName: "WebM", kind: .video, extensions: ["webm"], utType: "org.webmproject.webm"),
        Format(id: "avi", displayName: "AVI", kind: .video, extensions: ["avi"], utType: "public.avi"),
        Format(id: "wmv", displayName: "WMV", kind: .video, extensions: ["wmv"], utType: "com.microsoft.windows-media-wmv"),
        Format(id: "m4v", displayName: "M4V", kind: .video, extensions: ["m4v"], utType: "com.apple.m4v-video"),

        // Audio
        Format(id: "mp3", displayName: "MP3", kind: .audio, extensions: ["mp3"], utType: "public.mp3"),
        Format(id: "m4a", displayName: "M4A", kind: .audio, extensions: ["m4a"], utType: "com.apple.m4a-audio"),
        Format(id: "wav", displayName: "WAV", kind: .audio, extensions: ["wav"], utType: "com.microsoft.waveform-audio"),
        Format(id: "flac", displayName: "FLAC", kind: .audio, extensions: ["flac"], utType: "org.xiph.flac"),
        Format(id: "ogg", displayName: "OGG", kind: .audio, extensions: ["ogg", "oga"], utType: "org.xiph.ogg-audio"),
        Format(id: "opus", displayName: "Opus", kind: .audio, extensions: ["opus"], utType: "org.xiph.opus"),
        Format(id: "aiff", displayName: "AIFF", kind: .audio, extensions: ["aiff", "aif"], utType: "public.aiff-audio"),
        Format(id: "wma", displayName: "WMA", kind: .audio, extensions: ["wma"], utType: "com.microsoft.windows-media-wma"),

        // PDF
        Format(id: "pdf", displayName: "PDF", kind: .pdf, extensions: ["pdf"], utType: "com.adobe.pdf"),

        // Documents
        Format(id: "docx", displayName: "Word", kind: .document, extensions: ["docx"], utType: "org.openxmlformats.wordprocessingml.document"),
        Format(id: "doc", displayName: "Word 97", kind: .document, extensions: ["doc"], utType: "com.microsoft.word.doc"),
        Format(id: "pages", displayName: "Pages", kind: .document, extensions: ["pages"], utType: "com.apple.iwork.pages.sffpages"),
        Format(id: "rtf", displayName: "RTF", kind: .document, extensions: ["rtf"], utType: "public.rtf"),
        Format(id: "rtfd", displayName: "RTFD", kind: .document, extensions: ["rtfd"], utType: "com.apple.rtfd"),
        Format(id: "txt", displayName: "Text", kind: .document, extensions: ["txt", "text"], utType: "public.plain-text"),
        Format(id: "md", displayName: "Markdown", kind: .document, extensions: ["md", "markdown"], utType: "net.daringfireball.markdown"),
        Format(id: "html", displayName: "HTML", kind: .document, extensions: ["html", "htm"], utType: "public.html"),
        Format(id: "odt", displayName: "ODT", kind: .document, extensions: ["odt"], utType: "org.oasis-open.opendocument.text"),
        Format(id: "epub", displayName: "EPUB", kind: .document, extensions: ["epub"], utType: "org.idpf.epub-container"),
        Format(id: "textclipping", displayName: "Text Clipping", kind: .document, extensions: ["textclipping"], utType: "com.apple.finder.textclipping"),

        // Slides
        Format(id: "pptx", displayName: "PowerPoint", kind: .slides, extensions: ["pptx"], utType: "org.openxmlformats.presentationml.presentation"),
        Format(id: "ppt", displayName: "PowerPoint 97", kind: .slides, extensions: ["ppt"], utType: "com.microsoft.powerpoint.ppt"),
        Format(id: "key", displayName: "Keynote", kind: .slides, extensions: ["key"], utType: "com.apple.iwork.keynote.sffkey"),

        // Spreadsheets
        Format(id: "xlsx", displayName: "Excel", kind: .spreadsheet, extensions: ["xlsx"], utType: "org.openxmlformats.spreadsheetml.sheet"),
        Format(id: "xls", displayName: "Excel 97", kind: .spreadsheet, extensions: ["xls"], utType: "com.microsoft.excel.xls"),
        Format(id: "ods", displayName: "ODS", kind: .spreadsheet, extensions: ["ods"], utType: "org.oasis-open.opendocument.spreadsheet"),
        Format(id: "csv", displayName: "CSV", kind: .spreadsheet, extensions: ["csv"], utType: "public.comma-separated-values-text"),
        Format(id: "tsv", displayName: "TSV", kind: .spreadsheet, extensions: ["tsv", "tab"], utType: "public.tab-separated-values-text"),
        Format(id: "numbers", displayName: "Numbers", kind: .spreadsheet, extensions: ["numbers"], utType: "com.apple.iwork.numbers.sffnumbers"),

        // Subtitles
        Format(id: "srt", displayName: "SRT", kind: .subtitle, extensions: ["srt"], utType: "public.srt"),
        Format(id: "vtt", displayName: "WebVTT", kind: .subtitle, extensions: ["vtt"], utType: "org.w3.webvtt"),

        // Archives (compound extensions first so "x.tar.gz" isn't read as "gz")
        Format(id: "tar.gz", displayName: "TAR.GZ", kind: .archive, extensions: ["tar.gz", "tgz"], utType: "org.gnu.gnu-zip-tar-archive"),
        Format(id: "zip", displayName: "ZIP", kind: .archive, extensions: ["zip"], utType: "public.zip-archive"),
        Format(id: "tar", displayName: "TAR", kind: .archive, extensions: ["tar"], utType: "public.tar-archive"),
        Format(id: "gz", displayName: "GZIP", kind: .archive, extensions: ["gz", "gzip"], utType: "org.gnu.gnu-zip-archive"),
        Format(id: "rar", displayName: "RAR", kind: .archive, extensions: ["rar"], utType: "com.rarlab.rar-archive"),

        // Pseudo-format for directories (archive targets, actions)
        Format(id: "folder", displayName: "Folder", kind: .folder, extensions: [], utType: "public.folder"),
    ]

    private static let byID: [String: Format] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    private static let order: [String: Int] = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })

    public static func format(id: String) -> Format? { byID[id.lowercased()] }

    public static func format(utType: String) -> Format? {
        all.first { $0.utType == utType }
    }

    /// Format for a file URL by extension (compound extensions like `.tar.gz` win).
    /// Directories that aren't packages (`.rtfd`, `.pages`, …) map to the `folder` pseudo-format.
    public static func format(for url: URL) -> Format? {
        let name = url.lastPathComponent.lowercased()
        if let f = all.first(where: { f in f.extensions.contains { $0.contains(".") && name.hasSuffix("." + $0) } }) {
            return f
        }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, let f = all.first(where: { $0.extensions.contains(ext) }) {
            return f
        }
        if isPlainDirectory(url) { return byID["folder"] }
        return nil
    }

    public static func kind(for url: URL) -> FileKind {
        format(for: url)?.kind ?? .unknown
    }

    /// Sort key: catalog order, unknown ids last.
    public static func rank(_ id: String) -> Int { order[id] ?? Int.max }

    static func isPlainDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        return !isPackage
    }
}
