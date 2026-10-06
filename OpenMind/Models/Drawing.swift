import Foundation
import CoreGraphics

/// How a freehand drawing stroke looks and behaves.
enum DrawingStyle: String, CaseIterable, Identifiable {
    case pen, highlighter, line, arrow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen:         return "Pen"
        case .highlighter: return "Highlighter"
        case .line:        return "Line"
        case .arrow:       return "Arrow"
        }
    }

    /// SF Symbol used in menus.
    var symbol: String {
        switch self {
        case .pen:         return "pencil"
        case .highlighter: return "highlighter"
        case .line:        return "line.diagonal"
        case .arrow:       return "arrow.up.right"
        }
    }

    var defaultLineWidth: Double {
        switch self {
        case .pen:         return 4
        case .highlighter: return 12
        case .line:        return 4
        case .arrow:       return 4
        }
    }

    var opacity: Double {
        switch self {
        case .highlighter: return 0.45
        case .pen, .line, .arrow: return 1
        }
    }

    /// Straight-segment styles render only endpoints; the rest render the full polyline.
    var isStraight: Bool {
        switch self {
        case .line, .arrow: return true
        case .pen, .highlighter: return false
        }
    }
}

/// Active canvas interaction mode.
enum CanvasTool: Equatable {
    case select
    case hand
    case draw
    case erase
    /// Pin-note placement: the cursor turns into a crosshair and the next
    /// empty-canvas click drops a note pin there (see NoteItemView).
    case note
    /// Shape placement: the cursor turns into a crosshair and the next
    /// drag draws the shape's frame (Shift locks a square ratio).
    case shape(ShapeKind)

    var isDrawing: Bool {
        switch self {
        case .draw, .erase: return true
        case .select, .hand, .note, .shape: return false
        }
    }

    /// True while a shape frame is being placed.
    var isShapePlacing: Bool {
        if case .shape = self { return true }
        return false
    }

    /// The shape being placed, if any.
    var shapeKind: ShapeKind? {
        if case .shape(let kind) = self { return kind }
        return nil
    }
}

// MARK: - Stroke point codec (world points, relative to the item origin)

enum StrokeCodec {
    /// Encodes points as JSON `[[x, y]]` for SwiftData storage.
    static func encode(_ points: [CGPoint]) -> Data {
        let pairs = points.map { [$0.x, $0.y] }
        return (try? JSONEncoder().encode(pairs)) ?? Data()
    }

    static func decode(_ data: Data) -> [CGPoint] {
        guard !data.isEmpty,
              let pairs = try? JSONDecoder().decode([[CGFloat]].self, from: data) else {
            return []
        }
        return pairs.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
    }
}

// MARK: - Geometry helpers

/// Shortest distance from `p` to the segment `a`–`b` (all in the same space).
func distanceFromPointToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else {
        return hypot(p.x - a.x, p.y - a.y)
    }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

/// Arrowhead geometry for a shaft ending at `tip` with direction `angle`.
/// Returns the shaft's end point (head base) plus the two wing corners,
/// all in the caller's coordinate space. `lineWidth` is in the same space.
func arrowHeadGeometry(tip: CGPoint, angle: CGFloat, lineWidth: CGFloat)
    -> (base: CGPoint, p1: CGPoint, p2: CGPoint)
{
    let length = max(10, lineWidth * 3.5)
    let spread = CGFloat.pi / 6  // 30° each side
    let base = CGPoint(x: tip.x - length * cos(angle),
                       y: tip.y - length * sin(angle))
    let p1 = CGPoint(x: tip.x - length * cos(angle - spread),
                     y: tip.y - length * sin(angle - spread))
    let p2 = CGPoint(x: tip.x - length * cos(angle + spread),
                     y: tip.y - length * sin(angle + spread))
    return (base, p1, p2)
}

/// Direction angle of the final segment, or nil when the stroke is a dot.
func finalSegmentAngle(_ points: [CGPoint]) -> CGFloat? {
    guard points.count >= 2 else { return nil }
    let a = points[points.count - 2]
    let b = points[points.count - 1]
    guard hypot(b.x - a.x, b.y - a.y) > 0.001 else { return nil }
    return atan2(b.y - a.y, b.x - a.x)
}

/// True when `worldPoint` (in the item's local space) touches the stroke.
func polylineHitTest(points: [CGPoint], style: DrawingStyle, lineWidth: CGFloat,
                     at worldPoint: CGPoint, tolerance: CGFloat) -> Bool {
    guard points.count >= 2 else { return false }
    let padding = lineWidth / 2 + tolerance
    if style.isStraight {
        return distanceFromPointToSegment(worldPoint, points.first!, points.last!) <= padding
    }
    for i in points.indices.dropFirst() {
        if distanceFromPointToSegment(worldPoint, points[i - 1], points[i]) <= padding {
            return true
        }
    }
    return false
}

// MARK: - Partial eraser (pixel-like erasing for vector strokes)

/// Shortest distance between segments `p1`–`p2` and `q1`–`q2`.
/// Used so a fast eraser drag can't jump over a thin stroke between events.
func segmentSegmentDistance(_ p1: CGPoint, _ p2: CGPoint,
                            _ q1: CGPoint, _ q2: CGPoint) -> CGFloat {
    // Segments intersect → distance is zero.
    func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    func onSegment(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        min(a.x, c.x) <= b.x && b.x <= max(a.x, c.x) &&
        min(a.y, c.y) <= b.y && b.y <= max(a.y, c.y)
    }
    let o1 = orientation(p1, p2, q1)
    let o2 = orientation(p1, p2, q2)
    let o3 = orientation(q1, q2, p1)
    let o4 = orientation(q1, q2, p2)
    if ((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0)) &&
       ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0)) {
        return 0
    }
    // Collinear overlapping edge cases: treat touching projections as zero.
    if o1 == 0 && onSegment(p1, q1, p2) { return 0 }
    if o2 == 0 && onSegment(p1, q2, p2) { return 0 }
    if o3 == 0 && onSegment(q1, p1, q2) { return 0 }
    if o4 == 0 && onSegment(q1, p2, q2) { return 0 }
    return min(
        distanceFromPointToSegment(p1, q1, q2),
        distanceFromPointToSegment(p2, q1, q2),
        distanceFromPointToSegment(q1, p1, p2),
        distanceFromPointToSegment(q2, p1, p2)
    )
}

/// Splits a polyline stroke (world points) by an eraser segment `a`–`b`.
///
/// - Parameters:
///   - eraserWidth: eraser diameter in the same space as the points.
/// - Returns: `nil` when nothing was erased (caller can skip model churn),
///   otherwise the surviving runs (empty array = fully erased). Runs with
///   fewer than 2 points are already dropped since they cannot render.
func eraseRuns(worldPoints: [CGPoint], style: DrawingStyle, lineWidth: CGFloat,
               eraserA: CGPoint, eraserB: CGPoint, eraserWidth: CGFloat) -> [[CGPoint]]? {
    guard worldPoints.count >= 2, eraserWidth > 0 else { return nil }
    let eraseRadius = max(0.5, eraserWidth / 2)
    let effective = eraseRadius + lineWidth / 2

    if style.isStraight {
        guard let first = worldPoints.first, let last = worldPoints.last else { return nil }
        let hit = segmentSegmentDistance(first, last, eraserA, eraserB) <= effective
        return hit ? [] : nil
    }

    var erased = [Bool](repeating: false, count: worldPoints.count)
    var anyErased = false
    for i in worldPoints.indices {
        let p = worldPoints[i]
        if distanceFromPointToSegment(p, eraserA, eraserB) <= effective {
            erased[i] = true
            anyErased = true
        } else if i > 0 {
            // Catch thin segments whose endpoints straddle the eraser path.
            if segmentSegmentDistance(worldPoints[i - 1], p, eraserA, eraserB) <= effective {
                erased[i - 1] = true
                erased[i] = true
                anyErased = true
            }
        }
    }
    guard anyErased else { return nil }

    var runs: [[CGPoint]] = []
    var current: [CGPoint] = []
    for (i, p) in worldPoints.enumerated() {
        if erased[i] {
            if current.count >= 2 { runs.append(current) }
            current = []
        } else {
            current.append(p)
        }
    }
    if current.count >= 2 { runs.append(current) }
    return runs
}
