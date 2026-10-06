import Testing
import Foundation
@testable import OpenMind

/// Page-system model rules: per-page item lookup, add/delete pages, and the
/// merge back to a single page when a board returns to `.infinite`.
/// Transient models only — no store needed.
struct PageSystemTests {

    private func boardWithTwoPages() -> Board {
        let board = Board(title: "Paged")
        board.canvasSize = .A4
        board.pageCount = 2
        let first = CanvasItem(kind: .sticky, x: 0, y: 0, text: "p0")
        first.pageIndex = 0
        let second = CanvasItem(kind: .sticky, x: 0, y: 0, text: "p1")
        second.pageIndex = 1
        board.items.append(contentsOf: [first, second])
        return board
    }

    @Test func itemsFilterByPage() {
        let board = boardWithTwoPages()
        #expect(board.items(on: 0).map(\.text) == ["p0"])
        #expect(board.items(on: 1).map(\.text) == ["p1"])
        #expect(board.items(on: 2).isEmpty)
    }

    @Test func legacyItemsLiveOnPageZero() {
        let board = Board(title: "Legacy")
        let item = CanvasItem(kind: .sticky, x: 0, y: 0, text: "old")
        board.items.append(item)
        #expect(item.pageIndex == 0)
        #expect(board.items(on: 0).count == 1)
    }

    @Test func addPageAppendsIndex() {
        let board = Board(title: "Fresh")
        #expect(board.pageCount == 1)
        #expect(board.addPage() == 1)
        #expect(board.pageCount == 2)
    }

    @Test func deleteRefusesLastPageAndFullPages() {
        let board = boardWithTwoPages()
        // Page 0 holds an item — refused.
        #expect(!board.deletePage(at: 0))
        #expect(board.pageCount == 2)
        // Empty the page, then it deletes and higher pages shift down.
        board.items(on: 0).forEach { $0.isTrashed = true }
        #expect(board.deletePage(at: 0))
        #expect(board.pageCount == 1)
        #expect(board.items.first?.pageIndex == 0)
        #expect(board.items(on: 0).count == 1)
        // The last page can never go.
        #expect(!board.deletePage(at: 0))
    }

    @Test func mergeCollapsesToSinglePage() {
        let board = boardWithTwoPages()
        board.mergePagesToSingle()
        #expect(board.pageCount == 1)
        #expect(board.items(on: 0).count == 2)
    }

    @Test func customSheetMatchesStoredSize() {
        let board = Board(title: "Doc")
        board.canvasSize = .custom
        board.customWidth = 612
        board.customHeight = 792
        board.canvasOrientation = .portrait
        let portrait = board.sheetWorldRect
        #expect(portrait != nil)
        #expect(abs(portrait!.width - 612) < 0.01)
        #expect(abs(portrait!.height - 792) < 0.01)
        board.canvasOrientation = .landscape
        let landscape = board.sheetWorldRect
        #expect(abs(landscape!.width - 792) < 0.01)
        #expect(abs(landscape!.height - 612) < 0.01)
    }

    @Test func infiniteHasNoPageSystem() {
        let board = Board(title: "Free")
        #expect(!board.isPaged)
        board.canvasSize = .A4
        #expect(board.isPaged)
    }
}
