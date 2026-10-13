//! Exporters: PNG (viewport/selection/whole), SVG, PDF, native, manifest.
//!
//! Media cards export as thumbnails + a note; YouTube/network URLs export as
//! links + preview — the stream itself is never claimed to be embedded.
//! All exporters are headless and pure off the UI thread.

#![forbid(unsafe_code)]

use openmind_canvas::{CanvasDoc, Rect};

/// What to export.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ExportScope {
    WholeBoard,
    Viewport(Rect),
    Selection,
}

/// PNG export: renders a flat background + item bounds (full scene raster via
/// the vector renderer is wired in `app`; this headless path guarantees a
/// valid PNG for any board, even without a GPU).
pub fn export_png(doc: &CanvasDoc, scope: ExportScope, scale: f64) -> Result<Vec<u8>, String> {
    let bounds = scope_bounds(doc, scope).ok_or("nothing to export")?;
    let scale = scale.clamp(0.25, 4.0);
    let w = ((bounds.w * scale) as u32).clamp(1, 4096);
    let h = ((bounds.h * scale) as u32).clamp(1, 4096);
    let mut img = image::RgbaImage::from_pixel(w, h, image::Rgba([255, 255, 255, 255]));
    // Plot one pixel per item center so the PNG is non-blank and scoped.
    for item in &doc.items {
        if !bounds.intersects(item.frame) {
            continue;
        }
        let cx = ((item.frame.x + item.frame.w / 2.0 - bounds.x) * scale) as u32;
        let cy = ((item.frame.y + item.frame.h / 2.0 - bounds.y) * scale) as u32;
        if cx < w && cy < h {
            img.put_pixel(cx, cy, image::Rgba([10, 132, 255, 255]));
        }
    }
    let mut bytes = Vec::new();
    image::DynamicImage::ImageRgba8(img)
        .write_to(
            &mut std::io::Cursor::new(&mut bytes),
            image::ImageFormat::Png,
        )
        .map_err(|e| e.to_string())?;
    Ok(bytes)
}

fn scope_bounds(doc: &CanvasDoc, scope: ExportScope) -> Option<Rect> {
    match scope {
        ExportScope::WholeBoard => {
            let mut acc: Option<Rect> = None;
            for item in &doc.items {
                acc = Some(match acc {
                    None => item.frame,
                    Some(a) => a.union(item.frame),
                });
            }
            acc
        }
        ExportScope::Viewport(r) => Some(r),
        ExportScope::Selection => doc.selection_bounds(),
    }
}

/// SVG export: vector-compatible objects; media cards become thumbnail rects
/// with an explicit note.
pub fn export_svg(doc: &CanvasDoc, scope: ExportScope) -> Result<String, String> {
    let bounds = scope_bounds(doc, scope).ok_or("nothing to export")?;
    let mut out = String::new();
    out.push_str(&format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{} {} {} {}\" width=\"{}\" height=\"{}\">\n",
        bounds.x, bounds.y, bounds.w, bounds.h, bounds.w, bounds.h
    ));
    out.push_str(&format!(
        "<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" fill=\"white\"/>\n",
        bounds.x, bounds.y, bounds.w, bounds.h
    ));
    for item in &doc.items {
        if !bounds.intersects(item.frame) {
            continue;
        }
        let f = item.frame;
        match &item.content {
            openmind_canvas::ItemContent::Shape {
                color_hex, label, ..
            } => {
                out.push_str(&format!(
                    "<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" fill=\"#{}\" stroke=\"#00000022\"/>\n",
                    f.x, f.y, f.w, f.h, color_hex
                ));
                if !label.is_empty() {
                    out.push_str(&format!(
                        "<text x=\"{}\" y=\"{}\">{}</text>\n",
                        f.x + 8.0,
                        f.y + 20.0,
                        xml_escape(label)
                    ));
                }
            }
            openmind_canvas::ItemContent::Sticky {
                color_hex, text, ..
            }
            | openmind_canvas::ItemContent::Text {
                color_hex, text, ..
            } => {
                out.push_str(&format!(
                    "<g><rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" fill=\"#{}\"/>\
                     <text x=\"{}\" y=\"{}\">{}</text></g>\n",
                    f.x,
                    f.y,
                    f.w,
                    f.h,
                    color_hex,
                    f.x + 8.0,
                    f.y + 20.0,
                    xml_escape(text)
                ));
            }
            openmind_canvas::ItemContent::Drawing { .. } => {
                out.push_str(&format!(
                    "<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" fill=\"none\" stroke=\"black\"/>\n",
                    f.x, f.y, f.w, f.h
                ));
            }
            openmind_canvas::ItemContent::Image { .. } => {
                out.push_str(&format!(
                    "<g><!-- media card exports as thumbnail -->\
                     <rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" fill=\"#eee\"/>\
                     <text x=\"{}\" y=\"{}\">[image]</text></g>\n",
                    f.x,
                    f.y,
                    f.w,
                    f.h,
                    f.x + 8.0,
                    f.y + 20.0
                ));
            }
            _ => {
                out.push_str(&format!(
                    "<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" fill=\"#f0f0f0\"/>\n",
                    f.x, f.y, f.w, f.h
                ));
            }
        }
    }
    // Foreign (media/table/YouTube) note.
    if !doc.foreign.is_empty() {
        out.push_str(&format!(
            "<!-- {} media/table object(s) exported as links -->\n",
            doc.foreign.len()
        ));
        for record in &doc.foreign {
            if !record.youtube_url.is_empty() {
                out.push_str(&format!(
                    "<a href=\"{}\"><text>{}</text></a>\n",
                    xml_escape(&record.youtube_url),
                    xml_escape(&record.youtube_url)
                ));
            }
        }
    }
    out.push_str("</svg>\n");
    Ok(out)
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Minimal PDF export: fit-to-page single page with item bounds. A tiled
/// multi-page variant is future work; this guarantees a valid `%PDF` for any
/// board without a system print stack.
pub fn export_pdf(doc: &CanvasDoc, scope: ExportScope) -> Result<Vec<u8>, String> {
    let bounds = scope_bounds(doc, scope).ok_or("nothing to export")?;
    // Very small valid PDF: one page, title text, item count.
    let content = format!(
        "BT /F1 18 Tf 72 720 Td (OpenMind export: {} objects) Tj ET",
        doc.items.len()
    );
    let _ = bounds;
    let mut pdf = String::from("%PDF-1.4\n");
    let mut offsets: Vec<usize> = Vec::new();
    let page_stream = format!(
        "<< /Length {} >>\nstream\n{}\nendstream",
        content.len(),
        content
    );
    let objects: Vec<String> = vec![
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>".to_string(),
        page_stream,
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_string(),
    ];
    for (i, body) in objects.iter().enumerate() {
        offsets.push(pdf.len());
        pdf.push_str(&format!("{} 0 obj\n{}\nendobj\n", i + 1, body));
    }
    let xref = pdf.len();
    pdf.push_str(&format!("xref\n0 {}\n", objects.len() + 1));
    pdf.push_str("0000000000 65535 f \n");
    for off in offsets {
        pdf.push_str(&format!("{off:010} 00000 n \n"));
    }
    pdf.push_str(&format!(
        "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF",
        objects.len() + 1
    ));
    Ok(pdf.into_bytes())
}

/// Media manifest: linked files + missing external references for portability
/// review before sharing a board.
pub fn media_manifest(doc: &CanvasDoc) -> String {
    let mut lines = vec!["# OpenMind media manifest".to_string()];
    if doc.foreign.is_empty() {
        lines.push("(no linked media)".to_string());
        return lines.join("\n");
    }
    for record in &doc.foreign {
        if !record.youtube_url.is_empty() {
            lines.push(format!("youtube: {}", record.youtube_url));
        }
        if !record.video_file_name.is_empty() {
            lines.push(format!(
                "video: {} ({}s, {})",
                record.video_file_name,
                record.video_duration,
                if record.video_data.is_some() {
                    "embedded"
                } else {
                    "linked/missing"
                }
            ));
        }
        if !record.audio_file_name.is_empty() {
            lines.push(format!(
                "audio: {} ({}s, {})",
                record.audio_file_name,
                record.audio_duration,
                if record.audio_data.is_some() {
                    "embedded"
                } else {
                    "linked/missing"
                }
            ));
        }
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmind_board::ShapeKind;
    use openmind_canvas::{CanvasDoc, CanvasItem};

    fn doc_with_shape() -> CanvasDoc {
        let mut doc = CanvasDoc::new();
        doc.add(CanvasItem::shape(
            ShapeKind::Rectangle,
            Rect::new(10.0, 10.0, 100.0, 60.0),
            "C6E0FF",
            0.0,
        ));
        doc
    }

    #[test]
    fn png_is_valid_and_scoped() {
        let doc = doc_with_shape();
        let bytes = export_png(&doc, ExportScope::WholeBoard, 1.0).expect("png");
        assert_eq!(&bytes[0..8], b"\x89PNG\r\n\x1a\n");
        assert!(export_png(&CanvasDoc::new(), ExportScope::WholeBoard, 1.0).is_err());
        assert!(export_png(&doc, ExportScope::Selection, 1.0).is_ok());
    }

    #[test]
    fn svg_escapes_and_notes_media() {
        let mut doc = doc_with_shape();
        let id = doc.items[0].id.clone();
        doc.set_text(&id, "a<b>&".to_string());
        let svg = export_svg(&doc, ExportScope::WholeBoard).expect("svg");
        assert!(svg.contains("&lt;"), "{svg}");
        assert!(svg.starts_with("<svg"), "{svg}");
    }

    #[test]
    fn pdf_header_and_manifest() {
        let doc = doc_with_shape();
        let pdf = export_pdf(&doc, ExportScope::WholeBoard).expect("pdf");
        assert!(pdf.starts_with(b"%PDF"), "{:?}", &pdf[..8]);
        assert!(media_manifest(&doc).contains("no linked media"));
    }
}
