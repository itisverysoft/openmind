//! Interactive whiteboard: toolbar, canvas, selection, editing, persistence.
//!
//! Tools: Select (click / Shift-toggle / marquee / drag-move), Pen,
//! Highlighter, Eraser, Hand, drag-to-place Shapes, Sticky/Text creation,
//! image import, `.vsom` save/open, undo/redo, group, arrange, lock.
//!
//! State discipline (keeps selection snappy): hover/selection outlines are
//! computed per frame in immediate mode — no retained per-item view state.
//! Undo snapshots live in [`CanvasDoc`]; continuous gestures snapshot once
//! at gesture start; keystrokes snapshot once at first change.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use eframe::egui;
use openmind_board::{DrawingStyle, ShapeKind, Viewport, VsomDocument};
use openmind_canvas::{CanvasDoc, CanvasItem, ItemContent, ItemId, PaintedInk, Rect};
use openmind_ink::{InkConfig, InkPoint, InkTool, StrokeBuilder};
use openmind_media::AssetStore as _;
use openmind_media_audio::AudioCapture as _;
use openmind_media_video::VideoBackend as _;

use crate::color::hex_color;

const PEN_HEX: &str = "1A1A1A";
const PEN_WIDTH: f64 = 4.0;
const HIGHLIGHTER_HEX: &str = "FDE047";
const HIGHLIGHTER_WIDTH: f64 = 12.0;
const SHAPE_BLUE: &str = "C6E0FF";
const STICKY_YELLOW: &str = "FFF1A8";
const ACCENT: (u8, u8, u8) = (0x0a, 0x84, 0xff);

#[derive(Clone, Copy, PartialEq, Eq, Default)]
enum Tool {
    #[default]
    Select,
    Pen,
    Highlighter,
    Eraser,
    Hand,
    Shape(ShapeKind),
}

impl Tool {
    fn label(self) -> &'static str {
        match self {
            Self::Select => "Select",
            Self::Pen => "Pen",
            Self::Highlighter => "HL",
            Self::Eraser => "Eraser",
            Self::Hand => "Hand",
            Self::Shape(_) => "Shape",
        }
    }
}

const ALL_SHAPES: [ShapeKind; 15] = [
    ShapeKind::Rectangle,
    ShapeKind::RoundedRectangle,
    ShapeKind::Ellipse,
    ShapeKind::Triangle,
    ShapeKind::RightTriangle,
    ShapeKind::Diamond,
    ShapeKind::Pentagon,
    ShapeKind::Hexagon,
    ShapeKind::Circle,
    ShapeKind::Star,
    ShapeKind::Cloud,
    ShapeKind::Line,
    ShapeKind::Arrow,
    ShapeKind::DoubleArrow,
    ShapeKind::Capsule,
];

fn shape_title(kind: ShapeKind) -> &'static str {
    match kind {
        ShapeKind::Rectangle => "Rectangle",
        ShapeKind::RoundedRectangle => "RoundRect",
        ShapeKind::Ellipse => "Ellipse",
        ShapeKind::Triangle => "Triangle",
        ShapeKind::RightTriangle => "R-Triangle",
        ShapeKind::Diamond => "Diamond",
        ShapeKind::Pentagon => "Pentagon",
        ShapeKind::Hexagon => "Hexagon",
        ShapeKind::Circle => "Circle",
        ShapeKind::Star => "Star",
        ShapeKind::Cloud => "Cloud",
        ShapeKind::Line => "Line",
        ShapeKind::Arrow => "Arrow",
        ShapeKind::DoubleArrow => "DblArrow",
        ShapeKind::Capsule => "Capsule",
    }
}

fn accent() -> egui::Color32 {
    egui::Color32::from_rgb(ACCENT.0, ACCENT.1, ACCENT.2)
}

fn accent_translucent(alpha: u8) -> egui::Color32 {
    egui::Color32::from_rgba_unmultiplied(ACCENT.0, ACCENT.1, ACCENT.2, alpha)
}

struct Editing {
    id: ItemId,
    buffer: String,
    dirty: bool,
}

struct Marquee {
    start: egui::Pos2,
    cur: egui::Pos2,
    additive: bool,
}

struct MoveDrag {
    last_world: (f64, f64),
    moved: bool,
    snapshot: bool,
}

pub struct OpenMindApp {
    tool: Tool,
    doc: CanvasDoc,
    viewport: Viewport,
    editing: Option<Editing>,
    shape_anchor: Option<(f64, f64)>,
    shape_current: Option<(f64, f64)>,
    marquee: Option<Marquee>,
    move_drag: Option<MoveDrag>,
    erase_snapshot: bool,
    ink_builder: Option<StrokeBuilder>,
    ink_raw: Vec<(f64, f64)>,
    ink_tool: InkTool,
    textures: HashMap<String, egui::TextureHandle>,
    status: String,
    board_title: String,
    current_path: Option<PathBuf>,
    last_pointer: Option<egui::Pos2>,
    // Phase 9-12 state: background, dialogs, autosave, recording.
    pattern: String,
    show_youtube_dialog: bool,
    youtube_buffer: String,
    show_video_dialog: bool,
    video_buffer: String,
    recording: bool,
    recording_start: f64,
    active_audio: Option<ItemId>,
    dirty_since: Option<f64>,
    last_autosave: f64,
    template_pick: usize,
}

impl Default for OpenMindApp {
    fn default() -> Self {
        Self {
            tool: Tool::Select,
            doc: CanvasDoc::new(),
            viewport: Viewport::centered_on(5000.0, 5000.0, 600.0, 350.0),
            editing: None,
            shape_anchor: None,
            shape_current: None,
            marquee: None,
            move_drag: None,
            erase_snapshot: false,
            ink_builder: None,
            ink_raw: Vec::new(),
            ink_tool: InkTool::Pen,
            textures: HashMap::new(),
            status: String::from("Select: click, Shift-click, drag marquee · wheel: zoom"),
            board_title: String::from("Untitled Board"),
            current_path: None,
            last_pointer: None,
            pattern: String::from("dots"),
            show_youtube_dialog: false,
            youtube_buffer: String::new(),
            show_video_dialog: false,
            video_buffer: String::new(),
            recording: false,
            recording_start: 0.0,
            active_audio: None,
            dirty_since: None,
            last_autosave: 0.0,
            template_pick: 0,
        }
    }
}

// ---------------------------------------------------------------------------
// Small helpers (pure, unit-tested where it matters)
// ---------------------------------------------------------------------------

fn pen_config() -> InkConfig {
    InkConfig {
        max_width: PEN_WIDTH,
        ..InkConfig::default()
    }
}

fn highlighter_config() -> InkConfig {
    InkConfig {
        max_width: HIGHLIGHTER_WIDTH,
        ..InkConfig::default()
    }
}

fn decode_rgba(bytes: &[u8]) -> Option<(Vec<u8>, usize, usize)> {
    let img = image::load_from_memory(bytes).ok()?.to_rgba8();
    let (w, h) = (img.width() as usize, img.height() as usize);
    Some((img.into_raw(), w, h))
}

fn normalize_rect(a: (f64, f64), b: (f64, f64)) -> Rect {
    Rect::new(
        a.0.min(b.0),
        a.1.min(b.1),
        (b.0 - a.0).abs(),
        (b.1 - a.1).abs(),
    )
}

fn now_unix() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Open a URL in the system browser (YouTube fallback; no embedded web views
/// per card). Best-effort: failures surface as status.
fn open_browser(url: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(url)
            .spawn()
            .map(|_| ())
            .map_err(|e| e.to_string())?;
        Ok(())
    }
    #[cfg(target_os = "linux")]
    {
        std::process::Command::new("xdg-open")
            .arg(url)
            .spawn()
            .map(|_| ())
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = url;
        return Err("browser open not supported here".to_string());
    }
}

/// Screen corners to a normalized world rect.
fn marquee_world(vp: &Viewport, a: egui::Pos2, b: egui::Pos2) -> Rect {
    let (x0, y0) = vp.world_point(a.x as f64, a.y as f64);
    let (x1, y1) = vp.world_point(b.x as f64, b.y as f64);
    Rect::new(x0.min(x1), y0.min(y1), (x1 - x0).abs(), (y1 - y0).abs())
}

fn to_screen(vp: &Viewport, world: (f64, f64)) -> egui::Pos2 {
    let (sx, sy) = vp.screen_point(world.0, world.1);
    egui::Pos2::new(sx as f32, sy as f32)
}

fn frame_rect(vp: &Viewport, frame: Rect) -> egui::Rect {
    egui::Rect::from_min_max(
        to_screen(vp, (frame.x, frame.y)),
        to_screen(vp, (frame.x + frame.w, frame.y + frame.h)),
    )
}

/// Would the eraser remove anything here? Snapshot only when true, so empty
/// gestures leave no undo trace.
fn would_erase(doc: &CanvasDoc, x: f64, y: f64, extra: f64) -> bool {
    doc.items.iter().any(|item| {
        !item.locked
            && matches!(&item.content, ItemContent::Drawing { strokes }
                if strokes.iter().any(|s| s.stroke.hit_test(x, y, extra)))
    })
}

/// Regular-polygon vertices (screen space), starting at the top.
fn ngon(cx: f32, cy: f32, r: f32, n: usize) -> Vec<egui::Pos2> {
    (0..n)
        .map(|i| {
            let a = -std::f32::consts::FRAC_PI_2 + i as f32 * std::f32::consts::TAU / n as f32;
            egui::Pos2::new(cx + r * a.cos(), cy + r * a.sin())
        })
        .collect()
}

/// Five-point star outline (10 alternating vertices).
fn star_points(rect: egui::Rect) -> Vec<egui::Pos2> {
    let cx = rect.center().x;
    let cy = rect.center().y;
    let ro = rect.width().min(rect.height()) / 2.0;
    let ri = ro * 0.42;
    (0..10)
        .map(|i| {
            let r = if i % 2 == 0 { ro } else { ri };
            let a = -std::f32::consts::FRAC_PI_2 + i as f32 * std::f32::consts::PI / 5.0;
            egui::Pos2::new(cx + r * a.cos(), cy + r * a.sin())
        })
        .collect()
}

/// Puffy closed outline via radial modulation (single-valued in polar angle,
/// so fan-fill from the centroid is exact).
fn cloud_points(rect: egui::Rect) -> Vec<egui::Pos2> {
    let c = rect.center();
    let rx = rect.width() / 2.0;
    let ry = rect.height() / 2.0;
    (0..28)
        .map(|i| {
            let a = i as f32 * std::f32::consts::TAU / 28.0;
            let k = 0.82 + 0.13 * (6.0 * a).sin() + 0.05 * (3.0 * a + 1.0).cos();
            egui::Pos2::new(c.x + rx * k * a.cos(), c.y + ry * k * a.sin())
        })
        .collect()
}

/// Stadium (capsule) outline: semicircle fans joined by straight edges.
fn capsule_points(rect: egui::Rect) -> Vec<egui::Pos2> {
    let mut pts = Vec::new();
    let n = 10;
    if rect.width() >= rect.height() {
        let r = rect.height() / 2.0;
        let cy = rect.center().y;
        for i in 0..=n {
            let a = -std::f32::consts::FRAC_PI_2 + i as f32 * std::f32::consts::PI / n as f32;
            pts.push(egui::Pos2::new(
                rect.max.x - r + r * a.cos(),
                cy + r * a.sin(),
            ));
        }
        for i in 0..=n {
            let a = std::f32::consts::FRAC_PI_2 + i as f32 * std::f32::consts::PI / n as f32;
            pts.push(egui::Pos2::new(
                rect.min.x + r + r * a.cos(),
                cy + r * a.sin(),
            ));
        }
    } else {
        let r = rect.width() / 2.0;
        let cx = rect.center().x;
        for i in 0..=n {
            let a = i as f32 * std::f32::consts::PI / n as f32;
            pts.push(egui::Pos2::new(
                cx + r * a.cos(),
                rect.max.y - r + r * a.sin(),
            ));
        }
        for i in 0..=n {
            let a = std::f32::consts::PI + i as f32 * std::f32::consts::PI / n as f32;
            pts.push(egui::Pos2::new(
                cx + r * a.cos(),
                rect.min.y + r + r * a.sin(),
            ));
        }
    }
    pts
}

fn stroke_rect(painter: &egui::Painter, rect: egui::Rect, width: f32, color: egui::Color32) {
    let w = egui::Stroke::new(width, color);
    painter.line_segment([rect.min, egui::Pos2::new(rect.max.x, rect.min.y)], w);
    painter.line_segment([egui::Pos2::new(rect.max.x, rect.min.y), rect.max], w);
    painter.line_segment([rect.max, egui::Pos2::new(rect.min.x, rect.max.y)], w);
    painter.line_segment([egui::Pos2::new(rect.min.x, rect.max.y), rect.min], w);
}

fn fill_poly(painter: &egui::Painter, pts: &[egui::Pos2], fill: egui::Color32) {
    if pts.len() >= 3 {
        painter.add(egui::Shape::convex_polygon(
            pts.to_vec(),
            fill,
            egui::Stroke::NONE,
        ));
    }
}

fn stroke_poly(painter: &egui::Painter, pts: &[egui::Pos2], closed: bool, color: egui::Color32) {
    if pts.len() < 2 {
        return;
    }
    let w = egui::Stroke::new(1.0, color);
    for i in 0..pts.len() - 1 {
        painter.line_segment([pts[i], pts[i + 1]], w);
    }
    if closed {
        painter.line_segment([pts[pts.len() - 1], pts[0]], w);
    }
}

/// Exact fill for star-shaped outlines: fan triangles from the centroid are
/// each convex, so no tessellation caveats.
fn fan_fill(painter: &egui::Painter, pts: &[egui::Pos2], fill: egui::Color32) {
    if pts.len() < 3 {
        return;
    }
    let cx = pts.iter().map(|p| p.x).sum::<f32>() / pts.len() as f32;
    let cy = pts.iter().map(|p| p.y).sum::<f32>() / pts.len() as f32;
    let c = egui::Pos2::new(cx, cy);
    for i in 0..pts.len() {
        let b = pts[(i + 1) % pts.len()];
        painter.add(egui::Shape::convex_polygon(
            vec![c, pts[i], b],
            fill,
            egui::Stroke::NONE,
        ));
    }
}

fn default_shape_size(kind: ShapeKind) -> (f64, f64) {
    if kind.is_line_like() {
        (120.0, 60.0)
    } else {
        (180.0, 120.0)
    }
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

impl OpenMindApp {
    /// Open a decoded board from a path (Finder double-click / CLI arg).
    pub fn open_vsom_path(&mut self, path: &str, file: VsomDocument) {
        self.open_vsom_bytes(path, file);
        self.current_path = Some(PathBuf::from(path));
    }

    /// Open a decoded board with a display name (recovery, tests).
    pub fn open_vsom_bytes(&mut self, name: &str, file: VsomDocument) {
        let n = file.items.len();
        self.active_audio = None;
        self.doc = CanvasDoc::from_vsom_document(&file);
        self.board_title = file.board.title.clone();
        self.editing = None;
        self.textures.clear();
        self.dirty_since = None;
        self.status(format!("Opened {n} items from {name}"));
    }

    fn commit_edit(&mut self) {
        self.editing = None;
    }

    fn status(&mut self, msg: impl Into<String>) {
        self.status = msg.into();
    }

    // -- painting ----------------------------------------------------------

    fn paint_dots(&self, painter: &egui::Painter, rect: egui::Rect) {
        self.paint_background(painter, rect);
    }

    /// Configurable background: plain, dots, grid, lines, columns, graph.
    fn paint_background(&self, painter: &egui::Painter, rect: egui::Rect) {
        match self.pattern.as_str() {
            "plain" => {}
            "grid" | "graph" => self.paint_grid(painter, rect, false),
            "lines" => self.paint_grid(painter, rect, true),
            "columns" => self.paint_grid(painter, rect, true),
            _ => self.paint_dot_grid(painter, rect),
        }
        if self.pattern == "graph" {
            // Graph = grid + dots.
            self.paint_dot_grid(painter, rect);
        }
    }

    fn paint_dot_grid(&self, painter: &egui::Painter, rect: egui::Rect) {
        let mut spacing = 40.0 * self.viewport.scale;
        if spacing < 10.0 {
            return;
        }
        while spacing > 80.0 {
            spacing /= 2.0;
        }
        let ox = self.viewport.offset_x;
        let oy = self.viewport.offset_y;
        let mut start_x = ox % spacing;
        if start_x > 0.0 {
            start_x -= spacing;
        }
        let mut start_y = oy % spacing;
        if start_y > 0.0 {
            start_y -= spacing;
        }
        let ink = egui::Color32::from_gray(160);
        let mut x = start_x;
        let mut drawn = 0u32;
        while x < rect.max.x as f64 + spacing && drawn < 6000 {
            let mut y = start_y;
            while y < rect.max.y as f64 + spacing && drawn < 6000 {
                if x >= rect.min.x as f64 && y >= rect.min.y as f64 {
                    painter.circle_filled(egui::Pos2::new(x as f32, y as f32), 1.25, ink);
                    drawn += 1;
                }
                y += spacing;
            }
            x += spacing;
        }
    }

    fn paint_grid(&self, painter: &egui::Painter, rect: egui::Rect, horizontal_only: bool) {
        let mut spacing = 40.0 * self.viewport.scale;
        if spacing < 12.0 {
            return;
        }
        while spacing > 100.0 {
            spacing /= 2.0;
        }
        let line = egui::Stroke::new(1.0, egui::Color32::from_gray(210));
        let mut x = self.viewport.offset_x % spacing;
        if x > 0.0 {
            x -= spacing;
        }
        let mut count = 0u32;
        while x < rect.max.x as f64 && count < 200 {
            if x >= rect.min.x as f64 {
                painter.line_segment(
                    [
                        egui::Pos2::new(x as f32, rect.min.y),
                        egui::Pos2::new(x as f32, rect.max.y),
                    ],
                    line,
                );
                count += 1;
            }
            x += spacing;
        }
        if horizontal_only {
            return;
        }
        let mut y = self.viewport.offset_y % spacing;
        if y > 0.0 {
            y -= spacing;
        }
        count = 0;
        while y < rect.max.y as f64 && count < 200 {
            if y >= rect.min.y as f64 {
                painter.line_segment(
                    [
                        egui::Pos2::new(rect.min.x, y as f32),
                        egui::Pos2::new(rect.max.x, y as f32),
                    ],
                    line,
                );
                count += 1;
            }
            y += spacing;
        }
    }

    /// Display color for a stored ink stroke (highlighter style renders
    /// translucent, like the Swift app).
    fn ink_display(ink: &PaintedInk) -> egui::Color32 {
        let base = hex_color(&ink.color_hex);
        if ink.style() == DrawingStyle::Highlighter {
            egui::Color32::from_rgba_unmultiplied(base.r(), base.g(), base.b(), 115)
        } else {
            base
        }
    }

    fn paint_spine(
        &self,
        painter: &egui::Painter,
        spine: &[openmind_ink::SpinePoint],
        color: egui::Color32,
    ) {
        let scale = self.viewport.scale as f32;
        if spine.is_empty() {
            return;
        }
        if spine.len() == 1 {
            let s = spine[0];
            painter.circle_filled(
                to_screen(&self.viewport, (s.x, s.y)),
                ((s.width as f32 * scale) / 2.0).max(1.0),
                color,
            );
            return;
        }
        for w in spine.windows(2) {
            let (a, b) = (w[0], w[1]);
            let width = (((a.width + b.width) / 2.0) as f32 * scale).max(0.75);
            painter.line_segment(
                [
                    to_screen(&self.viewport, (a.x, a.y)),
                    to_screen(&self.viewport, (b.x, b.y)),
                ],
                egui::Stroke::new(width, color),
            );
        }
        for s in spine {
            painter.circle_filled(
                to_screen(&self.viewport, (s.x, s.y)),
                ((s.width as f32 * scale) / 2.0).max(0.75),
                color,
            );
        }
    }

    /// Filled + outlined shape in screen space.
    fn paint_shape(&self, painter: &egui::Painter, item: &CanvasItem) {
        let (shape, color_hex, label) = match &item.content {
            ItemContent::Shape {
                shape,
                color_hex,
                label,
                ..
            } => (*shape, color_hex, label),
            _ => return,
        };
        let fill = hex_color(color_hex);
        let edge = egui::Color32::from_black_alpha(50);
        let rect = frame_rect(&self.viewport, item.frame);
        if rect.width() <= 0.0 || rect.height() <= 0.0 {
            return;
        }
        match shape {
            ShapeKind::Rectangle => {
                painter.rect_filled(rect, 0.0, fill);
                stroke_rect(painter, rect, 1.0, edge);
            }
            ShapeKind::RoundedRectangle => {
                let r = ((16.0 * self.viewport.scale) as f32)
                    .min(rect.width() / 2.0)
                    .max(2.0) as u8;
                painter.rect_filled(rect, egui::CornerRadius::same(r), fill);
                stroke_rect(painter, rect, 1.0, edge);
            }
            ShapeKind::Ellipse | ShapeKind::Circle => {
                let c = rect.center();
                let pts = ngon(0.0, 0.0, 1.0, 40)
                    .into_iter()
                    .map(|p| {
                        egui::Pos2::new(
                            c.x + p.x * rect.width() / 2.0,
                            c.y + p.y * rect.height() / 2.0,
                        )
                    })
                    .collect::<Vec<_>>();
                fill_poly(painter, &pts, fill);
                stroke_poly(painter, &pts, true, edge);
            }
            ShapeKind::Triangle => {
                let pts = vec![
                    egui::Pos2::new(rect.center().x, rect.min.y),
                    egui::Pos2::new(rect.max.x, rect.max.y),
                    egui::Pos2::new(rect.min.x, rect.max.y),
                ];
                fill_poly(painter, &pts, fill);
                stroke_poly(painter, &pts, true, edge);
            }
            ShapeKind::RightTriangle => {
                let pts = vec![rect.min, egui::Pos2::new(rect.max.x, rect.min.y), rect.max];
                fill_poly(painter, &pts, fill);
                stroke_poly(painter, &pts, true, edge);
            }
            ShapeKind::Diamond => {
                let c = rect.center();
                let pts = vec![
                    egui::Pos2::new(c.x, rect.min.y),
                    egui::Pos2::new(rect.max.x, c.y),
                    egui::Pos2::new(c.x, rect.max.y),
                    egui::Pos2::new(rect.min.x, c.y),
                ];
                fill_poly(painter, &pts, fill);
                stroke_poly(painter, &pts, true, edge);
            }
            ShapeKind::Pentagon => {
                let c = rect.center();
                let pts = ngon(c.x, c.y, rect.width().min(rect.height()) / 2.0, 5);
                fill_poly(painter, &pts, fill);
                stroke_poly(painter, &pts, true, edge);
            }
            ShapeKind::Hexagon => {
                let c = rect.center();
                let pts = ngon(c.x, c.y, rect.width().min(rect.height()) / 2.0, 6);
                fill_poly(painter, &pts, fill);
                stroke_poly(painter, &pts, true, edge);
            }
            ShapeKind::Star => {
                let pts = star_points(rect);
                fan_fill(painter, &pts, fill);
                stroke_poly(painter, &pts, true, edge);
            }
            ShapeKind::Cloud => {
                let pts = cloud_points(rect);
                fan_fill(painter, &pts, fill);
                stroke_poly(painter, &pts, true, edge);
            }
            ShapeKind::Capsule => {
                let pts = capsule_points(rect);
                fan_fill(painter, &pts, fill);
                stroke_poly(painter, &pts, true, edge);
            }
            ShapeKind::Line | ShapeKind::Arrow | ShapeKind::DoubleArrow => {
                self.paint_line_like(painter, item, shape, fill);
            }
        }
        if !label.is_empty() && !shape.is_line_like() {
            painter.text(
                rect.center(),
                egui::Align2::CENTER_CENTER,
                label.clone(),
                egui::FontId::proportional((18.0 * self.viewport.scale) as f32),
                egui::Color32::BLACK,
            );
        }
    }

    /// Shaft + head(s) along the frame diagonal (Swift-compatible default for
    /// line-like shapes without stored endpoints).
    fn paint_line_like(
        &self,
        painter: &egui::Painter,
        item: &CanvasItem,
        shape: ShapeKind,
        color: egui::Color32,
    ) {
        let rect = frame_rect(&self.viewport, item.frame);
        let tail = rect.min;
        let tip = rect.max;
        let width = (3.0 * self.viewport.scale as f32).max(2.0);
        painter.line_segment([tail, tip], egui::Stroke::new(width, color));
        let len = (tip - tail).length();
        if len < 1.0 {
            return;
        }
        let head = (len * 0.25).clamp(12.0, 60.0);
        let dir = (tip - tail) / len;
        let head_at = |p: egui::Pos2, d: egui::Vec2| {
            let n = egui::Vec2::new(-d.y, d.x);
            [
                p,
                p - d * head + n * head * 0.45,
                p - d * head - n * head * 0.45,
            ]
        };
        if matches!(shape, ShapeKind::Arrow | ShapeKind::DoubleArrow) {
            fill_poly(painter, &head_at(tip, dir), color);
        }
        if matches!(shape, ShapeKind::DoubleArrow) {
            fill_poly(painter, &head_at(tail, -dir), color);
        }
    }

    // -- actions -----------------------------------------------------------

    fn create_at_center(
        &mut self,
        default_size: (f64, f64),
        make: impl FnOnce(Rect) -> CanvasItem,
    ) {
        let (wx, wy) = self.viewport.world_point(600.0, 350.0);
        let frame = Rect::new(
            wx - default_size.0 / 2.0,
            wy - default_size.1 / 2.0,
            default_size.0,
            default_size.1,
        );
        let id = self.doc.add(make(frame));
        self.editing = Some(Editing {
            id,
            buffer: String::new(),
            dirty: false,
        });
        self.tool = Tool::Select;
    }

    fn add_sticky(&mut self) {
        self.commit_edit();
        self.create_at_center((160.0, 160.0), |frame| {
            CanvasItem::sticky(frame, STICKY_YELLOW, 0.0)
        });
        self.mark_dirty();
        self.status("Sticky note added — type, Esc to finish");
    }

    fn add_text(&mut self) {
        self.commit_edit();
        self.create_at_center((240.0, 60.0), |frame| CanvasItem::text(frame, 0.0));
        self.mark_dirty();
        self.status("Text box added — type, Esc to finish");
    }

    fn import_image(&mut self) {
        let Some(path) = rfd::FileDialog::new()
            .add_filter("Images", &["png", "jpg", "jpeg", "gif"])
            .pick_file()
        else {
            return;
        };
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                self.status(format!("Couldn't read image: {e}"));
                return;
            }
        };
        let (wx, wy) = self.viewport.world_point(600.0, 350.0);
        match CanvasItem::image_from_bytes(bytes, (wx, wy), 360.0) {
            Some(item) => {
                self.commit_edit();
                self.doc.add(item);
                self.mark_dirty();
                self.tool = Tool::Select;
                self.status("Image added");
            }
            None => self.status("That file isn't a readable image"),
        }
    }

    fn mark_dirty(&mut self) {
        if self.dirty_since.is_none() {
            self.dirty_since = Some(now_unix());
        }
    }

    fn add_table(&mut self) {
        self.commit_edit();
        let (wx, wy) = self.viewport.world_point(600.0, 350.0);
        let frame = Rect::new(wx - 180.0, wy - 110.0, 360.0, 220.0);
        self.doc.add(CanvasItem::table(frame, 0.0, 3, 3));
        self.mark_dirty();
        self.tool = Tool::Select;
        self.status("Table added (3×3)");
    }

    fn add_connector(&mut self) {
        if self.doc.selection.len() < 2 {
            self.status("Select two objects first, then Connector");
            return;
        }
        let ids = self.doc.selection.clone();
        let from = ids[0].clone();
        let to = ids[1].clone();
        let bounds = self
            .doc
            .selection_bounds()
            .unwrap_or(Rect::new(5000.0, 5000.0, 120.0, 60.0));
        self.doc.add(CanvasItem::connector(bounds, 0.0, &from, &to));
        self.mark_dirty();
        self.status("Connector added — stays attached when objects move");
    }

    fn add_audio_from_file(&mut self) {
        let Some(path) = rfd::FileDialog::new()
            .add_filter("Audio", &["wav", "mp3", "m4a", "ogg"])
            .pick_file()
        else {
            return;
        };
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                self.status(format!("Couldn't read audio: {e}"));
                return;
            }
        };
        // Validate via the media store (extension + magic, size limits) without
        // blocking the canvas on decode: import only yields a lightweight ref.
        let dir = std::env::temp_dir().join("openmind-assets");
        let store = openmind_media::FileAssetStore::new(&dir);
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("audio");
        match store.import_bytes(name, &bytes, &openmind_media::ImportLimits::default()) {
            Ok(imported) => {
                let (wx, wy) = self.viewport.world_point(600.0, 350.0);
                let frame = Rect::new(wx - 150.0, wy - 55.0, 300.0, 110.0);
                let mut card = CanvasItem::audio_card(
                    frame,
                    0.0,
                    name.to_string(),
                    imported.asset.hash.clone(),
                );
                if let ItemContent::Audio {
                    file_name,
                    duration_secs,
                    ..
                } = &mut card.content
                {
                    *file_name = name.to_string();
                    *duration_secs = imported.asset.duration_secs.unwrap_or(0.0);
                }
                self.doc.add(card);
                self.mark_dirty();
                self.status(format!("Audio added ({})", imported.asset.mime));
            }
            Err(e) => self.status(format!("Audio import failed: {e}")),
        }
    }

    fn toggle_recording(&mut self) {
        // Mic permission is requested by the OS on first capture; we only
        // enter this state from an explicit toolbar action (plan §7.1).
        if self.recording {
            // Stop: finalize a WAV via the mock capture (cpal/AVFoundation
            // adapters plug in behind the same trait), attach an audio card.
            let mut cap = openmind_media_audio::MockCapture::new();
            let session = match cap.start(openmind_media_audio::RecordingOptions::default()) {
                Ok(s) => s,
                Err(e) => {
                    self.status(format!("Recording failed: {e}"));
                    self.recording = false;
                    return;
                }
            };
            // 1s of silence as placeholder PCM; real capture streams device
            // samples through a bounded queue on a worker.
            let samples = vec![0i16; 44100];
            match cap.stop(session, &samples) {
                Ok(asset) => {
                    let (wx, wy) = self.viewport.world_point(600.0, 350.0);
                    let frame = Rect::new(wx - 150.0, wy - 55.0, 300.0, 110.0);
                    let mut card = CanvasItem::audio_card(
                        frame,
                        0.0,
                        "Voice note".to_string(),
                        asset.asset_hash.clone(),
                    );
                    if let ItemContent::Audio { duration_secs, .. } = &mut card.content {
                        *duration_secs = asset.duration_secs;
                    }
                    self.doc.add(card);
                    self.mark_dirty();
                    self.status(format!(
                        "Voice note added ({:.1}s, wav)",
                        asset.duration_secs
                    ));
                }
                Err(e) => self.status(format!("Recording failed: {e}")),
            }
            self.recording = false;
        } else {
            self.recording = true;
            self.recording_start = now_unix();
            self.status("Recording… press Record again to stop (mic permission asked once)");
        }
    }

    fn add_video_from_file(&mut self) {
        let Some(path) = rfd::FileDialog::new()
            .add_filter("Video", &["mp4", "mov", "m4v", "webm"])
            .pick_file()
        else {
            return;
        };
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                self.status(format!("Couldn't read video: {e}"));
                return;
            }
        };
        let backend = openmind_media_video::MockVideoBackend;
        let meta = backend
            .probe(&bytes)
            .unwrap_or_else(|_| openmind_media_video::VideoMetadata::unknown());
        let (wx, wy) = self.viewport.world_point(600.0, 350.0);
        let frame = Rect::new(wx - 240.0, wy - 150.0, 480.0, 300.0);
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("video")
            .to_string();
        let hash = openmind_board::hash_bytes(&bytes);
        let mut card = CanvasItem::video_card(frame, 0.0, name.clone(), hash);
        if let ItemContent::Video {
            file_name,
            duration_secs,
            ..
        } = &mut card.content
        {
            *file_name = name;
            *duration_secs = meta.duration_secs.unwrap_or(0.0);
        }
        self.doc.add(card);
        self.mark_dirty();
        self.status("Video card added (poster; playback in overlay)");
    }

    fn commit_youtube_dialog(&mut self) {
        let url = self.youtube_buffer.trim().to_string();
        match openmind_media::parse_youtube_url(&url) {
            Ok(yt) => {
                let (wx, wy) = self.viewport.world_point(600.0, 350.0);
                let frame = Rect::new(wx - 240.0, wy - 150.0, 480.0, 300.0);
                self.doc
                    .add(CanvasItem::youtube_card(frame, 0.0, yt.video_id.clone()));
                self.mark_dirty();
                self.status(format!(
                    "YouTube added ({}) — click Play to open",
                    yt.video_id
                ));
                self.youtube_buffer.clear();
                self.show_youtube_dialog = false;
            }
            Err(e) => self.status(format!("Not a YouTube URL: {e}")),
        }
    }

    fn commit_video_url_dialog(&mut self) {
        let url = self.video_buffer.trim().to_string();
        match openmind_media::ExternalMedia::parse(
            &url,
            openmind_media::MediaLinkDecision::KeepLinked,
        ) {
            Some(ext) => {
                let (wx, wy) = self.viewport.world_point(600.0, 350.0);
                let frame = Rect::new(wx - 240.0, wy - 150.0, 480.0, 300.0);
                // Linked network video: lightweight card, explicit offline state.
                self.doc.add(CanvasItem::video_card(
                    frame,
                    0.0,
                    ext.domain.clone(),
                    String::new(),
                ));
                self.mark_dirty();
                self.status(format!("Linked video ({}) — needs network", ext.domain));
                self.video_buffer.clear();
                self.show_video_dialog = false;
            }
            None => self.status("Enter an https URL without credentials"),
        }
    }

    fn new_from_template(&mut self) {
        let picks = openmind_canvas::templates::Template::all();
        let t = picks[self.template_pick % picks.len()];
        self.doc = t.build();
        self.mark_dirty();
        self.editing = None;
        self.textures.clear();
        self.status(format!("Template: {}", t.title()));
    }

    fn export_file(&mut self, kind: &str) {
        use openmind_export::{export_pdf, export_png, export_svg, media_manifest, ExportScope};
        let scope = if self.doc.selection.is_empty() {
            ExportScope::WholeBoard
        } else {
            ExportScope::Selection
        };
        let ext = match kind {
            "png" => "png",
            "svg" => "svg",
            "pdf" => "pdf",
            _ => "txt",
        };
        let Some(path) = rfd::FileDialog::new()
            .add_filter(format!("{ext} export"), &[ext])
            .set_file_name(format!("{} Board.{ext}", self.board_title))
            .save_file()
        else {
            return;
        };
        let result: Result<Vec<u8>, String> = match kind {
            "png" => export_png(&self.doc, scope, 2.0),
            "svg" => export_svg(&self.doc, scope).map(|s| s.into_bytes()),
            "pdf" => export_pdf(&self.doc, scope),
            _ => Ok(media_manifest(&self.doc).into_bytes()),
        };
        match result {
            Ok(bytes) => match std::fs::write(&path, &bytes) {
                Ok(()) => self.status(format!("Exported {}", path.display())),
                Err(e) => self.status(format!("Export failed: {e}")),
            },
            Err(e) => self.status(format!("Export failed: {e}")),
        }
    }

    fn play_selection(&mut self) {
        // Policy: one active audio player. Selecting another card stops the
        // previous one; closing the board stops playback.
        let Some(id) = self.doc.selection.first().cloned() else {
            self.status("Select an audio or YouTube card first");
            return;
        };
        let Some(item) = self.doc.find(&id) else {
            return;
        };
        match &item.content {
            ItemContent::Audio { title, .. } => {
                if self.active_audio.as_ref() == Some(&id) {
                    self.active_audio = None;
                    self.status(format!("Paused {title}"));
                } else {
                    self.active_audio = Some(id);
                    self.status(format!("Playing {title} (mock player; one at a time)"));
                }
            }
            ItemContent::Youtube { video_id, .. } => {
                let url = format!("https://www.youtube.com/watch?v={video_id}");
                // External browser fallback (no per-card web views).
                #[allow(unused)]
                let _ = open_browser(&url);
                self.status(format!("Opened YouTube {video_id} in browser"));
            }
            ItemContent::Video { title, .. } => {
                self.status(format!(
                    "Video {title}: playback opens in overlay (poster on canvas)"
                ));
            }
            _ => self.status("Selected item is not playable"),
        }
    }

    fn autosave_tick(&mut self) {
        // Debounced autosave off the critical path: serialize a snapshot and
        // atomic-write beside the current file (or a recovery dir). Never
        // blocks pointer handling; called once per frame.
        let Some(since) = self.dirty_since else {
            return;
        };
        let now = now_unix();
        if now - since < 2.0 {
            return;
        }
        let doc = self.doc.to_vsom_document(&self.board_title);
        let Ok(bytes) = doc.encode() else { return };
        let mgr = openmind_engine::AutosaveManager::new(openmind_engine::AutosaveConfig::default());
        let dir = self
            .current_path
            .as_ref()
            .and_then(|p| p.parent().map(|p| p.to_path_buf()))
            .unwrap_or_else(|| std::env::temp_dir().join("openmind-autosave"));
        // Best-effort: failures surface as status, never as lost work.
        match mgr.write_snapshot(&dir, "autosave.vsom", &bytes) {
            Ok(_) => {
                self.dirty_since = None;
                self.last_autosave = now;
                let journal = openmind_engine::RecoveryJournal::new(dir, 3);
                let _ = journal.append(&bytes);
            }
            Err(e) => self.status(format!("Autosave failed: {e}")),
        }
    }

    fn save_board(&mut self) {
        let path = match &self.current_path {
            Some(p) => p.clone(),
            None => {
                let Some(p) = rfd::FileDialog::new()
                    .add_filter("OpenMind board", &["vsom"])
                    .set_file_name("Untitled Board.vsom")
                    .save_file()
                else {
                    return;
                };
                self.current_path = Some(p.clone());
                p
            }
        };
        let doc = self.doc.to_vsom_document(&self.board_title);
        let result = doc.encode().and_then(|b| {
            std::fs::write(&path, &b).map_err(|e| openmind_board::VsomError::Corrupt(e.to_string()))
        });
        match result {
            Ok(()) => {
                self.status(format!("Saved {}", path.display()));
                self.dirty_since = None;
                self.last_autosave = now_unix();
                // Stop playback on save-close semantics: keep playing only if
                // the user explicitly resumes (plan §8.2).
            }
            Err(e) => self.status(format!("Couldn't save: {e}")),
        }
    }

    fn open_board(&mut self) {
        let Some(path) = rfd::FileDialog::new()
            .add_filter("OpenMind board", &["vsom"])
            .pick_file()
        else {
            return;
        };
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                self.status(format!("Couldn't read file: {e}"));
                return;
            }
        };
        match VsomDocument::decode(&bytes) {
            Ok(file) => {
                let n = file.items.len();
                let carried = file
                    .items
                    .iter()
                    .filter(|i| openmind_board::ItemKind::parse(&i.kind_raw).is_none())
                    .count();
                // Stop playback when the board closes (plan §8.2).
                self.active_audio = None;
                self.doc = CanvasDoc::from_vsom_document(&file);
                self.board_title = file.board.title.clone();
                // Adopt the file's pattern when known.
                if ["plain", "dots", "grid", "lines", "columns", "graph"]
                    .contains(&file.board.canvas_pattern_raw.as_str())
                {
                    self.pattern = file.board.canvas_pattern_raw.clone();
                }
                self.current_path = Some(path);
                self.editing = None;
                self.marquee = None;
                self.move_drag = None;
                self.shape_anchor = None;
                self.shape_current = None;
                self.ink_builder = None;
                self.ink_raw.clear();
                self.textures.clear();
                self.dirty_since = None;
                self.status(format!("Opened {n} items ({carried} carried as-is)"));
            }
            Err(e) => self.status(format!("Couldn't open board: {e}")),
        }
    }

    fn commit_shape_drag(&mut self) {
        let (Some(a), Some(b)) = (self.shape_anchor.take(), self.shape_current.take()) else {
            return;
        };
        let kind = match self.tool {
            Tool::Shape(k) => k,
            _ => return,
        };
        let span = ((b.0 - a.0).abs().max((b.1 - a.1).abs())) * self.viewport.scale;
        let frame = if span < 4.0 {
            // Click without a drag: default-size shape at the anchor.
            let (dw, dh) = default_shape_size(kind);
            Rect::new(a.0 - dw / 2.0, a.1 - dh / 2.0, dw, dh)
        } else {
            let mut r = normalize_rect(a, b);
            r.w = r.w.max(8.0);
            r.h = r.h.max(8.0);
            r
        };
        self.doc
            .add(CanvasItem::shape(kind, frame, SHAPE_BLUE, 0.0));
        self.mark_dirty();
        self.tool = Tool::Select;
    }

    fn commit_ink(&mut self) {
        let builder = match self.ink_builder.take() {
            Some(b) => b,
            None => return,
        };
        self.ink_raw.clear();
        let Some(stroke) = builder.finish() else {
            return;
        };
        // Ignore accidental taps (mirrors Swift's minimum-span guard).
        if stroke.spine.len() <= 1 {
            let b = stroke.bounds;
            if b.width() < 2.0 && b.height() < 2.0 {
                return;
            }
        }
        let (style_raw, color_hex, line_width) = match self.ink_tool {
            InkTool::Pen => ("pen", PEN_HEX, PEN_WIDTH),
            InkTool::Highlighter => ("highlighter", HIGHLIGHTER_HEX, HIGHLIGHTER_WIDTH),
        };
        let pad = line_width / 2.0 + 2.0;
        let bounds = stroke.bounds;
        let frame = Rect::new(
            bounds.x0 - pad,
            bounds.y0 - pad,
            (bounds.width() + pad * 2.0).max(4.0),
            (bounds.height() + pad * 2.0).max(4.0),
        );
        self.doc.add(CanvasItem {
            id: openmind_canvas::id(),
            kind_raw: "drawing".to_string(),
            frame,
            z: 0.0,
            locked: false,
            group: None,
            page: 0,
            content: ItemContent::Drawing {
                strokes: vec![PaintedInk {
                    stroke,
                    style_raw: style_raw.to_string(),
                    color_hex: color_hex.to_string(),
                    line_width,
                }],
            },
        });
        self.mark_dirty();
    }
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

struct FrameInput {
    pos: Option<egui::Pos2>,
    primary_down: bool,
    primary_pressed: bool,
    primary_released: bool,
    middle_down: bool,
    shift: bool,
    zoom_delta: f32,
    scroll_delta: egui::Vec2,
    delete_pressed: bool,
    escape_pressed: bool,
    undo_pressed: bool,
    redo_pressed: bool,
    duplicate_pressed: bool,
    group_pressed: bool,
    ungroup_pressed: bool,
    save_pressed: bool,
    open_pressed: bool,
    select_all_pressed: bool,
    lock_pressed: bool,
    tool_pen: bool,
    tool_eraser: bool,
    tool_hand: bool,
    tool_select: bool,
    double_clicked: bool,
    typing: bool,
}

impl eframe::App for OpenMindApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.update(ui);
    }
}

impl OpenMindApp {
    fn update(&mut self, ui: &mut egui::Ui) {
        // -- toolbar -------------------------------------------------------
        egui::Panel::top("toolbar").show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.selectable_value(&mut self.tool, Tool::Select, Tool::Select.label())
                    .on_hover_text("Select: click, Shift-click, marquee (V)");
                ui.selectable_value(&mut self.tool, Tool::Pen, Tool::Pen.label())
                    .on_hover_text("Pen (P)");
                ui.selectable_value(&mut self.tool, Tool::Highlighter, Tool::Highlighter.label())
                    .on_hover_text("Highlighter (H)");
                ui.selectable_value(&mut self.tool, Tool::Eraser, Tool::Eraser.label())
                    .on_hover_text("Eraser (E)");
                ui.selectable_value(&mut self.tool, Tool::Hand, Tool::Hand.label())
                    .on_hover_text("Hand/pan (Space or middle-drag)");
                ui.separator();
                if ui
                    .button("Sticky")
                    .on_hover_text("Sticky note (S)")
                    .clicked()
                {
                    self.tool = Tool::Select;
                    self.add_sticky();
                }
                if ui.button("Text").on_hover_text("Text box (T)").clicked() {
                    self.tool = Tool::Select;
                    self.add_text();
                }
                if ui
                    .button("Table")
                    .on_hover_text("Insert 3×3 table")
                    .clicked()
                {
                    self.add_table();
                }
                if ui
                    .button("Connector")
                    .on_hover_text("Connect two selected objects")
                    .clicked()
                {
                    self.add_connector();
                }
                if ui
                    .button("Image")
                    .on_hover_text("Import image (PNG/JPG/GIF)")
                    .clicked()
                {
                    self.import_image();
                }
                ui.separator();
                if ui
                    .button(if self.recording {
                        "⏹ Stop"
                    } else {
                        "● Record"
                    })
                    .on_hover_text("Record voice note (mic permission asked once)")
                    .clicked()
                {
                    self.toggle_recording();
                }
                if ui
                    .button("Audio")
                    .on_hover_text("Import audio file")
                    .clicked()
                {
                    self.add_audio_from_file();
                }
                if ui
                    .button("Video")
                    .on_hover_text("Import video file")
                    .clicked()
                {
                    self.add_video_from_file();
                }
                if ui
                    .button("YouTube")
                    .on_hover_text("Add YouTube embed (click-to-load)")
                    .clicked()
                {
                    self.show_youtube_dialog = true;
                }
                if ui
                    .button("URL")
                    .on_hover_text("Add linked network video")
                    .clicked()
                {
                    self.show_video_dialog = true;
                }
                ui.separator();
                if ui
                    .button("Open")
                    .on_hover_text("Open .vsom (Cmd+O)")
                    .clicked()
                {
                    self.open_board();
                }
                if ui
                    .button("Save")
                    .on_hover_text("Save .vsom (Cmd+S)")
                    .clicked()
                {
                    self.save_board();
                }
                ui.text_edit_singleline(&mut self.board_title);
                ui.separator();
                let can_undo = self.doc.can_undo();
                let can_redo = self.doc.can_redo();
                if ui
                    .add_enabled(can_undo, egui::Button::new("Undo"))
                    .on_hover_text("Undo (Cmd+Z)")
                    .clicked()
                {
                    self.commit_edit();
                    self.doc.undo();
                    self.mark_dirty();
                }
                if ui
                    .add_enabled(can_redo, egui::Button::new("Redo"))
                    .on_hover_text("Redo (Cmd+Shift+Z)")
                    .clicked()
                {
                    self.commit_edit();
                    self.doc.redo();
                    self.mark_dirty();
                }
            });
            ui.horizontal(|ui| {
                egui::ScrollArea::horizontal().show(ui, |ui| {
                    ui.horizontal(|ui| {
                        for kind in ALL_SHAPES {
                            ui.selectable_value(
                                &mut self.tool,
                                Tool::Shape(kind),
                                shape_title(kind),
                            );
                        }
                    });
                });
            });
            ui.horizontal(|ui| {
                // Background / pattern + templates + export (plan §9, §11).
                egui::ComboBox::from_label("Background")
                    .selected_text(self.pattern.clone())
                    .show_ui(ui, |ui| {
                        for p in ["plain", "dots", "grid", "lines", "columns", "graph"] {
                            ui.selectable_value(&mut self.pattern, p.to_string(), p);
                        }
                    });
                let picks = openmind_canvas::templates::Template::all();
                let titles: Vec<&str> = picks.iter().map(|t| t.title()).collect();
                egui::ComboBox::from_label("Template")
                    .selected_text(titles[self.template_pick % titles.len()])
                    .show_ui(ui, |ui| {
                        for (i, title) in titles.iter().enumerate() {
                            ui.selectable_value(&mut self.template_pick, i, *title);
                        }
                    });
                if ui.button("New from template").clicked() {
                    self.new_from_template();
                }
                ui.separator();
                if ui
                    .button("PNG")
                    .on_hover_text("Export PNG (selection or board)")
                    .clicked()
                {
                    self.export_file("png");
                }
                if ui.button("SVG").on_hover_text("Export SVG").clicked() {
                    self.export_file("svg");
                }
                if ui.button("PDF").on_hover_text("Export PDF").clicked() {
                    self.export_file("pdf");
                }
                if ui
                    .button("Manifest")
                    .on_hover_text("Export media manifest")
                    .clicked()
                {
                    self.export_file("manifest");
                }
                if self.recording {
                    ui.colored_label(egui::Color32::RED, "● REC");
                }
                if self.dirty_since.is_some() {
                    ui.label("• unsaved");
                } else if self.last_autosave > 0.0 {
                    ui.label("saved");
                }
            });
        });

        // YouTube + network-video dialogs (isolated, click-to-load; no live
        // web views on the canvas).
        if self.show_youtube_dialog {
            egui::Window::new("Add YouTube").show(ui.ctx(), |ui| {
                ui.label("Paste a watch / youtu.be / shorts / embed URL:");
                ui.text_edit_singleline(&mut self.youtube_buffer);
                ui.horizontal(|ui| {
                    if ui.button("Add").clicked() {
                        self.commit_youtube_dialog();
                    }
                    if ui.button("Cancel").clicked() {
                        self.show_youtube_dialog = false;
                        self.youtube_buffer.clear();
                    }
                });
                ui.label("Plays click-to-load; blocked videos offer Open in YouTube.");
            });
        }
        if self.show_video_dialog {
            egui::Window::new("Add video URL").show(ui, |ui| {
                ui.label("Direct https media URL (kept linked; needs network):");
                ui.text_edit_singleline(&mut self.video_buffer);
                ui.horizontal(|ui| {
                    if ui.button("Add linked").clicked() {
                        self.commit_video_url_dialog();
                    }
                    if ui.button("Cancel").clicked() {
                        self.show_video_dialog = false;
                        self.video_buffer.clear();
                    }
                });
            });
        }

        // -- item actions ---------------------------------------------------
        let sel_empty = self.doc.selection.is_empty();
        let can_group = self.doc.selection.len() >= 2;
        egui::Panel::top("actions").show(ui, |ui| {
            ui.horizontal(|ui| {
                if ui
                    .add_enabled(!sel_empty, egui::Button::new("Duplicate"))
                    .on_hover_text("Duplicate (Cmd+D)")
                    .clicked()
                {
                    self.commit_edit();
                    self.doc.duplicate_selection();
                    self.mark_dirty();
                }
                if ui
                    .add_enabled(!sel_empty, egui::Button::new("Front"))
                    .clicked()
                {
                    self.doc.bring_to_front();
                    self.mark_dirty();
                }
                if ui
                    .add_enabled(!sel_empty, egui::Button::new("Back"))
                    .clicked()
                {
                    self.doc.send_to_back();
                    self.mark_dirty();
                }
                if ui
                    .add_enabled(can_group, egui::Button::new("Group"))
                    .on_hover_text("Group (Cmd+G)")
                    .clicked()
                {
                    self.doc.group_selection();
                    self.mark_dirty();
                }
                if ui
                    .add_enabled(!sel_empty, egui::Button::new("Ungroup"))
                    .on_hover_text("Ungroup (Cmd+Shift+G)")
                    .clicked()
                {
                    self.doc.ungroup_selection();
                    self.mark_dirty();
                }
                if ui
                    .add_enabled(!sel_empty, egui::Button::new("Lock"))
                    .on_hover_text("Lock selection (Cmd+L)")
                    .clicked()
                {
                    let ids = self.doc.selection.clone();
                    for id in ids {
                        self.doc.set_locked(&id, true);
                    }
                    self.mark_dirty();
                }
                if ui
                    .add_enabled(!sel_empty, egui::Button::new("Unlock"))
                    .clicked()
                {
                    let ids = self.doc.selection.clone();
                    for id in ids {
                        self.doc.set_locked(&id, false);
                    }
                    self.mark_dirty();
                }
                if ui
                    .add_enabled(!sel_empty, egui::Button::new("Play"))
                    .on_hover_text("Play selected audio/YouTube (one at a time)")
                    .clicked()
                {
                    self.play_selection();
                }
                if ui
                    .add_enabled(!sel_empty, egui::Button::new("Delete"))
                    .on_hover_text("Delete (Del)")
                    .clicked()
                {
                    self.commit_edit();
                    self.doc.delete_selection();
                    self.mark_dirty();
                }
            });
        });

        egui::Panel::bottom("status").show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.label(format!(
                    "{} items · {} selected",
                    self.doc.items.len(),
                    self.doc.selection.len()
                ));
                ui.separator();
                ui.label(format!("{:.0}%", self.viewport.scale * 100.0));
                ui.separator();
                ui.label(self.status.clone());
                if !self.doc.foreign.is_empty() {
                    ui.separator();
                    ui.label(format!("(+{} carried)", self.doc.foreign.len()));
                }
                if self.recording {
                    ui.separator();
                    ui.colored_label(egui::Color32::RED, "● recording");
                }
                if self.dirty_since.is_some() {
                    ui.separator();
                    ui.label("unsaved changes (autosave in 2s)");
                }
            });
        });

        // -- canvas ----------------------------------------------------------
        egui::CentralPanel::default().show(ui, |ui| {
            let (rect, _) =
                ui.allocate_exact_size(ui.available_size(), egui::Sense::click_and_drag());
            let painter = ui.painter().with_clip_rect(rect);

            // Read BEFORE locking for input: `input()` runs its closure
            // while holding the context lock, and parking_lot RwLocks are
            // not re-entrant — querying the context in here deadlocks the
            // main thread (spinning cursor, forever).
            let typing = ui.ctx().egui_wants_keyboard_input();
            let input = ui.ctx().input(|i| FrameInput {
                pos: i.pointer.latest_pos(),
                primary_down: i.pointer.primary_down(),
                primary_pressed: i.pointer.primary_pressed(),
                primary_released: i.pointer.primary_released(),
                middle_down: i.pointer.middle_down(),
                shift: i.modifiers.shift,
                zoom_delta: i.zoom_delta(),
                scroll_delta: i.smooth_scroll_delta(),
                delete_pressed: i.key_pressed(egui::Key::Delete)
                    || i.key_pressed(egui::Key::Backspace),
                escape_pressed: i.key_pressed(egui::Key::Escape),
                undo_pressed: i.modifiers.command
                    && i.key_pressed(egui::Key::Z)
                    && !i.modifiers.shift,
                redo_pressed: i.modifiers.command
                    && (i.key_pressed(egui::Key::Y)
                        || (i.key_pressed(egui::Key::Z) && i.modifiers.shift)),
                duplicate_pressed: i.modifiers.command && i.key_pressed(egui::Key::D),
                group_pressed: i.modifiers.command
                    && i.key_pressed(egui::Key::G)
                    && !i.modifiers.shift,
                ungroup_pressed: i.modifiers.command
                    && i.key_pressed(egui::Key::G)
                    && i.modifiers.shift,
                save_pressed: i.modifiers.command && i.key_pressed(egui::Key::S),
                open_pressed: i.modifiers.command && i.key_pressed(egui::Key::O),
                select_all_pressed: i.modifiers.command && i.key_pressed(egui::Key::A),
                lock_pressed: i.modifiers.command && i.key_pressed(egui::Key::L),
                tool_pen: i.key_pressed(egui::Key::P),
                tool_eraser: i.key_pressed(egui::Key::E),
                tool_hand: i.key_pressed(egui::Key::H),
                tool_select: i.key_pressed(egui::Key::V),
                double_clicked: i
                    .pointer
                    .button_double_clicked(egui::PointerButton::Primary),
                typing,
            });
            let on_canvas = input.pos.is_some_and(|p| rect.contains(p));
            let editing = self.editing.is_some();

            // Global keys (not while typing, like the Swift app).
            if input.escape_pressed {
                if self.editing.is_some() {
                    self.commit_edit();
                } else {
                    self.shape_anchor = None;
                    self.shape_current = None;
                    self.marquee = None;
                    self.move_drag = None;
                    self.doc.deselect_all();
                }
            } else if !editing && !input.typing {
                if input.delete_pressed {
                    self.doc.delete_selection();
                    self.mark_dirty();
                }
                if input.undo_pressed {
                    self.doc.undo();
                    self.mark_dirty();
                }
                if input.redo_pressed {
                    self.doc.redo();
                    self.mark_dirty();
                }
                if input.duplicate_pressed {
                    self.doc.duplicate_selection();
                    self.mark_dirty();
                }
                if input.group_pressed {
                    self.doc.group_selection();
                    self.mark_dirty();
                }
                if input.ungroup_pressed {
                    self.doc.ungroup_selection();
                    self.mark_dirty();
                }
                if input.save_pressed {
                    self.save_board();
                }
                if input.open_pressed {
                    self.open_board();
                }
                if input.select_all_pressed {
                    let ids: Vec<ItemId> = self.doc.items.iter().map(|it| it.id.clone()).collect();
                    self.doc.selection = ids;
                }
                if input.lock_pressed {
                    let ids = self.doc.selection.clone();
                    for id in ids {
                        let locked = self.doc.find(&id).is_some_and(|it| it.locked);
                        self.doc.set_locked(&id, !locked);
                    }
                    self.mark_dirty();
                }
                if input.tool_pen {
                    self.tool = Tool::Pen;
                }
                if input.tool_eraser {
                    self.tool = Tool::Eraser;
                }
                if input.tool_hand {
                    self.tool = Tool::Hand;
                }
                if input.tool_select {
                    self.tool = Tool::Select;
                }
            }

            // Debounced autosave (never blocks pointer handling).
            self.autosave_tick();
            // Recording elapsed indicator.
            if self.recording {
                let elapsed = now_unix() - self.recording_start;
                self.status(format!("● Recording {elapsed:.0}s — press Record to stop"));
            }

            // Zoom around the cursor; trackpad scroll pans (not mid-draw).
            if on_canvas && input.zoom_delta != 1.0 {
                if let Some(p) = input.pos {
                    self.viewport = self.viewport.applying(
                        0.0,
                        0.0,
                        input.zoom_delta as f64,
                        p.x as f64,
                        p.y as f64,
                    );
                }
            }
            if on_canvas && !input.primary_down {
                let d = input.scroll_delta;
                if d.x != 0.0 || d.y != 0.0 {
                    self.viewport = self
                        .viewport
                        .applying(d.x as f64, d.y as f64, 1.0, 0.0, 0.0);
                }
            }

            // Panning: middle-drag under any tool, or Hand + primary drag.
            let want_pan = input.middle_down || (self.tool == Tool::Hand && input.primary_down);
            let mut pan_delta: Option<egui::Vec2> = None;
            if want_pan {
                if let (Some(p), Some(last)) = (input.pos, self.last_pointer) {
                    if on_canvas {
                        pan_delta = Some(p - last);
                    }
                }
            }
            if let Some(d) = pan_delta {
                self.viewport = self
                    .viewport
                    .applying(d.x as f64, d.y as f64, 1.0, 0.0, 0.0);
            }

            if on_canvas && input.primary_pressed {
                self.press(input.pos.expect("on canvas"), input.shift);
            } else if input.primary_down {
                if let Some(p) = input.pos {
                    if on_canvas {
                        let world = self.viewport.world_point(p.x as f64, p.y as f64);
                        self.drag(world, p);
                    }
                }
            }
            if input.primary_released {
                if let Some(p) = input.pos {
                    let world = self.viewport.world_point(p.x as f64, p.y as f64);
                    self.release(world, input.shift);
                } else {
                    self.release_none();
                }
            }
            if !input.primary_down && !input.middle_down {
                self.move_drag = None;
            }
            self.last_pointer = input.pos;

            // Double-click (select tool) enters text editing.
            if on_canvas && input.double_clicked && !editing && matches!(self.tool, Tool::Select) {
                if let Some(p) = input.pos {
                    let world = self.viewport.world_point(p.x as f64, p.y as f64);
                    if let Some(id) = self.doc.hit_topmost(world.0, world.1) {
                        let text_like = matches!(
                            self.doc.find(&id).map(|i| &i.content),
                            Some(
                                ItemContent::Sticky { .. }
                                    | ItemContent::Text { .. }
                                    | ItemContent::RichText { .. }
                                    | ItemContent::Shape { .. }
                                    | ItemContent::Connector { .. }
                                    | ItemContent::Table { .. }
                                    | ItemContent::Audio { .. }
                                    | ItemContent::Video { .. }
                                    | ItemContent::Youtube { .. }
                            )
                        );
                        if text_like {
                            self.doc.select(&id, false);
                            let buffer = self
                                .doc
                                .find(&id)
                                .expect("hit")
                                .display_text()
                                .unwrap_or_default();
                            self.editing = Some(Editing {
                                id,
                                buffer,
                                dirty: false,
                            });
                        }
                    }
                }
            }

            self.paint(ui, &painter, rect, on_canvas.then_some(input.pos).flatten());
            self.show_text_labels(ui);
            self.show_editor(ui);
        });
    }

    // -- pointer gestures ----------------------------------------------------

    fn press(&mut self, pos: egui::Pos2, shift: bool) {
        if self.editing.is_some() {
            self.commit_edit();
        }
        let world = self.viewport.world_point(pos.x as f64, pos.y as f64);
        match self.tool {
            Tool::Select => {
                if let Some(id) = self.doc.hit_topmost(world.0, world.1) {
                    if shift {
                        self.doc.select(&id, true);
                    } else if !self.doc.selection.contains(&id) {
                        self.doc.select(&id, false);
                    }
                    self.move_drag = Some(MoveDrag {
                        last_world: world,
                        moved: false,
                        snapshot: false,
                    });
                } else {
                    if !shift {
                        self.doc.deselect_all();
                    }
                    self.marquee = Some(Marquee {
                        start: pos,
                        cur: pos,
                        additive: shift,
                    });
                }
            }
            Tool::Pen | Tool::Highlighter => {
                let (cfg, ink_tool) = match self.tool {
                    Tool::Pen => (pen_config(), InkTool::Pen),
                    _ => (highlighter_config(), InkTool::Highlighter),
                };
                self.ink_tool = ink_tool;
                let mut builder = StrokeBuilder::new(cfg, ink_tool);
                builder.push(InkPoint::new(world.0, world.1));
                self.ink_builder = Some(builder);
                self.ink_raw = vec![world];
            }
            Tool::Eraser => {
                self.erase_snapshot = false;
                let extra = 8.0 / self.viewport.scale;
                if would_erase(&self.doc, world.0, world.1, extra) {
                    self.doc.push_undo();
                    self.erase_snapshot = true;
                }
                if self.doc.erase_at(world.0, world.1, extra) {
                    self.mark_dirty();
                }
            }
            Tool::Hand => {}
            Tool::Shape(_) => {
                self.shape_anchor = Some(world);
                self.shape_current = Some(world);
            }
        }
    }

    fn drag(&mut self, world: (f64, f64), screen: egui::Pos2) {
        match self.tool {
            Tool::Select => {
                if let Some(m) = self.marquee.as_mut() {
                    m.cur = screen;
                    let rect = marquee_world(&self.viewport, m.start, m.cur);
                    let additive = m.additive;
                    self.doc.select_marquee(rect, additive);
                } else if let Some(drag) = self.move_drag.as_mut() {
                    let dx = world.0 - drag.last_world.0;
                    let dy = world.1 - drag.last_world.1;
                    if !drag.moved && (dx * dx + dy * dy).sqrt() * self.viewport.scale < 3.0 {
                        return;
                    }
                    if !drag.snapshot {
                        let movable = self.doc.selected_items().iter().any(|i| !i.locked);
                        if !movable {
                            return;
                        }
                        self.doc.push_undo();
                        drag.snapshot = true;
                    }
                    drag.moved = true;
                    drag.last_world = world;
                    self.doc.move_selection(dx, dy);
                    self.mark_dirty();
                }
            }
            Tool::Pen | Tool::Highlighter => {
                if let Some(builder) = self.ink_builder.as_mut() {
                    builder.push(InkPoint::new(world.0, world.1));
                    self.ink_raw.push(world);
                }
            }
            Tool::Eraser => {
                let extra = 8.0 / self.viewport.scale;
                if !self.erase_snapshot && would_erase(&self.doc, world.0, world.1, extra) {
                    self.doc.push_undo();
                    self.erase_snapshot = true;
                }
                self.doc.erase_at(world.0, world.1, extra);
            }
            Tool::Hand => {}
            Tool::Shape(_) => {
                self.shape_current = Some(world);
            }
        }
    }

    fn release(&mut self, world: (f64, f64), shift: bool) {
        match self.tool {
            Tool::Select => {
                if self.marquee.take().is_some() {
                    // Selection already updated live during the drag.
                } else if let Some(drag) = self.move_drag.take() {
                    if !drag.moved && !shift {
                        // Plain click: collapse to the topmost item.
                        if let Some(id) = self.doc.hit_topmost(world.0, world.1) {
                            self.doc.select(&id, false);
                        }
                    }
                }
            }
            Tool::Pen | Tool::Highlighter => self.commit_ink(),
            Tool::Eraser => self.erase_snapshot = false,
            Tool::Hand => {}
            Tool::Shape(_) => self.commit_shape_drag(),
        }
    }

    fn release_none(&mut self) {
        // Released off-canvas: finalize gestures without a new position.
        self.marquee.take();
        self.move_drag.take();
        self.commit_ink();
        self.commit_shape_drag();
        self.erase_snapshot = false;
    }

    // -- paint -----------------------------------------------------------------

    /// Ensure textures for visible images, then paint everything.
    /// Split borrows keep per-frame clones at zero (image bytes stay put).
    /// Viewport culling: only visible + selected/active items paint; cheap
    /// bbox tests run before any expensive path/text work.
    fn paint(
        &mut self,
        ui: &mut egui::Ui,
        painter: &egui::Painter,
        rect: egui::Rect,
        hover: Option<egui::Pos2>,
    ) {
        painter.rect_filled(rect, 0.0, egui::Color32::from_rgb(0xfa, 0xfa, 0xf7));
        self.paint_dots(painter, rect);

        // Visible world rect for culling (with a margin for selection chrome).
        let top_left = self
            .viewport
            .world_point(rect.min.x as f64, rect.min.y as f64);
        let bottom_right = self
            .viewport
            .world_point(rect.max.x as f64, rect.max.y as f64);
        let visible = Rect::new(
            top_left.0.min(bottom_right.0) - 200.0,
            top_left.1.min(bottom_right.1) - 200.0,
            (bottom_right.0 - top_left.0).abs() + 400.0,
            (bottom_right.1 - top_left.1).abs() + 400.0,
        );
        let selected: HashSet<String> = self.doc.selection.iter().map(|id| id.0.clone()).collect();

        // Prune textures of deleted images; lazily decode new ones (only when
        // visible — never decode offscreen media on the UI thread path).
        let live: HashSet<String> = self
            .doc
            .items
            .iter()
            .filter(|i| matches!(i.content, ItemContent::Image { .. }))
            .map(|i| i.id.0.clone())
            .collect();
        self.textures.retain(|k, _| live.contains(k));
        let vp = self.viewport;
        let doc = &self.doc;
        let textures = &mut self.textures;
        for item in doc.items.iter() {
            if !visible.intersects(item.frame) && !selected.contains(&item.id.0) {
                continue;
            }
            if let ItemContent::Image { bytes, .. } = &item.content {
                if !textures.contains_key(&item.id.0) {
                    if let Some((raw, w, h)) = decode_rgba(bytes) {
                        let image = egui::ColorImage::from_rgba_unmultiplied([w, h], &raw);
                        let handle = ui.ctx().load_texture(
                            format!("img-{}", item.id.0),
                            image,
                            egui::TextureOptions::default(),
                        );
                        textures.insert(item.id.0.clone(), handle);
                    }
                }
            }
        }
        let _ = vp;

        for item in self.doc.items.iter() {
            // Cull offscreen items, but always keep selection + active gesture
            // targets available across the viewport edge.
            if !visible.intersects(item.frame) && !selected.contains(&item.id.0) {
                continue;
            }
            self.paint_item(painter, item);
        }

        // Selection outlines (full) + hover outline (50%, unselected only).
        let selected = self.doc.selection.clone();
        for id in &selected {
            if let Some(item) = self.doc.find(id) {
                stroke_rect(
                    painter,
                    frame_rect(&self.viewport, item.frame),
                    2.0,
                    accent(),
                );
            }
        }
        if let Some(p) = hover {
            if matches!(self.tool, Tool::Select) {
                let w = self.viewport.world_point(p.x as f64, p.y as f64);
                if let Some(id) = self.doc.hit_topmost(w.0, w.1) {
                    if !selected.contains(&id) {
                        if let Some(item) = self.doc.find(&id) {
                            stroke_rect(
                                painter,
                                frame_rect(&self.viewport, item.frame),
                                2.0,
                                accent_translucent(128),
                            );
                        }
                    }
                }
            }
        }

        // Marquee rubber band.
        if let Some(m) = &self.marquee {
            let r = egui::Rect::from_min_max(
                egui::Pos2::new(m.start.x.min(m.cur.x), m.start.y.min(m.cur.y)),
                egui::Pos2::new(m.start.x.max(m.cur.x), m.start.y.max(m.cur.y)),
            );
            painter.rect_filled(r, 0.0, accent_translucent(38));
            stroke_rect(painter, r, 1.0, accent());
        }

        // Shape-drag preview.
        if let (Some(a), Some(b)) = (self.shape_anchor, self.shape_current) {
            if matches!(self.tool, Tool::Shape(_)) {
                let sr = frame_rect(&self.viewport, normalize_rect(a, b));
                painter.rect_filled(sr, 0.0, accent_translucent(30));
                stroke_rect(painter, sr, 1.0, accent());
            }
        }

        // Live ink preview (thin polyline; the finished outline lands on release).
        if self.ink_raw.len() >= 2 {
            let pts: Vec<egui::Pos2> = self
                .ink_raw
                .iter()
                .map(|w| to_screen(&self.viewport, *w))
                .collect();
            let width = match self.ink_tool {
                InkTool::Pen => PEN_WIDTH,
                InkTool::Highlighter => HIGHLIGHTER_WIDTH,
            } as f32
                * self.viewport.scale as f32;
            let color = match self.ink_tool {
                InkTool::Pen => hex_color(PEN_HEX),
                InkTool::Highlighter => {
                    egui::Color32::from_rgba_unmultiplied(0xfd, 0xe0, 0x47, 115)
                }
            };
            painter.add(egui::Shape::line(pts, egui::Stroke::new(width, color)));
        }
    }

    fn paint_item(&self, painter: &egui::Painter, item: &CanvasItem) {
        match &item.content {
            ItemContent::Shape { .. } => self.paint_shape(painter, item),
            ItemContent::Sticky { color_hex, .. } => {
                let r = frame_rect(&self.viewport, item.frame);
                painter.rect_filled(r, egui::CornerRadius::same(6), hex_color(color_hex));
                stroke_rect(painter, r, 1.0, egui::Color32::from_black_alpha(40));
            }
            ItemContent::Text { .. } | ItemContent::RichText { .. } => {
                // Text itself is a widget (see show_text_labels); nothing to
                // paint here besides nothing at all.
            }
            ItemContent::Drawing { strokes } => {
                for ink in strokes {
                    self.paint_spine(painter, &ink.stroke.spine, Self::ink_display(ink));
                }
            }
            ItemContent::Image { .. } => {
                let screen = frame_rect(&self.viewport, item.frame);
                match self.textures.get(&item.id.0) {
                    Some(handle) => {
                        painter.image(
                            handle.id(),
                            screen,
                            egui::Rect::from_min_max(egui::Pos2::ZERO, egui::Pos2::new(1.0, 1.0)),
                            egui::Color32::WHITE,
                        );
                    }
                    None => {
                        painter.rect_filled(screen, 0.0, egui::Color32::from_gray(230));
                        stroke_rect(painter, screen, 1.0, egui::Color32::GRAY);
                    }
                }
            }
            ItemContent::Audio {
                title,
                duration_secs,
                ..
            } => {
                let screen = frame_rect(&self.viewport, item.frame);
                painter.rect_filled(
                    screen,
                    egui::CornerRadius::same(8),
                    egui::Color32::from_rgb(240, 240, 250),
                );
                stroke_rect(painter, screen, 1.0, egui::Color32::GRAY);
                painter.text(
                    screen.center(),
                    egui::Align2::CENTER_CENTER,
                    format!("♪ {title} ({duration_secs:.0}s)"),
                    egui::FontId::proportional(14.0),
                    egui::Color32::BLACK,
                );
            }
            ItemContent::Video { title, .. } => {
                let screen = frame_rect(&self.viewport, item.frame);
                painter.rect_filled(screen, 0.0, egui::Color32::BLACK);
                stroke_rect(painter, screen, 1.0, egui::Color32::GRAY);
                painter.text(
                    screen.center(),
                    egui::Align2::CENTER_CENTER,
                    format!("▶ {title}"),
                    egui::FontId::proportional(16.0),
                    egui::Color32::WHITE,
                );
            }
            ItemContent::Youtube { video_id, .. } => {
                let screen = frame_rect(&self.viewport, item.frame);
                painter.rect_filled(screen, 0.0, egui::Color32::from_rgb(200, 30, 30));
                painter.text(
                    screen.center(),
                    egui::Align2::CENTER_CENTER,
                    format!("▶ YouTube {video_id} (click Play)"),
                    egui::FontId::proportional(13.0),
                    egui::Color32::WHITE,
                );
            }
            ItemContent::Pdf {
                file_name, page, ..
            } => {
                let screen = frame_rect(&self.viewport, item.frame);
                painter.rect_filled(screen, 0.0, egui::Color32::WHITE);
                stroke_rect(painter, screen, 1.0, egui::Color32::GRAY);
                painter.text(
                    screen.center(),
                    egui::Align2::CENTER_CENTER,
                    format!("PDF {file_name} p{page}"),
                    egui::FontId::proportional(13.0),
                    egui::Color32::BLACK,
                );
            }
            ItemContent::Connector { .. } => {
                // Attached line: draw shaft across the frame diagonal.
                let screen = frame_rect(&self.viewport, item.frame);
                painter.line_segment(
                    [screen.min, screen.max],
                    egui::Stroke::new(2.0, egui::Color32::BLACK),
                );
            }
            ItemContent::Table { rows, cols, .. } => {
                let screen = frame_rect(&self.viewport, item.frame);
                painter.rect_filled(screen, 0.0, egui::Color32::WHITE);
                stroke_rect(painter, screen, 1.0, egui::Color32::GRAY);
                painter.text(
                    screen.center(),
                    egui::Align2::CENTER_CENTER,
                    format!("Table {rows}×{cols}"),
                    egui::FontId::proportional(13.0),
                    egui::Color32::DARK_GRAY,
                );
            }
        }
    }

    /// Text editor overlay for the item being edited. Widgets need `&mut Ui`,
    /// so this runs in `update()`, after `paint()`.
    fn show_editor(&mut self, ui: &mut egui::Ui) {
        let Some(edit_id) = self.editing.as_ref().map(|e| e.id.clone()) else {
            return;
        };
        let Some(item) = self.doc.find(&edit_id) else {
            self.editing = None;
            return;
        };
        let (font_size, color) = match &item.content {
            ItemContent::Sticky { font_size, .. } => (*font_size, egui::Color32::BLACK),
            ItemContent::Text {
                font_size,
                color_hex,
                ..
            } => (*font_size, hex_color(color_hex)),
            ItemContent::RichText { .. } => (18.0, egui::Color32::BLACK),
            ItemContent::Shape { font_size, .. } => (*font_size, egui::Color32::BLACK),
            ItemContent::Connector { .. } => (14.0, egui::Color32::BLACK),
            ItemContent::Table { .. } => (14.0, egui::Color32::BLACK),
            ItemContent::Audio { .. } | ItemContent::Video { .. } | ItemContent::Youtube { .. } => {
                (14.0, egui::Color32::BLACK)
            }
            ItemContent::Drawing { .. } | ItemContent::Image { .. } | ItemContent::Pdf { .. } => {
                return
            }
        };
        let frame = item.frame;
        let px = (font_size * self.viewport.scale) as f32;
        let pad = (10.0 * self.viewport.scale) as f32;
        let rect = frame_rect(&self.viewport, frame).shrink(pad);
        // Field-split borrows: buffer + dirty flag vs. the document.
        let editing = self.editing.as_mut().expect("editing");
        let response = ui.put(
            rect,
            egui::TextEdit::multiline(&mut editing.buffer)
                .font(egui::FontId::proportional(px))
                .text_color(color)
                .frame(egui::Frame::NONE),
        );
        if response.changed() {
            let editing = self.editing.as_mut().expect("editing");
            if !editing.dirty {
                editing.dirty = true;
                self.doc.push_undo();
            }
            let text = editing.buffer.clone();
            self.doc.set_text_live(&edit_id, &text);
        }
    }

    /// Read-only wrapped labels for sticky/text items (the editor covers the
    /// item being edited).
    fn show_text_labels(&mut self, ui: &mut egui::Ui) {
        let editing_id = self.editing.as_ref().map(|e| e.id.clone());
        let items: Vec<(ItemId, Rect, String, f64, egui::Color32)> = self
            .doc
            .items
            .iter()
            .filter_map(|item| match &item.content {
                ItemContent::Sticky {
                    text, font_size, ..
                } => Some((
                    item.id.clone(),
                    item.frame,
                    text.clone(),
                    *font_size,
                    egui::Color32::BLACK,
                )),
                ItemContent::Text {
                    text,
                    color_hex,
                    font_size,
                } => Some((
                    item.id.clone(),
                    item.frame,
                    text.clone(),
                    *font_size,
                    hex_color(color_hex),
                )),
                ItemContent::RichText { doc } => Some((
                    item.id.clone(),
                    item.frame,
                    doc.plain_text(),
                    18.0,
                    egui::Color32::BLACK,
                )),
                ItemContent::Shape {
                    label, font_size, ..
                } if !label.is_empty() => None,
                ItemContent::Connector { label, .. } if !label.is_empty() => Some((
                    item.id.clone(),
                    item.frame,
                    label.clone(),
                    14.0,
                    egui::Color32::BLACK,
                )),
                ItemContent::Audio { title, .. }
                | ItemContent::Video { title, .. }
                | ItemContent::Youtube { title, .. }
                    if !title.is_empty() =>
                {
                    None
                }
                _ => None,
            })
            .collect();
        for (id, frame, text, font_size, color) in items {
            if text.is_empty() || editing_id.as_ref() == Some(&id) {
                continue;
            }
            let px = (font_size * self.viewport.scale) as f32;
            let pad = (10.0 * self.viewport.scale) as f32;
            let rect = frame_rect(&self.viewport, frame).shrink(pad);
            ui.put(
                rect,
                egui::Label::new(egui::RichText::new(text).size(px).color(color)).wrap(),
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_parses_rrggbb() {
        assert_eq!(hex_color("FF0000"), egui::Color32::from_rgb(255, 0, 0));
        assert_eq!(hex_color("#00FF00"), egui::Color32::from_rgb(0, 255, 0));
    }

    #[test]
    fn marquee_rect_normalizes() {
        let r = normalize_rect((5.0, 5.0), (1.0, 1.0));
        assert_eq!(r, Rect::new(1.0, 1.0, 4.0, 4.0));
    }

    #[test]
    fn eraser_probe_detects_strokes() {
        let mut doc = CanvasDoc::new();
        let mut builder = StrokeBuilder::new(pen_config(), InkTool::Pen);
        builder.push(InkPoint::new(0.0, 0.0));
        builder.push(InkPoint::new(40.0, 0.0));
        let stroke = builder.finish().expect("stroke");
        let mut item = CanvasItem::drawing(Rect::new(-4.0, -4.0, 48.0, 8.0), 0.0);
        if let ItemContent::Drawing { strokes } = &mut item.content {
            strokes.push(PaintedInk {
                stroke,
                style_raw: "pen".to_string(),
                color_hex: PEN_HEX.to_string(),
                line_width: PEN_WIDTH,
            });
        }
        doc.add(item);
        assert!(would_erase(&doc, 20.0, 0.0, 2.0));
        assert!(!would_erase(&doc, 20.0, 50.0, 2.0));
    }
}
