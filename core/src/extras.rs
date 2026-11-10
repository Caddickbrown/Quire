//! Everything beyond read/write of entries: templates and saved searches
//! (Quire's sidecar in `.quire/`), media in `assets/`, cleanup, export,
//! backup, imports and tag review. All of it keeps the journal layer in
//! jnl's format; only the sidecar and `assets/` are Quire's own.
//!
//! Entry files and sidecars go through the `Journal`'s vault. Backups,
//! imports from other folders and attaching files need real paths and ask
//! the journal for its local root; they are native on shells without one.

use crate::journal::*;
use chrono::{Local, NaiveDate, NaiveDateTime, TimeZone};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

// ---------- time ----------

pub const TS_FMT: &str = "%Y-%m-%d %H:%M:%S";

/// Local time now as `YYYY-MM-DD HH:MM:SS`.
pub fn now_local() -> String {
    Local::now().format(TS_FMT).to_string()
}

/// `ts` plus `secs` seconds (ts must pass check_ts).
pub fn add_secs(ts: &str, secs: i64) -> Result<String, String> {
    let t = NaiveDateTime::parse_from_str(ts, TS_FMT).map_err(|e| format!("Bad timestamp {:?}: {}", ts, e))?;
    Ok((t + chrono::Duration::seconds(secs)).format(TS_FMT).to_string())
}

/// Seconds since a local `YYYY-MM-DD HH:MM:SS` (None if unparsable).
pub fn secs_since(ts: &str) -> Option<i64> {
    let t = NaiveDateTime::parse_from_str(ts, TS_FMT).ok()?;
    Some((Local::now().naive_local() - t).num_seconds())
}

// ---------- templates (<sidecar>/templates/*.md) ----------

#[derive(Serialize)]
pub struct Template {
    pub name: String,
    pub body: String,
}

pub fn templates_rel(j: &Journal) -> String {
    format!("{}/templates", j.sidecar())
}

/// A template name becomes `<name>.md` in the sidecar's templates/: no separators, no `..`.
pub fn check_template_name(name: &str) -> Result<String, String> {
    let n = name.trim();
    if n.is_empty() {
        return Err("A template needs a name".into());
    }
    if n.contains('/') || n.contains('\\') || n.contains("..") || n.contains('\0') {
        return Err("A template name can't contain / \\ or ..".into());
    }
    Ok(n.to_string())
}

pub fn list_templates(j: &Journal) -> Vec<Template> {
    let dir = templates_rel(j);
    let mut out = Vec::new();
    for it in j.list(&dir) {
        if it.is_file && it.name.ends_with(".md") && !it.name.starts_with('.') {
            out.push(Template { name: it.name.trim_end_matches(".md").to_string(), body: j.read(&format!("{}/{}", dir, it.name)) });
        }
    }
    out.sort_by_key(|a| a.name.to_lowercase());
    out
}

pub fn save_template(j: &Journal, name: &str, body: &str) -> Result<(), String> {
    let name = check_template_name(name)?;
    j.write(&format!("{}/templates/{}.md", j.sidecar_mut()?, name), body)
}

pub fn delete_template(j: &Journal, name: &str) -> Result<(), String> {
    let name = check_template_name(name)?;
    match j.remove(&format!("{}/templates/{}.md", j.sidecar_mut()?, name))? {
        true => Ok(()),
        false => Err(format!("No template called “{}”", name)),
    }
}

pub fn rename_template(j: &Journal, from: &str, to: &str) -> Result<(), String> {
    let from = check_template_name(from)?;
    let to = check_template_name(to)?;
    let dir = format!("{}/templates", j.sidecar_mut()?);
    let (a, b) = (format!("{}/{}.md", dir, from), format!("{}/{}.md", dir, to));
    if a != b && j.is_file(&b) {
        return Err(format!("A template called “{}” already exists", to));
    }
    j.vault().rename(&a, &b)
}

pub const STARTER_TEMPLATE: &str = "What made today worth writing about?\n\n- [ ] One thing to remember\n- [ ] One thing to let go\n\n{{weekday}} {{date}}\n";

// ---------- saved searches (<sidecar>/searches.json) ----------

#[derive(Serialize, Deserialize, Clone)]
pub struct SavedSearch {
    pub name: String,
    pub query: String,
}

pub fn load_searches(j: &Journal) -> Vec<SavedSearch> {
    serde_json::from_str(&j.read(&format!("{}/searches.json", j.sidecar()))).unwrap_or_default()
}

pub fn save_searches(j: &Journal, list: &[SavedSearch]) -> Result<(), String> {
    j.write(&format!("{}/searches.json", j.sidecar_mut()?), &serde_json::to_string_pretty(list).map_err(|e| e.to_string())?)
}

// ---------- filesystem helpers ----------

/// Every regular file under `dir`, never following symlinked folders.
fn walk_all(dir: &Path, out: &mut Vec<PathBuf>) {
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                walk_all(&e.path(), out);
            } else if ft.is_file() {
                out.push(e.path());
            }
        }
    }
}

/// `walk_all`, leaving out anything whose name starts with a dot, folders
/// included.
fn walk_visible(dir: &Path, out: &mut Vec<PathBuf>) {
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            if e.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                walk_visible(&e.path(), out);
            } else if ft.is_file() {
                out.push(e.path());
            }
        }
    }
}

// ---------- media (assets/) ----------

pub fn media_kind(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().unwrap_or("").to_lowercase();
    match ext.as_str() {
        "jpg" | "jpeg" | "png" | "gif" | "webp" | "heic" | "bmp" | "svg" | "avif" => "image",
        "mp4" | "mov" | "m4v" | "webm" | "mkv" => "video",
        "m4a" | "mp3" | "wav" | "aac" | "ogg" | "opus" | "flac" | "caf" => "audio",
        _ => "file",
    }
}

/// What links point at: every interpretation of every local link in every
/// file that might reference media, plus the concatenated text for the
/// substring check. Read strictly: an unreadable file would otherwise make
/// every asset it links look orphaned.
pub struct LinkIndex {
    /// Resolved root-relative path → entry files that link it (rule 6 and
    /// the alternative interpretation both count).
    pub refs: HashMap<String, Vec<String>>,
    pub all_text: String,
}

impl LinkIndex {
    pub fn is_referenced(&self, rel: &str) -> bool {
        self.refs.contains_key(rel) || self.all_text.contains(rel)
    }
}

/// Files scanned for media references: entry files plus reserved root .md
/// files (transfer, export…), conflict copies and templates.
fn reference_files(j: &Journal) -> Vec<String> {
    let mut v: Vec<String> = j.entry_files().into_iter().map(|f| f.0).collect();
    if j.is_file(INBOX_PREAMBLE) {
        v.push(INBOX_PREAMBLE.to_string());
    }
    let mut extra: Vec<String> = j
        .list("")
        .into_iter()
        .filter(|it| it.is_file && it.name.to_lowercase().ends_with(".md") && !v.contains(&it.name))
        .map(|it| it.name)
        .collect();
    extra.sort();
    v.extend(extra);
    for c in j.conflict_files() {
        if !v.contains(&c) {
            v.push(c);
        }
    }
    v.extend(j.walk_files(&templates_rel(j)));
    v
}

pub fn link_index(j: &Journal) -> Result<LinkIndex, String> {
    let mut refs: HashMap<String, Vec<String>> = HashMap::new();
    let mut all_text = String::new();
    for rel in reference_files(j) {
        let text = j.try_read(&rel)?;
        for p in link_targets(&text) {
            for r in resolve_link_all(&rel, &p) {
                let owners = refs.entry(r).or_default();
                if !owners.contains(&rel) {
                    owners.push(rel.clone());
                }
            }
        }
        all_text.push_str(&text);
        all_text.push('\n');
    }
    Ok(LinkIndex { refs, all_text })
}

/// Back-compat: the set of referenced root-relative paths.
#[allow(dead_code)]
pub fn referenced_assets(j: &Journal) -> Result<HashSet<String>, String> {
    Ok(link_index(j)?.refs.into_keys().filter(|k| k.starts_with("assets/")).collect())
}

#[derive(Serialize)]
pub struct Asset {
    pub rel: String,
    pub kind: &'static str,
    pub bytes: u64,
    pub referenced: bool,
    /// Root-relative files whose links resolve to this asset.
    pub owners: Vec<String>,
}

pub fn list_assets(j: &Journal) -> Result<Vec<Asset>, String> {
    let idx = link_index(j)?;
    let orphans: HashSet<_> = crate::orphan_media(j)?.into_iter().collect();
    Ok(j.walk_files("assets")
        .into_iter()
        .filter(|rel| !rel.rsplit('/').next().unwrap_or(rel).starts_with('.'))
        .map(|rel| Asset {
            kind: media_kind(&rel),
            bytes: j.len(&rel),
            referenced: !orphans.contains(&rel),
            owners: idx.refs.get(&rel).cloned().unwrap_or_default(),
            rel,
        })
        .collect())
}

/// Copy a file into `assets/YYYY/MM/DD-HHMMSS[-n].ext` and return its
/// root-relative path.
pub fn attach_rel(j: &Journal, src: &Path, ts: &str) -> Result<String, String> {
    check_ts(ts)?;
    let root = j.local()?;
    let ext: String = src
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();
    let dot = if ext.is_empty() { String::new() } else { format!(".{}", ext) };
    let stamp = ts.replace(['-', ':', ' '], "");
    let (y, m) = (&ts[..4], &ts[5..7]);
    let dir = root.join("assets").join(y).join(m);
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut name = format!("{}-{}{}", &stamp[6..8], &stamp[8..], dot);
    let mut n = 2;
    while dir.join(&name).exists() {
        name = format!("{}-{}-{}{}", &stamp[6..8], &stamp[8..], n, dot);
        n += 1;
    }
    let dest = dir.join(&name);
    fs::copy(src, &dest).map_err(|e| e.to_string())?;
    // fs::copy keeps the source's mode; temp files are 0600, which sync tools
    // and other apps sharing the folder may not be able to read.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&dest, fs::Permissions::from_mode(0o644));
    }
    Ok(format!("assets/{}/{}/{}", y, m, name))
}

/// Copy a file into assets/ and return the markdown to insert. Links are
/// always base-relative (`assets/…`), as Nook writes them, whichever file
/// the entry lives in (`_entry_file` is kept for API compatibility).
pub fn attach(j: &Journal, src: &Path, ts: &str, _entry_file: &str) -> Result<String, String> {
    let rel = attach_rel(j, src, ts)?;
    let name = rel.rsplit('/').next().unwrap_or(&rel).to_string();
    Ok(if media_kind(&rel) == "file" { format!("[{}]({})", name, rel) } else { format!("![]({})", rel) })
}

/// A file `attach_media` / `attach_bytes` stored under assets/.
#[derive(Debug, Clone)]
pub struct Attached {
    /// The markdown to insert.
    pub link: String,
    /// Root-relative path of the stored file.
    pub rel: String,
    /// Video or audio that Data Saver should compress in the background
    /// (`media::compress_file_in_place`, then `media::record_saving`).
    pub compress_later: bool,
}

fn attached(link: String, saver: bool) -> Attached {
    let rel = link.rsplit_once("](").map(|(_, t)| t.trim_end_matches(')').to_string()).unwrap_or_default();
    let ext = rel.rsplit('.').next().unwrap_or("");
    let compress_later = saver && crate::media::is_compressible_av(ext) && crate::media::tools().ffmpeg;
    Attached { link, rel, compress_later }
}

/// Attach in-memory bytes (a clipboard image, say) the way every shell does:
/// HEIC becomes JPEG, Data Saver recompresses images when that is smaller
/// and counts the saving in this device's ledger. `ext` names the type; the
/// stored name comes from `ts`. Local folders only.
pub fn attach_bytes(j: &Journal, bytes: &[u8], ext: &str, ts: &str, saver: bool, device: &str) -> Result<Attached, String> {
    if bytes.is_empty() {
        return Err("Nothing to attach".into());
    }
    let ext: String = ext.trim().trim_start_matches('.').to_lowercase().chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    let ext = if ext.is_empty() { "png".to_string() } else { ext };
    let image = crate::media::is_heic(&ext) || crate::media::is_compressible_image(&ext);
    let (out, out_ext) = if image { crate::media::on_attach(bytes, &ext, saver) } else { (bytes.to_vec(), ext) };
    let tmp = tempfile::Builder::new().prefix(".quire-attach-").suffix(&format!(".{}", out_ext.to_lowercase())).tempfile().map_err(|e| e.to_string())?;
    fs::write(tmp.path(), &out).map_err(|e| e.to_string())?;
    let a = attached(attach(j, tmp.path(), ts, "")?, saver);
    if image && saver {
        let root = j.local()?;
        crate::media::record_saving(root, device, &root.join(&a.rel), bytes.len() as i64 - out.len() as i64);
    }
    Ok(a)
}

/// Attach a file from disk: images and HEIC through `attach_bytes`, anything
/// else copied as it is.
pub fn attach_media(j: &Journal, src: &Path, ts: &str, saver: bool, device: &str) -> Result<Attached, String> {
    let ext = src.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
    if crate::media::is_heic(&ext) || crate::media::is_compressible_image(&ext) {
        let bytes = fs::read(src).map_err(|e| format!("Can't read {}: {}", src.display(), e))?;
        return attach_bytes(j, &bytes, &ext, ts, saver, device);
    }
    Ok(attached(attach(j, src, ts, "")?, saver))
}

/// Clear unused media from assets/, retaining verified recovery copies.
pub fn delete_orphans(j: &Journal) -> Result<usize, String> {
    let offered = crate::orphan_media(j)?;
    crate::archive_orphan_media(j, &offered).map(|(count, _)| count)
}

/// Delete one file under assets/.
pub fn delete_asset(j: &Journal, rel: &str) -> Result<(), String> {
    let rel = check_rel(rel)?;
    if !rel.starts_with("assets/") {
        return Err("Only files under assets/ can be deleted here".into());
    }
    if j.is_dir(&rel) {
        return Err("That's a folder, not an asset".into());
    }
    match j.remove(&rel)? {
        true => Ok(()),
        false => Err("No such asset".into()),
    }
}

// ---------- cleanup (jnl's cmdCleanup + Nook's dedupe) ----------

#[derive(Serialize, Default, Debug)]
pub struct CleanupReport {
    pub formatted: usize,
    pub reordered: usize,
    pub deduped: usize,
    pub extracted: usize,
    /// Entries moved to the day file their header dates them to (pasted
    /// under the wrong day).
    pub moved: usize,
    /// Files that couldn't be read or written; cleanup carries on past them.
    pub errors: Vec<String>,
    /// Back-compat aliases: files = day files scanned, formatting = formatted,
    /// duplicates = deduped.
    pub files: usize,
    pub formatting: usize,
    pub duplicates: usize,
}

// The target may hold balanced brackets (`image(1).jpg`), as LINK_TARGET_RE allows.
static LINK_SPAN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"!?\[[^\]]*\]\((?:[^()]|\([^()]*\))+\)").unwrap());

fn punct(s: &str) -> String {
    s.replace("...", "\u{2026}").replace('\u{2019}', "'").replace(['\u{201C}', '\u{201D}'], "\"")
}

/// `...`→`…`, `’`→`'`, `“”`→`"`, outside link and image spans.
pub fn fix_punctuation(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut last = 0;
    for m in LINK_SPAN_RE.find_iter(s) {
        out.push_str(&punct(&s[last..m.start()]));
        out.push_str(m.as_str());
        last = m.end();
    }
    out.push_str(&punct(&s[last..]));
    out
}

/// Stable sort by ts then drop exact duplicates (raw.trim_end), keeping the
/// first. Returns (entries, order_changed, removed).
fn sort_dedupe(entries: Vec<RawEntry>) -> (Vec<RawEntry>, bool, usize) {
    let before: Vec<String> = entries.iter().map(|e| e.ts.clone()).collect();
    let mut sorted = entries;
    sorted.sort_by(|a, b| a.ts.cmp(&b.ts));
    let reordered = sorted.iter().zip(before.iter()).any(|(a, b)| &a.ts != b);
    let mut seen = HashSet::new();
    let n = sorted.len();
    let kept: Vec<RawEntry> = sorted.into_iter().filter(|e| seen.insert(e.raw.trim_end().to_string())).collect();
    let removed = n - kept.len();
    (kept, reordered, removed)
}

/// Move every entry whose header date isn't its day file's date into the
/// day file of that date in the same tree: the header is the date, the file
/// name only stores it. Destination first, skipping an entry already there
/// (counted as a duplicate), then removed from the source, so a failure
/// leaves a duplicate, never a loss.
fn rehome(j: &Journal, rep: &mut CleanupReport) {
    for (rel, _, _) in j.entry_files() {
        let Some(day) = day_file_date(&rel) else { continue };
        let content = match j.try_read(&rel) {
            Ok(s) => s,
            Err(e) => {
                // The passes below report unreadable inbox and journal files.
                if rel.starts_with("split/") {
                    rep.errors.push(e);
                }
                continue;
            }
        };
        let mut groups: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        for e in parse_entries(&content) {
            if e.date == day {
                continue;
            }
            if let Some(dest) = day_file_like(&rel, &e.date) {
                let raw = e.raw.trim_end().to_string();
                let moved = rebase_links(&raw, &rel, &dest);
                groups.entry(dest).or_default().push((raw, moved));
            }
        }
        let mut gone: HashMap<String, usize> = HashMap::new();
        for (dest, items) in &groups {
            let raws: Vec<String> = items.iter().map(|x| x.1.clone()).collect();
            match j.insert_entries(dest, &raws, true) {
                Ok(placed) => {
                    for ((k, _), at) in items.iter().zip(placed) {
                        *gone.entry(k.clone()).or_default() += 1;
                        if at.is_some() {
                            rep.moved += 1;
                        } else {
                            rep.deduped += 1;
                        }
                    }
                }
                Err(e) => rep.errors.push(format!("{} → {}: {}", rel, dest, e)),
            }
        }
        if gone.is_empty() {
            continue;
        }
        if let Err(e) = remove_gone(j, &rel, &mut gone) {
            rep.errors.push(format!("{}: {}", rel, e));
        }
    }
}

/// Remove Finder's `.DS_Store` files throughout the journal, including assets
/// and hidden folders. Vault listings exclude symlinks. Failures are reported
/// individually so other folders can still be cleaned.
pub fn remove_ds_store(j: &Journal) -> (usize, Vec<String>) {
    let mut removed = 0;
    let mut errors = Vec::new();
    let mut folders = vec![String::new()];
    while let Some(folder) = folders.pop() {
        let items = match j.vault().list(&folder) {
            Ok(items) => items,
            Err(e) => {
                errors.push(e);
                continue;
            }
        };
        for item in items {
            let rel = if folder.is_empty() {
                item.name.clone()
            } else {
                format!("{folder}/{}", item.name)
            };
            if item.is_dir {
                folders.push(rel);
            } else if item.is_file && item.name == ".DS_Store" {
                match j.vault().remove(&rel) {
                    Ok(true) => removed += 1,
                    Ok(false) => {}
                    Err(e) => errors.push(e),
                }
            }
        }
    }
    (removed, errors)
}

pub fn cleanup(j: &Journal, split_tags: &[String]) -> Result<CleanupReport, String> {
    let mut rep = CleanupReport::default();
    rehome(j, &mut rep);
    for rel in j.walk_md(JOURNAL_DIR) {
        rep.files += 1;
        let orig = match j.try_read(&rel) {
            Ok(s) => s,
            Err(e) => {
                rep.errors.push(e);
                continue;
            }
        };
        let fixed = fix_punctuation(&orig);
        let formatted = fixed != orig;
        let pre = leading_preamble(&fixed);
        let mut kept = Vec::new();
        let mut extract: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for e in parse_entries(&fixed) {
            match split_target(&e.raw, split_tags) {
                Some(t) => extract.entry(t.clone()).or_default().push(rebuild(&RawEntry {
                    raw: String::new(),
                    body: rebase_links(&e.body, &rel, &t),
                    suffix: rebase_links(&e.suffix, &rel, &t),
                    ..e
                })),
                None => kept.push(e),
            }
        }
        // Destinations first: a failure leaves the entry where it was.
        let mut extracted = 0;
        let mut failed = false;
        for (target, raws) in &extract {
            match j.insert_entries(target, raws, true) {
                Ok(_) => extracted += raws.len(),
                Err(e) => {
                    rep.errors.push(format!("{} → {}: {}", rel, target, e));
                    failed = true;
                }
            }
        }
        if failed {
            // Leave this file's entries in place (any that did land are
            // skipped as duplicates on the next run).
            if formatted {
                if let Err(e) = j.replace_text(&rel, &orig, &fixed) {
                    rep.errors.push(e);
                } else {
                    rep.formatted += 1;
                }
            }
            continue;
        }
        let (kept, reordered, removed) = sort_dedupe(kept);
        let structural = extracted > 0 || reordered || removed > 0;
        let res = if structural {
            let raws: Vec<String> = kept.into_iter().map(|e| e.raw).collect();
            j.replace_text(&rel, &orig, &render(&pre, &raws))
        } else if formatted {
            j.replace_text(&rel, &orig, &fixed)
        } else {
            Ok(())
        };
        match res {
            Ok(()) => {
                rep.formatted += formatted as usize;
                rep.reordered += reordered as usize;
                rep.deduped += removed;
                rep.extracted += extracted;
            }
            Err(e) => rep.errors.push(format!("{}: {}", rel, e)),
        }
    }
    // Inbox files: sort + dedupe only.
    for rel in j.inbox_files() {
        match j.try_read(&rel) {
            Ok(content) => {
                let pre = leading_preamble(&content);
                let (kept, reordered, removed) = sort_dedupe(parse_entries(&content));
                if reordered || removed > 0 {
                    let raws: Vec<String> = kept.into_iter().map(|e| e.raw).collect();
                    match j.replace_text(&rel, &content, &render(&pre, &raws)) {
                        Ok(()) => {
                            rep.reordered += reordered as usize;
                            rep.deduped += removed;
                        }
                        Err(e) => rep.errors.push(format!("{}: {}", rel, e)),
                    }
                }
            }
            Err(e) => rep.errors.push(e),
        }
    }
    rep.formatting = rep.formatted;
    rep.duplicates = rep.deduped;
    Ok(rep)
}

/// Sort every inbox file by timestamp (stable). Writes only the files whose
/// order changed; returns whether any did.
pub fn sort_inbox(j: &Journal) -> Result<bool, String> {
    let mut changed = false;
    for rel in j.inbox_files() {
        let content = j.try_read(&rel)?;
        let pre = leading_preamble(&content);
        let es = parse_entries(&content);
        let before: Vec<String> = es.iter().map(|e| e.ts.clone()).collect();
        let sorted = sorted_by_timestamp(&es);
        if sorted.iter().zip(before.iter()).all(|(a, b)| &a.ts == b) {
            continue;
        }
        let raws: Vec<String> = sorted.into_iter().map(|e| e.raw).collect();
        j.replace_text(&rel, &content, &render(&pre, &raws))?;
        changed = true;
    }
    Ok(changed)
}

// ---------- moving entries between files ----------

/// Remove from `content` (re-read fresh) the entries whose trim_end raw is in
/// the multiset `gone`. Returns the new rendered text, or None if nothing matched.
fn remove_raws(content: &str, gone: &mut HashMap<String, usize>) -> Option<String> {
    let pre = leading_preamble(content);
    let mut removed = false;
    let mut keep = Vec::new();
    for e in parse_entries(content) {
        let k = e.raw.trim_end().to_string();
        match gone.get_mut(&k) {
            Some(c) if *c > 0 => {
                *c -= 1;
                removed = true;
            }
            _ => keep.push(e.raw),
        }
    }
    removed.then(|| render(&pre, &keep))
}

#[derive(Serialize, Default, Debug)]
pub struct FileAllReport {
    pub filed: usize,
    pub skipped: usize,
    pub errors: Vec<String>,
}

/// File every inbox draft: split target (first matching split tag) else its
/// day file, inserted in time order, links rebased. One write per
/// destination; then the inbox is re-read and only drafts that were filed
/// are removed. Empty drafts are skipped and stay.
pub fn file_all(j: &Journal, split_tags: &[String]) -> Result<FileAllReport, String> {
    let mut rep = FileAllReport::default();
    let inbox = j.inbox_files();
    let mut groups: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
    for file in &inbox {
        let content = j.try_read(file)?;
        for e in parse_entries(&content) {
            if e.body.is_empty() && e.suffix.is_empty() {
                rep.skipped += 1;
                continue;
            }
            let target = split_target(&e.raw, split_tags).unwrap_or_else(|| journal_rel(&e.date));
            let raw = rebase_links(&rebuild(&e), file, &target);
            groups.entry(target).or_default().push((e.raw.trim_end().to_string(), raw));
        }
    }
    let mut gone: HashMap<String, usize> = HashMap::new();
    for (target, items) in &groups {
        let raws: Vec<String> = items.iter().map(|x| x.1.clone()).collect();
        match j.insert_entries(target, &raws, true) {
            Ok(_) => {
                for (k, _) in items {
                    *gone.entry(k.clone()).or_default() += 1;
                }
                rep.filed += items.len();
            }
            Err(e) => rep.errors.push(format!("{}: {}", target, e)),
        }
    }
    if rep.filed > 0 {
        for file in &inbox {
            remove_gone(j, file, &mut gone)?;
        }
    }
    Ok(rep)
}

/// Take the entries in the multiset `gone` out of `file`, counting them off
/// `gone`; a day file left with no entries is deleted (its preamble, if any, is
/// kept in place). Works on the file as it is now, retrying if it changes.
fn remove_gone(j: &Journal, file: &str, gone: &mut HashMap<String, usize>) -> Result<(), String> {
    *gone = j.edit_file(file, |content| {
        let mut left = gone.clone();
        let text = remove_raws(content, &mut left).map(|text| {
            if is_day_file(file) && parse_entries(&text).is_empty() && leading_preamble(&text).is_empty() {
                String::new()
            } else {
                text
            }
        });
        Ok((text, left))
    })?;
    Ok(())
}

#[derive(Serialize, Default, Debug)]
pub struct MergeReport {
    pub entries: usize,
    pub journals: usize,
    pub errors: Vec<String>,
}

/// Fold split journals whose tag is no longer a split tag (`split/<tag>/`,
/// or a legacy root `<tag>.md`) back into the journal's day files (no split
/// routing), destination first. A file that empties is deleted unless it has
/// a preamble, which is kept on its own.
pub fn merge_ex_split(j: &Journal, split_tags: &[String]) -> Result<MergeReport, String> {
    let mut rep = MergeReport::default();
    let tags: HashSet<String> = split_tags.iter().map(|t| t.trim_start_matches('@').to_lowercase()).collect();
    let mut merged: HashSet<String> = HashSet::new();
    for (name, tag) in j.split_files() {
        if tags.contains(&tag.to_lowercase()) {
            continue;
        }
        let content = match j.try_read(&name) {
            Ok(c) => c,
            Err(e) => {
                rep.errors.push(e);
                continue;
            }
        };
        let entries = parse_entries(&content);
        if entries.is_empty() {
            continue;
        }
        let mut groups: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
        for e in &entries {
            let dest = journal_rel(&e.date);
            let raw = rebase_links(e.raw.trim_end(), &name, &dest);
            groups.entry(dest).or_default().push((e.raw.trim_end().to_string(), raw));
        }
        let mut gone: HashMap<String, usize> = HashMap::new();
        let mut moved = 0;
        for (dest, items) in &groups {
            let raws: Vec<String> = items.iter().map(|x| x.1.clone()).collect();
            match j.insert_entries(dest, &raws, true) {
                Ok(_) => {
                    for (k, _) in items {
                        *gone.entry(k.clone()).or_default() += 1;
                    }
                    moved += items.len();
                }
                Err(e) => rep.errors.push(format!("{} → {}: {}", name, dest, e)),
            }
        }
        if moved == 0 {
            continue;
        }
        let pre = leading_preamble(&content);
        let res = if moved == entries.len() {
            if pre.trim().is_empty() {
                j.remove_text(&name, &content)
            } else {
                j.replace_text(&name, &content, &render(&pre, &[]))
            }
        } else {
            remove_gone(j, &name, &mut gone)
        };
        match res {
            Ok(()) => {
                rep.entries += moved;
                merged.insert(tag);
            }
            Err(e) => rep.errors.push(format!("{}: {}", name, e)),
        }
    }
    rep.journals = merged.len();
    Ok(rep)
}

/// Merge a sync-conflict copy into its main file: entries not already there
/// (exact raw) are added, the file is re-sorted by ts and written, and the
/// conflict copy is deleted. Returns how many entries were added.
pub fn merge_conflict(j: &Journal, rel: &str) -> Result<usize, String> {
    let crel = check_entry_rel(rel)?;
    let name = rel.rsplit('/').next().unwrap_or(rel);
    if !is_conflict_name(name) {
        return Err(format!("{} isn't a conflict copy", rel));
    }
    let main_rel = conflict_main_name(rel).ok_or("Can't tell which file that conflict copy belongs to")?;
    let main_rel = check_entry_rel(&main_rel)?;
    let ctext = j.try_read(&crel)?;
    let added = j.edit_file(&main_rel, |mtext| {
        let mut main = parse_entries(mtext);
        let mut have: HashMap<String, usize> = HashMap::new();
        for e in &main {
            *have.entry(e.raw.trim_end().to_string()).or_default() += 1;
        }
        let mut added = 0;
        for e in parse_entries(&ctext) {
            match have.get_mut(e.raw.trim_end()) {
                Some(c) if *c > 0 => *c -= 1,
                _ => {
                    main.push(e);
                    added += 1;
                }
            }
        }
        let mut pre = leading_preamble(mtext);
        let cpre = leading_preamble(&ctext);
        let mut pre_changed = false;
        if !cpre.trim().is_empty() && !pre.contains(cpre.trim()) {
            pre = if pre.is_empty() { cpre } else { format!("{}\n\n{}", pre, cpre) };
            pre_changed = true;
        }
        if added == 0 && !pre_changed {
            return Ok((None, 0));
        }
        main.sort_by(|a, b| a.ts.cmp(&b.ts));
        let raws: Vec<String> = main.into_iter().map(|e| e.raw).collect();
        Ok((Some(render(&pre, &raws)), added))
    })?;
    j.remove_text(&crel, &ctext)?;
    Ok(added)
}

// ---------- export / backup ----------

pub fn export_all(j: &Journal, dest: &Path) -> Result<usize, String> {
    // Strict: an export that silently omitted an unreadable day would look complete.
    let mut es: Vec<Entry> = j.try_load_all()?.into_iter().filter(|e| e.source != "inbox").collect();
    es.sort_by(|a, b| a.ts.cmp(&b.ts));
    let raws: Vec<String> = es.iter().map(|e| e.raw.clone()).collect();
    write_atomic(dest, &render("", &raws))?;
    Ok(raws.len())
}

/// Copy a folder tree. Symlinks are recreated as links (Unix) or skipped,
/// never followed. With `skip_hidden_top`, top-level dot-items other than
/// the sidecars (`.quire`, `.nook`) are left out.
pub fn copy_tree(from: &Path, to: &Path, skip_hidden_top: bool) -> Result<(), String> {
    copy_tree_counted(from, to, skip_hidden_top).map(|_| ())
}

/// `copy_tree`, returning how many files it copied and how many bytes each
/// copy reported: what the copy should hold, whatever happens to the original
/// afterwards.
fn copy_tree_counted(from: &Path, to: &Path, skip_hidden_top: bool) -> Result<(u64, u64), String> {
    fs::create_dir_all(to).map_err(|e| e.to_string())?;
    let (mut files, mut bytes) = (0, 0);
    for e in fs::read_dir(from).map_err(|e| e.to_string())?.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if skip_hidden_top && name.starts_with('.') && name != SIDECAR && name != LEGACY_SIDECAR {
            continue;
        }
        let t = to.join(&name);
        let ft = e.file_type().map_err(|e| e.to_string())?;
        if ft.is_symlink() {
            #[cfg(unix)]
            {
                let target = fs::read_link(e.path()).map_err(|e| e.to_string())?;
                std::os::unix::fs::symlink(target, &t).map_err(|e| e.to_string())?;
            }
        } else if ft.is_dir() {
            let (f, b) = copy_tree_counted(&e.path(), &t, false)?;
            files += f;
            bytes += b;
        } else {
            match fs::copy(e.path(), &t) {
                Ok(n) => {
                    files += 1;
                    bytes += n;
                }
                // Gone between the listing and the copy (a draft filed, an
                // emptied day file): it isn't part of this copy.
                Err(err) if err.kind() == std::io::ErrorKind::NotFound && !e.path().exists() => {}
                Err(err) => return Err(format!("{}: {}", err, t.display())),
            }
        }
    }
    Ok((files, bytes))
}

/// Count the files in a tree and add up their bytes, walking it the way
/// `copy_tree` does, so a copy can be checked against what it was copied from.
fn tree_stats(root: &Path, skip_hidden_top: bool) -> Result<(u64, u64), String> {
    let (mut files, mut bytes) = (0, 0);
    for e in fs::read_dir(root).map_err(|e| e.to_string())? {
        let e = e.map_err(|e| e.to_string())?;
        let name = e.file_name().to_string_lossy().to_string();
        if skip_hidden_top && name.starts_with('.') && name != SIDECAR && name != LEGACY_SIDECAR {
            continue;
        }
        let ft = e.file_type().map_err(|e| e.to_string())?;
        if ft.is_dir() {
            let (f, b) = tree_stats(&e.path(), false)?;
            files += f;
            bytes += b;
        } else if ft.is_file() {
            files += 1;
            bytes += e.metadata().map_err(|e| e.to_string())?.len();
        }
    }
    Ok((files, bytes))
}

/// Err unless `copy` holds as many files and bytes as `original`. Only for an
/// original that isn't being written to: a live journal is checked with
/// `verify_counted` instead.
#[cfg(test)]
fn verify_copy(original: &Path, copy: &Path, skip_hidden_top: bool) -> Result<(), String> {
    verify_counted(copy, tree_stats(original, skip_hidden_top)?)
}

/// Err unless `copy` holds exactly the files and bytes `copy_tree_counted`
/// reported writing into it. The journal itself is not walked a second time:
/// it may have been saved to since, and that must not fail a good copy.
fn verify_counted(copy: &Path, copied: (u64, u64)) -> Result<(), String> {
    let found = tree_stats(copy, false)?;
    if found == copied {
        Ok(())
    } else {
        Err(format!("the copy doesn't match: {} files and {} bytes, expected {} and {}", found.0, found.1, copied.0, copied.1))
    }
}

/// Refuse a backup folder inside the journal, or a journal inside the backup folder.
pub fn check_backup_dir(root: &Path, dest_dir: &Path) -> Result<(), String> {
    let r = root.canonicalize().map_err(|e| e.to_string())?;
    // dest_dir may not exist yet: check the nearest existing ancestor.
    let mut probe = dest_dir.to_path_buf();
    while !probe.exists() {
        match probe.parent() {
            Some(p) => probe = p.to_path_buf(),
            None => break,
        }
    }
    let d = probe.canonicalize().map_err(|e| e.to_string())?;
    if d.starts_with(&r) {
        return Err("Backup folder must be outside the journal folder".into());
    }
    if dest_dir.exists() {
        let dc = dest_dir.canonicalize().map_err(|e| e.to_string())?;
        if r.starts_with(&dc) {
            return Err("The journal folder can't be inside the backup folder".into());
        }
    }
    Ok(())
}

pub const BACKUP_PREFIX: &str = "Quire backup ";
pub const NOOK_BACKUP_PREFIX: &str = "Nook-Backup-";
/// The copy of the journal a restore takes before it replaces anything. Listed
/// and restorable like a backup, and never pruned with them.
pub const SAFETY_PREFIX: &str = "Quire before-restore ";
/// A backup still being copied is `.<final name>.partial`: hidden, so nothing
/// lists it, counts it against retention or restores from it.
const PARTIAL_SUFFIX: &str = ".partial";
/// A partial this old was abandoned (the app was closed or killed mid-copy).
pub const PARTIAL_MAX_AGE: Duration = Duration::from_secs(24 * 3600);

/// One backup or restore at a time, app-wide.
pub static BACKUP_RUNNING: AtomicBool = AtomicBool::new(false);

pub struct BackupGuard;
impl BackupGuard {
    pub fn acquire() -> Result<BackupGuard, String> {
        if BACKUP_RUNNING.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_err() {
            return Err("A backup or restore is already running".into());
        }
        Ok(BackupGuard)
    }
}
impl Drop for BackupGuard {
    fn drop(&mut self) {
        BACKUP_RUNNING.store(false, Ordering::SeqCst);
    }
}

fn is_partial_name(name: &str) -> bool {
    name.strip_prefix('.').and_then(|n| n.strip_suffix(PARTIAL_SUFFIX)).is_some_and(|n| n.starts_with(BACKUP_PREFIX) || n.starts_with(SAFETY_PREFIX))
}

/// Remove half-made backups (`.Quire backup ….partial`) that have sat in
/// `dest_dir` for `min_age` or more. Returns how many went. A younger one may
/// be another window's backup still being copied, and is left.
pub fn sweep_partial_backups(dest_dir: &Path, min_age: Duration) -> usize {
    let Ok(rd) = fs::read_dir(dest_dir) else { return 0 };
    let now = SystemTime::now();
    let mut n = 0;
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if !is_partial_name(&name) || !e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            continue;
        }
        let old = e.metadata().and_then(|m| m.modified()).ok().and_then(|m| now.duration_since(m).ok()).map(|age| age >= min_age).unwrap_or(false);
        if old && fs::remove_dir_all(e.path()).is_ok() {
            n += 1;
        }
    }
    n
}

/// Copy `root` into `dest_dir/<prefix><stamp>`. The copy is made under a
/// hidden `.….partial` name, checked against the sizes recorded as each file
/// was copied, and only then given its real name, so a backup that exists is a
/// backup that finished. `after_copy` runs between the copy and the check
/// (tests use it to write to the journal there).
fn copy_to_new_backup(root: &Path, dest_dir: &Path, skip_hidden_top: bool, prefix: &str, after_copy: impl FnOnce()) -> Result<PathBuf, String> {
    check_backup_dir(root, dest_dir)?;
    fs::create_dir_all(dest_dir).map_err(|e| e.to_string())?;
    check_backup_dir(root, dest_dir)?;
    sweep_partial_backups(dest_dir, PARTIAL_MAX_AGE);
    let base = format!("{}{}", prefix, Local::now().format("%Y-%m-%d-%H%M%S"));
    let partial_of = |name: &str| dest_dir.join(format!(".{}{}", name, PARTIAL_SUFFIX));
    let mut name = base.clone();
    let mut n = 2;
    while dest_dir.join(&name).exists() || partial_of(&name).exists() {
        name = format!("{}-{}", base, n);
        n += 1;
    }
    let (partial, dest) = (partial_of(&name), dest_dir.join(&name));
    let made = copy_tree_counted(root, &partial, skip_hidden_top)
        .and_then(|copied| {
            after_copy();
            verify_counted(&partial, copied)
        })
        .and_then(|_| fs::rename(&partial, &dest).map_err(|e| e.to_string()));
    if let Err(e) = made {
        let _ = fs::remove_dir_all(&partial);
        return Err(e);
    }
    crate::vault::sync_dir(dest_dir);
    Ok(dest)
}

/// Copy the journal into `dest_dir/Quire backup YYYY-MM-DD-HHMMSS` (local
/// time). Returns the backup's full path. Does not prune.
pub fn backup(j: &Journal, dest_dir: &Path) -> Result<String, String> {
    let root = j.local()?;
    Ok(copy_to_new_backup(root, dest_dir, true, BACKUP_PREFIX, || {})?.display().to_string())
}

fn backup_key(name: &str) -> Option<&str> {
    name.strip_prefix(BACKUP_PREFIX).or_else(|| name.strip_prefix(NOOK_BACKUP_PREFIX)).or_else(|| name.strip_prefix(SAFETY_PREFIX))
}

/// A stable name for a journal folder, for keeping one journal's backups (and
/// its "last backup" time) apart from another's: the folder's own name, made
/// safe for a path, and eight hex digits of its full path. `Journal` and
/// `Journal 2` in different places never share a key; the same folder always
/// gets the same one.
pub fn journal_key(root: &Path) -> String {
    let full = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
    let name: String = full
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default()
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { '-' })
        .collect();
    // FNV-1a: std's hasher may change between Rust versions, and this is kept.
    let hash = full.to_string_lossy().bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3));
    format!("{}-{:08x}", if name.is_empty() { "journal" } else { &name }, hash as u32)
}

/// `dest_dir/<journal_key>`: a backup folder of this journal's own, for a
/// shell that backs up more than one journal into one place.
pub fn backup_dir_for(dest_dir: &Path, root: &Path) -> PathBuf {
    dest_dir.join(journal_key(root))
}

/// What `prune_backups_checked` did.
#[derive(Debug, Default, Clone, Serialize)]
pub struct Pruned {
    pub removed: usize,
    /// Why nothing was removed although there were more backups than `keep`.
    pub held: Option<String>,
}

/// Keep only the `keep` newest "Quire backup …" folders. Nook's backups,
/// restore safety copies and anything else are left alone. Returns the number
/// removed. See `prune_backups_checked` for when it removes nothing.
pub fn prune_backups(dest_dir: &Path, keep: usize) -> Result<usize, String> {
    prune_backups_checked(dest_dir, keep).map(|p| p.removed)
}

/// `prune_backups`, saying why when it holds back. If the newest backup is
/// less than half the size of the one before it, the journal may have just
/// lost most of what it held (a sync gone wrong, the wrong folder): the older
/// backups are then the only good ones, so none is removed, and `held` says
/// so. The next backup is compared with this one, so a journal that really did
/// shrink starts pruning again one backup later.
pub fn prune_backups_checked(dest_dir: &Path, keep: usize) -> Result<Pruned, String> {
    sweep_partial_backups(dest_dir, PARTIAL_MAX_AGE);
    let names: Vec<String> = list_backups(dest_dir).into_iter().filter(|n| n.starts_with(BACKUP_PREFIX)).collect();
    let keep = keep.max(1);
    if names.len() <= keep {
        return Ok(Pruned::default());
    }
    if let [newest, previous, ..] = names.as_slice() {
        let size = |n: &String| tree_stats(&dest_dir.join(n), false).map(|s| s.1);
        let (new, old) = (size(newest)?, size(previous)?);
        if old >= SHRINK_FLOOR && new < old / 2 {
            return Ok(Pruned {
                removed: 0,
                held: Some(format!(
                    "“{}” is much smaller than the backup before it ({} bytes, down from {}), so no older backup was removed. Check the journal folder is the right one and complete.",
                    newest, new, old
                )),
            });
        }
    }
    let mut removed = 0;
    for name in names.iter().skip(keep) {
        fs::remove_dir_all(dest_dir.join(name)).map_err(|e| e.to_string())?;
        removed += 1;
    }
    Ok(Pruned { removed, held: None })
}

/// Below this a backup is too small for "half the size" to mean anything.
const SHRINK_FLOOR: u64 = 64 * 1024;

/// "Quire backup …", "Quire before-restore …" and "Nook-Backup-…" folders,
/// newest first (by the timestamp in the name). Half-made backups are hidden
/// (`.….partial`) and never listed.
pub fn list_backups(dest_dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(dest_dir)
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|n| backup_key(n).is_some())
                .collect()
        })
        .unwrap_or_default();
    v.sort_by(|a, b| backup_key(b).cmp(&backup_key(a)).then(b.cmp(a)));
    v
}

/// Restore `dest_dir/name` over `root`. Nothing in the journal is touched until
/// a checked safety copy (`Quire before-restore <stamp>`: listed and
/// restorable like a backup, never pruned) and a checked staged copy of the
/// backup both exist. The swap is then renames inside the journal folder,
/// undone if one fails, and the old content is deleted last.
/// Returns the safety copy's name.
pub fn restore(j: &Journal, dest_dir: &Path, name: &str) -> Result<String, String> {
    let root = j.local()?;
    if name.is_empty() || name.contains('/') || name.contains('\\') || name.contains("..") || name.starts_with('.') {
        return Err("Bad backup name".into());
    }
    let src = dest_dir.join(name);
    let md = fs::symlink_metadata(&src).map_err(|_| format!("No backup called {}", name))?;
    if !md.is_dir() {
        return Err(format!("No backup called {}", name));
    }
    if !src.join(LEGACY_INBOX).is_file() && !src.join(INBOX_DIR).is_dir() && !src.join(JOURNAL_DIR).is_dir() {
        return Err(format!("{} doesn't look like a journal backup (no inbox, inbox.md or journal/)", name));
    }
    check_backup_dir(root, dest_dir)?;
    // Full copy (hidden items too), since the restore removes everything.
    let safety = copy_to_new_backup(root, dest_dir, false, SAFETY_PREFIX, || {})
        .map_err(|e| format!("Couldn't make a safety copy first ({}); nothing was changed", e))?;
    let safety_name = safety.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    swap_in_backup(root, &src, |_| Ok(())).map_err(|e| {
        format!("Restore failed ({}). Your journal was put back, and it is also saved as “{}”.", e, safety_name)
    })?;
    Ok(safety_name)
}

const RESTORE_NEW: &str = ".quire-restore-new-";
const RESTORE_OLD: &str = ".quire-restore-old-";

/// What an interrupted restore left in a journal folder.
#[derive(Debug, Default, Clone, Serialize)]
pub struct RestoreLeftovers {
    /// Staged copies of a backup (`.quire-restore-new-*`) removed just now:
    /// the backup they were copied from is still in the backup folder.
    pub swept: usize,
    /// `.quire-restore-old-*` folders still there. Each holds what was in the
    /// journal when a restore was cut short, which may be the only copy of
    /// something, so they are never removed here: tell the person.
    pub old: Vec<String>,
}

/// Look for what a restore that was interrupted mid-swap left behind, when a
/// journal folder is opened. Staged copies at least `min_age` old are removed
/// (a younger one may belong to a restore running in another window); folders
/// of displaced journal content are only reported. Local folders only.
pub fn restore_leftovers(root: &Path, min_age: Duration) -> RestoreLeftovers {
    let mut out = RestoreLeftovers::default();
    let Ok(rd) = fs::read_dir(root) else { return out };
    let now = SystemTime::now();
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if !e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            continue;
        }
        if name.starts_with(RESTORE_OLD) {
            out.old.push(name);
        } else if name.starts_with(RESTORE_NEW) {
            let old = e.metadata().and_then(|m| m.modified()).ok().and_then(|m| now.duration_since(m).ok()).map(|age| age >= min_age).unwrap_or(false);
            if old && fs::remove_dir_all(e.path()).is_ok() {
                out.swept += 1;
            }
        }
    }
    out.old.sort();
    out
}

/// Hidden items other than the sidecars stay where they are: .git, Syncthing's
/// .stfolder/.stignore and the like aren't in backups, so moving them would
/// break things the restore can't put back.
fn restorable(name: &str) -> bool {
    !name.starts_with('.') || name == SIDECAR || name == LEGACY_SIDECAR
}

fn names_in(dir: &Path) -> Result<Vec<String>, String> {
    let mut v = Vec::new();
    for e in fs::read_dir(dir).map_err(|e| e.to_string())? {
        let n = e.map_err(|e| e.to_string())?.file_name().to_string_lossy().to_string();
        if restorable(&n) {
            v.push(n);
        }
    }
    Ok(v)
}

/// Stage `src` inside `root`, check it, then swap it in. On any failure the
/// journal is left as it was. `before_move` runs before each rename, so tests
/// can make one fail.
fn swap_in_backup(root: &Path, src: &Path, mut before_move: impl FnMut(&str) -> Result<(), String>) -> Result<(), String> {
    // Unique names: a leftover from a crash may hold the only copy of something.
    let stamp = Local::now().format("%Y%m%d-%H%M%S-%f");
    let new = root.join(format!("{}{}", RESTORE_NEW, stamp));
    let old = root.join(format!("{}{}", RESTORE_OLD, stamp));
    let staged = copy_tree_counted(src, &new, false).and_then(|copied| verify_counted(&new, copied));
    if let Err(e) = staged {
        let _ = fs::remove_dir_all(&new);
        return Err(e);
    }
    let (live, incoming) = (names_in(root)?, names_in(&new)?);
    fs::create_dir(&old).map_err(|e| e.to_string())?;
    let (mut moved_out, mut moved_in) = (Vec::new(), Vec::new());
    let mut swap = || -> Result<(), String> {
        for n in &live {
            before_move(n)?;
            fs::rename(root.join(n), old.join(n)).map_err(|e| format!("{}: {}", n, e))?;
            moved_out.push(n.clone());
        }
        for n in &incoming {
            before_move(n)?;
            fs::rename(new.join(n), root.join(n)).map_err(|e| format!("{}: {}", n, e))?;
            moved_in.push(n.clone());
        }
        Ok(())
    };
    if let Err(e) = swap() {
        let mut stuck = false;
        for n in &moved_in {
            stuck |= fs::rename(root.join(n), new.join(n)).is_err();
        }
        for n in &moved_out {
            stuck |= fs::rename(old.join(n), root.join(n)).is_err();
        }
        if stuck {
            // Keep both folders: they hold what couldn't be moved back.
            return Err(format!("{}; some items are still in {}", e, old.display()));
        }
        let _ = fs::remove_dir_all(&new);
        let _ = fs::remove_dir_all(&old);
        return Err(e);
    }
    let _ = fs::remove_dir_all(&new);
    let _ = fs::remove_dir_all(&old);
    Ok(())
}

pub fn backup_due(interval: &str, last: Option<&str>) -> bool {
    let period = match interval {
        "daily" => 86_400,
        "weekly" => 7 * 86_400,
        "monthly" => 30 * 86_400,
        _ => return false,
    };
    match last.and_then(secs_since) {
        Some(s) => s >= period - 60, // a minute's slack for launch-time jitter
        None => true,
    }
}

// ---------- stale temp files ----------

fn is_temp_name(n: &str) -> bool {
    (n.starts_with(".quire-") && n.ends_with(".tmp")) || (n.starts_with(".nook-") && n.ends_with(".tmp")) || n.starts_with("._tmp_")
}

/// Delete `.quire-*.tmp`, `.nook-*.tmp` and `._tmp_*` files older than
/// `min_age` anywhere under root (symlinks not followed). Returns the count.
pub fn sweep_temps(root: &Path, min_age: Duration) -> usize {
    let mut files = Vec::new();
    walk_all(root, &mut files);
    let now = SystemTime::now();
    let mut n = 0;
    for f in files {
        let name = f.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        if !is_temp_name(&name) {
            continue;
        }
        let old = fs::symlink_metadata(&f)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|m| now.duration_since(m).ok())
            .map(|age| age >= min_age)
            .unwrap_or(false);
        if old && fs::remove_file(&f).is_ok() {
            n += 1;
        }
    }
    n
}

// ---------- imports ----------

#[derive(Serialize, Default, Debug)]
pub struct ImportReport {
    pub found: usize,
    pub written: usize,
    pub skipped: usize,
    /// Media files copied into assets/ (Day One).
    pub media: usize,
}

static IMG_LINK_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"!\[[^\]]*\]\([^)]*\)").unwrap());

/// ts + \u1 + trimmed title + \u1 + body with images removed and whitespace collapsed.
pub fn dedupe_key(ts: &str, title: &str, body: &str) -> String {
    let b = IMG_LINK_RE.replace_all(body, " ");
    let b = b.split_whitespace().collect::<Vec<_>>().join(" ");
    format!("{}\u{1}{}\u{1}{}", ts, title.trim(), b)
}

/// Multiset of dedupe keys for everything already in the journal.
fn existing_key_counts(j: &Journal) -> Result<HashMap<String, usize>, String> {
    let mut m = HashMap::new();
    for e in j.try_load_all()? {
        *m.entry(dedupe_key(&e.ts, &e.title, &e.body)).or_default() += 1;
    }
    Ok(m)
}

/// Consume one matching key; true if it was already present.
fn take(m: &mut HashMap<String, usize>, k: &str) -> bool {
    match m.get_mut(k) {
        Some(c) if *c > 0 => {
            *c -= 1;
            true
        }
        _ => false,
    }
}

fn write_groups(j: &Journal, groups: BTreeMap<String, Vec<String>>) -> Result<(), String> {
    for (file, raws) in groups {
        j.insert_entries(&file, &raws, false)?;
    }
    Ok(())
}

static DATE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"([0-9]{4})-([0-9]{2})-([0-9]{2})").unwrap());

fn first_valid_date(s: &str) -> Option<String> {
    for m in DATE_RE.captures_iter(s) {
        let (y, mo, d) = (m[1].parse().ok()?, m[2].parse().ok()?, m[3].parse().ok()?);
        if NaiveDate::from_ymd_opt(y, mo, d).is_some() {
            return Some(m[0].to_string());
        }
    }
    None
}

fn file_date(p: &Path) -> Option<String> {
    let md = fs::metadata(p).ok()?;
    let t = md.created().or_else(|_| md.modified()).ok()?;
    Some(chrono::DateTime::<Local>::from(t).format("%Y-%m-%d").to_string())
}

/// A folder of markdown/text files (Obsidian daily notes and the like).
/// Date: first valid YYYY-MM-DD in the file name, else the file's created
/// (fallback modified) date. Time: 12:00:00, +1 s for each further file on
/// the same date. Title: the file stem unless it is just the date. Files
/// already in jnl format import their entries verbatim.
///
/// Folders and files whose names start with a dot are not read (`.trash/`,
/// `.stversions/`, `.obsidian/`: other tools' leftovers, not notes). In a
/// file with entries, text above the first header becomes an entry of its
/// own, dated like a plain file.
pub fn import_markdown_folder(j: &Journal, dir: &Path, dry_run: bool) -> Result<ImportReport, String> {
    let mut rep = ImportReport::default();
    let mut have = existing_key_counts(j)?;
    let mut files = Vec::new();
    walk_visible(dir, &mut files);
    files.sort();
    let mut per_date: HashMap<String, i64> = HashMap::new();
    let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for f in files {
        let name = f.file_name().unwrap().to_string_lossy().to_string();
        let ext = f.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        if (ext != "md" && ext != "txt") || name.starts_with('.') {
            continue;
        }
        let Ok(text) = fs::read_to_string(&f) else {
            rep.found += 1;
            rep.skipped += 1;
            continue;
        };
        let text = normalise_outside(&text);
        let parsed = parse_entries(&text);
        // Text with no header of its own: the whole of a plain note, or what
        // sits above the first entry of a file in jnl's format.
        let loose = if parsed.is_empty() { text.trim().to_string() } else { leading_preamble(&text).trim().to_string() };
        let mut items: Vec<(String, String, String)> = Vec::new();
        if !loose.is_empty() {
            if let Some(date) = first_valid_date(&name).or_else(|| file_date(&f)) {
                let n = per_date.entry(date.clone()).or_insert(0);
                let ts = add_secs(&format!("{} 12:00:00", date), *n)?;
                *n += 1;
                let stem = f.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                let title = if stem.trim() == date { String::new() } else { stem };
                let raw = make_raw(&ts, &title, false, &loose);
                let e = parse_entries(&raw).remove(0);
                items.push((dedupe_key(&ts, &strip_star(&e.suffix), &e.body), journal_rel(&date), raw));
            }
        }
        items.extend(parsed.into_iter().map(|e| (dedupe_key(&e.ts, &strip_star(&e.suffix), &e.body), journal_rel(&e.date), e.raw.trim_end().to_string())));
        for (key, file, raw) in items {
            rep.found += 1;
            if take(&mut have, &key) {
                rep.skipped += 1;
                continue;
            }
            groups.entry(file).or_default().push(raw);
            rep.written += 1;
        }
    }
    if !dry_run {
        write_groups(j, groups)?;
    }
    Ok(rep)
}

static DAYONE_UNESCAPE_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\\([!.()\[\]#\-*_])").unwrap());

/// Day One escapes markdown punctuation; undo exactly those escapes.
pub fn dayone_unescape(s: &str) -> String {
    DAYONE_UNESCAPE_RE.replace_all(s, "$1").into_owned()
}

/// UTC ISO creationDate → local wall time in the entry's IANA zone (else the
/// machine's local offset), as `YYYY-MM-DD HH:MM:SS`.
pub fn dayone_ts(created: &str, tz: Option<&str>) -> Option<String> {
    let utc = chrono::DateTime::parse_from_rfc3339(created)
        .map(|d| d.with_timezone(&chrono::Utc))
        .ok()
        .or_else(|| {
            NaiveDateTime::parse_from_str(created.trim_end_matches('Z'), "%Y-%m-%dT%H:%M:%S")
                .ok()
                .map(|n| chrono::Utc.from_utc_datetime(&n))
        })?;
    let s = match tz.and_then(|t| t.parse::<chrono_tz::Tz>().ok()) {
        Some(z) => utc.with_timezone(&z).format(TS_FMT).to_string(),
        None => utc.with_timezone(&Local).format(TS_FMT).to_string(),
    };
    check_ts(&s).ok().map(|_| s)
}

/// Lowercase, spaces → `-`, keep [a-z0-9_-], must start with a letter.
pub fn sanitize_tag(t: &str) -> Option<String> {
    let s: String = t.trim().to_lowercase().replace(' ', "-").chars().filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '_' || *c == '-').collect();
    s.chars().next().filter(|c| c.is_ascii_lowercase()).map(|_| s)
}

fn safe_part(s: &str) -> bool {
    !s.is_empty() && !s.contains('/') && !s.contains('\\') && !s.contains("..")
}

/// Day One JSON export (Journal.json, or the folder holding it). Photos,
/// videos and audio are copied into assets/ when the export's photos/,
/// videos/ and audios/ folders sit beside the JSON.
pub fn import_day_one(j: &Journal, path: &Path, dry_run: bool) -> Result<ImportReport, String> {
    let json_path = if path.is_dir() {
        let mut jsons: Vec<PathBuf> = fs::read_dir(path)
            .map_err(|e| e.to_string())?
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_file() && p.extension().map(|x| x.eq_ignore_ascii_case("json")).unwrap_or(false))
            .collect();
        jsons.sort();
        let name = |p: &PathBuf| p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
        jsons
            .iter()
            .find(|p| name(p) == "journal.json")
            .or_else(|| jsons.iter().find(|p| name(p) != "metadata.json"))
            .cloned()
            .ok_or("No Day One .json file in that folder")?
    } else {
        path.to_path_buf()
    };
    let text = fs::read_to_string(&json_path).map_err(|e| e.to_string())?;
    let v: serde_json::Value = serde_json::from_str(&text).map_err(|e| format!("Not a Day One export: {}", e))?;
    let entries = v.get("entries").and_then(|e| e.as_array()).ok_or("No entries in that file")?;
    let base = json_path.parent().unwrap_or(Path::new(".")).to_path_buf();
    let mut have = existing_key_counts(j)?;
    let mut rep = ImportReport::default();
    let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let s = |e: &serde_json::Value, k: &str| e.get(k).and_then(|x| x.as_str()).map(|x| x.to_string());
    for e in entries {
        rep.found += 1;
        let Some(ts) = s(e, "creationDate").and_then(|c| dayone_ts(&c, s(e, "timeZone").as_deref())) else {
            rep.skipped += 1;
            continue;
        };
        let text = dayone_unescape(&s(e, "text").unwrap_or_default());
        let mut title = String::new();
        let mut body = text.trim().to_string();
        if body.starts_with("# ") {
            let mut lines = body.splitn(2, '\n');
            title = lines.next().unwrap()[2..].trim().to_string();
            body = lines.next().unwrap_or("").trim().to_string();
        }
        // Tags not already in the text, appended as `@a @b`.
        let present: HashSet<String> = TAG_RE.find_iter(&format!("{}\n{}", title, body)).map(|m| m.as_str().to_lowercase()).collect();
        let mut tags: Vec<String> = Vec::new();
        for t in e.get("tags").and_then(|t| t.as_array()).into_iter().flatten().filter_map(|x| x.as_str()) {
            if let Some(t) = sanitize_tag(t) {
                let at = format!("@{}", t);
                if !present.contains(&at) && !tags.contains(&at) {
                    tags.push(at);
                }
            }
        }
        if !tags.is_empty() {
            body = format!("{}\n\n{}", body.trim(), tags.join(" ")).trim().to_string();
        }
        // Media: (identifier, source path).
        let mut media: Vec<(String, PathBuf)> = Vec::new();
        for (kind, default_ext) in [("photos", "jpeg"), ("videos", "mov"), ("audios", "m4a")] {
            for m in e.get(kind).and_then(|p| p.as_array()).into_iter().flatten() {
                let md5 = s(m, "md5").unwrap_or_default();
                let ext = s(m, "type").unwrap_or_else(|| default_ext.to_string());
                if !safe_part(&md5) || !safe_part(&ext) {
                    continue;
                }
                media.push((s(m, "identifier").unwrap_or_default(), base.join(kind).join(format!("{}.{}", md5, ext))));
            }
        }
        if body.trim().is_empty() && title.is_empty() && media.is_empty() {
            rep.skipped += 1;
            continue;
        }
        // The key as the entry will read back once written: built from the
        // same text `make_raw` produces, so a title with doubled spaces or a
        // body it tidies still matches itself on a second import.
        let starred = e.get("starred").and_then(|s| s.as_bool()).unwrap_or(false);
        let key = match parse_entries(&make_raw(&ts, &title, starred, &body)).into_iter().next() {
            Some(w) => dedupe_key(&w.ts, &strip_star(&w.suffix), &w.body),
            None => dedupe_key(&ts, &title, &guard_body(body.trim())),
        };
        if take(&mut have, &key) {
            rep.skipped += 1;
            continue;
        }
        rep.written += 1;
        if dry_run {
            continue;
        }
        for (id, src) in media {
            if !src.is_file() {
                continue;
            }
            let rel = attach_rel(j, &src, &ts)?;
            rep.media += 1;
            let link = format!("![]({})", rel);
            let re = (!id.is_empty())
                .then(|| Regex::new(&format!(r"!\[[^\]]*\]\(dayone-moment:[^)]*{}[^)]*\)", regex::escape(&id))).ok())
                .flatten();
            match re {
                Some(re) if re.is_match(&body) => body = re.replace_all(&body, regex::NoExpand(&link)).into_owned(),
                _ => body = format!("{}\n\n{}", body.trim(), link).trim().to_string(),
            }
        }
        groups.entry(journal_rel(&ts[..10])).or_default().push(make_raw(&ts, &title, starred, &body));
    }
    if !dry_run {
        write_groups(j, groups)?;
    }
    Ok(rep)
}

static PARA_SPLIT_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"\n[ \t\r]*\n").unwrap());

/// transfer.md: a batch of entries to file straight in (jnl's cmdTransfer).
/// With headers, each entry is filed and any preamble stays in transfer.md.
/// Without headers, each paragraph becomes an entry at `now_ts`, +1 s each.
/// Routing: split tags, else the day file (time-ordered insert); links are
/// rebased. transfer.md is only rewritten when every destination wrote, and
/// a retry skips entries already filed.
pub fn import_transfer(j: &Journal, now_ts: &str, split_tags: &[String]) -> Result<usize, String> {
    check_ts(now_ts)?;
    let text = j.try_read("transfer.md")?;
    if text.trim().is_empty() {
        return Ok(0);
    }
    let parsed = parse_entries(&text);
    let (pre, items): (String, Vec<RawEntry>) = if !parsed.is_empty() {
        (leading_preamble(&text), parsed)
    } else {
        let mut v = Vec::new();
        for (i, para) in PARA_SPLIT_RE.split(&text).map(|s| s.trim()).filter(|s| !s.is_empty()).enumerate() {
            let ts = add_secs(now_ts, i as i64)?;
            v.extend(parse_entries(&make_raw(&ts, "", false, para)));
        }
        (String::new(), v)
    };
    let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut n = 0;
    for e in items {
        if e.body.is_empty() && e.suffix.is_empty() {
            continue; // jnl's fileDraft: "nothing to file"
        }
        let target = split_target(&e.raw, split_tags).unwrap_or_else(|| journal_rel(&e.date));
        groups.entry(target.clone()).or_default().push(rebase_links(&rebuild(&e), "transfer.md", &target));
        n += 1;
    }
    for (file, raws) in &groups {
        j.insert_entries(file, raws, true)?;
    }
    j.replace_text("transfer.md", &text, &render(&pre, &[]))?;
    Ok(n)
}

// ---------- tag review ----------

#[derive(Serialize)]
pub struct TagGroup {
    pub tags: Vec<(String, usize)>,
    pub suggested: String,
}

fn one_letter_apart(a: &str, b: &str) -> bool {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    if a.len() == b.len() {
        return a.iter().zip(b.iter()).filter(|(x, y)| x != y).count() == 1;
    }
    let (s, l) = if a.len() < b.len() { (&a, &b) } else { (&b, &a) };
    if l.len() - s.len() != 1 {
        return false;
    }
    let mut i = 0;
    let mut j = 0;
    let mut skipped = false;
    while i < s.len() && j < l.len() {
        if s[i] == l[j] {
            i += 1;
            j += 1;
        } else if skipped {
            return false;
        } else {
            skipped = true;
            j += 1;
        }
    }
    true
}

pub fn tag_review(j: &Journal) -> Vec<TagGroup> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for e in j.load_all() {
        for t in e.tags {
            *counts.entry(t).or_default() += 1;
        }
    }
    let tags: Vec<(String, usize)> = counts.into_iter().collect();
    let mut used = vec![false; tags.len()];
    let mut groups = Vec::new();
    for i in 0..tags.len() {
        if used[i] {
            continue;
        }
        let mut g = vec![i];
        for j in i + 1..tags.len() {
            if used[j] {
                continue;
            }
            let (a, b) = (&tags[i].0[1..], &tags[j].0[1..]);
            // Case variants always group. A one-letter typo only counts when
            // both tags are long enough and the rarer one is rare (so
            // @home/@hope or @cats/@cars are not offered as merges).
            let rarer = tags[i].1.min(tags[j].1);
            let typo = a.len() >= 5 && b.len() >= 5 && rarer <= 3 && one_letter_apart(&a.to_lowercase(), &b.to_lowercase());
            if a.eq_ignore_ascii_case(b) || typo {
                g.push(j);
            }
        }
        if g.len() > 1 {
            g.iter().for_each(|&k| used[k] = true);
            let mut members: Vec<(String, usize)> = g.iter().map(|&k| tags[k].clone()).collect();
            members.sort_by_key(|m| std::cmp::Reverse(m.1));
            groups.push(TagGroup { suggested: members[0].0.clone(), tags: members });
        }
    }
    groups
}

static CODE_SPAN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"`[^`\n]+`").unwrap());

/// The parts of `s` where an `@word` is not a tag to rename: link and image
/// targets (`](assets/@home/x.jpg)`), inline code spans and fenced code
/// blocks. Byte ranges, in order. A fence left open ends at the next entry
/// header, so one stray ``` can't shield the rest of a file.
fn not_prose(s: &str) -> Vec<std::ops::Range<usize>> {
    let mut out: Vec<std::ops::Range<usize>> = Vec::new();
    let mut fenced = false;
    let mut at = 0;
    for line in s.split_inclusive('\n') {
        let (start, end) = (at, at + line.len());
        at = end;
        if is_header_line(line.trim_end_matches('\n')) {
            fenced = false;
        }
        let fence = line.trim_start().starts_with("```") || line.trim_start().starts_with("~~~");
        if fence || fenced {
            out.push(start..end);
            fenced ^= fence;
            continue;
        }
        out.extend(CODE_SPAN_RE.find_iter(line).map(|m| start + m.start()..start + m.end()));
        out.extend(LINK_TARGET_RE.find_iter(line).map(|m| start + m.start()..start + m.end()));
    }
    out
}

/// Replace whole `@tag` tokens in `s` (case-insensitive match against
/// `from`), skipping any preceded by a letter/digit, `.` or `/` (emails, URLs)
/// and any inside a link target, a code span or a fenced code block.
pub fn replace_tags(s: &str, from: &[String], to: &str) -> String {
    let skip = not_prose(s);
    let mut out = String::with_capacity(s.len());
    let mut last = 0;
    for m in TAG_RE.find_iter(s) {
        out.push_str(&s[last..m.start()]);
        let prev = s[..m.start()].chars().next_back();
        let blocked = prev.map(|c| c.is_alphanumeric() || c == '.' || c == '/').unwrap_or(false) || skip.iter().any(|r| r.contains(&m.start()));
        if !blocked && from.iter().any(|f| f.eq_ignore_ascii_case(m.as_str())) {
            out.push_str(to);
        } else {
            out.push_str(m.as_str());
        }
        last = m.end();
    }
    out.push_str(&s[last..]);
    out
}

/// Rename `from` tags to `to` across entry files only (inbox, day files,
/// split journals), whole tokens only. Returns files changed.
pub fn rename_tags(j: &Journal, from: &[String], to: &str) -> Result<usize, String> {
    let at = |t: &str| if t.starts_with('@') { t.to_string() } else { format!("@{}", t) };
    let from: Vec<String> = from.iter().map(|t| at(t.trim())).collect();
    let to = at(to.trim());
    if TAG_RE.find(&to).map(|m| m.as_str() != to).unwrap_or(true) {
        return Err(format!("{:?} is not a valid tag", to));
    }
    // Read everything first so an unreadable file stops the rename before any write.
    let mut todo = Vec::new();
    for (rel, _, _) in j.entry_files() {
        let s = j.try_read(&rel)?;
        let n = replace_tags(&s, &from, &to);
        if n != s {
            todo.push((rel, n));
        }
    }
    for (rel, _) in &todo {
        j.edit_file(rel, |content| {
            let n = replace_tags(content, &from, &to);
            Ok(((n != content).then_some(n), ()))
        })?;
    }
    Ok(todo.len())
}

// ---------- sizes / stats ----------

#[derive(Serialize, Default)]
pub struct Sizes {
    pub text: u64,
    pub image: u64,
    pub video: u64,
    pub audio: u64,
    pub other: u64,
}

pub fn sizes(j: &Journal) -> Sizes {
    let mut s = Sizes::default();
    for rel in j.walk_files("") {
        let b = j.len(&rel);
        if rel.starts_with("assets/") {
            match media_kind(&rel) {
                "image" => s.image += b,
                "video" => s.video += b,
                "audio" => s.audio += b,
                _ => s.other += b,
            }
        } else if rel.ends_with(".md") {
            s.text += b;
        }
    }
    s
}

#[derive(Serialize, Default, Debug)]
pub struct LongestDay {
    pub date: String,
    pub words: usize,
}

#[derive(Serialize, Default, Debug)]
pub struct SizesByLocation {
    pub inbox: u64,
    pub journal: u64,
    pub splits: u64,
    pub media: u64,
}

#[derive(Serialize, Default, Debug)]
pub struct StatsExtra {
    pub drafts: usize,
    pub tags: usize,
    pub splits: usize,
    pub avg_words_per_entry: f64,
    pub longest_day: LongestDay,
    pub sizes_by_location: SizesByLocation,
}

pub fn stats_extra(j: &Journal) -> StatsExtra {
    let all = j.load_all();
    let drafts = all.iter().filter(|e| e.source == "inbox").count();
    let tags: HashSet<&String> = all.iter().flat_map(|e| e.tags.iter()).collect();
    let filed: Vec<&Entry> = all.iter().filter(|e| e.source != "inbox").collect();
    let avg = if filed.is_empty() { 0.0 } else { filed.iter().map(|e| e.words).sum::<usize>() as f64 / filed.len() as f64 };
    let mut per_day: BTreeMap<&str, usize> = BTreeMap::new();
    for e in &filed {
        *per_day.entry(&e.date).or_default() += e.words;
    }
    let mut longest = LongestDay::default();
    for (d, w) in per_day {
        if w > longest.words {
            longest = LongestDay { date: d.to_string(), words: w };
        }
    }
    let splits = j.split_files();
    let split_tags: HashSet<&String> = splits.iter().map(|(_, t)| t).collect();
    StatsExtra {
        drafts,
        tags: tags.len(),
        splits: split_tags.len(),
        avg_words_per_entry: (avg * 10.0).round() / 10.0,
        longest_day: longest,
        sizes_by_location: SizesByLocation {
            inbox: j.len(LEGACY_INBOX) + j.tree_bytes(INBOX_DIR),
            journal: j.tree_bytes(JOURNAL_DIR),
            splits: splits.iter().map(|(rel, _)| j.len(rel)).sum(),
            media: j.tree_bytes("assets"),
        },
    }
}

// ---------- split tags and jnl's config ----------

/// `@a, b c` → ["a", "b", "c"]
pub fn parse_tags(raw: &str) -> Vec<String> {
    let mut v: Vec<String> = Vec::new();
    for t in raw.replace(',', " ").split_whitespace() {
        let t = t.trim_start_matches('@').to_string();
        if !t.is_empty() && !v.contains(&t) {
            v.push(t);
        }
    }
    v
}

pub fn jnl_config_path() -> Option<PathBuf> {
    let base = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .map(PathBuf::from)
        .or_else(|| dirs::home_dir().map(|h| h.join(".config")))?;
    Some(base.join("jnl").join("config"))
}

/// Lines like `: "${JNL_DIR:=$HOME/journal}"` → {JNL_DIR: "$HOME/journal"}.
pub fn parse_jnl_config(text: &str) -> HashMap<String, String> {
    static RE: Lazy<Regex> = Lazy::new(|| Regex::new(r#"^:\s+"\$\{(\w+):=(.*)\}"$"#).unwrap());
    let mut m = HashMap::new();
    for line in text.lines() {
        if let Some(c) = RE.captures(line.trim_end()) {
            m.insert(c[1].to_string(), c[2].to_string());
        }
    }
    m
}

pub fn jnl_config() -> HashMap<String, String> {
    jnl_config_path().and_then(|p| fs::read_to_string(p).ok()).map(|t| parse_jnl_config(&t)).unwrap_or_default()
}

/// Expand a leading `~`, `$HOME` or `${HOME}`.
pub fn expand_home(s: &str) -> String {
    let home = dirs::home_dir().map(|h| h.display().to_string()).unwrap_or_default();
    for pre in ["${HOME}", "$HOME", "~"] {
        if let Some(rest) = s.strip_prefix(pre) {
            if rest.is_empty() || rest.starts_with('/') {
                return format!("{}{}", home, rest);
            }
        }
    }
    s.to_string()
}

/// Effective split tags and where they came from: settings > env > jnl config.
/// Reserved names are dropped.
pub fn resolve_split_tags(settings: &Option<String>, env: Option<String>, config: Option<String>) -> (Vec<String>, &'static str) {
    let (raw, src) = if let Some(s) = settings {
        (s.clone(), "settings")
    } else if let Some(e) = env {
        (e, "env")
    } else if let Some(c) = config {
        (c, "jnl config")
    } else {
        (String::new(), "none")
    };
    (parse_tags(&raw).into_iter().filter(|t| !is_reserved(t)).collect(), src)
}

pub fn split_tags_resolved(settings: &Option<String>) -> (Vec<String>, &'static str) {
    resolve_split_tags(settings, std::env::var("JNL_SPLIT_TAGS").ok(), jnl_config().remove("JNL_SPLIT_TAGS"))
}

pub fn split_tags_from(settings: &Option<String>) -> Vec<String> {
    split_tags_resolved(settings).0
}

/// JNL_DIR from the environment, else jnl's config file, when it names an
/// existing folder.
pub fn jnl_dir_hint() -> Option<String> {
    let raw = std::env::var("JNL_DIR").ok().filter(|d| !d.trim().is_empty()).or_else(|| jnl_config().remove("JNL_DIR"))?;
    let d = expand_home(raw.trim());
    Path::new(&d).is_dir().then_some(d)
}

/// Reject reserved names in a split-tag list typed by the user.
pub fn check_split_tags(raw: &str) -> Result<(), String> {
    for t in parse_tags(raw) {
        if is_reserved(&t) {
            return Err(format!("@{} can't be a split tag: {}.md is reserved", t, t.to_lowercase()));
        }
        if TAG_RE.find(&format!("@{}", t)).map(|m| m.as_str().len() != t.len() + 1).unwrap_or(true) {
            return Err(format!("{:?} is not a valid tag", t));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    fn w(d: &Path, rel: &str, s: &str) {
        write_atomic(&d.join(rel), s).unwrap();
    }

    fn jn(d: &Path) -> Journal {
        Journal::open(d)
    }

    // #1: whole-token, case-insensitive rename; @ optional on inputs.
    #[test]
    fn rename_tags_whole_tokens() {
        let d = tmp();
        w(d.path(), "inbox.md", "[2026-09-30 08:00:00] x @WORK\nhello @Work and @workshop me@work.com http://x/@work\n");
        w(d.path(), "transfer.md", "@work\n");
        let n = rename_tags(&jn(d.path()), &["Work".into()], "@work").unwrap();
        assert_eq!(n, 1);
        assert_eq!(read(&d.path().join("inbox.md")), "[2026-09-30 08:00:00] x @work\nhello @work and @workshop me@work.com http://x/@work\n");
        assert!(rename_tags(&jn(d.path()), &["@work".into()], "bad tag").is_err());
        rename_tags(&jn(d.path()), &["work".into()], "job").unwrap();
        assert_eq!(read(&d.path().join("transfer.md")), "@work\n", "transfer.md isn't an entry file");
        assert!(read(&d.path().join("inbox.md")).contains("me@work.com"));
    }

    #[test]
    fn dayone_import() {
        let d = tmp();
        let exp = d.path().join("export");
        fs::create_dir_all(exp.join("photos")).unwrap();
        fs::create_dir_all(exp.join("audios")).unwrap();
        fs::write(exp.join("photos/abc.jpeg"), b"img").unwrap();
        fs::write(exp.join("audios/snd.m4a"), b"snd").unwrap();
        fs::write(exp.join("metadata.json"), b"{}").unwrap();
        fs::write(
            exp.join("Journal.json"),
            r#"{"entries":[
              {"creationDate":"2026-09-30T08:00:00Z","timeZone":"Europe/London","text":"Hi\\. \\(there\\) \\\\n\n\n![](dayone-moment://ID1)","starred":true,"tags":["Day Trip","9lives","ok!"],"photos":[{"identifier":"ID1","md5":"abc","type":"jpeg"}],"audios":[{"identifier":"A1","md5":"snd"}]},
              {"creationDate":"2026-09-30T09:00:00Z","timeZone":"Nowhere/Zone","text":""},
              {"creationDate":"garbage","text":"x"},
              {"creationDate":"2026-09-30T10:00:00Z","timeZone":"UTC","text":"evil","photos":[{"identifier":"P","md5":"../../etc/passwd","type":"jpeg"}]}
            ]}"#,
        )
        .unwrap();
        let dry = import_day_one(&jn(d.path()), &exp, true).unwrap();
        assert_eq!((dry.found, dry.written, dry.skipped, dry.media), (4, 2, 2, 0));
        assert!(!d.path().join("journal").exists());
        let r1 = import_day_one(&jn(d.path()), &exp, false).unwrap();
        assert_eq!((r1.written, r1.skipped, r1.media), (2, 2, 2));
        let r2 = import_day_one(&jn(d.path()), &exp, false).unwrap();
        assert_eq!((r2.written, r2.skipped), (0, 4));
        let day = read(&d.path().join("journal/2026/09/30.md"));
        let es = parse_entries(&day);
        assert_eq!(es.len(), 2, "{}", day);
        // BST: 08:00Z → 09:00 local; UTC entry stays 10:00.
        assert_eq!(es[0].ts, "2026-09-30 09:00:00");
        assert_eq!(es[1].ts, "2026-09-30 10:00:00");
        assert!(has_star(&es[0].suffix));
        assert!(es[0].body.starts_with("Hi. (there) \\\\n"), "{}", es[0].body);
        assert!(es[0].body.contains("![](assets/2026/09/30-090000.jpeg)"), "{}", day);
        assert!(es[0].body.contains("![](assets/2026/09/30-090000.m4a)"), "{}", day);
        assert!(es[0].body.contains("@day-trip"), "{}", day);
        assert!(!es[0].body.contains("@9lives") && !es[0].body.contains("dayone-moment"));
        assert_eq!(list_assets(&jn(d.path())).unwrap().iter().filter(|a| !a.referenced).count(), 0);
    }

    #[test]
    fn dayone_ts_zones() {
        assert_eq!(dayone_ts("2026-01-15T23:30:00Z", Some("America/New_York")).unwrap(), "2026-01-15 18:30:00");
        assert_eq!(dayone_ts("2026-07-01T00:30:00Z", Some("Asia/Tokyo")).unwrap(), "2026-07-01 09:30:00");
        assert!(dayone_ts("2026-07-01T00:30:00Z", Some("Bad/Zone")).is_some());
        assert!(dayone_ts("nope", None).is_none());
        assert_eq!(sanitize_tag("Day Trip").unwrap(), "day-trip");
        assert_eq!(sanitize_tag("9x"), None);
        assert_eq!(dayone_unescape(r"a\.b\-c\\d\[e\]\#\*\_\!\(\)"), r"a.b-c\\d[e]#*_!()");
    }

    #[test]
    fn markdown_folder_import() {
        let d = tmp();
        let src = d.path().join("src");
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("2026-09-30.md"), "First").unwrap();
        fs::write(src.join("2026-09-30 Holiday.md"), "Second").unwrap();
        fs::write(src.join("2026-13-45 then 2026-09-29 note.txt"), "Third").unwrap();
        fs::write(src.join("jnl.md"), "[2026-09-28 07:00:00] verbatim *\nbody\n").unwrap();
        let root = d.path().join("root");
        fs::create_dir_all(&root).unwrap();
        let r = import_markdown_folder(&jn(&root), &src, false).unwrap();
        assert_eq!((r.found, r.written), (4, 4));
        let e30 = parse_entries(&read(&root.join("journal/2026/09/30.md")));
        assert_eq!(e30.iter().map(|e| (e.ts.as_str(), e.suffix.as_str())).collect::<Vec<_>>(), vec![("2026-09-30 12:00:00", "2026-09-30 Holiday"), ("2026-09-30 12:00:01", "")]);
        let e29 = parse_entries(&read(&root.join("journal/2026/09/29.md")));
        assert_eq!(e29[0].suffix, "2026-13-45 then 2026-09-29 note");
        assert_eq!(read(&root.join("journal/2026/09/28.md")), "[2026-09-28 07:00:00] verbatim *\nbody\n");
        let r2 = import_markdown_folder(&jn(&root), &src, false).unwrap();
        assert_eq!((r2.written, r2.skipped), (0, 4));
    }

    #[test]
    fn transfer_routes_split_tags_and_keeps_preamble() {
        let d = tmp();
        w(d.path(), "transfer.md", "Keep me\n\n[2026-09-30 08:00:00] Standup @work\nnotes\n\n[2026-09-30 08:30:00]\n\n[2026-09-30 09:00:00] Home\n![](./assets/x.jpg)\n");
        assert_eq!(import_transfer(&jn(d.path()), "2026-09-30 10:00:00", &["work".into()]).unwrap(), 2);
        assert!(d.path().join("split/work/2026/09/30.md").exists());
        let day = read(&d.path().join("journal/2026/09/30.md"));
        assert_eq!(parse_entries(&day).len(), 1);
        assert!(day.contains("![](assets/x.jpg)"));
        assert_eq!(read(&d.path().join("transfer.md")), "Keep me\n");
        assert!(import_transfer(&jn(d.path()), "nope", &[]).is_err());
        // Plain paragraphs: one entry each, a second apart.
        w(d.path(), "transfer.md", "one\n\ntwo\n  \nthree\n");
        assert_eq!(import_transfer(&jn(d.path()), "2026-10-01 10:00:59", &[]).unwrap(), 3);
        let ts: Vec<String> = parse_entries(&read(&d.path().join("journal/2026/10/01.md"))).into_iter().map(|e| e.ts).collect();
        assert_eq!(ts, vec!["2026-10-01 10:00:59", "2026-10-01 10:01:00", "2026-10-01 10:01:01"]);
        assert_eq!(read(&d.path().join("transfer.md")), "");
    }

    #[test]
    fn orphans_are_conservative() {
        let d = tmp();
        fs::create_dir_all(d.path().join("assets/2026/09")).unwrap();
        for n in ["a", "b", "c", "d", "e", "f", "g"] {
            fs::write(d.path().join(format!("assets/2026/09/{}.jpg", n)), b"x").unwrap();
        }
        w(
            d.path(),
            "inbox.md",
            "pre [p](assets/2026/09/c.jpg)\n\n[2026-09-30 08:00:00] see ![](assets/2026/09/a.jpg)\nand [b](assets/2026/09/b.jpg \"title\")\n",
        );
        // Nook-style base-relative link inside a day file, and the old relative form.
        w(d.path(), "journal/2026/09/30.md", "[2026-09-30 08:00:00]\n![](assets/2026/09/d.jpg) ![](../../../assets/2026/09/e.jpg)\n");
        // Mentioned only as text.
        w(d.path(), "work.md", "[2026-09-30 08:00:00]\nsee assets/2026/09/f.jpg\n");
        let list = list_assets(&jn(d.path())).unwrap();
        let unref: Vec<&str> = list.iter().filter(|a| !a.referenced).map(|a| a.rel.as_str()).collect();
        assert_eq!(unref, vec!["assets/2026/09/g.jpg"]);
        let dd = list.iter().find(|a| a.rel.ends_with("d.jpg")).unwrap();
        assert_eq!(dd.owners, vec!["journal/2026/09/30.md"]);
        assert_eq!(delete_orphans(&jn(d.path())).unwrap(), 1);
        let j = jn(d.path());
        let recovered = j.walk_files(".quire/media-cleanup").into_iter().find(|p| p.ends_with("/assets/2026/09/g.jpg")).unwrap();
        assert_eq!(j.vault().read(&recovered).unwrap().unwrap(), b"x");
        fs::write(d.path().join("other.md"), b"[2026-09-30 08:00:00] caf\xe9\n").unwrap();
        assert!(delete_orphans(&jn(d.path())).is_err());
        assert!(d.path().join("assets/2026/09/a.jpg").exists());
    }

    #[test]
    fn attach_links_are_base_relative() {
        let d = tmp();
        let src = d.path().join("pic.jpg");
        fs::write(&src, b"x").unwrap();
        assert!(attach(&jn(d.path()), &src, "2026–09–30 08:00:00", "inbox.md").is_err());
        assert!(attach(&jn(d.path()), &src, "2026-09", "inbox.md").is_err());
        let link = attach(&jn(d.path()), &src, "2026-09-30 08:00:00", "journal/2026/09/30.md").unwrap();
        assert_eq!(link, "![](assets/2026/09/30-080000.jpg)");
        let link = attach(&jn(d.path()), &src, "2026-09-30 08:00:00", "inbox.md").unwrap();
        assert_eq!(link, "![](assets/2026/09/30-080000-2.jpg)");
        let doc = d.path().join("notes.pdf");
        fs::write(&doc, b"x").unwrap();
        assert_eq!(attach(&jn(d.path()), &doc, "2026-09-30 08:00:00", "x.md").unwrap(), "[30-080000.pdf](assets/2026/09/30-080000.pdf)");
        assert!(delete_asset(&jn(d.path()), "../pic.jpg").is_err());
        assert!(delete_asset(&jn(d.path()), "inbox.md").is_err());
        delete_asset(&jn(d.path()), "assets/2026/09/30-080000.pdf").unwrap();
        assert!(!d.path().join("assets/2026/09/30-080000.pdf").exists());
    }

    #[test]
    fn clipboard_images_attach_through_data_saver() {
        let d = tmp();
        let j = jn(d.path());
        let opaque = [200u8, 180, 160, 255].repeat(16);
        let (bytes, ext) = crate::media::encode_clipboard_image(4, 4, opaque).unwrap();
        assert_eq!(ext, "jpg");
        let a = attach_bytes(&j, &bytes, ext, "2026-09-30 08:00:00", true, "DEV").unwrap();
        assert_eq!(a.link, "![](assets/2026/09/30-080000.jpg)");
        assert_eq!(a.rel, "assets/2026/09/30-080000.jpg");
        assert!(!a.compress_later);
        let ledger = crate::media::read_ledger(d.path(), "DEV");
        assert_eq!(ledger.assets, vec!["2026/09/30-080000.jpg", "2026/09/30-080000"], "counted once on this device, under both forms of its id");
        let mut clear = vec![0u8; 2 * 2 * 4];
        clear[3] = 10;
        assert_eq!(crate::media::encode_clipboard_image(2, 2, clear).unwrap().1, "png");
        assert!(crate::media::encode_clipboard_image(3, 3, vec![0; 5]).is_err());
        assert!(attach_bytes(&j, &[], "png", "2026-09-30 08:00:00", false, "DEV").is_err());
        let doc = d.path().join("notes.pdf");
        fs::write(&doc, b"x").unwrap();
        assert_eq!(attach_media(&j, &doc, "2026-09-30 08:00:00", true, "DEV").unwrap().link, "[30-080000.pdf](assets/2026/09/30-080000.pdf)");
    }

    #[test]
    fn backup_guard_prune_and_restore() {
        let d = tmp();
        let root = d.path().join("journal-root");
        fs::create_dir_all(&root).unwrap();
        w(&root, "inbox.md", "[2026-09-30 08:00:00] x\n");
        assert!(backup(&jn(&root), &root.join("backups")).is_err());
        assert!(backup(&jn(&root), d.path()).is_err(), "journal inside backup dir");
        let dest = d.path().join("other/backups");
        for i in 0..3 {
            fs::create_dir_all(dest.join(format!("Quire backup 2026-01-0{}-000000", i + 1))).unwrap();
        }
        fs::create_dir_all(dest.join("Nook-Backup-2026-01-02-000000")).unwrap();
        fs::create_dir_all(dest.join("Quire before-restore 2026-01-01-000000")).unwrap();
        backup(&jn(&root), &dest).unwrap();
        assert_eq!(prune_backups(&dest, 2).unwrap(), 2);
        let left = list_backups(&dest);
        // The two newest backups, Nook's, and the restore safety copy: listed, never pruned.
        assert_eq!(left.len(), 4, "{:?}", left);
        assert!(left[0].starts_with(BACKUP_PREFIX) && left[0].as_str() > "Quire backup 2026-01-03", "{:?}", left);
        assert_eq!(&left[1..], ["Quire backup 2026-01-03-000000", "Nook-Backup-2026-01-02-000000", "Quire before-restore 2026-01-01-000000"]);

        // Restore: validates, takes a listed safety copy, replaces everything.
        let good = &left[0];
        w(&root, "inbox.md", "[2026-09-30 09:00:00] changed\n");
        w(&root, "stray.md", "[2026-09-30 09:00:00] stray\n");
        assert!(restore(&jn(&root), &dest, "../x").is_err());
        assert!(restore(&jn(&root), &dest, "Nook-Backup-2026-01-02-000000").is_err(), "empty backup refused");
        let n_before = list_backups(&dest).len();
        let safety = restore(&jn(&root), &dest, good).unwrap();
        assert_eq!(read(&root.join("inbox.md")), "[2026-09-30 08:00:00] x\n");
        assert!(!root.join("stray.md").exists());
        assert_eq!(list_backups(&dest).len(), n_before + 1);
        assert!(read(&dest.join(&safety).join("stray.md")).contains("stray"));

        // B3: the next scheduled backup, keeping one, leaves the safety copy
        // (and so the way back from the restore) where it is.
        assert!(safety.starts_with(SAFETY_PREFIX), "{safety}");
        assert!(list_backups(&dest).contains(&safety));
        backup(&jn(&root), &dest).unwrap();
        prune_backups(&dest, 1).unwrap();
        let left = list_backups(&dest);
        assert_eq!(left.iter().filter(|n| n.starts_with(BACKUP_PREFIX)).count(), 1, "{left:?}");
        assert!(left.contains(&safety) && left.contains(&"Quire before-restore 2026-01-01-000000".to_string()), "{left:?}");
        restore(&jn(&root), &dest, &safety).unwrap();
        assert!(read(&root.join("stray.md")).contains("stray"), "and it restores like any backup");
    }

    // B1
    #[test]
    fn a_backup_taken_while_the_journal_is_written_to_still_verifies() {
        let d = tmp();
        let (root, dest) = (d.path().join("live"), d.path().join("backups"));
        w(&root, "inbox/2026/11/09.md", "[2026-11-09 08:00:00] typing\n");
        w(&root, "journal/2026/11/08.md", "[2026-11-08 08:00:00] filed\n");
        // An autosave lands, and a draft is filed, after the copy and before the check.
        let made = copy_to_new_backup(&root, &dest, true, BACKUP_PREFIX, || {
            w(&root, "inbox/2026/11/09.md", "[2026-11-09 08:00:00] typing some more, and more\n");
            fs::remove_file(root.join("journal/2026/11/08.md")).unwrap();
            w(&root, "journal/2026/11/09.md", "[2026-11-09 08:01:00] new\n");
        })
        .unwrap();
        assert_eq!(read(&made.join("inbox/2026/11/09.md")), "[2026-11-09 08:00:00] typing\n", "the copy is the journal as it was copied");
        assert!(made.join("journal/2026/11/08.md").exists() && !made.join("journal/2026/11/09.md").exists());
        assert!(verify_copy(&root, &made, true).is_err(), "checking against the live folder is what used to fail it");
    }

    // B2
    #[test]
    fn a_half_made_backup_is_never_taken_for_a_backup() {
        let d = tmp();
        let (root, dest) = (d.path().join("live"), d.path().join("backups"));
        w(&root, "inbox.md", "[2026-11-09 08:00:00] x\n");
        w(&root, "journal/2026/11/08.md", "[2026-11-08 08:00:00] filed\n");
        // Killed mid-copy: what an interrupted run leaves is hidden and unfinished.
        let partial = ".Quire backup 2026-11-08-120000.partial";
        w(&dest, &format!("{partial}/inbox.md"), "[2026-11-08 08:00:00] half\n");
        assert!(list_backups(&dest).is_empty());
        assert!(restore(&jn(&root), &dest, partial).unwrap_err().contains("Bad backup name"));
        let made = backup(&jn(&root), &dest).unwrap();
        assert_eq!(list_backups(&dest).len(), 1);
        assert_eq!(prune_backups(&dest, 1).unwrap(), 0, "it takes no retention slot");
        assert!(Path::new(&made).is_dir() && dest.join(partial).is_dir(), "a young partial may be another window's backup");
        assert_eq!(sweep_partial_backups(&dest, Duration::ZERO), 1);
        assert!(!dest.join(partial).exists() && Path::new(&made).is_dir());
        // A copy that fails its check leaves nothing behind under either name.
        let before = fs::read_dir(&dest).unwrap().count();
        let failed = copy_to_new_backup(&root, &dest, true, BACKUP_PREFIX, || {
            let half = fs::read_dir(&dest).unwrap().flatten().find(|e| e.file_name().to_string_lossy().ends_with(".partial")).expect("copied under a partial name");
            fs::remove_file(half.path().join("journal/2026/11/08.md")).unwrap();
        });
        assert!(failed.unwrap_err().contains("doesn't match"));
        assert_eq!(fs::read_dir(&dest).unwrap().count(), before);
    }

    // B4
    #[test]
    fn pruning_holds_back_when_the_newest_backup_has_shrunk() {
        let d = tmp();
        let dest = d.path().join("backups");
        let full = "x".repeat(200 * 1024);
        for day in 1..=3 {
            w(&dest, &format!("Quire backup 2026-11-0{day}-000000/journal/2026/11/01.md"), &full);
        }
        // The journal folder came back nearly empty (a sync gone wrong).
        w(&dest, "Quire backup 2026-11-04-000000/inbox.md", "[2026-11-04 08:00:00] only this\n");
        let held = prune_backups_checked(&dest, 2).unwrap();
        assert_eq!(held.removed, 0);
        assert!(held.held.as_deref().unwrap().contains("much smaller"), "{held:?}");
        assert_eq!(prune_backups(&dest, 2).unwrap(), 0, "the plain call removes nothing either, without failing the backup");
        assert_eq!(list_backups(&dest).len(), 4, "every good backup is still there");
        // It really is that small now: the next backup is like the last, and pruning resumes.
        w(&dest, "Quire backup 2026-11-05-000000/inbox.md", "[2026-11-04 08:00:00] only this\n");
        let p = prune_backups_checked(&dest, 2).unwrap();
        assert_eq!((p.removed, p.held.is_none()), (3, true));
        assert_eq!(list_backups(&dest), ["Quire backup 2026-11-05-000000", "Quire backup 2026-11-04-000000"]);
        // Backups kept apart by journal.
        let (a, b) = (d.path().join("one/Journal"), d.path().join("two/Journal"));
        fs::create_dir_all(&a).unwrap();
        fs::create_dir_all(&b).unwrap();
        assert_ne!(journal_key(&a), journal_key(&b));
        assert_eq!(journal_key(&a), journal_key(&a.join(".")));
        assert!(journal_key(&a).starts_with("Journal-") && backup_dir_for(&dest, &a).starts_with(&dest));
    }

    // B5
    #[test]
    fn what_an_interrupted_restore_left_is_swept_or_reported() {
        let d = tmp();
        let root = d.path();
        w(root, ".quire-restore-new-20261109-080000-1/journal/2026/11/01.md", "staged");
        w(root, ".quire-restore-old-20261109-080000-1/journal/2026/11/01.md", "what was here");
        w(root, "journal/2026/11/01.md", "live");
        let young = restore_leftovers(root, Duration::from_secs(3600));
        assert_eq!((young.swept, young.old.len()), (0, 1), "a restore may be running in another window");
        let found = restore_leftovers(root, Duration::ZERO);
        assert_eq!(found.swept, 1);
        assert_eq!(found.old, vec![".quire-restore-old-20261109-080000-1"]);
        assert!(!root.join(".quire-restore-new-20261109-080000-1").exists());
        assert_eq!(read(&root.join(".quire-restore-old-20261109-080000-1/journal/2026/11/01.md")), "what was here", "never removed, only reported");
        assert_eq!(read(&root.join("journal/2026/11/01.md")), "live");
    }

    // C6, C15
    #[test]
    fn markdown_folder_import_skips_dot_folders_and_keeps_loose_text() {
        let d = tmp();
        let src = d.path().join("src");
        for hidden in [".trash", ".stversions", ".obsidian/plugins"] {
            fs::create_dir_all(src.join(hidden)).unwrap();
            fs::write(src.join(hidden).join("2026-09-01 old.md"), "Deleted long ago").unwrap();
        }
        fs::create_dir_all(src.join("notes")).unwrap();
        // jnl's format from a Windows editor (BOM, CRLF), with a line above the first header.
        fs::write(src.join("notes/2026-09-28 log.md"), "\u{FEFF}Written on the train.\r\n\r\n[2026-09-28 07:00:00] First\r\none\r\ntwo\r\n\r\n[2026-09-28 09:00:00] Second\r\nthree\r\n").unwrap();
        let root = d.path().join("root");
        fs::create_dir_all(&root).unwrap();
        let r = import_markdown_folder(&jn(&root), &src, false).unwrap();
        assert_eq!((r.found, r.written, r.skipped), (3, 3, 0), "{r:?}");
        assert_eq!(
            read(&root.join("journal/2026/09/28.md")),
            "[2026-09-28 07:00:00] First\none\ntwo\n\n[2026-09-28 09:00:00] Second\nthree\n\n[2026-09-28 12:00:00] 2026-09-28 log\nWritten on the train.\n"
        );
        assert!(!root.join("journal/2026/09/01.md").exists());
        let again = import_markdown_folder(&jn(&root), &src, false).unwrap();
        assert_eq!((again.written, again.skipped), (0, 3), "and a second import adds nothing");
    }

    #[test]
    fn dayone_reimport_matches_a_title_with_doubled_spaces() {
        let d = tmp();
        let json = d.path().join("Journal.json");
        fs::write(&json, r##"{"entries":[{"creationDate":"2026-09-30T08:00:00Z","timeZone":"UTC","text":"# Two  spaces   here\n\nBody\r\nsecond line"}]}"##).unwrap();
        let root = d.path().join("root");
        fs::create_dir_all(&root).unwrap();
        assert_eq!(import_day_one(&jn(&root), &json, false).unwrap().written, 1);
        assert_eq!(read(&root.join("journal/2026/09/30.md")), "[2026-09-30 08:00:00] Two spaces here\nBody\nsecond line\n");
        let again = import_day_one(&jn(&root), &json, false).unwrap();
        assert_eq!((again.written, again.skipped), (0, 1));
    }

    // C15
    #[test]
    fn tag_rename_leaves_link_targets_and_code_alone() {
        let text = "[2026-09-30 08:00:00] plans @home\nat @home ![](assets/@home/x.jpg) and `ssh dan@box @home`\n```\necho @home\n```\nafter @home\n\n[2026-10-01 08:00:00]\n```\nnever closed @home\n\n[2026-10-02 08:00:00]\nnext entry @home\n";
        assert_eq!(
            replace_tags(text, &["@home".into()], "@house"),
            "[2026-09-30 08:00:00] plans @house\nat @house ![](assets/@home/x.jpg) and `ssh dan@box @home`\n```\necho @home\n```\nafter @house\n\n[2026-10-01 08:00:00]\n```\nnever closed @home\n\n[2026-10-02 08:00:00]\nnext entry @house\n"
        );
    }

    #[test]
    fn punctuation_keeps_a_link_whose_name_has_brackets() {
        assert_eq!(fix_punctuation("So... ![](assets/2026/09/image(1)...final.jpg) done..."), "So\u{2026} ![](assets/2026/09/image(1)...final.jpg) done\u{2026}");
    }

    fn restore_fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let t = tempfile::tempdir().unwrap();
        let (root, src) = (t.path().join("live"), t.path().join("backup"));
        for (dir, text) in [(&root, "live"), (&src, "backup")] {
            fs::create_dir_all(dir.join("journal/2026/11")).unwrap();
            fs::write(dir.join("journal/2026/11/06.md"), text).unwrap();
            fs::write(dir.join("transfer.md"), text).unwrap();
        }
        fs::write(root.join("only-live.md"), "live").unwrap();
        fs::create_dir(root.join(".stfolder")).unwrap();
        (t, root, src)
    }

    #[test]
    fn restore_swaps_and_keeps_hidden_items() {
        let (_t, root, src) = restore_fixture();
        swap_in_backup(&root, &src, |_| Ok(())).unwrap();
        assert_eq!(fs::read_to_string(root.join("journal/2026/11/06.md")).unwrap(), "backup");
        assert!(!root.join("only-live.md").exists());
        assert!(root.join(".stfolder").is_dir());
        let left: Vec<_> = fs::read_dir(&root).unwrap().flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with(".quire-restore")).collect();
        assert!(left.is_empty());
    }

    #[test]
    fn restore_failing_partway_leaves_the_journal_as_it_was() {
        // Fail at every possible step of the swap in turn.
        let moves = {
            let (_t, root, src) = restore_fixture();
            let mut n = 0;
            swap_in_backup(&root, &src, |_| { n += 1; Ok(()) }).unwrap();
            n
        };
        for fail_at in 0..moves {
            let (_t, root, src) = restore_fixture();
            let before = tree_stats(&root, false).unwrap();
            let mut n = 0;
            let r = swap_in_backup(&root, &src, |_| {
                n += 1;
                if n > fail_at { Err("disk went away".into()) } else { Ok(()) }
            });
            assert!(r.is_err());
            assert_eq!(fs::read_to_string(root.join("journal/2026/11/06.md")).unwrap(), "live");
            assert!(root.join("only-live.md").exists());
            assert_eq!(tree_stats(&root, false).unwrap(), before);
            assert!(fs::read_dir(&root).unwrap().flatten()
                .all(|e| !e.file_name().to_string_lossy().starts_with(".quire-restore")));
        }
    }

    #[test]
    fn verify_copy_notices_a_short_copy() {
        let (_t, root, src) = restore_fixture();
        assert!(verify_copy(&root, &src, true).is_err());
        let copy = root.parent().unwrap().join("copy");
        copy_tree(&root, &copy, true).unwrap();
        verify_copy(&root, &copy, true).unwrap();
        fs::write(copy.join("transfer.md"), "x").unwrap();
        assert!(verify_copy(&root, &copy, true).is_err());
    }

    #[test]
    fn backup_lock() {
        let g = BackupGuard::acquire().unwrap();
        assert!(BackupGuard::acquire().is_err());
        drop(g);
        assert!(BackupGuard::acquire().is_ok());
    }

    #[test]
    fn due_logic() {
        assert!(!backup_due("off", None));
        assert!(backup_due("daily", None));
        assert!(!backup_due("daily", Some(&now_local())));
        let old = add_secs(&now_local(), -2 * 86_400).unwrap();
        assert!(backup_due("daily", Some(&old)));
        assert!(!backup_due("weekly", Some(&old)));
    }

    #[test]
    fn tag_review_grouping() {
        let d = tmp();
        w(d.path(), "inbox.md", "[2026-09-30 08:00:00]\n@home @hope @cats @cars @Running @running @readng @reading @reading @reading @reading\n");
        let g = tag_review(&jn(d.path()));
        let names: Vec<Vec<String>> = g.iter().map(|g| g.tags.iter().map(|t| t.0.clone()).collect()).collect();
        assert_eq!(names.len(), 2, "{:?}", names);
        assert!(names.iter().any(|g| g.contains(&"@Running".into()) && g.contains(&"@running".into())));
        assert!(names.iter().any(|g| g.contains(&"@readng".into()) && g.contains(&"@reading".into())));
    }

    #[test]
    fn punctuation_skips_links() {
        assert_eq!(fix_punctuation("Well... “hi” it’s ![a...b](x...y.jpg) [l’](a’b)"), "Well\u{2026} \"hi\" it's ![a...b](x...y.jpg) [l’](a’b)");
    }

    #[test]
    fn remove_ds_store_only_exact_files_without_following_symlinks() {
        let d = tmp();
        for rel in [
            ".DS_Store",
            "assets/2026/10/.DS_Store",
            ".quire/.DS_Store",
            "journal/keep.md",
            "assets/DS_Store",
            "assets/._photo.jpg",
        ] {
            w(d.path(), rel, "keep");
        }
        let outside = tmp();
        w(outside.path(), ".DS_Store", "outside");
        #[cfg(unix)]
        std::os::unix::fs::symlink(outside.path(), d.path().join("linked")).unwrap();
        let j = jn(d.path());
        let (removed, errors) = remove_ds_store(&j);
        assert_eq!(removed, 3);
        assert!(errors.is_empty(), "{errors:?}");
        for rel in ["journal/keep.md", "assets/DS_Store", "assets/._photo.jpg"] {
            assert_eq!(read(&d.path().join(rel)), "keep");
        }
        assert!(outside.path().join(".DS_Store").exists());
        assert_eq!(remove_ds_store(&j), (0, vec![]));
    }

    #[test]
    fn cleanup_macro() {
        let d = tmp();
        w(
            d.path(),
            "journal/2026/09/30.md",
            "[2026-09-30 10:00:00] b...\nx\n\n[2026-09-30 08:00:00] a\ny\n\n[2026-09-30 08:00:00] a\ny\n\n[2026-09-30 09:00:00] w @work\n  ![](../../../assets/p.jpg)  \n",
        );
        w(d.path(), "journal/2026/09/29.md", "[2026-09-29 08:00:00] fine\n");
        fs::write(d.path().join("journal/2026/09/28.md"), b"[2026-09-28 08:00:00] caf\xe9\n").unwrap();
        w(d.path(), "inbox.md", "[2026-09-30 09:00:00] i2\n\n[2026-09-30 08:00:00] i1\n\n[2026-09-30 08:00:00] i1\n");
        w(d.path(), "inbox/2026/10/01.md", "[2026-10-01 09:00:00] d2\n\n[2026-10-01 08:00:00] d1\n");
        let r = cleanup(&jn(d.path()), &["work".into()]).unwrap();
        assert_eq!((r.formatted, r.reordered, r.deduped, r.extracted, r.errors.len()), (1, 3, 2, 1, 1), "{:?}", r);
        assert_eq!(read(&d.path().join("inbox/2026/10/01.md")), "[2026-10-01 08:00:00] d1\n\n[2026-10-01 09:00:00] d2\n");
        assert_eq!(read(&d.path().join("journal/2026/09/30.md")), "[2026-09-30 08:00:00] a\ny\n\n[2026-09-30 10:00:00] b\u{2026}\nx\n");
        assert_eq!(read(&d.path().join("split/work/2026/09/30.md")), "[2026-09-30 09:00:00] w @work\n![](assets/p.jpg)\n");
        assert_eq!(read(&d.path().join("inbox.md")), "[2026-09-30 08:00:00] i1\n\n[2026-09-30 09:00:00] i2\n");
        let r2 = cleanup(&jn(d.path()), &["work".into()]).unwrap();
        assert_eq!((r2.formatted, r2.reordered, r2.deduped, r2.extracted), (0, 0, 0, 0));
        assert!(sort_inbox(&jn(d.path())).unwrap() == false);
    }

    #[test]
    fn cleanup_rehomes_misdated_entries() {
        let d = tmp();
        // The 14th's entries pasted into the 20th: one new, one already on the 14th.
        w(d.path(), "inbox/2026/10/14.md", "[2026-10-14 09:00:00] kept\n");
        w(d.path(), "inbox/2026/10/20.md", "[2026-10-20 08:00:00] today\n\n[2026-10-14 08:00:00] early\n\n[2026-10-14 09:00:00] kept\n");
        w(d.path(), "journal/2026/10/20.md", "[2026-10-15 07:00:00] filed\n![](../../../assets/p.jpg)\n");
        w(d.path(), "split/work/2026/10/20.md", "[2026-10-16 07:00:00] w @work\n");
        w(d.path(), "inbox.md", "[2026-10-01 07:00:00] legacy\n");
        let r = cleanup(&jn(d.path()), &["work".into()]).unwrap();
        assert_eq!((r.moved, r.deduped, r.errors.len()), (3, 1, 0), "{:?}", r);
        assert_eq!(read(&d.path().join("inbox/2026/10/14.md")), "[2026-10-14 08:00:00] early\n\n[2026-10-14 09:00:00] kept\n");
        assert_eq!(read(&d.path().join("inbox/2026/10/20.md")), "[2026-10-20 08:00:00] today\n");
        assert!(!d.path().join("journal/2026/10/20.md").exists());
        assert_eq!(read(&d.path().join("journal/2026/10/15.md")), "[2026-10-15 07:00:00] filed\n![](assets/p.jpg)\n");
        assert!(!d.path().join("split/work/2026/10/20.md").exists());
        assert_eq!(read(&d.path().join("split/work/2026/10/16.md")), "[2026-10-16 07:00:00] w @work\n");
        assert_eq!(read(&d.path().join("inbox.md")), "[2026-10-01 07:00:00] legacy\n");
        let r2 = cleanup(&jn(d.path()), &["work".into()]).unwrap();
        assert_eq!((r2.moved, r2.deduped), (0, 0));
    }

    #[test]
    fn file_all_macro() {
        let d = tmp();
        w(d.path(), "journal/2026/09/30.md", "[2026-09-30 12:00:00] noon\n");
        w(
            d.path(),
            "inbox.md",
            "pre\n\n[2026-09-30 13:00:00] late\n\n[2026-09-30 08:00:00]\n\n[2026-09-30 09:00:00] early   *\n![](./assets/x.jpg)\n\n[2026-09-30 10:00:00] job @work\n",
        );
        w(d.path(), "inbox/2026/09/29.md", "[2026-09-29 08:00:00] day draft\n");
        let r = file_all(&jn(d.path()), &["work".into()]).unwrap();
        assert_eq!((r.filed, r.skipped), (4, 1));
        assert_eq!(read(&d.path().join("inbox.md")), "pre\n\n[2026-09-30 08:00:00]\n");
        assert!(!d.path().join("inbox/2026/09/29.md").exists(), "emptied day file deleted");
        assert_eq!(read(&d.path().join("journal/2026/09/29.md")), "[2026-09-29 08:00:00] day draft\n");
        assert_eq!(
            read(&d.path().join("journal/2026/09/30.md")),
            "[2026-09-30 09:00:00] early *\n![](assets/x.jpg)\n\n[2026-09-30 12:00:00] noon\n\n[2026-09-30 13:00:00] late\n"
        );
        assert_eq!(read(&d.path().join("split/work/2026/09/30.md")), "[2026-09-30 10:00:00] job @work\n");
    }

    #[test]
    fn merge_ex_split_macro() {
        let d = tmp();
        w(d.path(), "old.md", "[2026-09-30 09:00:00] o1\n![](../x.jpg) ![](./assets/y.jpg)\n\n[2026-10-01 09:00:00] o2\n");
        w(d.path(), "notes.md", "My notes\n\n[2026-09-30 07:00:00] n1\n");
        w(d.path(), "work.md", "[2026-09-30 07:00:00] w1\n");
        w(d.path(), "readme.md", "[2026-09-30 07:00:00] r1\n");
        w(d.path(), "journal/2026/09/30.md", "[2026-09-30 08:00:00] here\n");
        let r = merge_ex_split(&jn(d.path()), &["Work".into()]).unwrap();
        assert_eq!((r.entries, r.journals), (3, 2), "{:?}", r);
        assert!(!d.path().join("old.md").exists());
        assert_eq!(read(&d.path().join("notes.md")), "My notes\n");
        assert!(d.path().join("work.md").exists() && d.path().join("readme.md").exists());
        assert_eq!(
            read(&d.path().join("journal/2026/09/30.md")),
            "[2026-09-30 07:00:00] n1\n\n[2026-09-30 08:00:00] here\n\n[2026-09-30 09:00:00] o1\n![](../x.jpg) ![](assets/y.jpg)\n"
        );
        assert_eq!(read(&d.path().join("journal/2026/10/01.md")), "[2026-10-01 09:00:00] o2\n");
        // A split/ journal whose tag was dropped: its day files fold back too.
        w(d.path(), "split/gone/2026/10/02.md", "[2026-10-02 09:00:00] g1\n");
        w(d.path(), "split/work/2026/10/02.md", "[2026-10-02 10:00:00] w2\n");
        let r = merge_ex_split(&jn(d.path()), &["work".into()]).unwrap();
        assert_eq!((r.entries, r.journals), (1, 1), "{:?}", r);
        assert!(!d.path().join("split/gone/2026/10/02.md").exists());
        assert!(d.path().join("split/work/2026/10/02.md").exists());
        assert_eq!(read(&d.path().join("journal/2026/10/02.md")), "[2026-10-02 09:00:00] g1\n");
    }

    #[test]
    fn merge_conflict_copy() {
        let d = tmp();
        w(d.path(), "journal/2026/09/30.md", "[2026-09-30 10:00:00] a\n\n[2026-09-30 12:00:00] c\n");
        let c = "journal/2026/09/30.sync-conflict-20260930-120000-ABC.md";
        w(d.path(), c, "[2026-09-30 10:00:00] a\n\n[2026-09-30 11:00:00] b\n");
        assert_eq!(jn(d.path()).conflict_files(), vec![c.to_string()]);
        assert!(merge_conflict(&jn(d.path()), "journal/2026/09/30.md").is_err());
        assert!(merge_conflict(&jn(d.path()), "../x.sync-conflict-1.md").is_err());
        assert_eq!(merge_conflict(&jn(d.path()), c).unwrap(), 1);
        assert_eq!(read(&d.path().join("journal/2026/09/30.md")), "[2026-09-30 10:00:00] a\n\n[2026-09-30 11:00:00] b\n\n[2026-09-30 12:00:00] c\n");
        assert!(jn(d.path()).conflict_files().is_empty());
    }

    #[test]
    fn split_tag_sources() {
        assert_eq!(resolve_split_tags(&Some("@a, b".into()), Some("c".into()), Some("d".into())), (vec!["a".to_string(), "b".to_string()], "settings"));
        assert_eq!(resolve_split_tags(&None, Some("c inbox".into()), Some("d".into())), (vec!["c".to_string()], "env"));
        assert_eq!(resolve_split_tags(&None, None, Some("d".into())).1, "jnl config");
        assert_eq!(resolve_split_tags(&None, None, None), (vec![], "none"));
        let m = parse_jnl_config("# jnl\n: \"${JNL_DIR:=$HOME/journal}\"\n:   \"${JNL_SPLIT_TAGS:=work dream}\"\nexport X=1\n");
        assert_eq!(m.get("JNL_DIR").unwrap(), "$HOME/journal");
        assert_eq!(m.get("JNL_SPLIT_TAGS").unwrap(), "work dream");
        assert!(check_split_tags("work, @Inbox").is_err());
        assert!(check_split_tags("work dream").is_ok());
        assert!(expand_home("$HOME/j").ends_with("/j") && !expand_home("$HOME/j").starts_with('$'));
    }

    #[test]
    fn temp_sweep() {
        let d = tmp();
        fs::create_dir_all(d.path().join("journal/2026")).unwrap();
        for n in ["journal/2026/.quire-abc.tmp", ".nook-x.tmp", "._tmp_y", "keep.md", ".quire-z.md"] {
            fs::write(d.path().join(n), b"x").unwrap();
        }
        assert_eq!(sweep_temps(d.path(), Duration::from_secs(3600)), 0);
        assert_eq!(sweep_temps(d.path(), Duration::ZERO), 3);
        assert!(d.path().join("keep.md").exists() && d.path().join(".quire-z.md").exists());
    }

    #[test]
    fn stats() {
        let d = tmp();
        w(d.path(), "inbox.md", "[2026-09-30 08:00:00]\none two @x\n");
        w(d.path(), "journal/2026/09/30.md", "[2026-09-30 08:00:00]\na b c d\n\n[2026-09-30 09:00:00]\ne f @y\n");
        w(d.path(), "journal/2026/09/29.md", "[2026-09-29 08:00:00]\na\n");
        w(d.path(), "work.md", "[2026-09-29 08:00:00]\na b\n");
        let s = stats_extra(&jn(d.path()));
        assert_eq!((s.drafts, s.tags, s.splits), (1, 2, 1));
        assert_eq!(s.longest_day.date, "2026-09-30");
        assert_eq!(s.longest_day.words, 7);
        assert_eq!(s.avg_words_per_entry, 2.5);
        assert!(s.sizes_by_location.journal > 0 && s.sizes_by_location.media == 0);
    }
}
