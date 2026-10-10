//! `.vsom` board files: decode, validate, encode.
//!
//! Byte-compatible with the Swift app (`BoardExport.swift`): the same JSON
//! shape, base64 `Data`, reference-date `Date`s. Decoders reject unknown
//! formats/versions loudly instead of importing half-understood boards.

use serde::{Deserialize, Serialize};
use std::fmt;

use crate::model::{Board, CanvasItem};

/// Expected `format` field (`VSOM.formatID`).
pub const VSOM_FORMAT_ID: &str = "openmind-board";
/// Only supported `version` (`VSOM.version`).
pub const VSOM_VERSION: i32 = 1;

/// Failure to read a `.vsom` file (mirrors `VSOMError`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VsomError {
    NotABoardFile,
    UnsupportedVersion(i32),
    Corrupt(String),
}

impl fmt::Display for VsomError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotABoardFile => write!(f, "not an OpenMind board file"),
            Self::UnsupportedVersion(v) => write!(f, "unsupported board version {v}"),
            Self::Corrupt(msg) => write!(f, "corrupt board file: {msg}"),
        }
    }
}

impl std::error::Error for VsomError {}

/// Versioned on-disk form of one board.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct VsomDocument {
    pub format: String,
    pub version: i32,
    pub board: Board,
    pub items: Vec<CanvasItem>,
}

impl VsomDocument {
    /// Decode + validate `.vsom` bytes.
    pub fn decode(bytes: &[u8]) -> Result<Self, VsomError> {
        let doc: Self = serde_json::from_slice(bytes).map_err(|_| VsomError::NotABoardFile)?;
        if doc.format != VSOM_FORMAT_ID {
            return Err(VsomError::NotABoardFile);
        }
        if doc.version != VSOM_VERSION {
            return Err(VsomError::UnsupportedVersion(doc.version));
        }
        Ok(doc)
    }

    /// Encode to `.vsom` bytes (canonical JSON, like the Swift exporter).
    pub fn encode(&self) -> Result<Vec<u8>, VsomError> {
        serde_json::to_vec(self).map_err(|e| VsomError::Corrupt(e.to_string()))
    }

    /// Items the canvas shows (trashed state is not persisted; every stored
    /// item here is visible, matching the Swift exporter's filter).
    pub fn visible_items(&self) -> &[CanvasItem] {
        &self.items
    }
}
