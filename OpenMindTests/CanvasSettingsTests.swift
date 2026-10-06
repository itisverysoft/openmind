import Testing
import CoreGraphics
@testable import OpenMind

struct CanvasSettingsTests {

    @Test func infiniteHasNoSheet() {
        let rect = CanvasSheet.worldRect(preset: .infinite,
                                         orientation: .portrait,
                                         center: CGPoint(x: 5000, y: 5000))
        #expect(rect == nil)
    }

    @Test func portraitSheetCentersOnMiddle() {
        let center = CGPoint(x: 5000, y: 5000)
        let rect = CanvasSheet.worldRect(preset: .A4,
                                         orientation: .portrait,
                                         center: center)
        #expect(rect != nil)
        #expect(abs(rect!.width - 595) < 0.01)
        #expect(abs(rect!.height - 842) < 0.01)
        #expect(abs(rect!.midX - center.x) < 0.01)
        #expect(abs(rect!.midY - center.y) < 0.01)
    }

    @Test func landscapeSwapsDimensions() {
        let center = CGPoint(x: 5000, y: 5000)
        let portrait = CanvasSheet.worldRect(preset: .letter, orientation: .portrait, center: center)!
        let landscape = CanvasSheet.worldRect(preset: .letter, orientation: .landscape, center: center)!
        #expect(abs(landscape.width - portrait.height) < 0.01)
        #expect(abs(landscape.height - portrait.width) < 0.01)
    }

    @Test func paperSizesMatchPrintPoints() {
        let center = CGPoint(x: 5000, y: 5000)
        let sizes: [(CanvasSizePreset, CGFloat, CGFloat)] = [
            (.A4, 595, 842),
            (.letter, 612, 792),
            (.A3, 842, 1191),
            (.legal, 612, 1008),
            (.A5, 420, 595),
        ]
        for (preset, w, h) in sizes {
            let rect = CanvasSheet.worldRect(preset: preset, orientation: .portrait, center: center)!
            #expect(abs(rect.width - w) < 0.01)
            #expect(abs(rect.height - h) < 0.01)
        }
    }

    @Test func luminanceSeparatesLightAndDark() {
        #expect(canvasLuminance(hex: "FFFFFF") > 0.9)
        #expect(canvasLuminance(hex: "232328") < 0.25)
    }
}
