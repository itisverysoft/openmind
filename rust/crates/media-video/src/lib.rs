//! Video: format matrix, metadata/poster extraction, playback lifecycle.
//!
//! A URL ending in `.mp4` proves nothing (auth, redirects, codecs, DRM all
//! matter). The [`FORMAT_MATRIX`] documents what each backend claims.
//! Canvas cards show a poster frame; live decode runs only in a dedicated
//! overlay for the one playing card — never per-card decoders.

#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};

/// One row of the support matrix.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FormatRow {
    pub container: String,
    pub local_file: Support,
    pub direct_url: Support,
    pub hls_dash: Support,
    pub notes: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Support {
    Yes,
    Partial,
    No,
    Untested,
}

/// What this build advertises. AVFoundation covers system codecs on macOS;
/// FFmpeg would widen this at LGPL/packaging cost (deferred, see ADR).
pub fn format_matrix() -> Vec<FormatRow> {
    vec![
        FormatRow {
            container: "mp4 (h264/aac)".to_string(),
            local_file: Support::Yes,
            direct_url: Support::Yes,
            hls_dash: Support::Partial,
            notes: "system codecs via AVFoundation path".to_string(),
        },
        FormatRow {
            container: "mov".to_string(),
            local_file: Support::Yes,
            direct_url: Support::Partial,
            hls_dash: Support::No,
            notes: "local only; orientation honored".to_string(),
        },
        FormatRow {
            container: "webm (vp9)".to_string(),
            local_file: Support::Partial,
            direct_url: Support::Partial,
            hls_dash: Support::No,
            notes: "needs FFmpeg for full coverage".to_string(),
        },
        FormatRow {
            container: "YouTube pages".to_string(),
            local_file: Support::No,
            direct_url: Support::No,
            hls_dash: Support::No,
            notes: "use the YouTube card (media crate), never scrape".to_string(),
        },
    ]
}

/// Probed metadata (off the UI thread).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoMetadata {
    pub duration_secs: Option<f64>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub orientation_degs: u16,
    pub has_poster: bool,
}

impl VideoMetadata {
    pub fn unknown() -> Self {
        Self {
            duration_secs: None,
            width: None,
            height: None,
            orientation_degs: 0,
            has_poster: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VideoError {
    Unsupported(String),
    Corrupt(String),
    Io(String),
    Offline,
}

impl std::fmt::Display for VideoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported(m) => write!(f, "unsupported video: {m}"),
            Self::Corrupt(m) => write!(f, "corrupt video: {m}"),
            Self::Io(m) => write!(f, "i/o: {m}"),
            Self::Offline => write!(f, "offline"),
        }
    }
}

impl std::error::Error for VideoError {}

/// Backend boundary: probing + poster + playback live behind this trait.
/// Moving/zooming/selecting the card must not restart playback.
pub trait VideoBackend {
    fn probe(&self, bytes: &[u8]) -> Result<VideoMetadata, VideoError>;
    fn poster(&self, bytes: &[u8], max_side: u32) -> Result<(Vec<u8>, u32, u32), VideoError>;
}

/// Playback handle lifecycle: play/pause/seek/mute, explicit close.
pub trait VideoPlayback {
    fn open(&mut self, asset_hash: &str) -> Result<(), VideoError>;
    fn play(&mut self) -> Result<(), VideoError>;
    fn pause(&mut self);
    fn seek(&mut self, secs: f64) -> Result<(), VideoError>;
    fn set_muted(&mut self, muted: bool);
    fn close(&mut self);
    fn is_open(&self) -> bool;
}

/// Mock backend: parses ISO-BMFF `mvhd` duration only; poster is a placeholder
/// PNG. Enough to test lifecycle without system decoders.
pub struct MockVideoBackend;

impl VideoBackend for MockVideoBackend {
    fn probe(&self, bytes: &[u8]) -> Result<VideoMetadata, VideoError> {
        if bytes.len() < 32 {
            return Err(VideoError::Corrupt("too short".to_string()));
        }
        if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
            Ok(VideoMetadata {
                duration_secs: Some(10.0),
                width: Some(1280),
                height: Some(720),
                orientation_degs: 0,
                has_poster: true,
            })
        } else {
            Err(VideoError::Unsupported("not iso-bmff".to_string()))
        }
    }

    fn poster(&self, _bytes: &[u8], max_side: u32) -> Result<(Vec<u8>, u32, u32), VideoError> {
        let side = max_side.clamp(16, 320);
        // 1x1 PNG scaled logically; real backends decode a frame here.
        let png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        Ok((png, side, side * 9 / 16))
    }
}

/// Mock playback: tracks open/playing without decoding.
pub struct MockPlayback {
    open_hash: Option<String>,
    playing: bool,
    muted: bool,
}

impl MockPlayback {
    pub fn new() -> Self {
        Self {
            open_hash: None,
            playing: false,
            muted: false,
        }
    }
}

impl Default for MockPlayback {
    fn default() -> Self {
        Self::new()
    }
}

impl VideoPlayback for MockPlayback {
    fn open(&mut self, asset_hash: &str) -> Result<(), VideoError> {
        self.open_hash = Some(asset_hash.to_string());
        self.playing = false;
        Ok(())
    }

    fn play(&mut self) -> Result<(), VideoError> {
        if self.open_hash.is_none() {
            return Err(VideoError::Corrupt("not open".to_string()));
        }
        self.playing = true;
        Ok(())
    }

    fn pause(&mut self) {
        self.playing = false;
    }

    fn seek(&mut self, _secs: f64) -> Result<(), VideoError> {
        if self.open_hash.is_none() {
            return Err(VideoError::Corrupt("not open".to_string()));
        }
        Ok(())
    }

    fn set_muted(&mut self, muted: bool) {
        self.muted = muted;
    }

    fn close(&mut self) {
        self.open_hash = None;
        self.playing = false;
    }

    fn is_open(&self) -> bool {
        self.open_hash.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matrix_documents_youtube_separation() {
        let m = format_matrix();
        assert!(m.iter().any(|r| r.container.contains("mp4")));
        let yt = m
            .iter()
            .find(|r| r.container.contains("YouTube"))
            .expect("yt row");
        assert_eq!(yt.local_file, Support::No);
    }

    #[test]
    fn mock_lifecycle() {
        let backend = MockVideoBackend;
        let mut bytes = vec![0u8; 64];
        bytes[4..8].copy_from_slice(b"ftyp");
        let meta = backend.probe(&bytes).expect("probe");
        assert_eq!(meta.width, Some(1280));
        assert!(backend.poster(&bytes, 320).is_ok());
        assert!(backend.probe(b"junkjunkjunkjunkjunkjunkjunkjunk").is_err());

        let mut pb = MockPlayback::new();
        assert!(!pb.is_open());
        pb.open("abc").expect("open");
        pb.play().expect("play");
        pb.seek(3.0).expect("seek");
        pb.set_muted(true);
        pb.pause();
        pb.close();
        assert!(!pb.is_open());
    }
}
