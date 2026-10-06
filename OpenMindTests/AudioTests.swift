import Testing
import Foundation
@testable import OpenMind

/// Builds a minimal PCM WAV in memory (sine tone) without fixtures.
func makeTestWAV(seconds: Double = 1.0, sampleRate: Int = 8000) -> Data {
    let samples = Int(seconds * Double(sampleRate))
    var data = Data()
    func appendU32(_ v: UInt32) {
        data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8((v >> 24) & 0xFF))
    }
    func appendU16(_ v: UInt16) {
        data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
    }
    data.append(contentsOf: "RIFF".utf8); appendU32(UInt32(36 + samples * 2))
    data.append(contentsOf: "WAVE".utf8); data.append(contentsOf: "fmt ".utf8)
    appendU32(16); appendU16(1); appendU16(1)
    appendU32(UInt32(sampleRate)); appendU32(UInt32(sampleRate * 2))
    appendU16(2); appendU16(16)
    data.append(contentsOf: "data".utf8); appendU32(UInt32(samples * 2))
    for i in 0..<samples {
        let t = Double(i) / Double(sampleRate)
        let s = Int16(sin(t * 440 * 2 * .pi) * 16000)
        appendU16(UInt16(bitPattern: s))
    }
    return data
}

@Suite struct AudioTests {
    @Test func validAudioIsRecognized() {
        let wav = makeTestWAV()
        #expect(!wav.isEmpty)
        #expect(isAudioData(wav))
    }

    @Test func garbageIsNotAudio() {
        #expect(!isAudioData(Data()))
        #expect(!isAudioData(Data("nope".utf8)))
        #expect(audioDuration(Data("nope".utf8)) == nil)
    }

    @Test func durationMatchesToneLength() {
        let wav = makeTestWAV(seconds: 1.0)
        let d = audioDuration(wav)
        #expect(d != nil)
        #expect(abs((d ?? 0) - 1.0) < 0.05)
    }

    @Test func durationFormatting() {
        #expect(formatAudioDuration(0) == "0:00")
        #expect(formatAudioDuration(7) == "0:07")
        #expect(formatAudioDuration(65) == "1:05")
        #expect(formatAudioDuration(3723) == "1:02:03")
    }

    @Test func audioItemDefaults() {
        #expect(ItemKind.audio.defaultSize.width == 300)
        #expect(!ItemKind.audio.isTextEditable)
        #expect(!ItemKind.audio.isEditable)
    }

    @Test func recordingNameDefaults() {
        let name = defaultRecordingName(date: Date(timeIntervalSince1970: 0))
        #expect(name.hasPrefix("Recording "))
        #expect(name.count > "Recording ".count)
    }

    @Test func recordingFileNameRules() {
        #expect(recordingFileName(from: "") .hasSuffix(".m4a"))
        #expect(recordingFileName(from: "   ").hasSuffix(".m4a"))
        #expect(recordingFileName(from: "Interview") == "Interview.m4a")
        #expect(recordingFileName(from: "Interview.m4a") == "Interview.m4a")
        #expect(recordingFileName(from: "Interview.M4A") == "Interview.M4A")
        // Typed extensions are normalized: the bytes are always AAC.
        #expect(recordingFileName(from: "note.mp3") == "note.m4a")
    }

    @Test func recordingCapIsSane() {
        #expect(AudioRecorder.maxDuration >= 60)
    }

    @Test func spaceTogglesLoneVoiceSelection() {
        let voice = CanvasItem(kind: .audio, x: 0, y: 0)
        #expect(spaceToggleAudioTarget(selectedItems: [voice], isEditing: false)?.id == voice.id)
    }

    @Test func spaceIgnoresOtherSelections() {
        let voice = CanvasItem(kind: .audio, x: 0, y: 0)
        let other = CanvasItem(kind: .audio, x: 10, y: 10)
        let text = CanvasItem(kind: .text, x: 0, y: 0)
        #expect(spaceToggleAudioTarget(selectedItems: [], isEditing: false) == nil)
        #expect(spaceToggleAudioTarget(selectedItems: [text], isEditing: false) == nil)
        #expect(spaceToggleAudioTarget(selectedItems: [voice, other], isEditing: false) == nil)
        #expect(spaceToggleAudioTarget(selectedItems: [voice], isEditing: true) == nil)
    }
}
