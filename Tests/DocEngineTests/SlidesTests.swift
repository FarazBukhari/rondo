import AppKit
import Foundation
import Testing
import RondoKit
@testable import DocEngine

@Suite struct SlidesTests {
    /// Exporters aren't installed on every Mac; the rasterizer they feed is tested on a generated PDF.
    @Test func rasterizesEveryPage() throws {
        let dir = try W5.dir("slides")
        let pdf = dir.appendingPathComponent("deck.pdf")
        let text = NSAttributedString(string: String(repeating: "Slide body text. ", count: 600), attributes: [.font: DocFonts.body(size: 18)])
        let pages = try PDFWriter.write(text, to: pdf, pageSize: CGSize(width: 720, height: 405), margin: 36, info: .init())
        #expect(pages >= 2)
        let files = try PDFWriter.rasterize(pdf, format: "png", dpi: 72, quality: 0.9, into: dir.appendingPathComponent("png"))
        #expect(files.count == pages)
        #expect(files.first?.lastPathComponent.hasPrefix("Slide ") == true)
        let src = try #require(CGImageSourceCreateWithURL(files[0] as CFURL, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(img.width == 720 && img.height == 405)
    }

    @Test func missingExporterIsReported() async throws {
        let locator = ToolLocator()
        guard !locator.has("soffice"), Slides.keynoteURL() == nil else { return }
        let dir = try W5.dir("slides-missing")
        let pptx = try W5.write("not really a deck", to: dir, name: "deck.pptx")
        await #expect(throws: EngineError.missingTool("LibreOffice (soffice) or Keynote")) {
            try await W5.one(pptx, to: "pdf")
        }
    }
}
