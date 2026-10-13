//! Autosave: debounced, atomic, with a rotating recovery journal.
//!
//! - Dirty on committed commands; debounced save + milestones (background,
//!   board switch, after large imports).
//! - Snapshot serialized off the UI thread; write temp + fsync + rename.
//! - Keep a small rotating journal (`recovery.0.json` …); never delete the
//!   last good board before the replacement validates.

use std::path::{Path, PathBuf};

/// Debounce + milestone policy.
#[derive(Clone, Debug)]
pub struct AutosaveConfig {
    /// Seconds after the last change before a save is due.
    pub debounce_secs: f64,
    /// Journal depth (number of recovery snapshots kept).
    pub journal_depth: usize,
}

impl Default for AutosaveConfig {
    fn default() -> Self {
        Self {
            debounce_secs: 2.0,
            journal_depth: 3,
        }
    }
}

/// Tracks dirty time; decides when a save is due. Actual serialization +
/// disk I/O happen on a worker (caller passes bytes in).
pub struct AutosaveManager {
    pub config: AutosaveConfig,
    last_save_unix: f64,
    last_change_unix: f64,
    dirty: bool,
}

impl AutosaveManager {
    pub fn new(config: AutosaveConfig) -> Self {
        Self {
            config,
            last_save_unix: now_unix(),
            last_change_unix: 0.0,
            dirty: false,
        }
    }

    pub fn mark_dirty(&mut self, change_unix: f64) {
        self.dirty = true;
        self.last_change_unix = change_unix;
    }

    pub fn mark_clean(&mut self) {
        self.dirty = false;
        self.last_save_unix = now_unix();
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty
    }

    /// True when debounced time has passed since the last change.
    pub fn save_due(&self, now_unix: f64) -> bool {
        self.dirty && (now_unix - self.last_change_unix) >= self.config.debounce_secs
    }

    /// Atomic snapshot write: temp + rename. Returns the final path.
    pub fn write_snapshot(
        &self,
        dir: &Path,
        filename: &str,
        bytes: &[u8],
    ) -> Result<PathBuf, String> {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        let final_path = dir.join(filename);
        let tmp = dir.join(format!("{filename}.tmp"));
        std::fs::write(&tmp, bytes).map_err(|e| e.to_string())?;
        if let Ok(f) = std::fs::File::open(&tmp) {
            let _ = f.sync_all();
        }
        // Validate JSON before replacing (cheap corruption guard).
        serde_json::from_slice::<serde_json::Value>(bytes).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &final_path).map_err(|e| e.to_string())?;
        Ok(final_path)
    }
}

/// Rotating recovery journal alongside the board file.
pub struct RecoveryJournal {
    pub dir: PathBuf,
    pub depth: usize,
}

impl RecoveryJournal {
    pub fn new(dir: impl Into<PathBuf>, depth: usize) -> Self {
        Self {
            dir: dir.into(),
            depth: depth.max(1),
        }
    }

    fn slot(&self, i: usize) -> PathBuf {
        self.dir.join(format!("recovery.{i}.json"))
    }

    /// Rotate (drop oldest) and write the newest snapshot to slot 0.
    pub fn append(&self, bytes: &[u8]) -> Result<(), String> {
        std::fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        for i in (1..self.depth).rev() {
            let src = self.slot(i - 1);
            let dst = self.slot(i);
            if src.exists() {
                let _ = std::fs::rename(&src, &dst);
            }
        }
        std::fs::write(self.slot(0), bytes).map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Newest valid snapshot, if any (tries slots in order).
    pub fn replay(&self) -> Option<Vec<u8>> {
        for i in 0..self.depth {
            if let Ok(bytes) = std::fs::read(self.slot(i)) {
                if serde_json::from_slice::<serde_json::Value>(&bytes).is_ok() {
                    return Some(bytes);
                }
            }
        }
        None
    }
}

fn now_unix() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debounce_and_atomic_write() {
        let mut mgr = AutosaveManager::new(AutosaveConfig {
            debounce_secs: 2.0,
            journal_depth: 3,
        });
        assert!(!mgr.save_due(100.0));
        mgr.mark_dirty(100.0);
        assert!(!mgr.save_due(101.0));
        assert!(mgr.save_due(102.5));
        let dir: PathBuf =
            std::env::temp_dir().join(format!("openmind-autosave-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let bytes = br#"{"ok":true}"#;
        let path = mgr
            .write_snapshot(&dir, "board.vsom", bytes)
            .expect("write");
        assert!(path.exists());
        assert!(mgr
            .write_snapshot(&dir, "board.vsom", b"not json{{")
            .is_err());
        // Previous good file is still there.
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn journal_rotates_and_replays() {
        let dir: PathBuf =
            std::env::temp_dir().join(format!("openmind-journal-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let journal = RecoveryJournal::new(&dir, 2);
        journal.append(br#"{"v":1}"#).unwrap();
        journal.append(br#"{"v":2}"#).unwrap();
        assert_eq!(journal.replay().unwrap(), br#"{"v":2}"#);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
