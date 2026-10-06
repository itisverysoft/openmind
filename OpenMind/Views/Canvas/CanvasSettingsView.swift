import SwiftUI
import SwiftData

/// Canvas settings panel (paper size, colour, pattern), matching the design:
/// size chips + orientation, colour swatches + custom colour, pattern tiles,
/// and the "use for new boards" default. Edits apply to this board only —
/// boards you already have are left exactly as they are.
struct CanvasSettingsView: View {
    @Bindable var board: Board
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var customColor: Color = .white
    @State private var useForNewBoards: Bool = CanvasDefaults.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                sizeSection
                colourSection
                patternSection
                newBoardsSection
            }
            .padding(20)
        }
        .onAppear {
            customColor = Color(hex: board.canvasColorHex)
            useForNewBoards = CanvasDefaults.isEnabled
        }
        .onChange(of: board.canvasSizeRaw) { syncDefaultsIfNeeded() }
        .onChange(of: board.canvasOrientationRaw) { syncDefaultsIfNeeded() }
        .onChange(of: board.canvasColorHex) {
            customColor = Color(hex: board.canvasColorHex)
            syncDefaultsIfNeeded()
        }
        .onChange(of: board.canvasPatternRaw) { syncDefaultsIfNeeded() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Canvas")
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
            Button { dismiss() } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .padding(6)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    // MARK: Size

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CANVAS SIZE")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                ForEach(CanvasSizePreset.chips) { preset in
                    sizeChip(preset)
                }
            }
            if board.canvasSize == .custom {
                Text("Custom — \(Int(board.sheetWorldRect?.width ?? 0)) × \(Int(board.sheetWorldRect?.height ?? 0)) pt (this document's page size)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                orientationChip(.portrait)
                orientationChip(.landscape)
            }
            .opacity(board.canvasSize == .infinite ? 0.4 : 1)
            .disabled(board.canvasSize == .infinite)
            Text("Anything you draw outside the sheet stays where it is — it just sits off the page, and exports use the sheet. Every fixed size is paged: flip, add, and delete pages from the pill above the toolbar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sizeChip(_ preset: CanvasSizePreset) -> some View {
        let selected = board.canvasSize == preset
        return Button {
            setSize(preset)
        } label: {
            Text(preset.title)
                .font(.callout)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minWidth: 76)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Applies a size choice. Falling back to `.infinite` has no page system,
    /// so every page merges onto one canvas first — nothing is ever lost.
    private func setSize(_ preset: CanvasSizePreset) {
        if preset == .infinite, board.canvasSize != .infinite {
            board.mergePagesToSingle()
        }
        board.canvasSize = preset
        save()
    }

    private func orientationChip(_ orientation: CanvasOrientation) -> some View {
        let selected = board.canvasOrientation == orientation
        return Button {
            board.canvasOrientation = orientation
            save()
        } label: {
            Text(orientation.title)
                .font(.callout)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: Colour

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("COLOUR")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                ForEach(CanvasPalette.sheetSwatches, id: \.self) { hex in
                    let selected = board.canvasColorHex.uppercased() == hex.uppercased()
                    Button {
                        board.canvasColorHex = hex
                        save()
                    } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: hex))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.2), lineWidth: 1))
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor, lineWidth: 2.5)
                                        .padding(-3)
                                }
                            }
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .help("#\(hex)")
                }
            }
            Text("CUSTOM COLOUR")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            ColorPicker("Custom colour", selection: $customColor)
                .labelsHidden()
                .onChange(of: customColor) { _, newValue in
                    if let hex = canvasHexString(from: newValue) {
                        board.canvasColorHex = hex
                        save()
                    }
                }
        }
    }

    // MARK: Pattern

    private var patternSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PATTERN")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(CanvasPattern.allCases) { pattern in
                    patternTile(pattern)
                }
            }
        }
    }

    private func patternTile(_ pattern: CanvasPattern) -> some View {
        let selected = board.canvasPattern == pattern
        return Button {
            board.canvasPattern = pattern
            save()
        } label: {
            VStack(spacing: 6) {
                PatternThumb(pattern: pattern)
                    .frame(height: 52)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1))
                Text(pattern.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: New boards

    private var newBoardsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEW BOARDS")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Toggle("Use this canvas for new boards", isOn: $useForNewBoards)
                .tint(.accentColor)
                .onChange(of: useForNewBoards) { _, enabled in
                    CanvasDefaults.isEnabled = enabled
                    if enabled { pushCurrentToDefaults() }
                }
            Text("The size, colour and pattern you choose here are used for every NEW board. Boards you already have are left exactly as they are.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Persistence

    private func save() {
        board.modifiedAt = .now
        try? context.save()
    }

    /// While the toggle is on, every choice becomes the default live.
    private func syncDefaultsIfNeeded() {
        guard useForNewBoards else { return }
        pushCurrentToDefaults()
    }

    private func pushCurrentToDefaults() {
        CanvasDefaults.size = board.canvasSize
        CanvasDefaults.orientation = board.canvasOrientation
        CanvasDefaults.colorHex = board.canvasColorHex
        CanvasDefaults.pattern = board.canvasPattern
        CanvasDefaults.customSize = CGSize(width: board.customWidth,
                                           height: board.customHeight)
    }
}

/// Miniature pattern preview for the pattern tiles.
private struct PatternThumb: View {
    var pattern: CanvasPattern

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let ink = Color.gray.opacity(0.5)
            switch pattern {
            case .plain:
                EmptyView()
            case .dots:
                Path { p in
                    for x in stride(from: 8, through: w - 4, by: 12) {
                        for y in stride(from: 8, through: h - 4, by: 12) {
                            p.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                        }
                    }
                }
                .fill(ink)
            case .grid:
                Path { p in
                    for x in stride(from: 8, through: w, by: 12) {
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    }
                    for y in stride(from: 8, through: h, by: 12) {
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    }
                }
                .stroke(ink, lineWidth: 1)
            case .lines:
                Path { p in
                    for y in stride(from: 10, through: h, by: 10) {
                        p.move(to: CGPoint(x: 6, y: y)); p.addLine(to: CGPoint(x: w - 6, y: y))
                    }
                }
                .stroke(ink, lineWidth: 1)
            case .columns:
                Path { p in
                    for x in stride(from: 14, through: w, by: 20) {
                        p.move(to: CGPoint(x: x, y: 4)); p.addLine(to: CGPoint(x: x, y: h - 4))
                    }
                }
                .stroke(ink, lineWidth: 1)
            case .graph:
                ZStack {
                    Path { p in
                        for x in stride(from: 4, through: w, by: 8) {
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                        }
                        for y in stride(from: 4, through: h, by: 8) {
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                        }
                    }
                    .stroke(ink.opacity(0.6), lineWidth: 0.5)
                    Path { p in
                        p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                        p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                    }
                    .stroke(ink, lineWidth: 1)
                }
            }
        }
        .clipped()
    }
}
