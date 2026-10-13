//! Schema migrations: deterministic, tested, never silent-drop.
//!
//! - v1 = legacy `.vsom` (id-less records, embedded bytes).
//! - v2 = `.canvaspkg` [`StableBoard`] (stable ids, asset refs).
//!
//! Unknown object types are preserved as opaque foreign records on the way
//! back to `.vsom` (see `canvas::vsom`).

use crate::id::{BoardId, ObjectId};
use crate::manifest::PACKAGE_SCHEMA_VERSION;
use crate::stable::{Background, BoardObject, BoardObjectKind, StableBoard, Transform};
use crate::time::swift_now;
use crate::vsom::VsomDocument;

/// Migrate a decoded `.vsom` document into a [`StableBoard`] (v1 → v2).
/// Every record gets a fresh stable id; group/lock/z/page survive verbatim.
pub fn vsom_to_stable(doc: &VsomDocument, title_override: Option<&str>) -> StableBoard {
    let now = swift_now();
    let mut board = StableBoard::new(
        BoardId::generate(),
        title_override.unwrap_or(&doc.board.title).to_string(),
        now,
    );
    board.created_at = doc.board.created_at;
    board.modified_at = doc.board.modified_at;
    board.background = Some(doc.board.canvas_pattern_raw.clone());
    // Validate pattern, fall back to dots.
    if Background::parse(board.background.as_deref().unwrap_or("")).is_none() {
        board.background = Some("dots".to_string());
    }
    for record in &doc.items {
        let kind = match record.kind_raw.as_str() {
            "sticky" => BoardObjectKind::StickyNote {
                text: record.text.clone(),
                color_hex: record.color_hex.clone(),
                font_size: record.font_size,
            },
            "text" => BoardObjectKind::RichText {
                doc: serde_json::json!({"text": record.text}),
            },
            "shape" => BoardObjectKind::Shape {
                shape_raw: record.shape_raw.clone(),
                color_hex: record.color_hex.clone(),
                label: record.text.clone(),
                font_size: record.font_size,
            },
            "drawing" => BoardObjectKind::Drawing {
                stroke_style_raw: record.stroke_style_raw.clone(),
                color_hex: record.color_hex.clone(),
                line_width: record.line_width,
                points_data: record.points_data.clone(),
            },
            _ => BoardObjectKind::Unknown,
        };
        let mut obj = BoardObject::new(
            ObjectId::generate(),
            Transform::rect(record.x, record.y, record.width, record.height),
            record.z_index,
            kind,
        );
        obj.locked = record.is_locked;
        obj.group_id = record.group_id.clone();
        obj.page_index = record.page_index;
        board.objects.push(obj);
    }
    board
        .objects
        .sort_by(|a, b| a.z_index.total_cmp(&b.z_index));
    board.schema_version = PACKAGE_SCHEMA_VERSION;
    board
}

/// Migration result for reporting (how many unknown records were preserved).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MigrationReport {
    pub objects: usize,
    pub unknown: usize,
}

pub fn migration_report(board: &StableBoard) -> MigrationReport {
    let unknown = board
        .objects
        .iter()
        .filter(|o| matches!(o.kind, BoardObjectKind::Unknown))
        .count();
    MigrationReport {
        objects: board.objects.len(),
        unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Board, CanvasItem};

    fn item(kind: &str, z: f64) -> CanvasItem {
        CanvasItem {
            kind_raw: kind.to_string(),
            shape_raw: "rectangle".to_string(),
            stroke_style_raw: "pen".to_string(),
            x: 1.0,
            y: 2.0,
            width: 160.0,
            height: 160.0,
            page_index: 0,
            text: "hi".to_string(),
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
            z_index: z,
            is_locked: false,
            group_id: None,
        }
    }

    fn vsom_doc() -> VsomDocument {
        VsomDocument {
            format: crate::vsom::VSOM_FORMAT_ID.to_string(),
            version: crate::vsom::VSOM_VERSION,
            board: Board {
                title: "M".to_string(),
                created_at: 0.0,
                modified_at: 0.0,
                canvas_size_raw: "infinite".to_string(),
                canvas_orientation_raw: "portrait".to_string(),
                canvas_color_hex: "FFFFFF".to_string(),
                canvas_pattern_raw: "dots".to_string(),
                custom_width: 595.0,
                custom_height: 842.0,
                page_count: 1,
            },
            items: vec![item("sticky", 1.0), item("hologram", 2.0)],
        }
    }

    #[test]
    fn v1_to_v2_keeps_known_and_opaque_unknown() {
        let doc = vsom_doc();
        let stable = vsom_to_stable(&doc, None);
        assert_eq!(stable.objects.len(), 2);
        assert!(matches!(
            stable.objects[0].kind,
            BoardObjectKind::StickyNote { .. }
        ));
        assert!(matches!(stable.objects[1].kind, BoardObjectKind::Unknown));
        let report = migration_report(&stable);
        assert_eq!(
            report,
            MigrationReport {
                objects: 2,
                unknown: 1
            }
        );
        assert_ne!(stable.objects[0].id, stable.objects[1].id);
    }
}
