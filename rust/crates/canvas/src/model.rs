//! Items, ids, frames, content.

use std::sync::atomic::{AtomicU64, Ordering};

use openmind_board::{DrawingStyle, ShapeKind};
use openmind_ink::Stroke;

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// Stable item identity, serialized as the `.vsom` `groupID`-style UUID
/// string. Fresh ids are process-unique (`rst-…`, UUID-shaped); ids read
/// from files keep their original strings verbatim.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ItemId(pub String);

/// Mint a fresh item id.
pub fn id() -> ItemId {
    let n = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let a = nanos ^ n.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    let b = n ^ 0xBF58_476D_1CE4_E5B9;
    ItemId(format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        (a >> 32) as u32,
        (a >> 16) as u16,
        a as u16,
        (b >> 48) as u16,
        b & 0xFFFF_FFFF_FFFF,
    ))
}

/// World-space frame (top-left origin).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self { x, y, w, h }
    }

    pub fn contains_point(self, x: f64, y: f64) -> bool {
        x >= self.x && x <= self.x + self.w && y >= self.y && y <= self.y + self.h
    }

    pub fn intersects(self, other: Rect) -> bool {
        self.x < other.x + other.w
            && other.x < self.x + self.w
            && self.y < other.y + other.h
            && other.y < self.y + self.h
    }

    pub fn union(self, other: Rect) -> Rect {
        let x0 = self.x.min(other.x);
        let y0 = self.y.min(other.y);
        let x1 = (self.x + self.w).max(other.x + other.w);
        let y1 = (self.y + self.h).max(other.y + other.h);
        Rect::new(x0, y0, x1 - x0, y1 - y0)
    }
}

/// One finished ink stroke with its paint.
#[derive(Clone, Debug)]
pub struct PaintedInk {
    pub stroke: Stroke,
    pub style_raw: String,
    pub color_hex: String,
    pub line_width: f64,
}

impl PaintedInk {
    pub fn style(&self) -> DrawingStyle {
        DrawingStyle::parse(&self.style_raw).unwrap_or(DrawingStyle::Pen)
    }
}

/// Typed item content. Every variant maps to a `.vsom` kind (see `vsom`).
#[derive(Clone, Debug)]
pub enum ItemContent {
    Shape {
        shape: ShapeKind,
        color_hex: String,
        label: String,
        font_size: f64,
    },
    Sticky {
        text: String,
        color_hex: String,
        font_size: f64,
    },
    Text {
        text: String,
        color_hex: String,
        font_size: f64,
    },
    /// Structured rich text (display via text stack; editing overlay commits
    /// bursts). Plain `Text` stays for legacy `.vsom` records.
    RichText {
        doc: openmind_text::RichTextDoc,
    },
    Drawing {
        strokes: Vec<PaintedInk>,
    },
    Image {
        bytes: Vec<u8>,
        pixel_w: u32,
        pixel_h: u32,
    },
    /// Lightweight media refs (hash + metadata, never decoded bytes in the
    /// item). The package `assets/` dir holds the bytes; `.vsom` foreign
    /// records carry them for Swift compat until promoted.
    Audio {
        title: String,
        asset_hash: String,
        file_name: String,
        duration_secs: f64,
    },
    Video {
        title: String,
        asset_hash: String,
        file_name: String,
        duration_secs: f64,
    },
    Youtube {
        video_id: String,
        title: String,
    },
    Pdf {
        asset_hash: String,
        file_name: String,
        page: i64,
    },
    /// Attached connector: endpoint ids + anchors stay attached on move.
    Connector {
        from: String,
        to: String,
        from_anchor: Option<String>,
        to_anchor: Option<String>,
        label: String,
    },
    /// Simple grid table (cells as plain strings; rich formatting deferred).
    Table {
        rows: usize,
        cols: usize,
        cells: Vec<Vec<String>>,
    },
}

/// One canvas item. `items` in [`crate::CanvasDoc`] stay sorted by `z`.
#[derive(Clone, Debug)]
pub struct CanvasItem {
    pub id: ItemId,
    pub kind_raw: String,
    pub frame: Rect,
    pub z: f64,
    pub locked: bool,
    pub group: Option<String>,
    pub page: i64,
    pub content: ItemContent,
}

impl CanvasItem {
    pub fn shape(shape: ShapeKind, frame: Rect, color_hex: &str, z: f64) -> Self {
        Self {
            id: id(),
            kind_raw: "shape".to_string(),
            frame,
            z,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Shape {
                shape,
                color_hex: color_hex.to_string(),
                label: String::new(),
                font_size: 18.0,
            },
        }
    }

    pub fn sticky(frame: Rect, color_hex: &str, z: f64) -> Self {
        Self {
            id: id(),
            kind_raw: "sticky".to_string(),
            frame,
            z,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Sticky {
                text: String::new(),
                color_hex: color_hex.to_string(),
                font_size: 18.0,
            },
        }
    }

    pub fn drawing(frame: Rect, z: f64) -> Self {
        Self {
            id: id(),
            kind_raw: "drawing".to_string(),
            frame,
            z,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Drawing {
                strokes: Vec::new(),
            },
        }
    }

    /// Image item from raw bytes, aspect-fit inside `max_side` world points
    /// (never smaller than 60 on the long edge, like the Swift importer).
    /// `None` when the bytes are not a readable image.
    pub fn image_from_bytes(bytes: Vec<u8>, at: (f64, f64), max_side: f64) -> Option<Self> {
        let (pw, ph) = image::load_from_memory(&bytes)
            .map(|i| (i.width(), i.height()))
            .ok()?;
        if pw == 0 || ph == 0 {
            return None;
        }
        let longest = pw.max(ph) as f64;
        let scale = (max_side / longest).min(1.0);
        let mut w = (pw as f64 * scale).max(60.0);
        let mut h = (ph as f64 * scale).max(60.0);
        // Keep aspect when one side clamped (mirrors fittedWorldSize).
        if w == 60.0 && h != 60.0 {
            h = 60.0 * ph as f64 / pw as f64;
        } else if h == 60.0 && w != 60.0 {
            w = 60.0 * pw as f64 / ph as f64;
        }
        Some(Self {
            id: id(),
            kind_raw: "image".to_string(),
            frame: Rect::new(at.0 - w / 2.0, at.1 - h / 2.0, w, h),
            z: 0.0,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Image {
                bytes,
                pixel_w: pw,
                pixel_h: ph,
            },
        })
    }

    pub fn text(frame: Rect, z: f64) -> Self {
        Self {
            id: id(),
            kind_raw: "text".to_string(),
            frame,
            z,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Text {
                text: String::new(),
                // Rendered near-black here; preserved verbatim in `.vsom`.
                color_hex: "000000".to_string(),
                font_size: 24.0,
            },
        }
    }

    pub fn rich_text(frame: Rect, z: f64, doc: openmind_text::RichTextDoc) -> Self {
        Self {
            id: id(),
            kind_raw: "text".to_string(),
            frame,
            z,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::RichText { doc },
        }
    }

    pub fn connector(frame: Rect, z: f64, from: &ItemId, to: &ItemId) -> Self {
        Self {
            id: id(),
            kind_raw: "shape".to_string(),
            frame,
            z,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Connector {
                from: from.0.clone(),
                to: to.0.clone(),
                from_anchor: None,
                to_anchor: None,
                label: String::new(),
            },
        }
    }

    pub fn table(frame: Rect, z: f64, rows: usize, cols: usize) -> Self {
        let rows = rows.clamp(1, 32);
        let cols = cols.clamp(1, 16);
        Self {
            id: id(),
            kind_raw: "table".to_string(),
            frame,
            z,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Table {
                rows,
                cols,
                cells: vec![vec![String::new(); cols]; rows],
            },
        }
    }

    pub fn audio_card(frame: Rect, z: f64, title: String, asset_hash: String) -> Self {
        Self {
            id: id(),
            kind_raw: "audio".to_string(),
            frame,
            z,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Audio {
                title,
                asset_hash,
                file_name: String::new(),
                duration_secs: 0.0,
            },
        }
    }

    pub fn video_card(frame: Rect, z: f64, title: String, asset_hash: String) -> Self {
        Self {
            id: id(),
            kind_raw: "video".to_string(),
            frame,
            z,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Video {
                title,
                asset_hash,
                file_name: String::new(),
                duration_secs: 0.0,
            },
        }
    }

    pub fn youtube_card(frame: Rect, z: f64, video_id: String) -> Self {
        Self {
            id: id(),
            kind_raw: "youtube".to_string(),
            frame,
            z,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Youtube {
                video_id,
                title: String::new(),
            },
        }
    }

    /// Plain-text view of any textual content (display + export).
    pub fn display_text(&self) -> Option<String> {
        match &self.content {
            ItemContent::Sticky { text, .. } | ItemContent::Text { text, .. } => Some(text.clone()),
            ItemContent::Shape { label, .. } => Some(label.clone()),
            ItemContent::RichText { doc } => Some(doc.plain_text()),
            ItemContent::Connector { label, .. } => Some(label.clone()),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique_and_uuid_shaped() {
        let a = id().0;
        let b = id().0;
        assert_ne!(a, b);
        assert_eq!(a.len(), 36);
        assert_eq!(a.chars().filter(|c| *c == '-').count(), 4);
    }

    #[test]
    fn rect_predicates() {
        let r = Rect::new(10.0, 10.0, 20.0, 20.0);
        assert!(r.contains_point(10.0, 10.0));
        assert!(r.contains_point(30.0, 30.0));
        assert!(!r.contains_point(31.0, 30.0));
        assert!(r.intersects(Rect::new(25.0, 25.0, 20.0, 20.0)));
        assert!(!r.intersects(Rect::new(31.0, 31.0, 5.0, 5.0)));
        assert_eq!(
            r.union(Rect::new(0.0, 0.0, 5.0, 5.0)),
            Rect::new(0.0, 0.0, 30.0, 30.0)
        );
    }
}
