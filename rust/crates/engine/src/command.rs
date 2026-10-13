//! [`BoardCommand`] + [`Engine`]: undoable, grouped mutations over `CanvasDoc`.

use openmind_canvas::{CanvasDoc, CanvasItem, ItemId, Rect};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineError {
    NoSelection,
    NotFound,
    Locked,
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoSelection => write!(f, "nothing selected"),
            Self::NotFound => write!(f, "object not found"),
            Self::Locked => write!(f, "object is locked"),
        }
    }
}

impl std::error::Error for EngineError {}

/// All mutations flow through these — never ad hoc UI writes.
#[derive(Clone, Debug)]
pub enum BoardCommand {
    AddObject(CanvasItem),
    DeleteObjects(Vec<ItemId>),
    /// Move/resize/rotate selected or listed objects by delta.
    TransformObjects {
        ids: Vec<ItemId>,
        dx: f64,
        dy: f64,
        /// Optional resize delta (world points) applied to w/h.
        dw: f64,
        dh: f64,
    },
    UpdateText {
        id: ItemId,
        text: String,
    },
    ReplaceRichText {
        id: ItemId,
        doc_json: serde_json::Value,
    },
    SetAssetReference {
        id: ItemId,
        asset_hash: String,
    },
    MoveLayer {
        ids: Vec<ItemId>,
        front: bool,
    },
    SetLocked {
        id: ItemId,
        locked: bool,
    },
    Group(Vec<ItemId>),
    Ungroup(Vec<ItemId>),
}

/// Undo grouping: [`Engine::begin_transaction`] snapshots once; inner ops
/// mutate freely; [`Engine::end_transaction`] closes the group. A lone command
/// outside a transaction is its own undo item.
pub struct Engine {
    pub doc: CanvasDoc,
    dirty: bool,
    in_transaction: bool,
    /// Autosave hook: set on every committed command.
    pub last_change_unix: f64,
}

impl Engine {
    pub fn new() -> Self {
        Self {
            doc: CanvasDoc::new(),
            dirty: false,
            in_transaction: false,
            last_change_unix: 0.0,
        }
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty
    }

    pub fn mark_clean(&mut self) {
        self.dirty = false;
    }

    pub fn begin_transaction(&mut self) {
        if !self.in_transaction {
            self.doc.push_undo();
            self.in_transaction = true;
        }
    }

    pub fn end_transaction(&mut self) {
        self.in_transaction = false;
    }

    fn touch(&mut self) {
        self.dirty = true;
        self.last_change_unix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
    }

    fn ensure_undo(&mut self) {
        if !self.in_transaction {
            self.doc.push_undo();
        }
    }

    /// Execute one command. Returns affected ids where meaningful.
    pub fn execute(&mut self, cmd: BoardCommand) -> Result<Vec<ItemId>, EngineError> {
        match cmd {
            BoardCommand::AddObject(item) => {
                self.ensure_undo();
                let id = self.doc.add(item);
                self.touch();
                Ok(vec![id])
            }
            BoardCommand::DeleteObjects(ids) => {
                if ids.is_empty() {
                    return Err(EngineError::NoSelection);
                }
                self.ensure_undo();
                self.doc.selection = ids.clone();
                self.doc.delete_selection();
                self.touch();
                Ok(ids)
            }
            BoardCommand::TransformObjects {
                ids,
                dx,
                dy,
                dw,
                dh,
            } => {
                if ids.is_empty() {
                    return Err(EngineError::NoSelection);
                }
                self.ensure_undo();
                for id in &ids {
                    if let Some(item) = self.doc.find_mut(id) {
                        if item.locked {
                            continue;
                        }
                        item.frame.x += dx;
                        item.frame.y += dy;
                        item.frame.w = (item.frame.w + dw).max(4.0);
                        item.frame.h = (item.frame.h + dh).max(4.0);
                    }
                }
                self.touch();
                Ok(ids)
            }
            BoardCommand::UpdateText { id, text } => {
                if self.doc.find(&id).is_none() {
                    return Err(EngineError::NotFound);
                }
                self.ensure_undo();
                self.doc.set_text(&id, text);
                self.touch();
                Ok(vec![id])
            }
            BoardCommand::ReplaceRichText { id, doc_json } => {
                match self.doc.find(&id) {
                    None => return Err(EngineError::NotFound),
                    Some(item) if item.locked => return Err(EngineError::Locked),
                    _ => {}
                }
                self.ensure_undo();
                let item = self.doc.find_mut(&id).ok_or(EngineError::NotFound)?;
                // Store the structured doc as JSON text for now; the text
                // crate owns the schema. Canvas text items keep plain text in
                // sync for display through the existing renderer.
                if let openmind_canvas::ItemContent::Text { text, .. } = &mut item.content {
                    *text = doc_json.to_string();
                } else if let openmind_canvas::ItemContent::Sticky { text, .. } = &mut item.content
                {
                    *text = doc_json.to_string();
                }
                self.touch();
                Ok(vec![id])
            }
            BoardCommand::SetAssetReference { id, asset_hash } => {
                if asset_hash.is_empty() {
                    return Err(EngineError::NotFound);
                }
                if self.doc.find(&id).is_none() {
                    return Err(EngineError::NotFound);
                }
                self.ensure_undo();
                let item = self.doc.find_mut(&id).ok_or(EngineError::NotFound)?;
                // Asset refs live in new content variants (Audio/Video/Pdf);
                // here we validate the command routes correctly.
                let _ = &mut item.kind_raw;
                self.touch();
                Ok(vec![id])
            }
            BoardCommand::MoveLayer { ids, front } => {
                if ids.is_empty() {
                    return Err(EngineError::NoSelection);
                }
                self.ensure_undo();
                self.doc.selection = ids;
                if front {
                    self.doc.bring_to_front();
                } else {
                    self.doc.send_to_back();
                }
                self.touch();
                Ok(self.doc.selection.clone())
            }
            BoardCommand::SetLocked { id, locked } => {
                if self.doc.find(&id).is_none() {
                    return Err(EngineError::NotFound);
                }
                self.ensure_undo();
                self.doc.set_locked(&id, locked);
                self.touch();
                Ok(vec![id])
            }
            BoardCommand::Group(ids) => {
                if ids.len() < 2 {
                    return Err(EngineError::NoSelection);
                }
                self.ensure_undo();
                self.doc.selection = ids;
                self.doc.group_selection();
                self.touch();
                Ok(self.doc.selection.clone())
            }
            BoardCommand::Ungroup(ids) => {
                self.ensure_undo();
                self.doc.selection = ids;
                self.doc.ungroup_selection();
                self.touch();
                Ok(self.doc.selection.clone())
            }
        }
    }

    /// Convenience: marquee selection does not dirty the board.
    pub fn marquee(&mut self, rect: Rect, additive: bool) {
        self.doc.select_marquee(rect, additive);
    }

    pub fn undo(&mut self) -> bool {
        let ok = self.doc.undo();
        if ok {
            self.dirty = true;
        }
        self.in_transaction = false;
        ok
    }

    pub fn redo(&mut self) -> bool {
        let ok = self.doc.redo();
        if ok {
            self.dirty = true;
        }
        self.in_transaction = false;
        ok
    }
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmind_board::ShapeKind;
    use openmind_canvas::CanvasItem as CItem;

    fn rect_item(x: f64) -> CItem {
        CItem::shape(
            ShapeKind::Rectangle,
            Rect::new(x, 0.0, 20.0, 20.0),
            "C6E0FF",
            0.0,
        )
    }

    #[test]
    fn add_and_undo_grouping() {
        let mut eng = Engine::new();
        assert!(!eng.is_dirty());
        let id = eng
            .execute(BoardCommand::AddObject(rect_item(0.0)))
            .expect("add")[0]
            .clone();
        assert!(eng.is_dirty());
        eng.mark_clean();
        assert!(!eng.is_dirty());
        // Transaction groups two transforms into one undo.
        eng.begin_transaction();
        eng.execute(BoardCommand::TransformObjects {
            ids: vec![id.clone()],
            dx: 5.0,
            dy: 0.0,
            dw: 0.0,
            dh: 0.0,
        })
        .unwrap();
        eng.execute(BoardCommand::TransformObjects {
            ids: vec![id.clone()],
            dx: 5.0,
            dy: 0.0,
            dw: 0.0,
            dh: 0.0,
        })
        .unwrap();
        eng.end_transaction();
        let x1 = eng.doc.find(&id).unwrap().frame.x;
        assert!((x1 - 10.0).abs() < 1e-9);
        assert!(eng.undo());
        let x0 = eng.doc.find(&id).unwrap().frame.x;
        assert!((x0 - 0.0).abs() < 1e-9);
    }

    #[test]
    fn delete_empty_is_error_and_locked_blocks_richtext() {
        let mut eng = Engine::new();
        assert!(eng.execute(BoardCommand::DeleteObjects(vec![])).is_err());
        let id = eng
            .execute(BoardCommand::AddObject(rect_item(0.0)))
            .unwrap()[0]
            .clone();
        eng.execute(BoardCommand::SetLocked {
            id: id.clone(),
            locked: true,
        })
        .unwrap();
        assert_eq!(
            eng.execute(BoardCommand::ReplaceRichText {
                id: id.clone(),
                doc_json: serde_json::json!({}),
            }),
            Err(EngineError::Locked)
        );
    }
}
