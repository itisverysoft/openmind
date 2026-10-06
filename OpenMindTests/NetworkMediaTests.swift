import Testing
import Foundation
@testable import OpenMind

@Suite struct NetworkMediaTests {
    @Test func normalizesBareHost() {
        #expect(normalizeNetworkURL("example.com/cat.png")?.absoluteString == "https://example.com/cat.png")
        #expect(normalizeNetworkURL("  https://example.com/a.mp3  ")?.absoluteString == "https://example.com/a.mp3")
        #expect(normalizeNetworkURL("http://example.com/v.mp4")?.scheme == "http")
    }

    @Test func rejectsNonHTTP() {
        #expect(normalizeNetworkURL("") == nil)
        #expect(normalizeNetworkURL("   ") == nil)
        #expect(normalizeNetworkURL("ftp://example.com/a.png") == nil)
        #expect(normalizeNetworkURL("just some words") == nil)
        #expect(normalizeNetworkURL("/tmp/photo.png") == nil)
    }

    @Test func remoteCheck() {
        #expect(isRemoteNetworkURL(URL(string: "https://example.com/a.png")!))
        #expect(isRemoteNetworkURL(URL(string: "http://example.com/a.mp3")!))
        #expect(!isRemoteNetworkURL(URL(fileURLWithPath: "/tmp/a.png")))
    }

    @Test func kindHintFromExtension() {
        #expect(networkMediaKindHint(for: URL(string: "https://x.com/a.png")!) == .image)
        #expect(networkMediaKindHint(for: URL(string: "https://x.com/a.JPG")!) == .image)
        #expect(networkMediaKindHint(for: URL(string: "https://x.com/a.mp3")!) == .audio)
        #expect(networkMediaKindHint(for: URL(string: "https://x.com/a.wav")!) == .audio)
        #expect(networkMediaKindHint(for: URL(string: "https://x.com/a.mp4")!) == .video)
        #expect(networkMediaKindHint(for: URL(string: "https://x.com/a")!) == nil)
    }

    @Test func kindHintFromMIME() {
        #expect(networkMediaKindHint(for: URL(string: "https://x.com/download")!, mimeType: "image/jpeg") == .image)
        #expect(networkMediaKindHint(for: URL(string: "https://x.com/download")!, mimeType: "audio/mpeg") == .audio)
        #expect(networkMediaKindHint(for: URL(string: "https://x.com/download")!, mimeType: "video/mp4") == .video)
    }

    @Test func fileNamePrefersPathComponent() {
        let url = URL(string: "https://example.com/files/cat%20photo.png?dl=1")!
        #expect(networkFileName(from: url, response: nil) == "cat photo.png")
    }

    @Test func errorMessagesAreHelpful() {
        #expect(NetworkMediaError.invalidURL.errorDescription?.contains("http") == true)
        #expect(NetworkMediaError.unsupportedType.errorDescription?.contains("image") == true)
        #expect(NetworkMediaError.tooLarge(100 * 1024 * 1024).errorDescription?.contains("100") == true)
    }
}
