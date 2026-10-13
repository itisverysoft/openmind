//! Package + document manifests for `.canvaspkg/`.
//!
//! ```text
//! MyBoard.canvaspkg/
//!   manifest.json    BoardManifest (board id, schema, asset table)
//!   document.json    StableBoard (objects with stable ids, world coords)
//!   assets/<sha256>.<ext>
//!   thumbnails/<sha256>.png
//!   previews/<sha256>.json  (waveform peaks / poster metadata)
//! ```

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::asset::AssetRef;

/// On-disk schema version for the package format.
pub const PACKAGE_SCHEMA_VERSION: u32 = 2;
/// `.vsom` interchange stays at version 1 (see `vsom`).
pub const VSOM_SCHEMA_VERSION: i32 = 1;

/// One row of the asset table.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetEntry {
    #[serde(flatten)]
    pub asset: AssetRef,
}

/// Manifest stored as `manifest.json`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardManifest {
    pub board_id: String,
    pub title: String,
    pub schema_version: u32,
    pub created_at: f64,
    pub modified_at: f64,
    /// hash-hex → entry (dedup table).
    #[serde(default)]
    pub assets: BTreeMap<String, AssetEntry>,
    /// App metadata kept separate from user content.
    #[serde(default)]
    pub app: AppMetadata,
}

impl BoardManifest {
    pub fn new(board_id: String, title: String, now: f64) -> Self {
        Self {
            board_id,
            title,
            schema_version: PACKAGE_SCHEMA_VERSION,
            created_at: now,
            modified_at: now,
            assets: BTreeMap::new(),
            app: AppMetadata::default(),
        }
    }

    pub fn touch(&mut self, now: f64) {
        self.modified_at = now;
    }

    pub fn insert_asset(&mut self, asset: AssetRef) {
        self.assets.insert(asset.hash.clone(), AssetEntry { asset });
    }
}

/// Non-content app state (viewport, last tool, window). Never user objects.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppMetadata {
    #[serde(default)]
    pub viewport_x: Option<f64>,
    #[serde(default)]
    pub viewport_y: Option<f64>,
    #[serde(default)]
    pub viewport_scale: Option<f64>,
    #[serde(default)]
    pub last_tool: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_round_trips() {
        let mut m = BoardManifest::new("brd-1".to_string(), "T".to_string(), 1.0);
        m.app.viewport_scale = Some(2.0);
        let json = serde_json::to_string(&m).expect("encode");
        let back: BoardManifest = serde_json::from_str(&json).expect("decode");
        assert_eq!(m, back);
    }
}
