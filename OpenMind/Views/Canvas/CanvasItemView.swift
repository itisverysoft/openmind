import SwiftUI

struct CanvasItemView: View {
    @Bindable var item: CanvasItem
    let viewport: Viewport
    let isSelected: Bool
    let isEditing: Bool
    /// Resize handle only makes sense for a lone selection.
    var showResize: Bool = true
    /// Rich-text controller for `.text` writing mode. Nil keeps plain editing.
    var richController: RichTextController?
    /// Lifted table cell selection (owned by CanvasView so the format
    /// toolbar acts on the same cells the grid highlights). Meaningful only
    /// for `.table` items; ignored otherwise.
    var tableSelection: Binding<Set<TableCellRef>> = .constant([])
    var tableAnchor: Binding<TableCellRef?> = .constant(nil)
    /// Shift held (plumbed from CanvasView): cell taps extend the range.
    var tableShiftHeld: Bool = false
    /// Live world-space offset applied to every selected item while a
    /// group drag is in flight. Owned by CanvasView so all selected items
    /// move together; this view itself holds no move state.
    var groupOffset: CGSize = .zero

    var onSelect: () -> Void = {}
    var onBeginEditing: () -> Void = {}
    var onCommit: () -> Void = {}
    /// Called when the lock badge (visible only for a selected locked item)
    /// is tapped. The parent clears `isLocked`.
    var onUnlock: () -> Void = {}
    /// Drag translation in screen points (global space). The parent converts
    /// to world points, updates `groupOffset`, and commits on end.
    var onDragChanged: (CGSize) -> Void = { _ in }
    var onDragEnded: (CGSize) -> Void = { _ in }

    // Live, not-yet-saved resize state, in WORLD points.
    @State private var resizeDelta: CGSize = .zero

    private let minSize: CGFloat = 60   // world points
    private let drawingMinSize: CGFloat = 8  // strokes size to their ink, not a box
    private let imageShortMin: CGFloat = 8   // thinnest allowed edge for panoramas
    private let noteMinSize: CGFloat = 1  // pins keep their fixed 48pt frame

    private var minSide: CGFloat {
        if item.kind == .drawing { return drawingMinSize }
        if item.kind == .note { return noteMinSize }
        return minSize
    }

    private var scale: CGFloat { viewport.scale }

    /// Fixed on-screen diameter for pin notes. Pins stay tappable at any
    /// zoom (like map pins) instead of growing huge at 300%+ as world-scaled
    /// frames do. Position still tracks the world center so pan/zoom and
    /// group-drag stay correct.
    private let noteDiameter: CGFloat = 24

    private var isNote: Bool { item.kind == .note }

    /// Screen size: constant for notes, world-scaled for everything else.
    private var displaySize: CGSize {
        if isNote { return CGSize(width: noteDiameter, height: noteDiameter) }
        return CGSize(width: worldWidth * scale, height: worldHeight * scale)
    }

    /// Screen origin: top-left of the displayed frame. Notes center their
    /// fixed circle on the item's world center; others use the world
    /// top-left like before.
    private var displayOrigin: CGPoint {
        if isNote {
            let dx = isSelected ? groupOffset.width : 0
            let dy = isSelected ? groupOffset.height : 0
            let cx = (CGFloat(item.x) + CGFloat(item.width) / 2 + dx) * scale + viewport.offset.width
            let cy = (CGFloat(item.y) + CGFloat(item.height) / 2 + dy) * scale + viewport.offset.height
            return CGPoint(x: cx - noteDiameter / 2, y: cy - noteDiameter / 2)
        }
        return screenOrigin
    }

    /// True media aspect (w/h) from the stored bytes, falling back to the
    /// current frame when bytes are missing. Nil for non-media items.
    /// Images decode pixels; PDFs use the displayed page's media box;
    /// YouTube tiles keep a fixed 16:9 player aspect.
    private var imageAspect: CGFloat? {
        if item.kind == .youtube { return YouTubeEmbed.aspect }
        guard item.kind == .image || item.kind == .pdf else { return nil }
        if item.kind == .pdf {
            if let size = item.pdfDisplaySize, size.height > 0 {
                return size.width / size.height
            }
        } else if let data = item.imageData,
                  let px = imagePixelSize(from: data),
                  px.width > 0, px.height > 0 {
            return px.width / px.height
        }
        let h = CGFloat(item.height)
        guard h > 0 else { return nil }
        let a = CGFloat(item.width) / h
        return a > 0 ? a : nil
    }

    private var isAspectLocked: Bool {
        (item.kind == .image || item.kind == .pdf || item.kind == .youtube) && imageAspect != nil
    }

    private var worldWidth: CGFloat {
        // Aspect-locked tiles must never clamp w/h independently — that is
        // what stretched thin panoramas. Mins are enforced in the gesture
        // while preserving aspect; here just guard against zero/negative.
        if isAspectLocked {
            return max(1, CGFloat(item.width) + resizeDelta.width)
        }
        return max(minSide, CGFloat(item.width) + resizeDelta.width)
    }
    private var worldHeight: CGFloat {
        if isAspectLocked {
            return max(1, CGFloat(item.height) + resizeDelta.height)
        }
        return max(minSide, CGFloat(item.height) + resizeDelta.height)
    }

    /// Top-left corner on screen: screen = world * scale + offset.
    /// While a group drag is active every selected item shifts by the shared
    /// `groupOffset` so the whole marquee selection moves together.
    private var screenOrigin: CGPoint {
        let dx = isSelected ? groupOffset.width : 0
        let dy = isSelected ? groupOffset.height : 0
        return CGPoint(
            x: (CGFloat(item.x) + dx) * scale + viewport.offset.width,
            y: (CGFloat(item.y) + dy) * scale + viewport.offset.height
        )
    }

    var body: some View {
        ItemBodyView(item: item, scale: isNote ? 1 : scale, isEditing: isEditing,
                     isSelected: isSelected,
                     richController: richController, onCommit: onCommit,
                     tableSelection: tableSelection, tableAnchor: tableAnchor,
                     tableShiftHeld: tableShiftHeld)
            .frame(width: displaySize.width, height: displaySize.height)
            .overlay {
                if isSelected { selectionOutline }
            }
            .overlay(alignment: .bottomTrailing) {
                // Pins keep their fixed frame: movable, never resizable.
                if isSelected && !isEditing && item.kind != .drawing && item.kind != .note && showResize && !item.isLocked { resizeHandle }
            }
            .overlay(alignment: .topLeading) {
                if item.isLocked && isSelected { lockBadge }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // Locked items never enter editing; drawings/images have no
                // editable content. Tables enter cell-editing mode.
                guard !item.isLocked else { onSelect(); return }
                if item.kind.isEditable { onBeginEditing() } else { onSelect() }
            }
            .onTapGesture { onSelect() }
            .gesture(moveGesture, including: isEditing ? .subviews : .all)
            // Locked PDF pages are tap-through while unselected: the page
            // fills its sheet, so without this every empty-area tap would
            // select the background instead of deselecting. Marquee-select
            // the page to reach its lock badge; selection restores hits.
            .allowsHitTesting(!isBackgroundPDF || isSelected)
            .offset(x: displayOrigin.x, y: displayOrigin.y)
    }

    /// Locked PDF tiles act as page backgrounds — taps belong to the canvas
    /// beneath them until the tile is selected (e.g. via marquee).
    private var isBackgroundPDF: Bool {
        item.kind == .pdf && item.isLocked
    }

    // MARK: Selection chrome (fixed on-screen size)

    private var selectionOutline: some View {
        Group {
            if item.isLocked {
                if isNote {
                    Circle().stroke(Color.gray, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                } else {
                    Rectangle()
                        .stroke(Color.gray, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            } else {
                if isNote {
                    Circle().stroke(Color.accentColor, lineWidth: 2)
                } else {
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Badge shown only while a locked item is selected. Tapping anywhere
    /// on the circle unlocks (see `onUnlock`). Fixed on-screen size; sits
    /// just outside the top-left corner so it never covers content. The
    /// Circle is the hit-test base (not a background) so the full disc —
    /// not just the glyph pixels — is tappable.
    private var lockBadge: some View {
        Button(action: onUnlock) {
            Circle()
                .fill(Color.gray)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help("Unlock")
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .offset(x: -14, y: -14)
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .frame(width: 22, height: 22)
            .gesture(resizeGesture)
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard !item.isLocked else { return }
                if !isSelected { onSelect() }
                onDragChanged(value.translation)
            }
            .onEnded { value in
                guard !item.isLocked else { return }
                onDragEnded(value.translation)
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard !item.isLocked else { return }
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                if let aspect = imageAspect {
                    resizeDelta = lockedImageDelta(dx: dx, dy: dy, aspect: aspect)
                } else {
                    resizeDelta = CGSize(width: dx, height: dy)
                }
            }
            .onEnded { _ in
                guard !item.isLocked else { resizeDelta = .zero; return }
                item.width = Double(worldWidth)     // computed from the live delta: assign before reset
                item.height = Double(worldHeight)
                resizeDelta = .zero
                onCommit()
            }
    }

    /// Corner resize that preserves `aspect` (w/h). Follows the dominant
    /// drag axis so both growing and shrinking feel natural, then enforces
    /// minimums without breaking the ratio: longer edge >= `minSize`,
    /// shorter edge >= `imageShortMin`.
    private func lockedImageDelta(dx: CGFloat, dy: CGFloat, aspect: CGFloat) -> CGSize {
        let origW = CGFloat(item.width)
        let origH = CGFloat(item.height)
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
        if shortest < imageShortMin {
            let s = imageShortMin / shortest
            newW *= s
            newH *= s
        }
        return CGSize(width: newW - origW, height: newH - origH)
    }
}
