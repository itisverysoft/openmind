import Foundation
import SwiftData
import CoreGraphics

@Model
final class CanvasItem {
    var id: UUID = UUID()
    var kindRaw: String = ItemKind.sticky.rawValue
    var shapeRaw: String = ShapeKind.rectangle.rawValue
    var strokeStyleRaw: String = DrawingStyle.pen.rawValue

    // World-space frame (top-left origin).
    var x: Double = 0
    var y: Double = 0
    var width: Double = 160
    var height: Double = 160

    /// Page this item lives on. 0 for everything on `.infinite` boards and
    /// all legacy content — the page system only splits fixed-size sheets.
    var pageIndex: Int = 0

    var text: String = ""
    var colorHex: String = Palette.swatches[0]
    var fontSize: Double = 18

    // Drawing strokes: JSON-encoded `[[x, y]]` points in the item's local
    // space (relative to x/y), plus the stroke width in world points.
    var pointsData: Data = Data()
    var lineWidth: Double = 4

    /// Rich-text content (RTF) for `.text` items. Empty for legacy plain-text
    /// items, which fall back to `text` + `fontSize`. See RichText.swift.
    var richTextData: Data = Data()

    /// Image bytes for `.image` items (JPEG or PNG, downscaled on import).
    /// Stored outside the database file so boards stay small and fast.
    @Attribute(.externalStorage) var imageData: Data? = nil

    /// Original PDF bytes for `.pdf` items. Pages rasterize on demand (see
    /// CanvasPDF) so the document stays sharp at any zoom without storing
    /// one bitmap per page.
    @Attribute(.externalStorage) var pdfData: Data? = nil

    /// Zero-based index of the displayed page for `.pdf` items. Clamped on
    /// read via `clampedPDFPage` so out-of-range values (e.g. after the
    /// file is replaced) can never crash page lookup.
    var pdfPage: Int = 0

    /// Original audio bytes for `.audio` items (mp3, m4a, wav, …).
    /// Stored outside the database file so boards stay small and fast.
    @Attribute(.externalStorage) var audioData: Data? = nil

    /// Original file name for `.audio` items (shown in the player tile).
    var audioFileName: String = ""

    /// Duration in seconds for `.audio` items, captured on import so the
    /// tile can display it without decoding the bytes on every layout.
    var audioDuration: Double = 0

    /// Raw YouTube URL (or bare video ID) for `.youtube` items, as typed in
    /// the embed prompt / URL editor. The 11-char video ID is derived on
    /// demand via `youtubeVideoID(from:)` so edits never desync.
    var youtubeURL: String = ""

    /// Original video bytes for `.video` items (mp4, mov, m4a, …).
    /// Stored outside the database file so boards stay small and fast.
    @Attribute(.externalStorage) var videoData: Data? = nil

    /// Original file name for `.video` items (shown in the player tile).
    var videoFileName: String = ""

    /// Duration in seconds for `.video` items, captured on import so the
    /// tile can display it without decoding the bytes on every layout.
    var videoDuration: Double = 0

    /// JSON-encoded `TableContent` for `.table` items. Empty for all other
    /// kinds. Decoded via `getTable()` / written via `setTable(_:)`.
    var tableData: Data = Data()

    /// Higher values draw on top.
    var zIndex: Double = 0

    /// Soft-delete flag (trash). Deletes set this instead of removing the
    /// object so undo can restore them: SwiftData undo reliably reverts
    /// attribute changes across saves, but object resurrection after
    /// `context.delete` does not survive the next save. Trashed items are
    /// hidden everywhere and hard-deleted on next app launch (when no undo
    /// stack exists that could still reference them).
    /// Named `isTrashed` (not `isDeleted`) to avoid Core Data's reserved
    /// `isDeleted` deletion-state flag.
    var isTrashed: Bool = false

    /// Lock flag. Locked items stay selectable (so they can be unlocked via
    /// the context menu) but reject moves, resizes, edits, deletes,
    /// recolors, restacks, and erasing.
    var isLocked: Bool = false

    /// Persistent group identity. Items sharing the same `groupID` behave
    /// as one unit: selecting any member selects the whole group, and
    /// moves/resizes apply together. Nil = ungrouped.
    var groupID: UUID? = nil

    var board: Board?

    init(kind: ItemKind,
         shape: ShapeKind = .rectangle,
         strokeStyle: DrawingStyle = .pen,
         x: Double,
         y: Double,
         text: String = "",
         colorHex: String? = nil,
         lineWidth: Double? = nil,
         points: [CGPoint] = [],
         zIndex: Double = 0) {
        self.kindRaw = kind.rawValue
        self.shapeRaw = shape.rawValue
        self.strokeStyleRaw = strokeStyle.rawValue
        self.x = x
        self.y = y
        self.width = kind.defaultSize.width
        self.height = kind.defaultSize.height
        self.text = text
        // Blue pin by default so the white glyph stays legible; shapes use
        // blue as their fill, everything else the yellow default.
        self.colorHex = colorHex ?? (kind == .shape || kind == .note ? Palette.swatches[3] : Palette.swatches[0])
        self.fontSize = kind.defaultFontSize
        self.lineWidth = lineWidth ?? strokeStyle.defaultLineWidth
        self.pointsData = StrokeCodec.encode(points)
        self.zIndex = zIndex
    }

    // MARK: Typed access to the raw strings

    var kind: ItemKind {
        get { ItemKind(rawValue: kindRaw) ?? .sticky }
        set { kindRaw = newValue.rawValue }
    }

    var shape: ShapeKind {
        get { ShapeKind(rawValue: shapeRaw) ?? .rectangle }
        set { shapeRaw = newValue.rawValue }
    }

    var strokeStyle: DrawingStyle {
        get { DrawingStyle(rawValue: strokeStyleRaw) ?? .pen }
        set { strokeStyleRaw = newValue.rawValue }
    }

    /// Stroke points in the item's local space (add x/y for world space).
    var strokePoints: [CGPoint] {
        get { StrokeCodec.decode(pointsData) }
        set { pointsData = StrokeCodec.encode(newValue) }
    }

    // MARK: Line endpoints (line-like shapes only)

    /// Normalized (0...1) box-fraction endpoints `[A, B]` for line-like
    /// `.shape` items (`.line`, `.arrow`, `.doubleArrow`), letting lines run
    /// any direction — unlike the legacy fixed diagonal. Fractions (not
    /// points) so resize stretches the line with its frame, duplication
    /// copies it via `strokePoints`, and no schema migration was needed.
    /// Empty for legacy items, which render the old diagonal instead.
    var lineEndpoints: [CGPoint] {
        get {
            guard kind == .shape, shape.isLineLike else { return [] }
            let pts = strokePoints
            return pts.count >= 2 ? [pts[0], pts[1]] : []
        }
        set { strokePoints = Array(newValue.prefix(2)) }
    }

    // MARK: PDF page

    /// Page count of the stored document, or 0 when there is none.
    var pdfCount: Int { pdfPageCount(pdfData) }

    /// Displayed page clamped into range. Never out-of-bounds.
    var clampedPDFPage: Int { clampPDFPage(pdfPage, count: pdfCount) }

    /// Media-box size of the displayed page in points, for aspect fitting.
    var pdfDisplaySize: CGSize? { pdfPageSize(pdfData, page: clampedPDFPage) }

    // MARK: Table content
    /// Decoded table, or a default 3x3 when empty/corrupt. Never mutates.
    func getTable() -> TableContent {
        if let decoded = TableContent.decode(tableData) {
            return decoded
        }
        return TableContent.makeDefault()
    }

    /// Persists table content. Callers must `touch()`/save afterwards.
    func setTable(_ table: TableContent) {
        tableData = table.encode()
    }

    /// Ensures a `.table` item actually carries table bytes (creation path
    /// and legacy items). No-op for other kinds.
    func ensureTable() {
        guard kind == .table, TableContent.decode(tableData) == nil else { return }
        setTable(TableContent.makeDefault())
    }

    /// Sets the frame to the stroke's bounding box (padded by the line width)
    /// and stores points relative to the new origin. Points are world-space.
    func adoptStroke(worldPoints: [CGPoint]) {
        var pad = CGFloat(lineWidth) / 2 + 2
        if strokeStyle == .arrow {
            // The head's wings spread sideways past the shaft's bounding box.
            pad += max(10, CGFloat(lineWidth) * 3.5)
        }
        let xs = worldPoints.map(\.x)
        let ys = worldPoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return }
        x = minX - pad
        y = minY - pad
        width = max(4, maxX - minX + pad * 2)
        height = max(4, maxY - minY + pad * 2)
        strokePoints = worldPoints.map { CGPoint(x: $0.x - x, y: $0.y - y) }
    }

    /// Hit-tests a world-space point against the stroke.
    /// - Parameter tolerance: extra world-space padding around the stroke.
    func strokeHitTest(world point: CGPoint, tolerance: CGFloat) -> Bool {
        let local = CGPoint(x: point.x - CGFloat(x), y: point.y - CGFloat(y))
        return polylineHitTest(points: strokePoints, style: strokeStyle,
                               lineWidth: CGFloat(lineWidth), at: local, tolerance: tolerance)
    }

    /// World-space frame, for marquee hit-testing.
    var frameRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
