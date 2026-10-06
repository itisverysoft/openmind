import SwiftUI
import AVFoundation
import Combine

/// Player tile for `.audio` items: file name, play/pause, tap-to-seek
/// progress bar, and elapsed/total times. Playback is URL-based (AVPlayer)
/// with the bytes staged to a temp file (see CanvasAudioTemp).
///
/// Interaction note: seeking is tap-based (not a drag Slider) so scrubbing
/// never fights the canvas item's move gesture — a drag starting on the
/// tile still moves the item, a tap on the bar seeks.
struct AudioItemView: View {
    @Bindable var item: CanvasItem
    var scale: CGFloat = 1

    @StateObject private var player: AudioPlayer

    init(item: CanvasItem, scale: CGFloat = 1) {
        self.item = item
        self.scale = scale
        _player = StateObject(wrappedValue: AudioPlayer(data: item.audioData,
                                                        fileName: item.audioFileName))
    }

    var body: some View {
        let corner = 8 * scale
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(tileBackground)
            if player.hasAudio {
                playerBody
            } else {
                VStack(spacing: 4 * scale) {
                    Image(systemName: "waveform")
                        .font(.system(size: 28 * scale))
                    Text(item.audioData == nil ? "Audio" : "Couldn't load audio")
                        .font(.system(size: 12 * scale))
                }
                .foregroundStyle(.secondary)
                .padding(10 * scale)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.black.opacity(0.15), lineWidth: max(0.5, scale))
        )
        .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: 2 * scale)
        .onChange(of: item.audioData) { _, newData in
            player.reload(data: newData, fileName: item.audioFileName)
        }
        .onReceive(NotificationCenter.default.publisher(for: AudioPlayer.togglePlayback)) { note in
            guard let id = note.object as? UUID, id == item.id else { return }
            player.toggle()
        }
        .onDisappear { player.pause() }
    }

    private var playerBody: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(spacing: 8 * scale) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30 * scale))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(displayName)
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(formatAudioDuration(player.currentTime)) / \(formatAudioDuration(player.duration))")
                        .font(.system(size: 11 * scale))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4 * scale)
                Image(systemName: "waveform")
                    .font(.system(size: 16 * scale))
                    .foregroundStyle(.secondary)
            }
            SeekBar(progress: player.progress) { fraction in
                player.seek(fraction: fraction)
            }
            .frame(height: max(14, 18 * scale))
        }
        .padding(10 * scale)
    }

    private var displayName: String {
        let name = item.audioFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return "Audio"
    }

#if os(macOS)
    private var tileBackground: Color { Color(nsColor: .controlBackgroundColor) }
#else
    private var tileBackground: Color { Color(uiColor: .secondarySystemBackground) }
#endif
}

/// Tap-to-seek progress bar. Drags intentionally do nothing here so the
/// canvas move gesture owns all drags starting on the tile.
private struct SeekBar: View {
    var progress: Double  // 0...1
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(0, geo.size.width)
            let height: CGFloat = 6
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: height)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: width * clampedProgress, height: height)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, min(width - 12, width * clampedProgress - 6)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in
                // `location` is in the inner view's coordinates.
                guard width > 0 else { return }
                onSeek(min(1, max(0, location.x / width)))
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onEnded { value in
                        guard width > 0 else { return }
                        onSeek(min(1, max(0, value.location.x / width)))
                    }
            )
        }
    }

    private var clampedProgress: Double {
        min(1, max(0, progress.isFinite ? progress : 0))
    }
}

// MARK: - Player

/// AVPlayer wrapper for one audio tile. Posts `stoppingOthers` so only one
/// tile plays at a time.
final class AudioPlayer: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    var hasAudio: Bool { player != nil }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    static let stopOthers = Notification.Name("AudioPlayerStopOthers")
    /// Posted with a canvas item's ID as the object to toggle that tile's
    /// playback (e.g. the canvas space-key shortcut). Tiles ignore IDs
    /// that aren't their own item.
    static let togglePlayback = Notification.Name("AudioPlayerTogglePlayback")

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stopObserver: NSObjectProtocol?
    private var playerID = UUID()

    init(data: Data?, fileName: String) {
        super.init()
        stopObserver = NotificationCenter.default.addObserver(
            forName: Self.stopOthers, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let id = note.object as? UUID, id != self.playerID else { return }
                self.pause()
            }
        load(data: data, fileName: fileName)
    }

    deinit {
        cleanup(playerOnly: false)
    }

    func reload(data: Data?, fileName: String) {
        pause()
        load(data: data, fileName: fileName)
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        NotificationCenter.default.post(name: Self.stopOthers, object: playerID)
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        if isPlaying { isPlaying = false }
    }

    func seek(fraction: Double) {
        guard let player, duration > 0 else { return }
        let target = CMTime(seconds: duration * min(1, max(0, fraction)),
                            preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.currentTime = target.seconds
        }
    }

    // MARK: Private

    private func load(data: Data?, fileName: String) {
        cleanup(playerOnly: true)
        currentTime = 0
        duration = 0
        isPlaying = false
        guard let data, !data.isEmpty,
              let url = CanvasAudioTemp.write(data: data, fileName: fileName.isEmpty ? "audio" : fileName)
        else { return }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player

        // Duration arrives asynchronously; fall back to the header probe.
        let probed = audioDuration(data) ?? 0
        if probed > 0 { duration = probed }

        Task { [weak self] in
            guard let self else { return }
            if let loaded = try? await asset.load(.duration),
               loaded.isValid, loaded.seconds > 0, loaded.seconds.isFinite {
                await MainActor.run { self.duration = loaded.seconds }
            }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, time.isValid else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if self.duration <= 0, let d = player.currentItem?.duration,
               d.isValid, d.seconds > 0, d.seconds.isFinite {
                self.duration = d.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.player?.seek(to: .zero)
                self.currentTime = 0
                self.isPlaying = false
            }
    }

    private func cleanup(playerOnly: Bool) {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if !playerOnly, let stopObserver {
            NotificationCenter.default.removeObserver(stopObserver)
            self.stopObserver = nil
        }
        if playerOnly {
            player?.pause()
            player = nil
        }
    }
}
