import Testing
import Foundation
import SwiftData
@testable import OpenMind

@Suite struct VideoTests {
    @Test func videoItemDefaults() {
        #expect(ItemKind.video.defaultSize.width == 480)
        #expect(!ItemKind.video.isTextEditable)
        #expect(!ItemKind.video.isEditable)
        #expect(!ItemKind.video.placeholder.isEmpty)
    }

    @Test func garbageIsNotVideo() {
        #expect(!isVideoData(Data()))
        #expect(!isVideoData(Data("nope".utf8)))
        #expect(videoDuration(Data("nope".utf8)) == nil)
        #expect(videoDuration(nil) == nil)
    }

    @Test func videoFileRouting() {
        #expect(isVideoFileURL(URL(fileURLWithPath: "/tmp/clip.mp4")))
        #expect(isVideoFileURL(URL(fileURLWithPath: "/tmp/clip.mov")))
        #expect(isVideoFileURL(URL(fileURLWithPath: "/tmp/clip.MKV")))
        #expect(!isVideoFileURL(URL(fileURLWithPath: "/tmp/note.mp3")))
        #expect(!isVideoFileURL(URL(fileURLWithPath: "/tmp/note.m4a")))
        #expect(!isVideoFileURL(URL(fileURLWithPath: "/tmp/photo.png")))
        #expect(!isVideoFileURL(URL(fileURLWithPath: "/tmp/doc.txt")))
    }

    @Test func vsomRoundTripsVideoFields() throws {
        let container = try ModelContainer(
            for: Board.self, CanvasItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let board = Board(title: "Vid")
        context.insert(board)
        // Bytes are stored verbatim: any payload round-trips, so plain
        // bytes stand in for real video data here (decoding is AV-side).
        let item = CanvasItem(kind: .video, x: 10, y: 20)
        item.videoData = Data([1, 2, 3, 4])
        item.videoFileName = "clip.mp4"
        item.videoDuration = 12.5
        context.insert(item)
        item.board = board
        let bytes = try exportBoard(board)
        let copy = try #require(importBoard(from: bytes, fileName: "Vid.vsom", context: context))
        let video = try #require(copy.items.first(where: { $0.kind == .video }))
        #expect(video.videoData == Data([1, 2, 3, 4]))
        #expect(video.videoFileName == "clip.mp4")
        #expect(video.videoDuration == 12.5)
    }

    @Test func vsomWithoutVideoKeysStillDecodes() throws {
        // Files from before local video existed lack the new keys entirely.
        let container = try ModelContainer(
            for: Board.self, CanvasItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let board = Board(title: "Old")
        context.insert(board)
        var json = String(decoding: try exportBoard(board), as: UTF8.self)
        json = json.replacingOccurrences(of: ",\"videoData\":null", with: "")
        json = json.replacingOccurrences(of: ",\"videoFileName\":\"\"", with: "")
        json = json.replacingOccurrences(of: ",\"videoDuration\":0", with: "")
        let copy = try #require(importBoard(from: Data(json.utf8), fileName: "Old.vsom", context: context))
        #expect(copy.title == "Old")
    }
}
