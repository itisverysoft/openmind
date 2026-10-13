//! Viewport culling + hit testing via a uniform grid index.
//!
//! - Query only objects intersecting the visible world-space viewport.
//! - Incremental insert/update/delete (no full rebuild on pointer move).
//! - Cheap bbox tests before expensive path/text hit tests.
//! - Selected objects + active gestures stay available across viewport edges
//!   (callers union selection bounds with the visible set).

use std::collections::{HashMap, HashSet};

use crate::model::{ItemId, Rect};

/// Cell size in world points. 512 balances small stickies vs. large images.
pub const CELL: f64 = 512.0;

fn cell_range(rect: Rect) -> (i64, i64, i64, i64) {
    let x0 = (rect.x / CELL).floor() as i64;
    let y0 = (rect.y / CELL).floor() as i64;
    let x1 = ((rect.x + rect.w) / CELL).floor() as i64;
    let y1 = ((rect.y + rect.h) / CELL).floor() as i64;
    (x0, y0, x1, y1)
}

/// Grid index: cell → item ids. The doc owns frames; the index is a hint that
/// must be kept in sync via insert/update/remove.
#[derive(Clone, Debug, Default)]
pub struct SpatialIndex {
    cells: HashMap<(i64, i64), HashSet<String>>,
    /// id-string → covered cells (for incremental updates).
    placement: HashMap<String, Vec<(i64, i64)>>,
}

impl SpatialIndex {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn clear(&mut self) {
        self.cells.clear();
        self.placement.clear();
    }

    fn cells_for(rect: Rect) -> Vec<(i64, i64)> {
        let (x0, y0, x1, y1) = cell_range(rect);
        let mut out = Vec::new();
        // Guard against degenerate giant frames covering the planet.
        let w = (x1 - x0 + 1).clamp(1, 64);
        let h = (y1 - y0 + 1).clamp(1, 64);
        for dx in 0..w {
            for dy in 0..h {
                out.push((x0 + dx, y0 + dy));
            }
        }
        out
    }

    pub fn insert(&mut self, id: &ItemId, rect: Rect) {
        self.remove(id);
        let cells = Self::cells_for(rect);
        for c in &cells {
            self.cells.entry(*c).or_default().insert(id.0.clone());
        }
        self.placement.insert(id.0.clone(), cells);
    }

    pub fn remove(&mut self, id: &ItemId) {
        if let Some(old) = self.placement.remove(&id.0) {
            for c in old {
                if let Some(set) = self.cells.get_mut(&c) {
                    set.remove(&id.0);
                    if set.is_empty() {
                        self.cells.remove(&c);
                    }
                }
            }
        }
    }

    /// Incremental move: same as insert (old cells dropped first).
    pub fn update(&mut self, id: &ItemId, rect: Rect) {
        self.insert(id, rect);
    }

    /// Rebuild from scratch (load, undo/redo, arrange).
    pub fn rebuild(&mut self, items: &[(ItemId, Rect)]) {
        self.clear();
        for (id, rect) in items {
            let cells = Self::cells_for(*rect);
            for c in &cells {
                self.cells.entry(*c).or_default().insert(id.0.clone());
            }
            self.placement.insert(id.0.clone(), cells);
        }
    }

    /// Ids intersecting `viewport` (world rect). Caller resolves to items and
    /// unions selection/active gestures.
    pub fn query(&self, viewport: Rect) -> Vec<String> {
        let (x0, y0, x1, y1) = cell_range(viewport);
        let mut out: HashSet<String> = HashSet::new();
        let w = (x1 - x0 + 1).clamp(1, 64);
        let h = (y1 - y0 + 1).clamp(1, 64);
        for dx in 0..w {
            for dy in 0..h {
                if let Some(set) = self.cells.get(&(x0 + dx, y0 + dy)) {
                    out.extend(set.iter().cloned());
                }
            }
        }
        out.into_iter().collect()
    }

    pub fn len(&self) -> usize {
        self.placement.len()
    }

    pub fn is_empty(&self) -> bool {
        self.placement.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::id;

    #[test]
    fn insert_query_update_remove() {
        let mut idx = SpatialIndex::new();
        let a = id();
        let b = id();
        idx.insert(&a, Rect::new(0.0, 0.0, 100.0, 100.0));
        idx.insert(&b, Rect::new(5000.0, 5000.0, 100.0, 100.0));
        let hits = idx.query(Rect::new(-10.0, -10.0, 600.0, 600.0));
        assert!(hits.contains(&a.0));
        assert!(!hits.contains(&b.0));
        idx.update(&a, Rect::new(5000.0, 5000.0, 50.0, 50.0));
        let hits2 = idx.query(Rect::new(-10.0, -10.0, 600.0, 600.0));
        assert!(!hits2.contains(&a.0));
        idx.remove(&b);
        assert_eq!(idx.len(), 1);
    }

    #[test]
    fn rebuild_matches_inserts() {
        let mut idx = SpatialIndex::new();
        let a = id();
        let items = vec![(a.clone(), Rect::new(10.0, 10.0, 20.0, 20.0))];
        idx.rebuild(&items);
        assert_eq!(idx.query(Rect::new(0.0, 0.0, 100.0, 100.0)), vec![a.0]);
    }
}
