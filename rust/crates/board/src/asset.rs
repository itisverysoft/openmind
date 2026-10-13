//! Lightweight media references.
//!
//! Core design rule: canvas objects store [`AssetRef`] (hash + metadata), not
//! decoded frames/bitmaps/PCM. Bytes live in the package `assets/` dir keyed
//! by content hash; objects only point at them.

use serde::{Deserialize, Serialize};

/// What the bytes are. Kept as a string on the wire for forward compat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AssetKind {
    Image,
    Audio,
    Video,
    Pdf,
    Other,
}

impl AssetKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Image => "image",
            Self::Audio => "audio",
            Self::Video => "video",
            Self::Pdf => "pdf",
            Self::Other => "other",
        }
    }

    pub fn parse(raw: &str) -> Self {
        match raw {
            "image" => Self::Image,
            "audio" => Self::Audio,
            "video" => Self::Video,
            "pdf" => Self::Pdf,
            _ => Self::Other,
        }
    }

    /// Expected file-name extensions (lowercase, without dot).
    pub fn extensions(self) -> &'static [&'static str] {
        match self {
            Self::Image => &["png", "jpg", "jpeg", "gif", "webp", "svg"],
            Self::Audio => &["wav", "mp3", "m4a", "aac", "ogg", "flac"],
            Self::Video => &["mp4", "m4v", "mov", "webm"],
            Self::Pdf => &["pdf"],
            Self::Other => &[],
        }
    }
}

/// A content-addressed reference to bytes in `assets/<hash>.<ext>`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetRef {
    /// Hex SHA-256 of the bytes (streamed at import; dedup key).
    pub hash: String,
    pub kind: AssetKind,
    /// MIME sniffed from magic bytes, not just the extension.
    pub mime: String,
    pub byte_size: u64,
    pub original_filename: String,
    /// Relative package path, always `assets/<hash>.<ext>`.
    pub path: String,
    /// Known dimensions / duration where applicable.
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub duration_secs: Option<f64>,
    /// Content-hash of generated thumbnail/waveform/poster, if any.
    pub preview_hash: Option<String>,
}

impl AssetRef {
    pub fn file_name(&self) -> String {
        self.path
            .rsplit('/')
            .next()
            .unwrap_or(&self.path)
            .to_string()
    }
}

/// Hex SHA-256 of bytes (streamed by callers for large files; this helper is
/// for small in-memory blobs and tests).
pub fn hash_bytes(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(bytes);
    hex::encode(h.finalize())
}

/// Minimal hex encoder (avoids another dependency).
mod hex {
    pub fn encode(bytes: impl AsRef<[u8]>) -> String {
        const LUT: &[u8; 16] = b"0123456789abcdef";
        let bytes = bytes.as_ref();
        let mut out = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            out.push(LUT[(b >> 4) as usize] as char);
            out.push(LUT[(b & 0x0F) as usize] as char);
        }
        out
    }
}

/// Sniff MIME from magic bytes. Extension alone is not trustworthy.
pub fn sniff_mime(bytes: &[u8]) -> &'static str {
    if bytes.len() >= 8 && &bytes[0..8] == b"\x89PNG\r\n\x1a\n" {
        "image/png"
    } else if bytes.len() >= 3 && &bytes[0..3] == b"\xff\xd8\xff" {
        "image/jpeg"
    } else if bytes.len() >= 6 && (&bytes[0..6] == b"GIF87a" || &bytes[0..6] == b"GIF89a") {
        "image/gif"
    } else if bytes.len() >= 4 && &bytes[0..4] == b"RIFF" {
        "audio/wav"
    } else if bytes.len() >= 4 && &bytes[0..4] == b"OggS" {
        "audio/ogg"
    } else if bytes.len() >= 4 && &bytes[0..4] == b"%PDF" {
        "application/pdf"
    } else if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        // MP4/M4A/MOV ISO-BMFF.
        "video/mp4"
    } else if bytes.len() >= 4 && &bytes[0..4] == b"ID3" {
        "audio/mpeg"
    } else {
        "application/octet-stream"
    }
}

/// Infer [`AssetKind`] from MIME + filename extension.
pub fn kind_for(mime: &str, filename: &str) -> AssetKind {
    if mime.starts_with("image/") {
        return AssetKind::Image;
    }
    if mime.starts_with("audio/") {
        return AssetKind::Audio;
    }
    if mime.starts_with("video/") {
        return AssetKind::Video;
    }
    if mime == "application/pdf" {
        return AssetKind::Pdf;
    }
    let ext = filename
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    for kind in [
        AssetKind::Image,
        AssetKind::Audio,
        AssetKind::Video,
        AssetKind::Pdf,
    ] {
        if kind.extensions().contains(&ext.as_str()) {
            return kind;
        }
    }
    AssetKind::Other
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_is_stable_hex() {
        let h = hash_bytes(b"hello");
        assert_eq!(
            h,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn sniffing_beats_extension() {
        assert_eq!(sniff_mime(b"\x89PNG\r\n\x1a\nrest"), "image/png");
        assert_eq!(sniff_mime(b"%PDF-1.7"), "application/pdf");
        assert_eq!(sniff_mime(b"junk"), "application/octet-stream");
        assert_eq!(kind_for("image/png", "x.bin"), AssetKind::Image);
        assert_eq!(
            kind_for("application/octet-stream", "song.mp3"),
            AssetKind::Audio
        );
    }
}
