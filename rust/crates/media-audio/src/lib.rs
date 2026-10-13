//! Audio capture + playback behind stable traits.
//!
//! - [`AudioCapture`]: mic recording (WAV writer + mock; `cpal`/AVFoundation
//!   adapters plug in behind the same trait without touching the board).
//! - [`AudioPlayer`]: load/play/pause/seek/stop with state events; timing
//!   lives outside the canvas render loop. Policy: one active player.
//! - [`waveform_peaks`]: downsampled peak envelope in a background task;
//!   compact `u8` peaks cached by content hash + algorithm version.
//!
//! Recording format v1 is WAV (simple, verifiable). AAC/M4A is deferred until
//! its encoder is verified on both Apple Silicon and Intel.

#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};

/// Recording options chosen in the UI.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingOptions {
    pub sample_rate: u32,
    pub channels: u16,
    #[serde(default = "default_device")]
    pub device_name: String,
}

fn default_device() -> String {
    "default".to_string()
}

impl Default for RecordingOptions {
    fn default() -> Self {
        Self {
            sample_rate: 44_100,
            channels: 1,
            device_name: default_device(),
        }
    }
}

/// Opaque recording session (temp file + start time).
#[derive(Clone, Debug)]
pub struct RecordingSession {
    pub id: String,
    pub started_unix: f64,
    pub options: RecordingOptions,
    pub temp_path: std::path::PathBuf,
}

/// Finalized asset metadata (persisted alongside the board's `AssetRef`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordedAsset {
    pub byte_size: u64,
    pub duration_secs: f64,
    pub codec: String,
    pub container: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub asset_hash: String,
    pub waveform_version: u32,
}

/// Capture backend. The audio callback must do minimal work (push into a
/// bounded queue); encoding/disk happen on a worker.
pub trait AudioCapture {
    fn start(&mut self, options: RecordingOptions) -> Result<RecordingSession, CaptureError>;
    fn stop(
        &mut self,
        session: RecordingSession,
        samples: &[i16],
    ) -> Result<RecordedAsset, CaptureError>;
    fn cancel(&mut self, session: RecordingSession);
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CaptureError {
    PermissionDenied,
    NoDevice,
    Io(String),
    Interrupted(String),
}

impl std::fmt::Display for CaptureError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PermissionDenied => write!(f, "microphone permission denied"),
            Self::NoDevice => write!(f, "no input device"),
            Self::Io(m) => write!(f, "i/o: {m}"),
            Self::Interrupted(m) => write!(f, "interrupted: {m}"),
        }
    }
}

impl std::error::Error for CaptureError {}

/// Playback state events (polled by the UI; never driven by the render loop).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PlaybackState {
    Stopped,
    Playing,
    Paused,
}

/// Player backend (symphonia/AVFoundation adapters plug in here).
pub trait AudioPlayer {
    fn load(&mut self, bytes: &[u8]) -> Result<f64, PlayerError>;
    fn play(&mut self) -> Result<(), PlayerError>;
    fn pause(&mut self) -> Result<(), PlayerError>;
    fn seek(&mut self, secs: f64) -> Result<(), PlayerError>;
    fn stop(&mut self);
    fn state(&self) -> PlaybackState;
    fn position_secs(&self) -> f64;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlayerError {
    Decode(String),
    Output(String),
    Empty,
}

impl std::fmt::Display for PlayerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Decode(m) => write!(f, "decode: {m}"),
            Self::Output(m) => write!(f, "output: {m}"),
            Self::Empty => write!(f, "no audio loaded"),
        }
    }
}

impl std::error::Error for PlayerError {}

/// Mock capture for tests + headless builds: writes WAV from provided PCM.
pub struct MockCapture {
    next: u64,
}

impl MockCapture {
    pub fn new() -> Self {
        Self { next: 1 }
    }
}

impl Default for MockCapture {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioCapture for MockCapture {
    fn start(&mut self, options: RecordingOptions) -> Result<RecordingSession, CaptureError> {
        let id = format!("rec-{}", self.next);
        self.next += 1;
        let mut tmp = std::env::temp_dir();
        tmp.push(format!("{id}.wav"));
        Ok(RecordingSession {
            id,
            started_unix: 0.0,
            options,
            temp_path: tmp,
        })
    }

    fn stop(
        &mut self,
        session: RecordingSession,
        samples: &[i16],
    ) -> Result<RecordedAsset, CaptureError> {
        let bytes = encode_wav_mono(samples, session.options.sample_rate);
        std::fs::write(&session.temp_path, &bytes).map_err(|e| CaptureError::Io(e.to_string()))?;
        let duration = samples.len() as f64 / session.options.sample_rate as f64;
        Ok(RecordedAsset {
            byte_size: bytes.len() as u64,
            duration_secs: duration,
            codec: "pcm-s16".to_string(),
            container: "wav".to_string(),
            sample_rate: session.options.sample_rate,
            channels: 1,
            asset_hash: hash_hex(&bytes),
            waveform_version: WAVEFORM_ALGO,
        })
    }

    fn cancel(&mut self, session: RecordingSession) {
        let _ = std::fs::remove_file(session.temp_path);
    }
}

/// Minimal WAV (PCM16 mono) encoder — the v1 recording format.
pub fn encode_wav_mono(samples: &[i16], sample_rate: u32) -> Vec<u8> {
    let data_bytes = samples.len() * 2;
    let mut out = Vec::with_capacity(44 + data_bytes);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&((36 + data_bytes) as u32).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&(sample_rate * 2).to_le_bytes()); // byte rate
    out.extend_from_slice(&2u16.to_le_bytes()); // block align
    out.extend_from_slice(&16u16.to_le_bytes()); // bits
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data_bytes as u32).to_le_bytes());
    for s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

/// Decode the WAV written above (validates header; errors are contextual).
pub fn decode_wav_mono(bytes: &[u8]) -> Result<(Vec<i16>, u32), PlayerError> {
    if bytes.len() < 44 {
        return Err(PlayerError::Decode("too short".to_string()));
    }
    if &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err(PlayerError::Decode("not wav".to_string()));
    }
    let sample_rate = u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]);
    let data_len = u32::from_le_bytes([bytes[40], bytes[41], bytes[42], bytes[43]]) as usize;
    if bytes.len() < 44 + data_len {
        return Err(PlayerError::Decode("truncated".to_string()));
    }
    let mut samples = Vec::with_capacity(data_len / 2);
    for chunk in bytes[44..44 + data_len].chunks_exact(2) {
        samples.push(i16::from_le_bytes([chunk[0], chunk[1]]));
    }
    Ok((samples, sample_rate))
}

/// Waveform algorithm version (bump when the envelope changes).
pub const WAVEFORM_ALGO: u32 = 1;

/// Downsampled peak envelope: `width` `u8` peaks in 0..=255.
/// Store these, not full PCM. Pure + allocation-bounded.
pub fn waveform_peaks(samples: &[i16], width: usize) -> Vec<u8> {
    if width == 0 || samples.is_empty() {
        return Vec::new();
    }
    let mut peaks = Vec::with_capacity(width);
    let per = (samples.len() as f64 / width as f64).max(1.0);
    for i in 0..width {
        let start = (i as f64 * per) as usize;
        let end = (((i + 1) as f64 * per) as usize)
            .min(samples.len())
            .max(start + 1);
        let mut peak: i32 = 0;
        for s in &samples[start..end] {
            let v = (*s as i32).abs();
            if v > peak {
                peak = v;
            }
        }
        peaks.push(((peak * 255) / 32768).min(255) as u8);
    }
    peaks
}

fn hash_hex(bytes: &[u8]) -> String {
    // FNV-1a hex for the mock path (real store uses SHA-256).
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

/// Mock player: decodes WAV, tracks position logically (no system audio).
pub struct MockPlayer {
    duration: f64,
    position: f64,
    state: PlaybackState,
}

impl MockPlayer {
    pub fn new() -> Self {
        Self {
            duration: 0.0,
            position: 0.0,
            state: PlaybackState::Stopped,
        }
    }
}

impl Default for MockPlayer {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioPlayer for MockPlayer {
    fn load(&mut self, bytes: &[u8]) -> Result<f64, PlayerError> {
        let (samples, rate) = decode_wav_mono(bytes)?;
        if rate == 0 {
            return Err(PlayerError::Decode("bad rate".to_string()));
        }
        self.duration = samples.len() as f64 / rate as f64;
        self.position = 0.0;
        self.state = PlaybackState::Stopped;
        Ok(self.duration)
    }

    fn play(&mut self) -> Result<(), PlayerError> {
        if self.duration <= 0.0 {
            return Err(PlayerError::Empty);
        }
        self.state = PlaybackState::Playing;
        Ok(())
    }

    fn pause(&mut self) -> Result<(), PlayerError> {
        if self.state != PlaybackState::Playing {
            return Err(PlayerError::Empty);
        }
        self.state = PlaybackState::Paused;
        Ok(())
    }

    fn seek(&mut self, secs: f64) -> Result<(), PlayerError> {
        if self.duration <= 0.0 {
            return Err(PlayerError::Empty);
        }
        self.position = secs.clamp(0.0, self.duration);
        Ok(())
    }

    fn stop(&mut self) {
        self.state = PlaybackState::Stopped;
        self.position = 0.0;
    }

    fn state(&self) -> PlaybackState {
        self.state
    }

    fn position_secs(&self) -> f64 {
        self.position
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_round_trips_and_waveform_peaks() {
        let samples: Vec<i16> = (0..4410).map(|i| ((i % 100) as i16) * 100).collect();
        let bytes = encode_wav_mono(&samples, 44100);
        let (back, rate) = decode_wav_mono(&bytes).expect("decode");
        assert_eq!(rate, 44100);
        assert_eq!(back, samples);
        let peaks = waveform_peaks(&samples, 64);
        assert_eq!(peaks.len(), 64);
        assert!(peaks.iter().any(|p| *p > 0));
        assert!(decode_wav_mono(b"junk").is_err());
    }

    #[test]
    fn mock_capture_and_player() {
        let mut cap = MockCapture::new();
        let session = cap.start(RecordingOptions::default()).expect("start");
        let samples = vec![0i16; 4410];
        let asset = cap.stop(session, &samples).expect("stop");
        assert!((asset.duration_secs - 0.1).abs() < 1e-6);
        assert_eq!(asset.container, "wav");
        let mut player = MockPlayer::new();
        let bytes = encode_wav_mono(&samples, 44100);
        let dur = player.load(&bytes).expect("load");
        assert!((dur - 0.1).abs() < 1e-6);
        player.play().expect("play");
        assert_eq!(player.state(), PlaybackState::Playing);
        player.seek(0.05).expect("seek");
        assert!((player.position_secs() - 0.05).abs() < 1e-9);
        player.pause().expect("pause");
        player.stop();
        assert_eq!(player.state(), PlaybackState::Stopped);
    }
}
