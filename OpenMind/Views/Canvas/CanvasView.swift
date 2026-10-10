import SwiftUI
import SwiftData
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct CanvasView: View {
    @Bindable var board: Board
    @Environment(\.modelContext) private var context
    /// Opens a board file: pops back to the board list and shows its
    /// importer. Wired by BoardListView, which owns the navigation path.
    var onOpenBoardFile: () -> Void = {}

    // Viewport
    @State private var viewport = Viewport()
    @State private var viewSize: CGSize = .zero
    @State private var didCenter = false
    @GestureState private var panDelta: CGSize = .zero
    @GestureState private var zoomDelta: CGFloat = 1

    /// Canvas settings inspector (paper size, colour, pattern).
    @State private var showCanvasSettings = false

    /// Voice-note recorder card (non-modal overlay, top right). The recorder
    /// lives here so recording continues while the canvas is used.
    @State private var showRecorder = false
    @StateObject private var voiceRecorder = AudioRecorder()
    /// In-app About sheet (VerySoft links, maintainer site).
    @State private var showAbout = false

    /// Board file staged for the save panel (built up front on Export tap).
    @State private var exportDoc = VSOMFileDocument()
    @State private var showExporter = false

    /// Rendered media (PNG/PDF/SVG) staged for its save panel.
    @State private var mediaDoc = ExportFileDocument()
    @State private var mediaType: UTType = .png
    @State private var mediaFilename = ""
    @State private var showMediaExporter = false

    // Selection and editing
    @State private var selectedIDs: Set<UUID> = []
    @State private var editingID: UUID?

    /// Page currently shown. The sheet rect is identical on every page, so
    /// flipping never moves the viewport — only the item filter changes.
    /// Not persisted: reopening a board starts on page 1, and flips never
    /// touch the undo stack or `modifiedAt`.
    @State private var currentPage = 0

    // Table cell selection, owned here so the format toolbar acts on the
    // same cells the grid highlights. Valid only while a table is being
    // edited (single tap = one cell, Shift-click = rectangular range).
    @State private var tableSelectedCells: Set<TableCellRef> = []
    @State private var tableAnchorCell: TableCellRef? = nil

    // Marquee (rubber-band) selection, in canvas-local screen points.
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeAdditive = false
    @State private var marqueeInitial: Set<UUID> = []

    // Shape placement drag, in canvas-local screen points.
    @State private var shapeDragStart: CGPoint?
    @State private var shapeDragCurrent: CGPoint?
    /// Pending point A (world) for two-tap line/arrow placement.
    @State private var lineAnchorWorld: CGPoint?
    /// Mouse position in canvas-local screen points for the anchor→cursor
    /// rubber band (macOS hover). Stored in screen space so the preview tip
    /// sticks to the cursor even across pan/zoom; the anchor stays in world
    /// space so it sticks to the canvas.
    @State private var lineHoverScreen: CGPoint?

    // Group drag: the shared live offset (world points) plus the snapshot
    // of which items are moving. Owned here so every selected item moves.
    @State private var groupDragOffset: CGSize = .zero
    @State private var groupDragIDs: Set<UUID> = []

    // Multi-select resize: snapshot of the selection's frames + original
    // bounds at drag start, plus the live world-space delta. Preview frames
    // are derived (see `multiResizeLiveFrames`) and passed as `liveFrame`
    // to each item; the model commits once on drag end. Ratios are preserved
    // by default (uniform scale of the bounds); holding Shift stretches the
    // bounds freely.
    @State private var multiResizeIDs: Set<UUID> = []
    @State private var multiResizeBase: [UUID: CGRect] = [:]
    @State private var multiResizeBoundsOrig: CGRect? = nil
    @State private var multiResizeDelta: CGSize = .zero
    @State private var multiResizeLocked: Bool = false
    /// Hover highlight for the multi-resize handle (appearance only).
    @State private var multiHandleHover = false

    // Drawing tools
    @State private var tool: CanvasTool = .select
    @State private var penStyle: DrawingStyle = .pen
    @State private var penColorHex: String = Palette.autoInk
    @State private var penWidth: Double = DrawingStyle.pen.defaultLineWidth
    /// Eraser diameter in world points (size-selectable, like a real eraser).
    @State private var eraserWidth: Double = 16
    /// In-progress stroke in screen points (canvas-local space).
    @State private var activeStrokeScreen: [CGPoint] = []
    /// Live eraser cursor in screen points + previous erase location for
    /// segment interpolation so fast drags can't jump over thin strokes.
    @State private var activeEraserScreen: CGPoint?
    /// Pointer position in screen points for the brush-size ring shown under
    /// the cursor (macOS hover). Hidden while a stroke/erase is in flight.
    @State private var brushHoverScreen: CGPoint?
    @State private var lastEraseScreen: CGPoint?
    @State private var didEraseInDrag = false
    @State private var eraseGroupingOpen = false

    // Illustrator-style temporary hand: holding Option pans the canvas.
    @State private var isOptionHeld = false
    @State private var isShiftHeld = false
    @State private var isPanning = false
    @State private var isHovering = false

    /// Bumped whenever the undo stack may have changed (button taps and
    /// system Cmd+Z alike) so toolbar/pill `canUndo`/`canRedo` and the
    /// soft-delete filter always re-render. Soft-deletes don't touch
    /// `board.items` itself, so model observation alone would miss them.
    @State private var undoRevision = 0

    /// Bridges the rich-text editor (writing mode) and the format toolbar.
    @StateObject private var richController = RichTextController()

    /// Focus for the pin-note editor card's TextEditor.
    @FocusState private var noteEditorFocused: Bool

    private var center: CGPoint {
        CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    }

    private var liveViewport: Viewport {
        viewport.applying(pan: panGestureEnabled ? panDelta : .zero, zoom: zoomDelta, around: center)
    }

    /// True while the temporary hand is active (macOS: Option held).
    private var isTemporaryPan: Bool {
#if os(macOS)
        isOptionHeld
#else
        false
#endif
    }

    /// Empty-canvas drags pan only when this is true: the hand tool is
    /// active, or the temporary hand (macOS: Option held). Otherwise an
    /// empty-space drag draws a marquee selection.
    private var panGestureEnabled: Bool {
        isTemporaryPan || tool == .hand
    }

    /// Items that are not in the trash. Every read path uses this so
    /// soft-deleted items are fully hidden until purged at next launch.
    private var visibleItems: [CanvasItem] {
        board.items.filter { !$0.isTrashed }
    }

    /// Current page clamped into range (the count may shrink under us when
    /// a page is deleted elsewhere).
    private var clampedPage: Int {
        min(max(currentPage, 0), max(0, board.pageCount - 1))
    }

    /// Visible items on the current page. All interaction — display,
    /// selection, creation, marquee, erase — scopes to this so pages are
    /// truly separate canvases. Legacy content (pageIndex 0) shows on page 1.
    private var pageItems: [CanvasItem] {
        visibleItems.filter { $0.pageIndex == clampedPage }
    }

    private var sortedItems: [CanvasItem] {
        pageItems.sorted { $0.zIndex < $1.zIndex }
    }

    private var selectedItems: [CanvasItem] {
        pageItems.filter { selectedIDs.contains($0.id) }
    }

    /// Live marquee rect in canvas-local screen points, if dragging one.
    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return marqueeScreenRect(from: start, to: current)
    }

    /// Live shape frame in canvas-local screen points, Shift-locked to a
    /// square when `isShiftHeld`.
    private var shapeDragRect: CGRect? {
        guard let start = shapeDragStart, let current = shapeDragCurrent else { return nil }
        return shapeScreenRect(from: start, to: current, locked: isShiftHeld)
    }

    private func itemsLayer(vp: Viewport) -> some View {
        let live = multiResizeLiveFrames()
        return Group {
            ForEach(sortedItems) { item in
                itemRow(for: item, vp: vp, liveFrame: live?[item.id] ?? nil)
            }
        }
        // In draw/erase/hand mode touches belong to the gestures below.
        // While the temporary hand is active items are click-through
        // so an Option-drag pans even when it starts on an item.
        // Note-placement mode keeps items hittable so existing pins stay
        // tappable/draggable; empty-canvas taps place new pins.
        .allowsHitTesting((tool == .select || tool == .note) && !isTemporaryPan)
    }

    /// One canvas item + its context menu. Split from `itemsLayer` so the
    /// type-checker sees small expressions instead of one giant ForEach.
    private func itemRow(for item: CanvasItem, vp: Viewport, liveFrame: CGRect?) -> some View {
        // Item-specific resize flag (not `selectedIDs.count == 1` for every
        // row): stays false→false for unselected items when selection goes
        // 0→1 or 1→2, so selection changes invalidate fewer rows. The view
        // still enforces kind/editing/lock rules before showing the handle.
        let isSingleSelected = selectedIDs.count == 1 && selectedIDs.contains(item.id)
        let row = CanvasItemView(
            item: item,
            viewport: vp,
            isSelected: selectedIDs.contains(item.id),
            isEditing: item.id == editingID,
            showResize: isSingleSelected,
            richController: richController,
            tableSelection: $tableSelectedCells,
            tableAnchor: $tableAnchorCell,
            tableShiftHeld: isShiftHeld,
            shiftHeld: isShiftHeld,
            liveFrame: liveFrame,
            groupOffset: groupDragOffset,
            hoverEnabled: tool == .select,
            onSelect: { select(item) },
            onBeginEditing: { beginEditing(item) },
            onCommit: touch,
            onUnlock: { unlockItem(item) },
            onDragChanged: { updateGroupDrag(item, translation: $0) },
            onDragEnded: { endGroupDrag(translation: $0) }
        )
        return row.contextMenu {
            arrangeMenu(for: item)
        }
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let rect = marqueeRect {
            Rectangle()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    /// Bounding box for 2+ selected items with a corner handle that scales
    /// the whole selection together. Ratios are preserved by default (Shift
    /// stretches freely). Select-mode only so draw/erase/hand and the
    /// temporary pan hand keep the pointer.
    @ViewBuilder
    private func multiSelectOverlay(vp: Viewport) -> some View {
        if canMultiResize, tool == .select, !isTemporaryPan,
           marqueeStart == nil, let world = multiResizeDisplayBounds() {
            let origin = vp.screenPoint(for: world.origin)
            let size = CGSize(width: world.width * vp.scale, height: world.height * vp.scale)
            let rect = CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
            Rectangle()
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            // Generous 44pt hit box (visible disc stays 22pt) so grabs near
            // the corner resize instead of falling through to the item-move
            // drag below. High-priority so the resize wins over ancestors
            // (marquee); hover grows the disc as a live affordance.
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .frame(width: 22, height: 22)
                .scaleEffect(multiHandleHover ? 1.25 : 1)
                .shadow(color: .black.opacity(multiHandleHover ? 0.3 : 0.15),
                        radius: multiHandleHover ? 4 : 2, y: 1)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .offset(x: rect.maxX - 22, y: rect.maxY - 22)
                .highPriorityGesture(multiResizeGesture(vp: vp))
                .onHover { multiHandleHover = $0 }
                .help("Drag to resize selection (ratios kept; Shift stretches freely)")
        }
    }

    private func multiResizeGesture(vp: Viewport) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if multiResizeIDs.isEmpty {
                    let items = selectedItems.filter { !$0.isLocked }
                    guard items.count >= 2 else { return }
                    let base = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.frameRect) })
                    guard let bounds = selectionUnion(frames: Array(base.values)),
                          bounds.width > 0, bounds.height > 0 else { return }
                    multiResizeIDs = Set(base.keys)
                    multiResizeBase = base
                    multiResizeBoundsOrig = bounds
                }
                updateMultiResize(translation: value.translation)
            }
            .onEnded { value in
                guard !multiResizeIDs.isEmpty else { cancelMultiResize(); return }
                endMultiResize(translation: value.translation)
            }
    }

    // MARK: Body decomposition
    // These helpers exist as type-check boundaries: each `some View`
    // return type forces the compiler to check one small piece at a time
    // instead of one giant modifier chain.

    private func canvasZStack(vp: Viewport) -> some View {
        ZStack(alignment: .topLeading) {
            Color.canvasBackground

            // Sheet fill under the pattern (shadow lifts the page off the
            // surrounding canvas). Hit-testing stays off so empty-space
            // gestures keep working on and around the sheet.
            if let sheet = sheetScreenRect(for: vp) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: board.canvasColorHex))
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.black.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                    .frame(width: sheet.width, height: sheet.height)
                    .offset(x: sheet.minX, y: sheet.minY)
                    .allowsHitTesting(false)
            }

            sheetPatternBackground(vp: vp)
                .gesture(emptySpaceGesture(vp: vp))
                .onTapGesture {
                    // Shift-click on empty space preserves the selection.
                    // Note-placement taps are handled by notePlacementGesture.
                    // Shape taps are handled by the shape gesture layer.
                    guard !isShiftHeld, tool != .note, !tool.isShapePlacing else { return }
                    selectedIDs = []
                    editingID = nil
                }
                .simultaneousGesture(notePlacementGesture(vp: vp))

            // Items are laid out at their real on-screen position and size.
            // There is no scaleEffect any more, which is what keeps them sharp.
            itemsLayer(vp: vp)

            // Marquee rubber-band, drawn above the items.
            marqueeOverlay

            // Multi-select bounding box + resize handle (2+ selected).
            multiSelectOverlay(vp: vp)

            // Freehand drawing + erasing layer. Only present while a draw
            // tool is active so selection, dragging and panning are
            // untouched in select mode.
            if tool.isDrawing {
                if tool == .erase {
                    Color.clear
                        .contentShape(Rectangle())
                        .allowsHitTesting(!isTemporaryPan)
                        .gesture(eraseGesture(vp: vp))
                        .hoverTracking(
                            onHover: { brushHoverScreen = $0 },
                            onLeave: { brushHoverScreen = nil })
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .allowsHitTesting(!isTemporaryPan)
                        .gesture(drawGesture(vp: vp))
                        .hoverTracking(
                            onHover: { brushHoverScreen = $0 },
                            onLeave: { brushHoverScreen = nil })
                }
                if tool == .draw, !activeStrokeScreen.isEmpty {
                    LiveStrokePreview(screenPoints: activeStrokeScreen,
                                      style: penStyle,
                                      colorHex: penColorHex,
                                      lineWidth: CGFloat(penWidth) * vp.scale)
                        .allowsHitTesting(false)
                }
                if tool == .erase, let cursor = activeEraserScreen {
                    brushRing(at: cursor, diameter: max(4, CGFloat(eraserWidth) * vp.scale),
                              fill: Color.white.opacity(0.25),
                              stroke: Color.primary.opacity(0.7))
                }
                brushHoverRing(vp: vp)
            }

    // Shape placement layer: drag anywhere to size the new shape.
            // Items are click-through while placing (see itemsLayer), so the
            // drag always defines a fresh frame instead of moving content.
            // Lines/arrows place point-to-point (tap A, tap B — or drag).
            if tool.isShapePlacing {
                if tool.shapeKind?.isLineLike == true {
                    Color.clear
                        .contentShape(Rectangle())
                        .allowsHitTesting(!isTemporaryPan)
                        .gesture(lineGesture(vp: vp))
                        .hoverTracking(
                            onHover: { location in
                                // Only track once point A is set — otherwise
                                // every mouse move would needlessly re-render.
                                // Stored in screen space (no vp conversion)
                                // so the tip never lags behind the cursor.
                                guard lineAnchorWorld != nil else { return }
                                lineHoverScreen = location
                            },
                            onLeave: { lineHoverScreen = nil })
                    linePreviewOverlay(vp: vp)
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .allowsHitTesting(!isTemporaryPan)
                        .gesture(shapeGesture(vp: vp))
                    shapePreviewOverlay
                }
            }
        }
    }

    /// Ring showing the exact brush diameter at `screen`. Shared by the pen
    /// hover ring, the eraser hover ring, and the in-drag eraser cursor.
    private func brushRing(at screen: CGPoint, diameter: CGFloat,
                           fill: Color, stroke: Color) -> some View {
        Circle()
            .fill(fill)
            .overlay(Circle().stroke(stroke, lineWidth: 1.5))
            .frame(width: diameter, height: diameter)
            .offset(x: screen.x - diameter / 2, y: screen.y - diameter / 2)
            .allowsHitTesting(false)
    }

    /// Hover ring under the pointer at the dialed-in size: pen diameter for
    /// the draw tool (tinted with the ink), eraser diameter for the eraser.
    /// Hidden while panning, while a stroke is being drawn, or mid-erase —
    /// those states already have their own live feedback.
    @ViewBuilder
    private func brushHoverRing(vp: Viewport) -> some View {
        if !isTemporaryPan, !isPanning, let hover = brushHoverScreen {
            if tool == .draw, activeStrokeScreen.isEmpty {
                let ink: Color = penColorHex.uppercased() == Palette.autoInk
                    ? .primary : Color(hex: penColorHex)
                brushRing(at: hover,
                          diameter: max(4, CGFloat(penWidth) * vp.scale),
                          fill: ink.opacity(0.25),
                          stroke: ink.opacity(0.8))
            } else if tool == .erase, activeEraserScreen == nil {
                brushRing(at: hover,
                          diameter: max(4, CGFloat(eraserWidth) * vp.scale),
                          fill: Color.white.opacity(0.25),
                          stroke: Color.primary.opacity(0.7))
            }
        }
    }

    /// Sheet in canvas-local screen points, or nil for `.infinite`.
    private func sheetScreenRect(for vp: Viewport) -> CGRect? {
        guard let world = board.sheetWorldRect else { return nil }
        let origin = vp.screenPoint(for: world.origin)
        return CGRect(x: origin.x, y: origin.y,
                      width: world.width * vp.scale, height: world.height * vp.scale)
    }

    /// Pattern background: full-view on the infinite canvas, clipped to the
    /// sheet otherwise. Items are never clipped — anything drawn off the
    /// sheet stays where it is, exactly like the design note.
    private func sheetPatternBackground(vp: Viewport) -> some View {
        Group {
            if let sheet = sheetScreenRect(for: vp) {
                GridBackground(viewport: vp,
                               pattern: board.canvasPattern,
                               sheetScreenRect: sheet,
                               sheetLuminance: canvasLuminance(hex: board.canvasColorHex))
            } else {
                GridBackground(viewport: vp, pattern: board.canvasPattern)
            }
        }
    }

    /// Live outline of the shape being placed, in canvas-local screen points.
    @ViewBuilder
    private var shapePreviewOverlay: some View {
        if let rect = shapeDragRect, let kind = tool.shapeKind, !kind.isLineLike {
            ShapeDragPreview(kind: kind, colorHex: Palette.swatches[3])
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    /// Live endpoint preview for line/arrow placement: the in-progress drag
    /// as A→B, otherwise a rubber band from the pending anchor to the
    /// cursor, falling back to the anchor marker plus a placement hint.
    private func linePreviewOverlay(vp: Viewport) -> some View {
        Group {
            if let kind = tool.shapeKind, kind.isLineLike {
                if let start = shapeDragStart, let current = shapeDragCurrent {
                    let end = isShiftHeld ? snappedLineEnd(from: start, to: current) : current
                    lineSpanPreview(kind: kind, a: start, b: end)
                } else if let anchor = lineAnchorWorld {
                    lineAnchorPreview(kind: kind, anchor: anchor, vp: vp)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func lineAnchorPreview(kind: ShapeKind, anchor: CGPoint, vp: Viewport) -> some View {
        let aScreen = vp.screenPoint(for: anchor)
        if let hScreen = lineHoverScreen {
            let far = hypot(hScreen.x - aScreen.x, hScreen.y - aScreen.y) >= 6
            if far {
                let end = isShiftHeld ? snappedLineEnd(from: aScreen, to: hScreen) : hScreen
                lineSpanPreview(kind: kind, a: aScreen, b: end)
                // Small cursor dot + hint so it's clear the next click
                // commits point B (Esc cancels the pending point A).
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .offset(x: end.x - 4, y: end.y - 4)
                placementHint(at: end, kind: kind)
            } else {
                anchorDot(at: aScreen)
                placementHint(at: aScreen, kind: kind)
            }
        } else {
            anchorDot(at: aScreen)
            placementHint(at: aScreen, kind: kind)
        }
    }

    /// Floating hint next to the pending anchor / cursor: what the next
    /// click will do. Keeps first-time users from getting stuck after
    /// tapping point A with no visible feedback (notably on trackpads
    /// where hover is the only cue, and on iOS where there is no hover).
    private func placementHint(at screen: CGPoint, kind: ShapeKind) -> some View {
        Text(kind == .line ? "Click to set end point • Esc to cancel"
             : kind == .arrow ? "Click to set arrow tip • Esc to cancel"
             : "Click to set end • Esc to cancel")
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .offset(x: screen.x + 14, y: screen.y + 14)
    }

    private func anchorDot(at screen: CGPoint) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 10, height: 10)
            .offset(x: screen.x - 5, y: screen.y - 5)
    }

    /// Screen-space line preview padded so heads never clip, positioned by
    /// frame + offset like the marquee overlay.
    private func lineSpanPreview(kind: ShapeKind, a: CGPoint, b: CGPoint) -> some View {
        let pad: CGFloat = 28
        let rect = CGRect(x: min(a.x, b.x) - pad, y: min(a.y, b.y) - pad,
                          width: abs(b.x - a.x) + pad * 2,
                          height: abs(b.y - a.y) + pad * 2)
        return LineEndpointsPreview(kind: kind,
                                    a: CGPoint(x: a.x - rect.minX, y: a.y - rect.minY),
                                    b: CGPoint(x: b.x - rect.minX, y: b.y - rect.minY),
                                    colorHex: Palette.swatches[3])
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    private func framedCanvas(vp: Viewport, size: CGSize) -> some View {
        canvasZStack(vp: vp)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .onDrop(of: [.image, .audio, .video, .fileURL, .url], isTargeted: nil) { providers, location in
                handleMediaDrop(providers: providers, location: location, vp: vp)
            }
    }

    private func applyMacHover<V: View>(to view: V) -> some View {
#if os(macOS)
        view
            .background {
                OptionKeyMonitor(isHeld: $isOptionHeld)
                ShiftKeyMonitor(isHeld: $isShiftHeld)
            }
            .onHover { hovering in
                isHovering = hovering
                updateCursor()
            }
            .onContinuousHover { phase in
                // Re-assert the hand on every move while it is active, so it
                // survives cursor-rect re-evaluation (e.g. over text editors).
                // Otherwise leave the system cursor (arrow, I-beam, …) alone.
                if isTemporaryPan || isPanning, case .active = phase {
                    updateCursor()
                }
            }
            .onChange(of: isOptionHeld) { _, _ in updateCursor() }
            .onChange(of: isPanning) { _, _ in updateCursor() }
#else
        view
#endif
    }

    private func applyScrollWheel<V: View>(to view: V) -> some View {
#if os(macOS)
        view.background {
            ScrollWheelHandler(
                onPan: { delta in
                    viewport = viewport.applying(pan: delta, around: center)
                },
                onZoom: { factor, location in
                    viewport = viewport.applying(zoom: factor, around: location)
                }
            )
        }
#else
        view
#endif
    }

    private func floatingToolbarView() -> some View {
        FloatingToolbar(
            selectedItems: selectedItems,
            isEditing: editingID != nil,
            tool: tool,
            penStyle: penStyle,
            penColorHex: penColorHex,
            penWidth: penWidth,
            eraserWidth: eraserWidth,
            onAdd: { (kind: ItemKind, shape: ShapeKind) in addItem(kind, shape: shape) },
            onShapeSelect: { (shape: ShapeKind) in selectShape(shape) },
            onColor: { (hex: String) in setColor(hex) },
            onDelete: deleteSelected,
            onDuplicate: duplicateSelected,
            canGroup: canGroup,
            canUngroup: canUngroup,
            onGroup: groupSelected,
            onUngroup: ungroupSelected,
            onTool: { (newTool: CanvasTool) in tool = newTool; handleToolChange() },
            onPenStyle: { (style: DrawingStyle) in
                penStyle = style
                penWidth = style.defaultLineWidth
            },
            onPenColor: { (hex: String) in penColorHex = hex },
            onPenWidth: { (width: Double) in penWidth = width },
            onEraserWidth: { (width: Double) in eraserWidth = width },
            onAddImage: { (data: Data) in addImageItem(with: data) },
            onAddAudio: { (data: Data, fileName: String) in addAudioItem(with: data, fileName: fileName) },
            onRecordAudio: { showRecorder = true },
            onAddYouTube: { (urlString: String) in addYouTubeItem(with: urlString) },
            onAddVideo: { (data: Data, fileName: String) in addVideoItem(with: data, fileName: fileName) },
            onPaste: { pasteImageFromClipboard() }
        )
    }

    /// Non-modal voice-note card docked beside the undo/redo pill, so
    /// recording never blocks the canvas. Closing mid-recording discards
    /// the take; finishing drops it on the canvas as a playable tile.
    @ViewBuilder
    private func voiceRecorderCard() -> some View {
        if showRecorder {
            AudioRecorderView(
                recorder: voiceRecorder,
                onFinish: { data, fileName in
                    addAudioItem(with: data, fileName: fileName)
                    showRecorder = false
                },
                onClose: {
                    if voiceRecorder.isRecording { voiceRecorder.cancel() }
                    showRecorder = false
                }
            )
        }
    }

    private func geometryBody(geo: GeometryProxy) -> some View {
        let vp = liveViewport
        let framed = framedCanvas(vp: vp, size: geo.size)
        let hovered = applyMacHover(to: framed)
        let scrolled = applyScrollWheel(to: hovered)
        return scrolled
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    pageNavigator
                    floatingToolbarView()
                }
            }
            .overlay(alignment: .topTrailing) { topRightCluster() }
            .overlay(alignment: .topLeading) { richToolbarOverlay(vp: vp) }
            .overlay(alignment: .topLeading) { tableToolbarOverlay(vp: vp) }
            .overlay(alignment: .topLeading) { noteCardOverlay(vp: vp) }
            .simultaneousGesture(zoomGesture)
            .onChange(of: geo.size, initial: true) { _, newSize in
                handleGeoSizeChange(newSize)
            }
    }

    // MARK: Rich text toolbar

    /// The lone selected text box, if any — the format bar anchors to it.
    private var richTargetItem: CanvasItem? {
        guard selectedItems.count == 1,
              let item = selectedItems.first,
              item.kind == .text else { return nil }
        return item
    }

    /// True while the cursor is focused in the target box (writing mode).
    private var isEditingRichTarget: Bool {
        guard let target = richTargetItem else { return false }
        return editingID == target.id
    }

    /// Toolbar state: live selection/typing state while writing, otherwise
    /// the whole box's uniform formatting (nil = mixed).
    private var richDisplayState: RichTextState {
        guard let target = richTargetItem else { return RichTextState() }
        if isEditingRichTarget { return richController.state }
        let base = RichTextCodec.decode(target.richTextData)
            ?? RichTextCodec.plainFallback(text: target.text,
                                           fontSize: CGFloat(target.fontSize))
        return richInspectWhole(base)
    }

    /// Routes a toolbar action: to the live editor while writing (selection
    /// or typing attributes), otherwise to the whole text box.
    private func applyRich(_ action: RichTextAction) {
        if isEditingRichTarget, let editor = richController.editor {
            editor.richPerform(action)
            return
        }
        switch action {
        case .bold: wholeBoxRich { richToggleTrait($0, in: $1, trait: .bold) }
        case .italic: wholeBoxRich { richToggleTrait($0, in: $1, trait: .italic) }
        case .underline: wholeBoxRich { richToggleUnderline($0, in: $1) }
        case .strikethrough: wholeBoxRich { richToggleStrikethrough($0, in: $1) }
        case .sizePlus: wholeBoxRich { richNudgeFontSize($0, in: $1, delta: 1) }
        case .sizeMinus: wholeBoxRich { richNudgeFontSize($0, in: $1, delta: -1) }
        case .size(let pointSize): wholeBoxRich { richSetFontSize($0, in: $1, size: pointSize) }
        case .color(let hex): wholeBoxRich { richSetColor($0, in: $1, hex: hex) }
        case .alignment(let alignment):
            wholeBoxRich { richSetAlignment($0, in: $1, alignment: alignment) }
        }
    }

    private func wholeBoxRich(_ apply: (NSMutableAttributedString, NSRange) -> Void) {
        guard let target = richTargetItem, !target.isLocked else { return }
        let base = RichTextCodec.decode(target.richTextData)
            ?? RichTextCodec.plainFallback(text: target.text,
                                           fontSize: CGFloat(target.fontSize))
        let mutable = NSMutableAttributedString(attributedString: base)
        guard mutable.length > 0 else { return }
        apply(mutable, NSRange(location: 0, length: mutable.length))
        guard let data = RichTextCodec.encode(mutable) else { return }
        target.richTextData = data
        if target.text != mutable.string { target.text = mutable.string }
        touch()
    }

    /// Format bar floating just above the selected text box (flips below when
    /// too close to the top edge so it never clips off-screen).
    @ViewBuilder
    private func richToolbarOverlay(vp: Viewport) -> some View {
        if let target = richTargetItem, !target.isLocked {
            let origin = CGPoint(x: CGFloat(target.x) * vp.scale + vp.offset.width,
                                 y: CGFloat(target.y) * vp.scale + vp.offset.height)
            let height = CGFloat(target.height) * vp.scale
            if origin.y >= 64 {
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: .bottomLeading) {
                        TextFormatToolbar(state: richDisplayState) { applyRich($0) }
                            .fixedSize()
                    }
                    .offset(x: max(8, origin.x), y: max(8, origin.y - 8))
            } else {
                TextFormatToolbar(state: richDisplayState) { applyRich($0) }
                    .offset(x: max(8, origin.x), y: origin.y + height + 8)
            }
        }
    }

    // MARK: Table toolbar

    /// The lone selected table, if any — the table bar anchors to it.
    private var tableTargetItem: CanvasItem? {
        guard selectedItems.count == 1,
              let item = selectedItems.first,
              item.kind == .table else { return nil }
        return item
    }

    /// Routes a table-bar action to the whole table (append/delete at the
    /// end, header toggle). Precise insert-at-row/col lives in each cell's
    /// context menu. One action is one undo step via `touch()`.
    private func applyTable(_ action: TableAction) {
        guard let target = tableTargetItem, !target.isLocked else { return }
        var t = target.getTable()
        switch action {
        case .addRow:
            guard t.appendRow() else { return }
        case .deleteRow:
            guard t.deleteRow(at: t.rows - 1) else { return }
        case .addColumn:
            guard t.appendColumn() else { return }
        case .deleteColumn:
            guard t.deleteColumn(at: t.cols - 1) else { return }
        case .toggleHeader:
            t.hasHeader.toggle()
        }
        target.setTable(t)
        growTableFrame(target, for: t)
        sanitizeTableSelection(for: t)
        touch()
    }

    /// Prunes the lifted cell selection after a structural edit so it never
    /// points past the grid.
    private func sanitizeTableSelection(for t: TableContent) {
        tableSelectedCells = t.sanitizedCells(tableSelectedCells)
        if let anchor = tableAnchorCell, !t.isValid(anchor) {
            tableAnchorCell = tableSelectedCells.first
        }
    }

    /// Keeps a minimum usable cell size when the grid grows via the bar.
    private func growTableFrame(_ target: CanvasItem, for t: TableContent) {
        let minCellW: Double = 90
        let minRowH: Double = 32
        let needW = Double(t.cols) * minCellW
        let needH = Double(t.rows) * minRowH + (t.hasHeader ? 8 : 0)
        if target.width < needW { target.width = needW }
        if target.height < needH { target.height = needH }
    }

    /// Format bar floating just above the selected table (flips below when
    /// too close to the top edge so it never clips off-screen). In writing
    /// mode with cells selected, the cell format pills (text attributes +
    /// fill, same options as text boxes) stack above the row/column bar.
    @ViewBuilder
    private func tableToolbarOverlay(vp: Viewport) -> some View {
        if let target = tableTargetItem, !target.isLocked {
            let table = target.getTable()
            let origin = CGPoint(x: CGFloat(target.x) * vp.scale + vp.offset.width,
                                 y: CGFloat(target.y) * vp.scale + vp.offset.height)
            let height = CGFloat(target.height) * vp.scale
            let stack = VStack(spacing: 8) {
                if isEditingTableCell(target) {
                    TextFormatToolbar(state: cellTextState(for: target)) { applyCellRich($0) }
                        .fixedSize()
                    TableCellFillToolbar(values: cellFillValues(for: target)) { setCellFill($0) }
                        .fixedSize()
                }
                TableFormatToolbar(table: table) { applyTable($0) }
                    .fixedSize()
            }
            .onTapGesture {} // swallow taps so the canvas doesn't deselect below
            if origin.y >= 64 {
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: .bottomLeading) { stack }
                    .offset(x: max(8, origin.x), y: max(8, origin.y - 8))
            } else {
                stack
                    .offset(x: max(8, origin.x), y: origin.y + height + 8)
            }
        }
    }

    // MARK: Table cell formatting

    /// True while the user is in writing mode inside the target table with
    /// at least one cell selected — the cell format pills show then.
    private func isEditingTableCell(_ target: CanvasItem) -> Bool {
        editingID == target.id && !tableSelectedCells.isEmpty
    }

    /// Cells the format actions apply to: the lifted selection, pruned to
    /// the current grid.
    private func formatCells(for target: CanvasItem) -> [TableCellRef] {
        let t = target.getTable()
        return tableSelectedCells.filter { t.isValid($0) }.sorted {
            $0.row == $1.row ? $0.col < $1.col : $0.row < $1.row
        }
    }

    /// Aggregate toolbar state over the selected cells, like text boxes:
    /// traits are on only when every cell has them; size/color/alignment
    /// are set only when unanimous, else nil (mixed).
    private func cellTextState(for target: CanvasItem) -> RichTextState {
        var state = RichTextState()
        let t = target.getTable()
        let cells = formatCells(for: target)
        guard !cells.isEmpty else { return state }
        state.hasSelection = true
        let styles = cells.map { t.styleAt($0) }
        state.bold = styles.allSatisfy(\.bold)
        state.italic = styles.allSatisfy(\.italic)
        state.underline = styles.allSatisfy(\.underline)
        state.strikethrough = styles.allSatisfy(\.strikethrough)
        let sizes = Set(styles.map { $0.fontSize ?? target.fontSize })
        if sizes.count == 1 { state.fontSize = sizes.first.map { CGFloat($0) } }
        let colors = Set(styles.map { ($0.colorHex ?? Palette.autoInk).uppercased() })
        if colors.count == 1 { state.colorHex = colors.first }
        let aligns = Set(styles.map { $0.alignmentRaw })
        if aligns.count == 1, let raw = aligns.first {
            state.alignment = tableCellAlignment(from: raw)
        }
        return state
    }

    /// Routes a text-format action to every selected cell at once (one undo
    /// step). Bool traits use all-or-set semantics: on only when all are on.
    private func applyCellRich(_ action: RichTextAction) {
        guard let target = tableTargetItem, !target.isLocked else { return }
        let cells = Set(formatCells(for: target))
        guard !cells.isEmpty else { return }
        var t = target.getTable()
        switch action {
        case .bold:
            let allOn = cells.allSatisfy { t.styleAt($0).bold }
            t.updateStyles(at: cells) { $0.bold = !allOn }
        case .italic:
            let allOn = cells.allSatisfy { t.styleAt($0).italic }
            t.updateStyles(at: cells) { $0.italic = !allOn }
        case .underline:
            let allOn = cells.allSatisfy { t.styleAt($0).underline }
            t.updateStyles(at: cells) { $0.underline = !allOn }
        case .strikethrough:
            let allOn = cells.allSatisfy { t.styleAt($0).strikethrough }
            t.updateStyles(at: cells) { $0.strikethrough = !allOn }
        case .sizePlus:
            let base = target.fontSize
            t.updateStyles(at: cells) {
                $0.fontSize = min(96, max(8, ($0.fontSize ?? base) + 1))
            }
        case .sizeMinus:
            let base = target.fontSize
            t.updateStyles(at: cells) {
                $0.fontSize = min(96, max(8, ($0.fontSize ?? base) - 1))
            }
        case .size(let pointSize):
            let clamped = min(96, max(8, Double(pointSize)))
            t.updateStyles(at: cells) { $0.fontSize = clamped }
        case .color(let hex):
            let stored: String? = hex.uppercased() == Palette.autoInk ? nil : hex
            t.updateStyles(at: cells) { $0.colorHex = stored }
        case .alignment(let alignment):
            let raw = tableCellAlignmentRaw(alignment)
            t.updateStyles(at: cells) { $0.alignmentRaw = raw }
        }
        target.setTable(t)
        touch()
    }

    /// Fill values (one per selected cell) for the fill pill; nil = default.
    private func cellFillValues(for target: CanvasItem) -> [String?] {
        let t = target.getTable()
        return formatCells(for: target).map { t.styleAt($0).backgroundHex }
    }

    /// Sets the fill of every selected cell (nil resets to the default).
    private func setCellFill(_ hex: String?) {
        guard let target = tableTargetItem, !target.isLocked else { return }
        let cells = Set(formatCells(for: target))
        guard !cells.isEmpty else { return }
        var t = target.getTable()
        t.updateStyles(at: cells) { $0.backgroundHex = hex }
        target.setTable(t)
        touch()
    }

    // MARK: Pin notes

    /// The lone selected pin note, if any — the details/editor card anchors
    /// to it.
    private var noteTargetItem: CanvasItem? {
        guard selectedItems.count == 1,
              let item = selectedItems.first,
              item.kind == .note else { return nil }
        return item
    }

    /// Details card (tap the pin) or editor card (writing mode), floating
    /// just above the pin and flipping below near the top edge. The pin
    /// itself stays a collapsed icon either way.
    @ViewBuilder
    private func noteCard(for target: CanvasItem) -> some View {
        if editingID == target.id, !target.isLocked {
            NoteEditorCard(
                text: Binding(get: { target.text }, set: { target.text = $0 }),
                colorHex: target.colorHex,
                focused: $noteEditorFocused
            ) {
                // Done: collapse back to the pin icon. Blank notes
                // are trashed by finishEditing, like text boxes.
                editingID = nil
            }
        } else {
            NoteDetailsCard(item: target) {
                beginEditing(target)
            } onDelete: {
                softDelete(target)
                touch()
            }
        }
    }

    @ViewBuilder
    private func noteCardOverlay(vp: Viewport) -> some View {
        if let target = noteTargetItem {
            // Pins draw at a constant 32pt on screen centered on their world
            // center — anchor the card to that visual position, not the
            // world top-left, so it tracks correctly at any zoom.
            let pinDiameter: CGFloat = 24
            let center = CGPoint(
                x: (CGFloat(target.x) + CGFloat(target.width) / 2) * vp.scale + vp.offset.width,
                y: (CGFloat(target.y) + CGFloat(target.height) / 2) * vp.scale + vp.offset.height)
            let origin = CGPoint(x: center.x - pinDiameter / 2, y: center.y - pinDiameter / 2)
            if origin.y >= 320 {
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: .bottomLeading) {
                        noteCard(for: target).fixedSize()
                    }
                    .offset(x: max(8, origin.x), y: max(8, origin.y - 8))
            } else {
                noteCard(for: target)
                    .offset(x: max(8, origin.x), y: origin.y + pinDiameter + 8)
            }
        }
    }

    /// Undo/redo plus the voice-note card side by side in the top right.
    /// The card is an overlay (never a sheet) so the canvas stays fully
    /// usable mid-take.
    private func topRightCluster() -> some View {
        HStack(alignment: .top, spacing: 8) {
            voiceRecorderCard()
            undoRedoPill()
        }
        .padding(.top, 12)
        .padding(.trailing, 12)
    }

    /// Undo/redo lives in its own floating pill on the canvas' trailing
    /// side — deliberately NOT in the toolbar, so it can never render
    /// attached to the zoom-out button.
    private func undoRedoPill() -> some View {
        HStack(spacing: 18) {
            Button { performUndo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(context.undoManager?.canUndo ?? false))
            Button { performRedo() } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!(context.undoManager?.canRedo ?? false))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    @ToolbarContentBuilder
    private var canvasToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showCanvasSettings.toggle() } label: {
                Label("Canvas", systemImage: "rectangle.dashed")
            }
            .help("Canvas size, colour and pattern")
            Button { zoom(by: 0.8) } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            Button { resetView() } label: {
                Text("\(Int((liveViewport.scale * 100).rounded()))%").monospacedDigit()
            }
            Button { zoom(by: 1.25) } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            Menu {
                Button { exportBoardPNG() } label: {
                    Label("Export board as PNG…", systemImage: "photo")
                }
                .disabled(pageItems.isEmpty)
                Button { exportSelectionPNG() } label: {
                    Label("Export selection as PNG…", systemImage: "photo.on.rectangle")
                }
                .disabled(selectedItems.isEmpty)
                Button { exportBoardPDF() } label: {
                    Label("Export as PDF…", systemImage: "doc.richtext")
                }
                .disabled(visibleItems.isEmpty)
                Button { exportBoardSVG() } label: {
                    Label("Export as SVG…", systemImage: "square.on.circle")
                }
                .disabled(pageItems.isEmpty)
                Divider()
                Button { fitContentToPaper() } label: {
                    Label("Fit everything onto the paper", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(board.sheetWorldRect == nil || pageItems.isEmpty)
                Divider()
                Button { beginExport() } label: {
                    Label("Save a copy (.vsom)…", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut("s", modifiers: .command)
                Button { onOpenBoardFile() } label: {
                    Label("Open a board file…", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button { showAbout = true } label: {
                    Label("About OpenMind…", systemImage: "info.circle")
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export this board (PNG, PDF, SVG, OpenMind file)")
        }
    }

    /// Stages this board for the save panel and presents it.
    private func beginExport() {
        guard let data = try? exportBoard(board) else { return }
        exportDoc = VSOMFileDocument(data: data)
        showExporter = true
    }

    // MARK: Media export (PNG / PDF / SVG)

    /// Paper color for paged boards, plain white for the infinite canvas.
    private var exportBackground: Color {
        if board.sheetWorldRect != nil {
            return Color(hex: board.canvasColorHex)
        }
        return Color.white
    }

    private var exportBackgroundHex: String {
        board.sheetWorldRect != nil ? board.canvasColorHex : "FFFFFF"
    }

    private func presentMediaExport(data: Data, contentType: UTType, filename: String) {
        mediaDoc = ExportFileDocument(data: data)
        mediaType = contentType
        mediaFilename = filename
        showMediaExporter = true
    }

    /// Renders one item set to PNG bytes at a capped retina scale.
    private func pngData(items: [CanvasItem], bounds: CGRect) -> Data? {
        let scale = exportPixelScale(for: bounds.size)
        return renderExportPNG(items: items, bounds: bounds,
                               background: exportBackground, pixelScale: scale)
    }

    /// Current page as a PNG file.
    private func exportBoardPNG() {
        let items = pageItems
        guard let bounds = exportContentBounds(items: items),
              let data = pngData(items: items, bounds: bounds)
        else { return }
        presentMediaExport(data: data, contentType: .png,
                           filename: mediaExportFilename(title: board.title, ext: "png"))
    }

    /// Current selection as a PNG file.
    private func exportSelectionPNG() {
        let items = selectedItems
        guard !items.isEmpty,
              let bounds = exportContentBounds(items: items),
              let data = pngData(items: items, bounds: bounds)
        else { return }
        presentMediaExport(data: data, contentType: .png,
                           filename: mediaExportFilename(title: board.title,
                                                         suffix: "selection", ext: "png"))
    }

    /// Every non-empty page as one PDF page (single content page for the
    /// infinite canvas).
    private func exportBoardPDF() {
        var pages: [ExportPDFPage] = []
        if board.isPaged {
            for p in 0..<board.pageCount {
                let items = visibleItems.filter { $0.pageIndex == p }
                guard let bounds = exportContentBounds(items: items) else { continue }
                pages.append(ExportPDFPage(items: items, bounds: bounds,
                                           background: exportBackground))
            }
        } else if let bounds = exportContentBounds(items: pageItems) {
            pages.append(ExportPDFPage(items: pageItems, bounds: bounds,
                                       background: exportBackground))
        }
        guard !pages.isEmpty, let data = renderExportPDF(pages: pages) else { return }
        presentMediaExport(data: data, contentType: .pdf,
                           filename: mediaExportFilename(title: board.title, ext: "pdf"))
    }

    /// Current page as a standalone vector SVG file.
    private func exportBoardSVG() {
        let items = pageItems
        guard let bounds = exportContentBounds(items: items) else { return }
        let svg = svgDocument(items: items, bounds: bounds,
                              backgroundHex: exportBackgroundHex)
        presentMediaExport(data: Data(svg.utf8), contentType: .svg,
                           filename: mediaExportFilename(title: board.title, ext: "svg"))
    }

    /// Scales the current page's unlocked content to fit inside the sheet,
    /// centered with a margin. One undo step. Infinite boards have no paper,
    /// so the menu disables the item there.
    private func fitContentToPaper() {
        guard let sheet = board.sheetWorldRect else { return }
        var content: CGRect?
        for item in pageItems {
            content = content?.union(item.frameRect) ?? item.frameRect
        }
        guard let content, let t = fitTransform(content: content, sheet: sheet)
        else { return }
        var moved = false
        for item in pageItems where !item.isLocked {
            applyFitTransform(t, to: item)
            moved = true
        }
        if moved { touch() }
    }

    private func handleGeoSizeChange(_ newSize: CGSize) {
        viewSize = newSize
        if !didCenter, newSize.width > 0 {
            viewport = Viewport.centered(on: CanvasMetrics.center, in: newSize)
            didCenter = true
        }
    }

    private func handleToolChange() {
        // Leaving a tool abandons its transient state; a stuck marquee
        // or group offset would otherwise haunt the next interaction.
        // An in-flight eraser grouping is closed first so later edits never
        // join the abandoned drag's undo group.
        if eraseGroupingOpen {
            context.undoManager?.endUndoGrouping()
            eraseGroupingOpen = false
        }
        if didEraseInDrag {
            didEraseInDrag = false
            touch()
        }
        activeStrokeScreen = []
        activeEraserScreen = nil
        brushHoverScreen = nil
        lastEraseScreen = nil
        marqueeStart = nil
        marqueeCurrent = nil
        shapeDragStart = nil
        shapeDragCurrent = nil
        lineAnchorWorld = nil
        lineHoverScreen = nil
        groupDragIDs = []
        groupDragOffset = .zero
        cancelMultiResize()
        #if os(macOS)
        updateCursor()
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            geometryBody(geo: geo)
        }
        .navigationTitle(board.title)
        .onChange(of: editingID) { oldValue, _ in
            finishEditing(oldValue)
        }
        .onChange(of: tool) {
            handleToolChange()
        }
        .withModelUndo()
        .onReceive(ModelUndoModifier.undoChangePublisher) { _ in undoRevision += 1 }
        .focusableWithoutRing()
        .onKeyPress(.delete) { deleteSelectionKeyPress() }
        .onKeyPress(.deleteForward) { deleteSelectionKeyPress() }
        .onKeyPress(.space, phases: .down) { _ in toggleAudioPlaybackKeyPress() }
        .onKeyPress(keys: ["a"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            return selectAllKeyPress()
        }
        .onKeyPress(keys: ["l", "L"]) { press in
            guard press.modifiers.contains(.command),
                  press.modifiers.contains(.shift) else { return .ignored }
            return toggleLockSelectionKeyPress()
        }
        .onKeyPress(keys: ["g", "G"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            if press.modifiers.contains(.shift) {
                return ungroupKeyPress()
            } else {
                return groupKeyPress()
            }
        }
        .onKeyPress(.escape) {
            // First Esc drops a pending line anchor, second disarms the tool.
            if lineAnchorWorld != nil {
                lineAnchorWorld = nil
                lineHoverScreen = nil
                shapeDragStart = nil
                shapeDragCurrent = nil
                return .handled
            }
            guard tool.isShapePlacing else { return .ignored }
            tool = .select
            handleToolChange()
            return .handled
        }
        .onPasteCommand(of: [.image, .fileURL]) { _ in
            pasteImageFromClipboard()
        }
        .toolbar {
            canvasToolbar
        }
        .inspector(isPresented: $showCanvasSettings) {
            CanvasSettingsView(board: board)
                .inspectorColumnWidth(min: 280, ideal: 300, max: 340)
        }
        .onDisappear {
            if voiceRecorder.isRecording { voiceRecorder.cancel() }
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .fileExporter(isPresented: $showExporter,
                      document: exportDoc,
                      contentType: .vsomBoard,
                      defaultFilename: vsomDefaultFilename(title: board.title)) { _ in }
        .fileExporter(isPresented: $showMediaExporter,
                      document: mediaDoc,
                      contentType: mediaType,
                      defaultFilename: mediaFilename) { _ in }
    }

    // MARK: Gestures

    /// Empty-space drag: pans when the hand is active, otherwise draws a
    /// marquee selection. One gesture branches on `panGestureEnabled` so the
    /// two never compete for the same touch.
    private func emptySpaceGesture(vp: Viewport) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .updating($panDelta) { value, state, _ in
                state = panGestureEnabled ? value.translation : .zero
            }
            .onChanged { value in
                if panGestureEnabled {
                    isPanning = true
                } else if tool == .select {
                    if marqueeStart == nil {
                        marqueeStart = value.startLocation
                        marqueeAdditive = isShiftHeld
                        marqueeInitial = selectedIDs
                        editingID = nil
                    }
                    marqueeCurrent = value.location
                    updateMarqueeSelection(vp: vp)
                }
            }
            .onEnded { value in
                if panGestureEnabled {
                    isPanning = false
                    viewport = viewport.applying(pan: value.translation, around: center)
                } else {
                    // A real drag keeps its live selection; a tap never
                    // reaches here (minimumDistance) and clears via onTapGesture.
                    marqueeStart = nil
                    marqueeCurrent = nil
                }
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .updating($zoomDelta) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                viewport = viewport.applying(zoom: value.magnification, around: center)
            }
    }

    // MARK: Note placement (locations are canvas-local screen points)

    /// Click-to-place for the note tool: a tap on empty canvas drops a pin
    /// and opens its editor. Taps on existing items never reach here (they
    /// hit the item above), and drags belong to the empty-space gesture.
    /// A tap outside while an editor/card is open just closes it (leaving
    /// the small pin icon) instead of stacking another pin, so the same
    /// tap can never both close and place.
    private func notePlacementGesture(vp: Viewport) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .local)
            .onEnded { value in
                guard tool == .note, !isTemporaryPan else { return }
                if editingID != nil || !selectedIDs.isEmpty {
                    editingID = nil
                    selectedIDs = []
                    return
                }
                placeNote(at: value.location, vp: vp)
            }
    }

    /// Drops a pin note centered on the tapped screen point and opens its
    /// writing UI immediately; closing collapses it to the small pin icon.
    /// The tool stays active so further clicks place more notes (tap the
    /// tool again or press V to exit).
    private func placeNote(at screen: CGPoint, vp: Viewport) {
        let world = vp.worldPoint(for: screen)
        let size = ItemKind.note.defaultSize
        let top = (pageItems.map(\.zIndex).max() ?? 0) + 1
        let item = CanvasItem(kind: .note,
                              x: world.x - size.width / 2,
                              y: world.y - size.height / 2,
                              zIndex: top)
        context.insert(item)
        item.board = board
        item.pageIndex = clampedPage
        selectedIDs = [item.id]
        editingID = item.id
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        touch()
    }

    // MARK: Drawing gestures (locations are canvas-local screen points)

    private func drawGesture(vp: Viewport) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if penStyle.isStraight {
                    if activeStrokeScreen.isEmpty {
                        activeStrokeScreen = [value.startLocation, value.location]
                    } else {
                        activeStrokeScreen = [activeStrokeScreen[0], value.location]
                    }
                } else {
                    if activeStrokeScreen.isEmpty {
                        activeStrokeScreen = [value.startLocation]
                    }
                    if let last = activeStrokeScreen.last,
                       hypot(value.location.x - last.x, value.location.y - last.y) >= 3 {
                        activeStrokeScreen.append(value.location)
                    }
                }
            }
            .onEnded { _ in
                commitStroke(vp: vp)
            }
    }

    private func eraseGesture(vp: Viewport) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let current = value.location
                let previous = lastEraseScreen ?? current
                if !eraseGroupingOpen {
                    context.undoManager?.beginUndoGrouping()
                    eraseGroupingOpen = true
                }
                activeEraserScreen = current
                let a = vp.worldPoint(for: previous)
                let b = vp.worldPoint(for: current)
                if eraseAlongSegment(from: a, to: b) {
                    didEraseInDrag = true
                }
                lastEraseScreen = current
            }
            .onEnded { value in
                let current = value.location
                let previous = lastEraseScreen ?? current
                activeEraserScreen = nil
                lastEraseScreen = nil
                let a = vp.worldPoint(for: previous)
                let b = vp.worldPoint(for: current)
                if eraseGroupingOpen {
                    if eraseAlongSegment(from: a, to: b) {
                        didEraseInDrag = true
                    }
                }
                // Single save per drag so one erase stroke is one undo step.
                if didEraseInDrag {
                    didEraseInDrag = false
                    touch()
                }
                if eraseGroupingOpen {
                    context.undoManager?.endUndoGrouping()
                    eraseGroupingOpen = false
                }
            }
    }

    // MARK: Shape placement (locations are canvas-local screen points)

    /// Drag-to-size placement for the shape tool: press anywhere and drag to
    /// frame the new shape. Holding Shift locks a square ratio (rectangle →
    /// square, ellipse → circle, lines → 45°). A plain tap drops a
    /// default-sized shape. The tool stays active for further placements.
    private func shapeGesture(vp: Viewport) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if shapeDragStart == nil {
                    shapeDragStart = value.startLocation
                    editingID = nil
                }
                shapeDragCurrent = value.location
            }
            .onEnded { value in
                defer {
                    shapeDragStart = nil
                    shapeDragCurrent = nil
                }
                guard let kind = tool.shapeKind else { return }
                let rect = shapeScreenRect(from: value.startLocation,
                                           to: value.location,
                                           locked: isShiftHeld)
                if rect.width < 6 && rect.height < 6 {
                    addShape(kind: kind, at: vp.worldPoint(for: value.location))
                } else {
                    addShape(kind: kind, in: vp.worldRect(for: rect))
                }
            }
    }

    /// Creates a shape item filling `world` (already normalized).
    private func addShape(kind: ShapeKind, in world: CGRect) {
        guard world.width >= 4 && world.height >= 4 else { return }
        let top = (pageItems.map(\.zIndex).max() ?? 0) + 1
        let item = CanvasItem(kind: .shape, shape: kind,
                              x: Double(world.minX), y: Double(world.minY),
                              zIndex: Double(top))
        item.width = Double(world.width)
        item.height = Double(world.height)
        context.insert(item)
        item.board = board
        item.pageIndex = clampedPage
        selectedIDs = [item.id]
        editingID = nil
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        touch()
    }

    /// Drops a default-sized shape centered on `worldCenter` (tap-to-place).
    /// Shift still squares the frame.
    private func addShape(kind: ShapeKind, at worldCenter: CGPoint) {
        var size = ItemKind.shape.defaultSize
        if isShiftHeld {
            let side = max(size.width, size.height)
            size = CGSize(width: side, height: side)
        }
        let world = CGRect(x: worldCenter.x - size.width / 2,
                           y: worldCenter.y - size.height / 2,
                           width: size.width, height: size.height)
        addShape(kind: kind, in: world)
    }

    /// Tapping a shape arms placement (crosshair + drag-to-size); tapping the
    /// armed shape again disarms back to select.
    private func selectShape(_ kind: ShapeKind) {
        if tool == .shape(kind) {
            tool = .select
        } else {
            editingID = nil
            tool = .shape(kind)
        }
        handleToolChange()
    }

    // MARK: Line placement — tap point A, tap point B (or drag A→B)

    /// Point-to-point placement for line-like shapes. A tap sets anchor A
    /// (accent marker); the next tap sets B and draws the line. A real drag
    /// draws directly from press to release. Shift snaps to 45° increments.
    /// The tool stays armed for further lines.
    private func lineGesture(vp: Viewport) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if shapeDragStart == nil {
                    shapeDragStart = value.startLocation
                    editingID = nil
                }
                shapeDragCurrent = value.location
            }
            .onEnded { value in
                defer {
                    shapeDragStart = nil
                    shapeDragCurrent = nil
                }
                guard let kind = tool.shapeKind, kind.isLineLike else { return }
                let px = hypot(value.location.x - value.startLocation.x,
                               value.location.y - value.startLocation.y)
                if px < 6 {
                    handleLineTap(at: value.location, vp: vp)
                } else {
                    let a = vp.worldPoint(for: value.startLocation)
                    var b = vp.worldPoint(for: value.location)
                    if isShiftHeld { b = snappedLineEnd(from: a, to: b) }
                    addLine(kind: kind, from: a, to: b)
                    lineAnchorWorld = nil
                    lineHoverScreen = nil
                }
            }
    }

    private func handleLineTap(at screen: CGPoint, vp: Viewport) {
        guard let kind = tool.shapeKind, kind.isLineLike else { return }
        let world = vp.worldPoint(for: screen)
        if let anchor = lineAnchorWorld {
            let aScreen = vp.screenPoint(for: anchor)
            // A second tap in place is a no-op (keeps the anchor).
            guard hypot(screen.x - aScreen.x, screen.y - aScreen.y) >= 6 else { return }
            var b = world
            if isShiftHeld { b = snappedLineEnd(from: anchor, to: world) }
            addLine(kind: kind, from: anchor, to: b)
            lineAnchorWorld = nil
            lineHoverScreen = nil
        } else {
            lineAnchorWorld = world
            // Seed the rubber-band tip at point A so the line/arrow/
            // double-arrow preview is visible immediately — the next mouse
            // move then stretches it from A to the cursor.
            lineHoverScreen = screen
        }
    }

    /// Creates a line-like shape from world-space endpoints A→B. The frame
    /// is their tight bounding box (padded to a 12pt minimum so thin lines
    /// stay selectable); the line itself is stored as normalized
    /// box-fraction endpoints (see `lineEndpoints`), so any direction works
    /// and resize stretches it with its frame.
    private func addLine(kind: ShapeKind, from a: CGPoint, to b: CGPoint) {
        guard hypot(b.x - a.x, b.y - a.y) >= 2 else { return }
        let minBox: CGFloat = 12
        var minX = min(a.x, b.x), minY = min(a.y, b.y)
        var w = abs(b.x - a.x), h = abs(b.y - a.y)
        if w < minBox { let d = (minBox - w) / 2; minX -= d; w = minBox }
        if h < minBox { let d = (minBox - h) / 2; minY -= d; h = minBox }
        let top = (pageItems.map(\.zIndex).max() ?? 0) + 1
        let item = CanvasItem(kind: .shape, shape: kind,
                              x: Double(minX), y: Double(minY),
                              zIndex: Double(top))
        item.width = Double(w)
        item.height = Double(h)
        item.lineEndpoints = [CGPoint(x: (a.x - minX) / w, y: (a.y - minY) / h),
                              CGPoint(x: (b.x - minX) / w, y: (b.y - minY) / h)]
        context.insert(item)
        item.board = board
        item.pageIndex = clampedPage
        selectedIDs = [item.id]
        editingID = nil
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        touch()
    }

    /// Erases the portion of every drawing stroke covered by the eraser
    /// segment `a`–`b` (world points). Surviving runs stay in place; a stroke
    /// split in the middle becomes separate items. No save here — the caller
    /// saves once at drag end so the whole drag undoes together.
    /// - Returns: true when any ink was removed.
    @discardableResult
    private func eraseAlongSegment(from a: CGPoint, to b: CGPoint) -> Bool {
        let eraser = CGFloat(eraserWidth)
        guard eraser > 0 else { return false }
        // Fast reject: eraser bounding box in world space.
        let pad = eraser / 2 + 8
        let eraseBox = CGRect(x: min(a.x, b.x) - pad, y: min(a.y, b.y) - pad,
                              width: abs(a.x - b.x) + pad * 2,
                              height: abs(a.y - b.y) + pad * 2)
        var removedAny = false
        // Snapshot: eraseAlongSegment mutates/inserts while iterating.
        // Locked drawings are protected from the eraser. Only the current
        // page erases — strokes on other pages are separate canvases.
        let page = clampedPage
        for item in board.items.filter({ $0.kind == .drawing && !$0.isTrashed && !$0.isLocked && $0.pageIndex == page }) {
            guard eraseBox.intersects(item.frameRect) else { continue }
            let local = item.strokePoints
            guard local.count >= 2 else { continue }
            let world = local.map { CGPoint(x: $0.x + CGFloat(item.x), y: $0.y + CGFloat(item.y)) }
            guard let runs = eraseRuns(worldPoints: world, style: item.strokeStyle,
                                       lineWidth: CGFloat(item.lineWidth),
                                       eraserA: a, eraserB: b, eraserWidth: eraser) else {
                continue
            }
            removedAny = true
            if runs.isEmpty {
                softDelete(item)
            } else {
                // First run stays in the original item; the rest become new items.
                // (eraseRuns only returns runs with >= 2 points, so all runs render.)
                item.adoptStroke(worldPoints: runs[0])
                var top = pageItems.map(\.zIndex).max() ?? 0
                for run in runs.dropFirst() {
                    top += 1
                    let piece = CanvasItem(kind: .drawing,
                                           strokeStyle: item.strokeStyle,
                                           x: 0, y: 0,
                                           colorHex: item.colorHex,
                                           lineWidth: item.lineWidth,
                                           zIndex: top)
                    piece.adoptStroke(worldPoints: run)
                    context.insert(piece)
                    piece.board = board
                    piece.pageIndex = item.pageIndex
                }
            }
        }
        return removedAny
    }

    // MARK: Viewport actions

    #if os(macOS)
    /// Select arrow by default, crosshair (+) while placing notes or shapes,
    /// open hand while Option is held or the hand tool is active, closed hand
    /// mid-pan. Called on state changes (and on every mouse move while the
    /// hand is active); otherwise the system cursor is left alone.
    private func updateCursor() {
        guard isHovering else { return }
        if isPanning {
            NSCursor.closedHand.set()
        } else if tool == .note || tool.isShapePlacing {
            NSCursor.crosshair.set()
        } else if isOptionHeld || tool == .hand {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
    #endif

    private func zoom(by factor: CGFloat) {
        viewport = viewport.applying(zoom: factor, around: center)
    }

    private func resetView() {
        viewport = Viewport.centered(on: CanvasMetrics.center, in: viewSize)
    }

    // MARK: Item actions

    /// Tap selection. Never touches the stacking order: selecting only
    /// highlights, and layering changes solely via the Arrange commands.
    /// Plain click selects exclusively; Shift-click toggles.
    /// Shift-clicks on cells of an already-selected table belong to the
    /// table's range selection (see TableItemView) and must not toggle the
    /// item itself — the cell tap bubbles here too.
    /// Grouped items always act as one: clicking (or Shift-toggling) any
    /// member selects/toggles the whole group.
    private func select(_ item: CanvasItem) {
        if isShiftHeld, item.kind == .table, selectedIDs.contains(item.id) { return }
        let members = groupMembers(of: item)
        if isShiftHeld {
            editingID = nil
            if members.isSubset(of: selectedIDs) {
                selectedIDs.subtract(members)
            } else {
                selectedIDs.formUnion(members)
            }
        } else {
            if editingID != item.id { editingID = nil }
            // Fast path: expanding an ungrouped ID is a no-op, so skip the
            // full page scan that `expandIDsForGroups` performs. Grouped
            // clicks keep the full expansion below.
            if item.groupID == nil {
                selectedIDs = members
            } else {
                selectedIDs = expandIDsForGroups(members)
            }
        }
    }

    /// All IDs sharing `item`'s group on this page (just itself when
    /// ungrouped). Trashed items never join.
    private func groupMembers(of item: CanvasItem) -> Set<UUID> {
        guard let gid = item.groupID else { return [item.id] }
        let ids = pageItems.filter { $0.groupID == gid }.map(\.id)
        return ids.isEmpty ? [item.id] : Set(ids)
    }

    /// Expands any grouped IDs to their whole groups (same-page, visible).
    private func expandIDsForGroups(_ ids: Set<UUID>) -> Set<UUID> {
        var groups: [UUID: UUID?] = [:]
        groups.reserveCapacity(pageItems.count)
        for it in pageItems { groups[it.id] = it.groupID }
        return expandedForGroups(selected: ids, groups: groups)
    }

    private func beginEditing(_ item: CanvasItem) {
        guard !item.isLocked else { return }
        selectedIDs = [item.id]
        editingID = item.id
        if item.kind == .table {
            // Fresh cell selection; TableItemView seeds (0,0) on edit start.
            tableSelectedCells = []
            tableAnchorCell = nil
        }
    }

    // MARK: Marquee selection

    private func updateMarqueeSelection(vp: Viewport) {
        guard let start = marqueeStart, let current = marqueeCurrent else { return }
        let world = vp.worldRect(for: marqueeScreenRect(from: start, to: current))
        let frames = sortedItems.map(\.frameRect)
        let hits = framesIntersectingMarquee(frames: frames, marqueeWorld: world)
        let hitIDs = expandIDsForGroups(Set(hits.map { sortedItems[$0].id }))
        if marqueeAdditive {
            selectedIDs = expandIDsForGroups(marqueeInitial.union(hitIDs))
        } else {
            selectedIDs = hitIDs
        }
    }

    // MARK: Group drag

    /// First movement establishes which items move: the whole selection when
    /// the dragged item belongs to it, otherwise just that item (the view
    /// already made it the exclusive selection, or added it with Shift).
    /// Locked items never move: dragging a locked item is a no-op, and a
    /// mixed selection drags only its unlocked members.
    private func updateGroupDrag(_ item: CanvasItem, translation: CGSize) {
        guard !item.isLocked else { return }
        if groupDragIDs.isEmpty {
            let candidates: Set<UUID> = selectedIDs.contains(item.id) ? selectedIDs : [item.id]
            let movable = candidates.filter { id in
                pageItems.first(where: { $0.id == id })?.isLocked == false
            }
            guard !movable.isEmpty else { return }
            groupDragIDs = movable
            editingID = nil
        }
        groupDragOffset = CGSize(width: translation.width / liveViewport.scale,
                                 height: translation.height / liveViewport.scale)
    }

    private func endGroupDrag(translation: CGSize) {
        defer {
            groupDragIDs = []
            groupDragOffset = .zero
        }
        guard !groupDragIDs.isEmpty else { return }
        let dx = Double(translation.width / liveViewport.scale)
        let dy = Double(translation.height / liveViewport.scale)
        var moved = false
        for id in groupDragIDs {
            if let item = pageItems.first(where: { $0.id == id }), !item.isLocked {
                item.x += dx
                item.y += dy
                moved = true
            }
        }
        if moved { touch() }
    }

    // MARK: Grouping

    /// Grouping needs 2+ selected items. Locks don't block grouping itself
    /// (only moves/resizes); trash is already filtered from the selection.
    private var canGroup: Bool { canGroupSelection(count: selectedItems.count) }

    private var canUngroup: Bool {
        canUngroupSelection(selectedGroupIDs: selectedItems.map(\.groupID))
    }

    /// Merges the whole selection into one new group (existing groups merge).
    /// One undo step; the selection stays so the group can be moved/resized.
    private func groupSelected() {
        guard canGroup else { return }
        let gid = UUID()
        for item in selectedItems { item.groupID = gid }
        touch()
    }

    /// Dissolves every group touched by the selection. Clears the group ID
    /// from all page members (not just the selected ones) so no orphaned
    /// single-item groups survive.
    private func ungroupSelected() {
        guard canUngroup else { return }
        let gids = Set(selectedItems.compactMap(\.groupID))
        guard !gids.isEmpty else { return }
        for item in pageItems where item.groupID.map({ gids.contains($0) }) ?? false {
            item.groupID = nil
        }
        touch()
    }

    private func groupKeyPress() -> KeyPress.Result {
        guard editingID == nil, canGroup else { return .ignored }
        groupSelected()
        return .handled
    }

    private func ungroupKeyPress() -> KeyPress.Result {
        guard editingID == nil, canUngroup else { return .ignored }
        ungroupSelected()
        return .handled
    }

    /// Context-menu Group/Ungroup acting on Finder-style targets (the whole
    /// selection when the right-clicked item belongs to it, else just it).
    private func groupTargeting(_ item: CanvasItem) {
        if !selectedIDs.contains(item.id) {
            selectedIDs = expandIDsForGroups([item.id])
            editingID = nil
        }
        groupSelected()
    }

    private func ungroupTargeting(_ item: CanvasItem) {
        if !selectedIDs.contains(item.id) {
            selectedIDs = expandIDsForGroups([item.id])
            editingID = nil
        }
        ungroupSelected()
    }

    // MARK: Multi-select resize

    /// Items that fully scale (position + size). Pins keep a fixed frame and
    /// drawings size to their ink, so both move with the layout but keep
    /// their size (see `multiResizeLiveFrames`); locked items never resize.
    private func isMultiScalable(_ item: CanvasItem) -> Bool {
        !item.isLocked && item.kind != .note && item.kind != .drawing
    }

    /// Handle shows when 2+ unlocked items are selected (any mix — pins
    /// and drawings ride along by position). Single-item resize stays in
    /// `CanvasItemView`; this overlay owns the multi case.
    private var canMultiResize: Bool {
        guard selectedIDs.count >= 2, editingID == nil else { return false }
        return selectedItems.filter({ !$0.isLocked }).count >= 2
    }

    /// Static union of the resizable selection (world; locked items are
    /// excluded so the idle box matches the drag box). Live bounds during a
    /// drag come from `multiResizeDisplayBounds`.
    private var multiSelectionBounds: CGRect? {
        let frames = selectedItems.filter({ !$0.isLocked }).map(\.frameRect)
        return selectionUnion(frames: frames)
    }

    /// Bounds to draw: the live resized box while dragging, else the static
    /// selection union.
    private func multiResizeDisplayBounds() -> CGRect? {
        if let orig = multiResizeBoundsOrig, !multiResizeIDs.isEmpty {
            return multiResizeBounds(original: orig, dx: multiResizeDelta.width,
                                     dy: multiResizeDelta.height, locked: multiResizeLocked)
        }
        return multiSelectionBounds
    }

    /// Live world frames for every item in the drag, or nil when idle.
    /// Scalable members map through the bounds; pins/drawings move by
    /// center so they ride the layout without changing size.
    private func multiResizeLiveFrames() -> [UUID: CGRect]? {
        guard let orig = multiResizeBoundsOrig, !multiResizeIDs.isEmpty else { return nil }
        let next = multiResizeBounds(original: orig, dx: multiResizeDelta.width,
                                     dy: multiResizeDelta.height, locked: multiResizeLocked)
        let byID = Dictionary(uniqueKeysWithValues: pageItems.map { ($0.id, $0) })
        var out: [UUID: CGRect] = [:]
        out.reserveCapacity(multiResizeIDs.count)
        for id in multiResizeIDs {
            guard let base = multiResizeBase[id], let item = byID[id] else { continue }
            if isMultiScalable(item) {
                out[id] = scaledFrame(base, from: orig, to: next)
            } else {
                let c = CGPoint(x: base.midX, y: base.midY)
                let nc = scaledPoint(c, from: orig, to: next)
                out[id] = CGRect(x: nc.x - base.width / 2, y: nc.y - base.height / 2,
                                 width: base.width, height: base.height)
            }
        }
        return out
    }

    private var shiftActiveForResize: Bool {
#if os(macOS)
        if isShiftHeld { return true }
        return NSEvent.modifierFlags.contains(.shift)
#else
        return isShiftHeld
#endif
    }

    private func updateMultiResize(translation: CGSize) {
        guard multiResizeBoundsOrig != nil, !multiResizeIDs.isEmpty else { return }
        multiResizeDelta = CGSize(width: translation.width / liveViewport.scale,
                                  height: translation.height / liveViewport.scale)
        // Uniform by default so every member keeps its ratio; Shift frees
        // the bounds aspect for non-uniform stretching.
        multiResizeLocked = !shiftActiveForResize
    }

    private func endMultiResize(translation: CGSize) {
        defer {
            multiResizeIDs = []
            multiResizeBase = [:]
            multiResizeBoundsOrig = nil
            multiResizeDelta = .zero
            multiResizeLocked = false
        }
        guard let orig = multiResizeBoundsOrig, !multiResizeIDs.isEmpty else { return }
        let delta = CGSize(width: translation.width / liveViewport.scale,
                           height: translation.height / liveViewport.scale)
        let locked = !shiftActiveForResize
        let next = multiResizeBounds(original: orig, dx: delta.width, dy: delta.height, locked: locked)
        guard next.width > 0, next.height > 0 else { return }
        let byID = Dictionary(uniqueKeysWithValues: pageItems.map { ($0.id, $0) })
        var changed = false
        for id in multiResizeIDs {
            guard let base = multiResizeBase[id], let item = byID[id], !item.isLocked else { continue }
            if isMultiScalable(item) {
                let f = scaledFrame(base, from: orig, to: next)
                guard f.width > 0, f.height > 0 else { continue }
                item.x = Double(f.minX)
                item.y = Double(f.minY)
                item.width = Double(max(1, f.width))
                item.height = Double(max(1, f.height))
                changed = true
            } else {
                let c = CGPoint(x: base.midX, y: base.midY)
                let nc = scaledPoint(c, from: orig, to: next)
                item.x = Double(nc.x - base.width / 2)
                item.y = Double(nc.y - base.height / 2)
                changed = true
            }
        }
        if changed { touch() }
    }

    private func cancelMultiResize() {
        multiResizeIDs = []
        multiResizeBase = [:]
        multiResizeBoundsOrig = nil
        multiResizeDelta = .zero
        multiResizeLocked = false
    }

    private func addItem(_ kind: ItemKind, shape: ShapeKind = .rectangle) {
        // Images, PDFs, audio, YouTube embeds and videos always carry
        // data/URLs: they enter via their pickers, drops, or the URL prompt.
        guard kind != .image && kind != .pdf && kind != .audio && kind != .youtube && kind != .video else { return }
        let p = viewport.worldPoint(for: center)
        let size = kind.defaultSize
        let jitter = { CGFloat.random(in: -16...16) }

        let item = CanvasItem(
            kind: kind,
            shape: shape,
            x: p.x - size.width / 2 + jitter(),
            y: p.y - size.height / 2 + jitter(),
            zIndex: (pageItems.map(\.zIndex).max() ?? 0) + 1
        )
        context.insert(item)
        item.board = board
        item.pageIndex = clampedPage
        if kind == .table {
            item.setTable(TableContent.makeDefault())
        }
        selectedIDs = [item.id]
        if kind == .text || kind == .table { editingID = item.id }
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        touch()
    }

    // MARK: Image actions

    /// Creates an image item from raw bytes (photo picker, file import, drop).
    /// Downscales huge photos before storing and sizes the frame to the
    /// image's aspect ratio. `worldCenter` places the item; nil = viewport
    /// center with a small random offset like `addItem`.
    private func addImageItem(with data: Data, at worldCenter: CGPoint? = nil) {
        guard let stored = downscaledImageData(from: data),
              isImageData(stored)
        else { return }
        // True dimensions (nil only for unreadable bytes): cached verbatim so
        // later lookups match uncached behavior; the frame falls back to a
        // default size when dimensions are unknown.
        let truePixelSize = imagePixelSize(from: stored)
        let pixelSize = truePixelSize ?? ItemKind.image.defaultSize
        let size = fittedWorldSize(for: pixelSize)
        let origin: CGPoint
        if let c = worldCenter {
            origin = CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        } else {
            let p = viewport.worldPoint(for: center)
            let jitter = { CGFloat.random(in: -16...16) }
            origin = CGPoint(x: p.x - size.width / 2 + jitter(),
                             y: p.y - size.height / 2 + jitter())
        }
        let top = (pageItems.map(\.zIndex).max() ?? 0) + 1
        let item = CanvasItem(kind: .image, x: origin.x, y: origin.y, zIndex: top)
        item.width = Double(size.width)
        item.height = Double(size.height)
        item.imageData = stored
        // Dimensions are already known: pre-populate the view cache so the
        // first display never touches ImageIO in a view body.
        ImageResourceCache.storePixelSize(truePixelSize, forItem: item.id, data: stored)
        context.insert(item)
        item.board = board
        item.pageIndex = clampedPage
        selectedIDs = [item.id]
        editingID = nil
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        touch()
    }

    // MARK: Audio actions

    /// Creates an audio item from raw bytes (file import, drop). Stores the
    /// bytes verbatim plus the file name and probed duration for the tile.
    /// `worldCenter` places the item; nil = viewport center like `addItem`.
    private func addAudioItem(with data: Data, fileName: String = "", at worldCenter: CGPoint? = nil) {
        guard isAudioData(data) else { return }
        let size = ItemKind.audio.defaultSize
        let origin: CGPoint
        if let c = worldCenter {
            origin = CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        } else {
            let p = viewport.worldPoint(for: center)
            let jitter = { CGFloat.random(in: -16...16) }
            origin = CGPoint(x: p.x - size.width / 2 + jitter(),
                             y: p.y - size.height / 2 + jitter())
        }
        let top = (pageItems.map(\.zIndex).max() ?? 0) + 1
        let item = CanvasItem(kind: .audio, x: origin.x, y: origin.y, zIndex: top)
        item.width = Double(size.width)
        item.height = Double(size.height)
        item.audioData = data
        item.audioFileName = fileName
        item.audioDuration = audioDuration(data) ?? 0
        context.insert(item)
        item.board = board
        item.pageIndex = clampedPage
        selectedIDs = [item.id]
        editingID = nil
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        touch()
    }

    // MARK: YouTube actions

    /// Creates a YouTube embed from a pasted URL (or bare video ID). The raw
    /// string is stored verbatim; the tile derives the ID for playback, so
    /// any watch / share / embed / Shorts link works. Invalid input is
    /// ignored so the prompt can keep the text for fixing.
    /// `worldCenter` places the item; nil = viewport center like `addItem`.
    private func addYouTubeItem(with urlString: String, at worldCenter: CGPoint? = nil) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard youtubeVideoID(from: trimmed) != nil else { return }
        let size = ItemKind.youtube.defaultSize
        let origin: CGPoint
        if let c = worldCenter {
            origin = CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        } else {
            let p = viewport.worldPoint(for: center)
            let jitter = { CGFloat.random(in: -16...16) }
            origin = CGPoint(x: p.x - size.width / 2 + jitter(),
                             y: p.y - size.height / 2 + jitter())
        }
        let top = (pageItems.map(\.zIndex).max() ?? 0) + 1
        let item = CanvasItem(kind: .youtube, x: origin.x, y: origin.y, zIndex: top)
        item.width = Double(size.width)
        item.height = Double(size.height)
        item.youtubeURL = trimmed
        context.insert(item)
        item.board = board
        item.pageIndex = clampedPage
        selectedIDs = [item.id]
        editingID = nil
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        touch()
    }

    // MARK: Video actions

    /// Creates a video item from raw bytes (file import, drop — device
    /// storage, iCloud, or Google Drive via the system picker). Stores the
    /// bytes verbatim plus the file name and probed duration for the tile.
    /// `worldCenter` places the item; nil = viewport center like `addItem`.
    private func addVideoItem(with data: Data, fileName: String = "", at worldCenter: CGPoint? = nil) {
        guard isVideoData(data) else { return }
        let size = ItemKind.video.defaultSize
        let origin: CGPoint
        if let c = worldCenter {
            origin = CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        } else {
            let p = viewport.worldPoint(for: center)
            let jitter = { CGFloat.random(in: -16...16) }
            origin = CGPoint(x: p.x - size.width / 2 + jitter(),
                             y: p.y - size.height / 2 + jitter())
        }
        let top = (pageItems.map(\.zIndex).max() ?? 0) + 1
        let item = CanvasItem(kind: .video, x: origin.x, y: origin.y, zIndex: top)
        item.width = Double(size.width)
        item.height = Double(size.height)
        item.videoData = data
        item.videoFileName = fileName
        item.videoDuration = videoDuration(data) ?? 0
        context.insert(item)
        item.board = board
        item.pageIndex = clampedPage
        selectedIDs = [item.id]
        editingID = nil
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        touch()
    }

    // MARK: Network media actions

    /// Downloads a remote http(s) URL and creates the matching tile
    /// (image / audio / video) at `worldCenter`. Used by link drops; the
    /// From-URL sheet in `FloatingToolbar` downloads via `fetchNetworkMedia`
    /// and routes through `addImageItem` / `addAudioItem` / `addVideoItem`
    /// directly. Failures are silent (drops have no sheet for errors).
    private func addNetworkMedia(from url: URL, at worldCenter: CGPoint? = nil) {
        guard isRemoteNetworkURL(url) else { return }
        Task {
            do {
                let (data, response) = try await downloadNetworkData(from: url)
                let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
                    ?? response.mimeType
                guard let kind = classifyNetworkMedia(data: data, url: url, mimeType: mime) else { return }
                // Enforce the same per-kind caps as local imports.
                switch kind {
                case .audio where data.count > CanvasAudio.maxImportBytes: return
                case .video where data.count > CanvasVideo.maxImportBytes: return
                default: break
                }
                let fallback = kind == .image ? "image" : (kind == .audio ? "audio" : "video")
                let fileName = networkFileName(from: url, response: response, defaultName: fallback)
                await MainActor.run {
                    switch kind {
                    case .image:
                        self.addImageItem(with: data, at: worldCenter)
                    case .audio:
                        self.addAudioItem(with: data, fileName: fileName, at: worldCenter)
                    case .video:
                        self.addVideoItem(with: data, fileName: fileName, at: worldCenter)
                    default:
                        break
                    }
                }
            } catch {
                return
            }
        }
    }

    // MARK: Page navigation

    /// Flips to `page` (clamped). Pure view state: clears the selection so
    /// the new page starts clean, and never touches undo or `modifiedAt`.
    private func goToPage(_ page: Int) {
        currentPage = min(max(page, 0), max(0, board.pageCount - 1))
        selectedIDs = []
        editingID = nil
        tableSelectedCells = []
        tableAnchorCell = nil
        // A pending line anchor belongs to the old page — drop it so the
        // next tap can't stretch a line across pages.
        lineAnchorWorld = nil
        lineHoverScreen = nil
        shapeDragStart = nil
        shapeDragCurrent = nil
        groupDragIDs = []
        groupDragOffset = .zero
        cancelMultiResize()
    }

    /// Appends a blank page and flips to it. Structural, so one undo step.
    private func addPage() {
        let index = board.addPage()
        touch()
        goToPage(index)
    }

    /// Deletes the current page when it is empty (the pill hides the button
    /// otherwise). Higher pages shift down; never touches other content.
    private func deleteCurrentPage() {
        guard board.deletePage(at: clampedPage) else { return }
        touch()
        goToPage(clampedPage)
    }

    /// Page stepper for paged boards (any fixed size — Infinite has no page
    /// system). Stacked above the floating toolbar so it never covers canvas
    /// content or collides with the format pills.
    @ViewBuilder
    private var pageNavigator: some View {
        if board.isPaged {
            HStack(spacing: 10) {
                Button { goToPage(clampedPage - 1) } label: {
                    Label("Previous page", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .disabled(clampedPage <= 0)
                Text("\(clampedPage + 1) / \(board.pageCount)")
                    .font(.callout)
                    .monospacedDigit()
                    .frame(minWidth: 44)
                Button { goToPage(clampedPage + 1) } label: {
                    Label("Next page", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .disabled(clampedPage >= board.pageCount - 1)
                Divider().frame(height: 18)
                Button(action: addPage) {
                    Label("Add page", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help("Add page")
                if board.pageCount > 1 && pageItems.isEmpty {
                    Button(role: .destructive, action: deleteCurrentPage) {
                        Label("Delete this page", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .help("Delete this empty page")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .onTapGesture {} // swallow taps so the canvas doesn't deselect below
        }
    }

    /// Pastes whatever images are on the system clipboard (screenshots,
    /// Finder/Files copies, browser copies) at the viewport center. No-op
    /// when the clipboard holds no image, so text paste keeps working
    /// untouched (including inside the text editor).
    private func pasteImageFromClipboard() {
        let datas = clipboardImageDatas()
        guard !datas.isEmpty else { return }
        for data in datas {
            addImageItem(with: data)
        }
    }

    /// Accepts Finder / Photos / browser drops onto the canvas, plus remote
    /// http(s) link drops (e.g. dragging an image or video link from a
    /// browser). Each image, audio, or video file lands where it was
    /// dropped (stacked with a small offset when several arrive together).
    /// Returns true when at least one provider looks like media so the
    /// system shows the copy cursor.
    private func handleMediaDrop(providers: [NSItemProvider], location: CGPoint, vp: Viewport) -> Bool {
        let candidates = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            || $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
            || $0.hasItemConformingToTypeIdentifier(UTType.video.identifier)
            || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard !candidates.isEmpty else { return false }
        let dropWorld = vp.worldPoint(for: location)
        for (index, provider) in candidates.enumerated() {
            let offset = CGFloat(index * 20)
            let target = CGPoint(x: dropWorld.x + offset, y: dropWorld.y + offset)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL? = {
                        if let u = item as? URL { return u }
                        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                        return nil
                    }()
                    guard let url else { return }
                    // A remote http(s) URL can arrive as a fileURL-typed
                    // provider on some browsers — route it to the downloader.
                    if isRemoteNetworkURL(url) {
                        self.addNetworkMedia(from: url, at: target)
                        return
                    }
                    // Video first: containers like mp4/mov also satisfy the
                    // audio mapping, so the audio check would steal them.
                    // Images keep the existing path after both media checks.
                    if isVideoFileURL(url), let loaded = videoDataFromFileURL(url) {
                        Task { @MainActor in
                            self.addVideoItem(with: loaded.data, fileName: loaded.fileName, at: target)
                        }
                    } else if isAudioFileURL(url), let loaded = audioDataFromFileURL(url) {
                        Task { @MainActor in
                            self.addAudioItem(with: loaded.data, fileName: loaded.fileName, at: target)
                        }
                    } else if let data = imageDataFromFileURL(url) {
                        Task { @MainActor in
                            self.addImageItem(with: data, at: target)
                        }
                    } else if let loaded = audioDataFromFileURL(url) {
                        Task { @MainActor in
                            self.addAudioItem(with: loaded.data, fileName: loaded.fileName, at: target)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    let url: URL? = {
                        if let u = item as? URL { return u }
                        if let s = item as? String { return normalizeNetworkURL(s) }
                        if let data = item as? Data,
                           let s = String(data: data, encoding: .utf8) {
                            return normalizeNetworkURL(s) ?? URL(dataRepresentation: data, relativeTo: nil)
                        }
                        return nil
                    }()
                    guard let url else { return }
                    if isRemoteNetworkURL(url) {
                        self.addNetworkMedia(from: url, at: target)
                    } else if isVideoFileURL(url), let loaded = videoDataFromFileURL(url) {
                        Task { @MainActor in
                            self.addVideoItem(with: loaded.data, fileName: loaded.fileName, at: target)
                        }
                    } else if isAudioFileURL(url), let loaded = audioDataFromFileURL(url) {
                        Task { @MainActor in
                            self.addAudioItem(with: loaded.data, fileName: loaded.fileName, at: target)
                        }
                    } else if let data = imageDataFromFileURL(url) {
                        Task { @MainActor in
                            self.addImageItem(with: data, at: target)
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                let audioType = UTType.audio.identifier
                provider.loadDataRepresentation(forTypeIdentifier: audioType) { data, _ in
                    guard let data, isAudioData(data) else { return }
                    Task { @MainActor in
                        self.addAudioItem(with: data, at: target)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {
                let videoType = UTType.video.identifier
                provider.loadDataRepresentation(forTypeIdentifier: videoType) { data, _ in
                    guard let data, isVideoData(data) else { return }
                    Task { @MainActor in
                        self.addVideoItem(with: data, fileName: "video.mp4", at: target)
                    }
                }
            } else {
                // Fall back to the first image type the provider offers.
                let imageType = UTType.image.identifier
                provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
                    guard let data, isImageData(data) else { return }
                    Task { @MainActor in
                        self.addImageItem(with: data, at: target)
                    }
                }
            }
        }
        return true
    }

    /// Legacy name kept for tests/callers: images-only drops route through
    /// the shared media handler.
    private func handleImageDrop(providers: [NSItemProvider], location: CGPoint, vp: Viewport) -> Bool {
        handleMediaDrop(providers: providers, location: location, vp: vp)
    }

    private func setColor(_ hex: String) {
        var changed = false
        for item in selectedItems where !item.isLocked {
            item.colorHex = hex
            changed = true
        }
        if changed { touch() }
    }

    // MARK: Drawing actions

    /// Turns the in-progress screen-space stroke into a persisted drawing item.
    private func commitStroke(vp: Viewport) {
        defer { activeStrokeScreen = [] }
        var screen = activeStrokeScreen
        guard screen.count >= 2 else { return }
        if penStyle.isStraight {
            screen = [screen.first!, screen.last!]
        }
        let span = hypot(screen.last!.x - screen.first!.x,
                         screen.last!.y - screen.first!.y)
        guard span >= 6 || screen.count > 4 else { return }  // ignore accidental taps

        let world = screen.map { vp.worldPoint(for: $0) }
        let top = pageItems.map(\.zIndex).max() ?? 0
        let item = CanvasItem(kind: .drawing,
                              strokeStyle: penStyle,
                              x: 0, y: 0,
                              colorHex: penColorHex,
                              lineWidth: penWidth,
                              zIndex: top + 1)
        item.adoptStroke(worldPoints: world)
        context.insert(item)
        item.board = board
        item.pageIndex = clampedPage
        selectedIDs = [item.id]
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        touch()
    }

    /// Trashes items instead of hard-deleting them, so undo can bring them
    /// back (see `CanvasItem.isTrashed`). Callers must `touch()` afterwards.
    private func softDelete(_ item: CanvasItem) {
        selectedIDs.remove(item.id)
        if editingID == item.id { editingID = nil }
        item.isTrashed = true
    }

    private func deleteSelected() {
        // Locked items are protected from deletion; a mixed selection deletes
        // only its unlocked members.
        let victims = selectedItems.filter { !$0.isLocked }
        guard !victims.isEmpty else { return }
        let victimIDs = Set(victims.map(\.id))
        selectedIDs.subtract(victimIDs)
        if let editing = editingID, victimIDs.contains(editing) {
            editingID = nil
            tableSelectedCells = []
            tableAnchorCell = nil
        }
        for item in victims { item.isTrashed = true }
        touch()
    }

    private func duplicateSelected() {
        let originals = selectedItems.sorted { $0.zIndex < $1.zIndex }
        guard !originals.isEmpty else { return }
        // Copies of a group stay grouped together (under a fresh ID), even
        // for partial-group duplicates — ungrouped originals stay ungrouped.
        let groupMap = remappedGroupIDs(for: originals.map(\.groupID))
        var top = pageItems.map(\.zIndex).max() ?? 0
        var newIDs: Set<UUID> = []
        for original in originals {
            top += 1
            let copy = CanvasItem(kind: original.kind,
                                  shape: original.shape,
                                  strokeStyle: original.strokeStyle,
                                  x: original.x + 20,
                                  y: original.y + 20,
                                  text: original.text,
                                  colorHex: original.colorHex,
                                  lineWidth: original.lineWidth,
                                  points: original.strokePoints,
                                  zIndex: top)
            copy.width = original.width
            copy.height = original.height
            copy.fontSize = original.fontSize
            copy.richTextData = original.richTextData
            copy.imageData = original.imageData
            copy.pdfData = original.pdfData
            copy.pdfPage = original.pdfPage
            copy.audioData = original.audioData
            copy.audioFileName = original.audioFileName
            copy.audioDuration = original.audioDuration
            copy.youtubeURL = original.youtubeURL
            copy.videoData = original.videoData
            copy.videoFileName = original.videoFileName
            copy.videoDuration = original.videoDuration
            copy.pageIndex = original.pageIndex
            copy.tableData = original.tableData
            if let gid = original.groupID { copy.groupID = groupMap[gid] }
            // Duplicates always start unlocked so a locked original never
            // spawns a copy the user can't immediately move.
            copy.isLocked = false
            context.insert(copy)
            copy.board = board
            newIDs.insert(copy.id)
        }
        selectedIDs = newIDs
        editingID = nil
        touch()
    }

    /// Right-click (long-press on iPad) menu for one item. Right-clicking an
    /// unselected item selects just it first (Finder-style); right-clicking
    /// inside the selection keeps the whole selection as the target.
    @ViewBuilder
    private func arrangeMenu(for item: CanvasItem) -> some View {
        arrangeOrderSection(for: item)
        Divider()
        arrangeGroupSection(for: item)
        Divider()
        arrangeLockSection(for: item)
    }

    @ViewBuilder
    private func arrangeOrderSection(for item: CanvasItem) -> some View {
        Button { arrangeTargeting(item, .bringToFront) } label: {
            Label(ArrangeOperation.bringToFront.title,
                  systemImage: ArrangeOperation.bringToFront.symbol)
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        Button { arrangeTargeting(item, .bringForward) } label: {
            Label(ArrangeOperation.bringForward.title,
                  systemImage: ArrangeOperation.bringForward.symbol)
        }
        .keyboardShortcut("f", modifiers: [.command, .option])
        Button { arrangeTargeting(item, .sendBackward) } label: {
            Label(ArrangeOperation.sendBackward.title,
                  systemImage: ArrangeOperation.sendBackward.symbol)
        }
        .keyboardShortcut("b", modifiers: [.command, .option])
        Button { arrangeTargeting(item, .sendToBack) } label: {
            Label(ArrangeOperation.sendToBack.title,
                  systemImage: ArrangeOperation.sendToBack.symbol)
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
    }

    @ViewBuilder
    private func arrangeGroupSection(for item: CanvasItem) -> some View {
        Button { groupTargeting(item) } label: {
            Label("Group", systemImage: "square.on.square.squareshape.controlhandles")
        }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(!canGroupTargeting(item))
        Button { ungroupTargeting(item) } label: {
            Label("Ungroup", systemImage: "square.on.square")
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(!canUngroupTargeting(item))
    }

    @ViewBuilder
    private func arrangeLockSection(for item: CanvasItem) -> some View {
        // Single toggle: locks when any target is unlocked, otherwise unlocks.
        // The target set mirrors Finder-style selection (see toggleLockTargeting).
        let shouldLock = shouldLockTargets(for: item)
        Button { toggleLockTargeting(item) } label: {
            Label(shouldLock ? "Lock" : "Unlock",
                  systemImage: shouldLock ? "lock.fill" : "lock.open.fill")
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }

    /// Group menu availability for Finder-style targets.
    private func canGroupTargeting(_ item: CanvasItem) -> Bool {
        canGroupSelection(count: contextTargets(for: item).count)
    }

    private func canUngroupTargeting(_ item: CanvasItem) -> Bool {
        canUngroupSelection(selectedGroupIDs: contextTargets(for: item).map(\.groupID))
    }

    /// Items the context menu acts on: the whole selection when the
    /// right-clicked item belongs to it, otherwise just that item.
    private func contextTargets(for item: CanvasItem) -> [CanvasItem] {
        if selectedIDs.contains(item.id) {
            return selectedItems
        }
        if let found = pageItems.first(where: { $0.id == item.id }) {
            return [found]
        }
        return [item]
    }

    /// True when at least one target is currently unlocked (so the menu
    /// offers "Lock"); false means every target is locked ("Unlock").
    private func shouldLockTargets(for item: CanvasItem) -> Bool {
        contextTargets(for: item).contains(where: { !$0.isLocked })
    }

    private func toggleLockTargeting(_ item: CanvasItem) {
        if !selectedIDs.contains(item.id) {
            selectedIDs = expandIDsForGroups([item.id])
            editingID = nil
        }
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let shouldLock = targets.contains(where: { !$0.isLocked })
        setLocked(targets, locked: shouldLock)
    }

    private func setLocked(_ targets: [CanvasItem], locked: Bool) {
        var changed = false
        for target in targets where target.isLocked != locked {
            target.isLocked = locked
            changed = true
        }
        // Locking ends any text editing on the targets so a locked box can
        // never stay in writing mode.
        if locked, let editing = editingID, targets.contains(where: { $0.id == editing }) {
            editingID = nil
        }
        if changed { touch() }
    }

    /// Unlocks a single item via its lock badge. Keeps the selection so the
    /// user sees the item become editable immediately. Undoable via `touch()`.
    private func unlockItem(_ item: CanvasItem) {
        guard item.isLocked else { return }
        item.isLocked = false
        touch()
    }

    private func arrangeTargeting(_ item: CanvasItem, _ operation: ArrangeOperation) {
        if !selectedIDs.contains(item.id) {
            selectedIDs = expandIDsForGroups([item.id])
            editingID = nil
        }
        arrangeSelected(operation)
    }

    /// Applies an explicit stacking command to the selection. The only way
    /// the layer order changes (creation aside): selection itself never
    /// restacks. Depths are reassigned contiguously bottom→top so ties can
    /// never form and values stay compact. Undoable via the normal save.
    /// Locked items never restack: a mixed selection rearranges only its
    /// unlocked members around the locked ones.
    private func arrangeSelected(_ operation: ArrangeOperation) {
        let sorted = sortedItems
        guard !sorted.isEmpty, !selectedIDs.isEmpty else { return }
        let movable = selectedIDs.filter { id in
            sorted.first(where: { $0.id == id })?.isLocked == false
        }
        guard !movable.isEmpty else { return }
        let ids = sorted.map(\.id)
        let next = arrangedOrder(sortedIDs: ids, selectedIDs: movable,
                                 operation: operation)
        guard next != ids else { return }
        let byID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        for (depth, id) in next.enumerated() {
            byID[id]?.zIndex = Double(depth)
        }
        touch()
    }

    private func finishEditing(_ id: UUID?) {
        guard let id, let item = pageItems.first(where: { $0.id == id }) else { return }

        // Empty text boxes and pin notes collapse to nothing: trash them so
        // cancelled editors leave no litter behind. Empty YouTube tiles
        // (no URL ever typed) go the same way; invalid URLs stay so the
        // user can double-click back in and fix them.
        let isBlank = item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if (item.kind == .text || item.kind == .note) && isBlank {
            softDelete(item)
        }
        if item.kind == .youtube,
           item.youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            softDelete(item)
        }
        touch()
    }

    private func touch() {
        board.modifiedAt = .now
        try? context.save()
    }

    /// Undo/redo must persist without touching `modifiedAt`: bumping it here
    /// would register a brand-new undo step and wipe the redo stack.
    private func performUndo() {
        context.undoManager?.undo()
        try? context.save()
    }

    private func performRedo() {
        context.undoManager?.redo()
        try? context.save()
    }

    /// Resumes/pauses the selected voice tile on Space. While a text editor
    /// is open the key belongs to it (it handles the press first, so it
    /// never bubbles here); the guard covers focus being elsewhere.
    private func toggleAudioPlaybackKeyPress() -> KeyPress.Result {
        guard let target = spaceToggleAudioTarget(selectedItems: selectedItems,
                                                  isEditing: editingID != nil)
        else { return .ignored }
        NotificationCenter.default.post(name: AudioPlayer.togglePlayback,
                                        object: target.id)
        return .handled
    }

    /// Deletes the selection on Backspace / Forward Delete. While a text
    /// editor is open the key belongs to it (it handles the press first,
    /// so it never bubbles here); the guard covers focus being elsewhere.
    /// Locked-only selections are ignored so Backspace never swallows a
    /// keypress that deleted nothing.
    private func deleteSelectionKeyPress() -> KeyPress.Result {
        guard editingID == nil, !selectedIDs.isEmpty else { return .ignored }
        guard selectedItems.contains(where: { !$0.isLocked }) else { return .ignored }
        deleteSelected()
        return .handled
    }

    /// Selects every visible item on Cmd+A. While a text box is open in
    /// writing mode the key belongs to its editor (select-all-text is
    /// handled natively and never bubbles here); the guard covers focus
    /// being elsewhere.
    private func selectAllKeyPress() -> KeyPress.Result {
        guard editingID == nil else { return .ignored }
        let ids = Set(pageItems.map(\.id))
        guard !ids.isEmpty else { return .ignored }
        selectedIDs = ids
        return .handled
    }

    /// Toggles lock on the current selection via ⇧⌘L. While a text box is
    /// open in writing mode the key belongs to its editor (never bubbles
    /// here); the guard covers focus being elsewhere. Context-menu
    /// `.keyboardShortcut` alone only shows the hint — this global handler
    /// is what actually makes the shortcut work.
    private func toggleLockSelectionKeyPress() -> KeyPress.Result {
        guard editingID == nil, !selectedItems.isEmpty else { return .ignored }
        let shouldLock = selectedItems.contains(where: { !$0.isLocked })
        setLocked(selectedItems, locked: shouldLock)
        return .handled
    }
}

#Preview {
    NavigationStack {
        CanvasView(board: PreviewData.board)
    }
    .modelContainer(PreviewData.container)
}

/// Live placement preview for the shape tool, drawn in screen space while
/// the frame is being dragged. Mirrors the ItemBodyView shape rendering.
struct ShapeDragPreview: View {
    var kind: ShapeKind
    var colorHex: String

    var body: some View {
        let fill = Color(hex: colorHex).opacity(0.75)
        switch kind {
        case .rectangle:        Rectangle().fill(fill)
        case .roundedRectangle: RoundedRectangle(cornerRadius: 12).fill(fill)
        case .ellipse:          Ellipse().fill(fill)
        case .capsule:          Capsule().fill(fill)
        case .triangle:         TriangleShape().fill(fill)
        case .rightTriangle:    RightTriangleShape().fill(fill)
        case .diamond:          DiamondShape().fill(fill)
        case .pentagon:         PentagonShape().fill(fill)
        case .hexagon:          HexagonShape().fill(fill)
        case .circle:           Circle().fill(fill)
        case .star:             StarShape().fill(fill)
        case .cloud:            CloudShape().fill(fill)
        case .line:             linePreview(single: false)
        case .arrow:            linePreview(single: true)
        case .doubleArrow:      linePreview(single: false, double: true)
        }
    }

    @ViewBuilder
    private func linePreview(single: Bool, double: Bool = false) -> some View {
        GeometryReader { geo in
            let fill = Color(hex: colorHex).opacity(0.9)
            let rect = CGRect(origin: .zero, size: geo.size)
            let tail = ShapeArrow.tailBottomLeft(in: rect)
            let tip = ShapeArrow.tipTopRight(in: rect)
            let angle = atan2(tip.y - tail.y, tip.x - tail.x)
            let size = min(rect.width, rect.height)
            ZStack {
                Path { p in
                    p.move(to: tail)
                    p.addLine(to: tip)
                }
                .stroke(fill, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                if single || double {
                    ShapeArrow.head(tip: tip, angle: angle, size: size).fill(fill)
                }
                if double {
                    ShapeArrow.head(tip: tail, angle: angle + .pi, size: size).fill(fill)
                }
            }
        }
    }
}

/// Screen-space endpoint preview for two-tap line/arrow placement.
/// `a` and `b` are in the view's own frame coordinates.
struct LineEndpointsPreview: View {
    var kind: ShapeKind
    var a: CGPoint
    var b: CGPoint
    var colorHex: String

    var body: some View {
        let fill = Color(hex: colorHex).opacity(0.9)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let len = hypot(b.x - a.x, b.y - a.y)
        // Heads scale with the line, clamped so short lines stay legible
        // and very long ones don't grow cartoonish tips.
        let headSize = min(max(len * 0.25, 24), 120)
        let showTipHead = (kind == .arrow || kind == .doubleArrow) && len > 0.5
        let showTailHead = kind == .doubleArrow && len > 0.5
        return ZStack {
            Path { p in
                p.move(to: a)
                p.addLine(to: b)
            }
            .stroke(fill, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            if showTipHead {
                ShapeArrow.head(tip: b, angle: angle, size: headSize).fill(fill)
            }
            if showTailHead {
                ShapeArrow.head(tip: a, angle: angle + .pi, size: headSize).fill(fill)
            }
            Circle().fill(fill).frame(width: 6, height: 6).position(a)
        }
    }
}

extension View {
    /// Focusable for key/paste handling without the macOS blue focus ring.
    @ViewBuilder
    func focusableWithoutRing() -> some View {
#if os(macOS)
        self.focusable().focusEffectDisabled()
#else
        self.focusable()
#endif
    }

    /// Reports mouse hover (local coordinates) for rubber-band previews and
    /// brush rings. macOS only — on iOS there is no hover, so this is a no-op.
    @ViewBuilder
    func hoverTracking(onHover: @escaping (CGPoint) -> Void,
                       onLeave: @escaping () -> Void) -> some View {
#if os(macOS)
        self.onContinuousHover { phase in
            switch phase {
            case .active(let location): onHover(location)
            case .ended: onLeave()
            }
        }
#else
        self
#endif
    }
}
