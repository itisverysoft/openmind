//! [`CanvasDoc`]: ordered items, selection, undo.

use openmind_board::CanvasItem as BoardItem;

use crate::model::{id, CanvasItem, ItemId, Rect};

/// Deep snapshot for undo/redo.
#[derive(Clone, Debug)]
struct Snapshot {
    items: Vec<CanvasItem>,
    selection: Vec<ItemId>,
    foreign: Vec<BoardItem>,
    next_z: f64,
}

/// Maximum undo steps (oldest dropped first).
const MAX_UNDO: usize = 100;

/// Selection drag offset applied at draw time (world points). Mirrors the
/// Swift group-drag: the model commits once, on release.
pub const DRAG_OFFSET: f64 = 20.0;

pub struct CanvasDoc {
    pub items: Vec<CanvasItem>,
    pub selection: Vec<ItemId>,
    /// Records the canvas cannot edit (other kinds, other pages) — carried
    /// verbatim through `.vsom` save so round trips never drop user data.
    pub foreign: Vec<BoardItem>,
    pub(crate) next_z: f64,
    past: Vec<Snapshot>,
    future: Vec<Snapshot>,
}

impl CanvasDoc {
    pub fn new() -> Self {
        Self {
            items: Vec::new(),
            selection: Vec::new(),
            foreign: Vec::new(),
            next_z: 1.0,
            past: Vec::new(),
            future: Vec::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty() && self.selection.is_empty()
    }

    fn snapshot(&self) -> Snapshot {
        Snapshot {
            items: self.items.clone(),
            selection: self.selection.clone(),
            foreign: self.foreign.clone(),
            next_z: self.next_z,
        }
    }

    fn restore(&mut self, snap: Snapshot) {
        self.items = snap.items;
        self.selection = snap.selection;
        self.foreign = snap.foreign;
        self.next_z = snap.next_z;
    }

    /// Snapshot current state for undo. Call before each discrete mutation;
    /// continuous gestures (move drags) call it once at gesture start and
    /// then mutate freely.
    pub fn push_undo(&mut self) {
        if self.past.len() >= MAX_UNDO {
            self.past.remove(0);
        }
        self.past.push(self.snapshot());
        self.future.clear();
    }

    pub fn undo(&mut self) -> bool {
        let snap = match self.past.pop() {
            Some(s) => s,
            None => return false,
        };
        self.future.push(self.snapshot());
        self.restore(snap);
        true
    }

    pub fn redo(&mut self) -> bool {
        let snap = match self.future.pop() {
            Some(s) => s,
            None => return false,
        };
        self.past.push(self.snapshot());
        self.restore(snap);
        true
    }

    pub fn can_undo(&self) -> bool {
        !self.past.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.future.is_empty()
    }

    // -- lookup -----------------------------------------------------------

    pub fn find(&self, id: &ItemId) -> Option<&CanvasItem> {
        self.items.iter().find(|i| &i.id == id)
    }

    pub fn find_mut(&mut self, id: &ItemId) -> Option<&mut CanvasItem> {
        self.items.iter_mut().find(|i| &i.id == id)
    }

    pub fn selected_items(&self) -> Vec<&CanvasItem> {
        self.selection
            .iter()
            .filter_map(|id| self.find(id))
            .collect()
    }

    fn sort_by_z(&mut self) {
        self.items.sort_by(|a, b| a.z.total_cmp(&b.z));
    }

    // -- groups -----------------------------------------------------------

    /// Whole group containing `id` (just itself when ungrouped).
    pub fn members_of(&self, id: &ItemId) -> Vec<ItemId> {
        let group = self.find(id).and_then(|i| i.group.clone());
        match group {
            None => vec![id.clone()],
            Some(g) => self
                .items
                .iter()
                .filter(|i| i.group.as_deref() == Some(g.as_str()))
                .map(|i| i.id.clone())
                .collect(),
        }
    }

    fn expand_ids(&self, ids: &[ItemId]) -> Vec<ItemId> {
        let mut out: Vec<ItemId> = Vec::new();
        for id in ids {
            for m in self.members_of(id) {
                if !out.contains(&m) {
                    out.push(m);
                }
            }
        }
        out
    }

    // -- selection --------------------------------------------------------

    /// Plain click: exclusive group selection. Shift-click: toggle the whole
    /// group. Mirrors `CanvasView.select`.
    pub fn select(&mut self, id: &ItemId, additive: bool) {
        let members = self.members_of(id);
        if additive {
            if members.iter().all(|m| self.selection.contains(m)) {
                self.selection.retain(|s| !members.contains(s));
            } else {
                for m in members {
                    if !self.selection.contains(&m) {
                        self.selection.push(m);
                    }
                }
            }
        } else {
            self.selection = members;
        }
    }

    pub fn deselect_all(&mut self) {
        self.selection.clear();
    }

    /// Marquee: replace (or union, when additive) with group-expanded hits.
    pub fn select_marquee(&mut self, rect: Rect, additive: bool) {
        let hits: Vec<ItemId> = self
            .items
            .iter()
            .filter(|i| i.frame.intersects(rect))
            .map(|i| i.id.clone())
            .collect();
        let expanded = self.expand_ids(&hits);
        if additive {
            for id in expanded {
                if !self.selection.contains(&id) {
                    self.selection.push(id);
                }
            }
        } else {
            self.selection = expanded;
        }
    }

    /// Topmost item (highest z) containing the point.
    pub fn hit_topmost(&self, x: f64, y: f64) -> Option<ItemId> {
        self.items
            .iter()
            .rev()
            .find(|i| i.frame.contains_point(x, y))
            .map(|i| i.id.clone())
    }

    // -- mutation (each snapshots first, except move_selection) -----------

    pub fn add(&mut self, mut item: CanvasItem) -> ItemId {
        self.push_undo();
        item.z = self.next_z;
        self.next_z += 1.0;
        let id = item.id.clone();
        self.items.push(item);
        self.sort_by_z();
        self.selection = vec![id.clone()];
        id
    }

    /// Free move for drag gestures: caller snapshots once at gesture start.
    pub fn move_selection(&mut self, dx: f64, dy: f64) {
        for item in self.items.iter_mut() {
            if self.selection.contains(&item.id) && !item.locked {
                item.frame.x += dx;
                item.frame.y += dy;
            }
        }
    }

    /// Eraser: drop every drawing stroke touching `(x, y)` (plus `extra`
    /// tolerance); drawing items left strokeless are removed. No snapshot —
    /// callers snapshot once at gesture start.
    /// Returns true when anything changed.
    pub fn erase_at(&mut self, x: f64, y: f64, extra: f64) -> bool {
        let mut changed = false;
        for item in self.items.iter_mut() {
            if item.locked {
                continue;
            }
            if let crate::model::ItemContent::Drawing { strokes } = &mut item.content {
                let before = strokes.len();
                strokes.retain(|s| !s.stroke.hit_test(x, y, extra));
                changed |= strokes.len() != before;
            }
        }
        if changed {
            let emptied: Vec<ItemId> = self
                .items
                .iter()
                .filter(|i| {
                    matches!(&i.content, crate::model::ItemContent::Drawing { strokes } if strokes.is_empty())
                })
                .map(|i| i.id.clone())
                .collect();
            self.items.retain(|i| !emptied.contains(&i.id));
            self.selection.retain(|s| !emptied.contains(s));
        }
        changed
    }

    pub fn delete_selection(&mut self) {
        let victims: Vec<ItemId> = self
            .selection
            .iter()
            .filter(|id| self.find(id).is_some_and(|i| !i.locked))
            .cloned()
            .collect();
        if victims.is_empty() {
            return;
        }
        self.push_undo();
        self.items.retain(|i| !victims.contains(&i.id));
        self.selection.retain(|s| !victims.contains(s));
    }

    /// Duplicate selection with a +20pt offset. Copies of one group regroup
    /// under a fresh id (mirrors `remappedGroupIDs`); copies start unlocked.
    pub fn duplicate_selection(&mut self) -> Vec<ItemId> {
        let originals: Vec<CanvasItem> = self.selected_items().into_iter().cloned().collect();
        if originals.is_empty() {
            return Vec::new();
        }
        self.push_undo();
        let mut group_map: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        for o in &originals {
            if let Some(g) = &o.group {
                group_map.entry(g.clone()).or_insert_with(|| id().0.clone());
            }
        }
        let mut new_ids = Vec::new();
        for mut o in originals {
            o.id = id();
            o.frame.x += DRAG_OFFSET;
            o.frame.y += DRAG_OFFSET;
            o.z = self.next_z;
            self.next_z += 1.0;
            o.locked = false;
            if let Some(g) = o.group.take() {
                if let Some(mapped) = group_map.get(&g) {
                    o.group = Some(mapped.clone());
                }
            }
            new_ids.push(o.id.clone());
            self.items.push(o);
        }
        self.sort_by_z();
        self.selection = new_ids.clone();
        new_ids
    }

    pub fn group_selection(&mut self) -> Option<String> {
        if self.selection.len() < 2 {
            return None;
        }
        self.push_undo();
        let gid = id().0;
        for item in self.items.iter_mut() {
            if self.selection.contains(&item.id) {
                item.group = Some(gid.clone());
            }
        }
        Some(gid)
    }

    pub fn ungroup_selection(&mut self) {
        if !self.selected_items().iter().any(|i| i.group.is_some()) {
            return;
        }
        self.push_undo();
        for item in self.items.iter_mut() {
            if self.selection.contains(&item.id) {
                item.group = None;
            }
        }
    }

    pub fn set_locked(&mut self, id: &ItemId, locked: bool) {
        if self.find(id).is_none() {
            return;
        }
        self.push_undo();
        if let Some(item) = self.find_mut(id) {
            item.locked = locked;
        }
    }

    pub fn set_text(&mut self, id: &ItemId, text: String) {
        if self.find(id).is_none() {
            return;
        }
        self.push_undo();
        if let Some(item) = self.find_mut(id) {
            match &mut item.content {
                crate::model::ItemContent::Sticky { text: t, .. }
                | crate::model::ItemContent::Text { text: t, .. } => *t = text,
                crate::model::ItemContent::Shape { label: t, .. } => *t = text,
                crate::model::ItemContent::Drawing { .. }
                | crate::model::ItemContent::Image { .. } => {}
            }
        }
    }

    /// Live text-editing write: no snapshot (caller snapshots once at edit
    /// start via [`CanvasDoc::push_undo`]).
    pub fn set_text_live(&mut self, id: &ItemId, text: &str) {
        if let Some(item) = self.find_mut(id) {
            match &mut item.content {
                crate::model::ItemContent::Sticky { text: t, .. }
                | crate::model::ItemContent::Text { text: t, .. } => *t = text.to_string(),
                crate::model::ItemContent::Shape { label: t, .. } => *t = text.to_string(),
                crate::model::ItemContent::Drawing { .. }
                | crate::model::ItemContent::Image { .. } => {}
            }
        }
    }

    fn arrange<F>(&mut self, order: F)
    where
        F: FnOnce(Vec<CanvasItem>, &[ItemId]) -> Vec<CanvasItem>,
    {
        if self.selection.is_empty() {
            return;
        }
        self.push_undo();
        let items = std::mem::take(&mut self.items);
        let mut ordered = order(items, &self.selection);
        let mut z = 1.0;
        for item in ordered.iter_mut() {
            item.z = z;
            z += 1.0;
        }
        self.next_z = z;
        self.items = ordered;
    }

    pub fn bring_to_front(&mut self) {
        self.arrange(|mut items, sel| {
            items.sort_by(|a, b| {
                let sa = sel.contains(&a.id);
                let sb = sel.contains(&b.id);
                sa.cmp(&sb).then_with(|| a.z.total_cmp(&b.z))
            });
            items
        });
    }

    pub fn send_to_back(&mut self) {
        self.arrange(|mut items, sel| {
            items.sort_by(|a, b| {
                let sa = sel.contains(&a.id);
                let sb = sel.contains(&b.id);
                sb.cmp(&sa).then_with(|| a.z.total_cmp(&b.z))
            });
            items
        });
    }

    pub fn clear(&mut self) {
        if self.items.is_empty() && self.selection.is_empty() {
            return;
        }
        self.push_undo();
        // Native items go; foreign records stay so a stray Clear can never
        // silently drop media/pages this build cannot show yet.
        self.items.clear();
        self.selection.clear();
    }

    /// Union frame of the selection, if any.
    pub fn selection_bounds(&self) -> Option<Rect> {
        let mut acc: Option<Rect> = None;
        for item in self.selected_items() {
            acc = Some(match acc {
                None => item.frame,
                Some(a) => a.union(item.frame),
            });
        }
        acc
    }
}

impl Default for CanvasDoc {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ItemContent;
    use openmind_board::ShapeKind;

    fn rect_item(x: f64) -> CanvasItem {
        CanvasItem::shape(
            ShapeKind::Rectangle,
            Rect::new(x, 0.0, 20.0, 20.0),
            "C6E0FF",
            0.0,
        )
    }

    fn doc_with(items: Vec<CanvasItem>) -> CanvasDoc {
        let mut doc = CanvasDoc::new();
        for item in items {
            doc.add(item);
        }
        doc.deselect_all();
        doc
    }

    #[test]
    fn click_selects_exclusively_and_shift_toggles() {
        let mut doc = doc_with(vec![rect_item(0.0), rect_item(50.0)]);
        let a = doc.items[0].id.clone();
        let b = doc.items[1].id.clone();
        doc.select(&a, false);
        assert_eq!(doc.selection, vec![a.clone()]);
        doc.select(&b, true);
        assert_eq!(doc.selection.len(), 2);
        doc.select(&a, true);
        assert_eq!(doc.selection, vec![b]);
    }

    #[test]
    fn grouped_items_act_as_one() {
        let mut doc = doc_with(vec![rect_item(0.0), rect_item(50.0), rect_item(100.0)]);
        let a = doc.items[0].id.clone();
        let b = doc.items[1].id.clone();
        let c = doc.items[2].id.clone();
        doc.selection = vec![a.clone(), b.clone()];
        doc.group_selection();
        doc.deselect_all();
        doc.select(&a, false);
        assert!(doc.selection.contains(&a) && doc.selection.contains(&b));
        assert!(!doc.selection.contains(&c));
        // Shift-click a member removes the whole group.
        doc.select(&b, true);
        assert!(doc.selection.is_empty());
    }

    #[test]
    fn marquee_hits_frames() {
        let mut doc = doc_with(vec![rect_item(0.0), rect_item(50.0), rect_item(200.0)]);
        doc.select_marquee(Rect::new(0.0, -5.0, 80.0, 30.0), false);
        assert_eq!(doc.selection.len(), 2);
    }

    #[test]
    fn locked_items_do_not_move_or_delete() {
        let mut doc = doc_with(vec![rect_item(0.0)]);
        let a = doc.items[0].id.clone();
        doc.select(&a, false);
        doc.set_locked(&a, true);
        doc.move_selection(10.0, 10.0);
        assert_eq!(doc.items[0].frame.x, 0.0);
        doc.delete_selection();
        assert_eq!(doc.items.len(), 1);
    }

    #[test]
    fn duplicate_offsets_and_regroups() {
        let mut doc = doc_with(vec![rect_item(0.0), rect_item(50.0)]);
        let a = doc.items[0].id.clone();
        doc.select(&a, false);
        let new_ids = doc.duplicate_selection();
        assert_eq!(new_ids.len(), 1);
        assert_eq!(doc.items.len(), 3);
        let copy = doc.find(&new_ids[0]).expect("copy");
        assert_eq!(copy.frame.x, 20.0);
    }

    #[test]
    fn undo_redo_round_trip() {
        let mut doc = doc_with(vec![rect_item(0.0)]);
        assert_eq!(doc.items.len(), 1);
        let a = doc.items[0].id.clone();
        doc.select(&a, false);
        doc.delete_selection();
        assert!(doc.items.is_empty());
        assert!(doc.undo());
        assert_eq!(doc.items.len(), 1);
        assert!(doc.redo());
        assert!(doc.items.is_empty());
        assert!(!doc.redo());
    }

    #[test]
    fn set_text_targets_textual_content() {
        let mut doc = CanvasDoc::new();
        let sticky = CanvasItem::sticky(Rect::new(0.0, 0.0, 160.0, 160.0), "FFF1A8", 0.0);
        let sid = doc.add(sticky);
        doc.set_text(&sid, "hello".to_string());
        match &doc.find(&sid).expect("item").content {
            ItemContent::Sticky { text, .. } => assert_eq!(text, "hello"),
            other => panic!("wrong content: {other:?}"),
        }
    }
}
