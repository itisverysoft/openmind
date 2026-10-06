import SwiftUI
import AVKit

/// Player tile for `.video` items: file name plus the platform video player
/// (inline controls on macOS, `VideoPlayer` on iOS). Playback is URL-based
/// with the bytes staged to a temp file (see CanvasVideoTemp).
///
/// Interaction note: the header is plain SwiftUI and always draggable — drag
/// the header/edges to move the tile, since clicks inside the player belong
/// to its transport controls.
struct VideoItemView: View {
    @Bindable var item: CanvasItem
    var scale: CGFloat = 1

    @State private var player: AVPlayer?

    init(item: CanvasItem, scale: CGFloat = 1) {
        self.item = item
        self.scale = scale
        _player = State(initialValue: Self.makePlayer(data: item.videoData))
    }

    var body: some View {
        let corner = 8 * scale
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color.black)
            VStack(spacing: 0) {
                header
                if let player {
                    platformPlayer(player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.black.opacity(0.35), lineWidth: max(0.5, scale))
        )
        .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: 2 * scale)
        .onChange(of: item.videoData) { _, newData in
            player?.pause()
            player = Self.makePlayer(data: newData)
        }
        .onDisappear { player?.pause() }
    }

    private var header: some View {
        HStack(spacing: 6 * scale) {
            Image(systemName: "film.fill")
                .font(.system(size: 14 * scale))
                .foregroundStyle(.white.opacity(0.85))
            Text(displayName)
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4 * scale)
            Text(formatAudioDuration(item.videoDuration))
                .font(.system(size: 11 * scale))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 10 * scale)
        .frame(height: 28 * scale)
        .background(Color(white: 0.12))
        // Reliable drag handle: plain SwiftUI, so a drag starting here
        // always moves the tile even though the player below captures
        // clicks for its transport controls.
        .contentShape(Rectangle())
    }

    private var placeholder: some View {
        VStack(spacing: 6 * scale) {
            Image(systemName: "film")
                .font(.system(size: 34 * scale))
                .foregroundStyle(.white.opacity(0.6))
            Text(item.videoData == nil ? "Video" : "Couldn't load video")
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10 * scale)
    }

    private var displayName: String {
        let name = item.videoFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return "Video"
    }

    @ViewBuilder
    private func platformPlayer(_ player: AVPlayer) -> some View {
#if os(macOS)
        MacVideoPlayer(player: player)
#else
        VideoPlayer(player: player)
#endif
    }

    private static func makePlayer(data: Data?) -> AVPlayer? {
        guard let data, !data.isEmpty,
              let url = CanvasVideoTemp.write(data: data, fileName: "video.mp4")
        else { return nil }
        return AVPlayer(url: url)
    }
}

#if os(macOS)
/// `AVPlayerView` with inline transport controls. The `AVPlayer` itself is
/// owned by the SwiftUI tile (`@State`), so the view only borrows it.
private struct MacVideoPlayer: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#endif
