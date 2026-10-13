//! YouTube URL recognition + click-to-load refs.
//!
//! Accepted public forms: watch, youtu.be, shorts, embed. Host is validated;
//! arbitrary HTML snippets are never trusted. Playback is click-to-load in an
//! external browser (or a single isolated web view) — never a live view per
//! card, never stream scraping.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum YoutubeError {
    NotYoutube,
    MissingId,
}

impl std::fmt::Display for YoutubeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotYoutube => write!(f, "not a YouTube URL"),
            Self::MissingId => write!(f, "YouTube URL has no video id"),
        }
    }
}

impl std::error::Error for YoutubeError {}

/// Lightweight canvas card: id + thumbnail until activated.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct YoutubeRef {
    pub video_id: String,
    #[serde(default)]
    pub title: String,
}

impl YoutubeRef {
    pub fn embed_url(&self) -> String {
        format!("https://www.youtube.com/embed/{}", self.video_id)
    }

    pub fn watch_url(&self) -> String {
        format!("https://www.youtube.com/watch?v={}", self.video_id)
    }

    pub fn thumbnail_url(&self) -> String {
        format!("https://i.ytimg.com/vi/{}/hqdefault.jpg", self.video_id)
    }
}

fn host_is_youtube(host: &str) -> bool {
    let h = host.to_ascii_lowercase();
    h == "youtube.com"
        || h == "www.youtube.com"
        || h == "m.youtube.com"
        || h == "youtu.be"
        || h == "www.youtu.be"
        || h.ends_with(".youtube.com")
}

fn valid_id(id: &str) -> bool {
    // YouTube ids are 11 chars of [A-Za-z0-9_-]; accept 6..32 to tolerate
    // future forms without accepting query junk.
    (6..=32).contains(&id.len())
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Parse a user-pasted URL into a [`YoutubeRef`]. Pure + total.
pub fn parse_youtube_url(url: &str) -> Result<YoutubeRef, YoutubeError> {
    let url = url.trim();
    // Arbitrary HTML snippets are never trusted, even when they contain a
    // youtube URL (plan §7.1). Reject markup/whitespace outright.
    if url.contains('<')
        || url.contains('>')
        || url.contains('"')
        || url.contains('\'')
        || url.contains(' ')
    {
        return Err(YoutubeError::NotYoutube);
    }
    // Split scheme://host/path?query — no URL crate needed.
    let after_scheme = url.find("://").map(|i| &url[i + 3..]).unwrap_or(url);
    let host_end = after_scheme
        .find(['/', '?', '#'])
        .unwrap_or(after_scheme.len());
    let host = &after_scheme[..host_end];
    if !host_is_youtube(host) {
        return Err(YoutubeError::NotYoutube);
    }
    let rest = &after_scheme[host_end..];
    let host_lc = host.to_ascii_lowercase();

    // youtu.be/VIDEO_ID
    if host_lc == "youtu.be" || host_lc == "www.youtu.be" {
        let id = rest
            .trim_start_matches('/')
            .split(['?', '#', '/'])
            .next()
            .unwrap_or("");
        if valid_id(id) {
            return Ok(YoutubeRef {
                video_id: id.to_string(),
                title: String::new(),
            });
        }
        return Err(YoutubeError::MissingId);
    }

    // /embed/VIDEO_ID, /shorts/VIDEO_ID
    for prefix in ["/embed/", "/shorts/"] {
        if let Some(i) = rest.find(prefix) {
            let id = rest[i + prefix.len()..]
                .split(['?', '#', '/', '&'])
                .next()
                .unwrap_or("");
            if valid_id(id) {
                return Ok(YoutubeRef {
                    video_id: id.to_string(),
                    title: String::new(),
                });
            }
            return Err(YoutubeError::MissingId);
        }
    }

    // /watch?v=VIDEO_ID (query may have other params first)
    if rest.starts_with("/watch") {
        for part in rest.split(['?', '&']) {
            let part = part.trim_start_matches('#');
            if let Some(v) = part.strip_prefix("v=") {
                let id = v.split(['#', '&']).next().unwrap_or("");
                if valid_id(id) {
                    return Ok(YoutubeRef {
                        video_id: id.to_string(),
                        title: String::new(),
                    });
                }
                return Err(YoutubeError::MissingId);
            }
        }
        return Err(YoutubeError::MissingId);
    }

    Err(YoutubeError::MissingId)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_public_forms() {
        for (url, id) in [
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
            (
                "https://youtube.com/watch?v=dQw4w9WgXcQ&t=10s",
                "dQw4w9WgXcQ",
            ),
            ("https://youtu.be/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
            ("https://www.youtube.com/shorts/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
            ("https://www.youtube.com/embed/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ] {
            assert_eq!(parse_youtube_url(url).expect(url).video_id, id);
        }
    }

    #[test]
    fn rejects_non_youtube_and_html() {
        assert_eq!(
            parse_youtube_url("https://vimeo.com/123"),
            Err(YoutubeError::NotYoutube)
        );
        assert_eq!(
            parse_youtube_url("<iframe src=\"https://www.youtube.com/embed/x\"></iframe>"),
            Err(YoutubeError::NotYoutube)
        );
        assert_eq!(
            parse_youtube_url("https://www.youtube.com/watch"),
            Err(YoutubeError::MissingId)
        );
        // Lookalike host.
        assert_eq!(
            parse_youtube_url("https://www.youtube.com.evil.com/watch?v=dQw4w9WgXcQ"),
            Err(YoutubeError::NotYoutube)
        );
    }

    #[test]
    fn embed_and_thumbnail_urls() {
        let r = parse_youtube_url("https://youtu.be/dQw4w9WgXcQ").unwrap();
        assert!(r.embed_url().contains("embed/dQw4w9WgXcQ"));
        assert!(r.thumbnail_url().contains("dQw4w9WgXcQ"));
    }
}
