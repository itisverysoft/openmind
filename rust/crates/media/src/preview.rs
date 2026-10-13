//! Async preview requests: thumbnails, waveforms, posters.
//!
//! The UI enqueues a [`PreviewRequest`]; a worker fulfills it and replies with
//! small bytes through a channel. Generation ids let the UI drop stale
//! results for deleted/replaced objects.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PreviewKind {
    Thumbnail,
    Waveform,
    Poster,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviewSize {
    pub width: u32,
    pub height: u32,
}

impl PreviewSize {
    pub fn thumb(size: u32) -> Self {
        Self {
            width: size,
            height: size,
        }
    }
}

/// One unit of background work. `generation` is bumped whenever the source
/// object changes; stale completions are discarded.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreviewRequest {
    pub asset_hash: String,
    pub kind: PreviewKind,
    pub size: PreviewSize,
    pub generation: u64,
}

impl PreviewRequest {
    pub fn is_stale(&self, current_generation: u64) -> bool {
        self.generation != current_generation
    }
}

/// Bounded preview cache key (hash + kind + size + algorithm version).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct PreviewKey {
    pub asset_hash: String,
    pub kind: PreviewKind,
    pub size: PreviewSize,
    pub algo_version: u32,
}

impl PreviewKey {
    pub const WAVEFORM_ALGO: u32 = 1;
    pub const THUMB_ALGO: u32 = 1;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_generations_are_dropped() {
        let req = PreviewRequest {
            asset_hash: "ab".to_string(),
            kind: PreviewKind::Thumbnail,
            size: PreviewSize::thumb(128),
            generation: 3,
        };
        assert!(!req.is_stale(3));
        assert!(req.is_stale(4));
    }
}
