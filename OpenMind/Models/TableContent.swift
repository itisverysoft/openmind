import Foundation

/// Reference to one table cell. Hashable so views can hold multi-selections
/// (single tap selects one, Shift-click extends a rectangular range).
struct TableCellRef: Hashable, Codable {
    var row: Int
    var col: Int
}

/// Per-cell formatting for `.table` items: the same attributes the text-box
/// toolbar offers (bold/italic/underline/strike, size, ink color, alignment)
/// plus a cell fill color. Stored parallel to `cells` in row-major order.
struct TableCellStyle: Codable, Equatable {
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    /// Point size in world points. Nil means the item's `fontSize`.
    var fontSize: Double? = nil
    /// Ink hex. Nil means the default (black body / adaptive header text).
    var colorHex: String? = nil
    /// Horizontal alignment: "left", "center" or "right".
    var alignmentRaw: String = "left"
    /// Fill hex. Nil means the default (header color / white).
    var backgroundHex: String? = nil
}

/// Codable grid backing a `.table` canvas item. Stored as JSON in
/// `CanvasItem.tableData` so it stays undoable, CloudKit-friendly, and
/// separate from the plain-text `text` field used by sticky/text/shape.
///
/// Layout: `rows x cols` cells in row-major order. Column widths are stored
/// as fractions of the table width (summing to 1); row heights are uniform
/// (`tableHeight / rows`) so outer-frame resize just scales rows.
struct TableContent: Codable, Equatable {
    static let minRows = 1
    static let maxRows = 20
    static let minCols = 1
    static let maxCols = 10

    var rows: Int
    var cols: Int
    var cells: [String]
    var hasHeader: Bool
    var colFractions: [Double]
    /// Per-cell formatting, row-major like `cells`. Always kept the same
    /// length as `cells` by every mutation below.
    var styles: [TableCellStyle]

    init(rows: Int = 3, cols: Int = 3, hasHeader: Bool = true,
         cells: [String]? = nil, colFractions: [Double]? = nil,
         styles: [TableCellStyle]? = nil) {
        let r = min(max(rows, Self.minRows), Self.maxRows)
        let c = min(max(cols, Self.minCols), Self.maxCols)
        self.rows = r
        self.cols = c
        self.hasHeader = hasHeader
        if let cells, cells.count == r * c {
            self.cells = cells
        } else {
            self.cells = Array(repeating: "", count: r * c)
        }
        if let styles, styles.count == r * c {
            self.styles = styles
        } else {
            self.styles = Array(repeating: TableCellStyle(), count: r * c)
        }
        if let colFractions, colFractions.count == c, colFractions.allSatisfy({ $0.isFinite && $0 > 0 }) {
            let sum = colFractions.reduce(0, +)
            self.colFractions = sum > 0 ? colFractions.map { $0 / sum } : Array(repeating: 1 / Double(c), count: c)
        } else {
            self.colFractions = Array(repeating: 1 / Double(c), count: c)
        }
        normalizeFractions()
    }

    // MARK: Codable (tolerant: `styles` is missing in pre-format tables)

    private enum CodingKeys: String, CodingKey {
        case rows, cols, cells, hasHeader, colFractions, styles
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let r = min(max(try box.decodeIfPresent(Int.self, forKey: .rows) ?? 3,
                        Self.minRows), Self.maxRows)
        let c = min(max(try box.decodeIfPresent(Int.self, forKey: .cols) ?? 3,
                        Self.minCols), Self.maxCols)
        rows = r
        cols = c
        hasHeader = try box.decodeIfPresent(Bool.self, forKey: .hasHeader) ?? true
        let need = r * c
        let decodedCells = try box.decodeIfPresent([String].self, forKey: .cells) ?? []
        cells = Array((decodedCells + Array(repeating: "", count: need)).prefix(need))
        let decodedStyles = try box.decodeIfPresent([TableCellStyle].self, forKey: .styles) ?? []
        styles = Array((decodedStyles + Array(repeating: TableCellStyle(), count: need)).prefix(need))
        let decodedFractions = try box.decodeIfPresent([Double].self, forKey: .colFractions) ?? []
        if decodedFractions.count == c, decodedFractions.allSatisfy({ $0.isFinite && $0 > 0 }) {
            colFractions = decodedFractions
        } else {
            colFractions = Array(repeating: 1 / Double(max(c, 1)), count: c)
        }
        normalizeFractions()
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(rows, forKey: .rows)
        try box.encode(cols, forKey: .cols)
        try box.encode(cells, forKey: .cells)
        try box.encode(hasHeader, forKey: .hasHeader)
        try box.encode(colFractions, forKey: .colFractions)
        try box.encode(styles, forKey: .styles)
    }

    /// Default 3x3 table with bold header labels, empty body.
    static func makeDefault() -> TableContent {
        var content = TableContent(rows: 3, cols: 3, hasHeader: true)
        for c in 0..<3 {
            content[row: 0, col: c] = "Header \(c + 1)"
        }
        content.updateStyles(at: Set((0..<3).map { TableCellRef(row: 0, col: $0) })) {
            $0.bold = true
        }
        return content
    }

    // MARK: Access

    func isValid(row: Int, col: Int) -> Bool {
        row >= 0 && row < rows && col >= 0 && col < cols
    }

    func isValid(_ ref: TableCellRef) -> Bool {
        isValid(row: ref.row, col: ref.col)
    }

    subscript(row row: Int, col col: Int) -> String {
        get {
            guard isValid(row: row, col: col) else { return "" }
            return cells[row * cols + col]
        }
        set {
            guard isValid(row: row, col: col) else { return }
            cells[row * cols + col] = newValue
        }
    }

    /// Style for a cell, or the default when out of range (never traps,
    /// so rendering stays safe during structural transitions).
    func styleAt(row: Int, col: Int) -> TableCellStyle {
        guard isValid(row: row, col: col),
              styles.count == rows * cols else { return TableCellStyle() }
        return styles[row * cols + col]
    }

    func styleAt(_ ref: TableCellRef) -> TableCellStyle {
        styleAt(row: ref.row, col: ref.col)
    }

    mutating func setStyle(_ style: TableCellStyle, at ref: TableCellRef) {
        guard isValid(ref), styles.count == rows * cols else { return }
        styles[ref.row * cols + ref.col] = style
    }

    /// Applies `update` to every valid cell in `refs`. Used by the format
    /// toolbar so one action restyles the whole multi-selection at once
    /// (a single undo step via the caller's single save).
    mutating func updateStyles(at refs: Set<TableCellRef>,
                               _ update: (inout TableCellStyle) -> Void) {
        guard styles.count == rows * cols else { return }
        for ref in refs where isValid(ref) {
            update(&styles[ref.row * cols + ref.col])
        }
    }

    /// True for header-styled cells (first row when `hasHeader`).
    func isHeaderCell(row: Int) -> Bool {
        hasHeader && row == 0
    }

    /// Rectangular range between two cells, inclusive — Shift-click
    /// selection. Order-independent.
    static func rangeCells(from a: TableCellRef, to b: TableCellRef) -> Set<TableCellRef> {
        var out = Set<TableCellRef>()
        for r in min(a.row, b.row)...max(a.row, b.row) {
            for c in min(a.col, b.col)...max(a.col, b.col) {
                out.insert(TableCellRef(row: r, col: c))
            }
        }
        return out
    }

    /// Drops refs that no longer fit (after row/column deletes or undo).
    func sanitizedCells(_ refs: Set<TableCellRef>) -> Set<TableCellRef> {
        refs.filter { isValid($0) }
    }

    // MARK: Fractions

    mutating func normalizeFractions() {
        guard colFractions.count == cols else {
            colFractions = Array(repeating: 1 / Double(max(cols, 1)), count: cols)
            return
        }
        var fixed = colFractions.map { $0.isFinite && $0 > 0.02 ? $0 : 0.05 }
        let sum = fixed.reduce(0, +)
        guard sum > 0 else {
            colFractions = Array(repeating: 1 / Double(max(cols, 1)), count: cols)
            return
        }
        fixed = fixed.map { $0 / sum }
        colFractions = fixed
    }

    mutating func setFraction(at col: Int, to value: Double) {
        guard col >= 0 && col < cols else { return }
        colFractions[col] = max(0.05, value)
        normalizeFractions()
    }

    /// Drag a divider between `col` and `col+1` by a fraction delta.
    /// The delta is clamped so neither side drops below the minimum; the
    /// pair total is preserved, so no renormalization (which would shrink
    /// untouched columns) is needed.
    mutating func resizeColumns(divider col: Int, by delta: Double) {
        guard col >= 0 && col + 1 < cols,
              delta.isFinite, delta != 0 else { return }
        let minFrac = 0.08
        let clamped = min(max(delta, minFrac - colFractions[col]),
                          colFractions[col + 1] - minFrac)
        guard clamped != 0 else { return }
        colFractions[col] += clamped
        colFractions[col + 1] -= clamped
    }

    // MARK: Row ops

    @discardableResult
    mutating func insertRow(at index: Int) -> Bool {
        guard rows < Self.maxRows else { return false }
        let at = min(max(index, 0), rows)
        cells.insert(contentsOf: Array(repeating: "", count: cols), at: at * cols)
        styles.insert(contentsOf: Array(repeating: TableCellStyle(), count: cols), at: at * cols)
        rows += 1
        return true
    }

    @discardableResult
    mutating func deleteRow(at index: Int) -> Bool {
        guard rows > Self.minRows, index >= 0, index < rows,
              styles.count == rows * cols else { return false }
        cells.removeSubrange(index * cols..<(index + 1) * cols)
        styles.removeSubrange(index * cols..<(index + 1) * cols)
        rows -= 1
        return true
    }

    @discardableResult
    mutating func appendRow() -> Bool { insertRow(at: rows) }

    // MARK: Column ops

    @discardableResult
    mutating func insertColumn(at index: Int) -> Bool {
        guard cols < Self.maxCols else { return false }
        let at = min(max(index, 0), cols)
        var next: [String] = []
        var nextStyles: [TableCellStyle] = []
        next.reserveCapacity((cols + 1) * rows)
        nextStyles.reserveCapacity((cols + 1) * rows)
        for r in 0..<rows {
            for c in 0...cols {
                if c == at {
                    next.append("")
                    nextStyles.append(TableCellStyle())
                }
                if c < cols {
                    next.append(self[row: r, col: c])
                    nextStyles.append(styleAt(row: r, col: c))
                }
            }
        }
        cells = next
        styles = nextStyles
        cols += 1
        // Split the neighbour's width so total stays 1.
        var fractions = colFractions
        let donor = min(at, fractions.count - 1)
        let half = (fractions.isEmpty ? 1 : fractions[donor] / 2)
        if fractions.isEmpty {
            fractions = Array(repeating: 1 / Double(cols), count: cols)
        } else if at >= fractions.count {
            fractions[donor] = half
            fractions.append(half)
        } else {
            fractions[donor] = half
            fractions.insert(half, at: at + (at <= donor ? 1 : 0))
            // `insert` above keeps count == cols; fix the edge case where
            // `at <= donor` misplaces the split by renormalizing anyway.
        }
        colFractions = fractions
        normalizeFractions()
        return true
    }

    @discardableResult
    mutating func deleteColumn(at index: Int) -> Bool {
        guard cols > Self.minCols, index >= 0, index < cols,
              styles.count == rows * cols else { return false }
        var next: [String] = []
        var nextStyles: [TableCellStyle] = []
        next.reserveCapacity((cols - 1) * rows)
        nextStyles.reserveCapacity((cols - 1) * rows)
        for r in 0..<rows {
            for c in 0..<cols where c != index {
                next.append(self[row: r, col: c])
                nextStyles.append(styleAt(row: r, col: c))
            }
        }
        cells = next
        styles = nextStyles
        cols -= 1
        colFractions.remove(at: index)
        normalizeFractions()
        return true
    }

    @discardableResult
    mutating func appendColumn() -> Bool { insertColumn(at: cols) }

    // MARK: Codec

    static func decode(_ data: Data) -> TableContent? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(TableContent.self, from: data)
    }

    func encode() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}
