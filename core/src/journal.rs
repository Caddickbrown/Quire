//! The jnl on-disk format, byte-compatible with jnl's main.go:
//!
//!   <dir>/inbox.md              undated drafts
//!   <dir>/journal/YYYY/MM/DD.md filed entries, one file per day
//!   <dir>/<tag>.md              split journals (JNL_SPLIT_TAGS)
//!
//! Each entry is `[YYYY-MM-DD HH:MM:SS] optional title` followed by its body.
//! Entries are separated by one blank line. A trailing ` *` on the title stars
//! it. Anything before the first header (a "preamble") is preserved on rewrite.

use once_cell::sync::Lazy;
use regex::Regex;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Component, Path, PathBuf};

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
    } else if let Some(c) = l.find("conflicted copy") {
        let open = l[..c].rfind('(')?;
        let close = c + l[c..].find(')')?;
        let before = name[..open].trim_end();
        format!("{}{}", before, &name[close + 1..])
    } else {
        return None;
    };
    if main.is_empty() || main == name {
        return None;
    }
    Some(format!("{}{}", dir, main))
}

/// Validate a root-relative path that came from the front end: no absolute
/// paths, no `..`, no backslashes, not empty. Returns `root.join(rel)`.
pub fn safe_rel(root: &Path, rel: &str) -> Result<PathBuf, String> {
    let bad = || format!("Refusing unsafe path {:?}", rel);
    if rel.trim().is_empty() || rel.contains('\\') || rel.contains('\0') {
        return Err(bad());
    }
    let p = Path::new(rel);
    if p.is_absolute() {
        return Err(bad());
    }
    for c in p.components() {
        match c {
            Component::Normal(_) | Component::CurDir => {}
            _ => return Err(bad()),
        }
    }
    Ok(root.join(p))
}

/// safe_rel plus: must be a `.md` file outside the `.nook/` and `assets/`
/// sidecars (an entry file: inbox, a day file or a split journal).
pub fn safe_entry_rel(root: &Path, rel: &str) -> Result<PathBuf, String> {
    let p = safe_rel(root, rel)?;
    let r = rel.trim_start_matches("./");
    if !r.to_lowercase().ends_with(".md") || r.starts_with(".nook/") || r.starts_with("assets/") {
        return Err(format!("{:?} is not an entry file", rel));
    }
    Ok(p)
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
    /// Path relative to the journal folder, e.g. `inbox.md`, `journal/2026/09/30.md`.
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
pub fn write_atomic(path: &Path, content: &str) -> Result<(), String> {
    let dir = path.parent().ok_or("no parent folder")?;
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let mut tmp = tempfile::Builder::new()
        .prefix(".quire-")
        .suffix(".tmp")
        .tempfile_in(dir)
        .map_err(|e| e.to_string())?;
    tmp.write_all(content.as_bytes()).map_err(|e| e.to_string())?;
    tmp.as_file().sync_all().map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(tmp.path(), fs::Permissions::from_mode(0o644));
    }
    tmp.persist(path).map_err(|e| e.to_string())?;
    Ok(())
}

/// Lenient read for display paths: anything unreadable is "".
pub fn read(path: &Path) -> String {
    try_read(path).unwrap_or_default()
}

/// Strict read for read-modify-write paths. A missing file is Ok(""); any
/// other failure (non-UTF-8 bytes, permissions) is an error so a writer never
/// mistakes an unreadable file for an empty one and overwrites it.
pub fn try_read(path: &Path) -> Result<String, String> {
    match fs::read_to_string(path) {
        Ok(s) => Ok(s),
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
    format!("journal/{}/{}/{}.md", p[0], p[1], p[2])
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

/// Every `.md` under `dir` (no symlinked folders), conflict copies excluded.
pub fn walk_md(dir: &Path, out: &mut Vec<PathBuf>) {
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            let ft = match e.file_type() {
                Ok(t) => t,
                Err(_) => continue,
            };
            let name = e.file_name().to_string_lossy().to_string();
            if ft.is_dir() {
                walk_md(&p, out);
            } else if p.is_file() && name.ends_with(".md") && !name.starts_with('.') && !is_conflict_name(&name) {
                out.push(p);
            }
        }
    }
}

pub fn rel_of(root: &Path, p: &Path) -> String {
    p.strip_prefix(root).unwrap_or(p).to_string_lossy().replace('\\', "/")
}

/// Root `.md` files that are split journals (not reserved, not conflict
/// copies, not hidden), sorted by name.
pub fn split_files(root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    if let Ok(rd) = fs::read_dir(root) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if e.path().is_file()
                && name.ends_with(".md")
                && !name.starts_with('.')
                && !is_reserved(&name)
                && !is_conflict_name(&name)
            {
                out.push(name);
            }
        }
    }
    out.sort();
    out
}

/// Every entry file as (root-relative path, source, split tag), in load order.
pub fn entry_files(root: &Path) -> Vec<(String, &'static str, Option<String>)> {
    let mut out = vec![("inbox.md".to_string(), "inbox", None)];
    let mut files = Vec::new();
    walk_md(&root.join("journal"), &mut files);
    files.sort();
    for f in files {
        out.push((rel_of(root, &f), "journal", None));
    }
    for name in split_files(root) {
        let tag = name.trim_end_matches(".md").to_string();
        out.push((name, "split", Some(tag)));
    }
    out
}

/// Conflict copies of entry files (root and journal/**), root-relative.
pub fn conflict_files(root: &Path) -> Vec<String> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>, recurse: bool) {
        if let Ok(rd) = fs::read_dir(dir) {
            for e in rd.flatten() {
                let p = e.path();
                let Ok(ft) = e.file_type() else { continue };
                let name = e.file_name().to_string_lossy().to_string();
                if ft.is_dir() {
                    if recurse {
                        walk(&p, out, true);
                    }
                } else if ft.is_file() && name.to_lowercase().ends_with(".md") && is_conflict_name(&name) {
                    out.push(p);
                }
            }
        }
    }
    let mut v = Vec::new();
    walk(root, &mut v, false);
    walk(&root.join("journal"), &mut v, true);
    let mut out: Vec<String> = v.iter().map(|p| rel_of(root, p)).collect();
    out.sort();
    out
}

/// Lenient load: unreadable files contribute nothing.
pub fn load_all(root: &Path) -> Vec<Entry> {
    load_all_with(root, false).unwrap_or_default()
}

/// Strict load: Err if any entry file cannot be read (used before destructive
/// operations such as deleting orphaned assets).
pub fn try_load_all(root: &Path) -> Result<Vec<Entry>, String> {
    load_all_with(root, true)
}

fn load_all_with(root: &Path, strict: bool) -> Result<Vec<Entry>, String> {
    let mut out = Vec::new();
    for (rel, source, split) in entry_files(root) {
        let content = if strict { try_read(&root.join(&rel))? } else { read(&root.join(&rel)) };
        for (i, r) in parse_entries(&content).iter().enumerate() {
            out.push(to_entry(r, &rel, i, source, split.clone()));
        }
    }
    Ok(out)
}

/// Locate an entry in a file by its raw text, preferring the expected index.
/// Returns the file's preamble, all raws, and the matching position.
pub fn locate(root: &Path, file: &str, index: usize, expected_raw: &str) -> Result<(String, Vec<String>, usize), String> {
    let content = try_read(&root.join(file))?;
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

pub fn write_file_entries(root: &Path, file: &str, pre: &str, raws: &[String]) -> Result<(), String> {
    write_atomic(&root.join(file), &render(pre, raws))
}

/// Append `raw` to a file the way jnl's fileDraft does (blank-line separated).
/// Returns the index of the (first) appended entry in the file.
pub fn append_raw(root: &Path, file: &str, raw: &str) -> Result<usize, String> {
    let path = root.join(file);
    let mut s = try_read(&path)?;
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
    write_atomic(&path, &s)?;
    Ok(before)
}

/// Insert every entry parsed from each of `raws` into `file`, each after the
/// last entry whose ts is <= its own (stable, so a file already in order
/// stays in order). One read and one write. With `skip_existing`, an entry
/// whose exact raw (trim_end) is already in the file is not inserted again
/// (makes destination-first moves safe to retry).
///
/// Returns the final indices of the inserted entries, in input order
/// (`None` for skipped ones). Errors if any raw parses to zero entries.
pub fn insert_entries(root: &Path, file: &str, raws: &[String], skip_existing: bool) -> Result<Vec<Option<usize>>, String> {
    let content = try_read(&root.join(file))?;
    let pre = leading_preamble(&content);
    // (entry, Some(input position) if new)
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
        write_file_entries(root, file, &pre, &rendered)?;
    }
    let mut pos_of: HashMap<usize, usize> = HashMap::new();
    for (i, (_, t)) in entries.iter().enumerate() {
        if let Some(t) = t {
            pos_of.insert(*t, i);
        }
    }
    Ok(out_slots.iter().map(|s| s.first().and_then(|t| pos_of.get(t).copied())).collect())
}

/// Insert into a file keeping it in timestamp order (stable). Inserts every
/// entry parsed from `raw`; errors if there are none. Returns the index of
/// the first inserted entry.
pub fn insert_sorted(root: &Path, file: &str, raw: &str) -> Result<usize, String> {
    let r = insert_entries(root, file, &[raw.to_string()], false)?;
    r.first().copied().flatten().ok_or_else(|| "bad entry".to_string())
}

/// The split journal a raw entry belongs in (`work.md`), honouring the order
/// of `split_tags`. Reserved names are never targets.
pub fn split_target(raw: &str, split_tags: &[String]) -> Option<String> {
    let present: Vec<&str> = TAG_RE.find_iter(raw).map(|m| m.as_str()).collect();
    for t in split_tags {
        let t = if t.starts_with('@') { t.clone() } else { format!("@{}", t) };
        if is_reserved(&t) {
            continue;
        }
        if present.contains(&t.as_str()) {
            return Some(format!("{}.md", t.trim_start_matches('@')));
        }
    }
    None
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

    #[test]
    fn split() {
        assert_eq!(split_target("x @work y", &["work".into()]), Some("work.md".into()));
        assert_eq!(split_target("x @workshop", &["work".into()]), None);
        assert_eq!(split_target("x @inbox", &["inbox".into()]), None);
        assert_eq!(split_target("x @Nook-Export", &["nook-export".into()]), None);
    }

    #[test]
    fn unicode_digits_do_not_match() {
        // Arabic-Indic digits: must not be a header (and must not panic).
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
        // Idempotent through a rebuild.
        assert_eq!(rebuild(&e[0]), raw);
        // A first body line is guarded too.
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
        let d = tempfile::tempdir().unwrap();
        fs::create_dir_all(d.path().join("journal/2026/10")).unwrap();
        fs::write(d.path().join("journal/2026/10/01.md"), "[2026-10-01 08:00:00] a\n").unwrap();
        fs::write(d.path().join("journal/2026/10/01.sync-conflict-1-2-X.md"), "[2026-10-01 09:00:00] b\n").unwrap();
        fs::write(d.path().join("inbox (conflicted copy).md"), "[2026-10-01 09:00:00] b\n").unwrap();
        fs::write(d.path().join("readme.md"), "[2026-10-01 09:00:00] b\n").unwrap();
        let files: Vec<String> = entry_files(d.path()).into_iter().map(|f| f.0).collect();
        assert_eq!(files, vec!["inbox.md", "journal/2026/10/01.md"]);
        assert_eq!(conflict_files(d.path()), vec!["inbox (conflicted copy).md", "journal/2026/10/01.sync-conflict-1-2-X.md"]);
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
        assert!(safe_entry_rel(r, "inbox.md").is_ok());
        assert!(safe_entry_rel(r, "inbox.txt").is_err());
    }

    // #2: a file with invalid UTF-8 must not be mistaken for empty and overwritten.
    #[test]
    fn append_raw_refuses_unreadable_file() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("inbox.md");
        let orig: &[u8] = b"[2026-09-30 08:00:00] caf\xe9\nold body\n";
        fs::write(&p, orig).unwrap();
        let r = append_raw(d.path(), "inbox.md", "[2026-09-30 09:00:00] new\nbody");
        assert!(r.is_err());
        assert_eq!(fs::read(&p).unwrap(), orig, "file must be untouched");
        assert!(insert_sorted(d.path(), "inbox.md", "[2026-09-30 09:00:00] new\nbody").is_err());
        assert!(locate(d.path(), "inbox.md", 0, "x").is_err());
        assert!(try_load_all(d.path()).is_err());
        assert_eq!(fs::read(&p).unwrap(), orig);
        // A missing file is still fine to append to.
        append_raw(d.path(), "other.md", "[2026-09-30 09:00:00] new\nbody").unwrap();
        assert_eq!(read(&d.path().join("other.md")), "[2026-09-30 09:00:00] new\nbody\n");
    }

    #[test]
    fn insert_sorted_keeps_all_entries() {
        let d = tempfile::tempdir().unwrap();
        write_atomic(&d.path().join("a.md"), "[2026-09-30 08:00:00] a\n\n[2026-09-30 10:00:00] c\n").unwrap();
        let i = insert_sorted(d.path(), "a.md", "[2026-09-30 09:00:00] b\n\n[2026-09-30 11:00:00] d").unwrap();
        assert_eq!(i, 1);
        let e = parse_entries(&read(&d.path().join("a.md")));
        let ts: Vec<&str> = e.iter().map(|x| &x.ts[11..13]).collect();
        assert_eq!(ts, vec!["08", "09", "10", "11"]);
        assert!(insert_sorted(d.path(), "a.md", "no header").is_err());
        // Equal timestamps go after existing ones; skip_existing dedupes.
        let r = insert_entries(d.path(), "a.md", &["[2026-09-30 08:00:00] a".into(), "[2026-09-30 08:00:00] a2".into()], true).unwrap();
        assert_eq!(r, vec![None, Some(1)]);
    }

    // #6: a title with a newline must stay on the header line.
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
}
