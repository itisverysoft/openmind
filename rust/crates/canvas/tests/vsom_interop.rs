//! `.vsom` interop: canvas → Swift-shaped file → canvas, lossless where the
//! canvas edits and verbatim everywhere else.

use openmind_board::{CanvasItem as BoardItem, VsomDocument};
use openmind_canvas::{CanvasDoc, CanvasItem, ItemContent, PaintedInk, Rect};
use openmind_ink::{InkConfig, InkPoint, InkTool, StrokeBuilder};

fn red_png() -> Vec<u8> {
    let img = image::RgbaImage::from_pixel(4, 4, image::Rgba([255, 0, 0, 255]));
    let mut bytes = Vec::new();
    image::DynamicImage::ImageRgba8(img)
        .write_to(
            &mut std::io::Cursor::new(&mut bytes),
            image::ImageFormat::Png,
        )
        .expect("png encodes");
    bytes
}

fn stroke_fixture() -> PaintedInk {
    let mut b = StrokeBuilder::new(
        InkConfig {
            max_width: 6.0,
            ..InkConfig::default()
        },
        InkTool::Pen,
    );
    for (i, x) in [0.0, 20.0, 40.0, 60.0].iter().enumerate() {
        b.push(InkPoint::with_pressure(*x, 0.0, Some(1.0), i as f64 * 8.0));
    }
    PaintedInk {
        stroke: b.finish().expect("stroke"),
        style_raw: "pen".to_string(),
        color_hex: "1A1A1A".to_string(),
        line_width: 6.0,
    }
}

fn table_record() -> BoardItem {
    // Something this build cannot edit: must survive the round trip untouched.
    BoardItem {
        kind_raw: "table".to_string(),
        shape_raw: "rectangle".to_string(),
        stroke_style_raw: "pen".to_string(),
        x: 10.0,
        y: 10.0,
        width: 360.0,
        height: 220.0,
        page_index: 0,
        text: String::new(),
        color_hex: "FFF1A8".to_string(),
        font_size: 14.0,
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
        table_data: vec![1, 2, 3, 4],
        z_index: 99.0,
        is_locked: false,
        group_id: None,
    }
}

#[test]
fn native_items_round_trip_with_text_intact() {
    let mut doc = CanvasDoc::new();
    let sticky = CanvasItem::sticky(Rect::new(10.0, 10.0, 160.0, 160.0), "FFF1A8", 0.0);
    let sid = doc.add(sticky);
    doc.set_text(&sid, "hello".to_string());
    let mut text = CanvasItem::text(Rect::new(200.0, 10.0, 240.0, 60.0), 0.0);
    if let ItemContent::Text { text: t, .. } = &mut text.content {
        *t = "world".to_string();
    }
    doc.add(text);
    doc.foreign.push(table_record());

    let bytes = doc.to_vsom_document("Interop").encode().expect("encode");
    let file = VsomDocument::decode(&bytes).expect("Swift-style decode");
    assert_eq!(file.items.len(), 3);

    let back = CanvasDoc::from_vsom_document(&file);
    assert_eq!(back.items.len(), 2);
    assert_eq!(back.foreign.len(), 1);
    assert_eq!(back.foreign[0].table_data, vec![1, 2, 3, 4]);
    let texts: Vec<String> = back
        .items
        .iter()
        .filter_map(|i| match &i.content {
            ItemContent::Sticky { text, .. } | ItemContent::Text { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect();
    assert!(texts.contains(&"hello".to_string()));
    assert!(texts.contains(&"world".to_string()));
}

#[test]
fn drawing_stroke_survives_as_swift_record() {
    let mut doc = CanvasDoc::new();
    let frame = Rect::new(0.0, 0.0, 100.0, 40.0);
    doc.add(CanvasItem {
        id: openmind_canvas::id(),
        kind_raw: "drawing".to_string(),
        frame,
        z: 0.0,
        locked: false,
        group: None,
        page: 0,
        content: ItemContent::Drawing {
            strokes: vec![stroke_fixture()],
        },
    });

    let bytes = doc.to_vsom_document("Ink").encode().expect("encode");
    let file = VsomDocument::decode(&bytes).expect("decode");
    assert_eq!(file.items.len(), 1);
    let record = &file.items[0];
    assert_eq!(record.kind_raw, "drawing");
    assert_eq!(record.stroke_style_raw, "pen");
    assert!(!record.points_data.is_empty());

    let back = CanvasDoc::from_vsom_document(&file);
    assert_eq!(back.items.len(), 1);
    match &back.items[0].content {
        ItemContent::Drawing { strokes } => {
            assert_eq!(strokes.len(), 1);
            assert!(strokes[0].stroke.spine.len() > 2);
            assert_eq!(strokes[0].color_hex, "1A1A1A");
        }
        other => panic!("expected drawing, got {other:?}"),
    }
}

#[test]
fn image_bytes_and_dims_survive() {
    let mut doc = CanvasDoc::new();
    let bytes = red_png();
    doc.add(CanvasItem {
        id: openmind_canvas::id(),
        kind_raw: "image".to_string(),
        frame: Rect::new(0.0, 0.0, 60.0, 60.0),
        z: 0.0,
        locked: false,
        group: None,
        page: 0,
        content: ItemContent::Image {
            bytes: bytes.clone(),
            pixel_w: 4,
            pixel_h: 4,
        },
    });

    let file_bytes = doc.to_vsom_document("Img").encode().expect("encode");
    let file = VsomDocument::decode(&file_bytes).expect("decode");
    assert_eq!(file.items[0].image_data.as_ref().expect("bytes"), &bytes);

    let back = CanvasDoc::from_vsom_document(&file);
    match &back.items[0].content {
        ItemContent::Image {
            pixel_w,
            pixel_h,
            bytes: back_bytes,
        } => {
            assert_eq!((*pixel_w, *pixel_h), (4, 4));
            assert_eq!(back_bytes, &bytes);
        }
        other => panic!("expected image, got {other:?}"),
    }
}
