import SwiftUI
import WebKit

/// Player tile for `.youtube` items: paste a URL once, watch directly on
/// the canvas. Uses a thumbnail facade (tap ▶ to load the real embed) so a
/// board with many videos stays light until each one plays.
///
/// Interaction note: the tile body is SwiftUI (thumbnail + buttons), so
/// canvas drag / marquee / resize keep working. The live `WKWebView` only
/// appears after ▶ is tapped, and only that playing region captures clicks
/// for YouTube's own controls — drag the header/edges to move the tile.
struct YouTubeItemView: View {
    @Bindable var item: CanvasItem
    var scale: CGFloat = 1
    var isEditing: Bool = false
    var onCommit: () -> Void = {}

    @Environment(\.openURL) private var openURL
    /// True once ▶ is tapped: swaps the thumbnail facade for the live embed.
    @State private var playing = false

    private var videoID: String? {
        youtubeVideoID(from: item.youtubeURL)
    }

    var body: some View {
        let corner = 8 * scale
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color.black)
            VStack(spacing: 0) {
                header
                if isEditing {
                    urlEditor
                }
                mainArea
                footer
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner)
                .stroke(Color.black.opacity(0.35), lineWidth: max(0.5, scale))
        )
        .shadow(color: .black.opacity(0.2), radius: 3 * scale, y: 2 * scale)
        .onChange(of: item.youtubeURL) { _, _ in
            // A new URL always drops back to the facade so the preview,
            // thumbnail, and embed can never disagree.
            playing = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6 * scale) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 15 * scale))
                .foregroundStyle(.red)
            Text("YouTube")
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4 * scale)
            if let id = videoID,
               let watch = youtubeWatchURL(for: id) {
                Button {
                    openURL(watch)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14 * scale))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Open in browser")
                .accessibilityLabel("Open in browser")
            }
        }
        .padding(.horizontal, 10 * scale)
        .frame(height: 30 * scale)
        .background(Color(white: 0.12))
        // The header is the reliable drag handle: it is plain SwiftUI, so
        // a drag starting here always moves the tile even while the embed
        // below captures clicks for playback.
        .contentShape(Rectangle())
    }

    // MARK: URL editor (double-click the tile to edit)

    private var urlEditor: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            TextField("Paste YouTube URL or ID…", text: $item.youtubeURL, onCommit: onCommit)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12 * scale))
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
            if let id = videoID {
                Label("Video ID: \(id)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else {
                Text("Enter a youtube.com / youtu.be link or 11-character ID.")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 8 * scale)
        .background(Color(white: 0.16))
    }

    // MARK: Main area

    @ViewBuilder
    private var mainArea: some View {
        if let id = videoID {
            if playing {
                // No autoplay: the outer ▶ tap is not inherited by the web
                // view as a user gesture, and autoplay-with-sound is blocked
                // by its media policy — that surfaces as a player error on
                // some videos. The user presses play in YouTube's own UI.
                YouTubeWebView(videoID: id, autoplay: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                facade(videoID: id)
            }
        } else {
            placeholder
        }
    }

    /// Escape hatch below the player: some videos disallow embedding
    /// entirely (owner setting, age-gated, music, …) and YouTube renders an
    /// error inside the player for those no matter how it is loaded — the
    /// browser button always works. Also offers a way back to the
    /// lightweight preview.
    @ViewBuilder
    private var footer: some View {
        if let id = videoID,
           let watch = youtubeWatchURL(for: id) {
            HStack(spacing: 6 * scale) {
                Button { openURL(watch) } label: {
                    Label("Watch on YouTube", systemImage: "arrow.up.right.square")
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Open in your browser (works even when the owner disables embedding)")
                .accessibilityLabel("Watch on YouTube")
                Spacer(minLength: 4 * scale)
                if playing {
                    Button { playing = false } label: {
                        Label("Preview", systemImage: "chevron.left")
                            .font(.system(size: 12 * scale))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Back to preview")
                }
            }
            .padding(.horizontal, 10 * scale)
            .frame(height: 28 * scale)
            .background(Color(white: 0.12))
            .contentShape(Rectangle())
        }
    }

    /// Thumbnail + ▶ facade. Stays lightweight until playback, keeps canvas
    /// gestures working, and still exports as a recognizable tile.
    private func facade(videoID: String) -> some View {
        Button {
            playing = true
        } label: {
            ZStack {
                if let thumb = youtubeThumbnailURL(for: videoID) {
                    AsyncImage(url: thumb) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color(white: 0.1)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                } else {
                    Color(white: 0.1)
                }
                Color.black.opacity(0.25)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 52 * scale))
                    .foregroundStyle(.white)
                    .shadow(radius: 4 * scale)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play video")
        .accessibilityLabel("Play video")
    }

    private var placeholder: some View {
        VStack(spacing: 6 * scale) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 34 * scale))
                .foregroundStyle(.white.opacity(0.6))
            Text(item.youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "Paste a YouTube URL"
                 : "Couldn't read that link")
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundStyle(.white)
            Text("Double-click to edit the URL")
                .font(.system(size: 11 * scale))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10 * scale)
    }
}

// MARK: - Live embed

/// `WKWebView` loading the YouTube embed URL directly (real https origin +
/// the `Referer` header YouTube requires — see `youtubeEmbedRequest`).
/// Reloads only when the video ID changes, so canvas zoom/pan re-renders
/// never restart playback.
struct YouTubeWebView: View {
    var videoID: String
    var autoplay: Bool = false

    var body: some View {
#if os(macOS)
        MacYouTubeWebView(videoID: videoID, autoplay: autoplay)
#else
        IOSYouTubeWebView(videoID: videoID, autoplay: autoplay)
#endif
    }
}

#if os(macOS)
private struct MacYouTubeWebView: NSViewRepresentable {
    var videoID: String
    var autoplay: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.loadedID = videoID
        // Direct URL load (real https origin + Referer). The previous
        // iframe-in-loadHTMLString wrapper ran under about:blank, which
        // YouTube rejects with "Error 153" — as does a referer-less load
        // since mid-2025.
        if let request = youtubeEmbedRequest(for: videoID, autoplay: autoplay) {
            view.load(request)
        }
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.loadedID != videoID else { return }
        context.coordinator.loadedID = videoID
        if let request = youtubeEmbedRequest(for: videoID, autoplay: autoplay) {
            nsView.load(request)
        }
    }

    final class Coordinator {
        var loadedID: String?
    }
}
#else
private struct IOSYouTubeWebView: UIViewRepresentable {
    var videoID: String
    var autoplay: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.scrollView.isScrollEnabled = false
        context.coordinator.loadedID = videoID
        if let request = youtubeEmbedRequest(for: videoID, autoplay: autoplay) {
            view.load(request)
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.loadedID != videoID else { return }
        context.coordinator.loadedID = videoID
        if let request = youtubeEmbedRequest(for: videoID, autoplay: autoplay) {
            uiView.load(request)
        }
    }

    final class Coordinator {
        var loadedID: String?
    }
}
#endif
