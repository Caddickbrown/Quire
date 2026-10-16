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
    Ok(j.walk_files("assets")
        .into_iter()
        .filter(|rel| !rel.rsplit('/').next().unwrap_or(rel).starts_with('.'))
        .map(|rel| Asset {
            kind: media_kind(&rel),
            bytes: j.len(&rel),
            referenced: idx.is_referenced(&rel),
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

pub fn delete_orphans(j: &Journal) -> Result<usize, String> {
    let mut n = 0;
    // list_assets is Err if any file is unreadable: never delete on a partial view.
    for a in list_assets(j)? {
        if !a.referenced {
            j.remove(&a.rel)?;
            n += 1;
        }
    }
    Ok(n)
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

static LINK_SPAN_RE: Lazy<Regex> = Lazy::new(|| Regex::new(r"!?\[[^\]]*\]\([^)]+\)").unwrap());

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
        let res = j.try_read(&rel).and_then(|fresh| match remove_raws(&fresh, &mut gone) {
            Some(text) => write_removed(j, &rel, &text),
            None => Ok(()),
        });
        if let Err(e) = res {
            rep.errors.push(format!("{}: {}", rel, e));
        }
    }
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
                if let Err(e) = j.write(&rel, &fixed) {
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
            j.write_file_entries(&rel, &pre, &raws)
        } else if formatted {
            j.write(&rel, &fixed)
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
                    match j.write_file_entries(&rel, &pre, &raws) {
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
        j.write_file_entries(&rel, &pre, &raws)?;
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
            let fresh = j.try_read(file)?;
            if let Some(text) = remove_raws(&fresh, &mut gone) {
                write_removed(j, file, &text)?;
            }
        }
    }
    Ok(rep)
}

/// Write a file `remove_raws` thinned; a day file left with no entries is
/// deleted (its preamble, if any, is kept in place).
fn write_removed(j: &Journal, file: &str, text: &str) -> Result<(), String> {
    if is_day_file(file) && parse_entries(text).is_empty() && leading_preamble(text).is_empty() {
        j.remove(file)?;
        return Ok(());
    }
    j.write(file, text)
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
                j.remove(&name).map(|_| ())
            } else {
                j.write(&name, &render(&pre, &[]))
            }
        } else {
            match remove_raws(&content, &mut gone) {
                Some(t) => j.write(&name, &t),
                None => Ok(()),
            }
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
    let mtext = j.try_read(&main_rel)?;
    let mut main = parse_entries(&mtext);
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
    let mut pre = leading_preamble(&mtext);
    let cpre = leading_preamble(&ctext);
    let mut pre_changed = false;
    if !cpre.trim().is_empty() && !pre.contains(cpre.trim()) {
        pre = if pre.is_empty() { cpre } else { format!("{}\n\n{}", pre, cpre) };
        pre_changed = true;
    }
    if added > 0 || pre_changed {
        main.sort_by(|a, b| a.ts.cmp(&b.ts));
        let raws: Vec<String> = main.into_iter().map(|e| e.raw).collect();
        j.write(&main_rel, &render(&pre, &raws))?;
    }
    j.remove(&crel)?;
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
    fs::create_dir_all(to).map_err(|e| e.to_string())?;
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
            copy_tree(&e.path(), &t, false)?;
        } else {
            fs::copy(e.path(), &t).map_err(|e| format!("{}: {}", e, t.display()))?;
        }
    }
    Ok(())
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

fn copy_to_new_backup(root: &Path, dest_dir: &Path, skip_hidden_top: bool) -> Result<PathBuf, String> {
    check_backup_dir(root, dest_dir)?;
    fs::create_dir_all(dest_dir).map_err(|e| e.to_string())?;
    check_backup_dir(root, dest_dir)?;
    let base = format!("{}{}", BACKUP_PREFIX, Local::now().format("%Y-%m-%d-%H%M%S"));
    let mut name = base.clone();
    let mut n = 2;
    while dest_dir.join(&name).exists() {
        name = format!("{}-{}", base, n);
        n += 1;
    }
    let dest = dest_dir.join(&name);
    if let Err(e) = copy_tree(root, &dest, skip_hidden_top) {
        let _ = fs::remove_dir_all(&dest);
        return Err(e);
    }
    Ok(dest)
}

/// Copy the journal into `dest_dir/Quire backup YYYY-MM-DD-HHMMSS` (local
/// time). Returns the backup's full path. Does not prune.
pub fn backup(j: &Journal, dest_dir: &Path) -> Result<String, String> {
    let root = j.local()?;
    Ok(copy_to_new_backup(root, dest_dir, true)?.display().to_string())
}

fn backup_key(name: &str) -> Option<&str> {
    name.strip_prefix(BACKUP_PREFIX).or_else(|| name.strip_prefix(NOOK_BACKUP_PREFIX))
}

/// Keep only the `keep` newest "Quire backup …" folders. Nook's backups and
/// anything else are left alone. Returns the number removed.
pub fn prune_backups(dest_dir: &Path, keep: usize) -> Result<usize, String> {
    let names: Vec<String> = list_backups(dest_dir).into_iter().filter(|n| n.starts_with(BACKUP_PREFIX)).collect();
    let mut n = 0;
    for name in names.iter().skip(keep.max(1)) {
        fs::remove_dir_all(dest_dir.join(name)).map_err(|e| e.to_string())?;
        n += 1;
    }
    Ok(n)
}

/// "Quire backup …" and "Nook-Backup-…" folders, newest first (by the
/// timestamp in the name).
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

/// Restore `dest_dir/name` over `root`. Takes a full safety copy first (named
/// like a normal backup, not pruned), then deletes every item in the root and
/// copies the backup's items in. Returns the safety copy's name.
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
    let safety = copy_to_new_backup(root, dest_dir, false)
        .map_err(|e| format!("Couldn't make a safety copy first ({}); nothing was changed", e))?;
    let safety_name = safety.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let fail = |e: String| format!("Restore failed part-way ({}). Your previous folder is saved as “{}”.", e, safety_name);
    for e in fs::read_dir(root).map_err(|e| fail(e.to_string()))?.flatten() {
        // Leave hidden items other than the sidecars alone: .git, Syncthing's
        // .stfolder/.stignore and the like aren't in backups, so removing them
        // would break things the restore can't put back.
        let n = e.file_name().to_string_lossy().to_string();
        if n.starts_with('.') && n != SIDECAR && n != LEGACY_SIDECAR {
            continue;
        }
        let ft = e.file_type().map_err(|e| fail(e.to_string()))?;
        let r = if ft.is_dir() { fs::remove_dir_all(e.path()) } else { fs::remove_file(e.path()) };
        r.map_err(|err| fail(format!("{}: {}", e.path().display(), err)))?;
    }
    copy_tree(&src, root, false).map_err(fail)?;
    Ok(safety_name)
}

/// Is a daily/weekly/monthly backup due, given the last one (local ts)?
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
pub fn import_markdown_folder(j: &Journal, dir: &Path, dry_run: bool) -> Result<ImportReport, String> {
    let mut rep = ImportReport::default();
    let mut have = existing_key_counts(j)?;
    let mut files = Vec::new();
    walk_all(dir, &mut files);
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
        let parsed = parse_entries(&text);
        let items: Vec<(String, String, String)> = if !parsed.is_empty() {
            parsed
                .into_iter()
                .map(|e| (dedupe_key(&e.ts, &strip_star(&e.suffix), &e.body), journal_rel(&e.date), e.raw.trim_end().to_string()))
                .collect()
        } else {
            let body = text.trim();
            if body.is_empty() {
                continue;
            }
            let Some(date) = first_valid_date(&name).or_else(|| file_date(&f)) else { continue };
            let n = per_date.entry(date.clone()).or_insert(0);
            let ts = add_secs(&format!("{} 12:00:00", date), *n)?;
            *n += 1;
            let stem = f.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
            let title = if stem.trim() == date { String::new() } else { stem };
            let raw = make_raw(&ts, &title, false, body);
            let e = parse_entries(&raw).remove(0);
            vec![(dedupe_key(&ts, &strip_star(&e.suffix), &e.body), journal_rel(&date), raw)]
        };
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
        let key = dedupe_key(&ts, &title, &guard_body(body.trim()));
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
        let starred = e.get("starred").and_then(|s| s.as_bool()).unwrap_or(false);
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
    j.write("transfer.md", &render(&pre, &[]))?;
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

/// Replace whole `@tag` tokens in `s` (case-insensitive match against
/// `from`), skipping any preceded by a letter/digit, `.` or `/` (emails, URLs).
pub fn replace_tags(s: &str, from: &[String], to: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut last = 0;
    for m in TAG_RE.find_iter(s) {
        out.push_str(&s[last..m.start()]);
        let prev = s[..m.start()].chars().next_back();
        let blocked = prev.map(|c| c.is_alphanumeric() || c == '.' || c == '/').unwrap_or(false);
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
    for (rel, n) in &todo {
        j.write(rel, n)?;
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
        assert_eq!(crate::media::read_ledger(d.path(), "DEV").assets.len(), 1, "counted once on this device");
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
        assert_eq!(left.len(), 3, "{:?}", left);
        assert!(left[0].starts_with("Quire backup 2026-10") || left[0] > "Quire backup 2026-01-03".to_string());
        assert!(left.contains(&"Nook-Backup-2026-01-02-000000".to_string()));
        assert!(dest.join("Quire before-restore 2026-01-01-000000").exists());

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
