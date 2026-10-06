import Testing
import Foundation
import SwiftData
@testable import OpenMind

/// Opening a PDF from the board list creates ONE board with a page system:
/// every document page becomes a separate page-canvas holding that page as
/// a locked background item. Uses an in-memory store — nothing touches disk.
/// (No @MainActor: suite-level main-actor isolation crashes this Xcode's
/// swift-testing runner in `_applyScopingTraits`; Swift 5 mode runs these
/// synchronous store tests fine without it.)
@Suite(.serialized)
struct PDFBoardImportTests {

    private func freshContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Board.self, CanvasItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func importCreatesOnePagedBoard() throws {
        let context = try freshContext()
        let pdf = makeTestPDF(pages: 3)
        let board = try #require(createPDFBoard(data: pdf, fileName: "Lecture.pdf", context: context))
        #expect(board.title == "Lecture")
        #expect(board.pageCount == 3)
        #expect(board.canvasSize == .custom)
        // Letter source stays Letter-sized with portrait orientation.
        #expect(abs(board.customWidth - 612) < 1)
        #expect(abs(board.customHeight - 792) < 1)
        #expect(board.canvasOrientation == .portrait)
        #expect(board.items.count == 3)
        for (index, item) in board.items.enumerated() {
            #expect(item.kind == .pdf)
            #expect(item.pageIndex == index)
            #expect(item.isLocked)
            #expect(item.pdfCount == 1)
            // Each page fills the sheet with the source aspect.
            let aspect = CGFloat(item.width) / CGFloat(item.height)
            #expect(abs(aspect - 612 / 792) < 0.01)
        }
        // Pages read 0, 1, 2 in order.
        #expect(board.items(on: 0).count == 1)
        #expect(board.items(on: 2).count == 1)
    }

    @Test func garbageCreatesNoBoard() throws {
        let context = try freshContext()
        #expect(createPDFBoard(data: Data("nope".utf8),
                               fileName: "x.pdf",
                               context: context) == nil)
        #expect(createPDFBoard(data: Data(),
                               fileName: "x.pdf",
                               context: context) == nil)
    }
}
