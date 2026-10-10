//! `.vsom` round-trip compatibility with the Swift app.
//!
//! The fixture below is shaped exactly like `BoardExport.exportBoard`
//! output: sorted keys don't matter for decode, but base64 `Data` blobs,
//! reference-date `Date` numbers, and the `youtubeURL`/`groupID` key spellings
//! must match. If the Swift format ever drifts, these tests fail first.

use openmind_board::{CanvasItem, VsomDocument, VsomError, VSOM_FORMAT_ID, VSOM_VERSION};

fn item_fixture() -> serde_json::Value {
    serde_json::json!({
        "kindRaw": "drawing",
        "shapeRaw": "rectangle",
        "strokeStyleRaw": "pen",
        "x": 100.0, "y": 150.0, "width": 200.0, "height": 120.0,
        "pageIndex": 0,
        "text": "",
        "colorHex": "3B82F6",
        "fontSize": 18.0,
        // Swift StrokeCodec JSON [[10,20],[30,40]] as stored bytes, base64'd.
        "pointsData": base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            b"[[10.0,20.0],[30.0,40.0]]",
        ),
        "lineWidth": 4.0,
        "richTextData": "",
        "imageData": null,
        "pdfData": null,
        "pdfPage": 0,
        "audioData": null,
        "audioFileName": "",
        "audioDuration": 0.0,
        "tableData": "",
        "zIndex": 1.0,
        "isLocked": false,
    })
}

fn doc_fixture() -> serde_json::Value {
    serde_json::json!({
        "format": VSOM_FORMAT_ID,
        "version": VSOM_VERSION,
        "board": {
            "title": "Round trip",
            // 2026-01-02T00:00:00Z as Swift reference-date seconds.
            "createdAt": 788_918_400.0,
            "modifiedAt": 788_918_400.0,
            "canvasSizeRaw": "infinite",
            "canvasOrientationRaw": "portrait",
            "canvasColorHex": "FFFFFF",
            "canvasPatternRaw": "dots",
            "customWidth": 595.0,
            "customHeight": 842.0,
            "pageCount": 1,
        },
        "items": [item_fixture()],
    })
}

#[test]
fn swift_shaped_document_decodes() {
    let bytes = serde_json::to_vec(&doc_fixture()).expect("fixture encodes");
    let doc = VsomDocument::decode(&bytes).expect("Swift-shaped file decodes");
    assert_eq!(doc.format, VSOM_FORMAT_ID);
    assert_eq!(doc.version, VSOM_VERSION);
    assert_eq!(doc.board.title, "Round trip");
    assert_eq!(doc.board.created_at, 788_918_400.0);
    assert_eq!(doc.items.len(), 1);
    let item: &CanvasItem = &doc.items[0];
    assert_eq!(item.kind_raw, "drawing");
    assert_eq!(item.points_data, b"[[10.0,20.0],[30.0,40.0]]");
    // Keys added after v1 items are absent in this fixture: lenient defaults.
    assert_eq!(item.youtube_url, "");
    assert_eq!(item.video_file_name, "");
    assert_eq!(item.video_duration, 0.0);
    assert_eq!(item.group_id, None);
}

#[test]
fn round_trip_is_stable() {
    let bytes = serde_json::to_vec(&doc_fixture()).expect("fixture encodes");
    let doc = VsomDocument::decode(&bytes).expect("decode");
    let re = doc.encode().expect("encode");
    let back = VsomDocument::decode(&re).expect("decode again");
    assert_eq!(doc, back);
}

#[test]
fn rejects_non_board_files() {
    assert_eq!(
        VsomDocument::decode(b"{}").expect_err("empty object"),
        VsomError::NotABoardFile
    );
    assert_eq!(
        VsomDocument::decode(b"not json at all").expect_err("garbage"),
        VsomError::NotABoardFile
    );
    let mut fixture = doc_fixture();
    fixture["format"] = serde_json::json!("vectorcraft");
    let bytes = serde_json::to_vec(&fixture).expect("encode");
    assert_eq!(
        VsomDocument::decode(&bytes).expect_err("wrong format"),
        VsomError::NotABoardFile
    );
}

#[test]
fn rejects_unknown_versions() {
    let mut fixture = doc_fixture();
    fixture["version"] = serde_json::json!(99);
    let bytes = serde_json::to_vec(&fixture).expect("encode");
    assert_eq!(
        VsomDocument::decode(&bytes).expect_err("future version"),
        VsomError::UnsupportedVersion(99)
    );
}
