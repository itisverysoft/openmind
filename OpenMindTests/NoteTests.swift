import Testing
import Foundation
import CoreGraphics
@testable import OpenMind

struct NoteTests {

    @Test func noteKindMetadata() {
        #expect(ItemKind.note.defaultSize == CGSize(width: 48, height: 48))
        #expect(ItemKind.note.isEditable == true)
        #expect(ItemKind.note.isTextEditable == false)
        #expect(!ItemKind.note.placeholder.isEmpty)
    }

    @Test func noteToolIsNotDrawingMode() {
        #expect(CanvasTool.note.isDrawing == false)
        #expect(CanvasTool.draw.isDrawing == true)
    }

    @Test func newNotePinHasReadableDefaultColor() {
        let pin = CanvasItem(kind: .note, x: 100, y: 100)
        // Blue pin keeps the white glyph legible (unlike the yellow default).
        #expect(pin.colorHex == Palette.swatches[3])
    }

    @Test func newNotePinSizeAndText() {
        let pin = CanvasItem(kind: .note, x: 100, y: 100)
        #expect(pin.width == 48)
        #expect(pin.height == 48)
        #expect(pin.text.isEmpty)
    }
}
