//! Swift `StrokeCodec` compatibility: stroke points as JSON `[[x, y]]`.
//!
//! The Swift app stores drawing points in `CanvasItem.points_data` as JSON
//! pairs (`Drawing.swift`). These helpers read and write the identical bytes
//! so Rust strokes round-trip through Swift boards.

/// Encode points exactly like `StrokeCodec.encode` (`[[x,y],…]`).
pub fn encode_points(points: &[(f64, f64)]) -> Vec<u8> {
    let pairs: Vec<[f64; 2]> = points.iter().map(|(x, y)| [*x, *y]).collect();
    serde_json::to_vec(&pairs).unwrap_or_default()
}

/// Decode like `StrokeCodec.decode`: empty/garbage → `[]`, pairs that are
/// not exactly `[x, y]` are skipped.
pub fn decode_points(data: &[u8]) -> Vec<(f64, f64)> {
    if data.is_empty() {
        return Vec::new();
    }
    match serde_json::from_slice::<Vec<Vec<f64>>>(data) {
        Err(_) => Vec::new(),
        Ok(pairs) => pairs
            .into_iter()
            .filter_map(|p| match p.as_slice() {
                [x, y] => Some((*x, *y)),
                _ => None,
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_pairs() {
        let pts = vec![(10.0, 20.0), (30.5, -40.25)];
        let bytes = encode_points(&pts);
        assert_eq!(decode_points(&bytes), pts);
    }

    #[test]
    fn swift_bytes_decode() {
        // Bytes exactly as Swift's JSONEncoder writes them.
        let pts = decode_points(b"[[10.0,20.0],[30.0,40.0]]");
        assert_eq!(pts, vec![(10.0, 20.0), (30.0, 40.0)]);
    }

    #[test]
    fn garbage_is_tolerated_like_swift() {
        assert!(decode_points(b"").is_empty());
        assert!(decode_points(b"nope").is_empty());
        // Wrong-arity pairs are skipped, not fatal.
        assert_eq!(decode_points(b"[[1.0],[2.0,3.0]]"), vec![(2.0, 3.0)]);
    }
}
