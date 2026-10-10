//! Stroke pipeline: smooth → resample → frame → outline.
//!
//! Coordinates are canvas world points; `y` grows downwards like the vector
//! stack and the Swift app.

use vectorcraft_brush::track::tracks;
use vectorcraft_geom::{BezPath, Point, Rect, Shape, Vec2};

/// One raw pointer/tablet sample.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct InkPoint {
    pub x: f64,
    pub y: f64,
    /// 0..=1. `None` at the call site (mouse) means full pressure.
    pub pressure: f64,
    /// Milliseconds since an arbitrary origin; kept for future velocity
    /// work, unused by the M1 geometry.
    pub time_ms: f64,
}

impl InkPoint {
    pub fn new(x: f64, y: f64) -> Self {
        Self {
            x,
            y,
            pressure: 1.0,
            time_ms: 0.0,
        }
    }

    pub fn with_pressure(x: f64, y: f64, pressure: Option<f64>, time_ms: f64) -> Self {
        Self {
            x,
            y,
            pressure: pressure.unwrap_or(1.0),
            time_ms,
        }
    }

    fn clamped_pressure(self) -> f64 {
        self.pressure.clamp(0.0, 1.0)
    }
}

/// Tool semantics for width/opacity (mirrors Swift `DrawingStyle`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InkTool {
    Pen,
    Highlighter,
}

impl InkTool {
    /// Fill opacity used when the stroke is painted.
    pub fn base_opacity(self) -> f64 {
        match self {
            Self::Pen => 1.0,
            Self::Highlighter => 0.45,
        }
    }

    fn uses_pressure(self) -> bool {
        match self {
            Self::Pen => true,
            // Marker nibs hold full width regardless of pressure.
            Self::Highlighter => false,
        }
    }
}

/// Tuning for the pipeline. All lengths are world points.
#[derive(Clone, Copy, Debug)]
pub struct InkConfig {
    /// Full width at pressure 1 (pen) or constant width (highlighter).
    pub max_width: f64,
    /// Fraction of `max_width` kept at pressure 0 (pen taper floor).
    pub min_width_frac: f64,
    /// Resample spacing as a fraction of `max_width`.
    pub spacing_frac: f64,
    pub min_spacing: f64,
    pub max_spacing: f64,
    /// Chaikin smoothing passes (0 disables).
    pub smooth_passes: u8,
}

impl Default for InkConfig {
    fn default() -> Self {
        Self {
            max_width: 4.0,
            min_width_frac: 0.35,
            spacing_frac: 0.25,
            min_spacing: 0.75,
            max_spacing: 6.0,
            smooth_passes: 1,
        }
    }
}

/// Evenly spaced spine sample with its full width.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpinePoint {
    pub x: f64,
    pub y: f64,
    pub width: f64,
}

/// A finished stroke: resampled spine + filled outline + bounds.
#[derive(Clone, Debug)]
pub struct Stroke {
    pub tool: InkTool,
    pub spine: Vec<SpinePoint>,
    pub outline: BezPath,
    pub bounds: Rect,
}

impl Stroke {
    /// Total spine length in world points (0 for tap dots).
    pub fn len(&self) -> f64 {
        let mut total = 0.0;
        for w in self.spine.windows(2) {
            total += dist(w[0].x, w[0].y, w[1].x, w[1].y);
        }
        total
    }

    pub fn is_dot(&self) -> bool {
        self.spine.len() <= 1
    }

    /// Eraser/selection hit test: true when `(x, y)` lands within the ink
    /// plus `extra` world points of tolerance.
    pub fn hit_test(&self, x: f64, y: f64, extra: f64) -> bool {
        if self.spine.is_empty() {
            return false;
        }
        if self.spine.len() == 1 {
            let s = self.spine[0];
            return dist(x, y, s.x, s.y) <= s.width / 2.0 + extra;
        }
        for w in self.spine.windows(2) {
            let (a, b) = (w[0], w[1]);
            let half = (a.width + b.width) / 4.0 + extra;
            if seg_dist(x, y, a.x, a.y, b.x, b.y) <= half {
                return true;
            }
        }
        false
    }
}

/// Incremental stroke builder: push pointer samples, `finish` the stroke.
pub struct StrokeBuilder {
    config: InkConfig,
    tool: InkTool,
    raw: Vec<InkPoint>,
}

impl StrokeBuilder {
    pub fn new(config: InkConfig, tool: InkTool) -> Self {
        Self {
            config,
            tool,
            raw: Vec::new(),
        }
    }

    pub fn push(&mut self, point: InkPoint) {
        self.raw.push(point);
    }

    pub fn is_empty(&self) -> bool {
        self.raw.is_empty()
    }

    /// Smooth → resample → frame → outline. `None` only when no samples
    /// were pushed; a single tap yields a dot stroke.
    pub fn finish(self) -> Option<Stroke> {
        if self.raw.is_empty() {
            return None;
        }
        let cfg = self.config;
        // 1. Dedupe (keep first; drop sensor repeats).
        let mut pts: Vec<InkPoint> = Vec::with_capacity(self.raw.len());
        for p in &self.raw {
            let keep = match pts.last() {
                None => true,
                Some(q) => dist(p.x, p.y, q.x, q.y) > 1e-9,
            };
            if keep {
                pts.push(*p);
            }
        }
        // 2. Light pressure smoothing (window 3) so nib width never pops.
        let pressures = smooth_pressures(&pts);
        // 3. Chaikin on positions (endpoints preserved).
        let mut xy: Vec<Point> = pts.iter().map(|p| Point::new(p.x, p.y)).collect();
        for _ in 0..cfg.smooth_passes {
            xy = chaikin(&xy);
        }
        // Re-zip smoothed positions with smoothed pressures by index. Chaikin
        // inserts midpoints, so resample pressures by arc position instead:
        // build (cumlen, pressure) over the smoothed polyline first.
        let (cum, total) = arc_table(&xy);
        let width_at = |s: f64| -> f64 {
            let p = pressure_at(&pressures, total, s);
            if self.tool.uses_pressure() {
                cfg.max_width * (cfg.min_width_frac + (1.0 - cfg.min_width_frac) * p)
            } else {
                cfg.max_width
            }
        };

        if xy.len() == 1 || total < 1e-9 {
            let w = width_at(0.0);
            let c = xy[0];
            let outline = circle_path(c, (w / 2.0).max(0.5));
            let bounds = outline.bounding_box();
            return Some(Stroke {
                tool: self.tool,
                spine: vec![SpinePoint {
                    x: c.x,
                    y: c.y,
                    width: w,
                }],
                outline,
                bounds,
            });
        }

        // 4. Arc-length resample.
        let spacing = (cfg.max_width * cfg.spacing_frac)
            .clamp(cfg.min_spacing, cfg.max_spacing)
            .max(1e-6);
        let n = (total / spacing).ceil() as usize + 1;
        let n = n.max(2);
        let mut spine = Vec::with_capacity(n);
        for i in 0..n {
            let s = total * i as f64 / (n - 1) as f64;
            let (x, y) = point_at(&xy, &cum, total, s);
            spine.push(SpinePoint {
                x,
                y,
                width: width_at(s).max(0.5),
            });
        }

        // 5. Frames from brush tracks (corner-aware tangents); fall back to
        // central differences if the track ever comes back empty.
        let mut center = BezPath::new();
        center.move_to(Point::new(spine[0].x, spine[0].y));
        for s in spine.iter().skip(1) {
            center.line_to(Point::new(s.x, s.y));
        }
        let tangents: Vec<Vec2> = match tracks(&center, spacing / 2.0).into_iter().next() {
            Some(t) if t.len() > 1e-9 => {
                let len = t.len();
                (0..n)
                    .map(|i| {
                        let s = len * i as f64 / (n - 1) as f64;
                        t.frame(s.clamp(0.0, len)).1
                    })
                    .collect()
            }
            _ => central_tangents(&spine),
        };

        let outline = build_outline(&spine, &tangents);
        let bounds = outline.bounding_box();
        Some(Stroke {
            tool: self.tool,
            spine,
            outline,
            bounds,
        })
    }
}

// ---------------------------------------------------------------------------
// Pipeline pieces
// ---------------------------------------------------------------------------

fn dist(ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    (bx - ax).hypot(by - ay)
}

/// Shortest distance from `p` to segment `a`–`b` (mirrors the Swift helper).
fn seg_dist(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let dx = bx - ax;
    let dy = by - ay;
    let len2 = dx * dx + dy * dy;
    if len2 <= 0.0 {
        return dist(px, py, ax, ay);
    }
    let t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
    dist(px, py, ax + t * dx, ay + t * dy)
}

/// One Chaikin pass, endpoints preserved.
fn chaikin(pts: &[Point]) -> Vec<Point> {
    if pts.len() < 3 {
        return pts.to_vec();
    }
    let mut out = Vec::with_capacity(pts.len() * 2);
    out.push(pts[0]);
    for w in pts.windows(2) {
        let (a, b) = (w[0], w[1]);
        out.push(Point::new(
            a.x + (b.x - a.x) * 0.25,
            a.y + (b.y - a.y) * 0.25,
        ));
        out.push(Point::new(
            a.x + (b.x - a.x) * 0.75,
            a.y + (b.y - a.y) * 0.75,
        ));
    }
    out.push(*pts.last().expect("non-empty"));
    out
}

fn smooth_pressures(pts: &[InkPoint]) -> Vec<f64> {
    let n = pts.len();
    (0..n)
        .map(|i| {
            // Endpoints keep their raw pressure: averaging them would taper
            // every stroke's start/end regardless of the hand.
            if i == 0 || i + 1 == n {
                return pts[i].clamped_pressure();
            }
            let mut sum = 0.0;
            for p in &pts[i - 1..=i + 1] {
                sum += p.clamped_pressure();
            }
            sum / 3.0
        })
        .collect()
}

/// Cumulative arc lengths + total for a polyline.
fn arc_table(xy: &[Point]) -> (Vec<f64>, f64) {
    let mut cum = Vec::with_capacity(xy.len());
    cum.push(0.0);
    for w in xy.windows(2) {
        let d = w[0].distance(w[1]);
        let last = cum.last().copied().unwrap_or(0.0);
        cum.push(last + d);
    }
    let total = cum.last().copied().unwrap_or(0.0);
    (cum, total)
}

fn locate(cum: &[f64], total: f64, s: f64) -> (usize, f64) {
    if total <= 0.0 || cum.len() < 2 {
        return (0, 0.0);
    }
    let s = s.clamp(0.0, total);
    let mut lo = 0usize;
    while lo + 1 < cum.len() - 1 && cum[lo + 1] < s {
        lo += 1;
    }
    let seg = (cum[lo + 1] - cum[lo]).max(1e-12);
    (lo, ((s - cum[lo]) / seg).clamp(0.0, 1.0))
}

fn point_at(xy: &[Point], cum: &[f64], total: f64, s: f64) -> (f64, f64) {
    if xy.len() == 1 {
        return (xy[0].x, xy[0].y);
    }
    let (i, t) = locate(cum, total, s);
    let a = xy[i];
    let b = xy[i + 1];
    (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
}

/// Pressure at arc position `s`, lerped over the smoothed profile by
/// fractional position (Chaikin inserts midpoints, so the table and the
/// profile are indexed by fraction, not 1:1).
fn pressure_at(press: &[f64], total: f64, s: f64) -> f64 {
    if press.is_empty() {
        return 1.0;
    }
    if press.len() == 1 || total <= 0.0 {
        return press[0];
    }
    // Map s onto the pressure samples by fractional position along the table.
    let frac = (s / total).clamp(0.0, 1.0) * (press.len() - 1) as f64;
    let i = (frac.floor() as usize).min(press.len() - 2);
    let t = frac - i as f64;
    press[i] + (press[i + 1] - press[i]) * t
}

fn central_tangents(spine: &[SpinePoint]) -> Vec<Vec2> {
    let n = spine.len();
    (0..n)
        .map(|i| {
            let a = spine[i.saturating_sub(1)];
            let b = spine[(i + 1).min(n - 1)];
            let v = Vec2::new(b.x - a.x, b.y - a.y);
            let l = v.hypot();
            if l < 1e-12 {
                Vec2::new(1.0, 0.0)
            } else {
                v / l
            }
        })
        .collect()
}

/// Closed circle from four cubic segments (kappa construction) — the tap-dot
/// outline, without needing a circle primitive.
fn circle_path(c: Point, r: f64) -> BezPath {
    const K: f64 = 0.552_284_749_830_793_6;
    let (x, y) = (c.x, c.y);
    let mut p = BezPath::new();
    p.move_to(Point::new(x + r, y));
    p.curve_to(
        Point::new(x + r, y + K * r),
        Point::new(x + K * r, y + r),
        Point::new(x, y + r),
    );
    p.curve_to(
        Point::new(x - K * r, y + r),
        Point::new(x - r, y + K * r),
        Point::new(x - r, y),
    );
    p.curve_to(
        Point::new(x - r, y - K * r),
        Point::new(x - K * r, y - r),
        Point::new(x, y - r),
    );
    p.curve_to(
        Point::new(x + K * r, y - r),
        Point::new(x + r, y - K * r),
        Point::new(x + r, y),
    );
    p.close_path();
    p
}

/// Offset rails + round caps as one closed path (non-zero fill).
fn build_outline(spine: &[SpinePoint], tangents: &[Vec2]) -> BezPath {
    debug_assert_eq!(spine.len(), tangents.len());
    let n = spine.len();
    let mut left = Vec::with_capacity(n);
    let mut right = Vec::with_capacity(n);
    for (s, t) in spine.iter().zip(tangents.iter()) {
        // Left-hand normal in y-down space.
        let nx = -t.y;
        let ny = t.x;
        let h = s.width / 2.0;
        left.push(Point::new(s.x + nx * h, s.y + ny * h));
        right.push(Point::new(s.x - nx * h, s.y - ny * h));
    }
    let mut path = BezPath::new();
    path.move_to(left[0]);
    for p in left.iter().skip(1) {
        path.line_to(*p);
    }
    // End cap: two quadratics bulging past the tip.
    let tip_t = tangents[n - 1];
    let tip_h = spine[n - 1].width / 2.0;
    let tip = Point::new(spine[n - 1].x, spine[n - 1].y);
    let cap_end = Point::new(tip.x + tip_t.x * tip_h, tip.y + tip_t.y * tip_h);
    path.quad_to(
        Point::new(
            left[n - 1].x + tip_t.x * tip_h,
            left[n - 1].y + tip_t.y * tip_h,
        ),
        cap_end,
    );
    path.quad_to(
        Point::new(
            right[n - 1].x + tip_t.x * tip_h,
            right[n - 1].y + tip_t.y * tip_h,
        ),
        right[n - 1],
    );
    for p in right[..n - 1].iter().rev() {
        path.line_to(*p);
    }
    // Start cap mirrored.
    let tail_t = tangents[0];
    let tail_h = spine[0].width / 2.0;
    let tail = Point::new(spine[0].x, spine[0].y);
    let cap_start = Point::new(tail.x - tail_t.x * tail_h, tail.y - tail_t.y * tail_h);
    path.quad_to(
        Point::new(
            right[0].x - tail_t.x * tail_h,
            right[0].y - tail_t.y * tail_h,
        ),
        cap_start,
    );
    path.quad_to(
        Point::new(left[0].x - tail_t.x * tail_h, left[0].y - tail_t.y * tail_h),
        left[0],
    );
    path.close_path();
    path
}

#[cfg(test)]
mod tests {
    use super::*;

    fn drag(points: &[(f64, f64)]) -> Stroke {
        let mut b = StrokeBuilder::new(InkConfig::default(), InkTool::Pen);
        for (i, (x, y)) in points.iter().enumerate() {
            b.push(InkPoint::with_pressure(*x, *y, Some(1.0), i as f64 * 8.0));
        }
        b.finish().expect("stroke")
    }

    #[test]
    fn empty_builder_yields_none() {
        assert!(StrokeBuilder::new(InkConfig::default(), InkTool::Pen)
            .finish()
            .is_none());
    }

    #[test]
    fn tap_yields_dot_with_area() {
        let mut b = StrokeBuilder::new(InkConfig::default(), InkTool::Pen);
        b.push(InkPoint::new(50.0, 50.0));
        let s = b.finish().expect("dot");
        assert!(s.is_dot());
        assert!(s.bounds.width() > 0.0 && s.bounds.height() > 0.0);
        assert!(s.hit_test(50.0, 50.0, 0.0));
        assert!(!s.hit_test(90.0, 90.0, 0.0));
    }

    #[test]
    fn straight_line_has_expected_bounds() {
        let s = drag(&[(10.0, 10.0), (60.0, 10.0), (110.0, 10.0)]);
        // Length ~100 plus round caps of half-width 2 on each end.
        assert!(s.bounds.width() >= 100.0, "{}", s.bounds.width());
        assert!(s.bounds.width() <= 110.0, "{}", s.bounds.width());
        assert!(s.hit_test(60.0, 10.0, 0.0));
        assert!(s.hit_test(60.0, 11.5, 0.0));
        assert!(!s.hit_test(60.0, 20.0, 0.0));
        assert!(s.hit_test(60.0, 20.0, 10.0));
    }

    #[test]
    fn pressure_tapers_width() {
        let mut b = StrokeBuilder::new(
            InkConfig {
                max_width: 10.0,
                min_width_frac: 0.2,
                ..InkConfig::default()
            },
            InkTool::Pen,
        );
        b.push(InkPoint::with_pressure(0.0, 0.0, Some(1.0), 0.0));
        b.push(InkPoint::with_pressure(50.0, 0.0, Some(0.0), 8.0));
        b.push(InkPoint::with_pressure(100.0, 0.0, Some(0.0), 16.0));
        let s = b.finish().expect("stroke");
        let first = s.spine.first().expect("spine").width;
        let last = s.spine.last().expect("spine").width;
        assert!(first > last, "{first} vs {last}");
        assert!((first - 10.0).abs() < 1.5, "{first}");
        assert!((last - 2.0).abs() < 1.5, "{last}");
    }

    #[test]
    fn highlighter_holds_full_width() {
        let mut b = StrokeBuilder::new(
            InkConfig {
                max_width: 12.0,
                ..InkConfig::default()
            },
            InkTool::Highlighter,
        );
        b.push(InkPoint::with_pressure(0.0, 0.0, Some(0.1), 0.0));
        b.push(InkPoint::with_pressure(80.0, 0.0, Some(0.9), 8.0));
        let s = b.finish().expect("stroke");
        for p in &s.spine {
            assert!((p.width - 12.0).abs() < 1e-6, "{}", p.width);
        }
        assert_eq!(InkTool::Highlighter.base_opacity(), 0.45);
    }
}
