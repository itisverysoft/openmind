import Foundation
import CoreGraphics

// MARK: - Grouping + multi-select resize (pure geometry, no models)

// These helpers back persistent groups (`CanvasItem.groupID`) and the
// multi-select bounding-box resize. They are intentionally model-free so
// they are trivially unit-testable; CanvasView wires them to SwiftData.

/// Union of `frames`. Nil when empty — callers hide the multi-resize
/// overlay then.
func selectionUnion(frames: [CGRect]) -> CGRect? {
    guard var acc = frames.first else { return nil }
    for f in frames.dropFirst() { acc = acc.union(f) }
    return acc
}

/// Maps `frame` from `oldBounds` to `newBounds`, preserving its relative
/// position and size. Uniform scales (newBounds aspect == oldBounds aspect)
/// keep every member's own ratio — the "ratio stays the same" behaviour
/// for multi-resize. Anchored at the bounds' top-leading corner, matching
/// the single-item corner handle.
func scaledFrame(_ frame: CGRect, from oldBounds: CGRect, to newBounds: CGRect) -> CGRect {
    guard oldBounds.width > 0, oldBounds.height > 0 else { return frame }
    let sx = newBounds.width / oldBounds.width
    let sy = newBounds.height / oldBounds.height
    let nx = newBounds.minX + (frame.minX - oldBounds.minX) * sx
    let ny = newBounds.minY + (frame.minY - oldBounds.minY) * sy
    let nw = frame.width * sx
    let nh = frame.height * sy
    return CGRect(x: nx, y: ny, width: nw, height: nh)
}

/// New bounding box for a corner-drag resize anchored at the top-leading
/// corner. `dx`/`dy` are world-point deltas from the drag translation.
/// When `locked` (Shift) the bounds keep their original aspect via the
/// shared `aspectLockedDelta`; otherwise the drag stretches freely.
/// Minimums keep the box usable without breaking the ratio when locked.
func multiResizeBounds(original: CGRect, dx: CGFloat, dy: CGFloat, locked: Bool,
                       minSize: CGFloat = 20) -> CGRect {
    guard original.width > 0, original.height > 0 else { return original }
    if locked {
        let aspect = original.width / original.height
        guard aspect > 0 else { return original }
        let d = aspectLockedDelta(origW: original.width, origH: original.height,
                                  dx: dx, dy: dy, aspect: aspect,
                                  minSize: max(minSize, 20), shortMin: 8)
        let w = max(1, original.width + d.width)
        let h = max(1, original.height + d.height)
        return CGRect(x: original.minX, y: original.minY, width: w, height: h)
    } else {
        let w = max(minSize, original.width + dx)
        let h = max(minSize, original.height + dy)
        return CGRect(x: original.minX, y: original.minY, width: w, height: h)
    }
}

/// Scales every entry of `originals` from `oldBounds` to `newBounds`.
/// Pure map step of the multi-resize commit/preview.
func scaledFrames(originals: [UUID: CGRect], from oldBounds: CGRect, to newBounds: CGRect) -> [UUID: CGRect] {
    var out: [UUID: CGRect] = [:]
    out.reserveCapacity(originals.count)
    for (id, f) in originals {
        out[id] = scaledFrame(f, from: oldBounds, to: newBounds)
    }
    return out
}

/// Maps a point from `oldBounds` to `newBounds` proportionally. Used for
/// position-only members (pins, drawings) that move with the layout while
/// keeping their own size.
func scaledPoint(_ p: CGPoint, from oldBounds: CGRect, to newBounds: CGRect) -> CGPoint {
    guard oldBounds.width > 0, oldBounds.height > 0 else { return p }
    let sx = newBounds.width / oldBounds.width
    let sy = newBounds.height / oldBounds.height
    return CGPoint(
        x: newBounds.minX + (p.x - oldBounds.minX) * sx,
        y: newBounds.minY + (p.y - oldBounds.minY) * sy
    )
}

// MARK: - Group membership (pure, ID-based for tests)

/// Expands `selected` to whole groups: any selected item that carries a
/// `groupID` pulls in every item sharing it. `groups` maps item ID to its
/// optional group. Un grouped selections pass through unchanged.
func expandedForGroups(selected: Set<UUID>, groups: [UUID: UUID?]) -> Set<UUID> {
    let wanted = Set(selected.compactMap { groups[$0] as? UUID })
    guard !wanted.isEmpty else { return selected }
    var out = selected
    for (id, g) in groups {
        if let g, wanted.contains(g) { out.insert(id) }
    }
    return out
}

/// Grouping is available for 2+ items.
func canGroupSelection(count: Int) -> Bool { count >= 2 }

/// Ungroup is available when at least one selected item is grouped.
func canUngroupSelection(selectedGroupIDs: [UUID?]) -> Bool {
    selectedGroupIDs.contains(where: { $0 != nil })
}

/// Fresh group IDs for duplicated items: every distinct old group among
/// the originals maps to one new UUID shared by its copies. Ungrouped
/// originals (nil) stay ungrouped. Preserves grouping structure among the
/// copies whether the whole group or only part of it was duplicated.
func remappedGroupIDs(for originalGroups: [UUID?]) -> [UUID: UUID] {
    var map: [UUID: UUID] = [:]
    for g in originalGroups.compactMap({ $0 }) {
        if map[g] == nil { map[g] = UUID() }
    }
    return map
}

/// Scales drawing stroke points (local space) by `sx`/`sy`. Line width
/// scales by the uniform factor, or the mean for free (non-uniform) drags
/// so strokes stay roughly proportional.
func scaledStroke(points: [CGPoint], sx: CGFloat, sy: CGFloat) -> [CGPoint] {
    guard sx != 1 || sy != 1 else { return points }
    return points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
}

func scaledLineWidth(_ lineWidth: Double, sx: CGFloat, sy: CGFloat) -> Double {
    guard sx > 0, sy > 0 else { return lineWidth }
    let s = abs(sx - sy) < 0.001 ? sx : (sx + sy) / 2
    return max(0.5, lineWidth * Double(s))
}
