import SwiftUI

/// Vector stroke renderer. Points are in the item's local space (world units);
/// everything is multiplied by `scale` so strokes stay sharp at any zoom,
/// matching the ItemBodyView rendering contract.
struct DrawingStrokeView: View {
    var points: [CGPoint]
    var style: DrawingStyle
    var colorHex: String
    var lineWidth: CGFloat
    var scale: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color {
        Color.ink(hex: colorHex, for: colorScheme).opacity(style.opacity)
    }

    var body: some View {
        strokePath
            .stroke(ink,
                    style: StrokeStyle(lineWidth: max(0.5, lineWidth * scale),
                                       lineCap: .round, lineJoin: .round))
            .overlay {
                if let head = arrowHead {
                    head.fill(ink)
                }
            }
    }

    /// The shaft in on-screen points. For arrows it stops at the head's base
    /// so the round cap stays tucked inside the head instead of poking past
    /// the tip.
    private var strokePath: Path {
        var path = Path()
        let scaled = points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        if style == .arrow,
           let angle = finalSegmentAngle(points),
           let tip = scaled.last {
            let (base, _, _) = scaledHead(tip: tip, angle: angle)
            path.move(to: scaled.first!)
            // Committed arrows store just endpoints, but tolerate polylines.
            for point in scaled.dropFirst().dropLast() {
                path.addLine(to: point)
            }
            path.addLine(to: base)
        } else if style.isStraight {
            guard let first = scaled.first, let last = scaled.last else { return path }
            path.move(to: first)
            path.addLine(to: last)
        } else {
            guard let first = scaled.first else { return path }
            path.move(to: first)
            for point in scaled.dropFirst() {
                path.addLine(to: point)
            }
        }
        return path
    }

    /// Filled arrow head at the last point, pointing along the final segment.
    private var arrowHead: Path? {
        guard style == .arrow,
              let angle = finalSegmentAngle(points),
              let tip = points.last.map({ CGPoint(x: $0.x * scale, y: $0.y * scale) })
        else { return nil }
        let (_, p1, p2) = scaledHead(tip: tip, angle: angle)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: p1)
        path.addLine(to: p2)
        path.closeSubpath()
        return path
    }

    private func scaledHead(tip: CGPoint, angle: CGFloat)
        -> (base: CGPoint, p1: CGPoint, p2: CGPoint)
    {
        arrowHeadGeometry(tip: tip, angle: angle, lineWidth: lineWidth * scale)
    }
}

/// Live in-progress stroke preview, drawn directly in screen space.
/// `lineWidth` is already in screen points.
struct LiveStrokePreview: View {
    var screenPoints: [CGPoint]
    var style: DrawingStyle
    var colorHex: String
    var lineWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color {
        Color.ink(hex: colorHex, for: colorScheme).opacity(style.opacity)
    }

    var body: some View {
        strokePath
            .stroke(ink,
                    style: StrokeStyle(lineWidth: max(1, lineWidth),
                                       lineCap: .round, lineJoin: .round))
            .overlay {
                if let head = arrowHead {
                    head.fill(ink)
                }
            }
    }

    private var strokePath: Path {
        var path = Path()
        if style == .arrow,
           let angle = finalSegmentAngle(screenPoints),
           let tip = screenPoints.last {
            let (base, _, _) = arrowHeadGeometry(tip: tip, angle: angle, lineWidth: lineWidth)
            path.move(to: screenPoints.first!)
            path.addLine(to: base)
        } else if style.isStraight {
            guard let first = screenPoints.first, let last = screenPoints.last else { return path }
            path.move(to: first)
            path.addLine(to: last)
        } else {
            guard let first = screenPoints.first else { return path }
            path.move(to: first)
            for point in screenPoints.dropFirst() {
                path.addLine(to: point)
            }
        }
        return path
    }

    private var arrowHead: Path? {
        guard style == .arrow,
              let angle = finalSegmentAngle(screenPoints),
              let tip = screenPoints.last
        else { return nil }
        let (_, p1, p2) = arrowHeadGeometry(tip: tip, angle: angle, lineWidth: lineWidth)
        var path = Path()
        path.move(to: tip)
        path.addLine(to: p1)
        path.addLine(to: p2)
        path.closeSubpath()
        return path
    }
}
