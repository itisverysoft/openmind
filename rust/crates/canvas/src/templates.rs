//! Board templates: brainstorming, mind map, SWOT, Kanban, meeting notes,
//! project plan, moodboard, weekly planner.
//!
//! Each template builds a fresh [`CanvasDoc`] with sensibly arranged native
//! items. Pure + deterministic (ids fresh per call, layout fixed).

use openmind_board::ShapeKind;

use crate::doc::CanvasDoc;
use crate::model::{CanvasItem, Rect};

#[allow(clippy::too_many_arguments)]
fn add_shape(
    doc: &mut CanvasDoc,
    kind: ShapeKind,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    color: &str,
    label: &str,
) {
    let mut item = CanvasItem::shape(kind, Rect::new(x, y, w, h), color, 0.0);
    if let crate::model::ItemContent::Shape { label: l, .. } = &mut item.content {
        *l = label.to_string();
    }
    doc.add(item);
}

fn add_sticky(doc: &mut CanvasDoc, x: f64, y: f64, color: &str, text: &str) {
    let mut item = CanvasItem::sticky(Rect::new(x, y, 160.0, 160.0), color, 0.0);
    if let crate::model::ItemContent::Sticky { text: t, .. } = &mut item.content {
        *t = text.to_string();
    }
    doc.add(item);
    // `add` selects; clear so the next template item doesn't inherit.
    doc.deselect_all();
}

/// Template ids (stable strings for the gallery UI).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Template {
    Blank,
    Brainstorming,
    MindMap,
    Swot,
    Kanban,
    MeetingNotes,
    ProjectPlan,
    Moodboard,
    WeeklyPlanner,
}

impl Template {
    pub fn title(self) -> &'static str {
        match self {
            Self::Blank => "Blank",
            Self::Brainstorming => "Brainstorming",
            Self::MindMap => "Mind map",
            Self::Swot => "SWOT",
            Self::Kanban => "Kanban",
            Self::MeetingNotes => "Meeting notes",
            Self::ProjectPlan => "Project plan",
            Self::Moodboard => "Moodboard",
            Self::WeeklyPlanner => "Weekly planner",
        }
    }

    pub fn all() -> &'static [Template] {
        &[
            Self::Blank,
            Self::Brainstorming,
            Self::MindMap,
            Self::Swot,
            Self::Kanban,
            Self::MeetingNotes,
            Self::ProjectPlan,
            Self::Moodboard,
            Self::WeeklyPlanner,
        ]
    }

    pub fn build(self) -> CanvasDoc {
        let mut doc = CanvasDoc::new();
        match self {
            Self::Blank => {}
            Self::Brainstorming => {
                add_shape(
                    &mut doc,
                    ShapeKind::RoundedRectangle,
                    4600.0,
                    4800.0,
                    800.0,
                    120.0,
                    "C6E0FF",
                    "Brainstorm",
                );
                add_sticky(&mut doc, 4500.0, 5000.0, "FFF1A8", "Idea 1");
                add_sticky(&mut doc, 4700.0, 5000.0, "C6F6C6", "Idea 2");
                add_sticky(&mut doc, 4900.0, 5000.0, "FFC6C6", "Idea 3");
            }
            Self::MindMap => {
                add_shape(
                    &mut doc,
                    ShapeKind::Ellipse,
                    4920.0,
                    4920.0,
                    160.0,
                    100.0,
                    "FFF1A8",
                    "Central",
                );
                add_shape(
                    &mut doc,
                    ShapeKind::RoundedRectangle,
                    4700.0,
                    4920.0,
                    160.0,
                    80.0,
                    "C6E0FF",
                    "Branch A",
                );
                add_shape(
                    &mut doc,
                    ShapeKind::RoundedRectangle,
                    5140.0,
                    4920.0,
                    160.0,
                    80.0,
                    "C6F6C6",
                    "Branch B",
                );
                add_shape(
                    &mut doc,
                    ShapeKind::RoundedRectangle,
                    4920.0,
                    5100.0,
                    160.0,
                    80.0,
                    "E6C6FF",
                    "Branch C",
                );
            }
            Self::Swot => {
                add_shape(
                    &mut doc,
                    ShapeKind::Rectangle,
                    4600.0,
                    4800.0,
                    380.0,
                    280.0,
                    "C6F6C6",
                    "Strengths",
                );
                add_shape(
                    &mut doc,
                    ShapeKind::Rectangle,
                    5000.0,
                    4800.0,
                    380.0,
                    280.0,
                    "FFC6C6",
                    "Weaknesses",
                );
                add_shape(
                    &mut doc,
                    ShapeKind::Rectangle,
                    4600.0,
                    5100.0,
                    380.0,
                    280.0,
                    "C6E0FF",
                    "Opportunities",
                );
                add_shape(
                    &mut doc,
                    ShapeKind::Rectangle,
                    5000.0,
                    5100.0,
                    380.0,
                    280.0,
                    "FFF1A8",
                    "Threats",
                );
            }
            Self::Kanban => {
                for (i, (title, color)) in
                    [("To do", "FFF1A8"), ("Doing", "C6E0FF"), ("Done", "C6F6C6")]
                        .iter()
                        .enumerate()
                {
                    let x = 4400.0 + i as f64 * 400.0;
                    add_shape(
                        &mut doc,
                        ShapeKind::RoundedRectangle,
                        x,
                        4700.0,
                        360.0,
                        80.0,
                        color,
                        title,
                    );
                    add_sticky(&mut doc, x + 20.0, 4820.0, color, "Task");
                }
            }
            Self::MeetingNotes => {
                add_shape(
                    &mut doc,
                    ShapeKind::Rectangle,
                    4600.0,
                    4700.0,
                    800.0,
                    80.0,
                    "C6E0FF",
                    "Meeting notes",
                );
                let table = CanvasItem::table(Rect::new(4600.0, 4820.0, 800.0, 300.0), 0.0, 4, 2);
                doc.add(table);
                doc.deselect_all();
            }
            Self::ProjectPlan => {
                add_shape(
                    &mut doc,
                    ShapeKind::Capsule,
                    4600.0,
                    4700.0,
                    800.0,
                    80.0,
                    "C6E0FF",
                    "Milestone 1",
                );
                add_shape(
                    &mut doc,
                    ShapeKind::Capsule,
                    4600.0,
                    4820.0,
                    800.0,
                    80.0,
                    "FFF1A8",
                    "Milestone 2",
                );
                add_shape(
                    &mut doc,
                    ShapeKind::Capsule,
                    4600.0,
                    4940.0,
                    800.0,
                    80.0,
                    "C6F6C6",
                    "Milestone 3",
                );
            }
            Self::Moodboard => {
                add_shape(
                    &mut doc,
                    ShapeKind::Rectangle,
                    4500.0,
                    4700.0,
                    360.0,
                    240.0,
                    "E6C6FF",
                    "Palette",
                );
                add_shape(
                    &mut doc,
                    ShapeKind::Ellipse,
                    4920.0,
                    4700.0,
                    240.0,
                    240.0,
                    "C6E0FF",
                    "",
                );
                add_sticky(&mut doc, 4500.0, 5000.0, "FFF1A8", "Vibe");
                add_sticky(&mut doc, 4740.0, 5000.0, "FFC6C6", "Refs");
            }
            Self::WeeklyPlanner => {
                for i in 0..5 {
                    let x = 4300.0 + i as f64 * 220.0;
                    add_shape(
                        &mut doc,
                        ShapeKind::Rectangle,
                        x,
                        4700.0,
                        200.0,
                        60.0,
                        "C6E0FF",
                        &format!("Day {}", i + 1),
                    );
                }
            }
        }
        doc.deselect_all();
        doc
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_template_builds() {
        for t in Template::all() {
            let doc = t.build();
            if *t != Template::Blank {
                assert!(!doc.items.is_empty(), "{:?}", t);
            }
            assert!(doc.selection.is_empty());
        }
    }

    #[test]
    fn kanban_has_three_columns() {
        let doc = Template::Kanban.build();
        assert!(doc.items.len() >= 6);
    }
}
