//! Swift `Date` encoding used by `.vsom` files.
//!
//! Swift's `JSONEncoder` default (`.deferredToDate`) writes a `Date` as a
//! JSON number: seconds (fractional) since the Apple reference date,
//! 2001-01-01T00:00:00Z. These helpers convert to/from unix time.

/// Seconds between 1970-01-01T00:00:00Z and 2001-01-01T00:00:00Z.
pub const UNIX_TO_SWIFT_OFFSET: f64 = 978_307_200.0;

/// Current time as a Swift reference-date timestamp.
pub fn swift_now() -> f64 {
    unix_to_swift(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0),
    )
}

/// Unix seconds → Swift reference-date seconds.
pub fn unix_to_swift(unix_secs: f64) -> f64 {
    unix_secs - UNIX_TO_SWIFT_OFFSET
}

/// Swift reference-date seconds → unix seconds.
pub fn swift_to_unix(swift_secs: f64) -> f64 {
    swift_secs + UNIX_TO_SWIFT_OFFSET
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reference_epoch_round_trips() {
        // 2001-01-01T00:00:00Z == unix 978307200 == swift 0.
        assert_eq!(unix_to_swift(978_307_200.0), 0.0);
        assert_eq!(swift_to_unix(0.0), 978_307_200.0);
    }

    #[test]
    fn now_is_plausible() {
        // Must be positive and far past the Y2K-era boards.
        let now = swift_now();
        assert!(now > 700_000_000.0, "unexpected swift_now: {now}");
        assert!(now < 2_000_000_000.0, "unexpected swift_now: {now}");
    }
}
