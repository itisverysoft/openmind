import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Non-modal voice-note controls docked beside the undo/redo pill: record
/// from the mic while the board stays fully usable.
///
/// The `AudioRecorder` is owned by `CanvasView` (not here) so recording
/// survives canvas interaction; this view is just the controls. Closing
/// mid-recording discards the take (via `onClose`).
///
/// Layout: a single-row pill exactly matching the undo/redo pill's height,
/// sitting side by side with it — idle → recording flows stay one row.
/// After stopping, a small review card (listen back + name + Add to Canvas)
/// appears below the pill; the finished take is dropped on the canvas via
/// `onFinish`.
struct AudioRecorderView: View {
    @ObservedObject var recorder: AudioRecorder

    var onFinish: (Data, String) -> Void = { _, _ in }
    var onClose: () -> Void = {}

    @State private var finishedData: Data?
    @State private var finishedDuration: TimeInterval = 0
    @State private var previewPlayer: AudioPlayer?
    @State private var name: String = ""
    @State private var errorMessage: String?
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if finishedData != nil {
                reviewCard
            } else {
                pill
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onAppear { pulse = true }
        .onDisappear {
            if recorder.isRecording { recorder.cancel() }
            previewPlayer?.pause()
        }
    }

    // MARK: Single-row pill (same height as the undo/redo pill)

    private var pill: some View {
        HStack(spacing: 12) {
            switch recorder.state {
            case .idle:
                idleControls
            case .requesting:
                ProgressView()
                    .controlSize(.small)
            case .recording:
                recordingControls
            case .denied:
                deniedControls
            case .failed:
                failedControls
            }
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    private var closeButton: some View {
        Button { onClose() } label: {
            Label("Close", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close")
    }

    private var idleControls: some View {
        Group {
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
            Button { recorder.requestAndStart() } label: {
                Label("Record", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Record")
            closeButton
        }
    }

    private var recordingControls: some View {
        Group {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                           value: pulse)
            Text(formatAudioDuration(recorder.elapsed))
                .font(.caption)
                .monospacedDigit()
            Capsule()
                .fill(Color.primary.opacity(0.15))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.red)
                        .frame(width: 48 * CGFloat(max(0, min(1, recorder.level))))
                }
                .frame(width: 48, height: 5)
            Button { stopRecording() } label: {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Stop")
            Button {
                recorder.cancel()
                onClose()
            } label: {
                Label("Cancel recording", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Cancel recording")
        }
    }

    private var deniedControls: some View {
        Group {
            Text("Mic is off")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Settings") { openMicrophoneSettings() }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            closeButton
        }
    }

    private var failedControls: some View {
        Group {
            if case .failed(let message) = recorder.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Retry") {
                errorMessage = nil
                recorder.requestAndStart()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            closeButton
        }
    }

    // MARK: Review card (below the pill, only after stopping)

    private var reviewCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { previewPlayer?.toggle() } label: {
                    Image(systemName: (previewPlayer?.isPlaying ?? false)
                          ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(previewPlayer == nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take ready")
                        .font(.headline)
                    if let previewPlayer {
                        PreviewTimeView(player: previewPlayer)
                    } else {
                        Text(formatAudioDuration(finishedDuration))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    previewPlayer?.pause()
                    onClose()
                } label: {
                    Label("Discard", systemImage: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Discard")
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button {
                    guard let finishedData else { return }
                    previewPlayer?.pause()
                    onFinish(finishedData, recordingFileName(from: name))
                } label: {
                    Label("Add to Canvas", systemImage: "plus")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(finishedData == nil)
                Button("Record Again") {
                    previewPlayer?.pause()
                    previewPlayer = nil
                    finishedData = nil
                    name = ""
                    errorMessage = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    // MARK: Actions

    private func stopRecording() {
        if let data = recorder.finishRecording() {
            finishedData = data
            finishedDuration = audioDuration(data) ?? 0
            previewPlayer = AudioPlayer(data: data, fileName: "preview")
            name = defaultRecordingName()
            errorMessage = nil
        } else {
            errorMessage = "Couldn't use that take — try recording again."
        }
    }

    private func openMicrophoneSettings() {
#if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
#else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
#endif
    }
}

/// Live elapsed/total readout for the review preview player.
private struct PreviewTimeView: View {
    @ObservedObject var player: AudioPlayer

    var body: some View {
        Text("\(formatAudioDuration(player.currentTime)) / \(formatAudioDuration(player.duration))")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
