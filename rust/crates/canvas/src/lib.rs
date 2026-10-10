//! Canvas document: whiteboard items, selection, groups, arrange, undo.
//!
//! This is the app-independent scene model. It mirrors the Swift app's
//! canvas semantics (`CanvasView.select`, `CanvasGrouping`, arrange
//! commands):
//!
//! * Items carry a stable [`ItemId`], a `z` order, lock + group state, and
//!   typed [`ItemContent`]. Anything the canvas cannot edit yet (tables,
//!   audio/video/YouTube, non-zero pages) rides along untouched in
//!   [`CanvasDoc::foreign`] so `.vsom` round trips never drop user data.
//! * Selection expands grouped items automatically; Shift toggles groups.
//! * Undo is snapshot-based (capped): mutating ops snapshot first, except
//!   continuous drags — those snapshot once at gesture start and call
//!   [`CanvasDoc::move_selection`] freely until release.

#![forbid(unsafe_code)]

pub mod doc;
pub mod model;
pub mod vsom;

pub use doc::CanvasDoc;
pub use model::{id, CanvasItem, ItemContent, ItemId, PaintedInk, Rect};
