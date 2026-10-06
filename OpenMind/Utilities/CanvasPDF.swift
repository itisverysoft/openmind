import Foundation
import CoreGraphics
import SwiftUI
import SwiftData
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// PDFKit is not thread-safe (documents, pages, and CG PDF drawing must not
/// run concurrently), so every entry below funnels through one lock. All
/// current app calls are main-thread, but parallel tests and any future
/// background thumbnailing share these helpers — the lock keeps them safe.
private let pdfKitLock = NSLock()

/// Runs `work` with exclusive PDFKit access.
private func withPDFKit<T>(_ work: () -> T?) -> T? {
    pdfKitLock.lock()
    defer { pdfKitLock.unlock() }
    return work()
}

/// Max pixel dimension for a rendered PDF page (longest side). Keeps zoomed
/// pages sharp without blowing memory on print-resolution documents.
enum CanvasPDF {
    static let maxPixelDimension: CGFloat = 2048
    /// Largest side (world points) of a newly imported PDF page.
    static let maxWorldSide: CGFloat = 420
    /// Largest PDF accepted on import (bytes). Beyond this the document
    /// stays in Files — rendering whole books would spike memory.
    static let maxImportBytes: Int = 100 * 1024 * 1024
}

/// True when `data` looks like a readable PDF (magic bytes + PDFKit parses
/// the header). Encrypted documents whose catalog won't open fail here and
/// are rejected on import like corrupt files.
func isPDFData(_ data: Data) -> Bool {
    guard data.count > 5,
          data.prefix(5) == Data("%PDF-".utf8)
    else { return false }
    return withPDFKit {
        PDFDocument(data: data).map { $0.pageCount > 0 }
    } ?? false
}

/// Number of pages, or 0 when `data` is not a readable PDF.
func pdfPageCount(_ data: Data?) -> Int {
    guard let data else { return 0 }
    return withPDFKit {
        PDFDocument(data: data).map { $0.pageCount }
    } ?? 0
}

/// Media-box size of one page in points. Nil for bad data / out-of-range.
func pdfPageSize(_ data: Data?, page index: Int) -> CGSize? {
    withPDFKit {
        guard let data,
              let page = PDFDocument(data: data)?.page(at: index)
        else { return nil }
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        return CGSize(width: abs(box.width), height: abs(box.height))
    }
}

/// Clamps a page index into `0..<count` (0 when the document is empty).
func clampPDFPage(_ page: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(page, 0), count - 1)
}

/// Reads a PDF file with security-scoped access when needed (file importer
/// and drag-and-drop file URLs). Nil when unreadable, oversized, or not a
/// readable PDF.
func pdfDataFromFileURL(_ url: URL) -> Data? {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url),
          data.count <= CanvasPDF.maxImportBytes,
          isPDFData(data)
    else { return nil }
    return data
}

/// Renders one page onto a white sheet at `pixelSize` (aspect-fit). Nil on
/// any failure. Called once per cache key — see `PDFRenderCache`.
///
/// Uses `PDFPage.thumbnail`, which rasterizes orientation-correct (page
/// `/Rotate` honored) — then composites onto opaque white. No manual Y-flip:
/// bitmap user space already displays upright, and the extra flip is what
/// used to turn pages upside down.
func pdfPageImage(data: Data, page index: Int, pixelSize: CGSize) -> PlatformImage? {
    return withPDFKit {
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: index),
              pixelSize.width > 0, pixelSize.height > 0
        else { return nil }
        let longest = max(pixelSize.width, pixelSize.height)
        let capped = longest > 0 ? min(1, CanvasPDF.maxPixelDimension / longest) : 1
        let target = CGSize(width: max(1, (pixelSize.width * capped).rounded()),
                            height: max(1, (pixelSize.height * capped).rounded()))
        let thumb = page.thumbnail(of: target, for: .mediaBox)
#if os(macOS)
        guard let tiff = thumb.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage
        else { return nil }
#else
        guard let cg = thumb.cgImage else { return nil }
#endif
        let tw = CGFloat(cg.width), th = CGFloat(cg.height)
        guard tw > 0, th > 0 else { return nil }
        // Aspect-fit the raster onto the white sheet, centered.
        let fit = min(target.width / tw, target.height / th)
        let dw = tw * fit, dh = th * fit
        let dx = (target.width - dw) / 2, dy = (target.height - dh) / 2
        let w = max(1, Int(target.width)), h = max(1, Int(target.height))
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        guard let out = ctx.makeImage() else { return nil }
#if os(macOS)
        return NSImage(cgImage: out, size: NSSize(width: w, height: h))
#else
        return UIImage(cgImage: out)
#endif
    }
}

/// Extracts one page as a standalone single-page PDF. Nil for bad data /
/// out-of-range pages. Used when opening a document from the board list so
/// every page becomes its own page-canvas holding just that page.
func pdfSinglePageData(_ data: Data, page index: Int) -> Data? {
    withPDFKit {
        guard let src = PDFDocument(data: data),
              let page = src.page(at: index),
              let copy = page.copy() as? PDFPage
        else { return nil }
        let single = PDFDocument()
        single.insert(copy, at: 0)
        return single.dataRepresentation()
    }
}

/// Opens a PDF from the board list as ONE board with a page system: every
/// document page becomes a separate page-canvas holding that page as a
/// locked full-sheet background item, and the board's sheet takes the
/// document's size (`.custom`) so pages fit exactly. The full toolbar works
/// over every page. Nil for unreadable documents.
func createPDFBoard(data: Data, fileName: String, context: ModelContext) -> Board? {
    guard isPDFData(data) else { return nil }
    let count = pdfPageCount(data)
    guard count > 0,
          let firstSize = pdfPageSize(data, page: 0),
          firstSize.width > 0, firstSize.height > 0
    else { return nil }
    // Portrait-normalized sheet matching the document; the orientation flag
    // records the original way round so landscape PDFs stay landscape.
    let isPortrait = firstSize.width <= firstSize.height
    let base = isPortrait
        ? firstSize
        : CGSize(width: firstSize.height, height: firstSize.width)
    let board = Board(title: (fileName as NSString).deletingPathExtension)
    board.canvasSize = .custom
    board.canvasOrientation = isPortrait ? .portrait : .landscape
    board.customWidth = Double(base.width)
    board.customHeight = Double(base.height)
    // Document fidelity over canvas defaults: a white plain sheet.
    board.canvasColorHex = "FFFFFF"
    board.canvasPattern = .plain
    board.pageCount = 0
    guard let sheet = board.sheetWorldRect else { return nil }
    context.insert(board)
    for i in 0..<count {
        guard let slice = pdfSinglePageData(data, page: i),
              let pageSize = pdfPageSize(slice, page: 0),
              pageSize.width > 0, pageSize.height > 0
        else { continue }
        // Aspect-fit the page into the sheet (full-bleed for uniform docs).
        let fit = min(sheet.width / pageSize.width, sheet.height / pageSize.height)
        let w = pageSize.width * fit, h = pageSize.height * fit
        let index = board.addPage()
        let item = CanvasItem(kind: .pdf,
                              x: sheet.midX - w / 2,
                              y: sheet.midY - h / 2,
                              zIndex: 0)
        item.width = Double(w)
        item.height = Double(h)
        item.pdfData = slice
        item.pdfPage = 0
        item.pageIndex = index
        // Locked background: annotations layer above and the page itself
        // can never be dragged away by accident.
        item.isLocked = true
        context.insert(item)
        item.board = board
    }
    guard board.pageCount > 0 else {
        context.delete(board)
        return nil
    }
    return board
}

/// In-memory page renders keyed by document + page + pixel size, so canvas
/// re-layouts never re-rasterize. Evicted automatically under pressure.
enum PDFRenderCache {
    private static let cache = NSCache<NSString, PlatformImage>()

    static func image(cacheKey: String, data: Data, page: Int, pixelSize: CGSize) -> PlatformImage? {
        let key = "\(cacheKey)-p\(page)-\(Int(pixelSize.width))x\(Int(pixelSize.height))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let rendered = pdfPageImage(data: data, page: page, pixelSize: pixelSize) else { return nil }
        cache.setObject(rendered, forKey: key)
        return rendered
    }
}

/// Draws one PDF page at the tile's on-screen size (points × zoom × retina),
/// capped for memory. Falls back to a document glyph while unloadable.
struct PDFPageImage: View {
    var cacheKey: String
    var data: Data
    var page: Int
    /// Frame size in points (before zoom).
    var pointSize: CGSize
    /// Current viewport zoom.
    var zoom: CGFloat

    private var pixelSize: CGSize {
        let retina: CGFloat = 3
        return CGSize(width: pointSize.width * zoom * retina,
                      height: pointSize.height * zoom * retina)
    }

    var body: some View {
        Group {
            if let img = PDFRenderCache.image(cacheKey: cacheKey,
                                              data: data,
                                              page: page,
                                              pixelSize: pixelSize) {
#if os(macOS)
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
#else
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
#endif
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "doc.richtext")
                    Text("Couldn't render page")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}
