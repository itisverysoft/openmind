import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Grid rendering + per-cell editing for `.table` items.
///
/// Interaction model (mirrors text boxes + spreadsheets):
/// - Single tap (via parent) selects the table; taps on cells then select
///   cells (highlighted) without entering text edit.
/// - Double-tap (via parent `onBeginEditing`) enters writing mode: the
///   anchor cell shows a TextField with keyboard focus.
/// - Shift-click extends a rectangular multi-selection from the anchor cell.
///   Format + fill actions apply to every selected cell at once.
/// - Right-click (long-press) on a cell offers row/column insert + delete.
/// - Column widths drag on dividers; outer-frame resize (parent handle)
///   scales all columns proportionally and stretches row heights.
///
/// Cell selection lives in `selectedCells`/`anchorCell` bindings owned by
/// CanvasView so the format toolbar can act on the same selection the grid
/// highlights. Draft text + keyboard focus stay local: only the anchor cell
/// ever hosts the editor.
struct TableItemView: View {
    @Bindable var item: CanvasItem
    var scale: CGFloat = 1
    var isEditing: Bool = false
    var isSelected: Bool = false
    /// Shift held (macOS key monitor, plumbed from CanvasView): taps extend
    /// the selection instead of replacing it.
    var shiftHeld: Bool = false
    @Binding var selectedCells: Set<TableCellRef>
    @Binding var anchorCell: TableCellRef?
    var onCommit: () -> Void = {}

    @State private var draft: String = ""
    @State private var draftCell: TableCellRef?
    @FocusState private var focusedCell: TableCellRef?

    // Column-resize preview (fractions, not points). Committed on drag end.
    @State private var resizeDivider: Int?
    @State private var resizeBase: [Double] = []
    @State private var resizeDelta: Double = 0

    private var table: TableContent { item.getTable() }
    private var isLocked: Bool { item.isLocked }
    /// Writing mode: anchor cell hosts the TextField.
    private var canEdit: Bool { isEditing && !isLocked }
    /// Cell selection, range highlight and cell menu are available whenever
    /// the table itself is active (selected or editing), never when locked.
    private var tableActive: Bool { (isSelected || isEditing) && !isLocked }

    private var corner: CGFloat { 8 * scale }
    private var lineWidth: CGFloat { max(0.75, 1 * scale) }

    var body: some View {
        GeometryReader { geo in
            let t = table
            let fractions = displayFractions(for: t)
            let totalW = geo.size.width
            let totalH = geo.size.height
            let rowH: CGFloat = t.rows > 0 ? totalH / CGFloat(t.rows) : totalH
            ZStack(alignment: .topLeading) {
                gridContent(table: t, fractions: fractions,
                            totalW: totalW, rowH: rowH)
                if showDividers {
                    dividersOverlay(fractions: fractions, totalW: totalW,
                                    totalH: totalH)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.black.opacity(0.2), lineWidth: lineWidth)
        )
        .shadow(color: .black.opacity(0.18), radius: 3 * scale, y: 2 * scale)
        // Inert when the table itself isn't active so taps fall through to
        // the parent (table selection, marquee, pan).
        .allowsHitTesting(tableActive)
        .onChange(of: isEditing) { _, editing in
            if editing {
                sanitizeSelection()
                if selectedCells.isEmpty {
                    let first = TableCellRef(row: 0, col: 0)
                    if table.isValid(first) {
                        selectedCells = [first]
                        anchorCell = first
                    }
                } else if anchorCell == nil {
                    anchorCell = selectedCells.first
                }
                focusAnchor()
            } else {
                commitDraft()
                selectedCells = []
                anchorCell = nil
                focusedCell = nil
                resizeDivider = nil
            }
        }
        .onChange(of: item.tableData) { _, _ in
            // External change (undo / toolbar op): drop a stale draft that
            // no longer matches the model so the grid never shows ghost
            // text, and prune refs that no longer fit the grid.
            if let dc = draftCell {
                let current = item.getTable()[row: dc.row, col: dc.col]
                if current != draft {
                    draft = current
                }
            }
            sanitizeSelection()
            if canEdit && selectedCells.isEmpty {
                let first = TableCellRef(row: 0, col: 0)
                if table.isValid(first) {
                    selectedCells = [first]
                    anchorCell = first
                    focusAnchor()
                }
            }
        }
    }

    /// Keeps the lifted selection valid after structural edits or undo.
    private func sanitizeSelection() {
        let t = item.getTable()
        selectedCells = t.sanitizedCells(selectedCells)
        if let anchor = anchorCell, !t.isValid(anchor) {
            anchorCell = selectedCells.first
        }
        if draftCell.map({ !t.isValid($0) }) ?? false {
            draftCell = nil
        }
    }

    private var showDividers: Bool {
        (isSelected || isEditing) && !isLocked && table.cols > 1
    }

    // MARK: Grid

    private func displayFractions(for t: TableContent) -> [Double] {
        guard let div = resizeDivider, !resizeBase.isEmpty,
              div >= 0, div + 1 < resizeBase.count else {
            return t.colFractions
        }
        // Mirror TableContent.resizeColumns: clamp the delta so neither
        // side drops below the minimum, preserving the pair total.
        var f = resizeBase
        let minFrac = 0.08
        let clamped = min(max(resizeDelta, minFrac - resizeBase[div]),
                          resizeBase[div + 1] - minFrac)
        f[div] += clamped
        f[div + 1] -= clamped
        return f
    }

    private func gridContent(table t: TableContent, fractions: [Double],
                             totalW: CGFloat, rowH: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<t.rows, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<t.cols, id: \.self) { c in
                        let w = (c < fractions.count ? CGFloat(fractions[c]) : 1 / CGFloat(max(t.cols, 1))) * totalW
                        cellView(row: r, col: c, table: t, width: w, height: rowH)
                    }
                }
                if r < t.rows - 1 {
                    Color.black.opacity(0.15).frame(height: lineWidth)
                }
            }
        }
    }

    private func cellView(row r: Int, col c: Int, table t: TableContent,
                          width: CGFloat, height: CGFloat) -> some View {
        let id = TableCellRef(row: r, col: c)
        let text = t[row: r, col: c]
        let style = t.styleAt(row: r, col: c)
        let isHeader = t.isHeaderCell(row: r)
        let isSel = tableActive && selectedCells.contains(id)
        let isAnchor = canEdit && anchorCell == id
        let size = CGFloat(style.fontSize ?? item.fontSize) * scale
        let ink: Color = {
            if let hex = style.colorHex { return Color(hex: hex) }
            return .black
        }()
        let fill: Color = {
            if let hex = style.backgroundHex { return Color(hex: hex) }
            return isHeader ? Color(hex: item.colorHex) : .white
        }()
        let textAlign: TextAlignment = {
            switch style.alignmentRaw {
            case "center": return .center
            case "right": return .trailing
            default: return .leading
            }
        }()
        let frameAlign: Alignment = {
            switch style.alignmentRaw {
            case "center": return .center
            case "right": return .trailing
            default: return .topLeading
            }
        }()
        return ZStack {
            fill
            if isSel {
                Color.accentColor.opacity(isAnchor ? 0.16 : 0.10)
            }
            if isAnchor {
                TextField("", text: $draft, prompt: Text("").foregroundColor(.clear))
                    .textFieldStyle(.plain)
                    .font(.system(size: size, weight: style.bold ? .bold : .regular))
                    .italic(style.italic)
                    .foregroundStyle(ink)
                    .multilineTextAlignment(textAlign)
                    .lineLimit(4)
                    .focused($focusedCell, equals: id)
                    .onSubmit { commitAndAdvance(from: id) }
                    .padding(6 * scale)
            } else {
                Text(text)
                    .font(.system(size: size, weight: style.bold ? .bold : .regular))
                    .italic(style.italic)
                    .underline(style.underline)
                    .strikethrough(style.strikethrough)
                    .foregroundStyle(text.isEmpty ? .clear : ink)
                    .multilineTextAlignment(textAlign)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlign)
                    .padding(6 * scale)
                    .contentShape(Rectangle())
            }
        }
        .frame(width: width, height: height)
        .overlay {
            if isSel {
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: max(1.5, (isAnchor ? 2 : 1.25) * scale))
            }
        }
        .overlay(alignment: .trailing) {
            if c < t.cols - 1 {
                Color.black.opacity(0.15).frame(width: lineWidth)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Bubbles to the parent (table selection) too, which is
            // harmless: the table is already selected, and CanvasView skips
            // the Shift-toggle for selected tables so range-select survives.
            guard tableActive else { return }
            selectCell(id, additive: shiftHeld)
        }
        .contextMenu {
            if tableActive {
                Button("Insert row above") { tableOp(at: id, op: .insertRowAbove) }
                Button("Insert row below") { tableOp(at: id, op: .insertRowBelow) }
                Button("Insert column left") { tableOp(at: id, op: .insertColLeft) }
                Button("Insert column right") { tableOp(at: id, op: .insertColRight) }
                Divider()
                Button("Delete row", role: .destructive) { tableOp(at: id, op: .deleteRow) }
                    .disabled(table.rows <= TableContent.minRows)
                Button("Delete column", role: .destructive) { tableOp(at: id, op: .deleteCol) }
                    .disabled(table.cols <= TableContent.minCols)
                Divider()
                if selectedCells.count > 1 && selectedCells.contains(id) {
                    Button("Clear \(selectedCells.count) cells", role: .destructive) {
                        tableOp(at: id, op: .clearSelection)
                    }
                } else {
                    Button("Clear cell", role: .destructive) { tableOp(at: id, op: .clearCell) }
                }
            }
        }
    }

    // MARK: Dividers (column resize)

    private func dividersOverlay(fractions: [Double], totalW: CGFloat,
                                 totalH: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<(table.cols - 1), id: \.self) { div in
                let x = fractions.prefix(div + 1).reduce(0, +) * Double(totalW)
                Rectangle()
                    .fill(Color.accentColor.opacity(resizeDivider == div ? 0.9 : 0.0))
                    .frame(width: max(2, 2 * scale), height: totalH)
                    .offset(x: CGFloat(x) - max(1, scale))
                    .overlay {
                        // Wider invisible hit area for easy grabbing.
                        Color.clear
                            .frame(width: max(14, 14 * scale), height: totalH)
                            .contentShape(Rectangle())
                            .gesture(columnResizeGesture(divider: div, totalW: totalW))
#if os(macOS)
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.resizeLeftRight.set()
                                } else if resizeDivider == nil {
                                    NSCursor.arrow.set()
                                }
                            }
#endif
                    }
            }
        }
        .allowsHitTesting(true)
    }

    private func columnResizeGesture(divider div: Int, totalW: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                guard !isLocked, totalW > 0 else { return }
                if resizeDivider == nil {
                    resizeDivider = div
                    resizeBase = table.colFractions
                }
                resizeDelta = Double(value.translation.width / totalW)
            }
            .onEnded { value in
                guard totalW > 0 else { resizeDivider = nil; return }
                let delta = Double(value.translation.width / totalW)
                var t = item.getTable()
                t.resizeColumns(divider: div, by: delta)
                item.setTable(t)
                resizeDivider = nil
                resizeBase = []
                resizeDelta = 0
                onCommit()
            }
    }

    // MARK: Cell selection + editing

    /// Tap selection. Plain tap selects one cell (anchor); Shift-tap extends
    /// a rectangular range from the anchor. The editor + keyboard focus stay
    /// on the anchor; in writing mode the anchor is (re)focused.
    private func selectCell(_ id: TableCellRef, additive: Bool) {
        guard table.isValid(id) else { return }
        if additive, let anchor = anchorCell, table.isValid(anchor) {
            // Range extend: focus stays on the anchor, so any in-progress
            // draft for it keeps living in its TextField.
            selectedCells = TableContent.rangeCells(from: anchor, to: id)
            if draftCell == nil || draftCell != anchor {
                draft = table[row: anchor.row, col: anchor.col]
                draftCell = anchor
            }
        } else {
            commitDraft()
            selectedCells = [id]
            anchorCell = id
            draft = table[row: id.row, col: id.col]
            draftCell = id
        }
        focusAnchor()
    }

    /// Loads the anchor's text into the draft and focuses its field in
    /// writing mode; parks focus otherwise.
    private func focusAnchor() {
        guard canEdit, let anchor = anchorCell, table.isValid(anchor) else {
            if !canEdit {
                focusedCell = nil
                draftCell = nil
            }
            return
        }
        if draftCell != anchor {
            draft = table[row: anchor.row, col: anchor.col]
            draftCell = anchor
        }
        DispatchQueue.main.async {
            focusedCell = anchor
        }
    }

    private func commitDraft() {
        guard let dc = draftCell else { return }
        var t = item.getTable()
        guard t.isValid(dc) else { draftCell = nil; return }
        if t[row: dc.row, col: dc.col] != draft {
            t[row: dc.row, col: dc.col] = draft
            item.setTable(t)
            onCommit()
        }
        draftCell = nil
    }

    private func commitAndAdvance(from id: TableCellRef) {
        commitDraft()
        let t = item.getTable()
        var next: TableCellRef?
        if id.col + 1 < t.cols {
            next = TableCellRef(row: id.row, col: id.col + 1)
        } else if id.row + 1 < t.rows {
            next = TableCellRef(row: id.row + 1, col: 0)
        }
        if let next, t.isValid(next) {
            selectedCells = [next]
            anchorCell = next
            draft = t[row: next.row, col: next.col]
            draftCell = next
            DispatchQueue.main.async {
                focusedCell = next
            }
        } else {
            focusedCell = nil
        }
    }

    // MARK: Context-menu ops

    private enum CellOp {
        case insertRowAbove, insertRowBelow, insertColLeft, insertColRight
        case deleteRow, deleteCol, clearCell, clearSelection
    }

    private func tableOp(at id: TableCellRef, op: CellOp) {
        commitDraft()
        var t = item.getTable()
        guard t.isValid(id) else { return }
        var newSel: TableCellRef? = id
        switch op {
        case .insertRowAbove:
            if t.insertRow(at: id.row) { newSel = id }
        case .insertRowBelow:
            if t.insertRow(at: id.row + 1) { newSel = TableCellRef(row: id.row + 1, col: id.col) }
        case .insertColLeft:
            if t.insertColumn(at: id.col) { newSel = id }
        case .insertColRight:
            if t.insertColumn(at: id.col + 1) { newSel = TableCellRef(row: id.row, col: id.col + 1) }
        case .deleteRow:
            if t.deleteRow(at: id.row) {
                newSel = TableCellRef(row: min(id.row, t.rows - 1), col: min(id.col, t.cols - 1))
            }
        case .deleteCol:
            if t.deleteColumn(at: id.col) {
                newSel = TableCellRef(row: min(id.row, t.rows - 1), col: min(id.col, t.cols - 1))
            }
        case .clearCell:
            t[row: id.row, col: id.col] = ""
        case .clearSelection:
            for ref in selectedCells where t.isValid(ref) {
                t[row: ref.row, col: ref.col] = ""
            }
            newSel = id
        }
        item.setTable(t)
        // Grow the frame when rows/cols are added so new cells stay usable.
        growFrameForContent(t)
        onCommit()
        let valid = t.sanitizedCells(selectedCells)
        if op == .clearCell || op == .clearSelection {
            selectedCells = valid.isEmpty ? (newSel.map { [$0] } ?? []) : valid
            if anchorCell.map({ !t.isValid($0) }) ?? false { anchorCell = newSel }
        } else if let newSel, t.isValid(newSel) {
            selectedCells = [newSel]
            anchorCell = newSel
        } else {
            selectedCells = valid
            if anchorCell.map({ !t.isValid($0) }) ?? false { anchorCell = valid.first }
        }
        focusAnchor()
    }

    /// Keeps a minimum usable cell size when the grid grows: expands the
    /// item frame (world points) instead of squeezing cells to nothing.
    private func growFrameForContent(_ t: TableContent) {
        let minCellW: Double = 90
        let minRowH: Double = 32
        let needW = Double(t.cols) * minCellW
        let needH = Double(t.rows) * minRowH + (t.hasHeader ? 8 : 0)
        if item.width < needW { item.width = needW }
        if item.height < needH { item.height = needH }
    }
}
