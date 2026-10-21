import AppKit
import RondoKit

/// PPT/PPTX (and Keynote) → PDF/JPG/PNG through an installed exporter: LibreOffice (`soffice --headless`)
/// or Keynote (AppleScript). Images are rasterized from the exported PDF. Advertised only when one exists.
enum Slides {
    static let keynoteBundleID = "com.apple.iWork.Keynote"

    enum Exporter { case soffice(URL), keynote(URL) }

    static func keynoteURL() -> URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: keynoteBundleID) { return u }
        let fallback = URL(fileURLWithPath: "/Applications/Keynote.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    /// Preferred exporter: soffice (headless, no permission prompt), else Keynote via osascript.
    static func exporter(_ tools: ToolLocator, input format: String) -> Exporter? {
        if format != "key", let s = tools.url(for: "soffice") { return .soffice(s) }
        if keynoteURL() != nil, let osa = tools.url(for: "osascript") { return .keynote(osa) }
        return nil
    }

    static func inputs(_ tools: ToolLocator) -> [String] {
        var out: [String] = []
        if tools.has("soffice") { out += ["pptx", "ppt"] }
        if keynoteURL() != nil, tools.has("osascript") {
            for f in ["pptx", "ppt", "key"] where !out.contains(f) { out.append(f) }
        }
        return out
    }

    static func convert(_ input: URL, from: String, to: String, job: JobSpec, context: JobContext,
                        progress: @escaping (Double) -> Void) async throws -> URL {
        try DocSupport.requireInput(input, allowPackage: from == "key")
        guard let exporter = exporter(context.tools, input: from) else {
            throw EngineError.missingTool("LibreOffice (soffice) or Keynote")
        }
        let work = try DocSupport.scratchDir(context)
        // Exporters get a clone (APFS copy-on-write) so LibreOffice's `.~lock.<name>#` never lands beside the original.
        let staged = work.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let copy = staged.appendingPathComponent(input.lastPathComponent)
        try FileManager.default.copyItem(at: input, to: copy)
        progress(0.05)
        let pdf = try await exportPDF(copy, exporter: exporter, work: work)
        progress(0.6)
        if to == "pdf" { return try DocSupport.commit(pdf, for: input, ext: "pdf", context: context) }

        let folder = work.appendingPathComponent("slides", isDirectory: true)
        let dpi = min(max(job.int("dpi", default: 150), 36), 600)
        let files = try PDFWriter.rasterize(pdf, format: to, dpi: Double(dpi),
                                            quality: job.double("quality", default: 0.9), into: folder) { progress(0.6 + $0 * 0.38) }
        if files.count == 1 { return try DocSupport.commit(files[0], for: input, ext: to, context: context) }
        return try context.namer.commit(folder, to: context.namer.folder(for: input, suffix: "slides", destination: context.destination))
    }

    static func exportPDF(_ input: URL, exporter: Exporter, work: URL) async throws -> URL {
        switch exporter {
        case .soffice(let soffice):
            let outDir = work.appendingPathComponent("out", isDirectory: true)
            let profile = work.appendingPathComponent("lo-profile", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            do {
                try await ProcessRunner.run(soffice, ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--norestore",
                                                      "--convert-to", "pdf", "--outdir", outDir.path, input.path])
            } catch let e as ProcessError {
                throw EngineError.failed("LibreOffice export failed: \(e.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            guard let pdf = (try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil))
                .first(where: { $0.pathExtension.lowercased() == "pdf" }) else {
                throw EngineError.failed("LibreOffice produced no PDF")
            }
            return pdf
        case .keynote(let osascript):
            let script = work.appendingPathComponent("export.applescript")
            let out = work.appendingPathComponent("slides.pdf")
            try """
            on run argv
                set inFile to POSIX file (item 1 of argv)
                set outFile to POSIX file (item 2 of argv)
                tell application id "\(keynoteBundleID)"
                    set theDoc to open inFile
                    export theDoc to outFile as PDF
                    close theDoc saving no
                end tell
            end run
            """.write(to: script, atomically: true, encoding: .utf8)
            do {
                try await ProcessRunner.run(osascript, [script.path, input.path, out.path])
            } catch let e as ProcessError {
                let tail = e.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                let hint = tail.contains("-1743") ? " (allow Rondo to control Keynote in System Settings › Privacy & Security › Automation)" : ""
                throw EngineError.failed("Keynote export failed\(hint): \(tail)")
            }
            guard FileManager.default.fileExists(atPath: out.path) else { throw EngineError.failed("Keynote produced no PDF") }
            return out
        }
    }
}
