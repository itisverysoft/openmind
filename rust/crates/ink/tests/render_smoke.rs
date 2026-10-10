//! Headless smoke test: ink stroke → vector document → PNG.
//!
//! Proves the M1 chain works end to end with the reused vector stack:
//! `openmind-ink` builds the outline [`BezPath`], `vectorcraft-doc` holds it
//! as a filled path node, `vectorcraft-render` rasterizes it.

use openmind_ink::{InkConfig, InkPoint, InkTool, StrokeBuilder};
use vectorcraft_color::{Color, Paint};
use vectorcraft_doc::{Appearance, Document, Node};
use vectorcraft_geom::{Affine, BezPath, PathData};
use vectorcraft_render::{RenderOptions, Renderer};

fn doc_with_stroke(outline: &BezPath, paint: Paint) -> Document {
    let mut doc = Document::new(200.0, 200.0);
    let layer = doc.layers[0].id;
    let id = doc.alloc_id();
    let node = Node::path(
        id,
        PathData::from_bezpath(outline),
        Appearance::basic(paint, Paint::None, 0.0),
    );
    doc.insert(Some(layer), 0, node)
        .expect("insert stroke node");
    doc
}

#[test]
fn pen_stroke_renders_dark_pixels_and_png() {
    let mut b = StrokeBuilder::new(
        InkConfig {
            max_width: 12.0,
            ..InkConfig::default()
        },
        InkTool::Pen,
    );
    for (i, t) in (20..=180).step_by(8).enumerate() {
        let v = f64::from(t);
        b.push(InkPoint::with_pressure(v, v, Some(1.0), i as f64 * 8.0));
    }
    let stroke = b.finish().expect("stroke");
    assert!(!stroke.outline.is_empty(), "outline must hold contours");

    let doc = doc_with_stroke(&stroke.outline, Paint::solid(Color::BLACK));
    let rendered =
        Renderer::new().render(&doc, 200, 200, Affine::IDENTITY, &RenderOptions::default());
    // The diagonal passes through (100,100); a 12pt nib covers it solidly.
    let [r, g, bl, a] = rendered.pixel(100, 100);
    assert_eq!(a, 255, "ink pixel must be opaque");
    assert!(
        r < 100 && g < 100 && bl < 100,
        "ink pixel must be dark: {r},{g},{bl}"
    );

    let png = rendered.to_png().expect("png encodes");
    assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n", "PNG magic");
    assert!(png.len() > 100, "non-trivial png");
}

#[test]
fn tap_dot_renders() {
    let mut b = StrokeBuilder::new(InkConfig::default(), InkTool::Pen);
    b.push(InkPoint::new(100.0, 100.0));
    let stroke = b.finish().expect("dot");
    let doc = doc_with_stroke(&stroke.outline, Paint::solid(Color::BLACK));
    let rendered =
        Renderer::new().render(&doc, 200, 200, Affine::IDENTITY, &RenderOptions::default());
    let [_, _, _, a] = rendered.pixel(100, 100);
    assert_eq!(a, 255, "dot pixel must be opaque");
}
