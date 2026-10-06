import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Helpers for `.audio` canvas items. Audio bytes are stored verbatim
/// (no transcoding) — playback decodes on demand via AVPlayer.
enum CanvasAudio {
    /// Largest audio file accepted on import (bytes). Keeps boards small.
    static let maxImportBytes: Int = 100 * 1024 * 1024
}

/// True when `data` looks like a playable audio file. Checked with
/// AVAudioPlayer (fast, local decode) before falling back to the asset's
/// synchronous `isPlayable` flag for formats AVAudioPlayer rejects.
func isAudioData(_ data: Data) -> Bool {
    guard !data.isEmpty else { return false }
    if (try? AVAudioPlayer(data: data)) != nil { return true }
    // Fallback for formats AVAudioPlayer rejects but AVPlayer handles:
    // write to a temp file and ask AVFoundation whether it is playable.
    let url = CanvasAudioTemp.write(data: data, fileName: "probe")
    defer { if let url { try? FileManager.default.removeItem(at: url) } }
    guard let url else { return false }
    return AVURLAsset(url: url).isPlayable
}

/// Duration in seconds, or nil when `data` is not playable audio.
func audioDuration(_ data: Data?) -> TimeInterval? {
    guard let data, !data.isEmpty else { return nil }
    if let player = try? AVAudioPlayer(data: data), player.duration > 0 {
        return player.duration
    }
    let url = CanvasAudioTemp.write(data: data, fileName: "probe")
    defer { if let url { try? FileManager.default.removeItem(at: url) } }
    guard let url else { return nil }
    let duration = AVURLAsset(url: url).duration
    guard duration.isValid, duration.seconds > 0,
          duration.seconds.isFinite else { return nil }
    return duration.seconds
}

/// Reads an audio file with security-scoped access when needed (file
/// importer and drag-and-drop file URLs). Returns the bytes plus the
/// display file name. Nil when unreadable, oversized, or not audio.
func audioDataFromFileURL(_ url: URL) -> (data: Data, fileName: String)? {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url),
          data.count <= CanvasAudio.maxImportBytes,
          isAudioData(data)
    else { return nil }
    return (data, url.lastPathComponent)
}

/// "m:ss" formatting for the player tile (e.g. 0:07, 12:34, 1:02:03).
func formatAudioDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

/// The voice tile the space key should resume/pause: the lone selection
/// when it is an audio item and nothing is being typed in. Nil otherwise —
/// space keeps its normal meaning (text input, button activation, …).
func spaceToggleAudioTarget(selectedItems: [CanvasItem], isEditing: Bool) -> CanvasItem? {
    guard !isEditing, selectedItems.count == 1,
          let item = selectedItems.first, item.kind == .audio
    else { return nil }
    return item
}

/// True when the file extension / UTType looks like audio. Used to route
/// drops to the audio path before sniffing bytes.
func isAudioFileURL(_ url: URL) -> Bool {
    if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
       type.conforms(to: .audio) {
        return true
    }
    let audioExts = ["mp3", "m4a", "wav", "aiff", "aif", "caf", "aac", "ogg", "flac", "opus", "mp4", "mov"]
    return audioExts.contains(url.pathExtension.lowercased())
}

/// Writes audio bytes to a uniquely-named temp file so AVPlayer (URL-based)
/// can play them. Files are cached per content hash and cleaned by the OS.
enum CanvasAudioTemp {
    static func write(data: Data, fileName: String) -> URL? {
        let ext = audioExtension(for: fileName, data: data)
        let hashed = "openmind-audio-\(stableHash(data))-\(sanitized(fileName))\(ext)"
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

    private static func audioExtension(for fileName: String, data: Data) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty, isAudioFileURL(URL(fileURLWithPath: "x.\(ext)")) || !ext.contains("/") {
            return ".\(ext)"
        }
        return ".m4a"
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
