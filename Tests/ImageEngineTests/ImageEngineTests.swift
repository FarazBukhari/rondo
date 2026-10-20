import Foundation
import CoreGraphics
import ImageIO
import Testing
import RondoKit
@testable import ImageEngine

@Suite struct ImageEngineCapabilityTests {
    @Test func descriptors() {
        let engine = RasterEngine()
        let ids = Set(engine.tools().map(\.id.rawValue))
        #expect(ids == ["image.compress", "image.resize", "image.metadata.read", "image.metadata.strip", "image.qr.read",
                        "image.toPDF", "image.collage", "image.crop", "image.adjust", "image.annotate", "image.redact", "image.background"])
        let ui = Set(engine.tools().filter(\.needsUI).map(\.id.rawValue))
        #expect(ui == ["image.crop", "image.adjust", "image.annotate", "image.redact", "image.background"])
        #expect(engine.tools().first { $0.id == "image.collage" }?.multiInput == .combine(minimum: 2))
        #expect(engine.tools().allSatisfy { $0.accepts == [.image] })
    }

    @Test func conversionsGatedOnCapabilities() {
        let pairs = Set(RasterEngine().conversions().map { "\($0.from)>\($0.to)" })
        #expect(pairs.contains("jpg>png"))
        #expect(pairs.contains("png>pdf"))
        #expect(!pairs.contains("png>svg"))
        #expect(!pairs.contains { $0.hasSuffix(">svg") })
        let noMagick = RasterEngine(tools: ToolLocator(overrides: [:], bundleBin: nil).withoutSearch())
        let limited = Set(noMagick.conversions().map { "\($0.from)>\($0.to)" })
        #expect(!limited.contains { $0.hasPrefix("svg>") })
        #expect(limited.contains("jpg>png"))
        if !ImageFormats.imageIOCanWrite("webp") { #expect(!limited.contains("png>webp")) }
        if ToolLocator().has("magick") {
            #expect(pairs.contains("svg>png"))
            #expect(pairs.contains("png>webp"))
        }
    }
}

extension ToolLocator {
    /// A locator that finds nothing (simulates a Mac without Homebrew tools).
    func withoutSearch() -> ToolLocator {
        var l = self
        l.searchDirectories = []
        return l
    }
}

@Suite struct ImageConversionTests {
    /// Every advertised pair round-trips on a generated fixture: decodable output, right size, upright, red corner.
    @Test func everyAdvertisedPair() async throws {
        let dir = try Fx.dir("matrix")
        defer { Fx.cleanup(dir) }
        let engine = RasterEngine()
        let pairs = engine.conversions()
        var fixtures: [String: URL] = [:]
        for from in Set(pairs.map(\.from)) {
            fixtures[from] = try await Fx.fixture(from, in: dir, name: "src-\(from)")
        }
        var failures: [String] = []
        for pair in pairs.sorted(by: { ($0.from, $0.to) < ($1.from, $1.to) }) {
            guard let input = fixtures[pair.from] else { failures.append("no fixture for \(pair.from)"); continue }
            do {
                let out = try await engine.runTest(JobSpec(inputs: [input], operation: .convert(to: pair.to)))
                guard out.count == 1, let url = out.first else { failures.append("\(pair.from)>\(pair.to): \(out.count) outputs"); continue }
                #expect(url.pathExtension == ImageFormats.ext(pair.to))
                #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
                if pair.to == "pdf" {
                    if Fx.pdfPageCount(url) != 1 { failures.append("\(pair.from)>pdf: bad page count") }
                    continue
                }
                guard let img = Fx.load(url) else { failures.append("\(pair.from)>\(pair.to): undecodable"); continue }
                if img.width != 160 || img.height != 120 { failures.append("\(pair.from)>\(pair.to): \(img.width)x\(img.height)") }
                if !Fx.isRed(Fx.pixel(img, 6, 6)) { failures.append("\(pair.from)>\(pair.to): top-left not red \(Fx.pixel(img, 6, 6))") }
            } catch {
                failures.append("\(pair.from)>\(pair.to): \(error.localizedDescription)")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(pairs.count >= 40)
    }

    @Test func alphaFlattensOntoWhiteForJPGAndBMP() async throws {
        let dir = try Fx.dir("alpha")
        defer { Fx.cleanup(dir) }
        let src = try #require(try await Fx.fixture("png", in: dir, alpha: true))
        let engine = RasterEngine()
        for target in ["jpg", "bmp"] {
            let out = try await engine.runTest(JobSpec(inputs: [src], operation: .convert(to: target)))
            let img = try #require(Fx.load(out[0]))
            #expect(Fx.isWhite(Fx.pixel(img, 150, 10)), "\(target) transparent corner should be white")
            #expect(!img.hasAlpha || Fx.pixel(img, 150, 10).a == 255)
        }
        // PNG → TIFF keeps alpha.
        let tiff = try await engine.runTest(JobSpec(inputs: [src], operation: .convert(to: "tiff")))
        #expect(Fx.pixel(try #require(Fx.load(tiff[0])), 150, 10).a < 10)
    }

    @Test func orientationIsBakedIntoPixels() async throws {
        let dir = try Fx.dir("orient")
        defer { Fx.cleanup(dir) }
        let src = dir.appendingPathComponent("rotated.jpg")
        #expect(Fx.write(Fx.pattern(), type: "public.jpeg", to: src, props: [kCGImagePropertyOrientation as String: 6]))
        let out = try await RasterEngine().runTest(JobSpec(inputs: [src], operation: .convert(to: "png")))
        let img = try #require(Fx.load(out[0]))
        #expect(img.width == 120 && img.height == 160)
        // EXIF 6 = rotate 90° clockwise to display: data top-left lands at display top-right.
        #expect(Fx.isRed(Fx.pixel(img, 113, 6)))
        let o = (Fx.properties(out[0])[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        #expect(o == 1)
    }

    @Test func colorProfileSurvivesConversion() async throws {
        let dir = try Fx.dir("profile")
        defer { Fx.cleanup(dir) }
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let base = Fx.pattern()
        let tagged = base.copy(colorSpace: p3)!
        let src = dir.appendingPathComponent("p3.png")
        #expect(Fx.write(tagged, type: "public.png", to: src))
        let out = try await RasterEngine().runTest(JobSpec(inputs: [src], operation: .convert(to: "jpg")))
        let profile = Fx.properties(out[0])[kCGImagePropertyProfileName as String] as? String
        #expect(profile?.contains("P3") == true, "profile: \(profile ?? "nil")")
    }

    @Test func batchProgressIsMonotonic() async throws {
        let dir = try Fx.dir("progress")
        defer { Fx.cleanup(dir) }
        let a = try #require(try await Fx.fixture("png", in: dir, name: "a"))
        let b = try #require(try await Fx.fixture("png", in: dir, name: "b"))
        let log = ProgressLog()
        let out = try await RasterEngine().runTest(JobSpec(inputs: [a, b], operation: .convert(to: "jpg")), progress: log)
        #expect(out.count == 2)
        let v = log.all
        #expect(!v.isEmpty)
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(v.allSatisfy { (0...1).contains($0) })
    }

    @Test func cancellationStopsWork() async throws {
        let dir = try Fx.dir("cancel")
        defer { Fx.cleanup(dir) }
        let src = dir.appendingPathComponent("n.jpg")
        Fx.write(Fx.noisy(), type: "public.jpeg", to: src)
        let task = Task {
            try await RasterEngine().runTest(JobSpec(inputs: [src, src, src], operation: .tool("image.compress"), options: ["targetBytes": .int(1000)]))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "n.jpg" }
        #expect(leftovers.isEmpty)
    }

    @Test func outputNeverOverwrites() async throws {
        let dir = try Fx.dir("collide")
        defer { Fx.cleanup(dir) }
        let src = try #require(try await Fx.fixture("png", in: dir, name: "photo"))
        let before = try Data(contentsOf: src)
        let a = try await RasterEngine().runTest(JobSpec(inputs: [src], operation: .convert(to: "jpg")))
        let b = try await RasterEngine().runTest(JobSpec(inputs: [src], operation: .convert(to: "jpg")))
        #expect(a[0].lastPathComponent == "photo.jpg")
        #expect(b[0].lastPathComponent == "photo 2.jpg")
        #expect(try Data(contentsOf: src) == before)
    }
}

@Suite struct ImageToolTests {
    @Test func compressByQuality() async throws {
        let dir = try Fx.dir("cq")
        defer { Fx.cleanup(dir) }
        let src = dir.appendingPathComponent("photo.jpg")
        Fx.write(Fx.noisy(), type: "public.jpeg", to: src, quality: 0.95)
        let out = try await RasterEngine().runTest(JobSpec(inputs: [src], operation: .tool("image.compress"), options: ["quality": .double(0.3)]))
        #expect(out[0].lastPathComponent == "photo compressed.jpg")
        #expect(fileSize(out[0]) < fileSize(src) / 2)
    }

    @Test(arguments: ["jpg", "heic", "webp"])
    func compressToTargetSize(format: String) async throws {
        let dir = try Fx.dir("ct-\(format)")
        defer { Fx.cleanup(dir) }
        guard ImageFormats.canWrite(format, tools: ToolLocator()) else { return }
        let src = dir.appendingPathComponent("photo.\(ImageFormats.ext(format))")
        let staging = dir.appendingPathComponent("stage.png")
        Fx.write(Fx.noisy(), type: "public.png", to: staging)
        // Produce a high-quality source in the format under test via the engine itself.
        let made = try await RasterEngine().runTest(JobSpec(inputs: [staging], operation: .convert(to: format), options: ["quality": .double(0.95)]))
        try FileManager.default.moveItem(at: made[0], to: src)
        let original = fileSize(src)
        let target = original * 2 / 5
        let out = try await RasterEngine().runTest(JobSpec(inputs: [src], operation: .tool("image.compress"), options: ["targetBytes": .int(target)]))
        let size = fileSize(out[0])
        #expect(abs(Double(size - target)) <= Double(target) * 0.10, "\(format): target \(target), got \(size) (orig \(original))")
        // percent: reduce by 50%
        let half = try await RasterEngine().runTest(JobSpec(inputs: [src], operation: .tool("image.compress"), options: ["percent": .double(50)]))
        let t2 = original / 2
        #expect(abs(Double(fileSize(half[0]) - t2)) <= Double(t2) * 0.10, "\(format) percent: target \(t2), got \(fileSize(half[0]))")
    }

    @Test func compressPNGQuantizes() async throws {
        let dir = try Fx.dir("cpng")
        defer { Fx.cleanup(dir) }
        let src = dir.appendingPathComponent("shot.png")
        Fx.write(Fx.noisy(), type: "public.png", to: src)
        let out = try await RasterEngine().runTest(JobSpec(inputs: [src], operation: .tool("image.compress"), options: ["quality": .double(0.3)]))
        #expect(out[0].pathExtension == "png")
        #expect(fileSize(out[0]) <= fileSize(src))
        if ToolLocator().has("magick") { #expect(fileSize(out[0]) < fileSize(src) * 3 / 4) }
    }

    @Test func resize() async throws {
        let dir = try Fx.dir("resize")
        defer { Fx.cleanup(dir) }
        let src = try #require(try await Fx.fixture("png", in: dir))
        let e = RasterEngine()
        func dims(_ opts: [String: OptionValue]) async throws -> (Int, Int) {
            let out = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.resize"), options: opts))
            #expect(out[0].lastPathComponent.hasPrefix("sample resized"))
            let img = try #require(Fx.load(out[0]))
            return (img.width, img.height)
        }
        #expect(try await dims(["width": .int(80)]) == (80, 60))
        #expect(try await dims(["height": .int(60)]) == (80, 60))
        #expect(try await dims(["percent": .double(25)]) == (40, 30))
        #expect(try await dims(["width": .int(100), "height": .int(100)]) == (100, 75))
        #expect(try await dims(["width": .int(100), "height": .int(100), "keepAspect": .bool(false)]) == (100, 100))
    }

    @Test func metadataReadAndStrip() async throws {
        let dir = try Fx.dir("meta")
        defer { Fx.cleanup(dir) }
        let src = dir.appendingPathComponent("camera.jpg")
        let props: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "RondoCam", kCGImagePropertyTIFFModel as String: "X1"],
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2026:10:01 12:00:00"],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 43.65, kCGImagePropertyGPSLatitudeRef as String: "N",
                                                      kCGImagePropertyGPSLongitude as String: 79.38, kCGImagePropertyGPSLongitudeRef as String: "W"],
        ]
        #expect(Fx.write(Fx.pattern(), type: "public.jpeg", to: src, props: props))
        #expect(Fx.properties(src)[kCGImagePropertyGPSDictionary as String] != nil)
        let e = RasterEngine()

        let read = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.metadata.read")))
        #expect(read[0].lastPathComponent == "camera metadata.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: read[0])) as? [String: Any])
        let image = try #require(json["image"] as? [String: Any])
        #expect(image["width"] as? Int == 160)
        let raw = try #require(json["properties"] as? [String: Any])
        #expect((raw["{TIFF}"] as? [String: Any])?["Make"] as? String == "RondoCam")
        #expect(raw["{GPS}"] != nil)

        let stripped = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.metadata.strip")))
        #expect(stripped[0].lastPathComponent == "camera stripped.jpg")
        let sp = Fx.properties(stripped[0])
        #expect(sp[kCGImagePropertyGPSDictionary as String] == nil)
        #expect((sp[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String] == nil)
        #expect((sp[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifDateTimeOriginal as String] == nil)
        #expect(Fx.load(stripped[0])?.width == 160)

        // Rotated source: strip must keep it upright.
        let rot = dir.appendingPathComponent("rot.jpg")
        Fx.write(Fx.pattern(), type: "public.jpeg", to: rot, props: props.merging([kCGImagePropertyOrientation as String: 6]) { a, _ in a })
        let s2 = try await e.runTest(JobSpec(inputs: [rot], operation: .tool("image.metadata.strip")))
        let img = try #require(Fx.load(s2[0]))
        #expect(img.width == 120 && img.height == 160)
        #expect(Fx.properties(s2[0])[kCGImagePropertyGPSDictionary as String] == nil)
    }

    @Test func qrRead() async throws {
        let dir = try Fx.dir("qr")
        defer { Fx.cleanup(dir) }
        let src = dir.appendingPathComponent("code.png")
        let payload = "https://rondo.example/w3?q=1"
        Fx.write(Fx.qr(payload), type: "public.png", to: src)
        let out = try await RasterEngine().runTest(JobSpec(inputs: [src], operation: .tool("image.qr.read")))
        #expect(out[0].lastPathComponent == "code QR.txt")
        #expect(try String(contentsOf: out[0], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == payload)

        let blank = try #require(try await Fx.fixture("png", in: dir, name: "blank"))
        await #expect(throws: EngineError.self) {
            _ = try await RasterEngine().runTest(JobSpec(inputs: [blank], operation: .tool("image.qr.read")))
        }
    }

    @Test func imagesToPDFAndCollage() async throws {
        let dir = try Fx.dir("combine")
        defer { Fx.cleanup(dir) }
        var inputs: [URL] = []
        for (i, f) in ["jpg", "png", "tiff", "png"].enumerated() {
            inputs.append(try #require(try await Fx.fixture(f, in: dir, name: "img\(i)")))
        }
        let e = RasterEngine()
        let pdf = try await e.runTest(JobSpec(inputs: Array(inputs.prefix(3)), operation: .tool("image.toPDF")))
        #expect(pdf.count == 1 && pdf[0].pathExtension == "pdf")
        let doc = try #require(CGPDFDocument(pdf[0] as CFURL))
        #expect(doc.numberOfPages == 3)
        let box = try #require(doc.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(box.width == 160 && box.height == 120)

        let a4 = try await e.runTest(JobSpec(inputs: [inputs[0]], operation: .tool("image.toPDF"), options: ["pageSize": .string("a4"), "margin": .int(36)]))
        let a4box = try #require(CGPDFDocument(a4[0] as CFURL)?.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(Int(a4box.width) == 841 && Int(a4box.height) == 595)   // landscape image → landscape page

        let collage = try await e.runTest(JobSpec(inputs: inputs, operation: .tool("image.collage"),
                                                  options: ["columns": .int(2), "cellSize": .int(100), "spacing": .int(10), "format": .string("png")]))
        #expect(collage[0].lastPathComponent == "img0 collage.png")
        let c = try #require(Fx.load(collage[0]))
        #expect(c.width == 230 && c.height == 230)
        let row = try await e.runTest(JobSpec(inputs: Array(inputs.prefix(2)), operation: .tool("image.collage"),
                                              options: ["layout": .string("horizontal"), "cellSize": .int(60), "spacing": .int(0)]))
        let r = try #require(Fx.load(row[0]))
        #expect(r.width == 160 && r.height == 60)
    }

    @Test func editorTools() async throws {
        let dir = try Fx.dir("edit")
        defer { Fx.cleanup(dir) }
        let src = try #require(try await Fx.fixture("png", in: dir, name: "pic"))
        let e = RasterEngine()

        // crop: top-left 24×24 → all red
        let crop = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.crop"), options: ["rect": .list([0, 0, 24, 24])]))
        let ci = try #require(Fx.load(crop[0]))
        #expect(ci.width == 24 && ci.height == 24 && Fx.isRed(Fx.pixel(ci, 12, 12)))
        #expect(crop[0].lastPathComponent == "pic cropped.png")
        // crop: rotate only
        let rot = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.crop"), options: ["rotation": .int(90)]))
        let ri = try #require(Fx.load(rot[0]))
        #expect(ri.width == 120 && ri.height == 160 && Fx.isRed(Fx.pixel(ri, 113, 6)))
        await #expect(throws: EngineError.self) {
            _ = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.crop")))
        }

        // adjust: brightness down → darker
        let adj = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.adjust"), options: ["brightness": .double(-0.5), "filter": .string("mono")]))
        let ai = try #require(Fx.load(adj[0]))
        let before = Fx.pixel(try #require(Fx.load(src)), 80, 60), after = Fx.pixel(ai, 80, 60)
        #expect(after.r + after.g + after.b < before.r + before.g + before.b)
        #expect(abs(after.r - after.g) < 12 && abs(after.g - after.b) < 12)   // mono

        // annotate: filled green rect + arrow + text
        let shapes = ##"[{"type":"rect","x":100,"y":50,"w":20,"h":20,"color":"#00FF00","fill":true},{"type":"arrow","points":[[30,100],[90,100]],"color":"#FFFF00","lineWidth":3},{"type":"text","x":30,"y":30,"text":"Hi","fontSize":20,"color":"#FFFFFF"}]"##
        let ann = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.annotate"), options: ["shapes": .string(shapes)]))
        let px = Fx.pixel(try #require(Fx.load(ann[0])), 110, 60)
        #expect(px.g > 230 && px.r < 30 && px.b < 30)
        await #expect(throws: EngineError.self) {
            _ = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.annotate"), options: ["shapes": .string("not json")]))
        }

        // redact: black region; pixelate & blur run
        let red = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.redact"), options: ["regions": .list([60, 40, 30, 30, 0, 0, 10, 10])]))
        let rp = Fx.pixel(try #require(Fx.load(red[0])), 75, 55)
        #expect(rp.r < 10 && rp.g < 10 && rp.b < 10)
        #expect(Fx.pixel(try #require(Fx.load(red[0])), 5, 5).r < 10)
        for style in ["pixelate", "blur"] {
            let out = try await e.runTest(JobSpec(inputs: [src], operation: .tool("image.redact"), options: ["rect": .list([0, 0, 60, 60]), "style": .string(style)]))
            #expect(Fx.load(out[0])?.width == 160)
        }

        // background fill with padding on an alpha image
        let alpha = try #require(try await Fx.fixture("png", in: dir, name: "cutout", alpha: true))
        let bg = try await e.runTest(JobSpec(inputs: [alpha], operation: .tool("image.background"), options: ["color": .string("#FF00FF"), "padding": .int(10)]))
        let bi = try #require(Fx.load(bg[0]))
        #expect(bi.width == 180 && bi.height == 140)
        let corner = Fx.pixel(bi, 160, 20)      // former transparent quadrant
        #expect(corner.r > 240 && corner.g < 15 && corner.b > 240 && corner.a == 255)
    }
}
