import Foundation
import ImageIO
import PDFKit
import RondoKit

/// Structural checks on produced files. Returns nil when the output looks valid.
enum Validator {
    static func problem(with url: URL, expected: String?) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return "missing" }

        let format = FormatCatalog.format(for: url)
        if isDir.boolValue && format?.kind != .document {   // .rtfd/.pages are packages
            let children = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
            guard !children.isEmpty else { return "empty folder" }
            for child in children {
                if let p = problem(with: child, expected: nil) { return "\(child.lastPathComponent): \(p)" }
            }
            return nil
        }

        if let expected, format?.id != expected {
            // Multi-file outputs (e.g. PDF → JPG pages) come back as folders and are handled above.
            return "expected .\(expected), got \(url.pathExtension)"
        }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if !isDir.boolValue && size == 0 { return "zero bytes" }

        guard let format else { return nil }
        switch format.kind {
        case .image where format.id != "svg":
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(src) > 0,
                  CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else { return "unreadable image" }
        case .video, .audio:
            return mediaProblem(url)
        case .pdf:
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return "unreadable PDF" }
        case .archive:
            return archiveProblem(url, id: format.id)
        default:
            switch format.id {
            case "docx", "xlsx", "pptx", "epub", "odt", "ods":
                return run("/usr/bin/unzip", ["-tq", url.path]) ? nil : "corrupt zip container"
            case "txt", "md", "html", "csv", "tsv", "srt", "vtt", "rtf":
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "empty/invalid text" }
                if format.id == "vtt" && !text.hasPrefix("WEBVTT") { return "missing WEBVTT header" }
                if format.id == "srt" && !text.contains("-->") { return "no cues" }
            default:
                break
            }
        }
        return nil
    }

    static func mediaProblem(_ url: URL) -> String? {
        guard let ffprobe = ToolLocator().url(for: "ffprobe") else { return nil }
        let out = capture(ffprobe.path, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
        guard let out, let d = Double(out.trimmingCharacters(in: .whitespacesAndNewlines)), d > 0 else {
            return "ffprobe: no duration"
        }
        return nil
    }

    static func archiveProblem(_ url: URL, id: String) -> String? {
        switch id {
        case "zip": run("/usr/bin/unzip", ["-tq", url.path]) ? nil : "corrupt zip"
        case "tar", "tar.gz": run("/usr/bin/tar", ["-tf", url.path]) ? nil : "corrupt tar"
        case "gz": run("/usr/bin/gzip", ["-t", url.path]) ? nil : "corrupt gzip"
        default: nil
        }
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func capture(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
