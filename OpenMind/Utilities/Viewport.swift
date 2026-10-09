import SwiftUI

enum CanvasMetrics {
    /// The canvas is a square world of this many points per side.
    static let worldSize: CGFloat = 10_000
    static var center: CGPoint { CGPoint(x: worldSize / 2, y: worldSize / 2) }
}

struct Viewport: Equatable {
    var offset: CGSize = .zero
    var scale: CGFloat = 1

    static let minScale: CGFloat = 0.2
    static let maxScale: CGFloat = 8

    /// Returns a new viewport after panning by `pan` and zooming by `zoom`
    /// (a multiplier) around the screen point `center`.
    func applying(pan: CGSize = .zero,
                  zoom: CGFloat = 1,
                  around center: CGPoint) -> Viewport {
        let newScale = min(max(scale * zoom, Viewport.minScale), Viewport.maxScale)
        let ratio = newScale / scale
        return Viewport(
            offset: CGSize(
                width: center.x - (center.x - offset.width) * ratio + pan.width,
                height: center.y - (center.y - offset.height) * ratio + pan.height
            ),
            scale: newScale
        )
    }

    /// Converts a point on screen (inside the canvas view) to world coordinates.
    func worldPoint(for screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - offset.width) / scale,
                y: (screen.y - offset.height) / scale)
    }

    /// Inverse of `worldPoint(for:)` — maps world coordinates back to
    /// canvas-local screen points (for anchor markers and previews).
    func screenPoint(for world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * scale + offset.width,
                y: world.y * scale + offset.height)
    }

    /// Converts a screen-space rect (canvas-local points) to world coordinates.
    /// The result is normalized (non-negative size) for hit-testing.
    func worldRect(for screenRect: CGRect) -> CGRect {
        let p0 = worldPoint(for: screenRect.origin)
        let p1 = worldPoint(for: CGPoint(x: screenRect.maxX, y: screenRect.maxY))
        return CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y),
                      width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
    }

    /// A viewport at 100% showing `world` at the middle of a view of `size`.
    static func centered(on world: CGPoint, in size: CGSize) -> Viewport {
        Viewport(
            offset: CGSize(width: size.width / 2 - world.x,
                           height: size.height / 2 - world.y),
            scale: 1
        )
    }
}

// MARK: - Marquee selection helpers (pure geometry, no models)

/// Builds a normalized screen-space rect from a drag's start and current points.
func marqueeScreenRect(from start: CGPoint, to current: CGPoint) -> CGRect {
    CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
           width: abs(current.x - start.x), height: abs(current.y - start.y))
}

/// Shape frame from a placement drag. When `locked` (Shift held) the frame
/// is forced square — rectangle becomes a square, ellipse a perfect circle,
/// lines/arrows a 45° diagonal — while preserving the drag direction.
func shapeScreenRect(from start: CGPoint, to current: CGPoint, locked: Bool) -> CGRect {
    var end = current
    if locked {
        let dx = current.x - start.x
        let dy = current.y - start.y
        let side = max(abs(dx), abs(dy))
        end = CGPoint(x: start.x + (dx >= 0 ? side : -side),
                      y: start.y + (dy >= 0 ? side : -side))
    }
    return marqueeScreenRect(from: start, to: end)
}

/// Snaps a line's free endpoint to 45° increments (horizontal, diagonal,
/// vertical, …) around `anchor`, preserving the drag length. Used for
/// Shift-locked lines/arrows in any coordinate space with uniform scale.
func snappedLineEnd(from anchor: CGPoint, to current: CGPoint) -> CGPoint {
    let dx = current.x - anchor.x
    let dy = current.y - anchor.y
    let len = hypot(dx, dy)
    guard len > 0.001 else { return current }
    let step = CGFloat.pi / 4
    let snapped = round(atan2(dy, dx) / step) * step
    return CGPoint(x: anchor.x + len * cos(snapped),
                   y: anchor.y + len * sin(snapped))
}

/// Corner-resize delta that preserves `aspect` (w/h). Follows the dominant
/// drag axis so both growing and shrinking feel natural, then enforces
/// minimums without breaking the ratio: longer edge >= `minSize`,
/// shorter edge >= `shortMin`. Pure geometry shared by always-locked media
/// (image/PDF/YouTube) and Shift-locked resize of shapes and other items.
func aspectLockedDelta(origW: CGFloat, origH: CGFloat,
                       dx: CGFloat, dy: CGFloat, aspect: CGFloat,
                       minSize: CGFloat = 60, shortMin: CGFloat = 8) -> CGSize {
    guard origW > 0, origH > 0, aspect > 0 else {
        return CGSize(width: dx, height: dy)
    }
    // Dominant axis drives; the other follows the aspect.
    let useWidth = abs(dx) >= abs(dy * aspect)
    var newW: CGFloat
    var newH: CGFloat
    if useWidth {
        newW = origW + dx
        newH = newW / aspect
    } else {
        newH = origH + dy
        newW = newH * aspect
    }
    // Guard against zero/negative drags: snap to the minimum tile
    // with the correct aspect instead of disappearing.
    if newW < 1 || newH < 1 {
        if aspect >= 1 {
            newW = minSize
            newH = newW / aspect
        } else {
            newH = minSize
            newW = newH * aspect
        }
        return CGSize(width: newW - origW, height: newH - origH)
    }
    // Minimums, preserving aspect (longer >= minSize, shorter >= shortMin).
    let longest = max(newW, newH)
    if longest < minSize {
        let s = minSize / longest
        newW *= s
        newH *= s
    }
    let shortest = min(newW, newH)
    if shortest < shortMin {
        let s = shortMin / shortest
        newW *= s
        newH *= s
    }
    return CGSize(width: newW - origW, height: newH - origH)
}

/// Indices of `frames` (world space) intersecting `marqueeWorld`.
/// Any overlap selects; full containment is not required.
func framesIntersectingMarquee(frames: [CGRect], marqueeWorld: CGRect) -> [Int] {
    guard marqueeWorld.width > 0, marqueeWorld.height > 0 else { return [] }
    return frames.indices.filter { frames[$0].intersects(marqueeWorld) }
}
