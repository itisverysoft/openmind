import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// `.vsom` — the OpenMind board file. A versioned JSON document holding the
/// board's settings plus every visible item, with media bytes (images,
/// PDFs, audio) embedded base64 via `Data`'s Codable support. Trashed items
/// are never exported; locks, pages, and stacking order survive the trip.
///
/// v1 is the first and only revision. Decoders reject unknown versions so a
/// newer file fails loudly instead of importing half-understood content.
enum VSOM {
    static let formatID = "openmind-board"
    static let version = 1
    static let fileExtension = "vsom"
    static let typeIdentifier = "com.openmind.board"
    static let mimeType = "application/vnd.openmind.board"
}

extension UTType {
    /// The `.vsom` board type. Resolves to the exported declaration (see
    /// Info.plist) when present, otherwise a dynamic type keyed off the
    /// extension — either way the panels filter and name files correctly.
    static var vsomBoard: UTType {
        UTType(filenameExtension: VSOM.fileExtension, conformingTo: .json) ?? .data
    }
}

enum VSOMError: Error, Equatable {
    case notABoardFile
    case unsupportedVersion(Int)
    case corrupt(String)
}

/// Versioned on-disk form of one board. Field-for-field with `Board` /
/// `CanvasItem` storage (raw strings and opaque `Data` blobs), so future
/// app versions read old files by falling back exactly like the models do.
struct VSOMDocument: Codable {
    var format: String
    var version: Int
    var board: VSOMBoard
    var items: [VSOMItem]
}

struct VSOMBoard: Codable {
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var canvasSizeRaw: String
    var canvasOrientationRaw: String
    var canvasColorHex: String
    var canvasPatternRaw: String
    var customWidth: Double
    var customHeight: Double
    var pageCount: Int
}

struct VSOMItem: Codable {
    var kindRaw: String
    var shapeRaw: String
    var strokeStyleRaw: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var pageIndex: Int
    var text: String
    var colorHex: String
    var fontSize: Double
    var pointsData: Data
    var lineWidth: Double
    var richTextData: Data
    var imageData: Data?
    var pdfData: Data?
    var pdfPage: Int
    var audioData: Data?
    var audioFileName: String
    var audioDuration: Double
    var youtubeURL: String = ""
    var videoData: Data?
    var videoFileName: String = ""
    var videoDuration: Double = 0
    var tableData: Data
    var zIndex: Double
    var isLocked: Bool
}

/// Serializes `board` (visible items only) to `.vsom` file bytes.
func exportBoard(_ board: Board) throws -> Data {
    let doc = VSOMDocument(
        format: VSOM.formatID,
        version: VSOM.version,
        board: VSOMBoard(
            title: board.title,
            createdAt: board.createdAt,
            modifiedAt: board.modifiedAt,
            canvasSizeRaw: board.canvasSizeRaw,
            canvasOrientationRaw: board.canvasOrientationRaw,
            canvasColorHex: board.canvasColorHex,
            canvasPatternRaw: board.canvasPatternRaw,
            customWidth: board.customWidth,
            customHeight: board.customHeight,
            pageCount: board.pageCount
        ),
        items: board.items.filter { !$0.isTrashed }.map { item in
            VSOMItem(
                kindRaw: item.kindRaw,
                shapeRaw: item.shapeRaw,
                strokeStyleRaw: item.strokeStyleRaw,
                x: item.x, y: item.y,
                width: item.width, height: item.height,
                pageIndex: item.pageIndex,
                text: item.text,
                colorHex: item.colorHex,
                fontSize: item.fontSize,
                pointsData: item.pointsData,
                lineWidth: item.lineWidth,
                richTextData: item.richTextData,
                imageData: item.imageData,
                pdfData: item.pdfData,
                pdfPage: item.pdfPage,
                audioData: item.audioData,
                audioFileName: item.audioFileName,
                audioDuration: item.audioDuration,
                youtubeURL: item.youtubeURL,
                videoData: item.videoData,
                videoFileName: item.videoFileName,
                videoDuration: item.videoDuration,
                tableData: item.tableData,
                zIndex: item.zIndex,
                isLocked: item.isLocked
            )
        }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(doc)
}

/// Decodes and validates `.vsom` bytes. Throws `VSOMError` for anything
/// that isn't a supported board file.
func decodeVSOM(_ data: Data) throws -> VSOMDocument {
    let doc: VSOMDocument
    do {
        doc = try JSONDecoder().decode(VSOMDocument.self, from: data)
    } catch {
        throw VSOMError.notABoardFile
    }
    guard doc.format == VSOM.formatID else { throw VSOMError.notABoardFile }
    guard doc.version == VSOM.version else { throw VSOMError.unsupportedVersion(doc.version) }
    return doc
}

/// Materializes a decoded document as a new board with fresh identities.
/// Faithful copy: locks, pages, and stacking are preserved (unlike
/// board-duplication, which unlocks). Returns nil only for invalid files.
func importVSOMDocument(_ doc: VSOMDocument, fileName: String, context: ModelContext) -> Board {
    let boardTitle = doc.board.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let board = Board(title: boardTitle.isEmpty
                      ? (fileName as NSString).deletingPathExtension
                      : boardTitle)
    board.createdAt = doc.board.createdAt
    board.modifiedAt = .now
    board.canvasSizeRaw = doc.board.canvasSizeRaw
    board.canvasOrientationRaw = doc.board.canvasOrientationRaw
    board.canvasColorHex = doc.board.canvasColorHex
    board.canvasPatternRaw = doc.board.canvasPatternRaw
    board.customWidth = doc.board.customWidth
    board.customHeight = doc.board.customHeight
    board.pageCount = max(1, doc.board.pageCount)
    context.insert(board)
    for src in doc.items {
        let item = CanvasItem(kind: ItemKind(rawValue: src.kindRaw) ?? .sticky,
                              x: src.x, y: src.y,
                              text: src.text,
                              zIndex: src.zIndex)
        item.shapeRaw = src.shapeRaw
        item.strokeStyleRaw = src.strokeStyleRaw
        item.width = src.width
        item.height = src.height
        item.pageIndex = src.pageIndex
        item.colorHex = src.colorHex
        item.fontSize = src.fontSize
        item.pointsData = src.pointsData
        item.lineWidth = src.lineWidth
        item.richTextData = src.richTextData
        item.imageData = src.imageData
        item.pdfData = src.pdfData
        item.pdfPage = src.pdfPage
        item.audioData = src.audioData
        item.audioFileName = src.audioFileName
        item.audioDuration = src.audioDuration
        item.youtubeURL = src.youtubeURL
        item.videoData = src.videoData
        item.videoFileName = src.videoFileName
        item.videoDuration = src.videoDuration
        item.tableData = src.tableData
        item.isLocked = src.isLocked
        item.ensureTable()
        context.insert(item)
        item.board = board
    }
    return board
}

/// Convenience: decode + import in one step. Nil for anything that isn't a
/// supported `.vsom` file.
func importBoard(from data: Data, fileName: String, context: ModelContext) -> Board? {
    guard let doc = try? decodeVSOM(data) else { return nil }
    return importVSOMDocument(doc, fileName: fileName, context: context)
}

/// Reads a `.vsom` file with security-scoped access when needed (file
/// importer, drag-and-drop, open-URL). Nil when unreadable.
func vsomDataFromFileURL(_ url: URL) -> Data? {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    return try? Data(contentsOf: url)
}

/// Save-panel default: the board title sanitized to a legal file name.
/// Falls back to "Untitled Board" for blank titles.
func vsomDefaultFilename(title: String) -> String {
    var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty { base = "Untitled Board" }
    for ch in ["/", ":", "\0"] {
        base = base.replacingOccurrences(of: ch, with: "-")
    }
    if base.lowercased().hasSuffix(".\(VSOM.fileExtension)") { return base }
    let stripped = (base as NSString).deletingPathExtension
    return "\((stripped.isEmpty ? base : stripped)).\(VSOM.fileExtension)"
}

/// `FileDocument` wrapper for `.fileExporter`. The document is built up
/// front (export is an in-memory JSON encode), so export never fails late.
struct VSOMFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.vsomBoard] }
    static var writableContentTypes: [UTType] { [.vsomBoard] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw VSOMError.corrupt("Empty file wrapper.")
        }
        // Validate on the way in so a bad file can't masquerade as a board.
        _ = try decodeVSOM(data)
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
