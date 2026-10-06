import Foundation

/// Helpers for attaching network (http/https) image, audio, and video to the
/// canvas. Bytes are downloaded verbatim and routed through the same
/// `addImageItem` / `addAudioItem` / `addVideoItem` paths as local imports,
/// so storage, validation, and playback stay identical — only the source
/// differs (URL download instead of file picker / drop / paste).
enum NetworkMedia {
    /// Largest single download accepted (bytes). Matches the video cap so
    /// one limit covers image + audio + video; per-kind caps are enforced
    /// again in `fetchNetworkMedia` via `CanvasAudio` / `CanvasVideo`.
    static let maxDownloadBytes: Int = 200 * 1024 * 1024
    /// Network timeout for the whole resource fetch.
    static let timeout: TimeInterval = 60
}

/// Failures surfaced in the From-URL sheet / drop path.
enum NetworkMediaError: LocalizedError, Equatable {
    case invalidURL
    case downloadFailed(String)
    case tooLarge(Int)
    case unsupportedType

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn't look like a valid http(s) link."
        case .downloadFailed(let detail):
            return detail.isEmpty ? "Couldn't download that link." : detail
        case .tooLarge(let limit):
            return "That file is too large (limit \(limit / 1_048_576) MB)."
        case .unsupportedType:
            return "Couldn't use that link — it isn't an image, audio, or video file."
        }
    }
}

/// Normalizes user-typed input into an http(s) URL. Tolerates missing
/// schemes ("example.com/cat.png" → "https://example.com/cat.png") and
/// surrounding whitespace. Nil for anything that isn't http/https
/// (file paths, ftp, bare words, empty input).
func normalizeNetworkURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // Reject obvious non-URLs early (no dot, no slash, contains spaces).
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty
    else { return nil }
    return url
}

/// True for remote http(s) URLs (not local file URLs).
func isRemoteNetworkURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
}

/// Display file name for a download: Content-Disposition filename wins,
/// otherwise the URL's last path component, otherwise a kind-based default.
func networkFileName(from url: URL, response: URLResponse?, defaultName: String = "file") -> String {
    if let http = response as? HTTPURLResponse,
       let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
       let name = contentDispositionFileName(disposition),
       !name.isEmpty {
        return name
    }
    let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if !last.isEmpty, last != "/" {
        // Strip query noise that sometimes sticks to pasted links.
        var clean = last
        for sep in ["?", "#"] {
            if let i = clean.firstIndex(of: Character(sep)) {
                clean = String(clean[..<i])
            }
        }
        if !clean.isEmpty { return clean }
    }
    return defaultName
}

/// Extracts `filename=` / `filename*=` from a Content-Disposition header.
func contentDispositionFileName(_ header: String) -> String? {
    // filename*=UTF-8''cat%20photo.png (RFC 5987)
    if let range = header.range(of: "filename*=", options: .caseInsensitive) {
        var value = String(header[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote = value.firstIndex(of: ";") { value = String(value[..<quote]) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        // Strip charset prefix: UTF-8''name
        if let ticks = value.range(of: "''") {
            value = String(value[ticks.upperBound...])
        }
        let decoded = value.removingPercentEncoding ?? value
        if !decoded.isEmpty { return decoded }
    }
    if let range = header.range(of: "filename=", options: .caseInsensitive) {
        var value = String(header[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let semi = value.firstIndex(of: ";") { value = String(value[..<semi]) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        if !value.isEmpty { return value }
    }
    return nil
}

/// Extension-based hint for the URL prompt (no byte sniffing). Used only for
/// the "Looks like …" label — the real decision happens after download in
/// `classifyNetworkMedia(data:url:mimeType:)`.
func networkMediaKindHint(for url: URL, mimeType: String? = nil) -> ItemKind? {
    if let mime = mimeType?.lowercased() {
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
    }
    let ext = url.pathExtension.lowercased()
    if ext.isEmpty { return nil }
    // Video first: mp4/mov match both the audio and video mappings.
    if isVideoFileURL(URL(fileURLWithPath: "x.\(ext)")) { return .video }
    if isAudioFileURL(URL(fileURLWithPath: "x.\(ext)")) { return .audio }
    let imageExts = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif",
                     "bmp", "webp", "svg", "ico", "avif", "jfif", "pjpeg", "pjp"]
    if imageExts.contains(ext) { return .image }
    return nil
}

/// Decides which canvas kind downloaded bytes belong to. MIME/extension
/// route first (cheap, exact); otherwise sniff bytes — image via ImageIO,
/// then video-before-audio mirroring the drop path (mp4/mov satisfy both).
func classifyNetworkMedia(data: Data, url: URL, mimeType: String?) -> ItemKind? {
    guard !data.isEmpty else { return nil }
    // Exact MIME routing.
    if let mime = mimeType?.lowercased().split(separator: ";").first.map(String.init) {
        let m = mime.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.hasPrefix("image/") { return isImageData(data) ? .image : nil }
        if m.hasPrefix("video/") { return isVideoData(data) ? .video : nil }
        if m.hasPrefix("audio/") { return isAudioData(data) ? .audio : nil }
    }
    // Extension routing.
    let ext = url.pathExtension.lowercased()
    if !ext.isEmpty {
        if isVideoFileURL(URL(fileURLWithPath: "x.\(ext)")) {
            if isVideoData(data) { return .video }
            // Fall through: mislabeled extension, try the sniffers below.
        } else if isAudioFileURL(URL(fileURLWithPath: "x.\(ext)")) {
            if isAudioData(data) { return .audio }
        } else {
            if isImageData(data) { return .image }
            return nil
        }
    }
    // No (or misleading) extension: sniff everything, image first.
    if isImageData(data) { return .image }
    if isVideoData(data) { return .video }
    if isAudioData(data) { return .audio }
    return nil
}

/// Downloads a remote resource, enforcing http(s), HTTP success, and the
/// size cap. Returns the bytes plus the response for filename/MIME use.
func downloadNetworkData(from url: URL) async throws -> (Data, URLResponse) {
    guard isRemoteNetworkURL(url) else { throw NetworkMediaError.invalidURL }
    var request = URLRequest(url: url, timeoutInterval: NetworkMedia.timeout)
    request.setValue("Mozilla/5.0 (OpenMind)", forHTTPHeaderField: "User-Agent")
    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch {
        throw NetworkMediaError.downloadFailed("Couldn't download that link (\(error.localizedDescription)).")
    }
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw NetworkMediaError.downloadFailed("The server returned status \(http.statusCode).")
    }
    guard !data.isEmpty else {
        throw NetworkMediaError.downloadFailed("The download was empty.")
    }
    guard data.count <= NetworkMedia.maxDownloadBytes else {
        throw NetworkMediaError.tooLarge(NetworkMedia.maxDownloadBytes)
    }
    return (data, response)
}

/// High-level fetch: normalize → download → per-kind size check → classify.
/// Returns the kind, bytes, and display file name for the tile.
func fetchNetworkMedia(from raw: String) async throws -> (kind: ItemKind, data: Data, fileName: String) {
    guard let url = normalizeNetworkURL(raw) else {
        throw NetworkMediaError.invalidURL
    }
    let (data, response) = try await downloadNetworkData(from: url)
    let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        ?? response.mimeType
    guard let kind = classifyNetworkMedia(data: data, url: url, mimeType: mime) else {
        throw NetworkMediaError.unsupportedType
    }
    switch kind {
    case .audio where data.count > CanvasAudio.maxImportBytes:
        throw NetworkMediaError.tooLarge(CanvasAudio.maxImportBytes)
    case .video where data.count > CanvasVideo.maxImportBytes:
        throw NetworkMediaError.tooLarge(CanvasVideo.maxImportBytes)
    default:
        break
    }
    let fallback = kind == .image ? "image" : (kind == .audio ? "audio" : "video")
    let name = networkFileName(from: url, response: response, defaultName: fallback)
    return (kind, data, name)
}
