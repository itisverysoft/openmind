import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Raster + fit helpers behind the Export menu (board/selection PNG, PDF).
/// Rendering reuses `ItemBodyView` in a static, light-mode tree so exports
/// match the canvas; `BoardSVG.swift` covers the vector path instead.
///
/// Scope notes: board PNG/SVG capture the current page (pages are separate
/// canvases), while PDF gives every non-empty page its own PDF page.
enum BoardMediaExport {
    /// Longest side (pixels) of a rendered export. Pixel scale is picked so
    /// output never exceeds this — huge boards export at ~1x instead of
    /// blowing memory at 3x.
    static let maxPixelSide: CGFloat = 4096
    /// Preferred rasterization scale for PNG (retina-crisp on normal boards).
    static let preferredScale: CGFloat = 3
}

/// Union of item frames, padded by `margin`. Nil when there is nothing (or
/// the union is degenerate), which is also how the menu disables export.
func exportContentBounds(items: [CanvasItem], margin: CGFloat = 16) -> CGRect? {
    var box: CGRect?
    for item in items {
        box = box?.union(item.frameRect) ?? item.frameRect
    }
    guard let box, box.width > 0, box.height > 0,
          box.width.isFinite, box.height.isFinite else { return nil }
    return box.insetBy(dx: -margin, dy: -margin)
}

/// Rasterization scale for `size` (world points): preferred 3x, pulled down
/// only when the output would exceed `maxPixels` on its longest side.
func exportPixelScale(for size: CGSize,
                      maxPixels: CGFloat = BoardMediaExport.maxPixelSide,
                      preferred: CGFloat = BoardMediaExport.preferredScale) -> CGFloat {
    let longest = max(size.width, size.height)
    guard longest > 0, longest.isFinite else { return 1 }
    return min(preferred, maxPixels / longest)
}

/// Static, non-interactive rendering of canvas items at world size. The
/// parent offsets each tile from the content origin; `ImageRenderer` then
/// rasterizes the whole tree at the export pixel scale.
struct BoardStaticExportView: View {
    var items: [CanvasItem]
    var origin: CGPoint
    var size: CGSize
    var background: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            ForEach(items.sorted { $0.zIndex < $1.zIndex }, id: \.id) { item in
                ItemBodyView(item: item)
                    .frame(width: CGFloat(item.width), height: CGFloat(item.height))
                    .offset(x: CGFloat(item.x) - origin.x, y: CGFloat(item.y) - origin.y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Deterministic output: exports always look like light mode, even
        // when the app runs dark.
        .environment(\.colorScheme, .light)
    }
}

/// Renders `items` inside `bounds` to PNG bytes, or nil on any failure.
/// Main-thread only (ImageRenderer).
@MainActor
func renderExportPNG(items: [CanvasItem], bounds: CGRect, background: Color,
                     pixelScale: CGFloat) -> Data? {
    let view = BoardStaticExportView(items: items, origin: bounds.origin,
                                     size: bounds.size, background: background)
    let renderer = ImageRenderer(content: view)
    renderer.scale = pixelScale
    guard let cg = renderer.cgImage else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

/// One rendered page for `renderExportPDF`.
struct ExportPDFPage {
    var items: [CanvasItem]
    var bounds: CGRect
    var background: Color
}

/// Renders each page to a same-sized PDF page (image scaled into a media
/// box of exactly `bounds.size` points). Skips pages that fail to render;
/// nil when no page survived. Main-thread only.
@MainActor
func renderExportPDF(pages: [ExportPDFPage]) -> Data? {
    let doc = PDFDocument()
    var at = 0
    for page in pages {
        let scale = exportPixelScale(for: page.bounds.size, maxPixels: 2048, preferred: 2)
        guard let png = renderExportPNG(items: page.items, bounds: page.bounds,
                                        background: page.background, pixelScale: scale),
              let image = makePlatformImage(from: png),
              let pdfPage = PDFPage(image: image)
        else { continue }
        pdfPage.setBounds(CGRect(origin: .zero, size: page.bounds.size), for: .mediaBox)
        doc.insert(pdfPage, at: at)
        at += 1
    }
    guard doc.pageCount > 0 else { return nil }
    return doc.dataRepresentation()
}

// MARK: - Fit everything onto the paper

/// Uniform scale + translation taking `content` into `sheet` (inset by
/// `margin`), centered. Scale clamps to 0.05...8 so degenerate content can
/// neither vanish nor explode; oversized content then overflows centered.
struct FitTransform {
    var scale: CGFloat
    var dx: CGFloat
    var dy: CGFloat
}

func fitTransform(content: CGRect, sheet: CGRect, margin: CGFloat = 24) -> FitTransform? {
    guard content.width > 0, content.height > 0,
          content.width.isFinite, content.height.isFinite else { return nil }
    let availW = sheet.width - margin * 2
    let availH = sheet.height - margin * 2
    guard availW > 0, availH > 0 else { return nil }
    let raw = min(availW / content.width, availH / content.height)
    guard raw.isFinite, raw > 0 else { return nil }
    let s = min(max(raw, 0.05), 8)
    let dx = sheet.minX + (sheet.width - content.width * s) / 2 - content.minX * s
    let dy = sheet.minY + (sheet.height - content.height * s) / 2 - content.minY * s
    return FitTransform(scale: s, dx: dx, dy: dy)
}

/// Applies a fit transform in place: frame, type size, stroke width, and
/// local stroke points (which also carry line/arrow endpoints) all scale
/// together so the item keeps its proportions. Table grids derive their
/// layout from the frame, so they follow automatically.
func applyFitTransform(_ t: FitTransform, to item: CanvasItem) {
    let s = Double(t.scale)
    item.x = item.x * s + Double(t.dx)
    item.y = item.y * s + Double(t.dy)
    item.width *= s
    item.height *= s
    item.fontSize *= s
    item.lineWidth *= s
    item.strokePoints = item.strokePoints.map {
        CGPoint(x: $0.x * t.scale, y: $0.y * t.scale)
    }
}

// MARK: - Save-panel plumbing

/// Save-panel default: sanitized title plus extension. `suffix` disambiguates
/// ("selection") without touching the title itself.
func mediaExportFilename(title: String, suffix: String = "", ext: String) -> String {
    var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty { base = "Untitled Board" }
    for ch in ["/", ":", "\0"] {
        base = base.replacingOccurrences(of: ch, with: "-")
    }
    let stripped = (base as NSString).deletingPathExtension
    let stem = stripped.isEmpty ? base : stripped
    let named = suffix.isEmpty ? stem : "\(stem) \(suffix)"
    return "\(named).\(ext)"
}

/// Throwaway `FileDocument` for media exports. Bytes are fully rendered
/// before the panel opens, so the panel itself cannot fail.
struct ExportFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .pdf, .svg] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw VSOMError.corrupt("Empty file wrapper.")
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
