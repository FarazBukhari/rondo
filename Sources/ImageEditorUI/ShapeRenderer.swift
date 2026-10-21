import CoreGraphics
import CoreText
import Foundation

/// Draws annotations exactly the way `image.annotate` does (same CG calls, same defaults),
/// in a *bottom-left-origin* context whose user space is image pixels of height `canvasHeight`.
public enum ShapeRenderer {
    public static func draw(_ shapes: [Annotation], in ctx: CGContext, canvasHeight H: CGFloat) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for s in shapes where s.isRenderable {
            draw(s, in: ctx, canvasHeight: H)
        }
        ctx.restoreGState()
    }

    static func bl(_ p: CGPoint, _ H: CGFloat) -> CGPoint { CGPoint(x: p.x, y: H - p.y) }
    static func bl(_ r: CGRect, _ H: CGFloat) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }

    static func draw(_ s: Annotation, in ctx: CGContext, canvasHeight H: CGFloat) {
        let color = s.color.cgColor
        let lw = CGFloat(max(0.5, s.lineWidth))
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lw)
        let rect = bl(s.rect.standardized, H)
        switch s.kind {
        case .rect:
            if s.fill { ctx.fill(rect) } else { ctx.stroke(rect) }
        case .highlight:
            ctx.fill(rect)
        case .ellipse:
            if s.fill { ctx.fillEllipse(in: rect) } else { ctx.strokeEllipse(in: rect) }
        case .line, .arrow, .freehand:
            let pts = s.points.map { bl($0, H) }
            guard pts.count >= 2 else { return }
            ctx.beginPath()
            ctx.addLines(between: pts)
            ctx.strokePath()
            if s.kind == .arrow, let tip = pts.last {
                let head = arrowHead(from: pts[pts.count - 2], tip: tip, lineWidth: lw)
                ctx.beginPath()
                ctx.move(to: tip); ctx.addLine(to: head.0); ctx.addLine(to: head.1); ctx.closePath()
                ctx.fillPath()
            }
        case .text:
            let font = font(for: s)
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
            let lineHeight = ascent + descent + leading
            ctx.saveGState()
            ctx.textMatrix = .identity
            for (i, line) in s.text.components(separatedBy: "\n").enumerated() {
                let ctLine = CTLineCreateWithAttributedString(attributed(line, font: font, color: color))
                ctx.textPosition = CGPoint(x: s.rect.minX, y: H - s.rect.minY - ascent - CGFloat(i) * lineHeight)
                CTLineDraw(ctLine, ctx)
            }
            ctx.restoreGState()
        }
    }

    /// Arrow-head base corners (engine geometry: length max(12, 4·lw), ±π/7). Works in either y orientation.
    static func arrowHead(from: CGPoint, tip: CGPoint, lineWidth lw: CGFloat) -> (CGPoint, CGPoint) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let len = max(12, lw * 4)
        return (CGPoint(x: tip.x - len * cos(angle - .pi / 7), y: tip.y - len * sin(angle - .pi / 7)),
                CGPoint(x: tip.x - len * cos(angle + .pi / 7), y: tip.y - len * sin(angle + .pi / 7)))
    }

    static func font(for s: Annotation) -> CTFont {
        let size = CGFloat(s.fontSize)
        return s.font.map { CTFontCreateWithName($0 as CFString, size, nil) }
            ?? CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    static func attributed(_ line: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    // MARK: Geometry (top-left image pixels)

    /// Visual bounds including stroke width.
    public static func bounds(of s: Annotation) -> CGRect {
        let half = CGFloat(s.lineWidth) / 2
        switch s.kind {
        case .rect, .ellipse:
            return s.fill ? s.rect.standardized : s.rect.standardized.insetBy(dx: -half, dy: -half)
        case .highlight:
            return s.rect.standardized
        case .line, .arrow, .freehand:
            guard let first = s.points.first else { return .null }
            var r = CGRect(origin: first, size: .zero)
            for p in s.points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
            let pad = s.kind == .arrow ? max(half, max(12, CGFloat(s.lineWidth) * 4)) : half
            return r.insetBy(dx: -pad, dy: -pad)
        case .text:
            let font = font(for: s)
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
            let lines = s.text.components(separatedBy: "\n")
            let width = lines.map { line -> CGFloat in
                let ct = CTLineCreateWithAttributedString(attributed(line, font: font, color: s.color.cgColor))
                return CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
            }.max() ?? 0
            let height = CGFloat(lines.count) * (ascent + descent + leading) - leading
            return CGRect(x: s.rect.minX, y: s.rect.minY, width: max(width, 1), height: max(height, 1))
        }
    }

    /// Hit test at `p` with `tolerance` image pixels.
    public static func hitTest(_ s: Annotation, at p: CGPoint, tolerance: CGFloat) -> Bool {
        let half = CGFloat(s.lineWidth) / 2
        switch s.kind {
        case .highlight, .text:
            return bounds(of: s).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .rect:
            let r = s.rect.standardized
            if s.fill { return r.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
            let outer = r.insetBy(dx: -(half + tolerance), dy: -(half + tolerance))
            let inner = r.insetBy(dx: half + tolerance, dy: half + tolerance)
            return outer.contains(p) && (inner.isNull || inner.width <= 0 || inner.height <= 0 || !inner.contains(p))
        case .ellipse:
            let r = s.rect.standardized
            guard r.width > 0, r.height > 0 else { return false }
            let rx = r.width / 2, ry = r.height / 2
            let dx = p.x - r.midX, dy = p.y - r.midY
            let d = sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry))   // 1 on the outline
            if s.fill { return d <= 1 + tolerance / min(rx, ry) }
            return abs(d - 1) * min(rx, ry) <= half + tolerance
        case .line, .arrow, .freehand:
            guard s.points.count >= 2 else { return false }
            for i in 1..<s.points.count where distance(p, segment: s.points[i - 1], s.points[i]) <= half + tolerance {
                return true
            }
            return false
        }
    }

    public static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Drops freehand samples closer than `minDistance` to the previous kept one (always keeps the last).
    public static func simplify(_ points: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var out = [points[0]]
        for p in points.dropFirst().dropLast() where hypot(p.x - out.last!.x, p.y - out.last!.y) >= minDistance {
            out.append(p)
        }
        out.append(points.last!)
        return out
    }
}
