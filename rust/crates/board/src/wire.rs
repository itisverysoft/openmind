//! Serde helpers matching Swift `JSONEncoder`/`JSONDecoder` conventions.

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use serde::{Deserialize, Deserializer, Serializer};

/// `Data` (possibly empty) as a base64 string. Always present on encode,
/// even when empty — exactly like Swift.
pub mod serde_base64 {
    use super::*;

    pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&B64.encode(bytes))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
        // Tolerate missing/null as well as the canonical string.
        let opt = Option::<String>::deserialize(d)?;
        match opt {
            None => Ok(Vec::new()),
            Some(text) if text.is_empty() => Ok(Vec::new()),
            Some(text) => B64
                .decode(text.as_bytes())
                .map_err(serde::de::Error::custom),
        }
    }
}

/// `Data?` as a base64 string or null. Missing keys also decode to `None`.
pub mod serde_base64_opt {
    use super::*;

    pub fn serialize<S: Serializer>(bytes: &Option<Vec<u8>>, s: S) -> Result<S::Ok, S::Error> {
        match bytes {
            None => s.serialize_none(),
            Some(b) => s.serialize_str(&B64.encode(b)),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<u8>>, D::Error> {
        let opt = Option::<String>::deserialize(d)?;
        match opt {
            None => Ok(None),
            Some(text) if text.is_empty() => Ok(Some(Vec::new())),
            Some(text) => B64
                .decode(text.as_bytes())
                .map(Some)
                .map_err(serde::de::Error::custom),
        }
    }
}

#[cfg(test)]
mod tests {
    use serde::{Deserialize, Serialize};

    #[derive(Serialize, Deserialize, PartialEq, Debug)]
    struct Probe {
        #[serde(with = "super::serde_base64")]
        #[serde(default)]
        data: Vec<u8>,
        #[serde(with = "super::serde_base64_opt")]
        #[serde(default)]
        maybe: Option<Vec<u8>>,
    }

    #[test]
    fn data_round_trips_like_swift() {
        // Swift: JSONEncoder().encode(Data([0x89,0x50])) == "\"iVA=\"" (base64).
        let p = Probe {
            data: vec![0x89, 0x50],
            maybe: None,
        };
        let json = serde_json::to_string(&p).expect("encode");
        assert!(json.contains("\"iVA=\""), "{json}");
        assert!(json.contains("\"maybe\":null"), "{json}");
        let back: Probe = serde_json::from_str(&json).expect("decode");
        assert_eq!(back, p);
    }

    #[test]
    fn empty_and_missing_are_tolerated() {
        let p: Probe = serde_json::from_str(r#"{"data":"","maybe":""}"#).expect("decode");
        assert_eq!(p.data, Vec::<u8>::new());
        assert_eq!(p.maybe, Some(Vec::new()));
        let p: Probe = serde_json::from_str("{}").expect("decode");
        assert_eq!(p.data, Vec::<u8>::new());
        assert_eq!(p.maybe, None);
    }
}
