//! The jnl on-disk format, byte-compatible with jnl's main.go, plus the
//! `Journal` handle every shell works through.
//!
//!   <dir>/inbox/YYYY/MM/DD.md   drafts, one file per day (Quire 0.7+)
//!   <dir>/inbox.md              drafts, the single file jnl and Nook write;
//!                               read when present and folded into inbox/ by
//!                               `migrate_legacy_inbox`
//!   <dir>/journal/YYYY/MM/DD.md filed entries, one file per day
//!   <dir>/<tag>.md              split journals (JNL_SPLIT_TAGS)
//!   <dir>/.quire/               Quire's sidecars (templates, searches,
//!                               Data Saver ledgers); `.nook/` is read when
//!                               `.quire/` does not exist yet and renamed on
//!                               the first write
//!
//! Each entry is `[YYYY-MM-DD HH:MM:SS] optional title` followed by its body.
//! Entries are separated by one blank line. A trailing ` *` on the title stars
//! it. Anything before the first header (a "preamble") is preserved on rewrite.
//!
//! Pure functions (parse, render, links) are free functions. Anything that
//! reads or writes goes through `Journal`, whose storage is a `Vault`.

use crate::vault::{write_atomic_bytes, FsVault, Item, Vault};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

// ASCII digits only: `\d` matches Unicode digits, which would then make the
// byte slicing below panic.
pub static HEADER_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^\[([0-9]{4}[-–][0-9]{2}[-–][0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2})\](.*)$").unwrap()
});
/// A body line that would be read back as a header (same rule as HEADER_RE's
/// prefix). make_raw prefixes such lines with a single backslash.
pub static EMBEDDED_HEADER_RE: Lazy<Regex> = Lazy::new(|| {
    Regex::new(r"^\[[0-9]{4}[-–][0-9]{2}[-–][0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]").unwrap()
});
pub static TAG_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"@[a-zA-Z][a-zA-Z0-9_-]*").unwrap());
pub static TS_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$").unwrap());

/// The single-file inbox jnl and Nook write.
pub const LEGACY_INBOX: &str = "inbox.md";
/// The folder of day files Quire keeps drafts in.
pub const INBOX_DIR: &str = "inbox";
/// Where preamble text from a migrated `inbox.md` is kept.
pub const INBOX_PREAMBLE: &str = "inbox/preamble.md";
pub const JOURNAL_DIR: &str = "journal";
/// The folder split journals live in, one folder of day files per tag:
/// `split/<tag>/YYYY/MM/DD.md`. jnl and Nook write a single root `<tag>.md`
/// instead; Journal::migrate_legacy_splits folds those in.
pub const SPLIT_DIR: &str = "split";
pub const SIDECAR: &str = ".quire";
pub const LEGACY_SIDECAR: &str = ".nook";

/// Validate a `YYYY-MM-DD HH:MM:SS` timestamp supplied by the front end before
/// it is sliced or written into a header.
pub fn check_ts(ts: &str) -> Result<(), String> {
    if TS_RE.is_match(ts) {
        Ok(())
    } else {
        Err(format!("Bad timestamp {:?} (want YYYY-MM-DD HH:MM:SS)", ts))
    }
}

/// Root file stems that are never split journals (compared case-insensitively).
pub const RESERVED_STEMS: &[&str] = &["inbox", "transfer", "export", "readme", "nook-export"];

/// True for a root file name (`work.md`) or bare tag (`work`, `@work`) that
/// can never be a split journal.
pub fn is_reserved(name_or_tag: &str) -> bool {
    let l = name_or_tag.trim().trim_start_matches('@').to_lowercase();
    let stem = l.strip_suffix(".md").unwrap_or(&l);
    RESERVED_STEMS.contains(&stem)
}

/// Syncthing (`x.sync-conflict-…`) and Dropbox (`x (… conflicted copy …)`) copies.
pub fn is_conflict_name(name: &str) -> bool {
    let l = name.to_lowercase();
    l.contains(".sync-conflict-") || l.contains("conflicted copy")
}

/// The file a conflict copy belongs to: `inbox.sync-conflict-2026…-ABC.md`
/// → `inbox.md`; `inbox (Dan's conflicted copy 2026-10-01).md` → `inbox.md`.
/// Works on a bare name or a path (only the last component changes).
pub fn conflict_main_name(rel: &str) -> Option<String> {
    let (dir, name) = match rel.rfind('/') {
        Some(i) => (&rel[..=i], &rel[i + 1..]),
        None => ("", rel),
    };
    let l = name.to_lowercase();
    let main = if let Some(i) = l.find(".sync-conflict-") {
        let rest = &name[i + ".sync-conflict-".len()..];
        let ext = rest.find('.').map(|j| &rest[j..]).unwrap_or("");
        format!("{}{}", &name[..i], ext)
    } else {
        let c = l.find("conflicted copy")?;
        let open = l[..c].rfind('(')?;
        let close = c + l[c..].find(')')?;
        let before = name[..open].trim_end();
        format!("{}{}", before, &name[close + 1..])
    };
    if main.is_empty() || main == name {
        return None;
    }
    Some(format!("{}{}", dir, main))
}

/// Validate a root-relative path that came from the front end: no absolute
/// paths, no `..`, no backslashes, not empty. Returns the normalised rel.
pub fn check_rel(rel: &str) -> Result<String, String> {
    let bad = || format!("Refusing unsafe path {:?}", rel);
    if rel.trim().is_empty() || rel.contains('\\') || rel.contains('\0') {
        return Err(bad());
    }
    let p = Path::new(rel);
    if p.is_absolute() {
        return Err(bad());
    }
    let mut parts = Vec::new();
    for c in p.components() {
        match c {
            Component::Normal(s) => parts.push(s.to_string_lossy().to_string()),
            Component::CurDir => {}
            _ => return Err(bad()),
        }
    }
    if parts.is_empty() {
        return Err(bad());
    }
    Ok(parts.join("/"))
}

/// check_rel, returning `root.join(rel)`.
pub fn safe_rel(root: &Path, rel: &str) -> Result<PathBuf, String> {
    Ok(root.join(check_rel(rel)?))
}

/// check_rel plus: must be a `.md` file outside the sidecars and `assets/`
/// (an entry file: an inbox file, a day file or a split journal).
pub fn check_entry_rel(rel: &str) -> Result<String, String> {
    let r = check_rel(rel)?;
    if !r.to_lowercase().ends_with(".md")
        || r.starts_with(&format!("{}/", SIDECAR))
        || r.starts_with(&format!("{}/", LEGACY_SIDECAR))
        || r.starts_with("assets/")
    {
        return Err(format!("{:?} is not an entry file", rel));
    }
    Ok(r)
}

/// check_entry_rel, returning `root.join(rel)`.
pub fn safe_entry_rel(root: &Path, rel: &str) -> Result<PathBuf, String> {
    Ok(root.join(check_entry_rel(rel)?))
}

#[derive(Debug, Clone)]
pub struct RawEntry {
    pub date: String,
    pub ts: String,
    pub suffix: String,
    pub body: String,
    pub raw: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Entry {
    /// Path relative to the journal folder, e.g. `inbox/2026/09/30.md`,
    /// `journal/2026/09/30.md`, `work.md` (or the legacy `inbox.md`).
    pub file: String,
    /// Position within that file, oldest first as written.
    pub index: usize,
    /// "inbox", "journal" or "split".
    pub source: String,
    /// For split journals, the tag without `@`.
    pub split: Option<String>,
    pub ts: String,
    pub date: String,
    pub time: String,
    pub title: String,
    pub starred: bool,
    pub body: String,
    pub raw: String,
    pub tags: Vec<String>,
    pub words: usize,
}

/// What a write produced: the file an entry now lives in, its index there,
/// and the raw text as written (what the next edit must present as
/// `expected_raw`).
#[derive(Debug, Clone, Serialize)]
pub struct Written {
    pub file: String,
    pub index: usize,
    pub raw: String,
}

pub fn parse_entries(content: &str) -> Vec<RawEntry> {
    let mut out = Vec::new();
    let mut cur: Vec<String> = Vec::new();
    let (mut ts, mut date, mut suffix) = (String::new(), String::new(), String::new());

    let flush = |cur: &Vec<String>, ts: &str, date: &str, suffix: &str, out: &mut Vec<RawEntry>| {
        if ts.is_empty() {
            return;
        }
        let body = cur[1..].join("\n").trim().to_string();
        out.push(RawEntry {
            date: date.to_string(),
            ts: ts.to_string(),
            suffix: suffix.to_string(),
            body,
            raw: cur.join("\n"),
        });
    };

    for line in content.split('\n') {
        if let Some(m) = HEADER_RE.captures(line) {
            flush(&cur, &ts, &date, &suffix, &mut out);
            date = m[1].replace('–', "-");
            ts = format!("{} {}", date, &m[2]);
            suffix = m[3].trim().to_string();
            let mut header = format!("[{}]", ts);
            if !suffix.is_empty() {
                header.push(' ');
                header.push_str(&suffix);
            }
            cur = vec![header];
        } else if !ts.is_empty() {
            cur.push(line.to_string());
        }
    }
    flush(&cur, &ts, &date, &suffix, &mut out);
    out
}

/// Drop a leading byte-order mark and turn CRLF into LF, as the Swift and
/// Kotlin ports do before parsing. A CRLF file becomes LF the first time it
/// is written back.
pub fn normalised(content: &str) -> String {
    let s = content.strip_prefix('\u{FEFF}').unwrap_or(content);
    if s.contains('\r') {
        s.replace("\r\n", "\n")
    } else {
        s.to_string()
    }
}

pub fn is_header_line(line: &str) -> bool {
    HEADER_RE.is_match(line)
}

pub fn leading_preamble(content: &str) -> String {
    let mut pre = Vec::new();
    for line in content.split('\n') {
        if HEADER_RE.is_match(line) {
            break;
        }
        pre.push(line);
    }
    let text = pre.join("\n").trim_end_matches('\n').to_string();
    if text.trim().is_empty() {
        String::new()
    } else {
        text
    }
}

/// Stable, oldest first (the fixed-width ts sorts lexicographically).
pub fn sorted_by_timestamp(entries: &[RawEntry]) -> Vec<RawEntry> {
    let mut v = entries.to_vec();
    v.sort_by(|a, b| a.ts.cmp(&b.ts));
    v
}

pub fn render(preamble: &str, raws: &[String]) -> String {
    let mut parts: Vec<String> = Vec::new();
    if !preamble.is_empty() {
        parts.push(preamble.trim_end_matches('\n').to_string());
    }
    for r in raws {
        parts.push(r.trim_end_matches('\n').to_string());
    }
    if parts.is_empty() {
        return String::new();
    }
    parts.join("\n\n") + "\n"
}

/// Write via a temp file in the same folder and rename, like jnl's writeFile.
/// For files outside a journal (settings, exports). Inside one, use the
/// `Journal`.
pub fn write_atomic(path: &Path, content: &str) -> Result<(), String> {
    write_atomic_bytes(path, content.as_bytes())
}

/// Lenient read of a local path: anything unreadable is "".
pub fn read(path: &Path) -> String {
    try_read(path).unwrap_or_default()
}

/// Strict read of a local path. A missing file is Ok(""); any other failure
/// (non-UTF-8 bytes, permissions) is an error so a writer never mistakes an
/// unreadable file for an empty one and overwrites it.
pub fn try_read(path: &Path) -> Result<String, String> {
    match fs::read_to_string(path) {
        Ok(s) => Ok(normalised(&s)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("Can't read {}: {}", path.display(), e)),
    }
}

pub fn has_star(title: &str) -> bool {
    let t = title.trim();
    t == "*" || t.ends_with(" *")
}

pub fn strip_star(title: &str) -> String {
    let t = title.trim();
    if has_star(t) {
        t[..t.len() - 1].trim().to_string()
    } else {
        t.to_string()
    }
}

/// Prefix `\` to every line that would otherwise read back as a header.
pub fn guard_body(body: &str) -> String {
    body.split('\n')
        .map(|l| if EMBEDDED_HEADER_RE.is_match(l) { format!("\\{}", l) } else { l.to_string() })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Build an entry's raw text the way jnl's fileDraft does.
/// Title whitespace (including newlines) collapses to single spaces; the body
/// is trimmed; body lines that look like headers get a leading backslash so
/// one entry stays one entry.
pub fn make_raw(ts: &str, title: &str, starred: bool, body: &str) -> String {
    let mut suffix = title.split_whitespace().collect::<Vec<_>>().join(" ");
    if starred {
        suffix = if suffix.is_empty() { "*".into() } else { format!("{} *", suffix) };
    }
    let body = guard_body(body.trim());
    match (suffix.is_empty(), body.is_empty()) {
        (false, false) => format!("[{}] {}\n{}", ts, suffix, body),
        (false, true) => format!("[{}] {}", ts, suffix),
        (true, _) => format!("[{}]\n{}", ts, body),
    }
}

/// make_raw from a parsed entry (normalises whitespace the way jnl does).
pub fn rebuild(e: &RawEntry) -> String {
    make_raw(&e.ts, &strip_star(&e.suffix), has_star(&e.suffix), &e.body)
}

pub fn journal_rel(date: &str) -> String {
    let p: Vec<&str> = date.split('-').collect();
    format!("{}/{}/{}/{}.md", JOURNAL_DIR, p[0], p[1], p[2])
}

/// The inbox day file a draft dated `date` lives in.
pub fn inbox_rel(date: &str) -> String {
    let p: Vec<&str> = date.split('-').collect();
    format!("{}/{}/{}/{}.md", INBOX_DIR, p[0], p[1], p[2])
}

/// True for any inbox file: the legacy `inbox.md` or a day file under `inbox/`.
pub fn is_inbox_rel(rel: &str) -> bool {
    rel == LEGACY_INBOX || rel.starts_with("inbox/")
}

/// The day file of split journal `tag` for `date`.
pub fn split_rel(tag: &str, date: &str) -> String {
    let p: Vec<&str> = date.split('-').collect();
    format!("{}/{}/{}/{}/{}.md", SPLIT_DIR, tag, p[0], p[1], p[2])
}

/// `split/<tag>/preamble.md`: where text above the first entry of a migrated
/// `<tag>.md` is kept. Not an entry file.
pub fn is_split_preamble(rel: &str) -> bool {
    let parts: Vec<&str> = rel.split('/').collect();
    parts.len() == 3 && parts[0] == SPLIT_DIR && parts[2] == "preamble.md"
}

/// The split journal a file belongs to: `split/work/2026/10/14.md` → `work`;
/// a legacy root `work.md` → `work`. None for anything else.
pub fn split_tag_of(rel: &str) -> Option<String> {
    if let Some(rest) = rel.strip_prefix("split/") {
        let (tag, tail) = rest.split_once('/')?;
        return (!tag.is_empty() && !tail.is_empty()).then(|| tag.to_string());
    }
    let legacy = !rel.contains('/') && rel.ends_with(".md") && !rel.starts_with('.') && !is_reserved(rel) && !is_conflict_name(rel);
    legacy.then(|| rel.trim_end_matches(".md").to_string())
}

/// True for a day file whose name is its date (`inbox/…/DD.md`,
/// `journal/…/DD.md`, `split/<tag>/…/DD.md`): the files that are deleted
/// rather than left empty.
pub fn is_day_file(rel: &str) -> bool {
    (rel.starts_with("inbox/") || rel.starts_with("journal/") || rel.starts_with("split/")) && rel != INBOX_PREAMBLE && !is_split_preamble(rel)
}

/// The date a day file is named for: `inbox/2026/10/14.md`,
/// `journal/2026/10/14.md` and `split/<tag>/2026/10/14.md` → `2026-10-14`.
/// None for anything else (`inbox.md`, a legacy `<tag>.md`, a conflict copy,
/// a file whose name isn't a date).
pub fn day_file_date(rel: &str) -> Option<String> {
    if !is_day_file(rel) {
        return None;
    }
    let parts: Vec<&str> = rel.split('/').collect();
    let want = if parts[0] == SPLIT_DIR { 5 } else { 4 };
    if parts.len() != want {
        return None;
    }
    let (y, m, d) = (parts[want - 3], parts[want - 2], parts[want - 1].strip_suffix(".md")?);
    let digits = |s: &str, n: usize| s.len() == n && s.bytes().all(|b| b.is_ascii_digit());
    (digits(y, 4) && digits(m, 2) && digits(d, 2)).then(|| format!("{}-{}-{}", y, m, d))
}

/// The day file for `date` in the same tree as day file `rel` (inbox,
/// journal, or the same split journal). None when `rel` isn't a day file.
pub fn day_file_like(rel: &str, date: &str) -> Option<String> {
    day_file_date(rel)?;
    if rel.starts_with("inbox/") {
        Some(inbox_rel(date))
    } else if rel.starts_with("journal/") {
        Some(journal_rel(date))
    } else {
        split_tag_of(rel).map(|tag| split_rel(&tag, date))
    }
}

fn to_entry(r: &RawEntry, file: &str, index: usize, source: &str, split: Option<String>) -> Entry {
    let mut tags: Vec<String> = Vec::new();
    for m in TAG_RE.find_iter(&format!("{}\n{}", r.suffix, r.body)) {
        let t = m.as_str().to_string();
        if !tags.contains(&t) {
            tags.push(t);
        }
    }
    Entry {
        file: file.to_string(),
        index,
        source: source.to_string(),
        split,
        ts: r.ts.clone(),
        date: r.date.clone(),
        time: r.ts[11..16].to_string(),
        title: strip_star(&r.suffix),
        starred: has_star(&r.suffix),
        words: r.body.split_whitespace().count(),
        body: r.body.clone(),
        raw: r.raw.clone(),
        tags,
    }
}

pub fn rel_of(root: &Path, p: &Path) -> String {
    p.strip_prefix(root).unwrap_or(p).to_string_lossy().replace('\\', "/")
}

fn join_rel_parts(dir: &str, name: &str) -> String {
    if dir.is_empty() || dir == "." {
        name.to_string()
    } else {
        format!("{}/{}", dir, name)
    }
}

/// The split tag a raw entry is routed by (`work`), honouring the order of
/// `split_tags`. Reserved names are never split tags.
pub fn split_tag(raw: &str, split_tags: &[String]) -> Option<String> {
    let present: Vec<&str> = TAG_RE.find_iter(raw).map(|m| m.as_str()).collect();
    for t in split_tags {
        let t = if t.starts_with('@') { t.clone() } else { format!("@{}", t) };
        if is_reserved(&t) {
            continue;
        }
        if present.contains(&t.as_str()) {
            return Some(t.trim_start_matches('@').to_string());
        }
    }
    None
}

/// The split-journal day file a raw entry belongs in
/// (`split/work/2026/10/14.md`), or None when no split tag matches.
pub fn split_target(raw: &str, split_tags: &[String]) -> Option<String> {
    let tag = split_tag(raw, split_tags)?;
    let date = parse_entries(raw).into_iter().next()?.date;
    Some(split_rel(&tag, &date))
}

/// Which sidecar folder a journal root uses, for local-only code (media): the
/// same rule as `Journal::sidecar`.
pub fn sidecar_dir_path(root: &Path) -> PathBuf {
    if root.join(SIDECAR).is_dir() {
        root.join(SIDECAR)
    } else if root.join(LEGACY_SIDECAR).is_dir() {
        root.join(LEGACY_SIDECAR)
    } else {
        root.join(SIDECAR)
    }
}

/// What Journal::migrate_legacy_splits did.
#[derive(Debug, Default, Clone, Serialize)]
pub struct SplitMigration {
    /// Root `<tag>.md` files folded into `split/<tag>/`.
    pub journals: usize,
    /// Entries written into day files.
    pub moved: usize,
    /// Entries already there (an older app rewrote `<tag>.md`).
    pub skipped: usize,
    /// Where each original went, relative to the root.
    pub backups: Vec<String>,
}

/// What folding `inbox.md` into `inbox/` did.
#[derive(Debug, Default, Clone, Serialize)]
pub struct InboxMigration {
    /// Drafts written into `inbox/` day files.
    pub moved: usize,
    /// Drafts already present there (an older app rewrote `inbox.md`).
    pub skipped: usize,
    /// Where the old `inbox.md` went, relative to the root.
    pub backup: String,
}

// ---------- the handle ----------

/// A journal folder and the vault that reaches it. Cheap to clone.
#[derive(Clone)]
pub struct Journal {
    root: PathBuf,
    vault: Arc<dyn Vault>,
}

impl std::fmt::Debug for Journal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Journal({})", self.root.display())
    }
}

impl Journal {
    /// A journal on the local filesystem.
    pub fn open(root: impl Into<PathBuf>) -> Journal {
        let root = root.into();
        Journal { vault: Arc::new(FsVault::new(root.clone())), root }
    }

    /// A journal behind any vault. `root` is only a label there (shown to
    /// the user, never opened).
    pub fn with_vault(root: impl Into<PathBuf>, vault: Arc<dyn Vault>) -> Journal {
        Journal { root: root.into(), vault }
    }

    /// The folder as the user knows it.
    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn vault(&self) -> &dyn Vault {
        self.vault.as_ref()
    }

    /// The root as a real path, for code that needs one (media tools,
    /// backups). Err on a vault with no local path.
    pub fn local(&self) -> Result<&Path, String> {
        match self.vault.local_path("") {
            Some(_) => Ok(&self.root),
            None => Err("This needs the journal on a local folder".into()),
        }
    }

    /// A real path for `rel`, where the vault has one.
    pub fn path(&self, rel: &str) -> Result<PathBuf, String> {
        self.vault.local_path(rel).ok_or_else(|| "This needs the journal on a local folder".to_string())
    }

    pub fn exists(&self) -> bool {
        self.vault.is_dir("")
    }

    // ----- primitives -----

    /// Strict read: missing is Ok(""), unreadable is Err.
    pub fn try_read(&self, rel: &str) -> Result<String, String> {
        match self.vault.read(rel)? {
            None => Ok(String::new()),
            Some(b) => String::from_utf8(b).map(|s| normalised(&s)).map_err(|e| format!("Can't read {}: {}", rel, e)),
        }
    }

    /// Lenient read: anything unreadable is "".
    pub fn read(&self, rel: &str) -> String {
        self.try_read(rel).unwrap_or_default()
    }

    pub fn write(&self, rel: &str, content: &str) -> Result<(), String> {
        self.vault.write(rel, content.as_bytes())
    }

    pub fn remove(&self, rel: &str) -> Result<bool, String> {
        self.vault.remove(rel)
    }

    pub fn is_file(&self, rel: &str) -> bool {
        self.vault.is_file(rel)
    }

    pub fn is_dir(&self, rel: &str) -> bool {
        self.vault.is_dir(rel)
    }

    pub fn len(&self, rel: &str) -> u64 {
        self.vault.len(rel)
    }

    pub fn list(&self, rel: &str) -> Vec<Item> {
        self.vault.list(rel).unwrap_or_default()
    }

    /// Every regular file under `dir` (rel paths, sorted), never following
    /// symlinks, hidden files included.
    pub fn walk_files(&self, dir: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut stack = vec![dir.trim_end_matches('/').to_string()];
        while let Some(d) = stack.pop() {
            for it in self.list(&d) {
                let rel = join_rel_parts(&d, &it.name);
                if it.is_dir {
                    stack.push(rel);
                } else if it.is_file {
                    out.push(rel);
                }
            }
        }
        out.sort();
        out
    }

    /// Total bytes of the files under `dir`.
    pub fn tree_bytes(&self, dir: &str) -> u64 {
        self.walk_files(dir).iter().map(|f| self.vault.len(f)).sum()
    }

    /// Every `.md` under `dir` (no symlinked folders), hidden files and
    /// conflict copies excluded, sorted.
    pub fn walk_md(&self, dir: &str) -> Vec<String> {
        self.walk_files(dir)
            .into_iter()
            .filter(|rel| {
                let name = rel.rsplit('/').next().unwrap_or(rel);
                name.ends_with(".md") && !name.starts_with('.') && !is_conflict_name(name)
            })
            .collect()
    }

    // ----- sidecar -----

    /// The sidecar folder to read: `.quire/`, else `.nook/` while only that
    /// exists.
    pub fn sidecar(&self) -> &'static str {
        if self.vault.is_dir(SIDECAR) {
            SIDECAR
        } else if self.vault.is_dir(LEGACY_SIDECAR) {
            LEGACY_SIDECAR
        } else {
            SIDECAR
        }
    }

    /// The sidecar folder to write: `.quire/`, renaming `.nook/` to it on the
    /// first write.
    pub fn sidecar_mut(&self) -> Result<&'static str, String> {
        if !self.vault.is_dir(SIDECAR) && self.vault.is_dir(LEGACY_SIDECAR) {
            self.vault.rename(LEGACY_SIDECAR, SIDECAR)?;
        }
        Ok(SIDECAR)
    }

    // ----- files -----

    /// Root `.md` files in jnl's one-file split-journal shape (not reserved,
    /// not conflict copies, not hidden), sorted by name. Quire folds them
    /// into `split/` (migrate_legacy_splits) but reads them where they are
    /// until then.
    pub fn legacy_split_files(&self) -> Vec<String> {
        self.list("")
            .into_iter()
            .filter(|it| it.is_file && split_tag_of(&it.name).is_some())
            .map(|it| it.name)
            .collect()
    }

    /// Every split-journal file as (rel, tag): legacy root `<tag>.md` files,
    /// then the day files under `split/<tag>/`.
    pub fn split_files(&self) -> Vec<(String, String)> {
        let mut out: Vec<(String, String)> = self.legacy_split_files().into_iter().map(|n| (n.clone(), split_tag_of(&n).unwrap_or_default())).collect();
        for rel in self.walk_md(SPLIT_DIR) {
            if is_split_preamble(&rel) {
                continue;
            }
            if let Some(tag) = split_tag_of(&rel) {
                out.push((rel, tag));
            }
        }
        out
    }

    /// Every inbox file in load order: the legacy `inbox.md` when present,
    /// then the day files under `inbox/`.
    pub fn inbox_files(&self) -> Vec<String> {
        let mut out = Vec::new();
        if self.vault.is_file(LEGACY_INBOX) {
            out.push(LEGACY_INBOX.to_string());
        }
        out.extend(self.walk_md(INBOX_DIR).into_iter().filter(|r| r != INBOX_PREAMBLE));
        out
    }

    /// Every entry file as (root-relative path, source, split tag), in load order.
    pub fn entry_files(&self) -> Vec<(String, &'static str, Option<String>)> {
        let mut out: Vec<(String, &'static str, Option<String>)> = self.inbox_files().into_iter().map(|f| (f, "inbox", None)).collect();
        for f in self.walk_md(JOURNAL_DIR) {
            out.push((f, "journal", None));
        }
        for (rel, tag) in self.split_files() {
            out.push((rel, "split", Some(tag)));
        }
        out
    }

    /// Conflict copies of entry files (root, inbox/**, journal/** and split/**).
    pub fn conflict_files(&self) -> Vec<String> {
        let mut out: Vec<String> = self
            .list("")
            .into_iter()
            .filter(|it| it.is_file && it.name.to_lowercase().ends_with(".md") && is_conflict_name(&it.name))
            .map(|it| it.name)
            .collect();
        for dir in [INBOX_DIR, JOURNAL_DIR, SPLIT_DIR] {
            out.extend(self.walk_files(dir).into_iter().filter(|rel| {
                let name = rel.rsplit('/').next().unwrap_or(rel);
                name.to_lowercase().ends_with(".md") && is_conflict_name(name)
            }));
        }
        out.sort();
        out
    }

    /// Lenient load: unreadable files contribute nothing.
    pub fn load_all(&self) -> Vec<Entry> {
        self.load_all_with(false).unwrap_or_default()
    }

    /// Strict load: Err if any entry file cannot be read (used before
    /// destructive operations such as deleting orphaned assets).
    pub fn try_load_all(&self) -> Result<Vec<Entry>, String> {
        self.load_all_with(true)
    }

    fn load_all_with(&self, strict: bool) -> Result<Vec<Entry>, String> {
        let mut out = Vec::new();
        for (rel, source, split) in self.entry_files() {
            let content = if strict { self.try_read(&rel)? } else { self.read(&rel) };
            for (i, r) in parse_entries(&content).iter().enumerate() {
                out.push(to_entry(r, &rel, i, source, split.clone()));
            }
        }
        Ok(out)
    }

    /// The entries of one file.
    pub fn load_file(&self, rel: &str) -> Vec<Entry> {
        self.try_load_file(rel).unwrap_or_default()
    }

    /// Read one file without treating unreadable bytes as an empty entry list.
    pub fn try_load_file(&self, rel: &str) -> Result<Vec<Entry>, String> {
        let rel = check_entry_rel(rel)?;
        let source = if is_inbox_rel(&rel) {
            "inbox"
        } else if rel.starts_with("journal/") {
            "journal"
        } else {
            "split"
        };
        let split = if source == "split" { split_tag_of(&rel) } else { None };
        Ok(parse_entries(&self.try_read(&rel)?).iter().enumerate().map(|(i, r)| to_entry(r, &rel, i, source, split.clone())).collect())
    }

    /// Locate an entry in a file by its raw text, preferring the expected index.
    /// Returns the file's preamble, all raws, and the matching position.
    pub fn locate(&self, file: &str, index: usize, expected_raw: &str) -> Result<(String, Vec<String>, usize), String> {
        let content = self.try_read(file)?;
        let pre = leading_preamble(&content);
        let raws: Vec<String> = parse_entries(&content).into_iter().map(|r| r.raw).collect();
        let norm = |s: &str| s.trim_end().to_string();
        let want = norm(expected_raw);
        if raws.get(index).map(|r| norm(r) == want).unwrap_or(false) {
            return Ok((pre, raws, index));
        }
        if let Some(i) = raws.iter().position(|r| norm(r) == want) {
            return Ok((pre, raws, i));
        }
        Err("That entry changed on disk since Quire last read it. Reloaded — try again.".into())
    }

    /// Write a file's preamble and entries. A day file (`inbox/…`,
    /// `journal/…`, `split/<tag>/…`) that would come out empty is deleted
    /// instead, as a day with no entries has no file; `inbox.md` and a legacy
    /// root `<tag>.md` are written empty, as jnl does.
    pub fn write_file_entries(&self, file: &str, pre: &str, raws: &[String]) -> Result<(), String> {
        let text = render(pre, raws);
        if text.is_empty() && is_day_file(file) {
            self.remove(file)?;
            return Ok(());
        }
        self.write(file, &text)
    }

    /// Append `raw` to a file the way jnl's fileDraft does (blank-line
    /// separated). Returns the index of the (first) appended entry.
    pub fn append_raw(&self, file: &str, raw: &str) -> Result<usize, String> {
        let mut s = self.try_read(file)?;
        let before = parse_entries(&s).len();
        if !s.trim().is_empty() {
            if !s.ends_with("\n\n") {
                s.push_str(if s.ends_with('\n') { "\n" } else { "\n\n" });
            }
        } else {
            s.clear();
        }
        s.push_str(raw.trim_end_matches('\n'));
        s.push('\n');
        self.write(file, &s)?;
        Ok(before)
    }

    /// Insert every entry parsed from each of `raws` into `file`, each after
    /// the last entry whose ts is <= its own (stable, so a file already in
    /// order stays in order). One read and one write. With `skip_existing`,
    /// an entry whose exact raw (trim_end) is already in the file is not
    /// inserted again (makes destination-first moves safe to retry).
    ///
    /// Returns the final indices of the inserted entries, in input order
    /// (`None` for skipped ones). Errors if any raw parses to zero entries.
    pub fn insert_entries(&self, file: &str, raws: &[String], skip_existing: bool) -> Result<Vec<Option<usize>>, String> {
        let content = self.try_read(file)?;
        let pre = leading_preamble(&content);
        let mut entries: Vec<(RawEntry, Option<usize>)> = parse_entries(&content).into_iter().map(|e| (e, None)).collect();
        let mut have: HashMap<String, usize> = HashMap::new();
        for (e, _) in &entries {
            *have.entry(e.raw.trim_end().to_string()).or_default() += 1;
        }
        let mut n_new = 0;
        let mut tag = 0usize;
        let mut out_slots: Vec<Vec<usize>> = Vec::new();
        for raw in raws {
            let parsed = parse_entries(raw);
            if parsed.is_empty() {
                return Err(format!("Not an entry: {:?}", raw.chars().take(60).collect::<String>()));
            }
            let mut slots = Vec::new();
            for n in parsed {
                let key = n.raw.trim_end().to_string();
                if skip_existing {
                    if let Some(c) = have.get_mut(&key) {
                        if *c > 0 {
                            *c -= 1;
                            continue;
                        }
                    }
                }
                let pos = entries.iter().rposition(|(e, _)| e.ts <= n.ts).map(|p| p + 1).unwrap_or(0);
                entries.insert(pos, (n, Some(tag)));
                slots.push(tag);
                tag += 1;
                n_new += 1;
            }
            out_slots.push(slots);
        }
        if n_new > 0 {
            let rendered: Vec<String> = entries.iter().map(|(e, _)| e.raw.clone()).collect();
            self.write_file_entries(file, &pre, &rendered)?;
        }
        let mut pos_of: HashMap<usize, usize> = HashMap::new();
        for (i, (_, t)) in entries.iter().enumerate() {
            if let Some(t) = t {
                pos_of.insert(*t, i);
            }
        }
        Ok(out_slots.iter().map(|s| s.first().and_then(|t| pos_of.get(t).copied())).collect())
    }

    /// Insert into a file keeping it in timestamp order (stable). Inserts
    /// every entry parsed from `raw`; errors if there are none. Returns the
    /// index of the first inserted entry.
    pub fn insert_sorted(&self, file: &str, raw: &str) -> Result<usize, String> {
        let r = self.insert_entries(file, &[raw.to_string()], false)?;
        r.first().copied().flatten().ok_or_else(|| "bad entry".to_string())
    }

    // ----- the operations every shell shares -----

    /// A new draft, into its day's inbox file, in time order.
    pub fn new_draft(&self, ts: &str, title: &str, starred: bool, body: &str) -> Result<Written, String> {
        check_ts(ts)?;
        if title.trim().is_empty() && body.trim().is_empty() && !starred {
            return Err("Nothing to save".into());
        }
        let raw = make_raw(ts, title, starred, body);
        let file = inbox_rel(&ts[..10]);
        let index = self.insert_sorted(&file, &raw)?;
        Ok(Written { file, index, raw })
    }

    /// Edit any entry in place. An entry in a day file whose date changes
    /// moves to the new day's file in the same tree (inbox, journal, or the
    /// same split journal), kept in time order. An entry in a legacy root
    /// `<tag>.md` stays in its file.
    #[allow(clippy::too_many_arguments)]
    pub fn update_entry(&self, file: &str, index: usize, expected_raw: &str, ts: &str, title: &str, starred: bool, body: &str) -> Result<Written, String> {
        let file = check_entry_rel(file)?;
        check_ts(ts)?;
        let (pre, mut raws, i) = self.locate(&file, index, expected_raw)?;
        let new_raw = make_raw(ts, title, starred, body);
        let new_date = &ts[..10];
        let day_file = is_day_file(&file);
        let dest = if file.starts_with("inbox/") {
            inbox_rel(new_date)
        } else if let (true, Some(tag)) = (file.starts_with("split/"), split_tag_of(&file)) {
            split_rel(&tag, new_date)
        } else {
            journal_rel(new_date)
        };
        if day_file && dest != file {
            let new_raw = rebase_links(&new_raw, &file, &dest);
            // Write the destination first: a failure leaves a duplicate, never a loss.
            let idx = self.insert_sorted(&dest, &new_raw)?;
            raws.remove(i);
            self.write_file_entries(&file, &pre, &raws)?;
            return Ok(Written { file: dest, index: idx, raw: new_raw });
        }
        let old_ts = parse_entries(&raws[i]).first().map(|e| e.ts.clone()).unwrap_or_default();
        raws[i] = new_raw.clone();
        let mut idx = i;
        if day_file && old_ts != ts {
            // Re-sort the day so a retimed entry lands in order (stable).
            let mut es: Vec<(usize, RawEntry)> =
                raws.iter().enumerate().flat_map(|(k, x)| parse_entries(x).into_iter().map(move |e| (k, e))).collect();
            es.sort_by(|a, b| a.1.ts.cmp(&b.1.ts));
            idx = es.iter().position(|(k, _)| *k == i).unwrap_or(i);
            raws = es.into_iter().map(|(_, e)| e.raw).collect();
        }
        self.write_file_entries(&file, &pre, &raws)?;
        Ok(Written { file, index: idx, raw: new_raw })
    }

    pub fn delete_entry(&self, file: &str, index: usize, expected_raw: &str) -> Result<(), String> {
        let file = check_entry_rel(file)?;
        let (pre, mut raws, i) = self.locate(&file, index, expected_raw)?;
        raws.remove(i);
        self.write_file_entries(&file, &pre, &raws)
    }

    /// File a draft: jnl's fileDraft (split tags first, else the day file,
    /// appended), then remove it from its inbox file. Returns where it went.
    pub fn file_draft(&self, file: &str, index: usize, expected_raw: &str, split_tags: &[String]) -> Result<String, String> {
        let file = check_entry_rel(file)?;
        if !is_inbox_rel(&file) {
            return Err("Only a draft in the inbox can be filed".into());
        }
        let (pre, mut raws, i) = self.locate(&file, index, expected_raw)?;
        let e = parse_entries(&raws[i]).into_iter().next().ok_or("bad draft")?;
        if e.body.is_empty() && e.suffix.is_empty() {
            return Err("Nothing to file".into());
        }
        let target = split_target(&e.raw, split_tags).unwrap_or_else(|| journal_rel(&e.date));
        let raw = rebase_links(&rebuild(&e), &file, &target);
        self.append_raw(&target, &raw)?;
        raws.remove(i);
        self.write_file_entries(&file, &pre, &raws)?;
        Ok(target)
    }

    /// Nook's "Return to Inbox": move a filed entry back to the queue, into
    /// the inbox day file of its own date.
    pub fn unfile_entry(&self, file: &str, index: usize, expected_raw: &str) -> Result<Written, String> {
        let file = check_entry_rel(file)?;
        if is_inbox_rel(&file) {
            return Err("That entry is already in the inbox".into());
        }
        let (pre, mut raws, i) = self.locate(&file, index, expected_raw)?;
        let e = parse_entries(&raws[i]).into_iter().next().ok_or("bad entry")?;
        let dest = inbox_rel(&e.date);
        let raw = rebase_links(raws.remove(i).trim_end(), &file, &dest);
        // Inbox first, then remove: a failure leaves a duplicate, never a loss.
        let index = self.insert_sorted(&dest, &raw)?;
        self.write_file_entries(&file, &pre, &raws)?;
        Ok(Written { file: dest, index, raw })
    }

    /// Pasted text into drafts: one per `[header]` when present, else one
    /// draft dated `now_ts`. Returns how many.
    pub fn import_text(&self, text: &str, now_ts: &str) -> Result<usize, String> {
        check_ts(now_ts)?;
        let parsed = parse_entries(text);
        if parsed.is_empty() {
            if text.trim().is_empty() {
                return Ok(0);
            }
            self.insert_sorted(&inbox_rel(&now_ts[..10]), &make_raw(now_ts, "", false, text.trim()))?;
            return Ok(1);
        }
        let n = parsed.len();
        for e in parsed {
            self.insert_sorted(&inbox_rel(&e.date), &rebuild(&e))?;
        }
        Ok(n)
    }

    /// Fold a legacy `inbox.md` into `inbox/` day files. Every draft is
    /// re-read from the day files before `inbox.md` is moved (never deleted)
    /// to `<sidecar>/migration/inbox-<stamp>.md`; preamble text goes to
    /// `inbox/preamble.md`. `Ok(None)` when there is no `inbox.md`. Safe to
    /// run again: drafts already in `inbox/` are skipped.
    pub fn migrate_legacy_inbox(&self) -> Result<Option<InboxMigration>, String> {
        if !self.vault.is_file(LEGACY_INBOX) {
            return Ok(None);
        }
        let content = self.try_read(LEGACY_INBOX)?;
        let entries = parse_entries(&content);
        let pre = leading_preamble(&content);
        let mut rep = InboxMigration::default();
        let mut by_day: Vec<(String, Vec<String>)> = Vec::new();
        for e in &entries {
            match by_day.iter_mut().find(|(d, _)| *d == e.date) {
                Some((_, v)) => v.push(e.raw.clone()),
                None => by_day.push((e.date.clone(), vec![e.raw.clone()])),
            }
        }
        for (date, raws) in &by_day {
            let res = self.insert_entries(&inbox_rel(date), raws, true)?;
            rep.moved += res.iter().filter(|r| r.is_some()).count();
            rep.skipped += res.iter().filter(|r| r.is_none()).count();
        }
        if !pre.is_empty() {
            let existing = self.read(INBOX_PREAMBLE);
            if !existing.contains(pre.trim()) {
                let text = if existing.trim().is_empty() { format!("{}\n", pre) } else { format!("{}\n\n{}\n", existing.trim_end(), pre) };
                self.write(INBOX_PREAMBLE, &text)?;
            }
        }
        // Verify before touching the original.
        let mut have: HashMap<String, usize> = HashMap::new();
        for rel in self.walk_md(INBOX_DIR) {
            for e in parse_entries(&self.try_read(&rel)?) {
                *have.entry(e.raw.trim_end().to_string()).or_default() += 1;
            }
        }
        for e in &entries {
            match have.get_mut(e.raw.trim_end()) {
                Some(c) if *c > 0 => *c -= 1,
                _ => return Err(format!("inbox.md was not moved: the draft {:?} could not be read back from inbox/", e.ts)),
            }
        }
        let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
        let dir = format!("{}/migration", self.sidecar_mut()?);
        let mut backup = format!("{}/inbox-{}.md", dir, stamp);
        let mut n = 1;
        while self.vault.is_file(&backup) {
            n += 1;
            backup = format!("{}/inbox-{}-{}.md", dir, stamp, n);
        }
        self.vault.rename(LEGACY_INBOX, &backup)?;
        rep.backup = backup;
        Ok(Some(rep))
    }

    /// Fold each legacy root `<tag>.md` split journal into
    /// `split/<tag>/YYYY/MM/DD.md`, the way migrate_legacy_inbox folds
    /// `inbox.md`: links rebased, preamble text kept in
    /// `split/<tag>/preamble.md`, every entry read back from the day files
    /// before the original is moved (never deleted) to
    /// `<sidecar>/migration/split-<tag>-<stamp>.md`. A root `.md` with no
    /// entries is not a journal and is left alone. `Ok(None)` when there was
    /// nothing to fold. Safe to run again: entries already there are skipped.
    pub fn migrate_legacy_splits(&self) -> Result<Option<SplitMigration>, String> {
        let mut rep = SplitMigration::default();
        for name in self.legacy_split_files() {
            let content = self.try_read(&name)?;
            let entries = parse_entries(&content);
            if entries.is_empty() {
                continue;
            }
            let tag = split_tag_of(&name).unwrap_or_default();
            let mut by_day: Vec<(String, Vec<String>)> = Vec::new();
            let mut want: HashMap<String, usize> = HashMap::new();
            for e in &entries {
                let dest = split_rel(&tag, &e.date);
                let raw = rebase_links(e.raw.trim_end(), &name, &dest);
                *want.entry(raw.trim_end().to_string()).or_default() += 1;
                match by_day.iter_mut().find(|(d, _)| *d == dest) {
                    Some((_, v)) => v.push(raw),
                    None => by_day.push((dest, vec![raw])),
                }
            }
            for (dest, raws) in &by_day {
                let res = self.insert_entries(dest, raws, true)?;
                rep.moved += res.iter().filter(|r| r.is_some()).count();
                rep.skipped += res.iter().filter(|r| r.is_none()).count();
            }
            let pre = leading_preamble(&content);
            if !pre.trim().is_empty() {
                let at = format!("{}/{}/preamble.md", SPLIT_DIR, tag);
                let existing = self.read(&at);
                if !existing.contains(pre.trim()) {
                    let text = if existing.trim().is_empty() { format!("{}\n", pre) } else { format!("{}\n\n{}\n", existing.trim_end(), pre) };
                    self.write(&at, &text)?;
                }
            }
            // Verify before touching the original.
            let mut have: HashMap<String, usize> = HashMap::new();
            for rel in self.walk_md(&format!("{}/{}", SPLIT_DIR, tag)) {
                if is_split_preamble(&rel) {
                    continue;
                }
                for e in parse_entries(&self.try_read(&rel)?) {
                    *have.entry(e.raw.trim_end().to_string()).or_default() += 1;
                }
            }
            for (raw, n) in &want {
                if have.get(raw).copied().unwrap_or(0) < *n {
                    return Err(format!("{} was not moved: an entry could not be read back from {}/{}/", name, SPLIT_DIR, tag));
                }
            }
            let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
            let dir = format!("{}/migration", self.sidecar_mut()?);
            let mut backup = format!("{}/split-{}-{}.md", dir, tag, stamp);
            let mut n = 1;
            while self.vault.is_file(&backup) {
                n += 1;
                backup = format!("{}/split-{}-{}-{}.md", dir, tag, stamp, n);
            }
            self.vault.rename(&name, &backup)?;
            rep.journals += 1;
            rep.backups.push(backup);
        }
        Ok((rep.journals > 0).then_some(rep))
    }
}

// ---------- links (rule shared with Nook) ----------

/// Normalise a `/`-joined relative path. None if it climbs above the root.
pub fn normalize_rel(p: &str) -> Option<String> {
    let mut parts: Vec<&str> = Vec::new();
    for c in p.split('/') {
        match c {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            s => parts.push(s),
        }
    }
    Some(parts.join("/"))
}

fn dir_of(file_rel: &str) -> &str {
    match file_rel.rfind('/') {
        Some(i) => &file_rel[..i],
        None => "",
    }
}

fn join_rel(dir: &str, p: &str) -> Option<String> {
    if dir.is_empty() {
        normalize_rel(p)
    } else {
        normalize_rel(&format!("{}/{}", dir, p))
    }
}

/// True for link targets that aren't local paths (`http:`, `mailto:`,
/// `dayone-moment:`, `#anchor`, `/abs`).
pub fn is_external(p: &str) -> bool {
    if p.starts_with('#') || p.starts_with('/') {
        return true;
    }
    static SCHEME: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[A-Za-z][A-Za-z0-9+.-]*:").unwrap());
    SCHEME.is_match(p)
}

/// Resolve link target `p` written in root-relative file `file_rel` to a
/// root-relative path (Nook's rule): `../x` or `./x` → relative to the file's
/// folder; `assets/x` → relative to the journal root; anything else →
/// relative to the file's folder. None for external links or paths that
/// climb out of the root.
pub fn resolve_link(file_rel: &str, p: &str) -> Option<String> {
    if is_external(p) {
        return None;
    }
    if p.starts_with("../") || p.starts_with("./") {
        join_rel(dir_of(file_rel), p)
    } else if p.starts_with("assets/") {
        normalize_rel(p)
    } else {
        join_rel(dir_of(file_rel), p)
    }
}

/// Every interpretation of `p` (file-relative and root-relative, plus
/// %-decoded forms): used where being wrong would delete something.
pub fn resolve_link_all(file_rel: &str, p: &str) -> Vec<String> {
    if is_external(p) {
        return vec![];
    }
    let mut forms = vec![p.to_string()];
    let dec = percent_decode(p);
    if dec != p {
        forms.push(dec);
    }
    let mut out = Vec::new();
    for f in forms {
        for c in [join_rel(dir_of(file_rel), &f), normalize_rel(&f)].into_iter().flatten() {
            if !out.contains(&c) {
                out.push(c);
            }
        }
    }
    out
}

pub fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = |c: u8| (c as char).to_digit(16);
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| s.to_string())
}

/// `](target` in images and links; group 1 = leading space, 2 = `<…>` form, 3 = bare.
pub static LINK_TARGET_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\]\((\s*)(?:<([^>\n]*)>|([^)\s]+))").unwrap());

/// Every local link target in `text` (as written).
pub fn link_targets(text: &str) -> Vec<String> {
    LINK_TARGET_RE
        .captures_iter(text)
        .filter_map(|c| c.get(2).or_else(|| c.get(3)).map(|m| m.as_str().to_string()))
        .filter(|p| !is_external(p))
        .collect()
}

/// Rewrite file-relative links (`../…`, `./…`) that resolve into `assets/`
/// as base-relative `assets/…`, so the entry can live in any file. Other
/// links (base-relative, external, or not under assets/) are left alone.
/// `to_rel` is the destination file (base-relative links work from anywhere).
pub fn rebase_links(raw: &str, from_rel: &str, _to_rel: &str) -> String {
    LINK_TARGET_RE
        .replace_all(raw, |c: &regex::Captures| {
            let ws = &c[1];
            let (p, angle) = match (c.get(2), c.get(3)) {
                (Some(m), _) => (m.as_str(), true),
                (_, Some(m)) => (m.as_str(), false),
                _ => return c[0].to_string(),
            };
            if !(p.starts_with("../") || p.starts_with("./")) {
                return c[0].to_string();
            }
            match resolve_link(from_rel, p) {
                Some(r) if r.starts_with("assets/") => {
                    if angle {
                        format!("]({}<{}>", ws, r)
                    } else {
                        format!("]({}{}", ws, r)
                    }
                }
                _ => c[0].to_string(),
            }
        })
        .into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> (tempfile::TempDir, Journal) {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        (d, j)
    }

    #[test]
    fn roundtrip_and_star() {
        let c = "note\n\n[2026-09-30 08:12:00] Walk *\nCold. @walk\n\n[2026-09-30 09:15:00]\nStandup\n";
        let e = parse_entries(c);
        assert_eq!(e.len(), 2);
        assert!(has_star(&e[0].suffix));
        assert_eq!(strip_star(&e[0].suffix), "Walk");
        assert_eq!(leading_preamble(c), "note");
        let raws: Vec<String> = e.iter().map(|x| x.raw.clone()).collect();
        assert_eq!(render("note", &raws), c);
        assert_eq!(make_raw("2026-09-30 08:12:00", "Walk", true, "Cold. @walk"), e[0].raw.trim_end());
        assert_eq!(make_raw("2026-09-30 09:15:00", "", false, "Standup"), e[1].raw.trim_end());
    }

    // jnl main_test.go: parseEntries, leadingPreamble, sortedByTimestamp.
    #[test]
    fn jnl_parity_cases() {
        let e = parse_entries("[2026-05-10 08:00:00] A title\nfirst line\nsecond line\n");
        assert_eq!(e.len(), 1);
        assert_eq!((e[0].date.as_str(), e[0].ts.as_str(), e[0].suffix.as_str(), e[0].body.as_str()), ("2026-05-10", "2026-05-10 08:00:00", "A title", "first line\nsecond line"));
        let e = parse_entries("orphan line\n\n[2026-05-10 08:00:00] one\nbody1\n\n[2026-05-11 09:00:00] two\nbody2\n");
        assert_eq!(e.len(), 2);
        assert_eq!((e[0].suffix.as_str(), e[1].suffix.as_str()), ("one", "two"));
        for (content, want) in [
            ("[2026-05-10 08:00:00] x\nbody\n", ""),
            ("\n\n[2026-05-10 08:00:00] x\n", ""),
            ("loose note\n\n[2026-05-10 08:00:00] x\n", "loose note"),
            ("a\nb\n[2026-05-10 08:00:00] x\n", "a\nb"),
            ("just text\nmore text\n", "just text\nmore text"),
        ] {
            assert_eq!(leading_preamble(content), want, "{:?}", content);
        }
        let mk = |ts: &str, s: &str| RawEntry { date: ts[..10].into(), ts: ts.into(), suffix: s.into(), body: String::new(), raw: String::new() };
        let es = vec![mk("2026-05-20 09:00:00", "c"), mk("2026-05-10 08:00:00", "a"), mk("2026-05-15 12:30:00", "b")];
        let got: Vec<String> = sorted_by_timestamp(&es).iter().map(|e| e.suffix.clone()).collect();
        assert_eq!(got, vec!["a", "b", "c"]);
        assert_eq!(es[0].suffix, "c", "input untouched");
        let es = vec![mk("2026-05-10 08:00:00", "first"), mk("2026-05-10 08:00:00", "second"), mk("2026-05-10 08:00:00", "third")];
        let got: Vec<String> = sorted_by_timestamp(&es).iter().map(|e| e.suffix.clone()).collect();
        assert_eq!(got, vec!["first", "second", "third"], "stable");
        // en-dash dates are accepted and normalised (jnl 1140729)
        let e = parse_entries("[2026–01–02 08:00:00] En dash\nbody\n");
        assert_eq!(e[0].ts, "2026-01-02 08:00:00");
        assert_eq!(e[0].raw, "[2026-01-02 08:00:00] En dash\nbody\n");
    }

    // nook ParserChecks: the star marker is a standalone token.
    #[test]
    fn star_marker_is_a_token() {
        let titled = |s: &str| parse_entries(&format!("[2026-05-10 08:00:00] {}\nbody\n", s)).remove(0);
        assert!(has_star(&titled("Morning *").suffix));
        assert!(has_star(&titled("*").suffix));
        assert!(!has_star(&titled("**bold**").suffix));
        assert!(!has_star(&titled("2 * 3").suffix));
        assert!(!has_star(&titled("").suffix));
        assert_eq!(strip_star(&titled("Morning *").suffix), "Morning");
        assert_eq!(strip_star(&titled("*").suffix), "");
        assert_eq!(strip_star("**bold**"), "**bold**");
        assert!(is_header_line("[2026-05-10 08:00:00] title"));
        assert!(is_header_line("[2026-05-10 08:00:00]"));
        assert!(!is_header_line("\\[2026-05-10 08:00:00] escaped"));
        assert!(!is_header_line(" [2026-05-10 08:00:00] indented"));
        assert!(!is_header_line("[2026-05-10] no time"));
    }

    // Wander: BOM dropped, CRLF read as LF.
    #[test]
    fn bom_and_crlf() {
        let e = parse_entries(&normalised("\u{FEFF}[2026-01-02 08:00:00] T\r\nbody\r\n"));
        assert_eq!(e[0].raw, "[2026-01-02 08:00:00] T\nbody\n");
        let (_d, j) = tmp();
        std::fs::write(j.root().join("x.md"), b"\xEF\xBB\xBF[2026-01-02 08:00:00] T\r\nbody\r\n").unwrap();
        assert_eq!(j.try_read("x.md").unwrap(), "[2026-01-02 08:00:00] T\nbody\n");
    }

    #[test]
    fn split() {
        assert_eq!(split_target("[2026-10-14 08:00:00] x @work y", &["work".into()]), Some("split/work/2026/10/14.md".into()));
        assert_eq!(split_tag("x @work y", &["work".into()]), Some("work".into()));
        assert_eq!(split_target("x @workshop", &["work".into()]), None);
        assert_eq!(split_target("x @inbox", &["inbox".into()]), None);
        assert_eq!(split_target("x @Nook-Export", &["nook-export".into()]), None);
        assert_eq!(split_target("plain", &[]), None);
    }

    #[test]
    fn unicode_digits_do_not_match() {
        let c = "[٢٠٢٦-٠٩-٣٠ ٠٨:٠٠:٠٠] x\nbody\n";
        assert!(parse_entries(c).is_empty());
        assert!(check_ts("٢٠٢٦-09-30 08:00:00").is_err());
    }

    #[test]
    fn embedded_header_guard() {
        let raw = make_raw("2026-09-30 08:00:00", "t", false, "a\n[2026-09-29 07:00:00] not a header\nb\n[2026–09–29 07:00:00] dash");
        let e = parse_entries(&raw);
        assert_eq!(e.len(), 1);
        assert!(e[0].body.contains("\n\\[2026-09-29 07:00:00] not a header\n"));
        assert!(e[0].body.contains("\\[2026–09–29 07:00:00] dash"));
        assert_eq!(rebuild(&e[0]), raw);
        let raw = make_raw("2026-09-30 08:00:00", "", false, "[2026-09-29 07:00:00]");
        assert_eq!(raw, "[2026-09-30 08:00:00]\n\\[2026-09-29 07:00:00]");
    }

    #[test]
    fn reserved_and_conflicts() {
        assert!(is_reserved("Inbox.md") && is_reserved("@readme") && is_reserved("nook-export") && !is_reserved("work"));
        assert!(is_conflict_name("inbox.sync-conflict-20261001-101010-ABCDEFG.md"));
        assert!(is_conflict_name("30 (Dan's conflicted copy 2026-10-01).md"));
        assert_eq!(conflict_main_name("inbox.sync-conflict-20261001-101010-ABCDEFG.md").unwrap(), "inbox.md");
        assert_eq!(conflict_main_name("journal/2026/10/01.sync-conflict-20261001-101010-ABC.md").unwrap(), "journal/2026/10/01.md");
        assert_eq!(conflict_main_name("journal/2026/10/01 (Dan's conflicted copy 2026-10-01).md").unwrap(), "journal/2026/10/01.md");
        assert_eq!(conflict_main_name("inbox.md"), None);
        let (_d, j) = tmp();
        j.write("journal/2026/10/01.md", "[2026-10-01 08:00:00] a\n").unwrap();
        j.write("journal/2026/10/01.sync-conflict-1-2-X.md", "[2026-10-01 09:00:00] b\n").unwrap();
        j.write("inbox (conflicted copy).md", "[2026-10-01 09:00:00] b\n").unwrap();
        j.write("inbox/2026/10/01.sync-conflict-1-2-Y.md", "[2026-10-01 09:00:00] b\n").unwrap();
        j.write("readme.md", "[2026-10-01 09:00:00] b\n").unwrap();
        let files: Vec<String> = j.entry_files().into_iter().map(|f| f.0).collect();
        assert_eq!(files, vec!["journal/2026/10/01.md"]);
        assert_eq!(j.conflict_files(), vec!["inbox (conflicted copy).md", "inbox/2026/10/01.sync-conflict-1-2-Y.md", "journal/2026/10/01.sync-conflict-1-2-X.md"]);
    }

    #[test]
    fn safe_paths() {
        let r = Path::new("/j");
        assert!(safe_rel(r, "journal/2026/09/30.md").is_ok());
        assert!(safe_rel(r, "/etc/passwd").is_err());
        assert!(safe_rel(r, "../x.md").is_err());
        assert!(safe_rel(r, "journal/../../x.md").is_err());
        assert!(safe_rel(r, "a\\b.md").is_err());
        assert!(safe_rel(r, "").is_err());
        assert!(safe_entry_rel(r, "assets/x.jpg").is_err());
        assert!(safe_entry_rel(r, ".nook/templates/a.md").is_err());
        assert!(safe_entry_rel(r, ".quire/templates/a.md").is_err());
        assert!(safe_entry_rel(r, "inbox.md").is_ok());
        assert!(safe_entry_rel(r, "inbox/2026/01/02.md").is_ok());
        assert!(safe_entry_rel(r, "inbox.txt").is_err());
        assert_eq!(check_rel("./a/b.md").unwrap(), "a/b.md");
    }

    // #2: a file with invalid UTF-8 must not be mistaken for empty and overwritten.
    #[test]
    fn append_raw_refuses_unreadable_file() {
        let (d, j) = tmp();
        let p = d.path().join("inbox.md");
        let orig: &[u8] = b"[2026-09-30 08:00:00] caf\xe9\nold body\n";
        fs::write(&p, orig).unwrap();
        assert!(j.append_raw("inbox.md", "[2026-09-30 09:00:00] new\nbody").is_err());
        assert_eq!(fs::read(&p).unwrap(), orig, "file must be untouched");
        assert!(j.insert_sorted("inbox.md", "[2026-09-30 09:00:00] new\nbody").is_err());
        assert!(j.locate("inbox.md", 0, "x").is_err());
        assert!(j.try_load_all().is_err());
        assert!(j.migrate_legacy_inbox().is_err());
        assert_eq!(fs::read(&p).unwrap(), orig);
        j.append_raw("other.md", "[2026-09-30 09:00:00] new\nbody").unwrap();
        assert_eq!(j.read("other.md"), "[2026-09-30 09:00:00] new\nbody\n");
    }

    #[test]
    fn insert_sorted_keeps_all_entries() {
        let (_d, j) = tmp();
        j.write("a.md", "[2026-09-30 08:00:00] a\n\n[2026-09-30 10:00:00] c\n").unwrap();
        let i = j.insert_sorted("a.md", "[2026-09-30 09:00:00] b\n\n[2026-09-30 11:00:00] d").unwrap();
        assert_eq!(i, 1);
        let e = parse_entries(&j.read("a.md"));
        let ts: Vec<&str> = e.iter().map(|x| &x.ts[11..13]).collect();
        assert_eq!(ts, vec!["08", "09", "10", "11"]);
        assert!(j.insert_sorted("a.md", "no header").is_err());
        let r = j.insert_entries("a.md", &["[2026-09-30 08:00:00] a".into(), "[2026-09-30 08:00:00] a2".into()], true).unwrap();
        assert_eq!(r, vec![None, Some(1)]);
    }

    #[test]
    fn make_raw_collapses_title_whitespace() {
        let raw = make_raw("2026-09-30 08:00:00", "line1\n  line2\t x", false, "body");
        let e = parse_entries(&raw);
        assert_eq!(e.len(), 1);
        assert_eq!(e[0].suffix, "line1 line2 x");
        assert_eq!(e[0].body, "body");
    }

    #[test]
    fn ts_check() {
        assert!(check_ts("2026-09-30 08:00:00").is_ok());
        assert!(check_ts("2026–09–30 08:00:00").is_err());
        assert!(check_ts("2026-09-30 08:00").is_err());
        assert!(check_ts("2026-09").is_err());
    }

    #[test]
    fn link_resolution_and_rebase() {
        let f = "journal/2026/09/30.md";
        assert_eq!(resolve_link(f, "assets/2026/09/a.jpg").unwrap(), "assets/2026/09/a.jpg");
        assert_eq!(resolve_link(f, "../../../assets/2026/09/a.jpg").unwrap(), "assets/2026/09/a.jpg");
        assert_eq!(resolve_link(f, "./x.jpg").unwrap(), "journal/2026/09/x.jpg");
        assert_eq!(resolve_link(f, "x.jpg").unwrap(), "journal/2026/09/x.jpg");
        assert_eq!(resolve_link("inbox.md", "../x.jpg"), None);
        assert_eq!(resolve_link(f, "https://x/y.jpg"), None);
        let all = resolve_link_all(f, "assets/a%20b.jpg");
        assert!(all.contains(&"assets/a b.jpg".to_string()) && all.contains(&"journal/2026/09/assets/a%20b.jpg".to_string()));

        let raw = "[2026-09-30 08:00:00]\n![](../../../assets/2026/09/a.jpg) [f](<../../../assets/2026/09/b c.pdf> \"t\") ![](assets/2026/09/d.jpg) [w](https://x.org/../a) ![](../../../notes/x.jpg)";
        let out = rebase_links(raw, f, "inbox.md");
        assert_eq!(out, "[2026-09-30 08:00:00]\n![](assets/2026/09/a.jpg) [f](<assets/2026/09/b c.pdf> \"t\") ![](assets/2026/09/d.jpg) [w](https://x.org/../a) ![](../../../notes/x.jpg)");
        assert_eq!(rebase_links(&out, f, "inbox.md"), out);
    }

    // ----- the inbox folder -----

    #[test]
    fn day_file_dates() {
        assert_eq!(day_file_date("inbox/2026/10/14.md").as_deref(), Some("2026-10-14"));
        assert_eq!(day_file_date("journal/2026/10/14.md").as_deref(), Some("2026-10-14"));
        assert_eq!(day_file_date("split/work/2026/10/14.md").as_deref(), Some("2026-10-14"));
        for rel in ["inbox.md", "work.md", "inbox/preamble.md", "split/work/preamble.md", "journal/2026/10/14 (conflict).md", "journal/2026/10.md", "journal/x/2026/10/14.md"] {
            assert_eq!(day_file_date(rel), None, "{}", rel);
        }
        assert_eq!(day_file_like("split/work/2026/10/20.md", "2026-10-14").as_deref(), Some("split/work/2026/10/14.md"));
        assert_eq!(day_file_like("inbox/2026/10/20.md", "2026-10-14").as_deref(), Some("inbox/2026/10/14.md"));
        assert_eq!(day_file_like("work.md", "2026-10-14"), None);
    }

    #[test]
    fn drafts_live_in_day_files() {
        let (_d, j) = tmp();
        let w = j.new_draft("2026-09-30 09:00:00", "Second", false, "b").unwrap();
        assert_eq!(w.file, "inbox/2026/09/30.md");
        let w2 = j.new_draft("2026-09-30 08:00:00", "First", false, "a").unwrap();
        assert_eq!((w2.file.as_str(), w2.index), ("inbox/2026/09/30.md", 0), "kept in time order");
        assert!(j.new_draft("2026-09-30 08:00:00", "", false, "  ").is_err());
        let all = j.load_all();
        assert_eq!(all.len(), 2);
        assert!(all.iter().all(|e| e.source == "inbox"));
        assert_eq!(all[0].title, "First");
        assert_eq!(j.inbox_files(), vec!["inbox/2026/09/30.md"]);

        // Filing removes it from the day file; the emptied file goes away.
        let target = j.file_draft(&w2.file, 0, &w2.raw, &[]).unwrap();
        assert_eq!(target, "journal/2026/09/30.md");
        let rest = j.load_file("inbox/2026/09/30.md");
        assert_eq!(rest.len(), 1);
        j.file_draft(&rest[0].file, rest[0].index, &rest[0].raw, &["work".into()]).unwrap();
        assert!(!j.is_file("inbox/2026/09/30.md"), "an empty day file is deleted");
        assert_eq!(j.load_file("journal/2026/09/30.md").len(), 2);

        // Return to inbox lands in the entry's own day.
        let filed = j.load_file("journal/2026/09/30.md");
        let back = j.unfile_entry(&filed[0].file, 0, &filed[0].raw).unwrap();
        assert_eq!(back.file, "inbox/2026/09/30.md");
        assert!(j.unfile_entry(&back.file, back.index, &back.raw).is_err());
        assert!(j.file_draft("journal/2026/09/30.md", 0, "x", &[]).is_err());
    }

    #[test]
    fn retiming_moves_between_day_files_in_both_trees() {
        let (_d, j) = tmp();
        let w = j.new_draft("2026-09-30 08:00:00", "t", false, "body").unwrap();
        let moved = j.update_entry(&w.file, w.index, &w.raw, "2026-10-01 08:00:00", "t", false, "body").unwrap();
        assert_eq!(moved.file, "inbox/2026/10/01.md");
        assert!(!j.is_file("inbox/2026/09/30.md"));
        // Same day, new time: re-sorted in place.
        j.new_draft("2026-10-01 07:00:00", "early", false, "x").unwrap();
        let es = j.load_file("inbox/2026/10/01.md");
        assert_eq!(es[1].title, "t");
        let r = j.update_entry(&es[1].file, es[1].index, &es[1].raw, "2026-10-01 06:00:00", "t", false, "body").unwrap();
        assert_eq!(r.index, 0);
        // Journal days behave the same.
        j.write("journal/2026/10/01.md", "[2026-10-01 08:00:00] f\nb\n").unwrap();
        let r = j.update_entry("journal/2026/10/01.md", 0, "[2026-10-01 08:00:00] f\nb", "2026-10-02 08:00:00", "f", false, "b").unwrap();
        assert_eq!(r.file, "journal/2026/10/02.md");
        assert!(!j.is_file("journal/2026/10/01.md"));
        // A split journal keeps its file; a legacy inbox.md edits in place.
        j.write("work.md", "[2026-10-01 08:00:00] w\n").unwrap();
        assert_eq!(j.update_entry("work.md", 0, "[2026-10-01 08:00:00] w", "2026-10-05 08:00:00", "w", false, "").unwrap().file, "work.md");
        j.write("inbox.md", "[2026-10-01 08:00:00] legacy\n").unwrap();
        assert_eq!(j.update_entry("inbox.md", 0, "[2026-10-01 08:00:00] legacy", "2026-10-05 08:00:00", "legacy", false, "").unwrap().file, "inbox.md");
        assert!(j.update_entry("assets/x.md", 0, "", "2026-10-05 08:00:00", "", false, "").is_err());
    }

    #[test]
    fn delete_and_import_text() {
        let (_d, j) = tmp();
        let w = j.new_draft("2026-09-30 08:00:00", "t", false, "body").unwrap();
        j.delete_entry(&w.file, w.index, &w.raw).unwrap();
        assert!(!j.is_file(&w.file));
        assert_eq!(j.import_text("plain words", "2026-09-30 09:00:00").unwrap(), 1);
        assert_eq!(j.import_text("[2026-09-01 08:00:00] a\n\n[2026-09-02 08:00:00] b\n", "2026-09-30 09:00:00").unwrap(), 2);
        assert_eq!(j.import_text("  ", "2026-09-30 09:00:00").unwrap(), 0);
        assert_eq!(j.inbox_files(), vec!["inbox/2026/09/01.md", "inbox/2026/09/02.md", "inbox/2026/09/30.md"]);
    }

    #[test]
    fn split_journals_live_in_day_files() {
        let (_d, j) = tmp();
        let tags = vec!["work".to_string()];
        let w = j.new_draft("2026-10-14 09:00:00", "Standup", false, "notes @work").unwrap();
        assert_eq!(j.file_draft(&w.file, w.index, &w.raw, &tags).unwrap(), "split/work/2026/10/14.md");
        let e = &j.load_file("split/work/2026/10/14.md")[0];
        assert_eq!((e.source.as_str(), e.split.as_deref()), ("split", Some("work")));
        assert_eq!(j.load_all().iter().filter(|e| e.split.as_deref() == Some("work")).count(), 1);
        // Retimed to another day: moves within the same split journal.
        let moved = j.update_entry(&e.file, e.index, &e.raw, "2026-10-15 09:00:00", "Standup", false, "notes @work").unwrap();
        assert_eq!(moved.file, "split/work/2026/10/15.md");
        assert!(!j.is_file("split/work/2026/10/14.md"), "an emptied split day file is deleted");
        j.delete_entry(&moved.file, moved.index, &moved.raw).unwrap();
        assert!(!j.is_file("split/work/2026/10/15.md"));
        assert_eq!(split_tag_of("split/work/2026/10/15.md").as_deref(), Some("work"));
        assert_eq!(split_tag_of("work.md").as_deref(), Some("work"));
        assert_eq!(split_tag_of("inbox.md"), None);
        assert_eq!(split_tag_of("journal/2026/10/15.md"), None);
        assert!(is_split_preamble("split/work/preamble.md") && !is_day_file("split/work/preamble.md"));
    }

    #[test]
    fn legacy_split_files_fold_into_split_folders() {
        let (_d, j) = tmp();
        let text = "Work log\n\n[2026-10-14 09:00:00] Standup @work\n![](./assets/a.jpg)\n\n[2026-10-13 17:00:00] Retro\nGood week.\n\nSecond paragraph.\n";
        j.write("work.md", text).unwrap();
        j.write("ideas.md", "Just notes, no entries.\n").unwrap();
        j.write("inbox.md", "").unwrap();
        let rep = j.migrate_legacy_splits().unwrap().unwrap();
        assert_eq!((rep.journals, rep.moved, rep.skipped), (1, 2, 0));
        assert!(rep.backups[0].starts_with(".quire/migration/split-work-"), "{:?}", rep.backups);
        assert_eq!(j.read(&rep.backups[0]), text, "the original is kept byte for byte");
        assert!(!j.is_file("work.md"));
        assert_eq!(j.read("split/work/2026/10/14.md"), "[2026-10-14 09:00:00] Standup @work\n![](assets/a.jpg)\n");
        assert_eq!(j.read("split/work/2026/10/13.md"), "[2026-10-13 17:00:00] Retro\nGood week.\n\nSecond paragraph.\n");
        assert_eq!(j.read("split/work/preamble.md"), "Work log\n");
        assert_eq!(j.read("ideas.md"), "Just notes, no entries.\n", "a root .md with no entries is not a journal");
        assert!(j.is_file("inbox.md"), "reserved names are never split journals");
        assert_eq!(j.load_all().len(), 2, "preamble.md is not an entry file");
        assert!(j.migrate_legacy_splits().unwrap().is_none());
        // jnl files another @work entry into work.md: merged, duplicates skipped.
        j.write("work.md", "[2026-10-14 09:00:00] Standup @work\n![](assets/a.jpg)\n\n[2026-10-15 08:00:00] New @work\n").unwrap();
        let rep = j.migrate_legacy_splits().unwrap().unwrap();
        assert_eq!((rep.moved, rep.skipped), (1, 1));
        assert_eq!(j.load_file("split/work/2026/10/15.md").len(), 1);
    }

    #[test]
    fn legacy_inbox_migrates_once_and_merges_later() {
        let (_d, j) = tmp();
        let text = "# notes\n\n[2026-01-05 09:00:00] Second day\nBody two.\n\n[2026-01-04 22:10:00]\nLate note @tag\n\n[2026-01-05 07:30:00] Early *\n- a\n";
        j.write("inbox.md", text).unwrap();
        j.write(".nook/searches.json", "[]").unwrap();
        let rep = j.migrate_legacy_inbox().unwrap().unwrap();
        assert_eq!((rep.moved, rep.skipped), (3, 0));
        assert!(rep.backup.starts_with(".quire/migration/inbox-"), "{}", rep.backup);
        assert!(!j.is_file("inbox.md"));
        assert_eq!(j.read(&rep.backup), text, "the original is kept byte for byte");
        assert!(j.is_file(".quire/searches.json") && !j.is_dir(".nook"), "sidecar renamed on first write");
        assert_eq!(j.read("inbox/2026/01/04.md"), "[2026-01-04 22:10:00]\nLate note @tag\n");
        assert_eq!(j.read("inbox/2026/01/05.md"), "[2026-01-05 07:30:00] Early *\n- a\n\n[2026-01-05 09:00:00] Second day\nBody two.\n");
        assert_eq!(j.read("inbox/preamble.md"), "# notes\n");
        assert_eq!(j.load_all().len(), 3, "preamble.md is not an entry file");
        assert!(j.migrate_legacy_inbox().unwrap().is_none());
        // An older app writes a fresh inbox.md: merged, duplicates skipped.
        j.write("inbox.md", "[2026-01-05 09:00:00] Second day\nBody two.\n\n[2026-01-06 10:00:00] New\nx\n").unwrap();
        let rep = j.migrate_legacy_inbox().unwrap().unwrap();
        assert_eq!((rep.moved, rep.skipped), (1, 1));
        assert_eq!(j.load_file("inbox/2026/01/05.md").len(), 2);
        assert_eq!(j.read("inbox/2026/01/06.md"), "[2026-01-06 10:00:00] New\nx\n");
        // Empty inbox.md: nothing to move, still tidied away.
        j.write("inbox.md", "\n").unwrap();
        let rep = j.migrate_legacy_inbox().unwrap().unwrap();
        assert_eq!(rep.moved, 0);
        assert!(!j.is_file("inbox.md"));
    }

    #[test]
    fn sidecar_rules() {
        let (_d, j) = tmp();
        assert_eq!(j.sidecar(), ".quire");
        j.write(".nook/a.json", "1").unwrap();
        assert_eq!(j.sidecar(), ".nook");
        assert_eq!(j.sidecar_mut().unwrap(), ".quire");
        assert!(j.is_file(".quire/a.json") && !j.is_dir(".nook"));
        // Both present (a sync race): read .quire, never rename over it.
        j.write(".nook/b.json", "2").unwrap();
        assert_eq!(j.sidecar(), ".quire");
        j.sidecar_mut().unwrap();
        assert!(j.is_file(".nook/b.json"));
        assert_eq!(sidecar_dir_path(j.root()), j.root().join(".quire"));
    }
}
