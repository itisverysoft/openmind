import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Helpers for `.video` canvas items. Video bytes are stored verbatim
/// (no transcoding) — playback decodes on demand via AVPlayer, with the
/// bytes staged to a temp file (see CanvasVideoTemp).
enum CanvasVideo {
    /// Largest video file accepted on import (bytes). Keeps boards small
    /// and avoids multi-hundred-MB `Data` spikes on import.
    static let maxImportBytes: Int = 200 * 1024 * 1024
}

/// True when `data` looks like a playable video file. Checked by staging to
/// a temp file and asking AVFoundation whether the asset is playable.
func isVideoData(_ data: Data) -> Bool {
    guard !data.isEmpty else { return false }
    guard let url = CanvasVideoTemp.write(data: data, fileName: "probe.mp4") else { return false }
    defer { try? FileManager.default.removeItem(at: url) }
    return AVURLAsset(url: url).isPlayable
}

/// Duration in seconds, or nil when `data` is not playable video.
func videoDuration(_ data: Data?) -> TimeInterval? {
    guard let data, !data.isEmpty else { return nil }
    guard let url = CanvasVideoTemp.write(data: data, fileName: "probe.mp4") else { return nil }
    defer { try? FileManager.default.removeItem(at: url) }
    let duration = AVURLAsset(url: url).duration
    guard duration.isValid, duration.seconds > 0,
          duration.seconds.isFinite else { return nil }
    return duration.seconds
}

/// Reads a video file with security-scoped access when needed (file
/// importer and drag-and-drop file URLs). Returns the bytes plus the
/// display file name. Nil when unreadable, oversized, or not video.
func videoDataFromFileURL(_ url: URL) -> (data: Data, fileName: String)? {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url),
          data.count <= CanvasVideo.maxImportBytes,
          isVideoData(data)
    else { return nil }
    return (data, url.lastPathComponent)
}

/// True when the file extension / UTType looks like video. Used to route
/// imports and drops to the video path before sniffing bytes. Checked
/// before the audio mapping because containers like mp4/mov match both.
func isVideoFileURL(_ url: URL) -> Bool {
    if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
       type.conforms(to: .video) {
        // Audio-only files (mp3, m4a, wav, …) never conform to `.video`,
        // so this branch can't steal the voice-note path.
        return true
    }
    let videoExts = ["mp4", "mov", "m4v", "avi", "mkv", "webm",
                     "mpg", "mpeg", "3gp", "3g2", "ogv"]
    return videoExts.contains(url.pathExtension.lowercased())
}

/// Writes video bytes to a uniquely-named temp file so AVPlayer (URL-based)
/// can play them. Files are cached per content hash and cleaned by the OS.
enum CanvasVideoTemp {
    static func write(data: Data, fileName: String) -> URL? {
        let ext = videoExtension(for: fileName)
        let hashed = "openmind-video-\(stableHash(data))-\(sanitized(fileName))\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(hashed)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func sanitized(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = base.unicodeScalars.filter { allowed.contains($0) }.map(Character.init).reduce("") { $0 + String($1) }
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(32)).replacingOccurrences(of: " ", with: "-")
    }

    private static func videoExtension(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let known = ["mp4", "mov", "m4v", "avi", "mkv", "webm",
                     "mpg", "mpeg", "3gp", "3g2", "ogv"]
        if known.contains(ext) { return ".\(ext)" }
        return ".mp4"
    }

    private static func stableHash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data.prefix(1_000_000) {
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        h ^= UInt64(data.count)
        return String(format: "%016llx", h)
    }
}
