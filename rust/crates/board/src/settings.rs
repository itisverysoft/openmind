//! Canvas sheet settings and the pan/zoom viewport.
//!
//! Mirrors `CanvasSettings.swift` (`CanvasSizePreset`, `CanvasOrientation`,
//! `CanvasPattern`) and `Viewport.swift` exactly, including the zoom-around
//! math and the 0.2…8 scale clamp.

/// World is a 10_000pt square; sheets center on its middle.
pub struct CanvasMetrics;

impl CanvasMetrics {
    pub const WORLD_SIZE: f64 = 10_000.0;
    pub fn center() -> (f64, f64) {
        (Self::WORLD_SIZE / 2.0, Self::WORLD_SIZE / 2.0)
    }
}

/// Fixed sheet sizes in world points (`CanvasSizePreset` raw values verbatim).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CanvasSizePreset {
    Infinite,
    A4,
    Letter,
    A3,
    Legal,
    A5,
    Custom,
}

impl CanvasSizePreset {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Infinite => "infinite",
            Self::A4 => "A4",
            Self::Letter => "letter",
            Self::A3 => "A3",
            Self::Legal => "legal",
            Self::A5 => "A5",
            Self::Custom => "custom",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "infinite" => Self::Infinite,
            "A4" => Self::A4,
            "letter" => Self::Letter,
            "A3" => Self::A3,
            "legal" => Self::Legal,
            "A5" => Self::A5,
            "custom" => Self::Custom,
            _ => return None,
        })
    }

    /// Portrait-base sheet size; `None` for infinite/custom.
    pub fn sheet_size(self) -> Option<(f64, f64)> {
        match self {
            Self::Infinite | Self::Custom => None,
            Self::A4 => Some((595.0, 842.0)),
            Self::Letter => Some((612.0, 792.0)),
            Self::A3 => Some((842.0, 1191.0)),
            Self::Legal => Some((612.0, 1008.0)),
            Self::A5 => Some((420.0, 595.0)),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CanvasOrientation {
    Portrait,
    Landscape,
}

impl CanvasOrientation {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Portrait => "portrait",
            Self::Landscape => "landscape",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "portrait" => Self::Portrait,
            "landscape" => Self::Landscape,
            _ => return None,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CanvasPattern {
    Plain,
    Dots,
    Grid,
    Lines,
    Columns,
    Graph,
}

impl CanvasPattern {
    pub fn as_str(self) -> &'static str {
        // Raw values verbatim from GridBackground.swift / CanvasSettings.swift.
        match self {
            Self::Plain => "plain",
            Self::Dots => "dots",
            Self::Grid => "grid",
            Self::Lines => "lines",
            Self::Columns => "columns",
            Self::Graph => "graph",
        }
    }
}

/// Pan/zoom viewport: `screen = world * scale + offset`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Viewport {
    pub offset_x: f64,
    pub offset_y: f64,
    pub scale: f64,
}

impl Viewport {
    pub const MIN_SCALE: f64 = 0.2;
    pub const MAX_SCALE: f64 = 8.0;

    pub fn new(offset_x: f64, offset_y: f64, scale: f64) -> Self {
        Self {
            offset_x,
            offset_y,
            scale,
        }
    }

    /// Pan by `pan` (screen points) and zoom by `zoom` around screen point
    /// `around`, clamping the scale — verbatim port of `applying(pan:zoom:around:)`.
    pub fn applying(self, pan_x: f64, pan_y: f64, zoom: f64, around_x: f64, around_y: f64) -> Self {
        let new_scale = (self.scale * zoom).clamp(Self::MIN_SCALE, Self::MAX_SCALE);
        let ratio = new_scale / self.scale;
        Self {
            offset_x: around_x - (around_x - self.offset_x) * ratio + pan_x,
            offset_y: around_y - (around_y - self.offset_y) * ratio + pan_y,
            scale: new_scale,
        }
    }

    pub fn world_point(self, screen_x: f64, screen_y: f64) -> (f64, f64) {
        (
            (screen_x - self.offset_x) / self.scale,
            (screen_y - self.offset_y) / self.scale,
        )
    }

    pub fn screen_point(self, world_x: f64, world_y: f64) -> (f64, f64) {
        (
            world_x * self.scale + self.offset_x,
            world_y * self.scale + self.offset_y,
        )
    }

    /// A viewport at 100% showing `world` in the middle of a `size` view.
    pub fn centered_on(world_x: f64, world_y: f64, size_w: f64, size_h: f64) -> Self {
        Self {
            offset_x: size_w / 2.0 - world_x,
            offset_y: size_h / 2.0 - world_y,
            scale: 1.0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zoom_around_keeps_anchor_still() {
        let vp = Viewport::centered_on(5000.0, 5000.0, 800.0, 600.0);
        let anchor = (400.0, 300.0);
        let before = vp.world_point(anchor.0, anchor.1);
        let after = vp.applying(0.0, 0.0, 2.0, anchor.0, anchor.1);
        let kept = after.world_point(anchor.0, anchor.1);
        assert!((before.0 - kept.0).abs() < 1e-9);
        assert!((before.1 - kept.1).abs() < 1e-9);
        assert_eq!(after.scale, 2.0);
    }

    #[test]
    fn scale_clamps_like_swift() {
        let vp = Viewport::new(0.0, 0.0, 1.0);
        assert_eq!(
            vp.applying(0.0, 0.0, 100.0, 0.0, 0.0).scale,
            Viewport::MAX_SCALE
        );
        assert_eq!(
            vp.applying(0.0, 0.0, 0.001, 0.0, 0.0).scale,
            Viewport::MIN_SCALE
        );
    }

    #[test]
    fn sheet_sizes_match_swift() {
        assert_eq!(CanvasSizePreset::A4.sheet_size(), Some((595.0, 842.0)));
        assert_eq!(CanvasSizePreset::Letter.sheet_size(), Some((612.0, 792.0)));
        assert_eq!(CanvasSizePreset::Infinite.sheet_size(), None);
    }
}
