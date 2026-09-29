//! The jnl markdown format, in Rust.
//!
//! A faithful port of `Sources/WanderCore/JournalParser.swift` (itself a port of
//! the Go `jnl` CLI), so a folder written by the Mac app, the `jnl` CLI, Nook or
//! this app round-trips byte for byte:
//!
//! ```text
//! <base>/journal/YYYY/MM/DD.md   one file per day
//! <base>/inbox.md                undated drafts
//! ```
//!
//! An entry is a `[YYYY-MM-DD HH:MM:SS] optional title` header line followed by
//! its body. A trailing `*` on the title means starred; `@tags` live inline.

use chrono::{Local, NaiveDateTime};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::ErrorKind;
use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;
use walkdir::WalkDir;

pub const STAMP: &str = "%Y-%m-%d %H:%M:%S";

/// What a reader is told when a day file can't be decoded. It gets its own
/// words, not the generic failure, because the remedy is theirs to take.
pub const NOT_UTF8: &str =
    "This file isn't valid UTF-8. Open it in an editor and re-save it as UTF-8.";

/// The date of a `YYYY-MM-DD HH:MM:SS` stamp, or `None` if it isn't one. Every
/// stamp that arrives from the webview comes through here before it can name a
/// file or be written as a header: a malformed one would otherwise slice past
/// the end of the string, climb out of the journal with `..`, or be written as
/// a header the parser can't read back — an entry that vanishes on reload.
pub fn stamp_date(ts: &str) -> Option<&str> {
    let parsed = NaiveDateTime::parse_from_str(ts, STAMP).ok()?;
    // chrono will take an unpadded month or day; the format won't.
    if parsed.format(STAMP).to_string() != ts {
        return None;
    }
    ts.get(..10)
}

/// A file's text with CRLF folded to LF — once, where it is read, so the parser
/// and the preamble see the same lines and the rewrite is LF throughout rather
/// than half of each.
fn normalised(content: String) -> String {
    if content.contains('\r') {
        content.replace("\r\n", "\n")
    } else {
        content
    }
}

/// A day file's text: `None` if it doesn't exist yet. Any other failure is an
/// error, never an empty file — rewriting from an empty parse would throw away
/// every entry in it but the one being saved.
fn read_day(path: &Path) -> Result<Option<String>, String> {
    match fs::read_to_string(path) {
        Ok(content) => Ok(Some(normalised(content))),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(None),
        Err(e) if e.kind() == ErrorKind::InvalidData => Err(NOT_UTF8.to_string()),
        Err(e) => Err(e.to_string()),
    }
}

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
        date: ts.get(..10).unwrap_or_default().to_string(),
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
            found.extend(parse_entries(&normalised(content), &inbox, &inbox));
        }
        for item in WalkDir::new(self.journal_dir()).into_iter().flatten() {
            let path = item.path();
            if path.extension().map(|e| e == "md").unwrap_or(false) {
                if let Ok(content) = fs::read_to_string(path) {
                    found.extend(parse_entries(&normalised(content), path, &inbox));
                }
            }
        }
        found.sort_by(|a, b| b.ts.cmp(&a.ts));
        found
    }

    /// Whether `path` is a file this library may touch: inbox.md or a `.md`
    /// under journal/, named without `..`. The webview names the file for every
    /// write, and nothing it sends should reach outside the folder.
    pub fn owns(&self, path: &Path) -> bool {
        if path.components().any(|c| matches!(c, Component::ParentDir)) {
            return false;
        }
        if path == self.inbox() {
            return true;
        }
        path.starts_with(self.journal_dir()) && path.extension().is_some_and(|e| e == "md")
    }

    /// Rewrite `target` without the entry stamped `drop` and with `add` in its
    /// place (or appended). The one primitive behind persist, remove and a move
    /// within a file. A file left with nothing in it is deleted.
    pub fn rewrite(&self, target: &Path, drop: Option<&str>, add: Option<&Entry>) -> Result<(), String> {
        let existing = read_day(target)?;
        if existing.is_none() && add.is_none() {
            return Ok(());
        }
        let existing = existing.unwrap_or_default();
        let preamble = leading_preamble(&existing);
        let inbox = self.inbox();
        let mut day: Vec<Entry> = parse_entries(&existing, target, &inbox)
            .into_iter()
            .filter(|e| Some(e.ts.as_str()) != drop)
            .collect();

        if let Some(entry) = add {
            match day.iter().position(|e| e.ts == entry.ts) {
                Some(index) => day[index] = entry.clone(),
                None => day.push(entry.clone()),
            }
            day.sort_by(|a, b| a.ts.cmp(&b.ts));
        }
        let content = render_entries(&preamble, &day);
        if content.trim().is_empty() {
            return match fs::remove_file(target) {
                Err(e) if e.kind() != ErrorKind::NotFound => Err(e.to_string()),
                _ => Ok(()),
            };
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        write_atomically(target, &content).map_err(|e| e.to_string())
    }

    /// Rewrite the file that owns `entry`, replacing the entry with the same
    /// timestamp or appending it.
    pub fn persist(&self, entry: &Entry) -> Result<Entry, String> {
        self.rewrite(Path::new(&entry.source), None, Some(entry))?;
        Ok(entry.clone())
    }

    /// Take an entry out of its file, deleting the file if nothing is left.
    pub fn remove(&self, entry: &Entry) -> Result<(), String> {
        self.rewrite(Path::new(&entry.source), Some(&entry.ts), None)
    }

    /// A free timestamp at or after `desired` in `target` — two entries in one
    /// file may not share a second, since the timestamp is the identity.
    pub fn free_stamp(&self, desired: &str, target: &Path, excluding: Option<&str>) -> Result<String, String> {
        let content = match read_day(target)? {
            Some(text) => text,
            None => return Ok(desired.to_string()),
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
        Ok(stamp)
    }

    /// The entry stamped `ts` in `source`, read from that file alone.
    pub fn find(&self, source: &Path, ts: &str) -> Result<Entry, String> {
        let content = read_day(source)?.ok_or_else(|| "entry not found".to_string())?;
        parse_entries(&content, source, &self.inbox())
            .into_iter()
            .find(|e| e.ts == ts)
            .ok_or_else(|| "entry not found".to_string())
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
    fs::rename(&tmp, target).inspect_err(|_| {
        let _ = fs::remove_file(&tmp);
    })
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A fresh, empty journal folder under the system temp directory.
    fn scratch() -> Library {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let base = std::env::temp_dir().join(format!(
            "wander-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = fs::remove_dir_all(&base);
        let library = Library::new(base);
        library.ensure();
        library
    }

    fn day(library: &Library, date: &str) -> PathBuf {
        library.day_file(date).unwrap()
    }

    #[test]
    fn a_file_that_is_not_utf8_is_refused_and_left_alone() {
        let library = scratch();
        let target = day(&library, "2026-09-08");
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        let bytes = b"[2026-09-08 09:00:00] caf\xe9\n\n[2026-09-08 10:00:00] two\nbody\n".to_vec();
        fs::write(&target, &bytes).unwrap();

        let entry = library.compose("2026-09-08 11:00:00", "three", "", false, &target);
        assert_eq!(library.persist(&entry).unwrap_err(), NOT_UTF8);
        assert_eq!(library.remove(&entry).unwrap_err(), NOT_UTF8);
        assert!(library.free_stamp("2026-09-08 11:00:00", &target, None).is_err());
        assert_eq!(fs::read(&target).unwrap(), bytes);
    }

    #[test]
    fn a_missing_file_is_created() {
        let library = scratch();
        let target = day(&library, "2026-09-08");
        let entry = library.compose("2026-09-08 09:00:00", "first", "hello", false, &target);
        library.persist(&entry).unwrap();
        assert_eq!(fs::read_to_string(&target).unwrap(), "[2026-09-08 09:00:00] first\nhello\n");
    }

    #[test]
    fn removing_from_a_missing_file_is_not_an_error() {
        let library = scratch();
        let entry = library.compose("2026-09-08 09:00:00", "x", "", false, &day(&library, "2026-09-08"));
        library.remove(&entry).unwrap();
    }

    #[test]
    fn crlf_is_written_back_as_lf() {
        let library = scratch();
        let target = day(&library, "2026-09-08");
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(&target, "preamble\r\n\r\n[2026-09-08 09:00:00] one\r\nline a\r\nline b\r\n").unwrap();

        let entry = library.compose("2026-09-08 10:00:00", "two", "body", false, &target);
        library.persist(&entry).unwrap();
        let written = fs::read_to_string(&target).unwrap();
        assert!(!written.contains('\r'), "{:?}", written);
        assert_eq!(
            written,
            "preamble\n\n[2026-09-08 09:00:00] one\nline a\nline b\n\n[2026-09-08 10:00:00] two\nbody\n"
        );
    }

    #[test]
    fn only_a_real_stamp_is_a_stamp() {
        for bad in ["", "2026", "2026-09-0é", "../.-..-..", "2026-9-8 09:00:00", "2026-09-08", "2026-09-08 25:00:00"] {
            assert_eq!(stamp_date(bad), None, "{:?}", bad);
        }
        assert_eq!(stamp_date("2026-09-08 09:30:00"), Some("2026-09-08"));
    }

    #[test]
    fn the_library_owns_only_its_own_files() {
        let library = scratch();
        assert!(library.owns(&library.inbox()));
        assert!(library.owns(&day(&library, "2026-09-08")));
        assert!(!library.owns(&library.journal_dir().join("../../etc/passwd.md")));
        assert!(!library.owns(&library.journal_dir().join("2026/notes.txt")));
        assert!(!library.owns(Path::new("/etc/passwd")));
        assert!(!library.owns(&library.base.join("other.md")));
    }

    fn entries_in(library: &Library, path: &Path) -> Vec<Entry> {
        let content = fs::read_to_string(path).unwrap_or_default();
        parse_entries(&content, path, &library.inbox())
    }

    #[test]
    fn a_move_across_files_leaves_exactly_one_copy() {
        let library = scratch();
        let inbox = library.inbox();
        let entry = library.compose("2026-09-08 09:00:00", "draft", "words", false, &inbox);
        library.persist(&entry).unwrap();
        let other = library.compose("2026-09-08 10:00:00", "stays", "", false, &inbox);
        library.persist(&other).unwrap();

        let target = day(&library, "2026-09-08");
        let moved = library.compose(&entry.ts, &entry.title, &entry.body, false, &target);
        library.persist(&moved).unwrap();
        library.remove(&entry).unwrap();

        assert_eq!(entries_in(&library, &target).len(), 1);
        let left: Vec<String> = entries_in(&library, &inbox).into_iter().map(|e| e.title).collect();
        assert_eq!(left, vec!["stays"]);
    }

    #[test]
    fn a_retime_within_one_file_leaves_exactly_one_copy() {
        let library = scratch();
        let target = day(&library, "2026-09-08");
        let entry = library.compose("2026-09-08 09:00:00", "one", "", false, &target);
        library.persist(&entry).unwrap();

        let free = library.free_stamp("2026-09-08 17:00:00", &target, Some(&entry.ts)).unwrap();
        let moved = library.compose(&free, "one", "", false, &target);
        library.rewrite(&target, Some(&entry.ts), Some(&moved)).unwrap();
        let found = entries_in(&library, &target);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].ts, "2026-09-08 17:00:00");

        // Retimed to the stamp it already has: still one.
        library.rewrite(&target, Some(&moved.ts), Some(&moved)).unwrap();
        assert_eq!(entries_in(&library, &target).len(), 1);
    }

    #[test]
    fn a_file_emptied_by_a_remove_is_deleted() {
        let library = scratch();
        let target = day(&library, "2026-09-08");
        let entry = library.compose("2026-09-08 09:00:00", "only", "", false, &target);
        library.persist(&entry).unwrap();
        library.remove(&entry).unwrap();
        assert!(!target.exists());
    }

    #[test]
    fn parse_then_render_is_idempotent() {
        let inbox = PathBuf::from("/x/inbox.md");
        let source = PathBuf::from("/x/journal/2026/09/08.md");
        for text in [
            "",
            "[2026-09-08 09:00:00]\n",
            "[2026-09-08 09:00:00] title *\nbody @tag\n\n[2026-09-08 10:00:00] two\n",
            "a preamble\n\n[2026-09-08 09:00:00] one\n\n\nspaced\n",
        ] {
            let once = render_entries(&leading_preamble(text), &parse_entries(text, &source, &inbox));
            let twice = render_entries(&leading_preamble(&once), &parse_entries(&once, &source, &inbox));
            assert_eq!(once, twice, "{:?}", text);
        }
    }
}
