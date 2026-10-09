import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct FloatingToolbar: View {
    let selectedItems: [CanvasItem]
    let isEditing: Bool

    // Drawing tools
    var tool: CanvasTool = .select
    var penStyle: DrawingStyle = .pen
    var penColorHex: String = Palette.autoInk
    var penWidth: Double = DrawingStyle.pen.defaultLineWidth
    var eraserWidth: Double = 16

    var onAdd: (ItemKind, ShapeKind) -> Void
    var onShapeSelect: (ShapeKind) -> Void = { _ in }
    var onColor: (String) -> Void
    var onDelete: () -> Void
    var onDuplicate: () -> Void = {}
    var canGroup: Bool = false
    var canUngroup: Bool = false
    var onGroup: () -> Void = {}
    var onUngroup: () -> Void = {}
    var onTool: (CanvasTool) -> Void = { _ in }
    var onPenStyle: (DrawingStyle) -> Void = { _ in }
    var onPenColor: (String) -> Void = { _ in }
    var onPenWidth: (Double) -> Void = { _ in }
    var onEraserWidth: (Double) -> Void = { _ in }
    var onAddImage: (Data) -> Void = { _ in }
    var onAddAudio: (Data, String) -> Void = { _, _ in }
    var onRecordAudio: () -> Void = {}
    var onAddYouTube: (String) -> Void = { _ in }
    var onAddVideo: (Data, String) -> Void = { _, _ in }
    var onPaste: () -> Void = {}

    @State private var pickerItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var showAudioImporter = false
    @State private var showVideoImporter = false
    @State private var showShapes = false
    @State private var showYouTubePrompt = false
    @State private var youtubeDraft = ""
    @State private var showNetworkPrompt = false
    @State private var networkDraft = ""
    @State private var isDownloadingNetwork = false
    @State private var networkError: String?

    /// Brush-size slider bounds (world points). Sliders replace the old
    /// fixed dot presets so any diameter can be dialed in; the canvas shows
    /// a matching ring under the pointer.
    static let penWidthRange: ClosedRange<Double> = 1...50
    static let eraserWidthRange: ClosedRange<Double> = 4...80

    /// The lone selected item, if exactly one is selected.
    private var selectedItem: CanvasItem? {
        selectedItems.count == 1 ? selectedItems.first : nil
    }

    private var isMultiSelection: Bool { selectedItems.count > 1 }

    /// Delete acts only on unlocked items; an all-locked selection has
    /// nothing deletable so the button disables instead of no-op'ing.
    private var hasDeletable: Bool { selectedItems.contains(where: { !$0.isLocked }) }

    /// The shape armed for drag-to-size placement, if any.
    private var selectedShape: ShapeKind? { tool.shapeKind }

    var body: some View {
        VStack(spacing: 10) {
            if showShapes {
                shapeRow
            }
            if tool == .draw {
                inkRow
                drawingOptionsRow
            } else if tool == .erase {
                eraserOptionsRow
            } else if let item = selectedItem, item.kind != .text, item.kind != .image, item.kind != .pdf, item.kind != .audio, item.kind != .youtube, item.kind != .video, !item.isLocked {
                swatchRow(selected: item.colorHex)
            }
            // No color row for multi-selections: a mixed selection (text,
            // images, drawings) has no single meaningful color, and applying
            // one would silently do nothing on text/image items.
            if isMultiSelection && tool == .select {
                HStack(spacing: 12) {
                    Text("\(selectedItems.count) selected")
                        .font(.caption)
                    if canGroup || canUngroup {
                        Divider().frame(height: 16)
                        if canGroup {
                            Button(action: onGroup) {
                                Label("Group", systemImage: "square.on.square.squareshape.controlhandles")
                            }
                            .keyboardShortcut("g", modifiers: .command)
                            .disabled(isEditing)
                            .help("Group selection (⌘G)")
                        }
                        if canUngroup {
                            Button(action: onUngroup) {
                                Label("Ungroup", systemImage: "square.on.square")
                            }
                            .keyboardShortcut("g", modifiers: [.command, .shift])
                            .disabled(isEditing)
                            .help("Ungroup selection (⇧⌘G)")
                        }
                    }
                    Text("drag corner to resize (Shift: free stretch)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .labelStyle(.iconOnly)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
            }
            mainRow
        }
        .padding(.bottom, 16)
    }

    // MARK: Main row

    private var mainRow: some View {
        HStack(spacing: 18) {
            toolButton(.note, systemImage: "note.text", help: "Note (N)")
                .keyboardShortcut("n", modifiers: [])
                .disabled(isEditing)

            Button { onAdd(.text, .rectangle) } label: {
                Label("Text", systemImage: "textformat")
            }

            Button { onAdd(.table, .rectangle) } label: {
                Label("Table", systemImage: "tablecells")
            }

            Button { showShapes.toggle() } label: {
                Label("Shapes", systemImage: "square.on.circle")
                    .foregroundStyle((showShapes || selectedShape != nil) ? Color.accentColor : Color.primary)
                    .fontWeight((showShapes || selectedShape != nil) ? .semibold : .regular)
            }
            .help("Shapes")

            Menu {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }
                Button { showFileImporter = true } label: {
                    Label("Browse Files…", systemImage: "folder")
                }
                Button { openNetworkPrompt() } label: {
                    Label("From URL…", systemImage: "link")
                }
            } label: {
                Label("Add Image", systemImage: "photo.badge.plus")
            }
            .menuIndicator(.hidden)
            .disabled(isEditing)
            .onChange(of: pickerItem) { _, newItem in
                guard let newItem else { return }
                pickerItem = nil
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        await MainActor.run { onAddImage(data) }
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.image],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if let data = imageDataFromFileURL(url) {
                        onAddImage(data)
                    }
                case .failure:
                    break
                }
            }

            Button { onPaste() } label: {
                Label("Paste Image", systemImage: "doc.on.clipboard")
            }
            .disabled(isEditing)
            .help("Paste Image (⌘V)")

            Menu {
                Button { showAudioImporter = true } label: {
                    Label("Browse Files…", systemImage: "folder")
                }
                Button { openNetworkPrompt() } label: {
                    Label("From URL…", systemImage: "link")
                }
            } label: {
                Label("Add Audio", systemImage: "waveform.badge.plus")
            }
            .disabled(isEditing)
            .help("Add Audio")
            .fileImporter(isPresented: $showAudioImporter,
                          allowedContentTypes: [.audio],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first,
                          let loaded = audioDataFromFileURL(url) else { return }
                    onAddAudio(loaded.data, loaded.fileName)
                case .failure:
                    break
                }
            }

            Button { onRecordAudio() } label: {
                Label("Record Audio", systemImage: "mic.badge.plus")
            }
            .disabled(isEditing)
            .help("Record Audio")

            Button { youtubeDraft = ""; showYouTubePrompt = true } label: {
                Label("Add YouTube video", systemImage: "play.rectangle.on.rectangle")
            }
            .disabled(isEditing)
            .help("Add YouTube video…")
            .sheet(isPresented: $showYouTubePrompt) {
                youtubePrompt
            }

            Menu {
                Button { showVideoImporter = true } label: {
                    Label("Browse Files…", systemImage: "folder")
                }
                Button { openNetworkPrompt() } label: {
                    Label("From URL…", systemImage: "link")
                }
            } label: {
                Label("Add Video", systemImage: "video.badge.plus")
            }
            .disabled(isEditing)
            .help("Add Video from device, Drive, or URL…")
            .fileImporter(isPresented: $showVideoImporter,
                          allowedContentTypes: [.video, .movie],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first,
                          let loaded = videoDataFromFileURL(url) else { return }
                    onAddVideo(loaded.data, loaded.fileName)
                case .failure:
                    break
                }
            }

            Button { openNetworkPrompt() } label: {
                Label("Add from URL", systemImage: "link.badge.plus")
            }
            .disabled(isEditing)
            .help("Add image, audio, or video from a link…")
            .sheet(isPresented: $showNetworkPrompt) {
                networkPrompt
            }

            Divider().frame(height: 22)

            toolButton(.select, systemImage: "cursorarrow", help: "Select (V)")
                .keyboardShortcut("v", modifiers: [])
                .disabled(isEditing)

            toolButton(.hand, systemImage: "hand.draw", help: "Pan (H)")
                .keyboardShortcut("h", modifiers: [])
                .disabled(isEditing)

            toolButton(.draw, systemImage: "pencil", help: "Draw")
            toolButton(.erase, systemImage: "eraser", help: "Eraser")

            if !selectedItems.isEmpty {
                Divider().frame(height: 22)

                Button(action: onDuplicate) {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(isEditing)

                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(isEditing || !hasDeletable)   // never steal Delete from the text editor
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    private func toolButton(_ target: CanvasTool, systemImage: String, help: String) -> some View {
        let active = tool == target
        return Button { onTool(active ? .select : target) } label: {
            Label(help, systemImage: systemImage)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .fontWeight(active ? .semibold : .regular)
        }
        .help(help)
    }

    // MARK: Shapes row (separate toolbar with every shape)

    private var shapeRow: some View {
        HStack(spacing: 8) {
            ForEach(ShapeKind.allCases) { shape in
                let selected = selectedShape == shape
                Button { onShapeSelect(shape) } label: {
                    ShapeIcon(kind: shape)
                        .frame(width: 24, height: 18)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .padding(4)
                        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        // Outlined icons only paint their thin stroke, so
                        // claim the whole cell for taps.
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .help(shape.isLineLike ? "\(shape.title) — tap point A, then point B" : shape.title)
                    .accessibilityLabel(shape.title)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    // MARK: Drawing options

    private var drawingOptionsRow: some View {
        HStack(spacing: 14) {
            ForEach(DrawingStyle.allCases) { style in
                Button { onPenStyle(style) } label: {
                    Label(style.title, systemImage: style.symbol)
                        .foregroundStyle(penStyle == style ? Color.accentColor : Color.primary)
                        .fontWeight(penStyle == style ? .semibold : .regular)
                }
                .help(style.title)
            }

            Divider().frame(height: 22)

            brushSlider(value: penWidth, range: Self.penWidthRange) {
                onPenWidth($0)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    /// Size slider with a live point readout. The canvas draws a ring of the
    /// same diameter under the pointer (macOS hover).
    private func brushSlider(value: Double, range: ClosedRange<Double>,
                             onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
                .help("Brush size")
            Slider(value: Binding(get: { value }, set: { onChange($0) }),
                   in: range, step: 1)
                .frame(width: 120)
                .help("Brush size (\(Int(value)) pt)")
            Text("\(Int(value))")
                .font(.callout)
                .monospacedDigit()
                .frame(minWidth: 24, alignment: .trailing)
                .foregroundStyle(.primary)
        }
    }

    // MARK: Eraser options

    private var eraserOptionsRow: some View {
        HStack(spacing: 14) {
            Label("Eraser", systemImage: "eraser")
                .foregroundStyle(.secondary)
            brushSlider(value: eraserWidth, range: Self.eraserWidthRange) {
                onEraserWidth($0)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    // MARK: Color rows

    private func swatchRow(selected: String) -> some View {
        colorRow(swatches: Palette.swatches, selected: selected) { onColor($0) }
    }

    private var inkRow: some View {
        colorRow(swatches: Palette.inkSwatches, selected: penColorHex,
                 includeAuto: true) { onPenColor($0) }
    }

    private func colorRow(swatches: [String], selected: String,
                           includeAuto: Bool = false,
                           onPick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            if includeAuto {
                Color.autoInkDot(selected: selected, diameter: 24, onPick: onPick)
            }
            ForEach(swatches, id: \.self) { hex in
                Button { onPick(hex) } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                        .overlay {
                            if hex == selected {
                                Circle().stroke(Color.accentColor, lineWidth: 3).padding(-3)
                            }
                        }
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    // MARK: YouTube prompt

    /// Resets the From-URL sheet state and presents it.
    private func openNetworkPrompt() {
        networkDraft = ""
        networkError = nil
        isDownloadingNetwork = false
        showNetworkPrompt = true
    }

    /// Downloads the typed URL and routes the bytes to the matching add
    /// callback (image / audio / video). Runs async so large files don't
    /// block the UI; the sheet shows a spinner until it resolves.
    private func submitNetworkURL() {
        let raw = networkDraft
        guard normalizeNetworkURL(raw) != nil else {
            networkError = NetworkMediaError.invalidURL.localizedDescription
            return
        }
        guard !isDownloadingNetwork else { return }
        isDownloadingNetwork = true
        networkError = nil
        Task {
            do {
                let result = try await fetchNetworkMedia(from: raw)
                await MainActor.run {
                    isDownloadingNetwork = false
                    showNetworkPrompt = false
                    switch result.kind {
                    case .image:
                        onAddImage(result.data)
                    case .audio:
                        onAddAudio(result.data, result.fileName)
                    case .video:
                        onAddVideo(result.data, result.fileName)
                    default:
                        break
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloadingNetwork = false
                    if let localized = error as? LocalizedError,
                       let description = localized.errorDescription {
                        networkError = description
                    } else {
                        networkError = error.localizedDescription
                    }
                }
            }
        }
    }

    /// URL sheet for network media: paste any direct image / audio / video
    /// link and it downloads onto the canvas as the matching tile. The type
    /// is auto-detected after download (extension + MIME + byte sniffing),
    /// with an extension-based hint shown live while typing.
    private var networkPrompt: some View {
        let normalized = normalizeNetworkURL(networkDraft)
        let hint: ItemKind? = normalized.flatMap { networkMediaKindHint(for: $0) }
        let trimmedEmpty = networkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            Text("Add from URL")
                .font(.headline)
            Text("Paste a direct link to an image, audio, or video file. It downloads onto the canvas as the matching tile.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://example.com/photo.jpg", text: $networkDraft)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .disabled(isDownloadingNetwork)
                .onSubmit { submitNetworkURL() }
                .onChange(of: networkDraft) { _, _ in
                    // Clear a stale error as soon as the user edits.
                    if networkError != nil { networkError = nil }
                }
            if !trimmedEmpty {
                if normalized == nil {
                    Label("That doesn't look like a valid http(s) link.", systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let hint {
                    Label("Looks like \(hint == .image ? "an image" : hint == .audio ? "audio" : "a video") — type is confirmed after download.", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Label("Link looks valid — the file type is detected after download.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let networkError {
                Label(networkError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isDownloadingNetwork {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showNetworkPrompt = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDownloadingNetwork)
                Button("Add to canvas") { submitNetworkURL() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalized == nil || isDownloadingNetwork)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    // MARK: YouTube prompt

    /// URL sheet for the YouTube embedder: paste any watch / share / embed
    /// link (or a bare 11-char ID) and it lands on the canvas as a playable
    /// tile. The Add button stays disabled until the text parses.
    private var youtubePrompt: some View {
        let parsed = youtubeVideoID(from: youtubeDraft)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Add YouTube video")
                .font(.headline)
            Text("Paste a YouTube link — watch, share, embed, Shorts — or a bare video ID. The video plays right on the canvas.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://www.youtube.com/watch?v=…", text: $youtubeDraft)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .onSubmit {
                    guard let id = parsed else { return }
                    _ = id
                    onAddYouTube(youtubeDraft)
                    showYouTubePrompt = false
                }
            if !youtubeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let id = parsed {
                    Label("Video ID: \(id)", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Label("That doesn't look like a YouTube link.", systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { showYouTubePrompt = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add video") {
                    onAddYouTube(youtubeDraft)
                    showYouTubePrompt = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}
