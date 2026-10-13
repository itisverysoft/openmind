//! Command-based mutations: every user action flows through [`BoardCommand`].
//!
//! Continuous drags / pen strokes / typing bursts group into one undo item —
//! never one undo per mouse-move or keystroke. Media recording is a service
//! action; only the resulting asset attachment is a command.

#![forbid(unsafe_code)]

pub mod autosave;
pub mod command;

pub use autosave::{AutosaveConfig, AutosaveManager, RecoveryJournal};
pub use command::{BoardCommand, Engine, EngineError};
