//! OpenMind whiteboard document model and `.vsom` board files.
//!
//! The structs here mirror the Swift app (`OpenMind/Models/*`,
//! `OpenMind/Utilities/BoardExport.swift`) **field for field**, so boards
//! saved by either implementation open in the other:
//!
//! * `Data` blobs are base64 strings (Swift `JSONEncoder` default).
//! * `Date`s are JSON numbers: seconds since 2001-01-01T00:00:00Z (Swift
//!   `JSONEncoder` `.deferredToDate` default). See [`time`].
//! * Integer fields are `i64`; dimensions are `f64`.
//! * `youtube_url`, `video_file_name`, `video_duration` (added after v1
//!   items) and `group_id` decode leniently when absent.
//!
//! Opaque blobs (`points_data`, `rich_text_data`, `table_data`, media bytes)
//! are preserved verbatim; their inner formats are decoded by later crates
//! (`ink` already reads stroke `points_data`).

#![forbid(unsafe_code)]

pub mod asset;
pub mod id;
pub mod manifest;
pub mod migrate;
pub mod model;
pub mod package;
pub mod settings;
pub mod stable;
pub mod time;
pub mod validate;
pub mod vsom;
pub mod wire;

pub use asset::{hash_bytes, kind_for, sniff_mime, AssetKind, AssetRef};
pub use id::{BoardId, ObjectId};
pub use manifest::{AppMetadata, BoardManifest, PACKAGE_SCHEMA_VERSION, VSOM_SCHEMA_VERSION};
pub use model::{Board, CanvasItem, DrawingStyle, ItemKind, ShapeKind};
pub use settings::{CanvasMetrics, CanvasOrientation, CanvasPattern, CanvasSizePreset, Viewport};
pub use stable::{Background, BoardObject, BoardObjectKind, StableBoard, Transform, ViewportState};
pub use time::{swift_now, swift_to_unix, unix_to_swift};
pub use validate::{validate_asset_path, validate_board, Limits, ValidationError};
pub use vsom::{VsomDocument, VsomError, VSOM_FORMAT_ID, VSOM_VERSION};
