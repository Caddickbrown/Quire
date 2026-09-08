//! The jnl markdown format, in Rust.
//!
//! A faithful port of `Sources/WanderCore/JournalParser.swift` (itself a port of
//! the Go `jnl` CLI), so a folder written by the Mac app, the `jnl` CLI, Nook or
//! this app round-trips byte for byte:
//!
//!     <base>/journal/YYYY/MM/DD.md   one file per day
//!     <base>/inbox.md                undated drafts
//!
//! An entry is a `[YYYY-MM-DD HH:MM:SS] optional title` header line followed by
//! its body. A trailing `*` on the title means starred; `@tags` live inline.

use chrono::{Local, NaiveDateTime};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use walkdir::WalkDir;

pub const STAMP: &str = "%Y-%m-%d %H:%M:%S";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub ts: String,
    pub date: String,
    /// The header's trailing text, star marker included.
    pub suffix: String,
    /// The title without the star marker — what the interface shows.
    pub title: String,
    pub body: String,
    /// The entry as it sits in the file. Kept off the wire: it is the header
    /// plus the body again, and sending it doubled the JSON the front end had
    /// to parse on every load. `rawOf` in app.js rebuilds it where it's wanted.
    #[serde(skip_serializing, default)]
    pub raw: String,
    /// Absolute path of the file the entry lives in.
    pub source: String,
    pub starred: bool,
    pub unfiled: bool,
    pub tags: Vec<String>,
    pub words: usize,
}

/// Both patterns are compiled once for the life of the process. They are used
/// per line and per entry, and `Regex::new` costs far more than the match does:
/// building them afresh each time made a 7,000-entry folder take five seconds
/// to open instead of a quarter of one.
fn header_regex() -> &'static Regex {
    static HEADER: OnceLock<Regex> = OnceLock::new();
    HEADER.get_or_init(|| {
        Regex::new(r"^\[(\d{4}[-–]\d{2}[-–]\d{2}) (\d{2}:\d{2}:\d{2})\](.*)$").unwrap()
    })
}

fn tag_regex() -> &'static Regex {
    static TAG: OnceLock<Regex> = OnceLock::new();
    TAG.get_or_init(|| Regex::new(r"@[a-zA-Z][a-zA-Z0-9_-]*").unwrap())
}

pub fn tags_in(text: &str) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    for found in tag_regex().find_iter(text) {
        let tag = found.as_str().to_string();
        // Deduplicated, case-insensitively: writing @admin three times in an
        // entry still files it under one tag.
        if !seen.iter().any(|s| s.eq_ignore_ascii_case(&tag)) {
            seen.push(tag);
        }
    }
    seen
}

pub fn word_count(text: &str) -> usize {
    text.split_whitespace().count()
}

fn is_starred(suffix: &str) -> bool {
    suffix == "*" || suffix.ends_with(" *")
}

fn display_title(suffix: &str) -> String {
    if is_starred(suffix) {
        suffix[..suffix.len() - 1].trim_end().to_string()
    } else {
        suffix.to_string()
    }
}

fn build(ts: &str, suffix: &str, body: &str, source: &Path, inbox: &Path) -> Entry {
    let mut raw = format!("[{}]", ts);
    if !suffix.is_empty() {
        raw.push(' ');
        raw.push_str(suffix);
    }
    if !body.is_empty() {
        raw.push('\n');
        raw.push_str(body);
    }
    Entry {
        ts: ts.to_string(),
        date: ts[..10].to_string(),
        suffix: suffix.to_string(),
        title: display_title(suffix),
        body: body.to_string(),
        tags: tags_in(&raw),
        words: word_count(body),
        starred: is_starred(suffix),
        unfiled: source == inbox,
        source: source.to_string_lossy().to_string(),
        raw,
    }
}

/// Split a file into entries. Text before the first header is dropped here;
/// `leading_preamble` keeps it for the rewrite.
pub fn parse_entries(content: &str, source: &Path, inbox: &Path) -> Vec<Entry> {
    let header = header_regex();
    let mut entries = Vec::new();
    let mut ts = String::new();
    let mut suffix = String::new();
    let mut body: Vec<&str> = Vec::new();

    for line in content.split('\n') {
        if let Some(caps) = header.captures(line) {
            if !ts.is_empty() {
                entries.push(build(&ts, &suffix, body.join("\n").trim(), source, inbox));
            }
            let date = caps[1].replace('–', "-");
            ts = format!("{} {}", date, &caps[2]);
            suffix = caps[3].trim().to_string();
            body.clear();
        } else if !ts.is_empty() {
            body.push(line);
        }
    }
    if !ts.is_empty() {
        entries.push(build(&ts, &suffix, body.join("\n").trim(), source, inbox));
    }
    entries
}

pub fn leading_preamble(content: &str) -> String {
    let header = header_regex();
    let mut lines = Vec::new();
    for line in content.split('\n') {
        if header.is_match(line) {
            break;
        }
        lines.push(line);
    }
    let text = lines.join("\n");
    if text.trim().is_empty() {
        String::new()
    } else {
        text.trim_end_matches('\n').to_string()
    }
}

pub fn render_entries(preamble: &str, entries: &[Entry]) -> String {
    let mut parts: Vec<String> = Vec::new();
    if !preamble.is_empty() {
        parts.push(preamble.trim_end_matches('\n').to_string());
    }
    for entry in entries {
        parts.push(entry.raw.trim_end_matches('\n').to_string());
    }
    if parts.is_empty() {
        String::new()
    } else {
        format!("{}\n", parts.join("\n\n"))
    }
}

// MARK: Folder

pub struct Library {
    pub base: PathBuf,
}

impl Library {
    pub fn new(base: PathBuf) -> Self {
        Library { base }
    }

    pub fn inbox(&self) -> PathBuf {
        self.base.join("inbox.md")
    }

    pub fn journal_dir(&self) -> PathBuf {
        self.base.join("journal")
    }

    /// journal/YYYY/MM/DD.md for a "YYYY-MM-DD" date.
    pub fn day_file(&self, date: &str) -> Option<PathBuf> {
        let parts: Vec<&str> = date.split('-').collect();
        if parts.len() != 3 {
            return None;
        }
        Some(
            self.journal_dir()
                .join(parts[0])
                .join(parts[1])
                .join(format!("{}.md", parts[2])),
        )
    }

    pub fn ensure(&self) {
        let _ = fs::create_dir_all(self.journal_dir());
    }

    /// Every entry in the folder, newest first.
    pub fn load(&self) -> Vec<Entry> {
        let inbox = self.inbox();
        let mut found: Vec<Entry> = Vec::new();

        if let Ok(content) = fs::read_to_string(&inbox) {
            found.extend(parse_entries(&content, &inbox, &inbox));
        }
        for item in WalkDir::new(self.journal_dir()).into_iter().flatten() {
            let path = item.path();
            if path.extension().map(|e| e == "md").unwrap_or(false) {
                if let Ok(content) = fs::read_to_string(path) {
                    found.extend(parse_entries(&content, path, &inbox));
                }
            }
        }
        found.sort_by(|a, b| b.ts.cmp(&a.ts));
        found
    }

    /// Rewrite the file that owns `entry`, replacing the entry with the same
    /// timestamp or appending it.
    pub fn persist(&self, entry: &Entry) -> std::io::Result<Entry> {
        let target = PathBuf::from(&entry.source);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let existing = fs::read_to_string(&target).unwrap_or_default();
        let preamble = leading_preamble(&existing);
        let inbox = self.inbox();
        let mut day = parse_entries(&existing, &target, &inbox);

        match day.iter().position(|e| e.ts == entry.ts) {
            Some(index) => day[index] = entry.clone(),
            None => day.push(entry.clone()),
        }
        day.sort_by(|a, b| a.ts.cmp(&b.ts));
        write_atomically(&target, &render_entries(&preamble, &day))?;
        Ok(entry.clone())
    }

    /// Take an entry out of its file, deleting the file if nothing is left.
    pub fn remove(&self, entry: &Entry) -> std::io::Result<()> {
        let target = PathBuf::from(&entry.source);
        let existing = match fs::read_to_string(&target) {
            Ok(content) => content,
            Err(_) => return Ok(()),
        };
        let preamble = leading_preamble(&existing);
        let inbox = self.inbox();
        let day: Vec<Entry> = parse_entries(&existing, &target, &inbox)
            .into_iter()
            .filter(|e| e.ts != entry.ts)
            .collect();
        let content = render_entries(&preamble, &day);
        if content.trim().is_empty() {
            let _ = fs::remove_file(&target);
        } else {
            write_atomically(&target, &content)?;
        }
        Ok(())
    }

    /// A free timestamp at or after `desired` in `target` — two entries in one
    /// file may not share a second, since the timestamp is the identity.
    pub fn free_stamp(&self, desired: &str, target: &Path, excluding: Option<&str>) -> String {
        let content = match fs::read_to_string(target) {
            Ok(text) => text,
            Err(_) => return desired.to_string(),
        };
        let inbox = self.inbox();
        let taken: Vec<String> = parse_entries(&content, target, &inbox)
            .into_iter()
            .map(|e| e.ts)
            .filter(|ts| Some(ts.as_str()) != excluding)
            .collect();

        let mut stamp = desired.to_string();
        let mut moment = NaiveDateTime::parse_from_str(&stamp, STAMP)
            .unwrap_or_else(|_| Local::now().naive_local());
        while taken.contains(&stamp) {
            moment += chrono::Duration::seconds(1);
            stamp = moment.format(STAMP).to_string();
        }
        stamp
    }

    /// Build an entry from edited parts, keeping its timestamp and file.
    pub fn compose(&self, ts: &str, title: &str, body: &str, starred: bool, source: &Path) -> Entry {
        let mut suffix = title.trim().to_string();
        if starred {
            suffix = if suffix.is_empty() {
                "*".to_string()
            } else {
                format!("{} *", suffix)
            };
        }
        build(ts, &suffix, body.trim(), source, &self.inbox())
    }
}

fn write_atomically(target: &Path, content: &str) -> std::io::Result<()> {
    let tmp = target.with_extension("wander-tmp");
    fs::write(&tmp, content)?;
    fs::rename(&tmp, target)
}

/// Where the chosen folder is remembered between launches. The Apple builds use
/// UserDefaults; this is the same idea, in the place each platform keeps its
/// per-app configuration.
pub fn config_file() -> PathBuf {
    let home = dirs_home();
    #[cfg(target_os = "macos")]
    let dir = home.join("Library/Application Support/wander");
    #[cfg(not(target_os = "macos"))]
    let dir = match std::env::var("XDG_CONFIG_HOME") {
        Ok(path) if !path.is_empty() => PathBuf::from(path).join("wander"),
        _ => home.join(".config/wander"),
    };
    dir.join("folder")
}

pub fn remembered_folder() -> Option<String> {
    let path = fs::read_to_string(config_file()).ok()?;
    let trimmed = path.trim().to_string();
    if trimmed.is_empty() || !PathBuf::from(&trimmed).is_dir() {
        return None;
    }
    Some(trimmed)
}

pub fn remember_folder(path: &Path) {
    let file = config_file();
    if let Some(parent) = file.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(file, path.to_string_lossy().as_bytes());
}

/// An explicit folder, then `JNL_DIR` so an existing jnl or Nook journal opens
/// as-is, then ~/Documents/Wander.
pub fn resolve_base(preferred: Option<String>) -> PathBuf {
    if let Some(path) = preferred {
        let candidate = PathBuf::from(&path);
        if candidate.is_dir() {
            return candidate;
        }
    }
    if let Ok(path) = std::env::var("JNL_DIR") {
        let candidate = PathBuf::from(path);
        if candidate.is_dir() {
            return candidate;
        }
    }
    let home = dirs_home();
    let documents = home.join("Documents");
    let base = if documents.is_dir() {
        documents.join("Wander")
    } else {
        home.join("wander")
    };
    let _ = fs::create_dir_all(&base);
    base
}

fn dirs_home() -> PathBuf {
    #[cfg(target_family = "unix")]
    {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home);
        }
    }
    #[cfg(target_family = "windows")]
    {
        if let Ok(profile) = std::env::var("USERPROFILE") {
            return PathBuf::from(profile);
        }
    }
    PathBuf::from(".")
}
