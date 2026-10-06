import Testing
import Foundation
import SwiftData
@testable import OpenMind

@Suite struct YouTubeTests {
    @Test func parsesWatchURLs() {
        #expect(youtubeVideoID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(youtubeVideoID(from: "https://youtube.com/watch?v=dQw4w9WgXcQ&t=30s") == "dQw4w9WgXcQ")
        #expect(youtubeVideoID(from: "https://m.youtube.com/watch?v=dQw4w9WgXcQ&feature=share") == "dQw4w9WgXcQ")
    }

    @Test func parsesShortAndEmbedURLs() {
        #expect(youtubeVideoID(from: "https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(youtubeVideoID(from: "https://youtu.be/dQw4w9WgXcQ?t=42") == "dQw4w9WgXcQ")
        #expect(youtubeVideoID(from: "https://www.youtube.com/embed/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(youtubeVideoID(from: "https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(youtubeVideoID(from: "https://www.youtube.com/live/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    }

    @Test func parsesBareIDs() {
        #expect(youtubeVideoID(from: "dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(youtubeVideoID(from: "  dQw4w9WgXcQ  ") == "dQw4w9WgXcQ")
    }

    @Test func rejectsGarbage() {
        #expect(youtubeVideoID(from: "") == nil)
        #expect(youtubeVideoID(from: "   ") == nil)
        #expect(youtubeVideoID(from: "https://example.com/watch?v=dQw4w9WgXcQ") == nil)
        #expect(youtubeVideoID(from: "https://www.youtube.com/watch") == nil)
        #expect(youtubeVideoID(from: "too-short") == nil)
        #expect(youtubeVideoID(from: "not a url at all!!!") == nil)
    }

    @Test func embedAndWatchURLs() {
        let embed = youtubeEmbedURL(for: "dQw4w9WgXcQ")
        #expect(embed?.absoluteString.contains("/embed/dQw4w9WgXcQ") == true)
        #expect(youtubeWatchURL(for: "dQw4w9WgXcQ")?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(youtubeThumbnailURL(for: "dQw4w9WgXcQ")?.absoluteString.contains("dQw4w9WgXcQ") == true)
    }

    @Test func embedRequestCarriesReferer() {
        // Regression test for "Error 153": YouTube rejects referer-less
        // embed loads, and WKWebView attaches none on its own.
        let req = youtubeEmbedRequest(for: "dQw4w9WgXcQ")
        #expect(req?.url?.absoluteString.contains("/embed/dQw4w9WgXcQ") == true)
        #expect(req?.value(forHTTPHeaderField: "Referer") == YouTubeEmbed.referer)
        #expect(YouTubeEmbed.referer.hasPrefix("https://"))
    }

    @Test func youtubeItemDefaults() {
        #expect(ItemKind.youtube.defaultSize.width == 480)
        #expect(!ItemKind.youtube.isTextEditable)
        #expect(ItemKind.youtube.isEditable)
        #expect(!ItemKind.youtube.placeholder.isEmpty)
    }

    @Test func vsomRoundTripsYouTubeURL() throws {
        let container = try ModelContainer(
            for: Board.self, CanvasItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let board = Board(title: "YT")
        context.insert(board)
        let item = CanvasItem(kind: .youtube, x: 10, y: 20)
        item.youtubeURL = "https://youtu.be/dQw4w9WgXcQ"
        context.insert(item)
        item.board = board
        let bytes = try exportBoard(board)
        let copy = try #require(importBoard(from: bytes, fileName: "YT.vsom", context: context))
        let yt = try #require(copy.items.first(where: { $0.kind == .youtube }))
        #expect(yt.youtubeURL == "https://youtu.be/dQw4w9WgXcQ")
        #expect(youtubeVideoID(from: yt.youtubeURL) == "dQw4w9WgXcQ")
    }

    @Test func vsomWithoutYouTubeKeyStillDecodes() throws {
        // Old files predate the YouTube kind: the new field must default.
        let container = try ModelContainer(
            for: Board.self, CanvasItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let board = Board(title: "Old")
        context.insert(board)
        var bytes = try exportBoard(board)
        // Strip the youtubeURL key to simulate a v1 file from before embeds.
        var json = String(decoding: bytes, as: UTF8.self)
        json = json.replacingOccurrences(of: ",\"youtubeURL\":\"\"", with: "")
        bytes = Data(json.utf8)
        let copy = try #require(importBoard(from: bytes, fileName: "Old.vsom", context: context))
        #expect(copy.title == "Old")
    }
}
