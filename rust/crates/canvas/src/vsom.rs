//! `.vsom` mapping: canvas items ↔ board records.
//!
//! Export mirrors the Swift exporter (visible items sorted by `z`); import
//! rebuilds native items for the kinds this build edits and carries
//! everything else (other kinds, other pages, unparseable blobs) in
//! [`CanvasDoc::foreign`] so a save never drops user data.
//!
//! `.vsom` records carry no item ids, so imports mint fresh ones; group,
//! lock, `z`, and page survive verbatim.

use openmind_board::{
    swift_now, CanvasItem as BoardItem, DrawingStyle, ItemKind, ShapeKind, VsomDocument,
};
use openmind_ink::{InkConfig, InkPoint, StrokeBuilder};

use crate::doc::CanvasDoc;
use crate::model::{CanvasItem, ItemContent, PaintedInk, Rect};

fn board_item_base(item: &CanvasItem) -> BoardItem {
    BoardItem {
        kind_raw: item.kind_raw.clone(),
        shape_raw: "rectangle".to_string(),
        stroke_style_raw: "pen".to_string(),
        x: item.frame.x,
        y: item.frame.y,
        width: item.frame.w,
        height: item.frame.h,
        page_index: item.page,
        text: String::new(),
        color_hex: "FFF1A8".to_string(),
        font_size: 18.0,
        points_data: Vec::new(),
        line_width: 4.0,
        rich_text_data: Vec::new(),
        image_data: None,
        pdf_data: None,
        pdf_page: 0,
        audio_data: None,
        audio_file_name: String::new(),
        audio_duration: 0.0,
        youtube_url: String::new(),
        video_data: None,
        video_file_name: String::new(),
        video_duration: 0.0,
        table_data: Vec::new(),
        z_index: item.z,
        is_locked: item.locked,
        group_id: item.group.clone(),
    }
}

/// Frame + relative points for one stroke, mirroring `adoptStroke`:
/// pad by half the nib, floor the frame at 4pt. Lock/group/page ride along
/// from the owning item.
fn stroke_record(stroke: &PaintedInk, item: &CanvasItem) -> BoardItem {
    let pad = stroke.line_width / 2.0 + 2.0;
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for s in &stroke.stroke.spine {
        min_x = min_x.min(s.x);
        min_y = min_y.min(s.y);
        max_x = max_x.max(s.x);
        max_y = max_y.max(s.y);
    }
    let (ox, oy) = if min_x.is_finite() {
        (min_x - pad, min_y - pad)
    } else {
        (0.0, 0.0)
    };
    let w = if min_x.is_finite() {
        (max_x - min_x + pad * 2.0).max(4.0)
    } else {
        4.0
    };
    let h = if min_x.is_finite() {
        (max_y - min_y + pad * 2.0).max(4.0)
    } else {
        4.0
    };
    let pairs: Vec<[f64; 2]> = stroke
        .stroke
        .spine
        .iter()
        .map(|s| [s.x - ox, s.y - oy])
        .collect();
    BoardItem {
        kind_raw: "drawing".to_string(),
        shape_raw: "rectangle".to_string(),
        stroke_style_raw: stroke.style_raw.clone(),
        x: ox,
        y: oy,
        width: w,
        height: h,
        page_index: item.page,
        text: String::new(),
        color_hex: stroke.color_hex.clone(),
        font_size: 18.0,
        points_data: serde_json::to_vec(&pairs).unwrap_or_default(),
        line_width: stroke.line_width,
        rich_text_data: Vec::new(),
        image_data: None,
        pdf_data: None,
        pdf_page: 0,
        audio_data: None,
        audio_file_name: String::new(),
        audio_duration: 0.0,
        youtube_url: String::new(),
        video_data: None,
        video_file_name: String::new(),
        video_duration: 0.0,
        table_data: Vec::new(),
        z_index: item.z,
        is_locked: item.locked,
        group_id: item.group.clone(),
    }
}

fn native_record(item: &CanvasItem) -> Vec<BoardItem> {
    let mut base = board_item_base(item);
    match &item.content {
        ItemContent::Shape {
            shape,
            color_hex,
            label,
            font_size,
        } => {
            base.shape_raw = shape.as_str().to_string();
            base.text = label.clone();
            base.color_hex = color_hex.clone();
            base.font_size = *font_size;
            vec![base]
        }
        ItemContent::Sticky {
            text,
            color_hex,
            font_size,
        } => {
            base.text = text.clone();
            base.color_hex = color_hex.clone();
            base.font_size = *font_size;
            vec![base]
        }
        ItemContent::Text {
            text,
            color_hex,
            font_size,
        } => {
            base.text = text.clone();
            base.color_hex = color_hex.clone();
            base.font_size = *font_size;
            vec![base]
        }
        // One record per stroke: Swift drawing items hold a single stroke.
        ItemContent::Drawing { strokes } => {
            strokes.iter().map(|s| stroke_record(s, item)).collect()
        }
        ItemContent::Image { bytes, .. } => {
            base.image_data = Some(bytes.clone());
            base.font_size = 18.0;
            vec![base]
        }
    }
}

impl CanvasDoc {
    /// Export to a `.vsom` document (native items by `z`, then foreign).
    pub fn to_vsom_document(&self, title: &str) -> VsomDocument {
        let mut records: Vec<BoardItem> = Vec::new();
        for item in &self.items {
            records.extend(native_record(item));
        }
        records.extend(self.foreign.iter().cloned());
        let now = swift_now();
        VsomDocument {
            format: openmind_board::VSOM_FORMAT_ID.to_string(),
            version: openmind_board::VSOM_VERSION,
            board: openmind_board::Board {
                title: title.to_string(),
                created_at: now,
                modified_at: now,
                canvas_size_raw: "infinite".to_string(),
                canvas_orientation_raw: "portrait".to_string(),
                canvas_color_hex: "FFFFFF".to_string(),
                canvas_pattern_raw: "dots".to_string(),
                custom_width: 595.0,
                custom_height: 842.0,
                page_count: 1,
            },
            items: records,
        }
    }

    /// Import: known page-0 kinds become native items (fresh ids);
    /// anything else rides along as foreign.
    pub fn from_vsom_document(doc: &VsomDocument) -> Self {
        let mut canvas = CanvasDoc::new();
        let mut max_z: f64 = 0.0;
        for record in &doc.items {
            max_z = max_z.max(record.z_index);
            let kind = ItemKind::parse(&record.kind_raw);
            let native = record.page_index == 0
                && matches!(
                    kind,
                    Some(
                        ItemKind::Shape
                            | ItemKind::Sticky
                            | ItemKind::Text
                            | ItemKind::Drawing
                            | ItemKind::Image
                    )
                );
            if !native {
                canvas.foreign.push(record.clone());
                continue;
            }
            match import_native(record) {
                Some(item) => canvas.items.push(item),
                None => canvas.foreign.push(record.clone()),
            }
        }
        canvas.items.sort_by(|a, b| a.z.total_cmp(&b.z));
        canvas.next_z = max_z + 1.0;
        canvas
    }
}

fn import_native(record: &BoardItem) -> Option<CanvasItem> {
    let frame = Rect::new(record.x, record.y, record.width, record.height);
    let base = CanvasItem {
        id: crate::model::id(),
        kind_raw: record.kind_raw.clone(),
        frame,
        z: record.z_index,
        locked: record.is_locked,
        group: record.group_id.clone(),
        page: 0,
        content: ItemContent::Text {
            text: String::new(),
            color_hex: String::new(),
            font_size: 18.0,
        },
    };
    let content = match ItemKind::parse(&record.kind_raw) {
        Some(ItemKind::Shape) => {
            let shape = ShapeKind::parse(&record.shape_raw)?;
            ItemContent::Shape {
                shape,
                color_hex: record.color_hex.clone(),
                label: record.text.clone(),
                font_size: record.font_size,
            }
        }
        Some(ItemKind::Sticky) => ItemContent::Sticky {
            text: record.text.clone(),
            color_hex: record.color_hex.clone(),
            font_size: record.font_size,
        },
        Some(ItemKind::Text) => ItemContent::Text {
            text: record.text.clone(),
            color_hex: record.color_hex.clone(),
            font_size: record.font_size,
        },
        Some(ItemKind::Drawing) => {
            let pts = openmind_ink::codec::decode_points(&record.points_data);
            if pts.is_empty() {
                return None;
            }
            let style = DrawingStyle::parse(&record.stroke_style_raw).unwrap_or(DrawingStyle::Pen);
            let cfg = InkConfig {
                max_width: record.line_width.max(1.0),
                ..InkConfig::default()
            };
            let mut builder = StrokeBuilder::new(cfg, ink_tool(style));
            for (i, (x, y)) in pts.iter().enumerate() {
                // Record points are relative to the item origin.
                builder.push(InkPoint::with_pressure(
                    record.x + x,
                    record.y + y,
                    Some(1.0),
                    i as f64 * 8.0,
                ));
            }
            let stroke = builder.finish()?;
            ItemContent::Drawing {
                strokes: vec![PaintedInk {
                    stroke,
                    style_raw: record.stroke_style_raw.clone(),
                    color_hex: record.color_hex.clone(),
                    line_width: record.line_width,
                }],
            }
        }
        Some(ItemKind::Image) => {
            let bytes = record.image_data.clone()?;
            let (pixel_w, pixel_h) = image::load_from_memory(&bytes)
                .map(|img| (img.width(), img.height()))
                .ok()?;
            ItemContent::Image {
                bytes,
                pixel_w,
                pixel_h,
            }
        }
        _ => return None,
    };
    Some(CanvasItem { content, ..base })
}

fn ink_tool(style: DrawingStyle) -> openmind_ink::InkTool {
    match style {
        DrawingStyle::Highlighter => openmind_ink::InkTool::Highlighter,
        DrawingStyle::Pen | DrawingStyle::Line | DrawingStyle::Arrow => openmind_ink::InkTool::Pen,
    }
}
