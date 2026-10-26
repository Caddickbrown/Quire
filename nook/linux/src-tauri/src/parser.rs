//! Pure, platform-independent parsing/rendering of the jnl markdown format.
//! Ported faithfully from ~/Code/jnl/main.go (and the Swift `JournalParser`)
//! so files round-trip identically to the Go `jnl` CLI and macOS/iOS Nook.

use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};

// Header: [YYYY-MM-DD HH:MM:SS] optional trailing text.
// Accepts ASCII hyphen or en-dash (U+2013) in the date (jnl normalises to hyphen).
static HEADER_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^\[(\d{4}[-\u{2013}]\d{2}[-\u{2013}]\d{2}) (\d{2}:\d{2}:\d{2})\](.*)").unwrap()
});
static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"@[a-zA-Z][a-zA-Z0-9_-]*").unwrap());
static MEDIA_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"!\[[^\]]*\]\(([^)]+)\)").unwrap());

/// A single journal entry. Mirrors the `entry` struct in the jnl Go backend so
/// the on-disk format stays byte-compatible: a `[YYYY-MM-DD HH:MM:SS] optional
/// title` header followed by body.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub date: String,   // "YYYY-MM-DD"
    pub ts: String,     // "YYYY-MM-DD HH:MM:SS"
    pub suffix: String, // text after the timestamp on the header line (the "title")
    pub body: String,   // lines after the header, trimmed of leading/trailing blanks
    pub raw: String,    // full original text including the (normalised) header line
    // Convenience fields computed at parse time (so the frontend needs no logic):
    pub header: String,
    pub is_starred: bool,
    pub display_title: String,
    pub preview: String,
    pub tags: Vec<String>,
    pub word_count: usize,
    pub media_badges: Vec<String>,
}

impl Entry {
    fn build(date: String, ts: String, suffix: String, body: String, raw: String) -> Entry {
        // Standalone token only: `ends_with('*')` also matched a markdown-bold
        // title like `**Important**`. Mirrors Swift `Entry.isStarred`.
        let is_starred = suffix == "*" || suffix.ends_with(" *");
        let display_title = if is_starred {
            let mut s = suffix.clone();
            s.pop();
            s.trim().to_string()
        } else {
            suffix.clone()
        };
        let header = if suffix.is_empty() {
            format!("[{}]", ts)
        } else {
            format!("[{}] {}", ts, suffix)
        };
        let preview = if !display_title.is_empty() {
            display_title.clone()
        } else {
            body.split('\n')
                .find(|l| !l.trim().is_empty())
                .unwrap_or("")
                .to_string()
        };
        let tags = split_tags(&raw);
        let word_count = body
            .split(|c: char| c == ' ' || c == '\n' || c == '\t')
            .filter(|w| !w.is_empty())
            .count();
        let media_badges = media_badges(&raw);
        Entry {
            date,
            ts,
            suffix,
            body,
            raw,
            header,
            is_starred,
            display_title,
            preview,
            tags,
            word_count,
            media_badges,
        }
    }
}

/// What kind of media a path points at, decided by its file extension. This is
/// the *one* place the extension lists live — the badges, the calendar dots,
/// the `has:` search filter and the Year in Review tally all read it, and they
/// had drifted apart. Mirrors `Entry.mediaBadges` on the Apple side; keep them
/// in step. `webm`/`weba`/`ogg`/`opus`/`flac`/`mkv` are here because the Linux
/// app itself records into them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    Image,
    Video,
    Audio,
    Other,
}

pub const VIDEO_EXTS: [&str; 5] = ["mov", "mp4", "m4v", "webm", "mkv"];
pub const AUDIO_EXTS: [&str; 11] =
    ["m4a", "mp3", "wav", "aac", "aiff", "caf", "ogg", "oga", "opus", "flac", "weba"];
pub const IMAGE_EXTS: [&str; 11] =
    ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg"];

pub fn media_kind(path: &str) -> MediaKind {
    let ext = path.rsplit('.').next().unwrap_or("").to_lowercase();
    let ext = ext.as_str();
    if VIDEO_EXTS.contains(&ext) {
        MediaKind::Video
    } else if AUDIO_EXTS.contains(&ext) {
        MediaKind::Audio
    } else if IMAGE_EXTS.contains(&ext) {
        MediaKind::Image
    } else {
        MediaKind::Other
    }
}

/// SF-Symbol-equivalent badge kinds for the media an entry links.
fn media_badges(raw: &str) -> Vec<String> {
    let paths = media_paths(raw);
    if paths.is_empty() {
        return vec![];
    }
    let (mut image, mut audio, mut video, mut other) = (false, false, false, false);
    for p in paths {
        match media_kind(&p) {
            MediaKind::Video => video = true,
            MediaKind::Audio => audio = true,
            MediaKind::Image => image = true,
            MediaKind::Other => other = true,
        }
    }
    let mut out = vec![];
    if image {
        out.push("photo".into());
    }
    if audio {
        out.push("mic".into());
    }
    if video {
        out.push("film".into());
    }
    if other {
        out.push("paperclip".into());
    }
    out
}

/// Match the header line, returning (date, time, suffix) or None.
fn match_header(line: &str) -> Option<(String, String, String)> {
    let c = HEADER_RE.captures(line)?;
    Some((
        c.get(1)?.as_str().to_string(),
        c.get(2)?.as_str().to_string(),
        c.get(3)?.as_str().to_string(),
    ))
}

/// Split file content into entries. Content before the first header is dropped
/// (see `leading_preamble` to preserve it on rewrite).
pub fn parse_entries(content: &str) -> Vec<Entry> {
    let mut entries: Vec<Entry> = vec![];
    let mut cur: Vec<String> = vec![];
    let mut cur_ts = String::new();
    let mut cur_date = String::new();
    let mut cur_suffix = String::new();

    macro_rules! flush {
        () => {
            if !cur_ts.is_empty() {
                let body = cur
                    .iter()
                    .skip(1)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join("\n")
                    .trim()
                    .to_string();
                entries.push(Entry::build(
                    cur_date.clone(),
                    cur_ts.clone(),
                    cur_suffix.clone(),
                    body,
                    cur.join("\n"),
                ));
            }
        };
    }

    for line in content.split('\n') {
        if let Some((date, time, suffix)) = match_header(line) {
            flush!();
            cur_date = date.replace('\u{2013}', "-");
            cur_ts = format!("{} {}", cur_date, time);
            cur_suffix = suffix.trim().to_string();
            let norm_header = if cur_suffix.is_empty() {
                format!("[{}]", cur_ts)
            } else {
                format!("[{}] {}", cur_ts, cur_suffix)
            };
            cur = vec![norm_header];
        } else if !cur_ts.is_empty() {
            cur.push(line.to_string());
        }
    }
    flush!();
    entries
}

/// Content before the first header (or "" if only blank/absent).
pub fn leading_preamble(content: &str) -> String {
    let mut pre: Vec<&str> = vec![];
    for line in content.split('\n') {
        if match_header(line).is_some() {
            break;
        }
        pre.push(line);
    }
    let text = trim_right_newlines(&pre.join("\n"));
    if text.trim().is_empty() {
        String::new()
    } else {
        text
    }
}

/// Copy ordered by timestamp, oldest first. Stable; input untouched.
pub fn sorted_by_timestamp(entries: &[Entry]) -> Vec<Entry> {
    let mut indexed: Vec<(usize, &Entry)> = entries.iter().enumerate().collect();
    indexed.sort_by(|a, b| a.1.ts.cmp(&b.1.ts).then(a.0.cmp(&b.0)));
    indexed.into_iter().map(|(_, e)| e.clone()).collect()
}

/// Rebuild file content from a preamble + entries, preserving raw text.
pub fn render_entries(preamble: &str, entries: &[Entry]) -> String {
    let mut parts: Vec<String> = vec![];
    if !preamble.is_empty() {
        parts.push(trim_right_newlines(preamble));
    }
    for e in entries {
        parts.push(trim_right_newlines(&e.raw));
    }
    if parts.is_empty() {
        return String::new();
    }
    format!("{}\n", parts.join("\n\n"))
}

/// All `@tag` tokens in `s`, in order of appearance.
pub fn split_tags(s: &str) -> Vec<String> {
    TAG_RE.find_iter(s).map(|m| m.as_str().to_string()).collect()
}

/// Extract the paths from markdown media links in some content.
pub fn media_paths(content: &str) -> Vec<String> {
    MEDIA_RE
        .captures_iter(content)
        .filter_map(|c| c.get(1).map(|m| m.as_str().to_string()))
        .collect()
}

/// Trim only trailing "\n" characters (Go strings.TrimRight(s, "\n")).
pub fn trim_right_newlines(s: &str) -> String {
    s.trim_end_matches('\n').to_string()
}

/// jnl cmdCleanup's punctuation pass (… and straight quotes), applied only
/// outside `![alt](path)` media links — a filename or URL containing "..."
/// must never be rewritten into an ellipsis and the link broken.
pub fn normalize_punctuation(s: &str) -> String {
    fn fix(t: &str) -> String {
        t.replace("...", "\u{2026}")
            .replace('\u{2019}', "'")
            .replace('\u{201C}', "\"")
            .replace('\u{201D}', "\"")
    }
    let re = regex::Regex::new(r"!\[[^\]]*\]\([^)]+\)").unwrap();
    let mut out = String::new();
    let mut cursor = 0;
    for m in re.find_iter(s) {
        out.push_str(&fix(&s[cursor..m.start()]));
        out.push_str(m.as_str()); // the link, verbatim
        cursor = m.end();
    }
    out.push_str(&fix(&s[cursor..]));
    out
}

#[cfg(test)]
mod star_tests {
    use super::*;

    fn titled(suffix: &str) -> Entry {
        parse_entries(&format!("[2026-05-10 08:00:00] {}\nbody\n", suffix))
            .into_iter()
            .next()
            .unwrap()
    }

    /// Mirrors the Swift `Entry.isStarred` cases: the marker is a standalone
    /// token, so a markdown-bold title is not starred (and can't be mangled by
    /// un-starring it).
    #[test]
    fn star_marker_is_a_standalone_token() {
        assert!(titled("Morning *").is_starred);
        assert!(titled("*").is_starred);
        assert!(!titled("**bold**").is_starred);
        assert!(!titled("2 * 3").is_starred);
        assert!(!titled("").is_starred);
        assert_eq!(titled("Morning *").display_title, "Morning");
        assert_eq!(titled("*").display_title, "");
        assert_eq!(titled("**bold**").display_title, "**bold**");
    }
}

#[cfg(test)]
mod punctuation_tests {
    use super::*;

    #[test]
    fn normalize_masks_media_links() {
        assert_eq!(normalize_punctuation("wait... what"), "wait\u{2026} what");
        assert_eq!(
            normalize_punctuation("see... ![dots](assets/a...b.png) end..."),
            "see\u{2026} ![dots](assets/a...b.png) end\u{2026}"
        );
        assert_eq!(normalize_punctuation("![alt...](a.png)"), "![alt...](a.png)");
    }
}
