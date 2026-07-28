//! The app's data layer. Owns the on-disk journal folder and every operation the
//! UI performs. Filing / sorting / atomic writes are ported from ~/Code/jnl/main.go
//! (via the Swift `JournalStore`), so the on-disk layout stays byte-compatible:
//!
//!     <base>/inbox.md                     — unsorted drafts
//!     <base>/journal/YYYY/MM/DD.md         — filed entries, one file per day
//!     <base>/<tag>.md                      — split-tag journals (JNL_SPLIT_TAGS)
//!     <base>/assets/<uuid>.<ext>           — media, Obsidian-style links

use crate::media;
use crate::parser::{self, Entry};
use chrono::{Datelike, Local, NaiveDate};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

// ---------------------------------------------------------------------------
// Preferences (backend-relevant settings persisted to ~/.config/Nook/settings.json)
// ---------------------------------------------------------------------------

fn config_dir() -> PathBuf {
    let dir = dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Nook");
    let _ = fs::create_dir_all(&dir);
    dir
}

fn prefs_path() -> PathBuf {
    config_dir().join("settings.json")
}

pub fn read_prefs() -> Value {
    fs::read_to_string(prefs_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!({}))
}

pub fn write_prefs(v: &Value) {
    if let Ok(s) = serde_json::to_string_pretty(v) {
        let _ = fs::write(prefs_path(), s);
    }
}

pub fn set_pref(key: &str, value: Value) {
    let mut p = read_prefs();
    if !p.is_object() {
        p = json!({});
    }
    p.as_object_mut().unwrap().insert(key.to_string(), value);
    write_prefs(&p);
}

fn pref_str(key: &str) -> Option<String> {
    read_prefs()
        .get(key)
        .and_then(|v| v.as_str().map(String::from))
        .filter(|s| !s.is_empty())
}

fn pref_bool(key: &str) -> bool {
    read_prefs().get(key).and_then(|v| v.as_bool()).unwrap_or(false)
}

/// Tags routed to their own `<base>/<tag>.md` file (jnl JNL_SPLIT_TAGS).
fn split_tags_pref() -> Vec<String> {
    let raw = pref_str("splitTags").unwrap_or_default();
    raw.split(|c| c == ' ' || c == ',')
        .filter(|s| !s.is_empty())
        .map(|s| {
            if s.starts_with('@') {
                s.to_string()
            } else {
                format!("@{}", s)
            }
        })
        .collect()
}

/// Stable per-device id, generated once and kept in prefs.
fn data_saver_device_id() -> String {
    if let Some(id) = pref_str("dataSaverDeviceID") {
        return id;
    }
    let id = uuid::Uuid::new_v4().to_string();
    set_pref("dataSaverDeviceID", json!(id));
    id
}

// ---------------------------------------------------------------------------
// Serializable payloads for the frontend
// ---------------------------------------------------------------------------

#[derive(Serialize)]
pub struct ArchiveDay {
    pub date: String,
    pub count: usize,
    pub preview: String,
    pub has_photo: bool,
    pub has_video: bool,
    pub has_audio: bool,
    pub has_starred: bool,
    pub year: String,
}

#[derive(Serialize)]
pub struct SplitJournal {
    pub name: String,
    pub count: usize,
}

#[derive(Serialize)]
pub struct TagCount {
    pub tag: String,
    pub count: usize,
}

#[derive(Serialize)]
pub struct Snapshot {
    pub base_path: String,
    pub storage_mode: String,
    pub inbox_drafts: Vec<Entry>,
    pub archive_days: Vec<ArchiveDay>,
    pub tag_counts: Vec<TagCount>,
    pub split_journals: Vec<SplitJournal>,
    pub data_saved: u64,
}

#[derive(Serialize)]
pub struct DatedEntry {
    pub date: String,
    pub entry: Entry,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Source {
    pub kind: String,        // "inbox" | "archive" | "journal"
    pub arg: Option<String>, // date for archive, name for journal
}

#[derive(Serialize)]
pub struct SourcedEntry {
    pub entry: Entry,
    pub source: Source,
}

#[derive(Serialize)]
pub struct AssetItem {
    pub rel: String,
    pub name: String,
    pub abs: String,
}

#[derive(Serialize, Default)]
pub struct CleanupResult {
    pub formatted: usize,
    pub reordered: usize,
    pub deduped: usize,
    pub extracted: usize,
}

#[derive(Serialize, Default)]
pub struct MergeResult {
    pub journals: usize,
    pub entries: usize,
}

#[derive(Serialize, Default)]
pub struct MediaCompressionResult {
    pub images: usize,
    pub videos: usize,
    pub audios: usize,
    pub bytes_saved: u64,
}

#[derive(Serialize, Default)]
pub struct Stats {
    pub days: usize,
    pub entries: usize,
    pub words: usize,
    pub current_streak: usize,
    pub best_streak: usize,
    pub longest_day: String,
    pub longest_day_words: usize,
    pub bytes: u64,
    pub inbox_bytes: u64,
    pub archive_bytes: u64,
    pub media_bytes: u64,
    pub inbox_drafts: usize,
    pub tags: usize,
    pub split_journals: usize,
}

#[derive(Serialize, Clone)]
pub struct TagGroupVariant {
    pub tag: String,
    pub count: usize,
}

#[derive(Serialize)]
pub struct TagGroup {
    pub id: String,
    pub variants: Vec<TagGroupVariant>,
    pub case_only: bool,
}

/// One device's compression record (per-device json in <base>/.nook/).
#[derive(Serialize, Deserialize, Default)]
struct DataSaverRecord {
    // On-disk key is camelCase `savedBytes` (written by the macOS/iOS app too),
    // so the tally round-trips across every device sharing the folder.
    #[serde(rename = "savedBytes", default)]
    saved_bytes: u64,
    #[serde(default)]
    assets: Vec<String>,
}

const RESERVED_FILES: [&str; 4] = ["inbox.md", "transfer.md", "export.md", "nook-export.md"];
const NON_JOURNAL_FILES: [&str; 3] = ["transfer.md", "export.md", "nook-export.md"];

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

pub struct Store {
    pub base: PathBuf,
    pub mode: String,
}

/// Resolve the journal base directory: a user-chosen custom folder if set and
/// present, else a local ~/Documents/Nook fallback (so it always works). The
/// chosen folder is used directly as the base — same as jnl's JNL_DIR.
pub fn resolve_store() -> Store {
    if let Some(p) = pref_str("customFolder") {
        let path = PathBuf::from(&p);
        if path.is_dir() {
            let _ = fs::create_dir_all(path.join("journal"));
            return Store {
                base: path,
                mode: "custom".into(),
            };
        }
    }
    let local = dirs::document_dir()
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")))
        .join("Nook");
    let _ = fs::create_dir_all(local.join("journal"));
    Store {
        base: local,
        mode: "local".into(),
    }
}

fn read_string(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

/// Atomic write via temp-file + rename. Empty content removes the file.
fn write_file(path: &Path, content: &str) -> std::io::Result<()> {
    if content.is_empty() {
        let _ = fs::remove_file(path);
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(format!(".nook-{}.tmp", uuid::Uuid::new_v4()));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(content.as_bytes())?;
        f.sync_all()?;
    }
    if path.exists() {
        let _ = fs::remove_file(path);
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

/// Find an entry in a list by timestamp, falling back to raw text.
fn find_entry(entries: &[Entry], ts: &str, raw: &str) -> Option<usize> {
    entries
        .iter()
        .position(|e| e.ts == ts)
        .or_else(|| entries.iter().position(|e| e.raw == raw))
}

impl Store {
    fn inbox_path(&self) -> PathBuf {
        self.base.join("inbox.md")
    }
    fn journal_dir(&self) -> PathBuf {
        self.base.join("journal")
    }
    fn assets_dir(&self) -> PathBuf {
        self.base.join("assets")
    }
    fn split_journal_path(&self, name: &str) -> PathBuf {
        self.base.join(format!("{}.md", name))
    }

    /// journal/YYYY/MM/DD.md for a "YYYY-MM-DD" date.
    fn journal_file(&self, date: &str) -> Option<PathBuf> {
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

    /// All journal day-file paths (recursive walk of journal/).
    fn all_journal_files(&self) -> Vec<PathBuf> {
        let dir = self.journal_dir();
        WalkDir::new(&dir)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().map(|x| x == "md").unwrap_or(false))
            .map(|e| e.path().to_path_buf())
            .collect()
    }

    /// journal/2026/05/10.md → "2026-05-10".
    fn file_to_date(path: &Path) -> String {
        let day = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
        let month = path
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|s| s.to_str())
            .unwrap_or("");
        let year = path
            .parent()
            .and_then(|p| p.parent())
            .and_then(|p| p.file_name())
            .and_then(|s| s.to_str())
            .unwrap_or("");
        format!("{}-{}-{}", year, month, day)
    }

    // ---- Loading / index ----

    pub fn snapshot(&self) -> Snapshot {
        let inbox_drafts = parser::parse_entries(&read_string(&self.inbox_path()));

        // Date journals.
        let mut files = self.all_journal_files();
        files.sort_by(|a, b| Self::file_to_date(b).cmp(&Self::file_to_date(a)));
        let mut days: Vec<ArchiveDay> = vec![];
        let mut tag_map: HashMap<String, usize> = HashMap::new();
        for u in &files {
            let content = read_string(u);
            let entries = parser::parse_entries(&content);
            if entries.is_empty() {
                continue;
            }
            let date = Self::file_to_date(u);
            let mut day = ArchiveDay {
                year: date[..4.min(date.len())].to_string(),
                date: date.clone(),
                count: entries.len(),
                preview: entries.first().map(|e| e.preview.clone()).unwrap_or_default(),
                has_photo: false,
                has_video: false,
                has_audio: false,
                has_starred: entries.iter().any(|e| e.is_starred),
            };
            for p in parser::media_paths(&content) {
                let ext = p.rsplit('.').next().unwrap_or("").to_lowercase();
                match ext.as_str() {
                    "mov" | "mp4" | "m4v" | "webm" | "mkv" => day.has_video = true,
                    "m4a" | "mp3" | "wav" | "aac" | "aiff" | "caf" | "ogg" | "opus" | "flac" => {
                        day.has_audio = true
                    }
                    "png" | "jpg" | "jpeg" | "gif" | "heic" | "heif" | "webp" | "tiff" | "tif"
                    | "bmp" => day.has_photo = true,
                    _ => {}
                }
            }
            days.push(day);
            for t in parser::split_tags(&content) {
                *tag_map.entry(t).or_insert(0) += 1;
            }
        }

        // Split-tag journals (top-level <base>/<name>.md).
        let mut splits: Vec<SplitJournal> = vec![];
        if let Ok(items) = fs::read_dir(&self.base) {
            for item in items.filter_map(|i| i.ok()) {
                let path = item.path();
                if path.extension().map(|x| x == "md").unwrap_or(false) {
                    let fname = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
                    if RESERVED_FILES.contains(&fname) {
                        continue;
                    }
                    let entries = parser::parse_entries(&read_string(&path));
                    if !entries.is_empty() {
                        splits.push(SplitJournal {
                            name: path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string(),
                            count: entries.len(),
                        });
                    }
                }
            }
        }
        splits.sort_by(|a, b| a.name.cmp(&b.name));

        // Merge inbox tags into counts.
        for e in &inbox_drafts {
            for t in &e.tags {
                *tag_map.entry(t.clone()).or_insert(0) += 1;
            }
        }
        let mut tag_counts: Vec<TagCount> = tag_map
            .into_iter()
            .map(|(tag, count)| TagCount { tag, count })
            .collect();
        tag_counts.sort_by(|a, b| b.count.cmp(&a.count).then(a.tag.cmp(&b.tag)));

        Snapshot {
            base_path: self.base.to_string_lossy().to_string(),
            storage_mode: self.mode.clone(),
            inbox_drafts,
            archive_days: days,
            tag_counts,
            split_journals: splits,
            data_saved: self.total_data_saved(),
        }
    }

    pub fn entries_for_day(&self, date: &str) -> Vec<Entry> {
        match self.journal_file(date) {
            Some(u) => parser::parse_entries(&read_string(&u)),
            None => vec![],
        }
    }

    pub fn all_entries_by_day(&self) -> Vec<serde_json::Value> {
        let mut files = self.all_journal_files();
        files.sort_by(|a, b| Self::file_to_date(b).cmp(&Self::file_to_date(a)));
        files
            .iter()
            .map(|u| (Self::file_to_date(u), parser::parse_entries(&read_string(u))))
            .filter(|(_, es)| !es.is_empty())
            .map(|(date, entries)| json!({ "date": date, "entries": entries }))
            .collect()
    }

    pub fn entries_tagged_with(&self, name: &str) -> Vec<DatedEntry> {
        let tag = if name.starts_with('@') {
            name.to_string()
        } else {
            format!("@{}", name)
        };
        let mut files = self.all_journal_files();
        files.sort_by(|a, b| Self::file_to_date(b).cmp(&Self::file_to_date(a)));
        let mut out = vec![];
        for u in &files {
            let date = Self::file_to_date(u);
            for e in parser::parse_entries(&read_string(u)) {
                if e.raw.contains(&tag) {
                    out.push(DatedEntry {
                        date: date.clone(),
                        entry: e,
                    });
                }
            }
        }
        out
    }

    pub fn entries_in_journal(&self, name: &str) -> Vec<Entry> {
        parser::parse_entries(&read_string(&self.split_journal_path(name)))
    }

    pub fn search(&self, query: &str) -> Vec<DatedEntry> {
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            return vec![];
        }
        let mut files = self.all_journal_files();
        files.sort_by(|a, b| Self::file_to_date(b).cmp(&Self::file_to_date(a)));
        let mut out = vec![];
        for u in &files {
            let date = Self::file_to_date(u);
            for e in parser::parse_entries(&read_string(u)) {
                if e.raw.to_lowercase().contains(&q) {
                    out.push(DatedEntry {
                        date: date.clone(),
                        entry: e,
                    });
                }
            }
        }
        out
    }

    pub fn random_entry(&self) -> Option<DatedEntry> {
        use rand::seq::SliceRandom;
        let mut all: Vec<DatedEntry> = vec![];
        for u in self.all_journal_files() {
            let date = Self::file_to_date(&u);
            for e in parser::parse_entries(&read_string(&u)) {
                all.push(DatedEntry {
                    date: date.clone(),
                    entry: e,
                });
            }
        }
        all.shuffle(&mut rand::thread_rng());
        all.into_iter().next()
    }

    pub fn starred_entries(&self) -> Vec<SourcedEntry> {
        let mut out = vec![];
        for day in self.all_entries_by_day() {
            let date = day["date"].as_str().unwrap_or("").to_string();
            let entries: Vec<Entry> = serde_json::from_value(day["entries"].clone()).unwrap_or_default();
            for e in entries {
                if e.is_starred {
                    out.push(SourcedEntry {
                        entry: e,
                        source: Source {
                            kind: "archive".into(),
                            arg: Some(date.clone()),
                        },
                    });
                }
            }
        }
        for d in parser::parse_entries(&read_string(&self.inbox_path())) {
            if d.is_starred {
                out.push(SourcedEntry {
                    entry: d,
                    source: Source {
                        kind: "inbox".into(),
                        arg: None,
                    },
                });
            }
        }
        // Split journals.
        let snap = self.snapshot();
        for j in &snap.split_journals {
            for e in self.entries_in_journal(&j.name) {
                if e.is_starred {
                    out.push(SourcedEntry {
                        entry: e,
                        source: Source {
                            kind: "journal".into(),
                            arg: Some(j.name.clone()),
                        },
                    });
                }
            }
        }
        out
    }

    // ---- Composer / drafts ----

    fn make_entry(timestamp: &str, title: &str, body: &str) -> Entry {
        let t = title.trim();
        let b = parser::trim_right_newlines(body);
        let raw = if !t.is_empty() && !b.is_empty() {
            format!("[{}] {}\n{}", timestamp, t, b)
        } else if !t.is_empty() {
            format!("[{}] {}", timestamp, t)
        } else {
            format!("[{}]\n{}", timestamp, b)
        };
        // Re-parse so all computed fields (starred, tags, etc.) are consistent.
        parser::parse_entries(&raw)
            .into_iter()
            .next()
            .unwrap_or_else(|| Entry {
                date: timestamp.chars().take(10).collect(),
                ts: timestamp.to_string(),
                suffix: t.to_string(),
                body: b.trim().to_string(),
                raw,
                header: String::new(),
                is_starred: false,
                display_title: String::new(),
                preview: String::new(),
                tags: vec![],
                word_count: 0,
                media_badges: vec![],
            })
    }

    pub fn upsert_draft(&self, previous: Option<&str>, timestamp: &str, title: &str, body: &str) {
        let inbox = self.inbox_path();
        let t = title.trim();
        let b = parser::trim_right_newlines(body);
        let b = b.trim();
        if t.is_empty() && b.is_empty() {
            if let Some(prev) = previous {
                self.remove_draft(prev);
            }
            return;
        }
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        if let Some(prev) = previous {
            if prev != timestamp {
                drafts.retain(|e| e.ts != prev);
            }
        }
        let entry = Self::make_entry(timestamp, title, body);
        if let Some(idx) = drafts.iter().position(|e| e.ts == timestamp) {
            drafts[idx] = entry;
        } else {
            drafts.push(entry);
        }
        let _ = write_file(&inbox, &parser::render_entries(&preamble, &drafts));
    }

    pub fn remove_draft(&self, timestamp: &str) {
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        let before = drafts.len();
        drafts.retain(|e| e.ts != timestamp);
        if drafts.len() == before {
            return;
        }
        let _ = write_file(&inbox, &parser::render_entries(&preamble, &drafts));
    }

    pub fn update_draft(&self, ts: &str, raw: &str, new_text: &str) {
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        let Some(idx) = find_entry(&drafts, ts, raw) else {
            return;
        };
        let parsed = parser::parse_entries(new_text);
        drafts.splice(idx..idx + 1, parsed);
        let _ = write_file(&inbox, &parser::render_entries(&preamble, &drafts));
    }

    pub fn delete_draft(&self, ts: &str, raw: &str) {
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        if let Some(idx) = find_entry(&drafts, ts, raw) {
            drafts.remove(idx);
        }
        let _ = write_file(&inbox, &parser::render_entries(&preamble, &drafts));
    }

    pub fn import_drafts(&self, text: &str) -> usize {
        let inbox = self.inbox_path();
        let imported = self.parse_import(text);
        if imported.is_empty() {
            return 0;
        }
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        let n = imported.len();
        drafts.extend(imported);
        let _ = write_file(&inbox, &parser::render_entries(&preamble, &drafts));
        n
    }

    fn parse_import(&self, text: &str) -> Vec<Entry> {
        let parsed = parser::parse_entries(text);
        if !parsed.is_empty() {
            return parsed;
        }
        let trimmed = text.trim();
        if trimmed.is_empty() {
            vec![]
        } else {
            vec![Self::make_entry(&now_ts(), "", trimmed)]
        }
    }

    pub fn sort_inbox(&self) {
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let entries = parser::parse_entries(&content);
        if entries.len() < 2 {
            return;
        }
        let sorted = parser::sorted_by_timestamp(&entries);
        let _ = write_file(&inbox, &parser::render_entries(&preamble, &sorted));
    }

    // ---- Filing (jnl fileDraft / splitTagTarget) ----

    fn split_tag_target(&self, raw: &str) -> Option<(String, PathBuf)> {
        let splits = split_tags_pref();
        if splits.is_empty() {
            return None;
        }
        let present: HashSet<String> = parser::split_tags(raw).into_iter().collect();
        for t in &splits {
            let tag = if t.starts_with('@') {
                t.clone()
            } else {
                format!("@{}", t)
            };
            if present.contains(&tag) {
                let name = &tag[1..];
                return Some((tag.clone(), self.split_journal_path(name)));
            }
        }
        None
    }

    /// Append one entry to its destination file. `route_split=false` forces the
    /// dated journal (used when merging ex-split journals back in).
    fn file_entry(&self, e: &Entry, route_split: bool) -> Result<String, String> {
        if e.body.is_empty() && e.suffix.is_empty() {
            return Err("nothing to file".into());
        }
        let (dest, label) = if route_split {
            if let Some((tag, url)) = self.split_tag_target(&e.raw) {
                (url, tag)
            } else {
                self.dated_dest(e)?
            }
        } else {
            self.dated_dest(e)?
        };

        let mut out = String::new();
        let existing = read_string(&dest);
        if !existing.trim().is_empty() {
            out = existing;
            if !out.ends_with("\n\n") {
                if out.ends_with('\n') {
                    out.push('\n');
                } else {
                    out.push_str("\n\n");
                }
            }
        }
        if !e.suffix.is_empty() && !e.body.is_empty() {
            out.push_str(&format!("[{}] {}\n{}\n", e.ts, e.suffix, e.body));
        } else if !e.suffix.is_empty() {
            out.push_str(&format!("[{}] {}\n", e.ts, e.suffix));
        } else {
            out.push_str(&format!("[{}]\n{}\n", e.ts, e.body));
        }
        write_file(&dest, &out).map_err(|err| err.to_string())?;
        Ok(label)
    }

    fn dated_dest(&self, e: &Entry) -> Result<(PathBuf, String), String> {
        let date = if e.date.is_empty() { now_date() } else { e.date.clone() };
        let url = self.journal_file(&date).ok_or("bad path")?;
        if let Some(dir) = url.parent() {
            let _ = fs::create_dir_all(dir);
        }
        Ok((url, date))
    }

    pub fn file_draft(&self, ts: &str, raw: &str) -> Option<String> {
        let drafts = parser::parse_entries(&read_string(&self.inbox_path()));
        let idx = find_entry(&drafts, ts, raw)?;
        let entry = drafts[idx].clone();
        let label = self.file_entry(&entry, true).ok()?;
        self.remove_from_inbox(&entry);
        Some(label)
    }

    fn remove_from_inbox(&self, entry: &Entry) {
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        if let Some(idx) = find_entry(&drafts, &entry.ts, &entry.raw) {
            drafts.remove(idx);
        }
        let _ = write_file(&inbox, &parser::render_entries(&preamble, &drafts));
    }

    pub fn file_all_drafts(&self) -> usize {
        let drafts = parser::parse_entries(&read_string(&self.inbox_path()));
        let mut filed = 0;
        for d in &drafts {
            if self.file_entry(d, true).is_ok() {
                filed += 1;
            }
        }
        let _ = write_file(&self.inbox_path(), "");
        filed
    }

    // ---- Filed-entry editing ----

    pub fn update_filed_entry(&self, date: &str, ts: &str, raw: &str, new_text: &str) {
        let Some(url) = self.journal_file(date) else {
            return;
        };
        let content = read_string(&url);
        let preamble = parser::leading_preamble(&content);
        let mut entries = parser::parse_entries(&content);
        let Some(idx) = find_entry(&entries, ts, raw) else {
            return;
        };
        entries.splice(idx..idx + 1, parser::parse_entries(new_text));
        let _ = write_file(&url, &parser::render_entries(&preamble, &entries));
    }

    pub fn delete_filed_entry(&self, date: &str, ts: &str, raw: &str) {
        let Some(url) = self.journal_file(date) else {
            return;
        };
        let content = read_string(&url);
        let preamble = parser::leading_preamble(&content);
        let mut entries = parser::parse_entries(&content);
        entries.retain(|e| e.ts != ts && e.raw != raw);
        let _ = write_file(&url, &parser::render_entries(&preamble, &entries));
    }

    pub fn update_journal_entry(&self, name: &str, ts: &str, raw: &str, new_text: &str) {
        let url = self.split_journal_path(name);
        let content = read_string(&url);
        let preamble = parser::leading_preamble(&content);
        let mut entries = parser::parse_entries(&content);
        let Some(idx) = find_entry(&entries, ts, raw) else {
            return;
        };
        entries.splice(idx..idx + 1, parser::parse_entries(new_text));
        let _ = write_file(&url, &parser::render_entries(&preamble, &entries));
    }

    pub fn delete_journal_entry(&self, name: &str, ts: &str, raw: &str) {
        let url = self.split_journal_path(name);
        let content = read_string(&url);
        let preamble = parser::leading_preamble(&content);
        let mut entries = parser::parse_entries(&content);
        entries.retain(|e| e.ts != ts && e.raw != raw);
        let _ = write_file(&url, &parser::render_entries(&preamble, &entries));
    }

    // ---- Starred ----

    pub fn toggle_star(&self, source: &Source, ts: &str, raw: &str) {
        let entries = self.entries_for_source(source);
        let Some(entry) = entries.into_iter().find(|e| e.ts == ts || e.raw == raw) else {
            return;
        };
        let base = if entry.suffix.ends_with('*') {
            let mut s = entry.suffix.clone();
            s.pop();
            s.trim().to_string()
        } else {
            entry.suffix.trim().to_string()
        };
        let new_title = if entry.is_starred {
            base
        } else if base.is_empty() {
            "*".to_string()
        } else {
            format!("{} *", base)
        };
        let new_text = Self::make_entry(&entry.ts, &new_title, &entry.body).raw;
        match source.kind.as_str() {
            "inbox" => self.update_draft(&entry.ts, &entry.raw, &new_text),
            "archive" => {
                if let Some(d) = &source.arg {
                    self.update_filed_entry(d, &entry.ts, &entry.raw, &new_text);
                }
            }
            "journal" => {
                if let Some(n) = &source.arg {
                    self.update_journal_entry(n, &entry.ts, &entry.raw, &new_text);
                }
            }
            _ => {}
        }
    }

    fn entries_for_source(&self, source: &Source) -> Vec<Entry> {
        match source.kind.as_str() {
            "inbox" => parser::parse_entries(&read_string(&self.inbox_path())),
            "archive" => source
                .arg
                .as_ref()
                .map(|d| self.entries_for_day(d))
                .unwrap_or_default(),
            "journal" => source
                .arg
                .as_ref()
                .map(|n| self.entries_in_journal(n))
                .unwrap_or_default(),
            _ => vec![],
        }
    }

    // ---- Tags: rename / merge / similar groups ----

    fn tag_rewrite_files(&self) -> Vec<PathBuf> {
        let mut files = vec![self.inbox_path()];
        files.extend(self.all_journal_files());
        for j in self.snapshot().split_journals {
            files.push(self.split_journal_path(&j.name));
        }
        files
    }

    pub fn rename_tag(&self, old: &str, new: &str) -> usize {
        let old_name = old.strip_prefix('@').unwrap_or(old);
        let new_tok = if new.starts_with('@') {
            new.to_string()
        } else {
            format!("@{}", new)
        };
        let re = match regex::Regex::new(&format!(
            r"@{}(?![A-Za-z0-9_-])",
            regex::escape(old_name)
        )) {
            Ok(r) => r,
            Err(_) => return 0,
        };
        let mut changed = 0;
        for url in self.tag_rewrite_files() {
            let s = read_string(&url);
            if s.is_empty() {
                continue;
            }
            let r = re.replace_all(&s, new_tok.as_str()).to_string();
            if r != s {
                let _ = write_file(&url, &r);
                changed += 1;
            }
        }
        changed
    }

    pub fn merge_tags(&self, merges: &[(String, String)]) {
        let rules: Vec<(regex::Regex, String)> = merges
            .iter()
            .filter_map(|(from, to)| {
                let old_name = from.strip_prefix('@').unwrap_or(from);
                let new_tok = if to.starts_with('@') {
                    to.clone()
                } else {
                    format!("@{}", to)
                };
                regex::Regex::new(&format!(r"@{}(?![A-Za-z0-9_-])", regex::escape(old_name)))
                    .ok()
                    .map(|re| (re, new_tok))
            })
            .collect();
        if rules.is_empty() {
            return;
        }
        for url in self.tag_rewrite_files() {
            let mut s = read_string(&url);
            if s.is_empty() {
                continue;
            }
            let orig = s.clone();
            for (re, tok) in &rules {
                s = re.replace_all(&s, tok.as_str()).to_string();
            }
            if s != orig {
                let _ = write_file(&url, &s);
            }
        }
    }

    pub fn similar_tag_groups(&self) -> Vec<TagGroup> {
        let counts: Vec<TagGroupVariant> = self
            .snapshot()
            .tag_counts
            .into_iter()
            .map(|c| TagGroupVariant {
                tag: c.tag,
                count: c.count,
            })
            .collect();
        let ignored: HashSet<String> = read_prefs()
            .get("ignoredTagGroups")
            .and_then(|v| v.as_array().cloned())
            .map(|a| a.into_iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();
        compute_tag_groups(&counts, &ignored)
    }

    pub fn ignore_tag_group(&self, id: &str) {
        let mut ignored: Vec<String> = read_prefs()
            .get("ignoredTagGroups")
            .and_then(|v| v.as_array().cloned())
            .map(|a| a.into_iter().filter_map(|x| x.as_str().map(String::from)).collect())
            .unwrap_or_default();
        if !ignored.iter().any(|x| x == id) {
            ignored.push(id.to_string());
        }
        set_pref("ignoredTagGroups", json!(ignored));
    }

    // ---- Assets ----

    pub fn asset_abs(&self, rel: &str) -> String {
        self.base.join(rel).to_string_lossy().to_string()
    }

    pub fn all_assets(&self) -> Vec<AssetItem> {
        let dir = self.assets_dir();
        let mut out: Vec<AssetItem> = match fs::read_dir(&dir) {
            Ok(items) => items
                .filter_map(|i| i.ok())
                .filter(|i| i.path().is_file())
                .map(|i| {
                    let name = i.file_name().to_string_lossy().to_string();
                    AssetItem {
                        rel: format!("assets/{}", name),
                        abs: i.path().to_string_lossy().to_string(),
                        name,
                    }
                })
                .collect(),
            Err(_) => vec![],
        };
        out.sort_by(|a, b| a.name.cmp(&b.name));
        out
    }

    pub fn delete_asset(&self, rel: &str) {
        let _ = fs::remove_file(self.base.join(rel));
    }

    pub fn assets_bytes(&self) -> u64 {
        let dir = self.assets_dir();
        WalkDir::new(&dir)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_file())
            .filter_map(|e| e.metadata().ok().map(|m| m.len()))
            .sum()
    }

    pub fn orphan_assets(&self) -> Vec<String> {
        let all = self.all_assets();
        if all.is_empty() {
            return vec![];
        }
        let mut corpus = read_string(&self.inbox_path());
        for u in self.all_journal_files() {
            corpus.push('\n');
            corpus.push_str(&read_string(&u));
        }
        for j in self.snapshot().split_journals {
            corpus.push('\n');
            corpus.push_str(&read_string(&self.split_journal_path(&j.name)));
        }
        all.into_iter()
            .filter(|a| !corpus.contains(&format!("assets/{}", a.name)))
            .map(|a| a.rel)
            .collect()
    }

    pub fn delete_orphan_assets(&self) -> usize {
        let orphans = self.orphan_assets();
        for rel in &orphans {
            self.delete_asset(rel);
        }
        orphans.len()
    }

    pub fn asset_usages(&self, file_name: &str) -> Vec<SourcedEntry> {
        let needle = format!("assets/{}", file_name);
        let mut out = vec![];
        for e in parser::parse_entries(&read_string(&self.inbox_path())) {
            if e.raw.contains(&needle) {
                out.push(SourcedEntry {
                    entry: e,
                    source: Source {
                        kind: "inbox".into(),
                        arg: None,
                    },
                });
            }
        }
        for u in self.all_journal_files() {
            let date = Self::file_to_date(&u);
            for e in parser::parse_entries(&read_string(&u)) {
                if e.raw.contains(&needle) {
                    out.push(SourcedEntry {
                        entry: e,
                        source: Source {
                            kind: "archive".into(),
                            arg: Some(date.clone()),
                        },
                    });
                }
            }
        }
        for j in self.snapshot().split_journals {
            for e in self.entries_in_journal(&j.name) {
                if e.raw.contains(&needle) {
                    out.push(SourcedEntry {
                        entry: e,
                        source: Source {
                            kind: "journal".into(),
                            arg: Some(j.name.clone()),
                        },
                    });
                }
            }
        }
        out
    }

    /// Save raw bytes into assets/ and return the relative markdown path. When
    /// Data Saver is on, raster images are downsampled/re-compressed first.
    pub fn save_asset(&self, data: &[u8], ext: &str) -> Option<String> {
        let dir = self.assets_dir();
        let _ = fs::create_dir_all(&dir);
        let id = uuid::Uuid::new_v4().to_string();
        let lower = ext.to_lowercase();
        let name = format!("{}.{}", id, lower);
        let mut out = data.to_vec();
        if pref_bool("dataSaver") && media::is_compressible_image(&lower) {
            if let Some(shrunk) = media::downsample(data, &lower) {
                if shrunk.len() < data.len() {
                    out = shrunk;
                }
            }
        }
        let dest = dir.join(&name);
        if fs::write(&dest, &out).is_err() {
            return None;
        }
        if out.len() < data.len() {
            self.record_compression(&id, (data.len() - out.len()) as u64);
        }
        let rel = format!("assets/{}", name);
        // Video/audio compress in the background.
        if !media::is_compressible_image(&lower) {
            self.schedule_compression(&rel);
        }
        Some(rel)
    }

    /// Copy an existing file into assets/ and return the relative path.
    pub fn import_asset(&self, src: &str) -> Option<String> {
        let src = PathBuf::from(src);
        let dir = self.assets_dir();
        let _ = fs::create_dir_all(&dir);
        let ext = src
            .extension()
            .and_then(|s| s.to_str())
            .map(|s| s.to_lowercase())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "bin".into());
        let name = format!("{}.{}", uuid::Uuid::new_v4(), ext);
        let dest = dir.join(&name);
        if fs::copy(&src, &dest).is_err() {
            return None;
        }
        let rel = format!("assets/{}", name);
        self.schedule_compression(&rel);
        Some(rel)
    }

    // ---- Data Saver (compression records, merged per-device) ----

    fn data_saver_dir(&self) -> PathBuf {
        self.base.join(".nook")
    }
    fn my_record_path(&self) -> PathBuf {
        self.data_saver_dir()
            .join(format!("datasaver-{}.json", data_saver_device_id()))
    }

    fn load_my_record(&self) -> DataSaverRecord {
        fs::read(self.my_record_path())
            .ok()
            .and_then(|d| serde_json::from_slice(&d).ok())
            .unwrap_or_default()
    }
    fn save_my_record(&self, rec: &DataSaverRecord) {
        let _ = fs::create_dir_all(self.data_saver_dir());
        if let Ok(d) = serde_json::to_vec(rec) {
            let _ = fs::write(self.my_record_path(), d);
        }
    }
    fn all_records(&self) -> Vec<DataSaverRecord> {
        match fs::read_dir(self.data_saver_dir()) {
            Ok(items) => items
                .filter_map(|i| i.ok())
                .filter(|i| {
                    let n = i.file_name().to_string_lossy().to_string();
                    n.starts_with("datasaver-") && n.ends_with(".json")
                })
                .filter_map(|i| fs::read(i.path()).ok())
                .filter_map(|d| serde_json::from_slice(&d).ok())
                .collect(),
            Err(_) => vec![],
        }
    }
    pub fn total_data_saved(&self) -> u64 {
        self.all_records().iter().map(|r| r.saved_bytes).sum()
    }
    fn all_compressed_ids(&self) -> HashSet<String> {
        self.all_records().into_iter().flat_map(|r| r.assets).collect()
    }
    fn record_compression(&self, asset_id: &str, saved: u64) {
        let mut rec = self.load_my_record();
        rec.saved_bytes += saved;
        if !rec.assets.iter().any(|a| a == asset_id) {
            rec.assets.push(asset_id.to_string());
        }
        self.save_my_record(&rec);
    }
    fn mark_handled(&self, asset_id: &str) {
        let mut rec = self.load_my_record();
        if !rec.assets.iter().any(|a| a == asset_id) {
            rec.assets.push(asset_id.to_string());
            self.save_my_record(&rec);
        }
    }

    /// Background video/audio transcode for a just-attached asset (Data Saver on).
    fn schedule_compression(&self, rel: &str) {
        if !pref_bool("dataSaver") {
            return;
        }
        let path = self.base.join(rel);
        let ext = path
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_lowercase();
        if !media::is_transcodable(&ext) {
            return;
        }
        let id = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        let base = self.base.clone();
        std::thread::spawn(move || {
            if let Some(saved) = media::compress_in_place(&path, &ext) {
                let store = Store {
                    base,
                    mode: String::new(),
                };
                if saved > 0 {
                    store.record_compression(&id, saved);
                } else {
                    store.mark_handled(&id);
                }
            }
        });
    }

    /// Compress existing media in place (skips anything already handled).
    /// `progress` is called with (done, total) as it goes.
    pub fn compress_existing_media<F: Fn(usize, usize)>(&self, progress: F) -> MediaCompressionResult {
        let dir = self.assets_dir();
        let items: Vec<PathBuf> = match fs::read_dir(&dir) {
            Ok(it) => it.filter_map(|i| i.ok()).map(|i| i.path()).collect(),
            Err(_) => return MediaCompressionResult::default(),
        };
        let already = self.all_compressed_ids();
        let candidates: Vec<PathBuf> = items
            .into_iter()
            .filter(|url| url.is_file())
            .filter(|url| {
                let ext = url.extension().and_then(|s| s.to_str()).unwrap_or("").to_lowercase();
                let known = media::is_compressible_image(&ext) || media::is_transcodable(&ext);
                let id = url.file_stem().and_then(|s| s.to_str()).unwrap_or("");
                known && !already.contains(id)
            })
            .collect();
        let mut res = MediaCompressionResult::default();
        let total = candidates.len();
        progress(0, total);
        for (i, url) in candidates.iter().enumerate() {
            let ext = url.extension().and_then(|s| s.to_str()).unwrap_or("").to_lowercase();
            let id = url.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
            if media::is_compressible_image(&ext) {
                if let Ok(data) = fs::read(url) {
                    if let Some(shrunk) = media::downsample(&data, &ext) {
                        if shrunk.len() < data.len() && fs::write(url, &shrunk).is_ok() {
                            res.images += 1;
                            res.bytes_saved += (data.len() - shrunk.len()) as u64;
                            self.record_compression(&id, (data.len() - shrunk.len()) as u64);
                            progress(i + 1, total);
                            continue;
                        }
                    }
                }
                self.mark_handled(&id);
            } else if let Some(saved) = media::compress_in_place(url, &ext) {
                if saved > 0 {
                    if media::is_video(&ext) {
                        res.videos += 1;
                    } else {
                        res.audios += 1;
                    }
                    res.bytes_saved += saved;
                    self.record_compression(&id, saved);
                } else {
                    self.mark_handled(&id);
                }
            } else {
                self.mark_handled(&id);
            }
            progress(i + 1, total);
        }
        res
    }

    // ---- Cleanup / merge / export ----

    fn dedupe(entries: Vec<Entry>) -> Vec<Entry> {
        let mut seen = HashSet::new();
        entries.into_iter().filter(|e| seen.insert(e.raw.clone())).collect()
    }

    pub fn cleanup(&self) -> CleanupResult {
        let mut res = CleanupResult::default();
        for url in self.all_journal_files() {
            let orig = read_string(&url);
            let fixed = orig
                .replace("...", "\u{2026}")
                .replace('\u{2019}', "'")
                .replace('\u{201C}', "\"")
                .replace('\u{201D}', "\"");
            if fixed != orig {
                res.formatted += 1;
            }
            let preamble = parser::leading_preamble(&fixed);
            let entries = parser::parse_entries(&fixed);
            let mut kept: Vec<Entry> = vec![];
            for e in entries {
                if self.split_tag_target(&e.raw).is_some() && self.file_entry(&e, true).is_ok() {
                    res.extracted += 1;
                } else {
                    kept.push(e);
                }
            }
            let sorted = parser::sorted_by_timestamp(&kept);
            if kept.iter().map(|e| &e.ts).collect::<Vec<_>>()
                != sorted.iter().map(|e| &e.ts).collect::<Vec<_>>()
            {
                res.reordered += 1;
            }
            let n_before = sorted.len();
            let deduped = Self::dedupe(sorted);
            res.deduped += n_before - deduped.len();
            let rebuilt = parser::render_entries(&preamble, &deduped);
            if rebuilt != orig {
                let _ = write_file(&url, &rebuilt);
            }
        }
        // Inbox.
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let entries = parser::parse_entries(&content);
        let sorted = parser::sorted_by_timestamp(&entries);
        if entries.iter().map(|e| &e.ts).collect::<Vec<_>>()
            != sorted.iter().map(|e| &e.ts).collect::<Vec<_>>()
        {
            res.reordered += 1;
        }
        let n_before = sorted.len();
        let deduped = Self::dedupe(sorted);
        res.deduped += n_before - deduped.len();
        let rebuilt = parser::render_entries(&preamble, &deduped);
        if rebuilt != content {
            let _ = write_file(&inbox, &rebuilt);
        }
        res
    }

    pub fn merge_ex_split_journals(&self) -> MergeResult {
        let mut res = MergeResult::default();
        let configured: HashSet<String> = split_tags_pref()
            .into_iter()
            .map(|t| t.strip_prefix('@').unwrap_or(&t).to_string())
            .collect();
        for sj in self.snapshot().split_journals {
            if configured.contains(&sj.name) {
                continue;
            }
            let url = self.split_journal_path(&sj.name);
            let content = read_string(&url);
            let entries = parser::parse_entries(&content);
            if entries.is_empty() {
                continue;
            }
            let mut remaining: Vec<Entry> = vec![];
            for e in entries {
                if self.file_entry(&e, false).is_ok() {
                    res.entries += 1;
                } else {
                    remaining.push(e);
                }
            }
            if remaining.is_empty() {
                let _ = fs::remove_file(&url);
                res.journals += 1;
            } else {
                let preamble = parser::leading_preamble(&content);
                let _ = write_file(&url, &parser::render_entries(&preamble, &remaining));
                if res.entries > 0 {
                    res.journals += 1;
                }
            }
        }
        res
    }

    pub fn export_markdown(&self) -> String {
        let mut files = self.all_journal_files();
        files.sort_by(|a, b| Self::file_to_date(a).cmp(&Self::file_to_date(b)));
        let parts: Vec<String> = files
            .iter()
            .map(|u| parser::trim_right_newlines(&read_string(u)))
            .filter(|s| !s.is_empty())
            .collect();
        if parts.is_empty() {
            String::new()
        } else {
            format!("{}\n", parts.join("\n\n"))
        }
    }

    // ---- Stats ----

    pub fn journal_bytes(&self) -> u64 {
        WalkDir::new(&self.base)
            .into_iter()
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.path().extension().map(|x| x == "md").unwrap_or(false)
                    && !NON_JOURNAL_FILES.contains(
                        &e.path().file_name().and_then(|s| s.to_str()).unwrap_or(""),
                    )
            })
            .filter_map(|e| e.metadata().ok().map(|m| m.len()))
            .sum()
    }

    pub fn stats(&self) -> Stats {
        let mut s = Stats::default();
        let mut dates: Vec<NaiveDate> = vec![];
        for url in self.all_journal_files() {
            let content = read_string(&url);
            let es = parser::parse_entries(&content);
            if es.is_empty() {
                continue;
            }
            let w = content
                .split(|c: char| c == ' ' || c == '\n' || c == '\t')
                .filter(|x| !x.is_empty())
                .count();
            s.days += 1;
            s.entries += es.len();
            s.words += w;
            if w > s.longest_day_words {
                s.longest_day_words = w;
                s.longest_day = Self::file_to_date(&url);
            }
            if let Ok(d) = NaiveDate::parse_from_str(&Self::file_to_date(&url), "%Y-%m-%d") {
                dates.push(d);
            }
        }
        dates.sort();
        dates.dedup();
        // Best streak.
        let mut run = 0;
        for i in 0..dates.len() {
            if i > 0 && dates[i - 1].succ_opt() == Some(dates[i]) {
                run += 1;
            } else {
                run = 1;
            }
            s.best_streak = s.best_streak.max(run);
        }
        // Current streak (back from today).
        let today = Local::now().date_naive();
        let mut cur = 0;
        for i in (0..dates.len()).rev() {
            let expected = today - chrono::Duration::days(cur as i64);
            if dates[i] == expected {
                cur += 1;
            } else if dates[i] < expected {
                break;
            }
        }
        s.current_streak = cur;
        s.bytes = self.journal_bytes();
        s.inbox_bytes = fs::metadata(self.inbox_path()).map(|m| m.len()).unwrap_or(0);
        s.archive_bytes = s.bytes.saturating_sub(s.inbox_bytes);
        s.media_bytes = self.assets_bytes();
        let snap = self.snapshot();
        s.inbox_drafts = snap.inbox_drafts.len();
        s.tags = snap.tag_counts.len();
        s.split_journals = snap.split_journals.len();
        s
    }

    // ---- Backup ----

    pub fn backup_now(&self) -> (bool, String) {
        let Some(backup_base) = pref_str("backupFolder").map(PathBuf::from) else {
            return (false, "Choose a backup folder first.".into());
        };
        if !backup_base.is_dir() {
            return (false, "Backup folder is not available.".into());
        }
        let name = format!("Nook-Backup-{}", Local::now().format("%Y-%m-%d-%H-%M-%S"));
        let dest = backup_base.join(&name);
        match copy_dir(&self.base, &dest) {
            Ok(_) => (true, format!("Backed up to {}.", name)),
            Err(e) => (false, format!("Backup failed: {}", e)),
        }
    }
}

// ---------------------------------------------------------------------------
// Tag-group clustering (case-only + one-edit lookalikes)
// ---------------------------------------------------------------------------

fn compute_tag_groups(counts: &[TagGroupVariant], ignored: &HashSet<String>) -> Vec<TagGroup> {
    let mut order: Vec<String> = vec![];
    let mut buckets: HashMap<String, Vec<TagGroupVariant>> = HashMap::new();
    for item in counts {
        let key: String = item.tag.chars().skip(1).collect::<String>().to_lowercase();
        if !buckets.contains_key(&key) {
            order.push(key.clone());
        }
        buckets.entry(key).or_default().push(item.clone());
    }
    let group_id = |variants: &[TagGroupVariant]| -> String {
        let mut tags: Vec<String> = variants.iter().map(|v| v.tag.clone()).collect();
        tags.sort();
        tags.join("|")
    };
    let mut groups: Vec<TagGroup> = vec![];
    // Tier 1: case-only variants.
    for key in &order {
        if buckets.get(key).map(|b| b.len()).unwrap_or(0) > 1 {
            let mut variants = buckets[key].clone();
            variants.sort_by(|a, b| b.count.cmp(&a.count));
            let id = group_id(&variants);
            if !ignored.contains(&id) {
                groups.push(TagGroup {
                    id,
                    variants,
                    case_only: true,
                });
            }
        }
    }
    // Tier 2: one-edit lookalikes.
    let mut used: HashSet<String> = HashSet::new();
    for i in 0..order.len() {
        if used.contains(&order[i]) {
            continue;
        }
        let mut cluster = vec![order[i].clone()];
        for j in (i + 1)..order.len() {
            if used.contains(&order[j]) {
                continue;
            }
            if order[i].chars().count().min(order[j].chars().count()) >= 4
                && levenshtein(&order[i], &order[j]) == 1
            {
                cluster.push(order[j].clone());
            }
        }
        if cluster.len() < 2 {
            continue;
        }
        for c in &cluster {
            used.insert(c.clone());
        }
        let mut variants: Vec<TagGroupVariant> =
            cluster.iter().flat_map(|k| buckets[k].clone()).collect();
        variants.sort_by(|a, b| b.count.cmp(&a.count));
        let id = group_id(&variants);
        if !ignored.contains(&id) {
            groups.push(TagGroup {
                id,
                variants,
                case_only: false,
            });
        }
    }
    groups
}

fn levenshtein(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    if a.is_empty() {
        return b.len();
    }
    let mut d: Vec<usize> = (0..=b.len()).collect();
    for i in 1..=a.len() {
        let mut prev = d[0];
        d[0] = i;
        for j in 1..=b.len() {
            let temp = d[j];
            d[j] = if a[i - 1] == b[j - 1] {
                prev
            } else {
                prev.min(d[j]).min(d[j - 1]) + 1
            };
            prev = temp;
        }
    }
    d[b.len()]
}

fn copy_dir(src: &Path, dest: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dest)?;
    for entry in WalkDir::new(src).into_iter().filter_map(|e| e.ok()) {
        let rel = entry.path().strip_prefix(src).unwrap();
        let target = dest.join(rel);
        if entry.file_type().is_dir() {
            fs::create_dir_all(&target)?;
        } else if entry.file_type().is_file() {
            if let Some(p) = target.parent() {
                fs::create_dir_all(p)?;
            }
            fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Time helpers (local time, jnl formats)
// ---------------------------------------------------------------------------

pub fn now_ts() -> String {
    Local::now().format("%Y-%m-%d %H:%M:%S").to_string()
}
pub fn now_date() -> String {
    Local::now().format("%Y-%m-%d").to_string()
}

// Silence unused-import warning for Datelike in some build configs.
#[allow(dead_code)]
fn _use_datelike(d: NaiveDate) -> i32 {
    d.year()
}
