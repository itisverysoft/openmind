import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Row/column operations for the selected table. The toolbar acts on the
/// table as a whole (append/delete at the end, header toggle); precise
/// insert-at-row/col lives in each cell's context menu (see TableItemView).
enum TableAction {
    case addRow, deleteRow, addColumn, deleteColumn, toggleHeader
}

/// Floating bar anchored to the selected table (mirrors TextFormatToolbar).
/// Per-cell insert/delete stays in the cell context menu; this bar covers
/// the whole-table ops plus a live `rows × cols` readout.
struct TableFormatToolbar: View {
    var table: TableContent
    var onAction: (TableAction) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Button { onAction(.addRow) } label: {
                Label("Add row", systemImage: "plus.rectangle.on.rectangle")
            }
            .disabled(table.rows >= TableContent.maxRows)
            .help("Add row (\(table.rows)/\(TableContent.maxRows))")

            Button { onAction(.deleteRow) } label: {
                Label("Delete row", systemImage: "minus.rectangle")
            }
            .disabled(table.rows <= TableContent.minRows)
            .help("Delete last row")

            Divider().frame(height: 22)

            Button { onAction(.addColumn) } label: {
                Label("Add column", systemImage: "rectangle.split.2x1")
            }
            .disabled(table.cols >= TableContent.maxCols)
            .help("Add column (\(table.cols)/\(TableContent.maxCols))")

            Button { onAction(.deleteColumn) } label: {
                Label("Delete column", systemImage: "rectangle.split.1x2")
            }
            .disabled(table.cols <= TableContent.minCols)
            .help("Delete last column")

            Divider().frame(height: 22)

            Button { onAction(.toggleHeader) } label: {
                Label("Header row",
                      systemImage: table.hasHeader
                        ? "tablecells.fill" : "tablecells")
                    .foregroundStyle(table.hasHeader ? Color.accentColor : Color.primary)
                    .fontWeight(table.hasHeader ? .semibold : .regular)
            }
            .help(table.hasHeader ? "Hide header row" : "Show header row")

            Text("\(table.rows)×\(table.cols)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Rows × columns. Double-tap the table to edit cells; drag dividers to resize columns.")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .contentShape(Capsule())
        .onTapGesture {} // swallow taps so the canvas doesn't deselect below
    }
}

/// Cell fill (background) picker for the selected table cells. `values` has
/// one entry per selected cell (nil = default fill); a swatch highlights
/// only when every selected cell shares it, and the clear button highlights
/// when all are default. Mixed selections highlight nothing.
struct TableCellFillToolbar: View {
    var values: [String?]
    var onPick: (String?) -> Void = { _ in }

    private var unanimous: String?? {
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? .some(first) : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Label("Cell fill", systemImage: "paintpalette")
                .foregroundStyle(.secondary)
            ForEach(Palette.swatches, id: \.self) { hex in
                Button { onPick(hex) } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                        .overlay {
                            if unanimous == .some(.some(hex)) {
                                Circle().stroke(Color.accentColor, lineWidth: 3).padding(-3)
                            }
                        }
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Fill cell")
            }
            Button { onPick(nil) } label: {
                Label("Default fill", systemImage: "xmark.circle")
                    .foregroundStyle(isDefault ? Color.accentColor : Color.primary)
                    .fontWeight(isDefault ? .semibold : .regular)
            }
            .help("Reset to default fill")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .contentShape(Capsule())
        .onTapGesture {} // swallow taps so the canvas doesn't deselect below
    }

    private var isDefault: Bool {
        !values.isEmpty && values.allSatisfy { $0 == nil }
    }
}

// MARK: - Alignment mapping (style storage <-> toolbar)

/// Toolbar alignment for a stored raw string. Unknown values read as left.
func tableCellAlignment(from raw: String) -> NSTextAlignment {
    switch raw {
    case "center": return .center
    case "right": return .right
    default: return .left
    }
}

func tableCellAlignmentRaw(_ alignment: NSTextAlignment) -> String {
    switch alignment {
    case .center: return "center"
    case .right: return "right"
    default: return "left"
    }
}
