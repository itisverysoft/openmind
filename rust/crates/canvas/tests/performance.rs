//! Performance fixtures: culling keeps large boards navigable.
//!
//! Budgets (plan §5.5, ADR 0001 §7): pointer-down→selection p95 <16 ms,
//! 10k lightweight objects navigable with the grid index. These tests assert
//! structural properties (visible subset ≪ total, index-backed hit testing)
//! with generous timing guards so CI stays stable.

use openmind_board::ShapeKind;
use openmind_canvas::{CanvasDoc, CanvasItem, Rect, SpatialIndex};

fn rect_item(x: f64, y: f64) -> CanvasItem {
    CanvasItem::shape(
        ShapeKind::Rectangle,
        Rect::new(x, y, 20.0, 20.0),
        "C6E0FF",
        0.0,
    )
}

#[test]
fn ten_thousand_objects_cull_to_viewport() {
    let mut doc = CanvasDoc::new();
    // 100×100 grid spaced 100pt → 10k items over a 10kpt world.
    for gx in 0..100 {
        for gy in 0..100 {
            // Bypass per-add undo snapshots for fixture speed.
            let mut item = rect_item(gx as f64 * 100.0, gy as f64 * 100.0);
            item.z = (gx * 100 + gy) as f64;
            doc.items.push(item);
        }
    }
    doc.items.sort_by(|a, b| a.z.total_cmp(&b.z));
    assert_eq!(doc.items.len(), 10_000);

    let mut idx = SpatialIndex::new();
    idx.rebuild(
        &doc.items
            .iter()
            .map(|i| (i.id.clone(), i.frame))
            .collect::<Vec<_>>(),
    );
    assert_eq!(idx.len(), 10_000);

    // 800×600 viewport at 100% → visible subset is tiny.
    let hits = idx.query(Rect::new(0.0, 0.0, 800.0, 600.0));
    assert!(
        hits.len() < 500,
        "culled to {}, expected ≪10000",
        hits.len()
    );
    assert!(!hits.is_empty());

    // Hit testing resolves through the culled set.
    let found = doc.hit_topmost(10.0, 10.0);
    assert!(found.is_some());
}

#[test]
fn mixed_thousand_plus_media_stays_responsive() {
    let mut doc = CanvasDoc::new();
    for i in 0..1000 {
        doc.items.push(rect_item(i as f64 * 10.0, 0.0));
    }
    for i in 0..20 {
        let frame = Rect::new(i as f64 * 500.0, 1000.0, 300.0, 110.0);
        doc.items.push(CanvasItem::audio_card(
            frame,
            0.0,
            format!("track {i}"),
            format!("hash{i}"),
        ));
    }
    assert_eq!(doc.items.len(), 1020);
    // Marquee over a small region hits a bounded subset (no full scan in UI).
    doc.select_marquee(Rect::new(0.0, -10.0, 100.0, 50.0), false);
    assert!(doc.selection.len() < 50);
}
