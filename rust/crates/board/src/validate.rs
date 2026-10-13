//! Validation: finiteness, bounds, traversal, sizes.
//!
//! All user-controlled numbers are checked; failures return contextual
//! errors, never panics.

use crate::stable::{BoardObject, StableBoard};

/// Limits that keep boards openable on modest Macs.
pub struct Limits {
    pub max_objects: usize,
    pub max_dimension: f64,
    pub max_asset_bytes: u64,
    pub max_text_len: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_objects: 50_000,
            max_dimension: 100_000.0,
            max_asset_bytes: 2_000_000_000,
            max_text_len: 1_000_000,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ValidationError {
    BadNumber(String),
    TooManyObjects(usize),
    TooLarge(String),
    BadPath(String),
}

impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadNumber(m) => write!(f, "invalid number: {m}"),
            Self::TooManyObjects(n) => write!(f, "too many objects: {n}"),
            Self::TooLarge(m) => write!(f, "too large: {m}"),
            Self::BadPath(p) => write!(f, "unsafe path: {p}"),
        }
    }
}

impl std::error::Error for ValidationError {}

fn finite(v: f64, what: &str) -> Result<f64, ValidationError> {
    if v.is_finite() {
        Ok(v)
    } else {
        Err(ValidationError::BadNumber(what.to_string()))
    }
}

pub fn validate_board(board: &StableBoard, limits: &Limits) -> Result<(), ValidationError> {
    if board.objects.len() > limits.max_objects {
        return Err(ValidationError::TooManyObjects(board.objects.len()));
    }
    finite(board.created_at, "createdAt")?;
    finite(board.modified_at, "modifiedAt")?;
    for obj in &board.objects {
        validate_object(obj, limits)?;
    }
    Ok(())
}

pub fn validate_object(obj: &BoardObject, limits: &Limits) -> Result<(), ValidationError> {
    let t = &obj.transform;
    finite(t.x, "x")?;
    finite(t.y, "y")?;
    finite(t.width, "width")?;
    finite(t.height, "height")?;
    finite(t.rotation_degs, "rotation")?;
    finite(obj.z_index, "zIndex")?;
    if t.width.abs() > limits.max_dimension || t.height.abs() > limits.max_dimension {
        return Err(ValidationError::TooLarge(format!(
            "object {} frame {}x{}",
            obj.id, t.width, t.height
        )));
    }
    if obj.id.is_empty() || obj.id.len() > 200 {
        return Err(ValidationError::BadNumber("object id".to_string()));
    }
    Ok(())
}

/// Package-relative asset paths only; rejects absolute paths, `..`, and
/// anything outside `assets/`/`thumbnails/`/`previews/`.
pub fn validate_asset_path(path: &str) -> Result<(), ValidationError> {
    if path.is_empty() {
        return Err(ValidationError::BadPath("(empty)".to_string()));
    }
    if path.starts_with('/') || path.contains("..") || path.contains('\\') {
        return Err(ValidationError::BadPath(path.to_string()));
    }
    let ok = path.starts_with("assets/")
        || path.starts_with("thumbnails/")
        || path.starts_with("previews/");
    if !ok {
        return Err(ValidationError::BadPath(path.to_string()));
    }
    if path.len() > 300 {
        return Err(ValidationError::BadPath(path.to_string()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::id::ObjectId;
    use crate::stable::{BoardObjectKind, Transform};

    #[test]
    fn rejects_non_finite_and_traversal() {
        let mut obj = BoardObject::new(
            ObjectId::generate(),
            Transform::rect(f64::NAN, 0.0, 10.0, 10.0),
            1.0,
            BoardObjectKind::Unknown,
        );
        assert!(validate_object(&obj, &Limits::default()).is_err());
        obj.transform.x = 0.0;
        assert!(validate_object(&obj, &Limits::default()).is_ok());
        assert!(validate_asset_path("assets/abc.png").is_ok());
        assert!(validate_asset_path("../etc/passwd").is_err());
        assert!(validate_asset_path("/abs/path").is_err());
        assert!(validate_asset_path("evil").is_err());
    }
}
