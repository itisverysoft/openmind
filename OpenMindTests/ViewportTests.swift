import Testing
import CoreGraphics
@testable import OpenMind

struct ViewportTests {

    @Test func worldAndScreenRoundTrip() {
        let vp = Viewport(offset: CGSize(width: -300, height: 120), scale: 2)
        let screen = CGPoint(x: 410, y: 250)
        let world = vp.worldPoint(for: screen)
        // screen = world * scale + offset
        #expect(abs(world.x * 2 - 300 - screen.x) < 0.001)
        #expect(abs(world.y * 2 + 120 - screen.y) < 0.001)
    }

    @Test func zoomKeepsTheCenterPointFixed() {
        let vp = Viewport(offset: CGSize(width: -100, height: -50), scale: 1)
        let center = CGPoint(x: 400, y: 300)

        let before = vp.worldPoint(for: center)
        let after = vp.applying(zoom: 2, around: center).worldPoint(for: center)

        #expect(abs(before.x - after.x) < 0.001)
        #expect(abs(before.y - after.y) < 0.001)
    }

    @Test func zoomIsClamped() {
        let vp = Viewport()
        let big = vp.applying(zoom: 1000, around: .zero)
        let small = vp.applying(zoom: 0.0001, around: .zero)
        #expect(big.scale == Viewport.maxScale)
        #expect(small.scale == Viewport.minScale)
    }

    @Test func centeredViewportShowsWorldCenterInMiddle() {
        let size = CGSize(width: 800, height: 600)
        let vp = Viewport.centered(on: CanvasMetrics.center, in: size)
        let world = vp.worldPoint(for: CGPoint(x: 400, y: 300))
        #expect(abs(world.x - CanvasMetrics.center.x) < 0.001)
        #expect(abs(world.y - CanvasMetrics.center.y) < 0.001)
    }

    @Test func worldRectConvertsAndNormalizes() {
        let vp = Viewport(offset: CGSize(width: 100, height: 50), scale: 2)
        // Screen (110, 70) -> world (5, 10); screen (130, 90) -> world (15, 20).
        let world = vp.worldRect(for: CGRect(x: 110, y: 70, width: 20, height: 20))
        #expect(abs(world.origin.x - 5) < 0.001)
        #expect(abs(world.origin.y - 10) < 0.001)
        #expect(abs(world.width - 10) < 0.001)
        #expect(abs(world.height - 10) < 0.001)
    }

    @Test func marqueeScreenRectNormalizesReversedDrag() {
        let rect = marqueeScreenRect(from: CGPoint(x: 100, y: 100),
                                     to: CGPoint(x: 40, y: 60))
        #expect(rect == CGRect(x: 40, y: 60, width: 60, height: 40))
    }

    @Test func marqueeSelectsAnyOverlap() {
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),     // fully inside
            CGRect(x: 90, y: 90, width: 100, height: 100),   // partial overlap
            CGRect(x: 500, y: 500, width: 50, height: 50),   // far away
        ]
        let hits = framesIntersectingMarquee(frames: frames,
                                             marqueeWorld: CGRect(x: 0, y: 0, width: 120, height: 120))
        #expect(hits == [0, 1])
    }

    @Test func emptyMarqueeSelectsNothing() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        #expect(framesIntersectingMarquee(frames: frames, marqueeWorld: .zero).isEmpty)
        #expect(framesIntersectingMarquee(frames: [],
                                          marqueeWorld: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }
}
