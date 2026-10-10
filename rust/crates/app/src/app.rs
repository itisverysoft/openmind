//! Interactive canvas: toolbar, infinite dot grid, ink strokes, pan/zoom.
//!
//! Input model (mouse-first; tablet pressure flows through `InkPoint` when
//! the backend reports it):
//!
//! * Pen / Highlighter: press-drag-release paints a stroke (`StrokeBuilder`).
//! * Eraser: drag removes every stroke it touches.
//! * Hand (or middle-drag any time): drag pans; wheel zooms around the
//!   cursor, trackpad scroll pans — all through `Viewport::applying`, the
//!   same math as the Swift app.

use eframe::egui;
use openmind_board::Viewport;
use openmind_ink::{InkConfig, InkPoint, InkTool, Stroke, StrokeBuilder};

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
enum Tool {
    #[default]
    Pen,
    Highlighter,
    Eraser,
    Hand,
}

impl Tool {
    fn label(self) -> &'static str {
        match self {
            Self::Pen => "Pen",
            Self::Highlighter => "Highlighter",
            Self::Eraser => "Eraser",
            Self::Hand => "Hand",
        }
    }
}

struct PaintedStroke {
    stroke: Stroke,
    color: egui::Color32,
}

pub struct OpenMindApp {
    tool: Tool,
    viewport: Viewport,
    strokes: Vec<PaintedStroke>,
    /// In-progress drag: geometry builder + raw world points for the preview.
    active_builder: Option<StrokeBuilder>,
    active_raw: Vec<(f64, f64)>,
    active_tool: InkTool,
    active_color: egui::Color32,
    panning: bool,
    last_pointer: Option<egui::Pos2>,
}

impl Default for OpenMindApp {
    fn default() -> Self {
        Self {
            tool: Tool::Pen,
            viewport: Viewport::centered_on(5000.0, 5000.0, 600.0, 350.0),
            strokes: Vec::new(),
            active_builder: None,
            active_raw: Vec::new(),
            active_tool: InkTool::Pen,
            active_color: pen_color(),
            panning: false,
            last_pointer: None,
        }
    }
}

fn pen_color() -> egui::Color32 {
    egui::Color32::from_rgb(0x1a, 0x1a, 0x1a)
}

fn highlighter_color() -> egui::Color32 {
    // Marker yellow at the Swift app's 0.45 opacity.
    egui::Color32::from_rgba_unmultiplied(0xfd, 0xe0, 0x47, 115)
}

fn pen_config() -> InkConfig {
    InkConfig {
        max_width: 4.0,
        ..InkConfig::default()
    }
}

fn highlighter_config() -> InkConfig {
    InkConfig {
        max_width: 12.0,
        ..InkConfig::default()
    }
}

/// Remove strokes touching world point `(x, y)`; returns how many went away.
fn erase_at(strokes: &mut Vec<PaintedStroke>, x: f64, y: f64, extra: f64) -> usize {
    let before = strokes.len();
    strokes.retain(|s| !s.stroke.hit_test(x, y, extra));
    before - strokes.len()
}

impl OpenMindApp {
    fn tool_config(tool: Tool) -> (InkConfig, InkTool, egui::Color32) {
        match tool {
            Tool::Pen => (pen_config(), InkTool::Pen, pen_color()),
            Tool::Highlighter => (
                highlighter_config(),
                InkTool::Highlighter,
                highlighter_color(),
            ),
            Tool::Eraser | Tool::Hand => (pen_config(), InkTool::Pen, pen_color()),
        }
    }

    fn begin_stroke(&mut self, world: (f64, f64)) {
        let (cfg, ink_tool, color) = Self::tool_config(self.tool);
        let mut builder = StrokeBuilder::new(cfg, ink_tool);
        builder.push(InkPoint::new(world.0, world.1));
        self.active_builder = Some(builder);
        self.active_raw = vec![world];
        self.active_tool = ink_tool;
        self.active_color = color;
    }

    fn push_to_stroke(&mut self, world: (f64, f64)) {
        if let Some(builder) = self.active_builder.as_mut() {
            builder.push(InkPoint::new(world.0, world.1));
            self.active_raw.push(world);
        }
    }

    fn end_stroke(&mut self) {
        if let Some(builder) = self.active_builder.take() {
            if let Some(stroke) = builder.finish() {
                self.strokes.push(PaintedStroke {
                    stroke,
                    color: self.active_color,
                });
            }
        }
        self.active_raw.clear();
    }

    fn to_screen(&self, world: (f64, f64)) -> egui::Pos2 {
        let (sx, sy) = self.viewport.screen_point(world.0, world.1);
        egui::Pos2::new(sx as f32, sy as f32)
    }

    fn paint_stroke(
        painter: &egui::Painter,
        to_screen: impl Fn((f64, f64)) -> egui::Pos2,
        spine: &[openmind_ink::SpinePoint],
        color: egui::Color32,
        scale: f32,
    ) {
        if spine.is_empty() {
            return;
        }
        if spine.len() == 1 {
            let s = spine[0];
            let r = ((s.width as f32 * scale) / 2.0).max(1.0);
            painter.circle_filled(to_screen((s.x, s.y)), r, color);
            return;
        }
        for w in spine.windows(2) {
            let (a, b) = (w[0], w[1]);
            let width = (((a.width + b.width) / 2.0) as f32 * scale).max(0.75);
            painter.line_segment(
                [to_screen((a.x, a.y)), to_screen((b.x, b.y))],
                egui::Stroke::new(width, color),
            );
        }
        // Round joints/caps: a disc per sample (spine is dense by design).
        for s in spine {
            let r = ((s.width as f32 * scale) / 2.0).max(0.75);
            painter.circle_filled(to_screen((s.x, s.y)), r, color);
        }
    }

    fn paint_dots(&self, painter: &egui::Painter, rect: egui::Rect) {
        // Same look as the Swift dot grid: 40pt world spacing, fading out
        // when zoomed far, subdividing when zoomed close.
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
}

impl eframe::App for OpenMindApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.update(ui);
    }
}

impl OpenMindApp {
    fn update(&mut self, ui: &mut egui::Ui) {
        egui::Panel::top("toolbar").show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.selectable_value(&mut self.tool, Tool::Pen, Tool::Pen.label());
                ui.selectable_value(&mut self.tool, Tool::Highlighter, Tool::Highlighter.label());
                ui.selectable_value(&mut self.tool, Tool::Eraser, Tool::Eraser.label());
                ui.selectable_value(&mut self.tool, Tool::Hand, Tool::Hand.label());
                ui.separator();
                if ui.button("Clear").clicked() {
                    self.strokes.clear();
                    self.active_builder = None;
                    self.active_raw.clear();
                }
                ui.separator();
                if ui.button("−").clicked() {
                    let c = ui.max_rect().center();
                    self.viewport = self
                        .viewport
                        .applying(0.0, 0.0, 0.8, c.x as f64, c.y as f64);
                }
                ui.label(format!("{:.0}%", self.viewport.scale * 100.0));
                if ui.button("+").clicked() {
                    let c = ui.max_rect().center();
                    self.viewport = self
                        .viewport
                        .applying(0.0, 0.0, 1.25, c.x as f64, c.y as f64);
                }
            });
        });

        egui::Panel::bottom("status").show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.label(format!("{} strokes", self.strokes.len()));
                ui.separator();
                ui.label(match self.tool {
                    Tool::Pen | Tool::Highlighter => "drag to draw",
                    Tool::Eraser => "drag to erase",
                    Tool::Hand => "drag to pan",
                });
                ui.separator();
                ui.label("wheel: zoom · trackpad scroll: pan · middle-drag: pan");
            });
        });

        egui::CentralPanel::default().show(ui, |ui| {
            let (rect, _) =
                ui.allocate_exact_size(ui.available_size(), egui::Sense::click_and_drag());
            let painter = ui.painter().with_clip_rect(rect);
            painter.rect_filled(rect, 0.0, egui::Color32::from_rgb(0xfa, 0xfa, 0xf7));

            // Snapshot input once per frame.
            struct Input {
                pos: Option<egui::Pos2>,
                primary_down: bool,
                primary_pressed: bool,
                primary_released: bool,
                middle_down: bool,
                zoom_delta: f32,
                scroll_delta: egui::Vec2,
            }
            let input = ui.ctx().input(|i| Input {
                pos: i.pointer.latest_pos(),
                primary_down: i.pointer.primary_down(),
                primary_pressed: i.pointer.primary_pressed(),
                primary_released: i.pointer.primary_released(),
                middle_down: i.pointer.middle_down(),
                zoom_delta: i.zoom_delta(),
                scroll_delta: i.smooth_scroll_delta(),
            });
            let on_canvas = input.pos.is_some_and(|p| rect.contains(p));

            // Pinch/scroll zoom around the cursor.
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
            // Trackpad scroll pans (not while drawing).
            if on_canvas
                && !input.primary_down
                && (input.scroll_delta.x != 0.0 || input.scroll_delta.y != 0.0)
            {
                self.viewport = self.viewport.applying(
                    input.scroll_delta.x as f64,
                    input.scroll_delta.y as f64,
                    1.0,
                    0.0,
                    0.0,
                );
            }

            // Middle-drag pans under any tool.
            if input.middle_down {
                if let (Some(p), Some(last)) = (input.pos, self.last_pointer) {
                    if on_canvas {
                        let d = p - last;
                        self.viewport = self
                            .viewport
                            .applying(d.x as f64, d.y as f64, 1.0, 0.0, 0.0);
                    }
                }
            } else if on_canvas && input.primary_pressed {
                if let Some(p) = input.pos {
                    let world = self.viewport.world_point(p.x as f64, p.y as f64);
                    match self.tool {
                        Tool::Pen | Tool::Highlighter => self.begin_stroke(world),
                        Tool::Eraser => {
                            let extra = 8.0 / self.viewport.scale;
                            erase_at(&mut self.strokes, world.0, world.1, extra);
                        }
                        Tool::Hand => self.panning = true,
                    }
                }
            } else if input.primary_down {
                if let Some(p) = input.pos {
                    if on_canvas {
                        let world = self.viewport.world_point(p.x as f64, p.y as f64);
                        match self.tool {
                            Tool::Pen | Tool::Highlighter => self.push_to_stroke(world),
                            Tool::Eraser => {
                                let extra = 8.0 / self.viewport.scale;
                                erase_at(&mut self.strokes, world.0, world.1, extra);
                            }
                            Tool::Hand => {
                                if self.panning {
                                    if let Some(last) = self.last_pointer {
                                        let d = p - last;
                                        self.viewport = self
                                            .viewport
                                            .applying(d.x as f64, d.y as f64, 1.0, 0.0, 0.0);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if input.primary_released {
                self.end_stroke();
                self.panning = false;
            }
            if !input.primary_down && !input.middle_down {
                self.panning = false;
            }
            self.last_pointer = input.pos;

            // Paint.
            self.paint_dots(&painter, rect);
            let scale = self.viewport.scale as f32;
            for s in &self.strokes {
                Self::paint_stroke(
                    &painter,
                    |w| self.to_screen(w),
                    &s.stroke.spine,
                    s.color,
                    scale,
                );
            }
            if !self.active_raw.is_empty() {
                // Live preview: thin polyline; the finished outline
                // replaces it on release.
                let pts: Vec<egui::Pos2> =
                    self.active_raw.iter().map(|w| self.to_screen(*w)).collect();
                painter.add(egui::Shape::line(
                    pts,
                    egui::Stroke::new(
                        (if self.active_tool == InkTool::Highlighter {
                            12.0
                        } else {
                            4.0
                        }) * scale,
                        self.active_color,
                    ),
                ));
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn painted(n: usize) -> Vec<PaintedStroke> {
        (0..n)
            .map(|i| {
                let mut b = StrokeBuilder::new(pen_config(), InkTool::Pen);
                let x = i as f64 * 50.0;
                b.push(InkPoint::new(x, 0.0));
                b.push(InkPoint::new(x + 20.0, 0.0));
                PaintedStroke {
                    stroke: b.finish().expect("stroke"),
                    color: pen_color(),
                }
            })
            .collect()
    }

    #[test]
    fn eraser_removes_only_touched_strokes() {
        let mut strokes = painted(3);
        // Strokes span x=0..20, 50..70, 100..120.
        let gone = erase_at(&mut strokes, 60.0, 0.0, 2.0);
        assert_eq!(gone, 1);
        assert_eq!(strokes.len(), 2);
        let gone = erase_at(&mut strokes, 500.0, 500.0, 2.0);
        assert_eq!(gone, 0);
        assert_eq!(strokes.len(), 2);
    }

    #[test]
    fn app_starts_empty_with_pen() {
        let app = OpenMindApp::default();
        assert_eq!(app.tool, Tool::Pen);
        assert!(app.strokes.is_empty());
        assert_eq!(app.viewport.scale, 1.0);
    }
}
