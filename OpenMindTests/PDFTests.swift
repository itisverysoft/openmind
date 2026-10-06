import Testing
import Foundation
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import OpenMind

/// Builds a minimal multi-page PDF in memory (Letter pages) without fixtures.
/// Shared with PDFBoardImportTests below. Each page's UPPER half (PDF
/// coordinates) is dark and the lower half light, so render tests can tell
/// upright apart from upside-down.
func makeTestPDF(pages: Int, pageSize: CGSize = CGSize(width: 612, height: 792)) -> Data {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: pageSize)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return Data() }
    for i in 0..<pages {
        ctx.beginPage(mediaBox: nil)
        // Light base with a per-page tint so renders differ page to page.
        let shade = CGFloat(0.9) - CGFloat(i) * 0.05
        ctx.setFillColor(CGColor(gray: shade, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: pageSize))
        // Dark UPPER half (PDF y-up): upright renders show it on top.
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: pageSize.height / 2,
                        width: pageSize.width, height: pageSize.height / 2))
        ctx.endPage()
    }
    ctx.closePDF()
    return data as Data
}

/// Average brightness of an image's top vs. bottom half (CGImage rows run
/// top-down). Trims the outer 10% so aspect-fit letterbox bars can't skew it.
private func halfBrightness(_ cg: CGImage) -> (top: Double, bottom: Double) {
    guard let raw = cg.dataProvider?.data as Data?,
          cg.bitsPerPixel == 32, cg.width > 0, cg.height > 0
    else { return (1, 1) }
    let bpr = cg.bytesPerRow
    func avg(rows: Range<Int>) -> Double {
        var sum = 0.0
        var n = 0
        raw.withUnsafeBytes { buf in
            let base = buf.baseAddress!
            for y in rows {
                let row = base.advanced(by: y * bpr)
                for x in 0..<cg.width {
                    let px = row.advanced(by: x * 4)
                    let r = Double(px.load(fromByteOffset: 0, as: UInt8.self))
                    let g = Double(px.load(fromByteOffset: 1, as: UInt8.self))
                    let b = Double(px.load(fromByteOffset: 2, as: UInt8.self))
                    sum += (r + g + b) / 3 / 255
                    n += 1
                }
            }
        }
        return n > 0 ? sum / Double(n) : 1
    }
    let lo = cg.height / 10, hi = cg.height - lo
    let mid = cg.height / 2
    return (avg(rows: lo..<mid), avg(rows: mid..<hi))
}

/// PDFKit is not thread-safe, so every suite touching it runs serialized.
@Suite(.serialized)
struct PDFTests {

    @Test func validPDFIsRecognized() {
        let pdf = makeTestPDF(pages: 2)
        #expect(!pdf.isEmpty)
        #expect(isPDFData(pdf))
        #expect(pdfPageCount(pdf) == 2)
    }

    @Test func garbageIsNotPDF() {
        #expect(!isPDFData(Data()))
        #expect(!isPDFData(Data("hello".utf8)))
        #expect(!isPDFData(Data("%PDF-".utf8))) // header only, no catalog
        #expect(pdfPageCount(nil) == 0)
        #expect(pdfPageCount(Data("nope".utf8)) == 0)
    }

    @Test func pageSizeMatchesMediaBox() {
        let pdf = makeTestPDF(pages: 2)
        let size = pdfPageSize(pdf, page: 0)
        #expect(size != nil)
        #expect(abs(size!.width - 612) < 1)
        #expect(abs(size!.height - 792) < 1)
        #expect(pdfPageSize(pdf, page: 9) == nil) // out of range
        #expect(pdfPageSize(nil, page: 0) == nil)
    }

    @Test func pageClampStaysInRange() {
        #expect(clampPDFPage(0, count: 0) == 0)
        #expect(clampPDFPage(5, count: 0) == 0)
        #expect(clampPDFPage(-3, count: 4) == 0)
        #expect(clampPDFPage(0, count: 4) == 0)
        #expect(clampPDFPage(2, count: 4) == 2)
        #expect(clampPDFPage(99, count: 4) == 3)
    }

    @Test func pagesRenderToImages() {
        let pdf = makeTestPDF(pages: 2)
        let first = pdfPageImage(data: pdf, page: 0, pixelSize: CGSize(width: 420, height: 560))
        let second = pdfPageImage(data: pdf, page: 1, pixelSize: CGSize(width: 420, height: 560))
        #expect(first != nil)
        #expect(second != nil)
        #expect(pdfPageImage(data: pdf, page: 7, pixelSize: CGSize(width: 100, height: 100)) == nil)
        #expect(pdfPageImage(data: Data("nope".utf8), page: 0, pixelSize: CGSize(width: 100, height: 100)) == nil)
    }

    @Test func renderKeepsPageUpright() throws {
        // The fixture's dark half lives at the TOP of the page: an
        // upside-down render (the old Y-flip bug) puts it at the bottom.
        let pdf = makeTestPDF(pages: 1)
        let img = try #require(pdfPageImage(data: pdf, page: 0,
                                            pixelSize: CGSize(width: 120, height: 160)))
        #if os(macOS)
        let cg = try #require(img.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0) }?.cgImage)
        #else
        let cg = try #require(img.cgImage)
        #endif
        let (top, bottom) = halfBrightness(cg)
        #expect(top < 0.4)
        #expect(bottom > 0.6)
    }

    @Test func pdfItemDefaults() {
        #expect(ItemKind.pdf.defaultSize.width == 420)
        #expect(ItemKind.pdf.defaultSize.height == 560)
        #expect(!ItemKind.pdf.isTextEditable)
        #expect(!ItemKind.pdf.isEditable)
    }

    @Test func singlePageSliceHoldsOnePage() {
        let pdf = makeTestPDF(pages: 3)
        let slice = pdfSinglePageData(pdf, page: 1)
        #expect(slice != nil)
        #expect(pdfPageCount(slice) == 1)
        let size = pdfPageSize(slice, page: 0)
        #expect(size != nil)
        #expect(abs(size!.width - 612) < 1)
        #expect(abs(size!.height - 792) < 1)
        #expect(pdfSinglePageData(pdf, page: 9) == nil)
        #expect(pdfSinglePageData(Data("nope".utf8), page: 0) == nil)
    }
}
