import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    /// Shift held (plumbed from CanvasView): while true, corner resize
    /// preserves the item's current aspect ratio.
    var shiftHeld: Bool = false
    /// Live multi-select resize preview (world frame). When set, the view
    /// renders this frame instead of the stored model + single-resize delta,
    /// so grouped / marquee selections scale together with one handle.
    var liveFrame: CGRect? = nil
    /// Live world-space offset applied to every selected item while a
    /// group drag is in flight. Owned by CanvasView so all selected items
    /// move together; this view itself holds no move state.
    var groupOffset: CGSize = .zero
    /// Hover affordance only makes sense in selection mode. Plumbed from
    /// CanvasView (`tool == .select`); changes only when the tool changes,
    /// so it never invalidates rows on selection clicks.
    var hoverEnabled: Bool = true

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

    /// Pointer currently over this item. Local `@State` (not lifted) so
    /// hover highlights never re-render sibling rows — only this row updates
    /// on enter/exit.
    @State private var isHovering = false

    // Live, not-yet-saved resize state, in WORLD points.
    @State private var resizeDelta: CGSize = .zero
    /// Aspect (w/h) used for the in-flight resize when Shift locks the
    /// ratio. Nil = free resize. Tracked so the live frame doesn't clamp
    /// w/h independently (which would break the ratio at minimum sizes).
    @State private var resizeLockedAspect: CGFloat? = nil

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
    /// A multi-resize `liveFrame` overrides the stored size (notes still
    /// render fixed, positioned by the live center — see `displayOrigin`).
    private var displaySize: CGSize {
        if isNote { return CGSize(width: noteDiameter, height: noteDiameter) }
        if let live = liveFrame {
            return CGSize(width: max(1, live.width) * scale, height: max(1, live.height) * scale)
        }
        return CGSize(width: worldWidth * scale, height: worldHeight * scale)
    }

    /// Screen origin: top-left of the displayed frame. Notes center their
    /// fixed circle on the item's world center; others use the world
    /// top-left like before. A multi-resize `liveFrame` wins over both the
    /// model and the move/group offsets so the whole selection previews
    /// together.
    private var displayOrigin: CGPoint {
        if isNote {
            if let live = liveFrame {
                let cx = live.midX * scale + viewport.offset.width
                let cy = live.midY * scale + viewport.offset.height
                return CGPoint(x: cx - noteDiameter / 2, y: cy - noteDiameter / 2)
            }
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
                  // Cached dimensions (not `imagePixelSize(from:)`): view
                  // bodies must never re-create an ImageIO source per item
                  // on each selection change.
                  let px = ImageResourceCache.pixelSize(forItem: item.id, data: data),
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

    /// Live Shift state: the plumbed binding covers the common case
    /// (Shift held before the drag starts). On macOS also poll the real
    /// modifier flags so pressing/releasing Shift mid-drag works even
    /// though the gesture closure captured the old value.
    private var shiftActive: Bool {
        if shiftHeld { return true }
#if os(macOS)
        return NSEvent.modifierFlags.contains(.shift)
#else
        return false
#endif
    }

    private var isResizeAspectLocked: Bool {
        isAspectLocked || resizeLockedAspect != nil
    }

    private var worldWidth: CGFloat {
        // Aspect-locked tiles must never clamp w/h independently — that is
        // what stretched thin panoramas. Mins are enforced in the gesture
        // while preserving aspect; here just guard against zero/negative.
        if isResizeAspectLocked {
            return max(1, CGFloat(item.width) + resizeDelta.width)
        }
        return max(minSide, CGFloat(item.width) + resizeDelta.width)
    }
    private var worldHeight: CGFloat {
        if isResizeAspectLocked {
            return max(1, CGFloat(item.height) + resizeDelta.height)
        }
        return max(minSide, CGFloat(item.height) + resizeDelta.height)
    }

    /// Top-left corner on screen: screen = world * scale + offset.
    /// While a group drag is active every selected item shifts by the shared
    /// `groupOffset` so the whole marquee selection moves together.
    /// A multi-resize `liveFrame` overrides both for the preview.
    private var screenOrigin: CGPoint {
        if let live = liveFrame {
            return CGPoint(
                x: live.minX * scale + viewport.offset.width,
                y: live.minY * scale + viewport.offset.height
            )
        }
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
                if isSelected {
                    selectionOutline
                } else if hoverEnabled && isHovering {
                    hoverOutline
                }
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
            .onHover { isHovering = $0 }
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

    /// Hover affordance in selection mode: same shape as the selection
    /// outline at 50% opacity. Hidden once selected (the full outline wins).
    private var hoverOutline: some View {
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
        .opacity(0.5)
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
                    resizeLockedAspect = aspect
                    resizeDelta = lockedImageDelta(dx: dx, dy: dy, aspect: aspect)
                } else if shiftActive {
                    let h = CGFloat(item.height)
                    if h > 0 {
                        let aspect = CGFloat(item.width) / h
                        if aspect > 0 {
                            resizeLockedAspect = aspect
                            resizeDelta = lockedImageDelta(dx: dx, dy: dy, aspect: aspect)
                        } else {
                            resizeLockedAspect = nil
                            resizeDelta = CGSize(width: dx, height: dy)
                        }
                    } else {
                        resizeLockedAspect = nil
                        resizeDelta = CGSize(width: dx, height: dy)
                    }
                } else {
                    resizeLockedAspect = nil
                    resizeDelta = CGSize(width: dx, height: dy)
                }
            }
            .onEnded { _ in
                guard !item.isLocked else { resizeDelta = .zero; resizeLockedAspect = nil; return }
                item.width = Double(worldWidth)     // computed from the live delta: assign before reset
                item.height = Double(worldHeight)
                resizeDelta = .zero
                resizeLockedAspect = nil
                onCommit()
            }
    }

    /// Corner resize that preserves `aspect` (w/h). Follows the dominant
    /// drag axis so both growing and shrinking feel natural, then enforces
    /// minimums without breaking the ratio: longer edge >= `minSize`,
    /// shorter edge >= `imageShortMin`. Used for always-locked media
    /// (image/PDF/YouTube) and for Shift-locked resize of shapes, text,
    /// tables and other free-form items.
    private func lockedImageDelta(dx: CGFloat, dy: CGFloat, aspect: CGFloat) -> CGSize {
        aspectLockedDelta(origW: CGFloat(item.width), origH: CGFloat(item.height),
                          dx: dx, dy: dy, aspect: aspect,
                          minSize: minSize, shortMin: imageShortMin)
    }
}
