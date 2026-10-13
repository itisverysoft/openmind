//! OpenMind desktop app: an infinite-canvas whiteboard window.
//!
//! Offline-first: boards open from Finder double-click / CLI args (`.vsom`),
//! autosave + recovery journal keep work safe, and everything stays local.

#![forbid(unsafe_code)]

mod app;
mod color;

fn main() -> eframe::Result<()> {
    // Finder double-click / `open OpenMind.app --args board.vsom` arrives as a
    // CLI arg; install.sh forwards it. Open it on launch when present.
    let mut initial: Option<app::OpenMindApp> = None;
    for arg in std::env::args().skip(1) {
        if arg == "--" {
            continue;
        }
        if arg.ends_with(".vsom") {
            if let Ok(bytes) = std::fs::read(&arg) {
                if let Ok(file) = openmind_board::VsomDocument::decode(&bytes) {
                    let mut app = app::OpenMindApp::default();
                    app.open_vsom_path(&arg, file);
                    initial = Some(app);
                    break;
                }
            }
        }
    }
    // Crash recovery: surface the newest autosave journal snapshot when the
    // last session never saved cleanly.
    if initial.is_none() {
        let dir = std::env::temp_dir().join("openmind-autosave");
        let journal = openmind_engine::RecoveryJournal::new(&dir, 3);
        if let Some(bytes) = journal.replay() {
            if let Ok(file) = openmind_board::VsomDocument::decode(&bytes) {
                let mut app = app::OpenMindApp::default();
                app.open_vsom_bytes("recovered autosave", file);
                initial = Some(app);
            }
        }
    }
    let initial = initial.unwrap_or_default();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("OpenMind")
            .with_inner_size([1200.0, 800.0]),
        ..Default::default()
    };
    eframe::run_native("OpenMind", options, Box::new(|_cc| Ok(Box::new(initial))))
}
