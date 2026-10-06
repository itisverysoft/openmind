import Testing
import Foundation
import CoreGraphics
@testable import OpenMind

/// Pure-logic coverage for the Export menu: content bounds, file names,
/// pixel-scale capping, fit-to-paper math, and SVG serialization.
/// (Raster PDF/PNG rendering needs ImageRenderer on the main thread in a
/// running app, so it stays out of unit tests by design.)
struct BoardMediaExportTests {

    private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasItem {
        let item = CanvasItem(kind: .sticky, x: x, y: y)
        item.width = w
        item.height = h
        return item
    }

    // MARK: Bounds

    @Test func boundsUnionWithMargin() throws {
        let items = [box(10, 20, 100, 50), box(200, 40, 60, 60)]
        let b = try #require(exportContentBounds(items: items))
        // Union (10,20,250,80) padded by the 16pt margin on every side.
        #expect(b == CGRect(x: -6, y: 4, width: 282, height: 112))
    }

    @Test func boundsEmptyIsNil() {
        #expect(exportContentBounds(items: []) == nil)
    }

    // MARK: Filenames

    @Test func mediaFilenameRules() {
        #expect(mediaExportFilename(title: "Lecture", ext: "png") == "Lecture.png")
        #expect(mediaExportFilename(title: "  ", ext: "pdf") == "Untitled Board.pdf")
        #expect(mediaExportFilename(title: "a/b", suffix: "selection", ext: "png")
                == "a-b selection.png")
        #expect(mediaExportFilename(title: "Old.png", ext: "png") == "Old.png")
    }

    // MARK: Pixel scale

    @Test func pixelScalePrefersRetina() {
        #expect(exportPixelScale(for: CGSize(width: 300, height: 200)) == 3)
    }

    @Test func pixelScaleCapsHugeBoards() {
        // 4000pt longest side at 3x would be 12000px; capped to 4096.
        let s = exportPixelScale(for: CGSize(width: 4000, height: 1000))
        #expect(abs(s - 4096.0 / 4000.0) < 0.001)
    }

    @Test func pixelScaleDegenerateIsOne() {
        #expect(exportPixelScale(for: .zero) == 1)
    }

    // MARK: Fit math

    @Test func fitScalesAndCenters() throws {
        let content = CGRect(x: 100, y: 100, width: 400, height: 300)
        let sheet = CGRect(x: 0, y: 0, width: 800, height: 600)
        let t = try #require(fitTransform(content: content, sheet: sheet, margin: 0))
        #expect(t.scale == 2)
        // Corners land exactly on the sheet.
        #expect(100 * t.scale + t.dx == 0)
        #expect(100 * t.scale + t.dy == 0)
        #expect(500 * t.scale + t.dx == 800)
        #expect(400 * t.scale + t.dy == 600)
    }

    @Test func fitIdentityWhenAlreadyFitted() throws {
        let sheet = CGRect(x: 0, y: 0, width: 800, height: 600)
        let t = try #require(fitTransform(content: sheet, sheet: sheet, margin: 0))
        #expect(t.scale == 1)
        #expect(t.dx == 0)
        #expect(t.dy == 0)
    }

    @Test func fitDegenerateIsNil() {
        let sheet = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(fitTransform(content: .zero, sheet: sheet) == nil)
    }

    @Test func applyFitScalesEverything() {
        let item = CanvasItem(kind: .drawing, x: 100, y: 100,
                              points: [CGPoint(x: 5, y: 5)], zIndex: 0)
        item.width = 40
        item.height = 20
        item.fontSize = 10
        item.lineWidth = 4
        applyFitTransform(FitTransform(scale: 2, dx: -200, dy: -200), to: item)
        #expect(item.x == 0)
        #expect(item.y == 0)
        #expect(item.width == 80)
        #expect(item.height == 40)
        #expect(item.fontSize == 20)
        #expect(item.lineWidth == 8)
        #expect(item.strokePoints == [CGPoint(x: 10, y: 10)])
    }

    // MARK: SVG

    @Test func svgEscapesText() {
        #expect(svgEscape("a&b<c>d\"e") == "a&amp;b&lt;c&gt;d&quot;e")
        #expect(svgFill(Palette.autoInk) == "#000000")
        #expect(svgFill("FF0000") == "#FF0000")
    }

    @Test func svgStickyHasRectAndText() {
        let item = CanvasItem(kind: .sticky, x: 10, y: 20, text: "hi & bye")
        item.width = 160
        item.height = 160
        let svg = svgDocument(items: [item],
                              bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
                              backgroundHex: "FFFFFF")
        #expect(svg.contains("xmlns=\"http://www.w3.org/2000/svg\""))
        #expect(svg.contains("viewBox=\"0 0 200 200\""))
        #expect(svg.contains("<rect"))
        #expect(svg.contains("hi &amp; bye"))
    }

    @Test func svgShapesAndDrawings() {
        let ellipse = CanvasItem(kind: .shape, shape: .ellipse, x: 0, y: 0)
        let star = CanvasItem(kind: .shape, shape: .star, x: 200, y: 0)
        let stroke = CanvasItem(kind: .drawing, x: 0, y: 200,
                                points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)],
                                zIndex: 0)
        let svg = svgDocument(items: [ellipse, star, stroke],
                              bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                              backgroundHex: "FFFFFF")
        #expect(svg.contains("<ellipse"))
        #expect(svg.contains("<polygon"))
        #expect(svg.contains("<polyline"))
    }

    @Test func svgImageEmbedsDataURI() {
        let image = CanvasItem(kind: .image, x: 0, y: 0)
        // Minimal PNG magic; content beyond the header is irrelevant here.
        image.imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let svg = svgDocument(items: [image],
                              bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                              backgroundHex: "FFFFFF")
        #expect(svg.contains("data:image/png;base64,"))
        #expect(svg.contains("clip-path="))
        #expect(svgImageMIME(Data([0xFF, 0xD8, 0xFF, 0x00])) == "image/jpeg")
        #expect(svgImageMIME(Data("nope".utf8)) == nil)
    }

    @Test func svgTableKeepsCellTextAndStyle() {
        var content = TableContent.makeDefault()
        content[row: 1, col: 0] = "cell & co"
        content.updateStyles(at: [TableCellRef(row: 1, col: 0)]) { $0.bold = true }
        let table = CanvasItem(kind: .table, x: 0, y: 0)
        table.width = 300
        table.height = 120
        table.setTable(content)
        let svg = svgDocument(items: [table],
                              bounds: CGRect(x: 0, y: 0, width: 320, height: 140),
                              backgroundHex: "FFFFFF")
        #expect(svg.contains("Header 1"))
        #expect(svg.contains("cell &amp; co"))
        #expect(svg.contains("font-weight=\"bold\""))
    }

    @Test func svgAudioAndPDFPlaceholders() {
        let audio = CanvasItem(kind: .audio, x: 0, y: 0)
        audio.audioFileName = "note.m4a"
        audio.audioDuration = 65
        let pdf = CanvasItem(kind: .pdf, x: 0, y: 200)
        let svg = svgDocument(items: [audio, pdf],
                              bounds: CGRect(x: 0, y: 0, width: 400, height: 800),
                              backgroundHex: "FFFFFF")
        #expect(svg.contains("note"))
        #expect(svg.contains("1:05"))
        #expect(svg.contains("PDF · page 1"))
    }
}
