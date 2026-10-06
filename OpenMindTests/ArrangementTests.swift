import Testing
import Foundation
@testable import OpenMind

/// Bottom→top fixture: A at the back, D in front.
private func fixture() -> (a: UUID, b: UUID, c: UUID, d: UUID, order: [UUID]) {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    return (a, b, c, d, [a, b, c, d])
}

struct ArrangementTests {

    @Test func bringToFrontMovesSingleToTop() {
        let f = fixture()
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.b],
                                   operation: .bringToFront)
        #expect(result == [f.a, f.c, f.d, f.b])
    }

    @Test func bringToFrontKeepsMultiOrder() {
        let f = fixture()
        // Selected out of order in the set; current relative order wins.
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.c, f.a],
                                   operation: .bringToFront)
        #expect(result == [f.b, f.d, f.a, f.c])
    }

    @Test func bringToFrontNoOpWhenAlreadyTop() {
        let f = fixture()
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.c, f.d],
                                   operation: .bringToFront)
        #expect(result == f.order)
    }

    @Test func sendToBackMovesSingleToBottom() {
        let f = fixture()
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.c],
                                   operation: .sendToBack)
        #expect(result == [f.c, f.a, f.b, f.d])
    }

    @Test func sendToBackNoOpWhenAlreadyBottom() {
        let f = fixture()
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.a, f.b],
                                   operation: .sendToBack)
        #expect(result == f.order)
    }

    @Test func bringForwardMovesSingleOneStep() {
        let f = fixture()
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.b],
                                   operation: .bringForward)
        #expect(result == [f.a, f.c, f.b, f.d])
    }

    @Test func bringForwardNoOpAtTop() {
        let f = fixture()
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.d],
                                   operation: .bringForward)
        #expect(result == f.order)
    }

    @Test func bringForwardMovesBlockTogether() {
        let f = fixture()
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.b, f.c],
                                   operation: .bringForward)
        #expect(result == [f.a, f.d, f.b, f.c])
    }

    @Test func sendBackwardMovesSingleOneStep() {
        let f = fixture()
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.c],
                                   operation: .sendBackward)
        #expect(result == [f.a, f.c, f.b, f.d])
    }

    @Test func sendBackwardNoOpAtBottom() {
        let f = fixture()
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.a],
                                   operation: .sendBackward)
        #expect(result == f.order)
    }

    @Test func sendBackwardMovesBlockTogether() {
        let f = fixture()
        let result = arrangedOrder(sortedIDs: f.order, selectedIDs: [f.b, f.c],
                                   operation: .sendBackward)
        #expect(result == [f.b, f.c, f.a, f.d])
    }

    @Test func emptyAndUnknownSelectionsAreNoOps() {
        let f = fixture()
        for op in ArrangeOperation.allCases {
            #expect(arrangedOrder(sortedIDs: f.order, selectedIDs: [],
                                  operation: op) == f.order)
            #expect(arrangedOrder(sortedIDs: f.order, selectedIDs: [UUID()],
                                  operation: op) == f.order)
        }
    }
}
