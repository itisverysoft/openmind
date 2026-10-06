import Foundation
import CoreGraphics
import SwiftUI

enum ItemKind: String, CaseIterable, Identifiable {
    case sticky, text, shape, drawing, image, table, note, pdf, audio, youtube, video

    var id: String { rawValue }

    /// Size (in world points) of a newly created item.
    var defaultSize: CGSize {
        switch self {
        case .sticky: return CGSize(width: 160, height: 160)
        case .text:   return CGSize(width: 240, height: 60)
        case .shape:  return CGSize(width: 180, height: 120)
        case .drawing: return CGSize(width: 200, height: 200)
        case .image: return CGSize(width: 280, height: 210)
        case .table: return CGSize(width: 360, height: 220)
        case .note: return CGSize(width: 48, height: 48)
        case .pdf: return CGSize(width: 420, height: 560)
        case .audio: return CGSize(width: 300, height: 110)
        case .youtube: return CGSize(width: 480, height: 300)
        case .video: return CGSize(width: 480, height: 300)
        }
    }

    var defaultFontSize: Double {
        switch self {
        case .sticky: return 18
        case .text:   return 24
        case .shape:  return 18
        case .drawing: return 18
        case .image: return 18
        case .table: return 14
        case .note: return 14
        case .pdf: return 18
        case .audio: return 14
        case .youtube: return 13
        case .video: return 13
        }
    }

    /// Faint hint text shown when the item is empty.
    var placeholder: String {
        switch self {
        case .sticky: return "Note"
        case .text:   return "Text"
        case .shape:  return ""
        case .drawing: return ""
        case .image: return "Image"
        case .table: return "Table"
        case .note: return "Write a note…"
        case .pdf: return "PDF"
        case .audio: return "Audio"
        case .youtube: return "Paste a YouTube URL…"
        case .video: return "Video"
        }
    }

    /// Drawings, images and PDFs have no text content and can't be
    /// text-edited. Tables edit per-cell through their own grid UI (see
    /// TableItemView), and pin notes edit through their card UI (see
    /// NoteItemView), so both stay out of the plain TextEditor path.
    var isTextEditable: Bool {
        switch self {
        case .sticky, .text, .shape: return true
        case .drawing, .image, .table, .note, .pdf, .audio, .youtube, .video: return false
        }
    }

    /// Double-tap enters an editing mode (plain text, table grid, note card).
    var isEditable: Bool {
        switch self {
        case .sticky, .text, .shape, .table, .note, .youtube: return true
        case .drawing, .image, .pdf, .audio, .video: return false
        }
    }
}

enum ShapeKind: String, CaseIterable, Identifiable {
    case rectangle
    case roundedRectangle
    case ellipse
    case triangle
    case rightTriangle
    case diamond
    case pentagon
    case hexagon
    case circle
    case star
    case cloud
    case line
    case arrow
    case doubleArrow
    case capsule

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle:        return "Rectangle"
        case .roundedRectangle: return "Rounded Rectangle"
        case .ellipse:          return "Ellipse"
        case .triangle:         return "Triangle"
        case .rightTriangle:    return "Right Triangle"
        case .diamond:          return "Diamond"
        case .pentagon:         return "Pentagon"
        case .hexagon:          return "Hexagon"
        case .circle:           return "Circle"
        case .star:             return "Star"
        case .cloud:            return "Cloud"
        case .line:             return "Line"
        case .arrow:            return "Arrow"
        case .doubleArrow:      return "Double Arrow"
        case .capsule:          return "Capsule"
        }
    }

    /// SF Symbol used in menus / fallback.
    var symbol: String {
        switch self {
        case .rectangle:        return "rectangle"
        case .roundedRectangle: return "rectangle.roundedtop"
        case .ellipse:          return "ellipse"
        case .triangle:         return "triangle"
        case .rightTriangle:    return "play"
        case .diamond:          return "diamond"
        case .pentagon:         return "pentagon"
        case .hexagon:          return "hexagon"
        case .circle:           return "circle"
        case .star:             return "star"
        case .cloud:            return "cloud"
        case .line:             return "line.diagonal"
        case .arrow:            return "arrow.up.right"
        case .doubleArrow:      return "arrow.up.left.and.arrow.down.right"
        case .capsule:          return "capsule"
        }
    }

    /// Line-only shapes render as strokes, everything else as filled figures.
    var isLineLike: Bool {
        switch self {
        case .line, .arrow, .doubleArrow: return true
        default: return false
        }
    }
}

// MARK: - Canvas shape figures

struct TriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct RightTriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct DiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

private func polygonPath(sides: Int, in rect: CGRect, rotation: CGFloat = -.pi / 2) -> Path {
    var p = Path()
    let cx = rect.midX, cy = rect.midY
    let rx = rect.width / 2, ry = rect.height / 2
    for i in 0..<sides {
        let a = rotation + CGFloat(i) * 2 * .pi / CGFloat(sides)
        let pt = CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

struct PentagonShape: Shape {
    func path(in rect: CGRect) -> Path { polygonPath(sides: 5, in: rect) }
}

struct HexagonShape: Shape {
    // Flat top/bottom (vertices left/right).
    func path(in rect: CGRect) -> Path { polygonPath(sides: 6, in: rect, rotation: 0) }
}

struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX, cy = rect.midY
        let outerX = rect.width / 2, outerY = rect.height / 2
        let innerX = outerX * 0.382, innerY = outerY * 0.382
        for i in 0..<10 {
            let a = -.pi / 2 + CGFloat(i) * .pi / 5
            let rx = (i % 2 == 0) ? outerX : innerX
            let ry = (i % 2 == 0) ? outerY : innerY
            let pt = CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Flat bottom, three humps on top (small–big–medium), smooth sides.
        let w = rect.width, h = rect.height
        let bottomY = rect.maxY - h * 0.14
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + w * 0.14, y: bottomY))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.86, y: bottomY))
        // Right side up to the small right hump.
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.97, y: h * 0.55),
                   control1: CGPoint(x: rect.minX + w * 0.95, y: bottomY),
                   control2: CGPoint(x: rect.minX + w * 0.99, y: h * 0.70))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.78, y: h * 0.30),
                   control1: CGPoint(x: rect.minX + w * 0.96, y: h * 0.40),
                   control2: CGPoint(x: rect.minX + w * 0.90, y: h * 0.28))
        // Big middle hump.
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.50, y: h * 0.16),
                   control1: CGPoint(x: rect.minX + w * 0.70, y: h * 0.14),
                   control2: CGPoint(x: rect.minX + w * 0.62, y: h * 0.08))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.28, y: h * 0.30),
                   control1: CGPoint(x: rect.minX + w * 0.40, y: h * 0.10),
                   control2: CGPoint(x: rect.minX + w * 0.34, y: h * 0.16))
        // Left side back down to the bottom edge.
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.03, y: h * 0.58),
                   control1: CGPoint(x: rect.minX + w * 0.16, y: h * 0.32),
                   control2: CGPoint(x: rect.minX + w * 0.02, y: h * 0.42))
        p.addCurve(to: CGPoint(x: rect.minX + w * 0.14, y: bottomY),
                   control1: CGPoint(x: rect.minX + w * 0.04, y: h * 0.72),
                   control2: CGPoint(x: rect.minX + w * 0.06, y: bottomY))
        p.closeSubpath()
        return p
    }
}

// MARK: Line-like helpers (unit space, diagonal bottom-left -> top-right)

enum ShapeArrow {
    static let headLength: CGFloat = 0.22
    static let headWidth: CGFloat = 0.10

    static func tipTopRight(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.maxX, y: rect.minY)
    }

    static func tailBottomLeft(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX, y: rect.maxY)
    }

    static func head(tip: CGPoint, angle: CGFloat, size: CGFloat) -> Path {
        let len = max(8, size * headLength)
        let half = max(4, size * headWidth)
        let base = CGPoint(x: tip.x - len * cos(angle), y: tip.y - len * sin(angle))
        let perp = angle + .pi / 2
        let p1 = CGPoint(x: base.x + half * cos(perp), y: base.y + half * sin(perp))
        let p2 = CGPoint(x: base.x - half * cos(perp), y: base.y - half * sin(perp))
        var p = Path()
        p.move(to: tip)
        p.addLine(to: p1)
        p.addLine(to: p2)
        p.closeSubpath()
        return p
    }
}

/// Small outline preview of a shape for the shapes toolbar.
/// Symmetric figures render in a centered square so they stay regular
/// inside the wide (24×18) toolbar cell; wide figures fill the full cell.
struct ShapeIcon: View {
    var kind: ShapeKind
    var lineWidth: CGFloat = 1.6

    var body: some View {
        switch kind {
        case .rectangle:
            Rectangle().stroke(lineWidth: lineWidth)
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: 5).stroke(lineWidth: lineWidth)
        case .ellipse:
            Ellipse().stroke(lineWidth: lineWidth)
        case .triangle:
            TriangleShape().stroke(lineWidth: lineWidth).padding(.horizontal, 3)
        case .rightTriangle:
            RightTriangleShape().stroke(lineWidth: lineWidth).padding(.horizontal, 3)
        case .diamond:
            DiamondShape().stroke(lineWidth: lineWidth).padding(.horizontal, 3)
        case .pentagon:
            PentagonShape().stroke(lineWidth: lineWidth).padding(.horizontal, 3)
        case .hexagon:
            HexagonShape().stroke(lineWidth: lineWidth).padding(.horizontal, 3)
        case .circle:
            Circle().stroke(lineWidth: lineWidth).padding(.horizontal, 3)
        case .star:
            StarShape().stroke(lineWidth: lineWidth).padding(.horizontal, 3)
        case .cloud:
            CloudShape().stroke(lineWidth: lineWidth)
        case .capsule:
            Capsule().stroke(lineWidth: lineWidth)
        case .line, .arrow, .doubleArrow:
            lineIcon
        }
    }

    @ViewBuilder
    private var lineIcon: some View {
        GeometryReader { geo in
            let rect = geo.frame(in: .local).insetBy(dx: 2, dy: 2)
            let tail = ShapeArrow.tailBottomLeft(in: rect)
            let tip = ShapeArrow.tipTopRight(in: rect)
            let angle = atan2(tip.y - tail.y, tip.x - tail.x)
            let size = min(rect.width, rect.height)
            Path { p in
                p.move(to: tail)
                p.addLine(to: tip)
            }
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if kind == .arrow || kind == .doubleArrow {
                ShapeArrow.head(tip: tip, angle: angle, size: size * 2).fill()
            }
            if kind == .doubleArrow {
                ShapeArrow.head(tip: tail, angle: angle + .pi, size: size * 2).fill()
            }
        }
    }
}
