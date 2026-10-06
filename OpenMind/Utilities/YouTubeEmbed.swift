import Foundation
import CoreGraphics

/// Helpers for `.youtube` canvas items. Only the raw URL the user typed is
/// stored (`CanvasItem.youtubeURL`); the 11-char video ID is derived on
/// demand so edits can never desync the two.
enum YouTubeEmbed {
    /// Fixed 16:9 player aspect (480×270 default tile).
    static let aspect: CGFloat = 16.0 / 9.0
    /// Referer sent with embed loads. Since mid-2025 YouTube requires
    /// embedded players to arrive with a valid top-level browsing context
    /// (an HTTP `Referer` header); `WKWebView.load(_:)` attaches none to a
    /// plain `URLRequest`, which YouTube rejects with "Error 153".
    static let referer = "https://openmind.canvas/"
}

/// Extracts the 11-char YouTube video ID from the usual URL shapes, or from
/// a bare ID pasted on its own. Nil when nothing looks like a video.
///
/// Accepted:
/// - `https://www.youtube.com/watch?v=ID` (any subdomain, extra params ok)
/// - `https://youtu.be/ID` (extra params ok)
/// - `https://www.youtube.com/embed/ID`, `/shorts/ID`, `/live/ID`, `/v/ID`
/// - bare `ID` (11 chars of `[A-Za-z0-9_-]`)
func youtubeVideoID(from raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if isBareYouTubeID(trimmed) { return trimmed }
    // Tolerate URLs pasted without a scheme ("youtube.com/watch?v=…").
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate),
          let host = url.host?.lowercased()
    else { return nil }
    // Short links: youtu.be/ID
    if host == "youtu.be" || host.hasSuffix(".youtu.be") {
        let id = url.pathComponents.dropFirst().first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clean = stripYouTubeIDNoise(id)
        return isBareYouTubeID(clean) ? clean : nil
    }
    guard host.contains("youtube.com") || host.contains("youtube-nocookie.com") else {
        return nil
    }
    // watch?v=ID (also /watch/…, extra params, fragments like &t=30s)
    if let components = URLComponents(string: candidate),
       let queryID = components.queryItems?.first(where: { $0.name == "v" })?.value {
        let clean = stripYouTubeIDNoise(queryID)
        if isBareYouTubeID(clean) { return clean }
    }
    // Path styles: /embed/ID, /shorts/ID, /live/ID, /v/ID
    let parts = url.pathComponents.filter { $0 != "/" }
    if parts.count >= 2,
       ["embed", "shorts", "live", "v"].contains(parts[parts.count - 2].lowercased()) {
        let clean = stripYouTubeIDNoise(parts.last ?? "")
        if isBareYouTubeID(clean) { return clean }
    }
    return nil
}

/// True for an 11-char YouTube video ID (`[A-Za-z0-9_-]{11}`).
func isBareYouTubeID(_ s: String) -> Bool {
    guard s.count == 11 else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return s.unicodeScalars.allSatisfy { allowed.contains($0) }
}

/// Strips query/fragment noise that sometimes sticks to a pasted ID.
private func stripYouTubeIDNoise(_ s: String) -> String {
    var clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
    for sep in ["?", "#", "&", "/"] {
        if let i = clean.firstIndex(of: Character(sep)) {
            clean = String(clean[..<i])
        }
    }
    return clean
}

/// Embed URL for an ID. Uses the regular `youtube.com` host (not the
/// `nocookie` variant): YouTube rejects nocookie embeds loaded from a
/// `WKWebView` with "Error 153", and likewise rejects any embed wrapped in
/// `loadHTMLString(_:baseURL:)` with a nil/`about:blank` origin — so the
/// tile loads this URL directly via `URLRequest` for a real https origin.
func youtubeEmbedURL(for videoID: String, autoplay: Bool = false) -> URL? {
    var comps = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")
    var items = [
        URLQueryItem(name: "rel", value: "0"),
        URLQueryItem(name: "playsinline", value: "1"),
    ]
    if autoplay { items.append(URLQueryItem(name: "autoplay", value: "1")) }
    comps?.queryItems = items
    return comps?.url
}

/// `URLRequest` for loading an embed in a `WKWebView`. Carries the `Referer`
/// header YouTube requires (see `YouTubeEmbed.referer`): without it the
/// player renders "Error 153". The header rides the top-level navigation,
/// which is the request YouTube checks; the player's own sub-requests then
/// inherit the embed page as their referrer.
func youtubeEmbedRequest(for videoID: String, autoplay: Bool = false) -> URLRequest? {
    guard let url = youtubeEmbedURL(for: videoID, autoplay: autoplay) else { return nil }
    var request = URLRequest(url: url)
    request.setValue(YouTubeEmbed.referer, forHTTPHeaderField: "Referer")
    return request
}

/// Public watch URL (Open in browser / SVG export link).
func youtubeWatchURL(for videoID: String) -> URL? {
    URL(string: "https://www.youtube.com/watch?v=\(videoID)")
}

/// Thumbnail used for the facade preview (and docs): `hqdefault` always
/// exists, even when higher resolutions don't.
func youtubeThumbnailURL(for videoID: String) -> URL? {
    URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
}
