//! OpenMind desktop app: an infinite-canvas whiteboard window.
//!
//! M2-first-window: draw with pen/highlighter (pressure-ready inking from
//! `openmind-ink`), erase strokes, pan/zoom with the `openmind-board`
//! viewport. Strokes live in memory for now; `.vsom` save/open lands next.

#![forbid(unsafe_code)]

mod app;
mod color;

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("OpenMind")
            .with_inner_size([1200.0, 800.0]),
        ..Default::default()
    };
    eframe::run_native(
        "OpenMind",
        options,
        Box::new(|_cc| Ok(Box::new(app::OpenMindApp::default()))),
    )
}
