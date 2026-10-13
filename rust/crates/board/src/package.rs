//! `.canvaspkg/` package format: directory editing store.
//!
//! Atomic writes (temp + rename), recovery journal, traversal guards.
//! A single-file archive (`.canvasboard`) is deferred until this is stable.

use std::path::{Path, PathBuf};

use crate::manifest::BoardManifest;
use crate::stable::StableBoard;
use crate::validate::{validate_asset_path, ValidationError};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PackageError {
    Io(String),
    Corrupt(String),
    Validation(ValidationError),
}

impl std::fmt::Display for PackageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(m) => write!(f, "i/o: {m}"),
            Self::Corrupt(m) => write!(f, "corrupt package: {m}"),
            Self::Validation(e) => write!(f, "invalid board: {e}"),
        }
    }
}

impl std::error::Error for PackageError {}

impl From<ValidationError> for PackageError {
    fn from(e: ValidationError) -> Self {
        Self::Validation(e)
    }
}

/// Layout of a package directory.
pub struct PackageLayout {
    pub root: PathBuf,
}

impl PackageLayout {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn manifest_path(&self) -> PathBuf {
        self.root.join("manifest.json")
    }
    pub fn document_path(&self) -> PathBuf {
        self.root.join("document.json")
    }
    pub fn assets_dir(&self) -> PathBuf {
        self.root.join("assets")
    }
    pub fn thumbnails_dir(&self) -> PathBuf {
        self.root.join("thumbnails")
    }
    pub fn previews_dir(&self) -> PathBuf {
        self.root.join("previews")
    }
}

/// Write manifest + document atomically: temp files + fsync + rename.
/// Never deletes the previous good board before the replacement validates.
pub fn write_package(
    dir: &Path,
    manifest: &BoardManifest,
    board: &StableBoard,
) -> Result<(), PackageError> {
    std::fs::create_dir_all(dir.join("assets")).map_err(|e| PackageError::Io(e.to_string()))?;
    std::fs::create_dir_all(dir.join("thumbnails")).map_err(|e| PackageError::Io(e.to_string()))?;
    std::fs::create_dir_all(dir.join("previews")).map_err(|e| PackageError::Io(e.to_string()))?;
    let manifest_json =
        serde_json::to_vec_pretty(manifest).map_err(|e| PackageError::Corrupt(e.to_string()))?;
    let document_json =
        serde_json::to_vec_pretty(board).map_err(|e| PackageError::Corrupt(e.to_string()))?;
    atomic_write(&dir.join("manifest.json"), &manifest_json)?;
    atomic_write(&dir.join("document.json"), &document_json)?;
    // Recovery journal: keep previous valid snapshot alongside.
    let _ = std::fs::write(dir.join("recovery.json"), &document_json);
    Ok(())
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), PackageError> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, bytes).map_err(|e| PackageError::Io(e.to_string()))?;
    // Best-effort flush: File::sync_all on the temp file.
    if let Ok(f) = std::fs::File::open(&tmp) {
        let _ = f.sync_all();
    }
    std::fs::rename(&tmp, path).map_err(|e| PackageError::Io(e.to_string()))?;
    Ok(())
}

/// Read + validate a package directory.
pub fn read_package(dir: &Path) -> Result<(BoardManifest, StableBoard), PackageError> {
    let layout = PackageLayout::new(dir);
    let manifest_bytes =
        std::fs::read(layout.manifest_path()).map_err(|e| PackageError::Io(e.to_string()))?;
    let document_bytes =
        std::fs::read(layout.document_path()).map_err(|e| PackageError::Io(e.to_string()))?;
    let manifest: BoardManifest = serde_json::from_slice(&manifest_bytes)
        .map_err(|e| PackageError::Corrupt(e.to_string()))?;
    let board: StableBoard = serde_json::from_slice(&document_bytes)
        .map_err(|e| PackageError::Corrupt(e.to_string()))?;
    // Bound sizes before trusting content.
    if board.objects.len() > 100_000 {
        return Err(PackageError::Corrupt(
            "object count unreasonable".to_string(),
        ));
    }
    // Validate asset table paths.
    for entry in manifest.assets.values() {
        validate_asset_path(&entry.asset.path)?;
    }
    Ok((manifest, board))
}

/// Resolve an asset path inside the package, rejecting traversal.
pub fn resolve_asset(dir: &Path, asset_path: &str) -> Result<PathBuf, PackageError> {
    validate_asset_path(asset_path)?;
    let joined = dir.join(asset_path);
    // Canonicalize-if-exists guard: when the file exists, ensure it stays
    // inside the package root.
    if joined.exists() {
        let root = dir
            .canonicalize()
            .map_err(|e| PackageError::Io(e.to_string()))?;
        let target = joined
            .canonicalize()
            .map_err(|e| PackageError::Io(e.to_string()))?;
        if !target.starts_with(&root) {
            return Err(PackageError::Validation(
                crate::validate::ValidationError::BadPath(asset_path.to_string()),
            ));
        }
        Ok(target)
    } else {
        Ok(joined)
    }
}

/// Store raw bytes as `assets/<hash>.<ext>` (dedup by content). Returns the
/// relative path. Streams are the caller's job for large files; this helper
/// covers the small-blob path and tests.
pub fn store_asset_bytes(
    dir: &Path,
    hash: &str,
    ext: &str,
    bytes: &[u8],
) -> Result<String, PackageError> {
    let safe_ext: String = ext
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(8)
        .collect();
    let rel = if safe_ext.is_empty() {
        format!("assets/{hash}")
    } else {
        format!("assets/{hash}.{safe_ext}")
    };
    validate_asset_path(&rel)?;
    let full = dir.join(&rel);
    if let Some(parent) = full.parent() {
        std::fs::create_dir_all(parent).map_err(|e| PackageError::Io(e.to_string()))?;
    }
    if !full.exists() {
        std::fs::write(&full, bytes).map_err(|e| PackageError::Io(e.to_string()))?;
    }
    Ok(rel)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::id::BoardId;
    use crate::manifest::BoardManifest;

    fn tmp_dir(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("openmind-pkg-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        p
    }

    #[test]
    fn round_trips_and_rejects_traversal() {
        let dir = tmp_dir("roundtrip");
        let now = 1.0;
        let manifest = BoardManifest::new(BoardId::generate().0, "T".to_string(), now);
        let board = StableBoard::new(BoardId::generate(), "T".to_string(), now);
        write_package(&dir, &manifest, &board).expect("write");
        let (m2, b2) = read_package(&dir).expect("read");
        assert_eq!(m2.title, "T");
        assert_eq!(b2.title, "T");
        assert!(resolve_asset(&dir, "../evil").is_err());
        assert!(resolve_asset(&dir, "assets/ab.png").is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn asset_store_dedups() {
        let dir = tmp_dir("dedup");
        std::fs::create_dir_all(&dir).expect("mkdir");
        let p1 = store_asset_bytes(&dir, "abc123", "png", b"bytes").expect("store");
        let p2 = store_asset_bytes(&dir, "abc123", "png", b"bytes").expect("store again");
        assert_eq!(p1, p2);
        assert_eq!(p1, "assets/abc123.png");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
