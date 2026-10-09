import Foundation
import SwiftData
import CoreGraphics

@Model
final class Board {
    var id: UUID = UUID()
    var title: String = "Untitled Board"
    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now

    /// Canvas sheet settings (see CanvasSettings.swift). Raw strings keep the
    /// schema lightweight; typed accessors below fall back to safe defaults
    /// for legacy boards. `canvasColorHex` is the sheet fill (or the custom
    /// colour); the infinite canvas keeps the system background.
    var canvasSizeRaw: String = CanvasSizePreset.infinite.rawValue
    var canvasOrientationRaw: String = CanvasOrientation.portrait.rawValue
    var canvasColorHex: String = "FFFFFF"
    var canvasPatternRaw: String = CanvasPattern.dots.rawValue
    /// Portrait-base dimensions for `.custom` sheets (e.g. a PDF page size).
    var customWidth: Double = 595
    var customHeight: Double = 842

    /// Page system: any fixed size (anything but `.infinite`) is paged —
    /// each page is a separate canvas of the sheet size. `.infinite` always
    /// collapses to a single page (see `mergePagesToSingle`).
    var pageCount: Int = 1

    /// Deleting a board deletes its items.
    @Relationship(deleteRule: .cascade, inverse: \CanvasItem.board)
    var items: [CanvasItem] = []

    init(title: String = "Untitled Board") {
        self.title = title
    }

    // MARK: Canvas settings (typed access)

    var canvasSize: CanvasSizePreset {
        get { CanvasSizePreset(rawValue: canvasSizeRaw) ?? .infinite }
        set { canvasSizeRaw = newValue.rawValue }
    }

    var canvasOrientation: CanvasOrientation {
        get { CanvasOrientation(rawValue: canvasOrientationRaw) ?? .portrait }
        set { canvasOrientationRaw = newValue.rawValue }
    }

    var canvasPattern: CanvasPattern {
        get { CanvasPattern(rawValue: canvasPatternRaw) ?? .dots }
        set { canvasPatternRaw = newValue.rawValue }
    }

    /// World-space sheet rect centered on the canvas middle, or nil for
    /// `.infinite` (no sheet — items live on the freeform canvas). The same
    /// rect backs every page: pages are separate canvases, not stacked
    /// sheets, so flipping never moves the viewport.
    var sheetWorldRect: CGRect? {
        if canvasSize == .custom {
            let base = CGSize(width: max(1, customWidth), height: max(1, customHeight))
            let size: CGSize
            switch canvasOrientation {
            case .portrait:  size = base
            case .landscape: size = CGSize(width: base.height, height: base.width)
            }
            let c = CanvasMetrics.center
            return CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2,
                          width: size.width, height: size.height)
        }
        return CanvasSheet.worldRect(preset: canvasSize,
                                     orientation: canvasOrientation,
                                     center: CanvasMetrics.center)
    }

    /// True when the board uses the page system (any fixed sheet size).
    var isPaged: Bool { canvasSize != .infinite }

    /// Visible (non-trashed) items on one page.
    func items(on page: Int) -> [CanvasItem] {
        items.filter { !$0.isTrashed && $0.pageIndex == page }
    }

    /// Appends a blank page and returns its index.
    @discardableResult
    func addPage() -> Int {
        pageCount += 1
        return pageCount - 1
    }

    /// Deletes a page and shifts higher pages down. Refused (false) for the
    /// last page or a page holding items, so content is never orphaned.
    @discardableResult
    func deletePage(at index: Int) -> Bool {
        guard pageCount > 1, items(on: index).isEmpty else { return false }
        for item in items where item.pageIndex > index {
            item.pageIndex -= 1
        }
        pageCount -= 1
        return true
    }

    /// Collapses every page onto page 0 (used when switching back to
    /// `.infinite`, which has no page system). Nothing is lost.
    func mergePagesToSingle() {
        for item in items {
            item.pageIndex = 0
        }
        pageCount = 1
    }

    /// Applies the user's new-board defaults (when enabled in the Canvas
    /// panel) to a freshly created board. Existing boards never change.
    func applyCanvasDefaults() {
        guard CanvasDefaults.isEnabled else { return }
        canvasSize = CanvasDefaults.size
        canvasOrientation = CanvasDefaults.orientation
        canvasColorHex = CanvasDefaults.colorHex
        canvasPattern = CanvasDefaults.pattern
        let custom = CanvasDefaults.customSize
        customWidth = Double(custom.width)
        customHeight = Double(custom.height)
    }
}

/// Deep-copies a board and every visible item for board-list multi-select
/// duplication. Copies start unlocked (like canvas duplicates) and gain
/// " copy" titles; trashed items are left behind, never inherited.
func duplicateBoard(_ source: Board, in context: ModelContext) -> Board {
    let copy = Board(title: "\(source.title) copy")
    copy.canvasSizeRaw = source.canvasSizeRaw
    copy.canvasOrientationRaw = source.canvasOrientationRaw
    copy.canvasColorHex = source.canvasColorHex
    copy.canvasPatternRaw = source.canvasPatternRaw
    copy.customWidth = source.customWidth
    copy.customHeight = source.customHeight
    copy.pageCount = source.pageCount
    context.insert(copy)
    for original in source.items where !original.isTrashed {
        let itemCopy = CanvasItem(kind: original.kind,
                                  shape: original.shape,
                                  strokeStyle: original.strokeStyle,
                                  x: original.x,
                                  y: original.y,
                                  text: original.text,
                                  colorHex: original.colorHex,
                                  lineWidth: original.lineWidth,
                                  points: original.strokePoints,
                                  zIndex: original.zIndex)
        itemCopy.width = original.width
        itemCopy.height = original.height
        itemCopy.fontSize = original.fontSize
        itemCopy.richTextData = original.richTextData
        itemCopy.imageData = original.imageData
        itemCopy.pdfData = original.pdfData
        itemCopy.pdfPage = original.pdfPage
        itemCopy.audioData = original.audioData
        itemCopy.audioFileName = original.audioFileName
        itemCopy.audioDuration = original.audioDuration
        itemCopy.youtubeURL = original.youtubeURL
        itemCopy.videoData = original.videoData
        itemCopy.videoFileName = original.videoFileName
        itemCopy.videoDuration = original.videoDuration
        itemCopy.pageIndex = original.pageIndex
        itemCopy.tableData = original.tableData
        itemCopy.groupID = original.groupID
        // Duplicates start unlocked (see CanvasView.duplicateSelected).
        itemCopy.isLocked = false
        context.insert(itemCopy)
        itemCopy.board = copy
    }
    return copy
}
