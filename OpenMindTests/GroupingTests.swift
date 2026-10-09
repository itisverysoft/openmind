import Testing
import Foundation
import CoreGraphics
@testable import OpenMind

struct GroupingTests {

    @Test func unionOfTwoFrames() {
        let u = selectionUnion(frames: [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 50, y: 80, width: 100, height: 40),
        ])
        #expect(u == CGRect(x: 0, y: 0, width: 150, height: 120))
    }

    @Test func unionEmptyIsNil() {
        #expect(selectionUnion(frames: []) == nil)
    }

    @Test func uniformScaleKeepsEachRatio() {
        let old = CGRect(x: 0, y: 0, width: 200, height: 100)
        let new = CGRect(x: 0, y: 0, width: 400, height: 200)
        let f = scaledFrame(CGRect(x: 10, y: 10, width: 50, height: 25), from: old, to: new)
        #expect(abs(f.minX - 20) < 0.001)
        #expect(abs(f.minY - 20) < 0.001)
        #expect(abs(f.width - 100) < 0.001)
        #expect(abs(f.height - 50) < 0.001)
        // Member ratio preserved (50/25 == 100/50).
        #expect(abs(f.width / f.height - 2) < 0.001)
    }

    @Test func lockedBoundsKeepAspect() {
        let orig = CGRect(x: 0, y: 0, width: 200, height: 100)
        let b = multiResizeBounds(original: orig, dx: 40, dy: 5, locked: true)
        #expect(abs(b.width / b.height - 2) < 0.001)
        #expect(abs(b.width - 240) < 0.001)
    }

    @Test func freeBoundsStretch() {
        let orig = CGRect(x: 0, y: 0, width: 200, height: 100)
        let b = multiResizeBounds(original: orig, dx: 40, dy: 5, locked: false)
        #expect(b.width == 240)
        #expect(b.height == 105)
    }

    @Test func scaledFramesMapAll() {
        let a = UUID(), b = UUID()
        let old = CGRect(x: 0, y: 0, width: 100, height: 100)
        let new = CGRect(x: 0, y: 0, width: 200, height: 200)
        let out = scaledFrames(
            originals: [a: CGRect(x: 0, y: 0, width: 10, height: 10),
                        b: CGRect(x: 50, y: 50, width: 20, height: 10)],
            from: old, to: new)
        #expect(out[a] == CGRect(x: 0, y: 0, width: 20, height: 20))
        #expect(out[b] == CGRect(x: 100, y: 100, width: 40, height: 20))
    }

    @Test func expandSelectsWholeGroup() {
        let a = UUID(), b = UUID(), c = UUID()
        let g = UUID()
        let groups: [UUID: UUID?] = [a: g, b: g, c: nil]
        #expect(expandedForGroups(selected: [a], groups: groups) == [a, b])
        #expect(expandedForGroups(selected: [c], groups: groups) == [c])
        #expect(expandedForGroups(selected: [b, c], groups: groups) == [a, b, c])
    }

    @Test func groupAvailability() {
        #expect(canGroupSelection(count: 2))
        #expect(!canGroupSelection(count: 1))
        #expect(canUngroupSelection(selectedGroupIDs: [nil, UUID()]))
        #expect(!canUngroupSelection(selectedGroupIDs: [nil, nil]))
    }

    @Test func duplicateRemapKeepsStructure() {
        let g1 = UUID(), g2 = UUID()
        let map = remappedGroupIDs(for: [g1, g1, g2, nil])
        #expect(map.count == 2)
        #expect(map[g1] != nil && map[g2] != nil && map[g1] != map[g2])
    }

    @Test func strokeScalesUniformly() {
        let pts = [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40)]
        let out = scaledStroke(points: pts, sx: 2, sy: 2)
        #expect(out == [CGPoint(x: 20, y: 40), CGPoint(x: 60, y: 80)])
        #expect(abs(scaledLineWidth(4, sx: 2, sy: 2) - 8) < 0.001)
    }
}
