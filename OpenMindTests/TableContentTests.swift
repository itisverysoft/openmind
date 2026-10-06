import Testing
import Foundation
@testable import OpenMind

struct TableContentTests {

    @Test func defaultTableIs3x3WithHeaders() {
        let t = TableContent.makeDefault()
        #expect(t.rows == 3)
        #expect(t.cols == 3)
        #expect(t.hasHeader == true)
        #expect(t[row: 0, col: 0] == "Header 1")
        #expect(t[row: 1, col: 0] == "")
        #expect(t.colFractions.count == 3)
        let sum = t.colFractions.reduce(0, +)
        #expect(abs(sum - 1) < 0.001)
    }

    @Test func cellSubscriptReadsAndWrites() {
        var t = TableContent(rows: 2, cols: 2)
        t[row: 0, col: 0] = "A"
        t[row: 1, col: 1] = "D"
        #expect(t[row: 0, col: 0] == "A")
        #expect(t[row: 1, col: 1] == "D")
        #expect(t[row: 0, col: 1] == "")
        // Out of bounds is a safe no-op.
        t[row: 9, col: 9] = "X"
        #expect(t[row: 9, col: 9] == "")
    }

    @Test func insertAndDeleteRowPreservesCells() {
        var t = TableContent(rows: 2, cols: 2)
        t[row: 0, col: 0] = "A"
        t[row: 0, col: 1] = "B"
        t[row: 1, col: 0] = "C"
        t[row: 1, col: 1] = "D"
        #expect(t.insertRow(at: 1) == true)
        #expect(t.rows == 3)
        #expect(t[row: 0, col: 0] == "A")
        #expect(t[row: 1, col: 0] == "")
        #expect(t[row: 2, col: 0] == "C")
        #expect(t.deleteRow(at: 1) == true)
        #expect(t.rows == 2)
        #expect(t[row: 1, col: 1] == "D")
    }

    @Test func insertAndDeleteColumnPreservesCells() {
        var t = TableContent(rows: 2, cols: 2)
        t[row: 0, col: 0] = "A"
        t[row: 0, col: 1] = "B"
        #expect(t.insertColumn(at: 1) == true)
        #expect(t.cols == 3)
        #expect(t[row: 0, col: 0] == "A")
        #expect(t[row: 0, col: 1] == "")
        #expect(t[row: 0, col: 2] == "B")
        #expect(t.colFractions.count == 3)
        #expect(t.deleteColumn(at: 1) == true)
        #expect(t.cols == 2)
        #expect(t[row: 0, col: 1] == "B")
    }

    @Test func rowColumnLimitsAreEnforced() {
        var t = TableContent(rows: 1, cols: 1)
        #expect(t.deleteRow(at: 0) == false)
        #expect(t.deleteColumn(at: 0) == false)
        var big = TableContent(rows: TableContent.maxRows, cols: TableContent.maxCols)
        #expect(big.appendRow() == false)
        #expect(big.appendColumn() == false)
        #expect(big.rows == TableContent.maxRows)
        #expect(big.cols == TableContent.maxCols)
    }

    @Test func columnResizeKeepsTotalAtOne() {
        var t = TableContent(rows: 2, cols: 3)
        t.resizeColumns(divider: 0, by: 0.1)
        let sum = t.colFractions.reduce(0, +)
        #expect(abs(sum - 1) < 0.001)
        #expect(t.colFractions[0] > t.colFractions[1])
        // Clamped at the minimum instead of going negative.
        t.resizeColumns(divider: 0, by: -10)
        #expect(t.colFractions.allSatisfy { $0 >= 0.05 })
    }

    @Test func codecRoundTrips() {
        var t = TableContent.makeDefault()
        t[row: 2, col: 2] = "Hello"
        t.hasHeader = false
        let data = t.encode()
        #expect(!data.isEmpty)
        let back = TableContent.decode(data)
        #expect(back == t)
        #expect(TableContent.decode(Data()).isNil)
    }

    @Test func legacyJSONWithoutStylesDecodesWithDefaults() {
        // Pre-format tables stored no `styles` key; they must still decode,
        // with one default style per cell.
        let json = """
        {"rows":2,"cols":2,"cells":["a","b","c","d"],"hasHeader":false,"colFractions":[0.5,0.5]}
        """
        let back = TableContent.decode(Data(json.utf8))
        #expect(back != nil)
        #expect(back?.rows == 2)
        #expect(back?.styles.count == 4)
        #expect(back?.styles.allSatisfy { $0 == TableCellStyle() } == true)
        #expect(back?[row: 0, col: 0] == "a")
    }

    @Test func rowOpsKeepStylesAligned() {
        var t = TableContent(rows: 2, cols: 2)
        t.updateStyles(at: [TableCellRef(row: 0, col: 0)]) {
            $0.bold = true
            $0.backgroundHex = "FFC9D6"
        }
        #expect(t.insertRow(at: 1) == true)
        #expect(t.styles.count == 6)
        #expect(t.styleAt(row: 0, col: 0).bold == true)
        #expect(t.styleAt(row: 0, col: 0).backgroundHex == "FFC9D6")
        // Inserted row carries default styles.
        #expect(t.styleAt(row: 1, col: 0) == TableCellStyle())
        // Former row 1 shifted to row 2 with default styles.
        #expect(t.styleAt(row: 2, col: 0) == TableCellStyle())
        #expect(t.deleteRow(at: 0) == true)
        #expect(t.styles.count == 4)
        #expect(t.styleAt(row: 0, col: 0) == TableCellStyle())
    }

    @Test func columnOpsKeepStylesAligned() {
        var t = TableContent(rows: 2, cols: 2)
        t.updateStyles(at: [TableCellRef(row: 1, col: 1)]) { $0.italic = true }
        #expect(t.insertColumn(at: 0) == true)
        #expect(t.styles.count == 6)
        // Former (1,1) moved to (1,2) with its style.
        #expect(t.styleAt(row: 1, col: 2).italic == true)
        #expect(t.styleAt(row: 1, col: 0) == TableCellStyle())
        #expect(t.deleteColumn(at: 2) == true)
        #expect(t.styles.count == 4)
        #expect(t.styles.allSatisfy { $0 == TableCellStyle() })
    }

    @Test func rangeCellsFormsInclusiveRect() {
        let range = TableContent.rangeCells(from: TableCellRef(row: 2, col: 3),
                                            to: TableCellRef(row: 0, col: 1))
        #expect(range.count == 3 * 3)
        #expect(range.contains(TableCellRef(row: 0, col: 1)))
        #expect(range.contains(TableCellRef(row: 2, col: 3)))
        #expect(!range.contains(TableCellRef(row: 0, col: 0)))
        #expect(!range.contains(TableCellRef(row: 3, col: 1)))
        // Single cell range.
        let single = TableContent.rangeCells(from: TableCellRef(row: 1, col: 1),
                                             to: TableCellRef(row: 1, col: 1))
        #expect(single == [TableCellRef(row: 1, col: 1)])
    }

    @Test func sanitizedCellsDropsOutOfRangeRefs() {
        let t = TableContent(rows: 2, cols: 2)
        let refs: Set<TableCellRef> = [TableCellRef(row: 0, col: 0),
                                        TableCellRef(row: 5, col: 5)]
        #expect(t.sanitizedCells(refs) == [TableCellRef(row: 0, col: 0)])
    }

    @Test func alignmentMappingRoundTrips() {
        #expect(tableCellAlignment(from: "center") == .center)
        #expect(tableCellAlignment(from: "right") == .right)
        #expect(tableCellAlignment(from: "left") == .left)
        #expect(tableCellAlignment(from: "bogus") == .left)
        #expect(tableCellAlignmentRaw(.center) == "center")
        #expect(tableCellAlignmentRaw(.right) == "right")
        #expect(tableCellAlignmentRaw(.left) == "left")
    }
}

private extension Optional {
    var isNil: Bool { self == nil }
}
