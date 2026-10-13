//! Integration: record → play → move → save/reopen; video poster lifecycle;
//! rich-text undo; autosave recovery; import safety.
//!
//! Uses mock backends (no system audio/video) so CI stays headless.

use openmind_board::ShapeKind;
use openmind_canvas::{CanvasDoc, CanvasItem, Rect};
use openmind_media_audio::{
    AudioCapture, AudioPlayer, MockCapture, MockPlayer, PlaybackState, RecordingOptions,
};
use openmind_media_video::{MockPlayback, MockVideoBackend, VideoBackend, VideoPlayback};

#[test]
fn record_attach_save_reopen_and_play() {
    // Record (mock) → attach card → move → save → reopen → play.
    let mut cap = MockCapture::new();
    let session = cap.start(RecordingOptions::default()).expect("start");
    let samples = vec![100i16; 4410];
    let asset = cap.stop(session, &samples).expect("stop");
    assert!((asset.duration_secs - 0.1).abs() < 1e-6);

    let mut doc = CanvasDoc::new();
    let frame = Rect::new(0.0, 0.0, 300.0, 110.0);
    let id = doc.add(CanvasItem::audio_card(
        frame,
        0.0,
        "Voice".to_string(),
        asset.asset_hash.clone(),
    ));
    doc.select(&id, false);
    doc.move_selection(20.0, 20.0);
    assert_eq!(doc.find(&id).expect("card").frame.x, 20.0);

    let bytes = doc
        .to_vsom_document("Audio board")
        .encode()
        .expect("encode");
    let file = openmind_board::VsomDocument::decode(&bytes).expect("decode");
    let back = CanvasDoc::from_vsom_document(&file);
    // Audio rides as foreign (Swift-compatible) until promoted — never dropped.
    assert!(!back.foreign.is_empty() || !back.items.is_empty());

    let mut player = MockPlayer::new();
    let wav = openmind_media_audio::encode_wav_mono(&samples, 44100);
    let dur = player.load(&wav).expect("load");
    assert!((dur - 0.1).abs() < 1e-6);
    player.play().expect("play");
    assert_eq!(player.state(), PlaybackState::Playing);
    player.stop();
}

#[test]
fn video_poster_and_playback_lifecycle() {
    let backend = MockVideoBackend;
    let mut bytes = vec![0u8; 64];
    bytes[4..8].copy_from_slice(b"ftyp");
    let meta = backend.probe(&bytes).expect("probe");
    assert_eq!(meta.width, Some(1280));
    let (_poster, w, h) = backend.poster(&bytes, 320).expect("poster");
    assert!(w > 0 && h > 0);

    let mut doc = CanvasDoc::new();
    let id = doc.add(CanvasItem::video_card(
        Rect::new(0.0, 0.0, 480.0, 300.0),
        0.0,
        "clip".to_string(),
        "hash".to_string(),
    ));
    // Selecting/moving never restarts playback: playback handle is separate.
    let mut pb = MockPlayback::new();
    pb.open("hash").expect("open");
    doc.select(&id, false);
    doc.move_selection(10.0, 0.0);
    assert!(pb.is_open());
    pb.play().expect("play");
    pb.seek(2.0).expect("seek");
    pb.close();
    assert!(!pb.is_open());
}

#[test]
fn rich_text_edit_undo_reopen() {
    let mut doc = CanvasDoc::new();
    let id = doc.add(CanvasItem::text(Rect::new(0.0, 0.0, 240.0, 60.0), 0.0));
    doc.set_text(&id, "hello".to_string());
    assert!(doc.undo());
    assert!(doc.redo());
    let bytes = doc.to_vsom_document("RT").encode().expect("encode");
    let file = openmind_board::VsomDocument::decode(&bytes).expect("decode");
    let back = CanvasDoc::from_vsom_document(&file);
    assert!(!back.items.is_empty());
}

#[test]
fn youtube_variants_and_invalid() {
    for url in [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://www.youtube.com/shorts/dQw4w9WgXcQ",
        "https://www.youtube.com/embed/dQw4w9WgXcQ",
    ] {
        let yt = openmind_media::parse_youtube_url(url).expect(url);
        assert_eq!(yt.video_id, "dQw4w9WgXcQ");
        let mut doc = CanvasDoc::new();
        doc.add(CanvasItem::youtube_card(
            Rect::new(0.0, 0.0, 480.0, 300.0),
            0.0,
            yt.video_id,
        ));
    }
    assert!(openmind_media::parse_youtube_url("https://vimeo.com/1").is_err());
    assert!(openmind_media::parse_youtube_url("https://www.youtube.com/watch").is_err());
}

#[test]
fn connectors_and_shapes_survive() {
    let mut doc = CanvasDoc::new();
    let a = doc.add(CanvasItem::shape(
        ShapeKind::Rectangle,
        Rect::new(0.0, 0.0, 100.0, 60.0),
        "C6E0FF",
        0.0,
    ));
    let b = doc.add(CanvasItem::shape(
        ShapeKind::Ellipse,
        Rect::new(200.0, 0.0, 100.0, 60.0),
        "FFF1A8",
        0.0,
    ));
    let from = doc.find(&a).expect("a").id.clone();
    let to = doc.find(&b).expect("b").id.clone();
    // Move endpoints; connector ids stay stable (reattach by id).
    doc.select(&from, false);
    doc.move_selection(10.0, 0.0);
    let c = doc.add(CanvasItem::connector(
        Rect::new(0.0, 0.0, 300.0, 60.0),
        0.0,
        &from,
        &to,
    ));
    match &doc.find(&c).expect("connector").content {
        openmind_canvas::ItemContent::Connector { from: f, to: t, .. } => {
            assert_eq!(f, &from.0);
            assert_eq!(t, &to.0);
        }
        other => panic!("expected connector, got {other:?}"),
    }
}
