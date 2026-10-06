import Foundation
import CoreGraphics

/// Vector export for the Export menu: current-page items as a standalone
/// `.svg` file (background + shapes + text + embedded images).
///
/// Fidelity notes: `.text` boxes export as plain text (rich traits live in
/// RTF and don't survive the trip — table cells keep theirs, since those
/// are structured); empty text renders nothing rather than baking in the
/// canvas placeholder.
enum BoardSVG {
    static let fontFamily = "-apple-system, 'SF Pro Text', Helvetica, Arial, sans-serif"
}

/// Shortest exact decimal for SVG coordinates.
func svgN(_ v: Double) -> String { String(format: "%g", v) }
func svgN(_ v: CGFloat) -> String { svgN(Double(v)) }

/// XML-escapes free text (item content, file names).
func svgEscape(_ text: String) -> String {
    var out = text
    out = out.replacingOccurrences(of: "&", with: "&amp;")
    out = out.replacingOccurrences(of: "<", with: "&lt;")
    out = out.replacingOccurrences(of: ">", with: "&gt;")
    out = out.replacingOccurrences(of: "\"", with: "&quot;")
    return out
}

/// `#RRGGBB` fill from a stored hex (`Palette.autoInk` resolves to black,
///
/// the light-mode ink exports always assume).
func svgFill(_ hex: String) -> String {
    if hex.uppercased() == Palette.autoInk { return "#000000" }
    return "#\(hex)"
}

/// Full standalone SVG document for `items` inside `bounds`.
func svgDocument(items: [CanvasItem], bounds: CGRect, backgroundHex: String) -> String {
    var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    s += "<svg xmlns=\"http://www.w3.org/2000/svg\""
    s += " width=\"\(svgN(bounds.width))\" height=\"\(svgN(bounds.height))\""
    s += " viewBox=\"\(svgN(bounds.minX)) \(svgN(bounds.minY)) \(svgN(bounds.width)) \(svgN(bounds.height))\""
    s += " font-family=\"\(BoardSVG.fontFamily)\">\n"
    s += "<rect x=\"\(svgN(bounds.minX))\" y=\"\(svgN(bounds.minY))\""
    s += " width=\"\(svgN(bounds.width))\" height=\"\(svgN(bounds.height))\""
    s += " fill=\"\(svgFill(backgroundHex))\"/>\n"
    for (index, item) in items.sorted(by: { $0.zIndex < $1.zIndex }).enumerated() {
        s += svgItem(item, clipID: "clip\(index)")
    }
    s += "</svg>\n"
    return s
}

private func svgItem(_ item: CanvasItem, clipID: String) -> String {
    switch item.kind {
    case .sticky, .text, .shape:
        return svgTextBox(item)
    case .drawing:
        return svgDrawing(item)
    case .image:
        return svgImage(item, clipID: clipID)
    case .table:
        return svgTable(item)
    case .note:
        return svgNote(item)
    case .pdf:
        return svgPDF(item)
    case .audio:
        return svgAudio(item)
    case .video:
        return svgVideo(item)
    case .youtube:
        return svgYouTube(item)
    }
}

// MARK: - Text boxes (sticky / text / shape)

/// Plain-text lines with an SVG anchor/position for the box's alignment.
private func svgTextLines(_ text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat,
                          anchor: String, fill: String) -> String {
    let lines = text.components(separatedBy: "\n")
    guard !lines.allSatisfy({ $0.isEmpty }) else { return "" }
    var s = "<text x=\"\(svgN(x))\" y=\"\(svgN(y))\""
    s += " font-size=\"\(svgN(fontSize))\" text-anchor=\"\(anchor)\" fill=\"\(fill)\">"
    for (i, line) in lines.enumerated() {
        if i == 0 {
            s += svgEscape(line)
        } else {
            s += "<tspan x=\"\(svgN(x))\" dy=\"\(svgN(fontSize * 1.25))\">\(svgEscape(line))</tspan>"
        }
    }
    s += "</text>\n"
    return s
}

private func svgTextBox(_ item: CanvasItem) -> String {
    let x = CGFloat(item.x), y = CGFloat(item.y)
    let w = CGFloat(item.width), h = CGFloat(item.height)
    var s = ""
    let fill = svgFill(item.colorHex)
    switch item.shape {
    case .rectangle:
        s += "<rect x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\" fill=\"\(fill)\"/>\n"
    case .roundedRectangle:
        s += "<rect x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\" rx=\"16\" fill=\"\(fill)\"/>\n"
    case .ellipse:
        s += "<ellipse cx=\"\(svgN(x + w / 2))\" cy=\"\(svgN(y + h / 2))\" rx=\"\(svgN(w / 2))\" ry=\"\(svgN(h / 2))\" fill=\"\(fill)\"/>\n"
    case .capsule:
        s += "<rect x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\" rx=\"\(svgN(min(w, h) / 2))\" fill=\"\(fill)\"/>\n"
    case .triangle, .rightTriangle, .diamond, .pentagon, .hexagon, .circle, .star, .cloud:
        // Sticky/text kinds always use `.rectangle`; anything else is a real
        // shape figure (see below). Fall through to the figure renderer so
        // text-on-shape keeps its backdrop.
        s += svgShapeFigure(item)
    case .line, .arrow, .doubleArrow:
        // Unreachable for text boxes (they never take line shapes), but the
        // figure renderer handles them anyway.
        s += svgLineFigure(item)
    }
    // Sticky/text/shape labels all render black on canvas (light mode).
    let fs = CGFloat(item.fontSize)
    if item.kind == .shape, !item.text.isEmpty {
        s += svgTextLines(item.text, x: x + w / 2, y: y + h / 2 - fs / 2,
                          fontSize: fs, anchor: "middle", fill: "#000000")
    } else if item.kind != .shape {
        s += svgTextLines(item.text, x: x + 10, y: y + 10 + fs,
                          fontSize: fs, anchor: "start", fill: "#000000")
    }
    return s
}

// MARK: - Shape figures

/// Regular-polygon vertices mirroring `polygonPath(sides:rotation:)`.
func svgPolygonPoints(sides: Int, in rect: CGRect, rotation: CGFloat = -.pi / 2) -> [CGPoint] {
    let cx = rect.midX, cy = rect.midY
    let rx = rect.width / 2, ry = rect.height / 2
    return (0..<sides).map { i in
        let a = rotation + CGFloat(i) * 2 * .pi / CGFloat(sides)
        return CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
    }
}

private func svgPointsAttr(_ pts: [CGPoint]) -> String {
    pts.map { "\(svgN($0.x)),\(svgN($0.y))" }.joined(separator: " ")
}

/// Star vertices mirroring `StarShape` (alternating outer/inner radius).
func svgStarPoints(in rect: CGRect) -> [CGPoint] {
    let cx = rect.midX, cy = rect.midY
    let outerX = rect.width / 2, outerY = rect.height / 2
    let innerX = outerX * 0.382, innerY = outerY * 0.382
    return (0..<10).map { i in
        let a = -.pi / 2 + CGFloat(i) * .pi / 5
        let rx = (i % 2 == 0) ? outerX : innerX
        let ry = (i % 2 == 0) ? outerY : innerY
        return CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
    }
}

/// Cloud outline mirroring `CloudShape` as cubic segments.
func svgCloudPath(in rect: CGRect) -> String {
    let w = rect.width, h = rect.height
    let x = rect.minX
    let bottomY = rect.maxY - h * 0.14
    var d = "M\(svgN(x + w * 0.14)),\(svgN(bottomY))"
    d += "L\(svgN(x + w * 0.86)),\(svgN(bottomY))"
    d += "C\(svgN(x + w * 0.95)),\(svgN(bottomY)) \(svgN(x + w * 0.99)),\(svgN(h * 0.70)) \(svgN(x + w * 0.97)),\(svgN(h * 0.55))"
    d += "C\(svgN(x + w * 0.96)),\(svgN(h * 0.40)) \(svgN(x + w * 0.90)),\(svgN(h * 0.28)) \(svgN(x + w * 0.78)),\(svgN(h * 0.30))"
    d += "C\(svgN(x + w * 0.70)),\(svgN(h * 0.14)) \(svgN(x + w * 0.62)),\(svgN(h * 0.08)) \(svgN(x + w * 0.50)),\(svgN(h * 0.16))"
    d += "C\(svgN(x + w * 0.40)),\(svgN(h * 0.10)) \(svgN(x + w * 0.34)),\(svgN(h * 0.16)) \(svgN(x + w * 0.28)),\(svgN(h * 0.30))"
    d += "C\(svgN(x + w * 0.16)),\(svgN(h * 0.32)) \(svgN(x + w * 0.02)),\(svgN(h * 0.42)) \(svgN(x + w * 0.03)),\(svgN(h * 0.58))"
    d += "C\(svgN(x + w * 0.04)),\(svgN(h * 0.72)) \(svgN(x + w * 0.06)),\(svgN(bottomY)) \(svgN(x + w * 0.14)),\(svgN(bottomY))Z"
    return d
}

private func svgShapeFigure(_ item: CanvasItem) -> String {
    let rect = item.frameRect
    let fill = svgFill(item.colorHex)
    switch item.shape {
    case .triangle:
        let pts = [CGPoint(x: rect.midX, y: rect.minY),
                   CGPoint(x: rect.maxX, y: rect.maxY),
                   CGPoint(x: rect.minX, y: rect.maxY)]
        return "<polygon points=\"\(svgPointsAttr(pts))\" fill=\"\(fill)\"/>\n"
    case .rightTriangle:
        let pts = [CGPoint(x: rect.minX, y: rect.minY),
                   CGPoint(x: rect.minX, y: rect.maxY),
                   CGPoint(x: rect.maxX, y: rect.maxY)]
        return "<polygon points=\"\(svgPointsAttr(pts))\" fill=\"\(fill)\"/>\n"
    case .diamond:
        let pts = [CGPoint(x: rect.midX, y: rect.minY),
                   CGPoint(x: rect.maxX, y: rect.midY),
                   CGPoint(x: rect.midX, y: rect.maxY),
                   CGPoint(x: rect.minX, y: rect.midY)]
        return "<polygon points=\"\(svgPointsAttr(pts))\" fill=\"\(fill)\"/>\n"
    case .pentagon:
        return "<polygon points=\"\(svgPointsAttr(svgPolygonPoints(sides: 5, in: rect)))\" fill=\"\(fill)\"/>\n"
    case .hexagon:
        return "<polygon points=\"\(svgPointsAttr(svgPolygonPoints(sides: 6, in: rect, rotation: 0)))\" fill=\"\(fill)\"/>\n"
    case .circle:
        return "<circle cx=\"\(svgN(rect.midX))\" cy=\"\(svgN(rect.midY))\" r=\"\(svgN(min(rect.width, rect.height) / 2))\" fill=\"\(fill)\"/>\n"
    case .star:
        return "<polygon points=\"\(svgPointsAttr(svgStarPoints(in: rect)))\" fill=\"\(fill)\"/>\n"
    case .cloud:
        return "<path d=\"\(svgCloudPath(in: rect))\" fill=\"\(fill)\"/>\n"
    case .rectangle, .roundedRectangle, .ellipse, .capsule:
        return ""
    case .line, .arrow, .doubleArrow:
        return svgLineFigure(item)
    }
}

/// Normalized box-fraction endpoints → absolute points (or the legacy fixed
/// diagonal for items that predate endpoint storage).
func svgLineEnds(_ item: CanvasItem) -> (tail: CGPoint, tip: CGPoint) {
    let rect = item.frameRect
    let pts = item.lineEndpoints
    if pts.count >= 2 {
        return (CGPoint(x: rect.minX + pts[0].x * rect.width,
                        y: rect.minY + pts[0].y * rect.height),
                CGPoint(x: rect.minX + pts[1].x * rect.width,
                        y: rect.minY + pts[1].y * rect.height))
    }
    return (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY))
}

private func svgArrowHead(tip: CGPoint, angle: CGFloat, size: CGFloat, fill: String) -> String {
    // Same wings as ShapeArrow.head.
    let len = max(8, size * 0.22)
    let half = max(4, size * 0.10)
    let base = CGPoint(x: tip.x - len * cos(angle), y: tip.y - len * sin(angle))
    let perp = angle + .pi / 2
    let p1 = CGPoint(x: base.x + half * cos(perp), y: base.y + half * sin(perp))
    let p2 = CGPoint(x: base.x - half * cos(perp), y: base.y - half * sin(perp))
    return "<polygon points=\"\(svgPointsAttr([tip, p1, p2]))\" fill=\"\(fill)\"/>\n"
}

private func svgLineFigure(_ item: CanvasItem) -> String {
    let fill = svgFill(item.colorHex)
    let (tail, tip) = svgLineEnds(item)
    let angle = atan2(tip.y - tail.y, tip.x - tail.x)
    let len = hypot(tip.x - tail.x, tip.y - tail.y)
    let headSize = min(max(len * 0.25, 24), 120)
    var s = "<line x1=\"\(svgN(tail.x))\" y1=\"\(svgN(tail.y))\""
    s += " x2=\"\(svgN(tip.x))\" y2=\"\(svgN(tip.y))\""
    s += " stroke=\"\(fill)\" stroke-width=\"4\" stroke-linecap=\"round\"/>\n"
    if (item.shape == .arrow || item.shape == .doubleArrow) && len > 0.5 {
        s += svgArrowHead(tip: tip, angle: angle, size: headSize, fill: fill)
    }
    if item.shape == .doubleArrow && len > 0.5 {
        s += svgArrowHead(tip: tail, angle: angle + .pi, size: headSize, fill: fill)
    }
    return s
}

// MARK: - Drawings

private func svgDrawing(_ item: CanvasItem) -> String {
    let ox = CGFloat(item.x), oy = CGFloat(item.y)
    let pts = item.strokePoints.map { CGPoint(x: $0.x + ox, y: $0.y + oy) }
    guard pts.count >= 2 else { return "" }
    let stroke = svgFill(item.colorHex)
    let w = svgN(item.lineWidth)
    var s = ""
    if item.strokeStyle.isStraight {
        let a = pts.first!, b = pts.last!
        s += "<line x1=\"\(svgN(a.x))\" y1=\"\(svgN(a.y))\""
        s += " x2=\"\(svgN(b.x))\" y2=\"\(svgN(b.y))\""
        s += " stroke=\"\(stroke)\" stroke-width=\"\(w)\" stroke-linecap=\"round\"/>\n"
        if item.strokeStyle == .arrow {
            let angle = atan2(b.y - a.y, b.x - a.x)
            let (base, p1, p2) = arrowHeadGeometry(tip: b, angle: angle,
                                                   lineWidth: CGFloat(item.lineWidth))
            _ = base
            s += "<polygon points=\"\(svgPointsAttr([b, p1, p2]))\" fill=\"\(stroke)\"/>\n"
        }
    } else {
        s += "<polyline points=\"\(svgPointsAttr(pts))\" fill=\"none\""
        s += " stroke=\"\(stroke)\" stroke-width=\"\(w)\""
        s += " stroke-linecap=\"round\" stroke-linejoin=\"round\""
        if item.strokeStyle == .highlighter { s += " opacity=\"0.45\"" }
        s += "/>\n"
    }
    return s
}

// MARK: - Images

/// Sniffed MIME type for an `<image>` data URI. Nil for unrecognized bytes
/// (the caller draws a placeholder instead of a lying extension).
func svgImageMIME(_ data: Data) -> String? {
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if data.starts(with: Data("GIF8".utf8)) { return "image/gif" }
    return nil
}

private func svgImage(_ item: CanvasItem, clipID: String) -> String {
    let x = CGFloat(item.x), y = CGFloat(item.y)
    let w = CGFloat(item.width), h = CGFloat(item.height)
    guard let data = item.imageData, !data.isEmpty,
          let mime = svgImageMIME(data) else {
        return "<rect x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\""
            + " fill=\"#E4E4E4\"/>\n"
    }
    // scaledToFill + tile clip, mirroring the canvas tile.
    var s = "<clipPath id=\"\(clipID)\">"
    s += "<rect x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\"/></clipPath>\n"
    s += "<image x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\""
    s += " preserveAspectRatio=\"xMidYMid slice\" clip-path=\"url(#\(clipID))\""
    s += " href=\"data:\(mime);base64,\(data.base64EncodedString())\"/>\n"
    return s
}

// MARK: - Tables / notes / PDFs / audio

private func svgTable(_ item: CanvasItem) -> String {
    let t = item.getTable()
    let x = CGFloat(item.x), y = CGFloat(item.y)
    let w = CGFloat(item.width), h = CGFloat(item.height)
    guard t.rows > 0, t.cols > 0 else { return "" }
    let rowH = h / CGFloat(t.rows)
    var s = "<rect x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\" fill=\"#FFFFFF\" stroke=\"#CCCCCC\"/>\n"
    var cx = x
    let colW = t.colFractions.map { CGFloat($0) * w }
    for c in 0..<t.cols {
        let cw = c < colW.count ? colW[c] : w / CGFloat(t.cols)
        for r in 0..<t.rows {
            let cy = y + CGFloat(r) * rowH
            let style = t.styleAt(row: r, col: c)
            if t.isHeaderCell(row: r) {
                s += "<rect x=\"\(svgN(cx))\" y=\"\(svgN(cy))\" width=\"\(svgN(cw))\" height=\"\(svgN(rowH))\" fill=\"#EFEFEF\" stroke=\"#CCCCCC\"/>\n"
            } else {
                if let bg = style.backgroundHex {
                    s += "<rect x=\"\(svgN(cx))\" y=\"\(svgN(cy))\" width=\"\(svgN(cw))\" height=\"\(svgN(rowH))\" fill=\"\(svgFill(bg))\" stroke=\"#CCCCCC\"/>\n"
                } else {
                    s += "<rect x=\"\(svgN(cx))\" y=\"\(svgN(cy))\" width=\"\(svgN(cw))\" height=\"\(svgN(rowH))\" fill=\"none\" stroke=\"#CCCCCC\"/>\n"
                }
            }
            let fs = CGFloat(style.fontSize ?? item.fontSize)
            let text = t[row: r, col: c]
            guard !text.isEmpty else { continue }
            let anchor: String
            let tx: CGFloat
            switch style.alignmentRaw {
            case "center": anchor = "middle"; tx = cx + cw / 2
            case "right": anchor = "end"; tx = cx + cw - 4
            default: anchor = "start"; tx = cx + 4
            }
            var open = "<text x=\"\(svgN(tx))\" y=\"\(svgN(cy + 4 + fs))\" font-size=\"\(svgN(fs))\""
            open += " text-anchor=\"\(anchor)\" fill=\"\(svgFill(style.colorHex ?? Palette.autoInk))\""
            if style.bold { open += " font-weight=\"bold\"" }
            if style.italic { open += " font-style=\"italic\"" }
            if style.underline { open += " text-decoration=\"underline\"" }
            else if style.strikethrough { open += " text-decoration=\"line-through\"" }
            open += ">"
            s += open + svgEscape(text) + "</text>\n"
        }
        cx += cw
    }
    return s
}

private func svgNote(_ item: CanvasItem) -> String {
    let rect = item.frameRect
    return "<circle cx=\"\(svgN(rect.midX))\" cy=\"\(svgN(rect.midY))\""
        + " r=\"\(svgN(min(rect.width, rect.height) / 2))\" fill=\"\(svgFill(item.colorHex))\"/>\n"
}

private func svgPDF(_ item: CanvasItem) -> String {
    let x = CGFloat(item.x), y = CGFloat(item.y)
    let w = CGFloat(item.width), h = CGFloat(item.height)
    var s = "<rect x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\""
    s += " fill=\"#FFFFFF\" stroke=\"#CCCCCC\"/>\n"
    s += svgTextLines("PDF · page \(item.clampedPDFPage + 1)",
                      x: x + w / 2, y: y + h / 2, fontSize: 14,
                      anchor: "middle", fill: "#888888")
    return s
}

private func svgAudio(_ item: CanvasItem) -> String {
    let x = CGFloat(item.x), y = CGFloat(item.y)
    let w = CGFloat(item.width), h = CGFloat(item.height)
    var s = "<rect x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\" rx=\"8\""
    s += " fill=\"#F2F2F2\" stroke=\"#CCCCCC\"/>\n"
    let name = item.audioFileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = name.isEmpty ? "Audio" : (name as NSString).deletingPathExtension
    s += svgTextLines("\(title)\n\(formatAudioDuration(item.audioDuration))",
                      x: x + 10, y: y + 10 + 13, fontSize: 13,
                      anchor: "start", fill: "#333333")
    return s
}

private func svgVideo(_ item: CanvasItem) -> String {
    let x = CGFloat(item.x), y = CGFloat(item.y)
    let w = CGFloat(item.width), h = CGFloat(item.height)
    var s = "<rect x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\" rx=\"8\""
    s += " fill=\"#111111\" stroke=\"#CCCCCC\"/>\n"
    // Centered play badge.
    let cx = x + w / 2, cy = y + h / 2 - 8
    let bw: CGFloat = 56, bh: CGFloat = 40
    s += "<rect x=\"\(svgN(cx - bw / 2))\" y=\"\(svgN(cy - bh / 2))\" width=\"\(svgN(bw))\" height=\"\(svgN(bh))\" rx=\"8\" fill=\"#FFFFFF\" opacity=\"0.9\"/>\n"
    s += "<polygon points=\"\(svgN(cx - 7)),\(svgN(cy - 10)) \(svgN(cx - 7)),\(svgN(cy + 10)) \(svgN(cx + 10)),\(svgN(cy))\" fill=\"#111111\"/>\n"
    let name = item.videoFileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = name.isEmpty ? "Video" : name
    s += svgTextLines("\(title)\n\(formatAudioDuration(item.videoDuration))",
                      x: x + w / 2, y: y + h - 26, fontSize: 12,
                      anchor: "middle", fill: "#FFFFFF")
    return s
}

private func svgYouTube(_ item: CanvasItem) -> String {
    let x = CGFloat(item.x), y = CGFloat(item.y)
    let w = CGFloat(item.width), h = CGFloat(item.height)
    var s = "<rect x=\"\(svgN(x))\" y=\"\(svgN(y))\" width=\"\(svgN(w))\" height=\"\(svgN(h))\" rx=\"8\""
    s += " fill=\"#000000\" stroke=\"#CCCCCC\"/>\n"
    // Red play badge, centered.
    let cx = x + w / 2, cy = y + h / 2 - 8
    let bw: CGFloat = 56, bh: CGFloat = 40
    s += "<rect x=\"\(svgN(cx - bw / 2))\" y=\"\(svgN(cy - bh / 2))\" width=\"\(svgN(bw))\" height=\"\(svgN(bh))\" rx=\"8\" fill=\"#FF0000\"/>\n"
    s += "<polygon points=\"\(svgN(cx - 7)),\(svgN(cy - 10)) \(svgN(cx - 7)),\(svgN(cy + 10)) \(svgN(cx + 10)),\(svgN(cy))\" fill=\"#FFFFFF\"/>\n"
    if let id = youtubeVideoID(from: item.youtubeURL),
       let watch = youtubeWatchURL(for: id)?.absoluteString {
        s += "<a href=\"\(svgEscape(watch))\">"
        s += svgTextLines("youtube.com/watch?v=\(id)",
                          x: x + w / 2, y: y + h - 18, fontSize: 12,
                          anchor: "middle", fill: "#FFFFFF")
        s += "</a>\n"
    } else {
        s += svgTextLines("YouTube video",
                          x: x + w / 2, y: y + h - 18, fontSize: 12,
                          anchor: "middle", fill: "#BBBBBB")
    }
    return s
}
