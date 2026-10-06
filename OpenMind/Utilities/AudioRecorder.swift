import Foundation
import AVFoundation

/// Recording lifecycle for the voice-note sheet.
enum AudioRecordingState: Equatable {
    case idle
    case requesting
    case recording
    case denied
    case failed(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.requesting, .requesting),
             (.recording, .recording), (.denied, .denied):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Microphone recorder for voice notes. Records AAC into a temp `.m4a`
/// file, publishes elapsed time and a normalized input level for the UI,
/// and hands the finished bytes back via `finishRecording()`.
///
/// Permission uses AVCaptureDevice on both platforms; iOS additionally
/// configures a play-and-record audio session so the mic is actually live.
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var state: AudioRecordingState = .idle
    /// Seconds since recording started.
    @Published private(set) var elapsed: TimeInterval = 0
    /// Normalized input level 0...1 for the meter.
    @Published private(set) var level: Float = 0

    /// Recordings auto-stop here so a forgotten session can't grow unbounded.
    static let maxDuration: TimeInterval = 10 * 60

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var timer: Timer?
    private var startDate: Date?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Asks for microphone access when needed, then starts recording.
    func requestAndStart() {
        guard !isRecording else { return }
        // Silence any tile playback so it can't bleed into the mic.
        NotificationCenter.default.post(name: AudioPlayer.stopOthers, object: UUID())
        state = .requesting
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.start() } else { self.state = .denied }
                }
            }
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .denied
        }
    }

    /// Stops and returns the recorded bytes, or nil when nothing usable was
    /// captured. The temp file is removed afterwards.
    func finishRecording() -> Data? {
        let url = stopCapture()
        state = .idle
        guard let url else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= CanvasAudio.maxImportBytes,
              isAudioData(data)
        else { return nil }
        return data
    }

    /// Stops and throws the take away.
    func cancel() {
        if let url = stopCapture() {
            try? FileManager.default.removeItem(at: url)
        }
        state = .idle
    }

    // MARK: Private

    private func start() {
        do {
            try configureSession()
        } catch {
            state = .failed("Couldn't set up audio (\(error.localizedDescription)).")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openmind-recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                state = .failed("The microphone didn't start. Try again.")
                return
            }
            self.recorder = recorder
            self.fileURL = url
        } catch {
            state = .failed("Couldn't start recording (\(error.localizedDescription)).")
            return
        }
        startDate = Date()
        elapsed = 0
        level = 0
        state = .recording
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let recorder, isRecording else { return }
        elapsed = Date().timeIntervalSince(startDate ?? Date())
        recorder.updateMeters()
        // averagePower is dBFS in roughly -160...0; map -50...0 dB to 0...1.
        let db = recorder.averagePower(forChannel: 0)
        let normalized = max(0, min(1, (db + 50) / 50))
        // Smooth the needle so it doesn't jump.
        level = level * 0.6 + Float(pow(10, Double(normalized) * 0.7 - 0.7)) * 0.4
        if elapsed >= Self.maxDuration {
            recorder.stop()
        }
    }

    /// Stops the capture and timer, returning the file (if any) without
    /// deleting it — the caller owns cleanup.
    private func stopCapture() -> URL? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        level = 0
        deactivateSession()
        let url = fileURL
        fileURL = nil
        return url
    }

    private func configureSession() throws {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
#endif
    }

    private func deactivateSession() {
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
#endif
    }

    // MARK: AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Interruptions (calls, Siri) land here with flag == false.
        timer?.invalidate()
        timer = nil
        if !flag, isRecording {
            self.recorder = nil
            if let url = fileURL {
                try? FileManager.default.removeItem(at: url)
                fileURL = nil
            }
            level = 0
            deactivateSession()
            state = .failed("Recording was interrupted.")
        }
    }
}

// MARK: - Naming helpers (tested)

/// Default voice-note title, e.g. "Recording 7 Oct 2026, 10:22".
func defaultRecordingName(date: Date = Date()) -> String {
    let stamp = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    return "Recording \(stamp)"
}

/// Tile file name from the sheet's name field: trims, falls back to a
/// default, and normalizes to `.m4a` (recordings are always AAC, so any
/// typed extension is replaced rather than kept as a lie).
func recordingFileName(from draft: String, date: Date = Date()) -> String {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? defaultRecordingName(date: date) : trimmed
    if base.lowercased().hasSuffix(".m4a") { return base }
    let withoutExt = (base as NSString).deletingPathExtension
    let clean = withoutExt.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\((clean.isEmpty ? base : clean)).m4a"
}
