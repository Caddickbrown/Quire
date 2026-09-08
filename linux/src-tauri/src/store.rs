//! The app's data layer. Owns the on-disk journal folder and every operation the
//! UI performs. Filing / sorting / atomic writes are ported from ~/Code/jnl/main.go
//! (via the Swift `JournalStore`), so the on-disk layout stays byte-compatible:
//!
//! ```text
//! <base>/inbox.md                     — unsorted drafts
//! <base>/journal/YYYY/MM/DD.md         — filed entries, one file per day
//! <base>/<tag>.md                      — split-tag journals (JNL_SPLIT_TAGS)
//! <base>/assets/<uuid>.<ext>           — media, Obsidian-style links
//! ```

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

/// One writer at a time. `set_pref` is a read-modify-write and is called from
/// background threads (the Data Saver's compression bookkeeping), so two
/// overlapping calls used to drop one another's key.
static PREFS_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// settings.json, parsed once and kept until the next write. `resolve_store()`
/// opens nearly every command and used to read and parse the file each time —
/// with sixty-odd call sites, the single biggest per-call cost in this layer.
/// A pref edited on disk by hand while Nook runs isn't seen until the next
/// write or relaunch, which is how the Apple app's UserDefaults behave too.
static PREFS: std::sync::RwLock<Option<Value>> = std::sync::RwLock::new(None);

pub fn read_prefs() -> Value {
    if let Some(v) = PREFS.read().unwrap_or_else(|e| e.into_inner()).as_ref() {
        return v.clone();
    }
    let v = fs::read_to_string(prefs_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| json!({}));
    *PREFS.write().unwrap_or_else(|e| e.into_inner()) = Some(v.clone());
    v
}

/// Temp file + rename, so a crash (or a full disk) mid-write can't leave a
/// truncated settings.json that reads back as "no preferences at all" — which
/// would silently forget the custom journal folder.
pub fn write_prefs(v: &Value) {
    let Ok(s) = serde_json::to_string_pretty(v) else { return };
    let path = prefs_path();
    let tmp = path.with_file_name(format!(".settings-{}.tmp", uuid::Uuid::new_v4()));
    let wrote = fs::File::create(&tmp).and_then(|mut f| {
        f.write_all(s.as_bytes())?;
        f.sync_all()
    });
    let mut cache = PREFS.write().unwrap_or_else(|e| e.into_inner());
    if wrote.is_err() || fs::rename(&tmp, &path).is_err() {
        let _ = fs::remove_file(&tmp);
        // Unsure what's on disk now: drop the cache so the next read looks.
        *cache = None;
        return;
    }
    *cache = Some(v.clone());
}

pub fn set_pref(key: &str, value: Value) {
    let _guard = PREFS_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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
    /// Words dated today (filed + drafts) — drives the word goal.
    pub words_today: usize,
    pub has_entry_today: bool,
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
///
/// A custom folder that is *set but gone* (an unmounted drive, a renamed or
/// not-yet-synced folder) resolves to mode `"missing"`: the app reports it and
/// blocks writes, rather than quietly recreating the folder — or writing into
/// ~/Documents/Nook — and stranding today's entries somewhere the real journal
/// will never see them.
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
        return Store {
            base: path,
            mode: "missing".into(),
        };
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
    // rename(2) replaces the destination atomically on POSIX — no pre-remove,
    // which would open a window where a crash leaves only the temp file.
    fs::rename(&tmp, path)?;
    Ok(())
}

/// Remove leftover `.nook-*.tmp` files from writes that never completed.
/// Age-guarded (an hour) so an in-flight write from another process — the
/// macOS app or `jnl` sharing the folder — is never swept out from under it.
/// Mirrors `JournalStore.sweepStaleTempFiles`.
pub fn sweep_stale_temp_files(base: &Path) {
    let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
    for e in WalkDir::new(base).into_iter().filter_map(|e| e.ok()) {
        let path = e.path();
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !name.starts_with(".nook-") || !name.ends_with(".tmp") {
            continue;
        }
        let modified = e.metadata().ok().and_then(|m| m.modified().ok());
        if modified.map(|m| m < cutoff).unwrap_or(false) {
            let _ = fs::remove_file(path);
        }
    }
}

/// A name the frontend supplied (a template, a split journal, a backup, an
/// asset) has to stay one path component inside the folder we mean to touch —
/// `../../.ssh/id_rsa` is not a template name.
fn safe_component(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.contains('/')
        && !name.contains('\\')
        && !name.contains('\0')
}

/// The first four characters of an ISO date. Byte-slicing `date[..4]` panicked
/// on a non-ASCII directory name reached through `file_to_date`.
fn year_of(date: &str) -> String {
    date.chars().take(4).collect()
}

/// What the UI shows when an entry has no usable header timestamp.
const BAD_TIMESTAMP: &str = "Needs a full date and time (YYYY-MM-DD HH:MM:SS).";

/// True when `ts` composes a header the jnl parser accepts. Checked through the
/// parser itself so the two can't drift.
fn valid_timestamp(ts: &str) -> bool {
    parser::parse_entries(&format!("[{}] x", ts)).len() == 1
}

/// The entries a replacement body parses to. Text that parses to *nothing*
/// would splice nothing in — silently deleting the entry it was meant to
/// replace (a cleared date field composes `[]`, which is not an entry) — so
/// that is an error rather than a delete.
fn replacement_entries(new_text: &str) -> Result<Vec<Entry>, String> {
    let parsed = parser::parse_entries(new_text);
    if parsed.is_empty() && !new_text.trim().is_empty() {
        return Err(BAD_TIMESTAMP.into());
    }
    Ok(parsed)
}

/// The jnl timestamp one second after `ts` (the input itself on parse failure —
/// callers bound their retry loops, so this can never spin).
fn timestamp_after(ts: &str) -> String {
    match chrono::NaiveDateTime::parse_from_str(ts, "%Y-%m-%d %H:%M:%S") {
        Ok(t) => (t + chrono::Duration::seconds(1))
            .format("%Y-%m-%d %H:%M:%S")
            .to_string(),
        Err(_) => ts.to_string(),
    }
}

/// Find an entry by raw text first, timestamp second — raw is the sharper
/// identity when two entries share a second, so an edit or delete can't land
/// on the wrong twin.
fn find_entry(entries: &[Entry], ts: &str, raw: &str) -> Option<usize> {
    entries
        .iter()
        .position(|e| e.raw == raw)
        .or_else(|| entries.iter().position(|e| e.ts == ts))
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

    /// `journal_file`, for callers outside this module (the reveal command).
    pub fn journal_file_for(&self, date: &str) -> Option<PathBuf> {
        if date.split('-').any(|p| !p.chars().all(|c| c.is_ascii_digit())) {
            return None;
        }
        self.journal_file(date)
    }

    /// `checked_split_path`, for callers outside this module.
    pub fn split_file_for(&self, name: &str) -> Option<PathBuf> {
        self.checked_split_path(name)
    }

    /// A split journal named by the frontend. `None` for anything that isn't a
    /// plain name — the path is joined onto the base folder, so `../inbox` must
    /// not get through.
    fn checked_split_path(&self, name: &str) -> Option<PathBuf> {
        if !safe_component(name) || RESERVED_FILES.contains(&format!("{}.md", name).as_str()) {
            return None;
        }
        Some(self.split_journal_path(name))
    }

    /// Refuse every write while the chosen journal folder is unavailable. It is
    /// checked here rather than at each command because `write_file` creates
    /// missing parents — an unmounted drive would otherwise be *recreated* as an
    /// empty folder, hiding the real journal when it came back.
    fn writable(&self) -> Result<(), String> {
        if self.mode == "missing" {
            return Err(format!(
                "The journal folder {} isn't available. Reconnect it, or choose another in Settings.",
                self.base.display()
            ));
        }
        Ok(())
    }

    /// `write_file` with the failure kept. Every journal write goes through here
    /// so a full disk or a read-only folder reaches the UI as an error toast
    /// instead of being dropped while the app claims it saved.
    fn write_journal(&self, path: &Path, content: &str) -> Result<(), String> {
        self.writable()?;
        write_file(path, content).map_err(|e| format!("Couldn't write {}: {}", path.display(), e))
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
                year: year_of(&date),
                date: date.clone(),
                count: entries.len(),
                preview: entries.first().map(|e| e.preview.clone()).unwrap_or_default(),
                has_photo: false,
                has_video: false,
                has_audio: false,
                has_starred: entries.iter().any(|e| e.is_starred),
            };
            for p in parser::media_paths(&content) {
                match parser::media_kind(&p) {
                    parser::MediaKind::Video => day.has_video = true,
                    parser::MediaKind::Audio => day.has_audio = true,
                    parser::MediaKind::Image => day.has_photo = true,
                    parser::MediaKind::Other => {}
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
        match self.checked_split_path(name) {
            Some(u) => parser::parse_entries(&read_string(&u)),
            None => vec![],
        }
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

    /// Returns the timestamp actually used: a brand-new draft landing on a
    /// second that is already taken is nudged forward until free, so the
    /// composer can never overwrite an unrelated same-second draft.
    pub fn upsert_draft(
        &self,
        previous: Option<&str>,
        timestamp: &str,
        title: &str,
        body: &str,
    ) -> Result<Option<String>, String> {
        let inbox = self.inbox_path();
        let t = title.trim();
        let b = parser::trim_right_newlines(body);
        let b = b.trim();
        if t.is_empty() && b.is_empty() {
            if let Some(prev) = previous {
                self.remove_draft(prev)?;
            }
            return Ok(None);
        }
        // A cleared or half-typed date composes `[] title`, which parses to no
        // entry at all — written to the inbox it is absorbed into the draft
        // above it on the next parse.
        if !valid_timestamp(timestamp) {
            return Err(BAD_TIMESTAMP.into());
        }
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        let mut ts = timestamp.to_string();
        if previous == Some(timestamp) {
            if let Some(idx) = drafts.iter().position(|e| e.ts == timestamp) {
                drafts[idx] = Self::make_entry(&ts, title, body);
                self.write_journal(&inbox, &parser::render_entries(&preamble, &drafts))?;
                return Ok(Some(ts));
            }
        }
        if let Some(prev) = previous {
            if let Some(idx) = drafts.iter().position(|e| e.ts == prev) {
                drafts.remove(idx);
            }
        }
        let mut attempts = 0;
        while attempts < 3600 && drafts.iter().any(|e| e.ts == ts) {
            ts = timestamp_after(&ts);
            attempts += 1;
        }
        drafts.push(Self::make_entry(&ts, title, body));
        self.write_journal(&inbox, &parser::render_entries(&preamble, &drafts))?;
        Ok(Some(ts))
    }

    pub fn remove_draft(&self, timestamp: &str) -> Result<(), String> {
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        // One draft only — with two entries sharing a second, retain() by
        // timestamp deleted both.
        let Some(idx) = drafts.iter().position(|e| e.ts == timestamp) else {
            return Ok(());
        };
        drafts.remove(idx);
        self.write_journal(&inbox, &parser::render_entries(&preamble, &drafts))
    }

    pub fn update_draft(&self, ts: &str, raw: &str, new_text: &str) -> Result<(), String> {
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        let Some(idx) = find_entry(&drafts, ts, raw) else {
            return Ok(());
        };
        drafts.splice(idx..idx + 1, replacement_entries(new_text)?);
        self.write_journal(&inbox, &parser::render_entries(&preamble, &drafts))
    }

    pub fn delete_draft(&self, ts: &str, raw: &str) -> Result<(), String> {
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        if let Some(idx) = find_entry(&drafts, ts, raw) {
            drafts.remove(idx);
        }
        self.write_journal(&inbox, &parser::render_entries(&preamble, &drafts))
    }

    pub fn import_drafts(&self, text: &str) -> Result<usize, String> {
        let inbox = self.inbox_path();
        let imported = self.parse_import(text);
        if imported.is_empty() {
            return Ok(0);
        }
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        let n = imported.len();
        drafts.extend(imported);
        self.write_journal(&inbox, &parser::render_entries(&preamble, &drafts))?;
        Ok(n)
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

    pub fn sort_inbox(&self) -> Result<(), String> {
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let entries = parser::parse_entries(&content);
        if entries.len() < 2 {
            return Ok(());
        }
        let sorted = parser::sorted_by_timestamp(&entries);
        self.write_journal(&inbox, &parser::render_entries(&preamble, &sorted))
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
        self.write_journal(&dest, &out)?;
        Ok(label)
    }

    /// Append several entries to one file in a single read + write.
    fn append_entries(&self, entries: &[&Entry], dest: &Path) -> bool {
        if entries.is_empty() || self.writable().is_err() {
            return false;
        }
        if let Some(dir) = dest.parent() {
            let _ = fs::create_dir_all(dir);
        }
        let mut out = String::new();
        let existing = read_string(dest);
        if !existing.trim().is_empty() {
            out = format!("{}\n", parser::trim_right_newlines(&existing));
        }
        for e in entries {
            if !out.is_empty() {
                out.push('\n');
            }
            if !e.suffix.is_empty() && !e.body.is_empty() {
                out.push_str(&format!("[{}] {}\n{}\n", e.ts, e.suffix, e.body));
            } else if !e.suffix.is_empty() {
                out.push_str(&format!("[{}] {}\n", e.ts, e.suffix));
            } else {
                out.push_str(&format!("[{}]\n{}\n", e.ts, e.body));
            }
        }
        write_file(dest, &out).is_ok()
    }

    fn dated_dest(&self, e: &Entry) -> Result<(PathBuf, String), String> {
        let date = if e.date.is_empty() { now_date() } else { e.date.clone() };
        let url = self.journal_file(&date).ok_or("bad path")?;
        if let Some(dir) = url.parent() {
            let _ = fs::create_dir_all(dir);
        }
        Ok((url, date))
    }

    pub fn file_draft(&self, ts: &str, raw: &str) -> Result<Option<String>, String> {
        let drafts = parser::parse_entries(&read_string(&self.inbox_path()));
        let Some(idx) = find_entry(&drafts, ts, raw) else {
            return Ok(None);
        };
        let entry = drafts[idx].clone();
        let label = self.file_entry(&entry, true)?;
        self.remove_from_inbox(&entry)?;
        Ok(Some(label))
    }

    fn remove_from_inbox(&self, entry: &Entry) -> Result<(), String> {
        let inbox = self.inbox_path();
        let content = read_string(&inbox);
        let preamble = parser::leading_preamble(&content);
        let mut drafts = parser::parse_entries(&content);
        if let Some(idx) = find_entry(&drafts, &entry.ts, &entry.raw) {
            drafts.remove(idx);
        }
        self.write_journal(&inbox, &parser::render_entries(&preamble, &drafts))
    }

    /// Only drafts that actually filed are removed: one whose write failed
    /// stays in the inbox instead of being lost with it.
    pub fn file_all_drafts(&self) -> Result<usize, String> {
        let content = read_string(&self.inbox_path());
        let preamble = parser::leading_preamble(&content);
        let drafts = parser::parse_entries(&content);
        let mut filed_raws: HashMap<String, usize> = HashMap::new();
        let mut filed = 0;
        let mut failed = 0;
        // Group by destination first, so ten drafts from one day rewrite that
        // day's file once, not ten times (mirrors JournalStore.fileAllDrafts).
        let mut order: Vec<PathBuf> = vec![];
        let mut by_dest: HashMap<PathBuf, Vec<&Entry>> = HashMap::new();
        for d in &drafts {
            if d.body.is_empty() && d.suffix.is_empty() {
                continue;
            }
            let dest = match self.split_tag_target(&d.raw) {
                Some((_, url)) => url,
                None => match self.dated_dest(d) {
                    Ok((url, _)) => url,
                    Err(_) => continue,
                },
            };
            if !by_dest.contains_key(&dest) {
                order.push(dest.clone());
            }
            by_dest.entry(dest).or_default().push(d);
        }
        for dest in order {
            let group = by_dest.get(&dest).cloned().unwrap_or_default();
            if !self.append_entries(&group, &dest) {
                failed += group.len();
                continue;
            }
            filed += group.len();
            for d in group {
                *filed_raws.entry(d.raw.clone()).or_insert(0) += 1;
            }
        }
        if filed > 0 {
            let mut remaining: Vec<Entry> = vec![];
            for e in drafts {
                match filed_raws.get_mut(&e.raw) {
                    Some(n) if *n > 0 => *n -= 1, // counted, so a duplicate only vanishes once
                    _ => remaining.push(e),
                }
            }
            self.write_journal(&self.inbox_path(), &parser::render_entries(&preamble, &remaining))?;
        }
        if failed > 0 {
            return Err(format!(
                "Filed {} of {} drafts — the rest could not be written.",
                filed,
                filed + failed
            ));
        }
        Ok(filed)
    }

    // ---- Filed-entry editing ----

    pub fn update_filed_entry(
        &self,
        date: &str,
        ts: &str,
        raw: &str,
        new_text: &str,
    ) -> Result<(), String> {
        let Some(url) = self.journal_file(date) else {
            return Err("Bad journal path.".into());
        };
        let content = read_string(&url);
        let preamble = parser::leading_preamble(&content);
        let mut entries = parser::parse_entries(&content);
        let Some(idx) = find_entry(&entries, ts, raw) else {
            return Ok(());
        };
        entries.splice(idx..idx + 1, replacement_entries(new_text)?);
        self.write_journal(&url, &parser::render_entries(&preamble, &entries))
    }

    pub fn delete_filed_entry(&self, date: &str, ts: &str, raw: &str) -> Result<(), String> {
        let Some(url) = self.journal_file(date) else {
            return Err("Bad journal path.".into());
        };
        let content = read_string(&url);
        let preamble = parser::leading_preamble(&content);
        let mut entries = parser::parse_entries(&content);
        // Single, raw-first removal — retain() deleted both twins of a
        // same-second pair.
        let Some(idx) = find_entry(&entries, ts, raw) else {
            return Ok(());
        };
        entries.remove(idx);
        self.write_journal(&url, &parser::render_entries(&preamble, &entries))
    }

    pub fn update_journal_entry(
        &self,
        name: &str,
        ts: &str,
        raw: &str,
        new_text: &str,
    ) -> Result<(), String> {
        let Some(url) = self.checked_split_path(name) else {
            return Err("Bad journal name.".into());
        };
        let content = read_string(&url);
        let preamble = parser::leading_preamble(&content);
        let mut entries = parser::parse_entries(&content);
        let Some(idx) = find_entry(&entries, ts, raw) else {
            return Ok(());
        };
        entries.splice(idx..idx + 1, replacement_entries(new_text)?);
        self.write_journal(&url, &parser::render_entries(&preamble, &entries))
    }

    pub fn delete_journal_entry(&self, name: &str, ts: &str, raw: &str) -> Result<(), String> {
        let Some(url) = self.checked_split_path(name) else {
            return Err("Bad journal name.".into());
        };
        let content = read_string(&url);
        let preamble = parser::leading_preamble(&content);
        let mut entries = parser::parse_entries(&content);
        // Single, raw-first removal — retain() deleted both twins of a
        // same-second pair.
        let Some(idx) = find_entry(&entries, ts, raw) else {
            return Ok(());
        };
        entries.remove(idx);
        self.write_journal(&url, &parser::render_entries(&preamble, &entries))
    }

    // ---- Starred ----

    pub fn toggle_star(&self, source: &Source, ts: &str, raw: &str) -> Result<(), String> {
        let entries = self.entries_for_source(source);
        // raw-first, like every other lookup: matching the timestamp first
        // starred the wrong twin of a same-second pair.
        let Some(idx) = find_entry(&entries, ts, raw) else {
            return Ok(());
        };
        let entry = entries[idx].clone();
        // `display_title` already strips the marker (and only a real marker).
        let base = entry.display_title.trim().to_string();
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
            "archive" => match &source.arg {
                Some(d) => self.update_filed_entry(d, &entry.ts, &entry.raw, &new_text),
                None => Ok(()),
            },
            "journal" => match &source.arg {
                Some(n) => self.update_journal_entry(n, &entry.ts, &entry.raw, &new_text),
                None => Ok(()),
            },
            _ => Ok(()),
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

    pub fn rename_tag(&self, old: &str, new: &str) -> Result<usize, String> {
        let old_name = old.strip_prefix('@').unwrap_or(old);
        let new_tok = if new.starts_with('@') {
            new.to_string()
        } else {
            format!("@{}", new)
        };
        // The regex crate has no lookahead — `(?!…)` failed to compile and the
        // whole rename silently did nothing. Capture the boundary (or end)
        // instead and put it back in the replacement.
        let re = match regex::Regex::new(&format!(
            r"@{}($|[^A-Za-z0-9_-])",
            regex::escape(old_name)
        )) {
            Ok(r) => r,
            Err(_) => return Ok(0),
        };
        let replacement = format!("{}$1", new_tok);
        let mut changed = 0;
        for url in self.tag_rewrite_files() {
            let s = read_string(&url);
            if s.is_empty() {
                continue;
            }
            let r = re.replace_all(&s, replacement.as_str()).to_string();
            if r != s {
                self.write_journal(&url, &r)?;
                changed += 1;
            }
        }
        Ok(changed)
    }

    pub fn merge_tags(&self, merges: &[(String, String)]) -> Result<(), String> {
        let rules: Vec<(regex::Regex, String)> = merges
            .iter()
            .filter_map(|(from, to)| {
                let old_name = from.strip_prefix('@').unwrap_or(from);
                let new_tok = if to.starts_with('@') {
                    to.clone()
                } else {
                    format!("@{}", to)
                };
                // Same boundary-capture trick as rename_tag — lookahead is
                // unsupported, and the old pattern never compiled.
                regex::Regex::new(&format!(r"@{}($|[^A-Za-z0-9_-])", regex::escape(old_name)))
                    .ok()
                    .map(|re| (re, format!("{}$1", new_tok)))
            })
            .collect();
        if rules.is_empty() {
            return Ok(());
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
                self.write_journal(&url, &s)?;
            }
        }
        Ok(())
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

    /// Delete one file out of `assets/`. The path comes from the frontend, so
    /// it has to be exactly `assets/<one component>` — `assets/../inbox.md`
    /// would otherwise resolve to the journal itself.
    pub fn delete_asset(&self, rel: &str) {
        let Some(name) = rel.strip_prefix("assets/") else { return };
        if !safe_component(name) || self.writable().is_err() {
            return;
        }
        let _ = fs::remove_file(self.assets_dir().join(name));
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
        self.writable().ok()?;
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
        self.writable().ok()?;
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
                        // Temp file + rename: a half-written re-encode would
                        // otherwise destroy the only copy of the photo.
                        if shrunk.len() < data.len() && media::write_atomic(url, &shrunk).is_ok() {
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

    pub fn cleanup(&self) -> Result<CleanupResult, String> {
        let mut res = CleanupResult::default();
        for url in self.all_journal_files() {
            let orig = read_string(&url);
            let fixed = parser::normalize_punctuation(&orig);
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
                self.write_journal(&url, &rebuilt)?;
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
            self.write_journal(&inbox, &rebuilt)?;
        }
        Ok(res)
    }

    pub fn merge_ex_split_journals(&self) -> Result<MergeResult, String> {
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
                self.write_journal(&url, &parser::render_entries(&preamble, &remaining))?;
                if res.entries > 0 {
                    res.journals += 1;
                }
            }
        }
        Ok(res)
    }

    /// Dated days oldest first, then the split journals — they're filed
    /// entries too, and leaving them out made "Export" quietly incomplete.
    pub fn export_markdown(&self) -> String {
        let mut files = self.all_journal_files();
        files.sort_by(|a, b| Self::file_to_date(a).cmp(&Self::file_to_date(b)));
        let mut parts: Vec<String> = files
            .iter()
            .map(|u| parser::trim_right_newlines(&read_string(u)))
            .filter(|s| !s.is_empty())
            .collect();
        let mut split_names: Vec<String> = self.snapshot().split_journals.iter().map(|j| j.name.clone()).collect();
        split_names.sort();
        for name in split_names {
            let text = parser::trim_right_newlines(&read_string(&self.split_journal_path(&name)));
            if !text.is_empty() {
                parts.push(text);
            }
        }
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
        // Current streak — counted back from today, or from yesterday when
        // today is still unwritten, so a live streak doesn't read as 0 all
        // morning just because today's entry isn't in yet.
        let today = Local::now().date_naive();
        let anchor = match dates.last() {
            Some(&last) if last != today => today.pred_opt().unwrap_or(today),
            _ => today,
        };
        let mut cur = 0;
        for i in (0..dates.len()).rev() {
            let expected = anchor - chrono::Duration::days(cur as i64);
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
        // Today's words: today's day file plus drafts dated today.
        let today_iso = now_date();
        for e in self.entries_for_day(&today_iso) {
            s.has_entry_today = true;
            s.words_today += e.word_count;
        }
        for e in &snap.inbox_drafts {
            if e.date == today_iso {
                s.words_today += e.word_count;
            }
        }
        s
    }

    // ---- Backup ----

    /// A backup folder inside the journal (or the reverse) turns backup into
    /// recursion and restore into deleting its own source — refuse both.
    fn nesting_problem(&self, backup_base: &Path) -> Option<String> {
        let b = format!("{}/", self.base.to_string_lossy());
        let k = format!("{}/", backup_base.to_string_lossy());
        if k.starts_with(&b) {
            return Some("The backup folder is inside the journal folder — choose one outside it.".into());
        }
        if b.starts_with(&k) {
            return Some("The journal folder is inside the backup folder — choose a separate backup location.".into());
        }
        None
    }

    pub fn backup_now(&self) -> (bool, String) {
        if let Err(e) = self.writable() {
            return (false, e);
        }
        let Some(backup_base) = pref_str("backupFolder").map(PathBuf::from) else {
            return (false, "Choose a backup folder first.".into());
        };
        if !backup_base.is_dir() {
            return (false, "Backup folder is not available.".into());
        }
        if let Some(clash) = self.nesting_problem(&backup_base) {
            return (false, clash);
        }
        let name = format!("Nook-Backup-{}", Local::now().format("%Y-%m-%d-%H-%M-%S"));
        let dest = backup_base.join(&name);
        match copy_dir(&self.base, &dest) {
            Ok(_) => (true, format!("Backed up to {}.", name)),
            Err(e) => (false, format!("Backup failed: {}", e)),
        }
    }

    /// Timestamped copies in the backup folder, newest first.
    pub fn list_backups(&self) -> Vec<String> {
        let Some(backup_base) = pref_str("backupFolder").map(PathBuf::from) else {
            return vec![];
        };
        let mut names: Vec<String> = fs::read_dir(&backup_base)
            .map(|items| {
                items
                    .filter_map(|i| i.ok())
                    .map(|i| i.file_name().to_string_lossy().to_string())
                    .filter(|n| n.starts_with("Nook-Backup-"))
                    .collect()
            })
            .unwrap_or_default();
        names.sort_by(|a, b| b.cmp(a));
        names
    }

    /// Replace the journal with a backup copy. A safety copy of the current
    /// folder is taken first, so a restore is itself restorable.
    pub fn restore_backup(&self, name: &str) -> (bool, String) {
        if let Err(e) = self.writable() {
            return (false, e);
        }
        let Some(backup_base) = pref_str("backupFolder").map(PathBuf::from) else {
            return (false, "Choose a backup folder first.".into());
        };
        if let Some(clash) = self.nesting_problem(&backup_base) {
            return (false, clash);
        }
        if !safe_component(name) {
            return (false, "That isn't a backup name — nothing was changed.".into());
        }
        let source = backup_base.join(name);
        if !source.join("inbox.md").exists() && !source.join("journal").exists() {
            return (false, "That folder doesn't look like a Nook backup — nothing was changed.".into());
        }
        let (ok, msg) = self.backup_now();
        if !ok {
            return (false, format!("Couldn't take a safety copy first — nothing was changed. {}", msg));
        }
        // Empty the base, then copy the backup's contents in.
        if let Ok(items) = fs::read_dir(&self.base) {
            for item in items.filter_map(|i| i.ok()) {
                let p = item.path();
                let _ = if p.is_dir() { fs::remove_dir_all(&p) } else { fs::remove_file(&p) };
            }
        }
        match copy_dir(&source, &self.base) {
            Ok(_) => (true, format!("Restored {}. The pre-restore journal was saved as a new backup.", name)),
            Err(e) => (false, format!("Restore failed partway: {}. A safety copy of the pre-restore journal is in the backup folder.", e)),
        }
    }

    // ---- Global search (SearchQuery grammar over the whole corpus) ----

    pub fn global_search(&self, query: &str) -> Vec<SourcedEntry> {
        let q = crate::search::Query::parse(query);
        if q.is_empty() {
            return vec![];
        }
        let mut out = vec![];
        for e in parser::parse_entries(&read_string(&self.inbox_path())) {
            if q.matches(&e) {
                out.push(SourcedEntry { entry: e, source: Source { kind: "inbox".into(), arg: None } });
            }
        }
        for u in self.all_journal_files() {
            let date = Self::file_to_date(&u);
            for e in parser::parse_entries(&read_string(&u)) {
                if q.matches(&e) {
                    out.push(SourcedEntry {
                        entry: e,
                        source: Source { kind: "archive".into(), arg: Some(date.clone()) },
                    });
                }
            }
        }
        for j in self.snapshot().split_journals {
            for e in self.entries_in_journal(&j.name) {
                if q.matches(&e) {
                    out.push(SourcedEntry {
                        entry: e,
                        source: Source { kind: "journal".into(), arg: Some(j.name.clone()) },
                    });
                }
            }
        }
        out.sort_by(|a, b| b.entry.ts.cmp(&a.entry.ts));
        out
    }

    // ---- Saved searches (<base>/.nook/searches.json, shared with the apps) ----

    fn saved_searches_path(&self) -> PathBuf {
        self.base.join(".nook").join("searches.json")
    }

    pub fn saved_searches(&self) -> Value {
        fs::read_to_string(self.saved_searches_path())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(|| json!([]))
    }

    pub fn add_saved_search(&self, name: &str, query: &str) {
        if self.writable().is_err() {
            return;
        }
        let mut list: Vec<Value> = self
            .saved_searches()
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|v| v.get("name").and_then(|n| n.as_str()) != Some(name))
            .collect();
        list.push(json!({ "name": name, "query": query }));
        let _ = fs::create_dir_all(self.base.join(".nook"));
        if let Ok(s) = serde_json::to_string_pretty(&list) {
            let _ = fs::write(self.saved_searches_path(), s);
        }
    }

    pub fn remove_saved_search(&self, name: &str) {
        let list: Vec<Value> = self
            .saved_searches()
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter(|v| v.get("name").and_then(|n| n.as_str()) != Some(name))
            .collect();
        if list.is_empty() {
            let _ = fs::remove_file(self.saved_searches_path());
        } else if let Ok(s) = serde_json::to_string_pretty(&list) {
            let _ = fs::write(self.saved_searches_path(), s);
        }
    }

    // ---- Templates (<base>/.nook/templates/*.md, shared with the apps) ----

    fn templates_dir(&self) -> PathBuf {
        self.base.join(".nook").join("templates")
    }

    pub fn template_names(&self) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(self.templates_dir())
            .map(|items| {
                items
                    .filter_map(|i| i.ok())
                    .map(|i| i.path())
                    .filter(|p| p.extension().map(|x| x == "md").unwrap_or(false))
                    .filter_map(|p| p.file_stem().and_then(|s| s.to_str()).map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        names.sort();
        names
    }

    /// A template's content with {{date}}, {{time}} and {{weekday}} filled in.
    pub fn template_body(&self, name: &str) -> Option<String> {
        if !safe_component(name) {
            return None;
        }
        let raw = fs::read_to_string(self.templates_dir().join(format!("{}.md", name))).ok()?;
        let now = Local::now();
        Some(
            raw.replace("{{date}}", &now.format("%Y-%m-%d").to_string())
                .replace("{{time}}", &now.format("%H:%M").to_string())
                .replace("{{weekday}}", &now.format("%A").to_string()),
        )
    }

    pub fn create_template(&self) -> Option<String> {
        self.writable().ok()?;
        let dir = self.templates_dir();
        let _ = fs::create_dir_all(&dir);
        let mut name = "New Template".to_string();
        let mut n = 2;
        while dir.join(format!("{}.md", name)).exists() {
            name = format!("New Template {}", n);
            n += 1;
        }
        let starter = "What made today worth writing about?\n\n- One thing to remember\n- One thing to let go\n\n{{weekday}} {{date}}\n";
        fs::write(dir.join(format!("{}.md", name)), starter).ok()?;
        Some(name)
    }

    pub fn delete_template(&self, name: &str) {
        if !safe_component(name) {
            return;
        }
        let _ = fs::remove_file(self.templates_dir().join(format!("{}.md", name)));
    }

    // ---- On This Day ----

    /// Filed entries from this calendar day in previous years, newest year first.
    pub fn on_this_day(&self) -> Vec<Value> {
        let today = now_date();
        let month_day = &today[4..]; // "-MM-DD"
        let this_year = &today[..4];
        let mut dates: Vec<String> = self
            .all_journal_files()
            .iter()
            .map(|u| Self::file_to_date(u))
            .filter(|d| d.len() == 10 && d.ends_with(month_day) && year_of(d).as_str() < this_year)
            .collect();
        dates.sort_by(|a, b| b.cmp(a));
        dates.dedup();
        dates
            .into_iter()
            .map(|d| {
                let entries = self.entries_for_day(&d);
                json!({ "date": d, "entries": entries })
            })
            .filter(|v| !v["entries"].as_array().map(|a| a.is_empty()).unwrap_or(true))
            .collect()
    }

    // ---- Year in Review ----

    pub fn year_review(&self, year: &str) -> Value {
        let mut entries_n = 0usize;
        let mut words = 0usize;
        let mut days_written = 0usize;
        let mut busiest = (String::new(), 0usize);
        let mut starred = 0usize;
        let mut first_line = String::new();
        let mut tag_map: HashMap<String, usize> = HashMap::new();
        let mut photos = 0usize;
        let mut videos = 0usize;
        let mut audios = 0usize;
        let mut dates: Vec<NaiveDate> = vec![];

        let mut files: Vec<PathBuf> = self
            .all_journal_files()
            .into_iter()
            .filter(|u| Self::file_to_date(u).starts_with(year))
            .collect();
        files.sort_by(|a, b| Self::file_to_date(a).cmp(&Self::file_to_date(b)));

        for u in &files {
            let content = read_string(u);
            let es = parser::parse_entries(&content);
            if es.is_empty() {
                continue;
            }
            let date = Self::file_to_date(u);
            let day_words: usize = es.iter().map(|e| e.word_count).sum();
            days_written += 1;
            entries_n += es.len();
            words += day_words;
            if day_words > busiest.1 {
                busiest = (date.clone(), day_words);
            }
            if first_line.is_empty() {
                if let Some(e) = es.first() {
                    first_line = e.preview.clone();
                }
            }
            starred += es.iter().filter(|e| e.is_starred).count();
            for t in parser::split_tags(&content) {
                *tag_map.entry(t).or_insert(0) += 1;
            }
            for p in parser::media_paths(&content) {
                match parser::media_kind(&p) {
                    parser::MediaKind::Video => videos += 1,
                    parser::MediaKind::Audio => audios += 1,
                    _ => photos += 1,
                }
            }
            if let Ok(d) = NaiveDate::parse_from_str(&date, "%Y-%m-%d") {
                dates.push(d);
            }
        }
        let mut longest_streak = 0usize;
        let mut run = 0usize;
        for i in 0..dates.len() {
            if i > 0 && dates[i - 1].succ_opt() == Some(dates[i]) {
                run += 1;
            } else {
                run = 1;
            }
            longest_streak = longest_streak.max(run);
        }
        let mut top_tags: Vec<(String, usize)> = tag_map.into_iter().collect();
        top_tags.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        top_tags.truncate(5);

        json!({
            "year": year,
            "entries": entries_n,
            "words": words,
            "days_written": days_written,
            "longest_streak": longest_streak,
            "busiest_day": busiest.0,
            "busiest_day_words": busiest.1,
            "starred": starred,
            "first_line": first_line,
            "top_tags": top_tags.iter().map(|(t, c)| json!({ "tag": t, "count": c })).collect::<Vec<_>>(),
            "photos": photos, "videos": videos, "audios": audios,
        })
    }

    pub fn years_with_entries(&self) -> Vec<String> {
        let mut years: Vec<String> = self
            .all_journal_files()
            .iter()
            .map(|u| year_of(&Self::file_to_date(u)))
            .collect();
        years.sort_by(|a, b| b.cmp(a));
        years.dedup();
        years
    }

    // ---- Importers (Day One JSON, dated markdown folders) ----

    /// Append filed entries to their day files (no split routing), skipping any
    /// whose exact text is already there. Returns how many were written.
    fn append_filed_entries(&self, entries: Vec<Entry>) -> (usize, usize) {
        let mut added = 0usize;
        let mut skipped = 0usize;
        for e in parser::sorted_by_timestamp(&entries) {
            let Some(url) = self.journal_file(&e.date) else {
                skipped += 1;
                continue;
            };
            if read_string(&url).contains(&e.raw) {
                skipped += 1;
                continue;
            }
            if self.file_entry(&e, false).is_ok() {
                added += 1;
            } else {
                skipped += 1;
            }
        }
        (added, skipped)
    }

    /// Import a Day One JSON export (the Journal.json or its unzipped folder).
    /// `commit=false` only counts. Returns {entries, media, skipped, first, last}.
    pub fn import_day_one(&self, path: &str, commit: bool) -> Value {
        let p = PathBuf::from(path);
        let (json_path, folder) = if p.is_dir() {
            let jsons: Vec<PathBuf> = fs::read_dir(&p)
                .map(|it| {
                    it.filter_map(|i| i.ok())
                        .map(|i| i.path())
                        .filter(|x| x.extension().map(|e| e == "json").unwrap_or(false))
                        .collect()
                })
                .unwrap_or_default();
            let pick = jsons
                .iter()
                .find(|x| x.file_name().map(|n| n == "Journal.json").unwrap_or(false))
                .or_else(|| {
                    jsons.iter().find(|x| {
                        x.file_name()
                            .and_then(|n| n.to_str())
                            .map(|n| n.to_lowercase() != "metadata.json")
                            .unwrap_or(false)
                    })
                })
                .or(jsons.first());
            match pick {
                Some(j) => (j.clone(), p.clone()),
                None => return json!({ "ok": false, "message": "No Journal.json found in that folder." }),
            }
        } else {
            (p.clone(), p.parent().map(PathBuf::from).unwrap_or_default())
        };

        #[derive(Deserialize)]
        struct DOMedia {
            identifier: Option<String>,
            md5: Option<String>,
            #[serde(rename = "type")]
            kind: Option<String>,
        }
        #[derive(Deserialize)]
        struct DOEntry {
            #[serde(rename = "creationDate")]
            creation_date: Option<String>,
            /// The zone the entry was *written* in (an IANA identifier). Day One
            /// stamps creationDate in UTC, so without this a 23:30 entry written
            /// in Sydney imports onto the wrong day.
            #[serde(rename = "timeZone")]
            time_zone: Option<String>,
            text: Option<String>,
            tags: Option<Vec<String>>,
            starred: Option<bool>,
            photos: Option<Vec<DOMedia>>,
            videos: Option<Vec<DOMedia>>,
            audios: Option<Vec<DOMedia>>,
        }
        #[derive(Deserialize)]
        struct DOJson {
            entries: Option<Vec<DOEntry>>,
        }

        let Ok(data) = fs::read_to_string(&json_path) else {
            return json!({ "ok": false, "message": "Couldn't read that file." });
        };
        let Ok(decoded) = serde_json::from_str::<DOJson>(&data) else {
            return json!({ "ok": false, "message": "That doesn't look like a Day One JSON export." });
        };
        let mut prepared: Vec<Entry> = vec![];
        let mut media_count = 0usize;
        let mut media_copied = 0usize;
        for e in decoded.entries.unwrap_or_default() {
            let Some(created) = e.creation_date else { continue };
            let Ok(dt) = chrono::DateTime::parse_from_rfc3339(&created) else { continue };
            // Same rule as the Swift importer: render in the entry's own zone
            // when it names one, else this machine's.
            let zone = e.time_zone.as_deref().and_then(|z| z.parse::<chrono_tz::Tz>().ok());
            let ts = match zone {
                Some(tz) => dt.with_timezone(&tz).format("%Y-%m-%d %H:%M:%S").to_string(),
                None => dt.with_timezone(&Local).format("%Y-%m-%d %H:%M:%S").to_string(),
            };
            let mut body = e.text.unwrap_or_default().trim().to_string();
            for ch in ["!", ".", "(", ")", "[", "]", "#", "-", "*", "_"] {
                body = body.replace(&format!("\\{}", ch), ch);
            }
            let mut entry_media = 0usize;
            for (dir_name, list, fallback_ext) in [
                ("photos", &e.photos, "jpeg"),
                ("videos", &e.videos, "mov"),
                ("audios", &e.audios, "m4a"),
            ] {
                for m in list.as_deref().unwrap_or_default() {
                    let (Some(id), Some(md5)) = (&m.identifier, &m.md5) else { continue };
                    let ext = m.kind.clone().unwrap_or_else(|| fallback_ext.to_string());
                    let file = folder.join(dir_name).join(format!("{}.{}", md5, ext));
                    if !file.exists() {
                        continue;
                    }
                    media_count += 1;
                    entry_media += 1;
                    if commit {
                        if let Some(rel) = self.import_asset(&file.to_string_lossy()) {
                            media_copied += 1;
                            let link = format!("![]({})", rel);
                            let moment = format!("![](dayone-moment://{})", id);
                            if body.contains(&moment) {
                                body = body.replace(&moment, &link);
                            } else {
                                if !body.is_empty() {
                                    body.push_str("\n\n");
                                }
                                body.push_str(&link);
                            }
                        }
                    }
                }
            }
            if let Some(tags) = &e.tags {
                let cleaned: Vec<String> = tags
                    .iter()
                    .filter_map(|t| sanitize_tag(t))
                    .map(|t| format!("@{}", t))
                    .collect();
                if !cleaned.is_empty() {
                    if !body.is_empty() {
                        body.push_str("\n\n");
                    }
                    body.push_str(&cleaned.join(" "));
                }
            }
            // A photo with no caption is still an entry. Dropping it here made
            // the preview under-count exactly the entries the import would go
            // on to write (on a commit run the media link fills the body in).
            if body.is_empty() && entry_media == 0 {
                continue;
            }
            let title = if e.starred.unwrap_or(false) { "*" } else { "" };
            prepared.push(Self::make_entry(&ts, title, &body));
        }
        if prepared.is_empty() {
            return json!({ "ok": false, "message": "No entries were found in that export." });
        }
        let first = prepared.iter().map(|e| e.date.clone()).min();
        let last = prepared.iter().map(|e| e.date.clone()).max();
        if !commit {
            return json!({ "ok": true, "entries": prepared.len(), "media": media_count,
                           "first": first, "last": last });
        }
        let (added, skipped) = self.append_filed_entries(prepared);
        json!({ "ok": true, "entries": added, "skipped": skipped, "media": media_copied })
    }

    /// Import a folder of dated markdown/text files (Obsidian daily notes work).
    pub fn import_md_folder(&self, path: &str, commit: bool) -> Value {
        let date_re = regex::Regex::new(r"(\d{4}-\d{2}-\d{2})").unwrap();
        let mut prepared: Vec<Entry> = vec![];
        let mut per_date: HashMap<String, usize> = HashMap::new();
        for entry in WalkDir::new(path).into_iter().filter_map(|e| e.ok()) {
            let p = entry.path();
            let ext = p.extension().and_then(|s| s.to_str()).unwrap_or("").to_lowercase();
            if ext != "md" && ext != "txt" {
                continue;
            }
            let content = read_string(p);
            if content.trim().is_empty() {
                continue;
            }
            // Files already in the jnl shape import entry-by-entry, verbatim.
            let parsed = parser::parse_entries(&content);
            if !parsed.is_empty() {
                prepared.extend(parsed);
                continue;
            }
            let name = p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
            let date = date_re
                .captures(&name)
                .and_then(|c| c.get(1))
                .map(|m| m.as_str().to_string())
                .filter(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").is_ok())
                // No date in the filename? Fall back to the file's own date,
                // like the Swift importer's `.creationDateKey` — skipping these
                // silently dropped whole folders of undated notes.
                .or_else(|| file_date(p));
            let Some(date) = date else { continue };
            // Fan out +1s from noon per same-date file, so order stays stable.
            let offset = *per_date.entry(date.clone()).or_insert(0);
            per_date.insert(date.clone(), offset + 1);
            let ts = format!("{} 12:{:02}:{:02}", date, offset / 60, offset % 60);
            let title = if name == date { "" } else { &name };
            prepared.push(Self::make_entry(&ts, title, content.trim()));
        }
        if prepared.is_empty() {
            return json!({ "ok": false, "message": "No dated markdown/text files were found there." });
        }
        let first = prepared.iter().map(|e| e.date.clone()).min();
        let last = prepared.iter().map(|e| e.date.clone()).max();
        if !commit {
            return json!({ "ok": true, "entries": prepared.len(), "media": 0,
                           "first": first, "last": last });
        }
        let (added, skipped) = self.append_filed_entries(prepared);
        json!({ "ok": true, "entries": added, "skipped": skipped, "media": 0 })
    }
}

/// The date a file was created, or failing that last modified — Linux
/// filesystems don't always carry a birth time.
fn file_date(path: &Path) -> Option<String> {
    let md = fs::metadata(path).ok()?;
    let t = md.created().or_else(|_| md.modified()).ok()?;
    Some(
        chrono::DateTime::<Local>::from(t)
            .format("%Y-%m-%d")
            .to_string(),
    )
}

/// "Deep Thoughts" → "deep-thoughts"; a tag must start with a letter.
fn sanitize_tag(raw: &str) -> Option<String> {
    let lowered: String = raw
        .to_lowercase()
        .replace(' ', "-")
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    if lowered.chars().next().map(|c| c.is_alphabetic()).unwrap_or(false) {
        Some(lowered)
    } else {
        None
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A throwaway journal folder — these tests exercise the file ops, so they
    /// need a real base directory (never the user's).
    fn temp_store() -> Store {
        let base = std::env::temp_dir().join(format!("nook-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(base.join("journal")).unwrap();
        Store { base, mode: "local".into() }
    }

    #[test]
    fn timestamps_are_validated_through_the_parser() {
        assert!(valid_timestamp("2026-05-10 08:00:00"));
        assert!(!valid_timestamp(""));
        assert!(!valid_timestamp("2026-05-10"));
        assert!(!valid_timestamp("2026-05-10 08:00"));
    }

    #[test]
    fn a_headerless_replacement_is_an_error_not_a_delete() {
        assert!(replacement_entries("[] still typing\nbody").is_err());
        assert!(replacement_entries("").is_ok()); // blank is a deliberate clear
        assert_eq!(
            replacement_entries("[2026-05-10 08:00:00] ok\nbody").unwrap().len(),
            1
        );
    }

    #[test]
    fn clearing_the_date_leaves_the_draft_alone() {
        let s = temp_store();
        let before = "[2026-05-10 08:00:00] one\nfirst\n\n[2026-05-11 09:00:00] two\nsecond\n";
        fs::write(s.inbox_path(), before).unwrap();
        let drafts = parser::parse_entries(before);
        let err = s
            .update_draft(&drafts[1].ts, &drafts[1].raw, "[] two\nsecond")
            .unwrap_err();
        assert_eq!(err, BAD_TIMESTAMP);
        assert_eq!(read_string(&s.inbox_path()), before);
        // …and the composer refuses the same input.
        assert!(s.upsert_draft(None, "", "two", "second").is_err());
        assert_eq!(read_string(&s.inbox_path()), before);
        fs::remove_dir_all(&s.base).ok();
    }

    #[test]
    fn toggle_star_finds_the_same_second_twin_by_raw() {
        let s = temp_store();
        let day = s.journal_file("2026-05-10").unwrap();
        fs::create_dir_all(day.parent().unwrap()).unwrap();
        fs::write(
            &day,
            "[2026-05-10 08:00:00] one\nfirst\n\n[2026-05-10 08:00:00] two\nsecond\n",
        )
        .unwrap();
        let entries = s.entries_for_day("2026-05-10");
        let target = entries[1].clone();
        let source = Source { kind: "archive".into(), arg: Some("2026-05-10".into()) };
        s.toggle_star(&source, &target.ts, &target.raw).unwrap();
        let after = s.entries_for_day("2026-05-10");
        assert_eq!(after[0].suffix, "one");
        assert_eq!(after[1].suffix, "two *");
        fs::remove_dir_all(&s.base).ok();
    }

    #[test]
    fn frontend_names_cannot_escape_the_journal_folder() {
        assert!(safe_component("Morning Pages"));
        assert!(!safe_component(""));
        assert!(!safe_component(".."));
        assert!(!safe_component("../inbox"));
        assert!(!safe_component("nested/name"));

        let s = temp_store();
        let inbox = s.inbox_path();
        fs::write(&inbox, "[2026-05-10 08:00:00] keep\nbody\n").unwrap();
        // `assets/../inbox.md` used to resolve straight onto the journal.
        s.delete_asset("assets/../inbox.md");
        s.delete_asset("../inbox.md");
        assert!(inbox.exists());
        assert!(s.delete_journal_entry("../inbox", "2026-05-10 08:00:00", "x").is_err());
        assert!(s.entries_in_journal("../inbox").is_empty());
        fs::remove_dir_all(&s.base).ok();
    }

    #[test]
    fn an_unavailable_folder_blocks_writes_instead_of_recreating_itself() {
        let gone = std::env::temp_dir().join(format!("nook-gone-{}", uuid::Uuid::new_v4()));
        let s = Store { base: gone.clone(), mode: "missing".into() };
        assert!(s.upsert_draft(None, &now_ts(), "", "body").is_err());
        assert!(s.import_drafts("a stray thought").is_err());
        assert!(s.save_asset(b"x", "png").is_none());
        assert!(!s.backup_now().0);
        // Nothing was conjured up where the drive used to be.
        assert!(!gone.exists());
    }

    #[test]
    fn year_of_survives_a_non_ascii_folder_name() {
        assert_eq!(year_of("2026-05-10"), "2026");
        assert_eq!(year_of("日本語-05-10"), "日本語-");
        assert_eq!(year_of("26"), "26");
    }
}
