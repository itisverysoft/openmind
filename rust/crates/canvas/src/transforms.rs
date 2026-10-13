//! Object transforms: move/resize/rotate with bounds guards.
//!
//! All math is in board/world coordinates; screen conversion happens only at
//! the view boundary (`board::Viewport`).

use crate::model::Rect;

/// Normalized resize: drag corner `corner` (0..3) by world delta, keeping a
/// 4pt minimum and finite coordinates. Returns the new frame or `None` when
/// the delta is non-finite.
pub fn resize_frame(frame: Rect, corner: u8, dx: f64, dy: f64) -> Option<Rect> {
    if !dx.is_finite() || !dy.is_finite() {
        return None;
    }
    let mut f = frame;
    match corner % 4 {
        0 => {
            // Top-left.
            let nx = f.x + dx;
            let ny = f.y + dy;
            let nw = f.w - dx;
            let nh = f.h - dy;
            if nw >= 4.0 && nh >= 4.0 {
                f.x = nx;
                f.y = ny;
                f.w = nw;
                f.h = nh;
            }
        }
        1 => {
            // Top-right.
            let ny = f.y + dy;
            let nw = f.w + dx;
            let nh = f.h - dy;
            if nw >= 4.0 && nh >= 4.0 {
                f.y = ny;
                f.w = nw;
                f.h = nh;
            }
        }
        2 => {
            // Bottom-right.
            let nw = f.w + dx;
            let nh = f.h + dy;
            if nw >= 4.0 && nh >= 4.0 {
                f.w = nw;
                f.h = nh;
            }
        }
        _ => {
            // Bottom-left.
            let nx = f.x + dx;
            let nw = f.w - dx;
            let nh = f.h + dy;
            if nw >= 4.0 && nh >= 4.0 {
                f.x = nx;
                f.w = nw;
                f.h = nh;
            }
        }
    }
    if f.x.is_finite() && f.y.is_finite() && f.w.is_finite() && f.h.is_finite() {
        Some(f)
    } else {
        None
    }
}

/// Rotation in degrees clockwise, normalized to [0, 360).
pub fn normalize_rotation(degs: f64) -> f64 {
    if !degs.is_finite() {
        return 0.0;
    }
    ((degs % 360.0) + 360.0) % 360.0
}

/// Multi-select resize: scale every frame about the selection-bounds origin
/// by `factor` (from a corner drag). Pure helper for gestures.
pub fn scale_frames_about(frames: &[Rect], origin: (f64, f64), factor: f64) -> Vec<Rect> {
    if !factor.is_finite() || factor <= 0.0 {
        return frames.to_vec();
    }
    frames
        .iter()
        .map(|f| {
            Rect::new(
                origin.0 + (f.x - origin.0) * factor,
                origin.1 + (f.y - origin.1) * factor,
                (f.w * factor).max(4.0),
                (f.h * factor).max(4.0),
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resize_keeps_minimum_and_finite() {
        let f = Rect::new(0.0, 0.0, 100.0, 60.0);
        let grown = resize_frame(f, 2, 10.0, 10.0).expect("resize");
        assert_eq!((grown.w, grown.h), (110.0, 70.0));
        // Shrinking below minimum is ignored, not inverted.
        let shrunk = resize_frame(f, 2, -200.0, 0.0).expect("resize");
        assert_eq!((shrunk.w, shrunk.h), (100.0, 60.0));
        assert!(resize_frame(f, 2, f64::NAN, 0.0).is_none());
    }

    #[test]
    fn rotation_normalizes() {
        assert_eq!(normalize_rotation(370.0), 10.0);
        assert_eq!(normalize_rotation(-10.0), 350.0);
        assert_eq!(normalize_rotation(f64::INFINITY), 0.0);
    }
}
