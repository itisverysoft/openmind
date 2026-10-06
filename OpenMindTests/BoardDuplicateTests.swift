import Testing
import Foundation
import SwiftData
@testable import OpenMind

/// Board-list multi-select duplication: deep copies carry every setting and
/// item, gain " copy" titles, and never share identity with the original.
/// (No @MainActor — see PDFBoardImportTests for why.)
@Suite(.serialized)
struct BoardDuplicateTests {

    private func freshContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Board.self, CanvasItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func stockedBoard(in context: ModelContext) -> Board {
        let board = Board(title: "Source")
        board.canvasSize = .A4
        board.canvasColorHex = "FFF6D9"
        board.canvasPattern = .grid
        board.pageCount = 2
        context.insert(board)

        let sticky = CanvasItem(kind: .sticky, x: 10, y: 20, text: "hi")
        sticky.pageIndex = 1
        context.insert(sticky)
        sticky.board = board

        let locked = CanvasItem(kind: .text, x: 30, y: 40, text: "locked")
        locked.isLocked = true
        context.insert(locked)
        locked.board = board

        let stroke = CanvasItem(kind: .drawing, x: 0, y: 0,
                                points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
                                zIndex: 5)
        context.insert(stroke)
        stroke.board = board

        let table = CanvasItem(kind: .table, x: 50, y: 60)
        table.setTable(TableContent.makeDefault())
        context.insert(table)
        table.board = board

        let image = CanvasItem(kind: .image, x: 70, y: 80)
        image.imageData = Data([0x89, 0x50, 0x4E, 0x47])
        context.insert(image)
        image.board = board

        let pdf = CanvasItem(kind: .pdf, x: 90, y: 100)
        pdf.pdfData = makeTestPDF(pages: 2)
        pdf.pdfPage = 1
        context.insert(pdf)
        pdf.board = board

        let trash = CanvasItem(kind: .sticky, x: 0, y: 0, text: "trashed")
        trash.isTrashed = true
        context.insert(trash)
        trash.board = board

        return board
    }

    @Test func duplicateCopiesSettingsAndItems() throws {
        let context = try freshContext()
        let source = stockedBoard(in: context)

        let copy = duplicateBoard(source, in: context)
        #expect(copy.title == "Source copy")
        #expect(copy.id != source.id)
        #expect(copy.canvasSize == .A4)
        #expect(copy.canvasColorHex == "FFF6D9")
        #expect(copy.canvasPattern == .grid)
        #expect(copy.pageCount == 2)
        // Trash is left behind, never inherited.
        #expect(copy.items.count == 6)
        #expect(copy.items.allSatisfy { !$0.isTrashed })

        let sticky = try #require(copy.items.first(where: { $0.kind == .sticky && $0.text == "hi" }))
        #expect(sticky.pageIndex == 1)
        // Copies start unlocked even when the original was locked.
        #expect(copy.items.allSatisfy { !$0.isLocked })

        let stroke = try #require(copy.items.first(where: { $0.kind == .drawing }))
        #expect(stroke.strokePoints == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])
        #expect(stroke.zIndex == 5)

        let table = try #require(copy.items.first(where: { $0.kind == .table }))
        #expect(table.getTable().rows == 3)

        let image = try #require(copy.items.first(where: { $0.kind == .image }))
        #expect(image.imageData == Data([0x89, 0x50, 0x4E, 0x47]))

        let pdf = try #require(copy.items.first(where: { $0.kind == .pdf }))
        #expect(pdf.pdfCount == 2)
        #expect(pdf.pdfPage == 1)

        // Original untouched: still 7 items incl. trash, still locked.
        #expect(source.items.count == 7)
        #expect(source.items.contains(where: { $0.isLocked }))
    }

    @Test func duplicateOfEmptyBoard() throws {
        let context = try freshContext()
        let source = Board(title: "Blank")
        context.insert(source)
        let copy = duplicateBoard(source, in: context)
        #expect(copy.title == "Blank copy")
        #expect(copy.items.isEmpty)
    }
}
