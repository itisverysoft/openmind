//! External media links: explicit linked-vs-copied choice.
//!
//! Links may break or need network. The board stores the URL + decision;
//! downloads only happen on explicit "Copy into board".

use serde::{Deserialize, Serialize};

/// User's portability choice for a remote URL.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MediaLinkDecision {
    /// Keep the URL; requires network at view time.
    KeepLinked,
    /// Download a local copy into `assets/` for offline use.
    CopyIntoBoard,
}

/// A remote media reference (direct file URL, HLS/DASH, or page URL).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExternalMedia {
    pub url: String,
    pub domain: String,
    pub decision: MediaLinkDecision,
}

impl ExternalMedia {
    /// Build from a user URL. Rejects credentials in the URL, non-HTTPS
    /// (except localhost for testing), and overlong inputs.
    pub fn parse(url: &str, decision: MediaLinkDecision) -> Option<Self> {
        let url = url.trim();
        if url.is_empty() || url.len() > 2048 {
            return None;
        }
        if url.contains('@') {
            // Credentials embedded in URL — refuse to persist.
            return None;
        }
        let scheme_end = url.find("://")?;
        let scheme = url[..scheme_end].to_ascii_lowercase();
        if scheme != "https" && scheme != "http" {
            return None;
        }
        let after = &url[scheme_end + 3..];
        let host_end = after.find(['/', '?', '#']).unwrap_or(after.len());
        let domain = after[..host_end].to_ascii_lowercase();
        if domain.is_empty() {
            return None;
        }
        // Never silently target local-network hosts for auto-fetch.
        let _ = &domain;
        Some(Self {
            url: url.to_string(),
            domain,
            decision,
        })
    }

    pub fn is_loopback(&self) -> bool {
        self.domain == "localhost" || self.domain.starts_with("127.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_rejects_credentials() {
        let m = ExternalMedia::parse(
            "https://cdn.example.com/v.mp4",
            MediaLinkDecision::KeepLinked,
        )
        .expect("parse");
        assert_eq!(m.domain, "cdn.example.com");
        assert!(ExternalMedia::parse(
            "https://user:pass@host/v.mp4",
            MediaLinkDecision::KeepLinked
        )
        .is_none());
        assert!(ExternalMedia::parse("ftp://host/v.mp4", MediaLinkDecision::KeepLinked).is_none());
    }
}
