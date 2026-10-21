import CoreGraphics
import Foundation
import RondoKit
import ImageEngine
import Testing
@testable import ImageEditorUI

@Suite struct ColorTests {
    @Test func hexRoundTrip() {
        #expect(RGBAColor(hex: "#FF3B30")?.hex == "#FF3B30")
        #expect(RGBAColor(hex: "ff3b30")?.hex == "#FF3B30")
        #expect(RGBAColor(hex: "#abc")?.hex == "#AABBCC")
        #expect(RGBAColor(hex: "#11223380")?.hex == "#11223380")
        #expect(RGBAColor(hex: "#1122")  == nil)
        #expect(RGBAColor(hex: "zzzzzz") == nil)
        #expect(RGBAColor.yellow.withAlpha(0.4).hex == "#FFD60A66")
        #expect(RGBAColor(r: 1.2, g: -1, b: 0.5).hex == "#FF0080")
        let c = RGBAColor(cgColor: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        #expect(c?.hex == "#336699")
    }
}

@Suite struct AdjustOptionTests {
    @Test func defaultsAreOmitted() {
        var a = AdjustSettings()
        #expect(a.options.isEmpty && a.isDefault)
        a.exposure = 0.5
        a.temperature = 7200
        a.filter = "noir"
        #expect(a.options == ["exposure": .double(0.5), "temperature": .double(7200), "filter": .string("noir")])
        a.exposure = 0
        a.temperature = 6500
        a.filter = "none"
        #expect(a.options.isEmpty)
        a.contrast = 1.000_000_000_01   // within tolerance of the default
        #expect(a.options.isEmpty)
    }

    @Test func everySliderKeyRoundTripsAndMatchesTheEngineDescriptor() {
        let descriptor = RasterEngineDescriptors.tool("image.adjust")
        for s in AdjustSettings.sliders {
            var a = AdjustSettings()
            #expect(a[s.key] == s.defaultValue, "\(s.key) default")
            a[s.key] = s.range.upperBound
            #expect(a.options == [s.key: .double(s.range.upperBound)])
            // Same key, range and default as the engine's OptionSpec.
            let spec = descriptor?.options.first { $0.key == s.key }
            #expect(spec?.defaultValue == .double(s.defaultValue), "\(s.key)")
            if case .slider(let lo, let hi, _)? = spec?.control { #expect(lo == s.range.lowerBound && hi == s.range.upperBound, "\(s.key)") }
        }
        if case .choice(let names)? = descriptor?.options.first(where: { $0.key == "filter" })?.control {
            #expect(names == AdjustSettings.filters)
        } else {
            Issue.record("engine has no filter choice")
        }
    }
}

@Suite struct AnnotationJSONTests {
    @Test func exactSchema() {
        let shapes: [Annotation] = [
            Annotation(kind: .rect, rect: CGRect(x: 10, y: 20, width: 30, height: 40), color: .red, lineWidth: 4),
            Annotation(kind: .ellipse, rect: CGRect(x: 50, y: 60, width: -20, height: 10), color: .blue, lineWidth: 2.5, fill: true),
            Annotation(kind: .arrow, points: [CGPoint(x: 1, y: 2), CGPoint(x: 100.123, y: 200.456)], color: .green, lineWidth: 6),
            Annotation(kind: .line, points: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)], color: .black, lineWidth: 1),
            Annotation(kind: .freehand, points: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 3), CGPoint(x: 4, y: 4)], color: .orange, lineWidth: 3),
            Annotation(kind: .text, rect: CGRect(x: 15, y: 25, width: 0, height: 0), color: .white, text: "Hi \"there\"\nline 2", fontSize: 48),
            Annotation(kind: .highlight, rect: CGRect(x: 0, y: 0, width: 80, height: 12), color: RGBAColor.yellow.withAlpha(0.4)),
        ]
        let json = AnnotationJSON.encode(shapes)
        let expected = ##"[{"color":"#FF3B30","fill":false,"h":40,"lineWidth":4,"type":"rect","w":30,"x":10,"y":20},"##
            + ##"{"color":"#0A84FF","fill":true,"h":10,"lineWidth":2.5,"type":"ellipse","w":20,"x":30,"y":60},"##
            + ##"{"color":"#34C759","lineWidth":6,"points":[[1,2],[100.12,200.46]],"type":"arrow"},"##
            + ##"{"color":"#000000","lineWidth":1,"points":[[0,0],[5,5]],"type":"line"},"##
            + ##"{"color":"#FF9500","lineWidth":3,"points":[[1,1],[2,3],[4,4]],"type":"freehand"},"##
            + ##"{"color":"#FFFFFF","fontSize":48,"text":"Hi \"there\"\nline 2","type":"text","x":15,"y":25},"##
            + ##"{"color":"#FFD60A66","fill":true,"h":12,"type":"highlight","w":80,"x":0,"y":0}]"##
        #expect(json == expected)
        #expect(AnnotationJSON.options(shapes) == ["shapes": .string(expected)])
    }

    /// Structural check against the engine's `Shape` schema: only known keys, right JSON types.
    @Test func onlyEngineKeysWithEngineTypes() throws {
        let shapes = AnnotationKind.allCases.map { kind in
            Annotation(kind: kind, rect: CGRect(x: 1, y: 2, width: 30, height: 40),
                       points: [CGPoint(x: 0, y: 0), CGPoint(x: 9, y: 9)], text: "T", font: kind == .text ? "Menlo-Bold" : nil)
        }
        let data = Data(AnnotationJSON.encode(shapes).utf8)
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(array.count == AnnotationKind.allCases.count)
        let numeric: Set = ["x", "y", "w", "h", "lineWidth", "fontSize"]
        let allowed: Set = numeric.union(["type", "points", "color", "fill", "text", "font"])
        for obj in array {
            #expect(Set(obj.keys).isSubset(of: allowed))
            for k in numeric where obj[k] != nil { #expect(obj[k] is NSNumber, "\(k)") }
            if let fill = obj["fill"] { #expect(CFGetTypeID(fill as CFTypeRef) == CFBooleanGetTypeID()) }
            let color = try #require(obj["color"] as? String)
            #expect(color.range(of: "^#[0-9A-F]{6}([0-9A-F]{2})?$", options: .regularExpression) != nil)
            if let pts = obj["points"] { #expect((pts as? [[Double]])?.allSatisfy { $0.count == 2 } == true) }
        }
        #expect(array.last(where: { $0["type"] as? String == "text" })?["font"] as? String == "Menlo-Bold")
    }

    @Test func degenerateShapesAreDropped() {
        let shapes = [
            Annotation(kind: .rect, rect: CGRect(x: 5, y: 5, width: 0.4, height: 20)),
            Annotation(kind: .arrow, points: [CGPoint(x: 3, y: 3), CGPoint(x: 3.2, y: 3)]),
            Annotation(kind: .text, text: "   "),
            Annotation(kind: .freehand, points: [CGPoint(x: 1, y: 1)]),
        ]
        #expect(AnnotationJSON.encode(shapes) == "[]")
    }
}

@Suite struct RedactOptionTests {
    @Test func regionListIsCoveringAndFlat() {
        let s = RedactSettings(regions: [
            CGRect(x: 10.6, y: 9.4, width: 20.2, height: 30.2),
            CGRect(x: 90, y: 90, width: 50, height: 50),      // clipped by the 100×100 image
            CGRect(x: 120, y: 5, width: 5, height: 5),        // outside → dropped
            CGRect(x: 40, y: 40, width: 0, height: 10),       // empty → dropped
        ], style: .black, color: RGBAColor(hex: "#112233")!)
        let bounds = CGSize(width: 100, height: 100)
        #expect(s.pixelRegions(bounds: bounds) == [CGRect(x: 10, y: 9, width: 21, height: 31), CGRect(x: 90, y: 90, width: 10, height: 10)])
        #expect(s.options(bounds: bounds) == [
            "regions": .list([10, 9, 21, 31, 90, 90, 10, 10]),
            "style": .string("black"),
            "color": .string("#112233"),
        ])
        var p = s
        p.style = .pixelate
        #expect(p.options(bounds: bounds)["color"] == nil)
        #expect(p.options(bounds: bounds)["style"] == .string("pixelate"))
        p.style = .blur
        #expect(p.options(bounds: bounds)["style"] == .string("blur"))
    }
}

@Suite struct BackgroundOptionTests {
    @Test func explicitOptions() {
        var b = BackgroundSettings()
        #expect(b.options == ["mode": .string("fill"), "color": .string("#FFFFFF"), "padding": .int(0)])
        b.color = nil
        b.padding = 24
        #expect(b.options == ["mode": .string("fill"), "color": .string("transparent"), "padding": .int(24)])
        #expect(b.outputSize(for: CGSize(width: 100, height: 50)) == CGSize(width: 148, height: 98))
        b.mode = .remove
        b.padding = -5
        #expect(b.options["mode"] == .string("remove"))
        #expect(b.options["padding"] == .int(0))
    }
}

/// Reads ImageEngine's public descriptors so option ranges can't drift silently.
enum RasterEngineDescriptors {
    static func tool(_ id: String) -> ToolDescriptor? {
        RasterEngine().tools().first { $0.id.rawValue == id }
    }
}
