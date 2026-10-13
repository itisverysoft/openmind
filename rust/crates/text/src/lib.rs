//! Structured rich text: paragraphs + runs, not an HTML string.
//!
//! Display goes through the vector/text stack; editing overlays commit undo
//! transactions at typing bursts/formatting/paste — never per keystroke.
//! Imported HTML is sanitized; embedded scripts never execute.

#![forbid(unsafe_code)]

use serde::{Deserialize, Serialize};

/// Inline formatting for one run.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunStyle {
    #[serde(default)]
    pub bold: bool,
    #[serde(default)]
    pub italic: bool,
    #[serde(default)]
    pub underline: bool,
    #[serde(default)]
    pub strikethrough: bool,
    #[serde(default)]
    pub font_family: Option<String>,
    #[serde(default)]
    pub font_size: Option<f64>,
    #[serde(default)]
    pub text_color: Option<String>,
    #[serde(default)]
    pub highlight_color: Option<String>,
    #[serde(default)]
    pub link: Option<String>,
    #[serde(default)]
    pub code: bool,
}

/// One styled run inside a paragraph.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextRun {
    pub text: String,
    #[serde(default)]
    pub style: RunStyle,
}

impl TextRun {
    pub fn plain(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            style: RunStyle::default(),
        }
    }
}

/// Paragraph alignment.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Align {
    #[default]
    Left,
    Center,
    Right,
    Justify,
}

/// Block kinds: headings, quotes, lists, code.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BlockKind {
    #[default]
    Paragraph,
    Heading1,
    Heading2,
    Heading3,
    Quote,
    Bullet,
    Numbered,
    Code,
}

/// One paragraph / block.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Paragraph {
    #[serde(default)]
    pub kind: BlockKind,
    #[serde(default)]
    pub align: Align,
    #[serde(default)]
    pub indent: u32,
    #[serde(default)]
    pub runs: Vec<TextRun>,
}

impl Paragraph {
    pub fn text(&self) -> String {
        self.runs.iter().map(|r| r.text.as_str()).collect()
    }

    pub fn char_count(&self) -> usize {
        self.runs.iter().map(|r| r.text.chars().count()).sum()
    }
}

/// Versioned rich-text document.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RichTextDoc {
    pub version: u32,
    #[serde(default)]
    pub paragraphs: Vec<Paragraph>,
}

impl RichTextDoc {
    pub const VERSION: u32 = 1;

    pub fn new() -> Self {
        Self {
            version: Self::VERSION,
            paragraphs: Vec::new(),
        }
    }

    pub fn from_plain(text: &str) -> Self {
        let mut doc = Self::new();
        if text.is_empty() {
            doc.paragraphs.push(Paragraph::default());
            return doc;
        }
        for line in text.split('\n') {
            doc.paragraphs.push(Paragraph {
                runs: vec![TextRun::plain(line)],
                ..Default::default()
            });
        }
        doc
    }

    pub fn plain_text(&self) -> String {
        self.paragraphs
            .iter()
            .map(|p| p.text())
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn char_count(&self) -> usize {
        self.paragraphs.iter().map(|p| p.char_count()).sum()
    }

    /// Encode to bytes for `.vsom` `richTextData` / package storage.
    pub fn encode(&self) -> Vec<u8> {
        serde_json::to_vec(self).unwrap_or_default()
    }

    /// Decode leniently: empty/garbage → single empty paragraph (never fails
    /// the board load; editing can then repair it).
    pub fn decode(bytes: &[u8]) -> Self {
        if bytes.is_empty() {
            return Self::from_plain("");
        }
        // Lenient: accept both the struct form and a bare plain string.
        if let Ok(doc) = serde_json::from_slice::<Self>(bytes) {
            return doc;
        }
        if let Ok(text) = serde_json::from_slice::<String>(bytes) {
            return Self::from_plain(&text);
        }
        Self::from_plain(&String::from_utf8_lossy(bytes))
    }

    /// Apply one formatting action to a paragraph run range. Returns false
    /// when indices are out of range (no panic on user data).
    pub fn toggle_bold(&mut self, para: usize, run: usize) -> bool {
        match self
            .paragraphs
            .get_mut(para)
            .and_then(|p| p.runs.get_mut(run))
        {
            Some(r) => {
                r.style.bold = !r.style.bold;
                true
            }
            None => false,
        }
    }
}

/// Sanitize imported HTML into plain text + minimal structure.
///
/// Strips tags, decodes common entities, drops `<script>`/`<style>` content
/// entirely. Never executes anything; returns a [`RichTextDoc`].
pub fn sanitize_html(html: &str) -> RichTextDoc {
    let mut text = String::with_capacity(html.len());
    let mut in_tag = false;
    let mut in_skip = false; // inside script/style
    let mut tag_buf = String::new();
    let lower = html.to_ascii_lowercase();
    let _ = &lower;
    let bytes = html.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if in_skip {
            // Look for closing tag.
            if c == '<' {
                let rest = &html[i..];
                let rl = rest.to_ascii_lowercase();
                if rl.starts_with("</script") || rl.starts_with("</style") {
                    in_skip = false;
                }
            }
            i += 1;
            continue;
        }
        if c == '<' {
            in_tag = true;
            tag_buf.clear();
            i += 1;
            continue;
        }
        if in_tag {
            if c == '>' {
                in_tag = false;
                let t = tag_buf.to_ascii_lowercase();
                let t = t.trim();
                if t.starts_with("script") || t.starts_with("style") {
                    in_skip = true;
                } else if t.starts_with("br") || t.starts_with("p") || t.starts_with("/p") {
                    text.push('\n');
                }
            } else {
                tag_buf.push(c);
            }
            i += 1;
            continue;
        }
        if c == '&' {
            if let Some(semi) = html[i..].find(';') {
                if semi < 10 {
                    let entity = &html[i..i + semi + 1];
                    let decoded = match entity {
                        "&amp;" => Some("&"),
                        "&lt;" => Some("<"),
                        "&gt;" => Some(">"),
                        "&quot;" => Some("\""),
                        "&#39;" | "&apos;" => Some("'"),
                        "&nbsp;" => Some(" "),
                        _ => None,
                    };
                    if let Some(d) = decoded {
                        text.push_str(d);
                        i += semi + 1;
                        continue;
                    }
                }
            }
        }
        text.push(c);
        i += 1;
    }
    // Collapse excessive blank lines, trim.
    let mut lines: Vec<String> = text.lines().map(|l| l.trim().to_string()).collect();
    // Drop leading/trailing empties.
    while lines.first().is_some_and(|l| l.is_empty()) {
        lines.remove(0);
    }
    while lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    RichTextDoc::from_plain(&lines.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_round_trips() {
        let doc = RichTextDoc::from_plain("hello\nworld");
        assert_eq!(doc.paragraphs.len(), 2);
        assert_eq!(doc.plain_text(), "hello\nworld");
        let bytes = doc.encode();
        let back = RichTextDoc::decode(&bytes);
        assert_eq!(doc, back);
    }

    #[test]
    fn decode_is_lenient() {
        assert_eq!(RichTextDoc::decode(b"").paragraphs.len(), 1);
        assert_eq!(RichTextDoc::decode(b"garbage{{").plain_text(), "garbage{{");
        let s = serde_json::to_vec(&"just text".to_string()).unwrap();
        assert_eq!(RichTextDoc::decode(&s).plain_text(), "just text");
    }

    #[test]
    fn sanitize_drops_scripts_and_tags() {
        let doc = sanitize_html("<p>Hello <b>world</b></p><script>alert(1)</script><p>Bye</p>");
        let text = doc.plain_text();
        assert!(text.contains("Hello"), "{text}");
        assert!(text.contains("Bye"), "{text}");
        assert!(!text.contains("alert"), "{text}");
        assert!(!text.contains('<'), "{text}");
    }

    #[test]
    fn toggle_out_of_range_is_false() {
        let mut doc = RichTextDoc::from_plain("hi");
        assert!(doc.toggle_bold(0, 0));
        assert!(!doc.toggle_bold(9, 0));
    }

    #[test]
    fn emoji_and_cjk_survive() {
        let doc = RichTextDoc::from_plain("héllo 🌍 日本語 مرحبا");
        assert_eq!(RichTextDoc::decode(&doc.encode()), doc);
    }
}
