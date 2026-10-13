//! Stable identities: boards and objects.
//!
//! `.vsom` records carry no ids, so imports mint fresh ones. The new
//! `.canvaspkg` editing format persists these ids verbatim; sorting or
//! deletion never invalidates references (connectors store endpoint ids +
//! anchors).

use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(1);

fn mint(prefix: &str) -> String {
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let a = nanos ^ n.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    let b = n ^ 0xBF58_476D_1CE4_E5B9;
    format!(
        "{prefix}-{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        (a >> 32) as u32,
        (a >> 16) as u16,
        a as u16,
        (b >> 48) as u16,
        b & 0xFFFF_FFFF_FFFF,
    )
}

/// Stable board identity (`brd-…`, UUID-shaped suffix).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct BoardId(pub String);

impl BoardId {
    pub fn generate() -> Self {
        Self(mint("brd"))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for BoardId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Stable object identity (`obj-…`). Never an array index.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ObjectId(pub String);

impl ObjectId {
    pub fn generate() -> Self {
        Self(mint("obj"))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for ObjectId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique_and_prefixed() {
        let a = BoardId::generate();
        let b = BoardId::generate();
        assert_ne!(a, b);
        assert!(a.0.starts_with("brd-"));
        let x = ObjectId::generate();
        let y = ObjectId::generate();
        assert_ne!(x, y);
        assert!(x.0.starts_with("obj-"));
    }
}
