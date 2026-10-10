//! Whiteboard document model, mirroring the Swift app field for field.
//!
//! [`Board`] and [`CanvasItem`] are the `.vsom` wire structs *and* the
//! in-memory domain model for M1: one shape keeps encode/decode from
//! drifting. Later milestones may split persistence from the live scene.

use serde::{Deserialize, Serialize};

use crate::wire::{serde_base64, serde_base64_opt};

// ---------------------------------------------------------------------------
// Item kinds
// ---------------------------------------------------------------------------

/// All canvas item kinds (`ItemKind.swift`). Unknown strings from newer files
/// parse to `None` via [`ItemKind::parse`] instead of failing the decode —
/// the raw string is always preserved on the record.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ItemKind {
    Sticky,
    Text,
    Shape,
    Drawing,
    Image,
    Table,
    Note,
    Pdf,
    Audio,
    Youtube,
    Video,
}

impl ItemKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Sticky => "sticky",
            Self::Text => "text",
            Self::Shape => "shape",
            Self::Drawing => "drawing",
            Self::Image => "image",
            Self::Table => "table",
            Self::Note => "note",
            Self::Pdf => "pdf",
            Self::Audio => "audio",
            Self::Youtube => "youtube",
            Self::Video => "video",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "sticky" => Self::Sticky,
            "text" => Self::Text,
            "shape" => Self::Shape,
            "drawing" => Self::Drawing,
            "image" => Self::Image,
            "table" => Self::Table,
            "note" => Self::Note,
            "pdf" => Self::Pdf,
            "audio" => Self::Audio,
            "youtube" => Self::Youtube,
            "video" => Self::Video,
            _ => return None,
        })
    }

    /// Default frame size in world points (`ItemKind.defaultSize`).
    pub fn default_size(self) -> (f64, f64) {
        match self {
            Self::Sticky => (160.0, 160.0),
            Self::Text => (240.0, 60.0),
            Self::Shape => (180.0, 120.0),
            Self::Drawing => (200.0, 200.0),
            Self::Image => (280.0, 210.0),
            Self::Table => (360.0, 220.0),
            Self::Note => (48.0, 48.0),
            Self::Pdf => (420.0, 560.0),
            Self::Audio => (300.0, 110.0),
            Self::Youtube => (480.0, 300.0),
            Self::Video => (480.0, 300.0),
        }
    }

    pub fn default_font_size(self) -> f64 {
        match self {
            Self::Sticky => 18.0,
            Self::Text => 24.0,
            Self::Shape => 18.0,
            Self::Drawing => 18.0,
            Self::Image => 18.0,
            Self::Table => 14.0,
            Self::Note => 14.0,
            Self::Pdf => 18.0,
            Self::Audio => 14.0,
            Self::Youtube => 13.0,
            Self::Video => 13.0,
        }
    }
}

/// Shape variants (`ShapeKind.swift`, raw values verbatim).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ShapeKind {
    Rectangle,
    RoundedRectangle,
    Ellipse,
    Triangle,
    RightTriangle,
    Diamond,
    Pentagon,
    Hexagon,
    Circle,
    Star,
    Cloud,
    Line,
    Arrow,
    DoubleArrow,
    Capsule,
}

impl ShapeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Rectangle => "rectangle",
            Self::RoundedRectangle => "roundedRectangle",
            Self::Ellipse => "ellipse",
            Self::Triangle => "triangle",
            Self::RightTriangle => "rightTriangle",
            Self::Diamond => "diamond",
            Self::Pentagon => "pentagon",
            Self::Hexagon => "hexagon",
            Self::Circle => "circle",
            Self::Star => "star",
            Self::Cloud => "cloud",
            Self::Line => "line",
            Self::Arrow => "arrow",
            Self::DoubleArrow => "doubleArrow",
            Self::Capsule => "capsule",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "rectangle" => Self::Rectangle,
            "roundedRectangle" => Self::RoundedRectangle,
            "ellipse" => Self::Ellipse,
            "triangle" => Self::Triangle,
            "rightTriangle" => Self::RightTriangle,
            "diamond" => Self::Diamond,
            "pentagon" => Self::Pentagon,
            "hexagon" => Self::Hexagon,
            "circle" => Self::Circle,
            "star" => Self::Star,
            "cloud" => Self::Cloud,
            "line" => Self::Line,
            "arrow" => Self::Arrow,
            "doubleArrow" => Self::DoubleArrow,
            "capsule" => Self::Capsule,
            _ => return None,
        })
    }

    pub fn is_line_like(self) -> bool {
        matches!(self, Self::Line | Self::Arrow | Self::DoubleArrow)
    }
}

/// Freehand styles (`DrawingStyle.swift`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DrawingStyle {
    Pen,
    Highlighter,
    Line,
    Arrow,
}

impl DrawingStyle {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pen => "pen",
            Self::Highlighter => "highlighter",
            Self::Line => "line",
            Self::Arrow => "arrow",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "pen" => Self::Pen,
            "highlighter" => Self::Highlighter,
            "line" => Self::Line,
            "arrow" => Self::Arrow,
            _ => return None,
        })
    }

    pub fn default_line_width(self) -> f64 {
        match self {
            Self::Pen => 4.0,
            Self::Highlighter => 12.0,
            Self::Line => 4.0,
            Self::Arrow => 4.0,
        }
    }

    /// Highlighter ink is translucent; the rest are opaque.
    pub fn opacity(self) -> f64 {
        match self {
            Self::Highlighter => 0.45,
            Self::Pen | Self::Line | Self::Arrow => 1.0,
        }
    }

    pub fn is_straight(self) -> bool {
        matches!(self, Self::Line | Self::Arrow)
    }
}

// ---------------------------------------------------------------------------
// Records (Swift `Board` / `CanvasItem`, `.vsom` field order preserved)
// ---------------------------------------------------------------------------

/// A board (`Board.swift` + `VSOMBoard`). Dates are Swift reference-date
/// seconds (see [`crate::time`]).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Board {
    pub title: String,
    #[serde(rename = "createdAt")]
    pub created_at: f64,
    #[serde(rename = "modifiedAt")]
    pub modified_at: f64,
    #[serde(rename = "canvasSizeRaw")]
    pub canvas_size_raw: String,
    #[serde(rename = "canvasOrientationRaw")]
    pub canvas_orientation_raw: String,
    #[serde(rename = "canvasColorHex")]
    pub canvas_color_hex: String,
    #[serde(rename = "canvasPatternRaw")]
    pub canvas_pattern_raw: String,
    #[serde(rename = "customWidth")]
    pub custom_width: f64,
    #[serde(rename = "customHeight")]
    pub custom_height: f64,
    #[serde(rename = "pageCount")]
    pub page_count: i64,
}

/// One canvas item (`CanvasItem.swift` + `VSOMItem`).
///
/// Enum-typed fields stay raw strings on the wire so newer kinds never break
/// older readers; use [`ItemKind::parse`], [`ShapeKind::parse`],
/// [`DrawingStyle::parse`] for typed access.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CanvasItem {
    #[serde(rename = "kindRaw")]
    pub kind_raw: String,
    #[serde(rename = "shapeRaw")]
    pub shape_raw: String,
    #[serde(rename = "strokeStyleRaw")]
    pub stroke_style_raw: String,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    #[serde(rename = "pageIndex")]
    pub page_index: i64,
    pub text: String,
    #[serde(rename = "colorHex")]
    pub color_hex: String,
    #[serde(rename = "fontSize")]
    pub font_size: f64,
    #[serde(rename = "pointsData", with = "serde_base64")]
    #[serde(default)]
    pub points_data: Vec<u8>,
    #[serde(rename = "lineWidth")]
    pub line_width: f64,
    #[serde(rename = "richTextData", with = "serde_base64")]
    #[serde(default)]
    pub rich_text_data: Vec<u8>,
    #[serde(rename = "imageData", with = "serde_base64_opt")]
    #[serde(default)]
    pub image_data: Option<Vec<u8>>,
    #[serde(rename = "pdfData", with = "serde_base64_opt")]
    #[serde(default)]
    pub pdf_data: Option<Vec<u8>>,
    #[serde(rename = "pdfPage")]
    pub pdf_page: i64,
    #[serde(rename = "audioData", with = "serde_base64_opt")]
    #[serde(default)]
    pub audio_data: Option<Vec<u8>>,
    #[serde(rename = "audioFileName")]
    pub audio_file_name: String,
    #[serde(rename = "audioDuration")]
    pub audio_duration: f64,
    // Added after v1 items: absent keys decode leniently, like Swift.
    #[serde(rename = "youtubeURL")]
    #[serde(default)]
    pub youtube_url: String,
    #[serde(rename = "videoData", with = "serde_base64_opt")]
    #[serde(default)]
    pub video_data: Option<Vec<u8>>,
    #[serde(rename = "videoFileName")]
    #[serde(default)]
    pub video_file_name: String,
    #[serde(rename = "videoDuration")]
    #[serde(default)]
    pub video_duration: f64,
    #[serde(rename = "tableData", with = "serde_base64")]
    #[serde(default)]
    pub table_data: Vec<u8>,
    #[serde(rename = "zIndex")]
    pub z_index: f64,
    #[serde(rename = "isLocked")]
    pub is_locked: bool,
    #[serde(rename = "groupID")]
    #[serde(default)]
    pub group_id: Option<String>,
}

impl CanvasItem {
    pub fn kind(&self) -> Option<ItemKind> {
        ItemKind::parse(&self.kind_raw)
    }

    pub fn frame(&self) -> (f64, f64, f64, f64) {
        (self.x, self.y, self.width, self.height)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_round_trips_verbatim() {
        for raw in [
            "sticky", "text", "shape", "drawing", "image", "table", "note", "pdf", "audio",
            "youtube", "video",
        ] {
            let kind = ItemKind::parse(raw).expect("known kind");
            assert_eq!(kind.as_str(), raw);
        }
        assert_eq!(ItemKind::parse("hologram"), None);
    }

    #[test]
    fn shape_and_style_raw_values_match_swift() {
        assert_eq!(ShapeKind::RoundedRectangle.as_str(), "roundedRectangle");
        assert_eq!(ShapeKind::DoubleArrow.as_str(), "doubleArrow");
        assert!(ShapeKind::Arrow.is_line_like());
        assert!(!ShapeKind::Star.is_line_like());
        assert_eq!(DrawingStyle::Highlighter.opacity(), 0.45);
        assert_eq!(DrawingStyle::Pen.default_line_width(), 4.0);
        assert!(DrawingStyle::Line.is_straight());
    }
}
