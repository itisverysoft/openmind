import Testing
import Foundation
import SwiftData
@testable import OpenMind

/// `.vsom` export/import: a board serializes to versioned JSON and comes
/// back field-for-field (settings, pages, stacking, locks, media bytes)
/// with fresh identities and trash left behind.
/// (No @MainActor — see PDFBoardImportTests for why.)
@Suite(.serialized)
struct BoardExportTests {

    private func freshContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Board.self, CanvasItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func stockedBoard(in context: ModelContext) -> Board {
        let board = Board(title: "Export Me")
        board.canvasSize = .A4
        board.canvasColorHex = "FFF6D9"
        board.canvasPattern = .grid
        board.customWidth = 500
        board.customHeight = 700
        board.pageCount = 2
        context.insert(board)

        let sticky = CanvasItem(kind: .sticky, x: 10, y: 20, text: "hi")
        sticky.pageIndex = 1
        sticky.zIndex = 3
        context.insert(sticky)
        sticky.board = board

        let locked = CanvasItem(kind: .text, x: 30, y: 40, text: "locked")
        locked.isLocked = true
        locked.richTextData = Data([1, 2, 3])
        context.insert(locked)
        locked.board = board

        let stroke = CanvasItem(kind: .drawing, x: 0, y: 0,
                                points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
                                zIndex: 5)
        context.insert(stroke)
        stroke.board = board

        let table = CanvasItem(kind: .table, x: 50, y: 60)
        table.setTable(TableContent.makeDefault())
        context.insert(table)
        table.board = board

        let image = CanvasItem(kind: .image, x: 70, y: 80)
        image.imageData = Data([0x89, 0x50, 0x4E, 0x47])
        context.insert(image)
        image.board = board

        let pdf = CanvasItem(kind: .pdf, x: 90, y: 100)
        pdf.pdfData = makeTestPDF(pages: 2)
        pdf.pdfPage = 1
        context.insert(pdf)
        pdf.board = board

        let audio = CanvasItem(kind: .audio, x: 110, y: 120)
        audio.audioData = makeTestWAV(seconds: 0.5)
        audio.audioFileName = "note.m4a"
        audio.audioDuration = 0.5
        context.insert(audio)
        audio.board = board

        let trash = CanvasItem(kind: .sticky, x: 0, y: 0, text: "trashed")
        trash.isTrashed = true
        context.insert(trash)
        trash.board = board

        return board
    }

    @Test func roundTripPreservesEverything() throws {
        let source = stockedBoard(in: try freshContext())
        let bytes = try exportBoard(source)

        let context = try freshContext()
        let copy = try #require(importBoard(from: bytes, fileName: "Export Me.vsom", context: context))

        // Board settings survive; the import gets a fresh identity.
        #expect(copy.id != source.id)
        #expect(copy.title == "Export Me")
        #expect(copy.canvasSize == .A4)
        #expect(copy.canvasColorHex == "FFF6D9")
        #expect(copy.canvasPattern == .grid)
        #expect(copy.pageCount == 2)
        #expect(copy.customWidth == 500)

        // Trash is left behind, never exported.
        #expect(copy.items.count == 7)
        #expect(copy.items.allSatisfy { !$0.isTrashed })

        let sticky = try #require(copy.items.first(where: { $0.kind == .sticky }))
        #expect(sticky.text == "hi")
        #expect(sticky.pageIndex == 1)
        #expect(sticky.zIndex == 3)

        let locked = try #require(copy.items.first(where: { $0.kind == .text }))
        #expect(locked.isLocked)
        #expect(locked.richTextData == Data([1, 2, 3]))

        let stroke = try #require(copy.items.first(where: { $0.kind == .drawing }))
        #expect(stroke.strokePoints == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])

        let table = try #require(copy.items.first(where: { $0.kind == .table }))
        #expect(table.getTable().rows == 3)

        let image = try #require(copy.items.first(where: { $0.kind == .image }))
        #expect(image.imageData == Data([0x89, 0x50, 0x4E, 0x47]))

        let pdf = try #require(copy.items.first(where: { $0.kind == .pdf }))
        #expect(pdf.pdfCount == 2)
        #expect(pdf.pdfPage == 1)

        let audio = try #require(copy.items.first(where: { $0.kind == .audio }))
        #expect(audio.audioData == makeTestWAV(seconds: 0.5))
        #expect(audio.audioFileName == "note.m4a")
        #expect(audio.audioDuration == 0.5)

        // Every item has a fresh identity.
        let sourceIDs = Set(source.items.map(\.id))
        #expect(copy.items.allSatisfy { !sourceIDs.contains($0.id) })
    }

    @Test func garbageIsNotABoardFile() throws {
        let context = try freshContext()
        #expect(importBoard(from: Data(), fileName: "x.vsom", context: context) == nil)
        #expect(importBoard(from: Data("nope".utf8), fileName: "x.vsom", context: context) == nil)
    }

    @Test func decodeRejectsWrongFormatAndVersion() throws {
        #expect(throws: VSOMError.notABoardFile) {
            try decodeVSOM(Data("{\"format\":\"nope\",\"version\":1}".utf8))
        }
        // Well-formed JSON with the wrong shape is still not a board file.
        #expect(throws: VSOMError.notABoardFile) {
            try decodeVSOM(Data("{\"a\":1}".utf8))
        }
        // A newer revision decodes structurally but is refused by version.
        let context = try freshContext()
        let board = Board(title: "v1")
        context.insert(board)
        let v1 = String(decoding: try exportBoard(board), as: UTF8.self)
            .replacingOccurrences(of: "\"version\":1", with: "\"version\":999")
        #expect(throws: VSOMError.unsupportedVersion(999)) {
            try decodeVSOM(Data(v1.utf8))
        }
    }

    @Test func blankTitleFallsBackToFileName() throws {
        let context = try freshContext()
        let board = Board(title: "   ")
        context.insert(board)
        let bytes = try exportBoard(board)
        let copy = try #require(importBoard(from: bytes, fileName: "Lecture Notes.vsom", context: context))
        #expect(copy.title == "Lecture Notes")
    }

    @Test func exportFilenameRules() {
        #expect(vsomDefaultFilename(title: "Lecture Notes") == "Lecture Notes.vsom")
        #expect(vsomDefaultFilename(title: "  ") == "Untitled Board.vsom")
        #expect(vsomDefaultFilename(title: "a/b:c") == "a-b-c.vsom")
        #expect(vsomDefaultFilename(title: "Done.vsom") == "Done.vsom")
    }
}
