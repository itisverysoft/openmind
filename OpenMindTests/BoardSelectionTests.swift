import Testing
@testable import OpenMind

/// Shift-click range math for board-list multi-select.
struct BoardSelectionTests {

    @Test func forwardRange() {
        #expect(Array(selectedRange(from: 2, to: 5, count: 8)) == [2, 3, 4, 5])
    }

    @Test func backwardRangeMatchesForward() {
        #expect(Array(selectedRange(from: 5, to: 2, count: 8)) == [2, 3, 4, 5])
    }

    @Test func sameRowSelectsOne() {
        #expect(Array(selectedRange(from: 3, to: 3, count: 8)) == [3])
    }

    @Test func outOfBoundsClamps() {
        #expect(Array(selectedRange(from: -4, to: 99, count: 5)) == [0, 1, 2, 3, 4])
    }

    @Test func emptyListSelectsNothing() {
        #expect(selectedRange(from: 0, to: 3, count: 0).isEmpty)
    }
}

/// Inline-rename draft validation: trims, rejects blanks.
struct BoardRenameTests {

    @Test func trimsWhitespace() {
        #expect(validatedBoardTitle("  Lecture  ") == "Lecture")
    }

    @Test func blankDraftIsNil() {
        #expect(validatedBoardTitle("") == nil)
        #expect(validatedBoardTitle("   \n  ") == nil)
    }

    @Test func plainTitlePassesThrough() {
        #expect(validatedBoardTitle("IELTS Listening") == "IELTS Listening")
    }
}
