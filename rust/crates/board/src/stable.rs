//! Stable board document: the editing model for `.canvaspkg/document.json`.
//!
//! Unlike `.vsom` (Swift-compatible, id-less), every object here has a stable
//! [`ObjectId`], geometry is in board/world coordinates, and media are
//! [`AssetRef`]s. Conversion to/from `.vsom` lives in `canvas::vsom` so the
//! wire stays byte-compatible.

use serde::{Deserialize, Serialize};

use crate::asset::AssetRef;
use crate::id::{BoardId, ObjectId};

/// Canvas background + grid style.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Background {
    Plain,
    Dots,
    Grid,
    Lines,
    Columns,
    Graph,
}

impl Background {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Plain => "plain",
            Self::Dots => "dots",
            Self::Grid => "grid",
            Self::Lines => "lines",
            Self::Columns => "columns",
            Self::Graph => "graph",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "plain" => Self::Plain,
            "dots" => Self::Dots,
            "grid" => Self::Grid,
            "lines" => Self::Lines,
            "columns" => Self::Columns,
            "graph" => Self::Graph,
            _ => return None,
        })
    }
}

/// World-space transform shared by all objects.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Transform {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// Degrees clockwise. 0 when axis-aligned.
    #[serde(default)]
    pub rotation_degs: f64,
    #[serde(default)]
    pub opacity: Option<f64>,
}

impl Transform {
    pub fn rect(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self {
            x,
            y,
            width: w,
            height: h,
            rotation_degs: 0.0,
            opacity: None,
        }
    }

    pub fn bounds(&self) -> (f64, f64, f64, f64) {
        (self.x, self.y, self.width, self.height)
    }
}

/// All board object kinds. Content fields are per-type; common fields
/// (id/transform/z/lock/group) live on [`BoardObject`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum BoardObjectKind {
    StickyNote {
        text: String,
        color_hex: String,
        font_size: f64,
    },
    RichText {
        #[serde(default)]
        doc: serde_json::Value,
    },
    Shape {
        shape_raw: String,
        color_hex: String,
        label: String,
        font_size: f64,
    },
    Drawing {
        stroke_style_raw: String,
        color_hex: String,
        line_width: f64,
        #[serde(with = "crate::wire::serde_base64")]
        #[serde(default)]
        points_data: Vec<u8>,
    },
    Connector {
        from: String,
        to: String,
        #[serde(default)]
        from_anchor: Option<String>,
        #[serde(default)]
        to_anchor: Option<String>,
        #[serde(default)]
        label: String,
    },
    Table {
        #[serde(with = "crate::wire::serde_base64")]
        #[serde(default)]
        table_data: Vec<u8>,
        #[serde(default)]
        rows: u32,
        #[serde(default)]
        cols: u32,
    },
    Image {
        asset: AssetRef,
    },
    Audio {
        asset: AssetRef,
        #[serde(default)]
        title: String,
    },
    Video {
        asset: AssetRef,
        #[serde(default)]
        title: String,
    },
    Youtube {
        video_id: String,
        #[serde(default)]
        title: String,
    },
    PdfPage {
        asset: AssetRef,
        #[serde(default)]
        page: i64,
    },
    /// Unknown future kinds: preserved opaque, never dropped.
    #[serde(other)]
    Unknown,
}

/// One object: stable id + world transform + z/lock/group + typed content.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BoardObject {
    pub id: String,
    pub transform: Transform,
    pub z_index: f64,
    #[serde(default)]
    pub locked: bool,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub group_id: Option<String>,
    #[serde(default)]
    pub parent_id: Option<String>,
    #[serde(default)]
    pub page_index: i64,
    #[serde(flatten)]
    pub kind: BoardObjectKind,
}

impl BoardObject {
    pub fn new(id: ObjectId, transform: Transform, z: f64, kind: BoardObjectKind) -> Self {
        Self {
            id: id.0,
            transform,
            z_index: z,
            locked: false,
            hidden: false,
            group_id: None,
            parent_id: None,
            page_index: 0,
            kind,
        }
    }
}

/// The versioned editing document.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StableBoard {
    pub board_id: String,
    pub title: String,
    pub schema_version: u32,
    pub created_at: f64,
    pub modified_at: f64,
    #[serde(default)]
    pub background: Option<String>,
    #[serde(default)]
    pub objects: Vec<BoardObject>,
    #[serde(default)]
    pub viewport: Option<ViewportState>,
}

impl StableBoard {
    pub fn new(board_id: BoardId, title: String, now: f64) -> Self {
        Self {
            board_id: board_id.0,
            title,
            schema_version: crate::manifest::PACKAGE_SCHEMA_VERSION,
            created_at: now,
            modified_at: now,
            background: Some("dots".to_string()),
            objects: Vec::new(),
            viewport: None,
        }
    }

    pub fn find(&self, id: &str) -> Option<&BoardObject> {
        self.objects.iter().find(|o| o.id == id)
    }
}

/// Persisted camera (optional; app metadata may also hold it).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ViewportState {
    pub x: f64,
    pub y: f64,
    pub scale: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_kinds_survive_as_opaque() {
        // Future `{ "type": "hologram" }` must not fail decode.
        let json = serde_json::json!({
            "id": "obj-1",
            "transform": {"x":0.0,"y":0.0,"width":10.0,"height":10.0},
            "zIndex": 1.0,
            "type": "hologram",
        });
        let obj: BoardObject = serde_json::from_value(json).expect("decode");
        assert!(matches!(obj.kind, BoardObjectKind::Unknown));
        let back = serde_json::to_value(&obj).expect("encode");
        assert_eq!(back["type"], serde_json::json!("unknown"));
    }

    #[test]
    fn connector_keeps_endpoint_ids() {
        let obj = BoardObject::new(
            ObjectId::generate(),
            Transform::rect(0.0, 0.0, 10.0, 10.0),
            1.0,
            BoardObjectKind::Connector {
                from: "obj-a".to_string(),
                to: "obj-b".to_string(),
                from_anchor: Some("east".to_string()),
                to_anchor: Some("west".to_string()),
                label: String::new(),
            },
        );
        let json = serde_json::to_string(&obj).expect("encode");
        let back: BoardObject = serde_json::from_str(&json).expect("decode");
        assert_eq!(obj, back);
    }
}
