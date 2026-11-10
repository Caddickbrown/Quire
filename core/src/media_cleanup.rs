//! Conservative media organisation: verified copies first, backed-up references,
//! then archive originals only after every reference update succeeds.
use crate::journal::{link_targets, parse_entries, resolve_link_all, Journal, LINK_TARGET_RE};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use unicode_normalization::UnicodeNormalization;

/// The folder inside the sidecar where recovery copies go, one folder per run
/// named for its UTC time.
const RECOVERY_NAME: &str = "media-cleanup";

/// The recovery folder to write into. Asking the journal for its sidecar
/// means a journal that only has `.nook/` gets it renamed to `.quire/` first,
/// as every other sidecar write does, instead of a second sidecar appearing
/// beside it and hiding Nook's templates.
fn recovery_root(j: &Journal) -> Result<String, String> {
    Ok(format!("{}/{RECOVERY_NAME}", j.sidecar_mut()?))
}

/// A new run's folder: `<sidecar>/media-cleanup/<UTC time>`.
pub(crate) fn new_recovery_run(j: &Journal) -> Result<String, String> {
    Ok(format!("{}/{}", recovery_root(j)?, chrono::Utc::now().format("%Y%m%dT%H%M%S%.9f")))
}

/// Put the file at `rel` into a run's recovery folder as
/// `<run>/<section>/<rel>` without reading it into memory, for media of any
/// size: moved there when `take` is set, otherwise linked (or, on a filesystem
/// without hard links, copied) so `rel` stays in place for the caller to
/// replace. The result is checked against the original's size. Local folders
/// only. Returns the recovery path.
pub(crate) fn park_file(j: &Journal, run: &str, section: &str, rel: &str, take: bool) -> Result<String, String> {
    let dest = format!("{run}/{section}/{rel}");
    check_parents(j, &dest)?;
    let (from, to) = (j.path(rel)?, j.path(&dest)?);
    let size = std::fs::symlink_metadata(&from).map_err(|e| format!("{rel}: {e}"))?.len();
    if let Some(dir) = to.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{dest}: {e}"))?;
    }
    let placed = if take { std::fs::rename(&from, &to) } else { std::fs::hard_link(&from, &to) };
    if placed.is_err() {
        std::fs::copy(&from, &to).map_err(|e| format!("Couldn't keep a recovery copy of {rel}: {e}"))?;
    }
    if std::fs::symlink_metadata(&to).map(|m| m.len()).ok() != Some(size) {
        let _ = std::fs::remove_file(&to);
        return Err(format!("Couldn't keep a recovery copy of {rel}; original kept"));
    }
    if take && placed.is_err() {
        std::fs::remove_file(&from).map_err(|e| format!("{rel}: {e}"))?;
    }
    Ok(dest)
}

/// How names are compared when deciding whether something still points at a
/// file: composed (NFC) and lower-cased. macOS hands back a name in whatever
/// form it was created with and matches it in any case, so a link that works
/// there can differ from the listing in both.
fn fold(s: &str) -> String {
    s.nfc().collect::<String>().to_lowercase()
}
/// Recovery copies older than this are pruned the next time media cleanup or
/// orphan clearing runs: long enough to notice a mistake (backups' monthly
/// interval), short enough that the folder, which backups and sync carry too,
/// can't grow without bound.
pub const RECOVERY_DAYS: i64 = 30;

#[derive(Default, Debug, Serialize)]
pub struct MediaCleanupReport {
    pub checked: usize,
    pub organised: usize,
    pub references_updated: usize,
    pub unreferenced: usize,
    pub issues: Vec<String>,
    pub backup: Option<String>,
    /// Recovery folders older than RECOVERY_DAYS removed by this run.
    pub pruned: usize,
}

/// Remove recovery folders older than `days`, judged by the UTC time in their
/// name (`20261020T101500.123456789`, as this module writes them). A folder
/// whose name isn't such a time is left alone. Files go through the vault one
/// by one, then the emptied folders; links are never followed, and a folder a
/// link keeps non-empty simply stays. Returns how many folders went.
pub fn prune_media_recovery(j: &Journal, days: i64) -> Result<usize, String> {
    let cutoff = chrono::Utc::now() - chrono::Duration::days(days);
    let mut pruned = 0;
    let root = format!("{}/{RECOVERY_NAME}", j.sidecar());
    for item in j.vault().list(&root)? {
        if !item.is_dir {
            continue;
        }
        let Some(when) = item
            .name
            .get(..15)
            .and_then(|s| chrono::NaiveDateTime::parse_from_str(s, "%Y%m%dT%H%M%S").ok())
        else {
            continue;
        };
        if when.and_utc() >= cutoff {
            continue;
        }
        remove_tree(j, &format!("{root}/{}", item.name))?;
        pruned += 1;
    }
    Ok(pruned)
}

fn remove_tree(j: &Journal, dir: &str) -> Result<(), String> {
    for item in j.vault().list(dir)? {
        let rel = format!("{dir}/{}", item.name);
        if item.is_dir {
            remove_tree(j, &rel)?;
        } else if item.is_file {
            j.vault().remove(&rel)?;
        }
    }
    // Best effort: a link left inside keeps the folder, which is harmless.
    let _ = j.vault().remove(dir);
    Ok(())
}

fn inventory(j: &Journal) -> Result<BTreeSet<String>, String> {
    let mut files = BTreeSet::new();
    let mut dirs = vec![
        String::new(),
        ".quire/templates".into(),
        ".nook/templates".into(),
    ];
    while let Some(dir) = dirs.pop() {
        for item in j.vault().list(&dir)? {
            if item.name == ".git" || item.name == ".quire" || item.name == ".nook" {
                continue;
            }
            let rel = if dir.is_empty() {
                item.name
            } else {
                format!("{dir}/{}", item.name)
            };
            if item.is_dir {
                dirs.push(rel);
            } else if item.is_file {
                files.insert(rel);
            }
        }
    }
    Ok(files)
}

fn target_parts(target: &str) -> (&str, &str) {
    let end = target.find(['#', '?']).unwrap_or(target.len());
    (&target[..end], &target[end..])
}

/// The files a link target may mean. An exact path wins; failing that, files
/// whose path differs only in case or in how its accents are composed.
fn candidates(file: &str, target: &str, files: &BTreeSet<String>) -> Vec<String> {
    let forms = resolve_link_all(file, target_parts(target).0);
    let exact: Vec<String> = forms.iter().filter(|p| files.contains(*p)).cloned().collect();
    if !exact.is_empty() {
        return exact;
    }
    let folded: BTreeSet<String> = forms.iter().map(|p| fold(p)).collect();
    files.iter().filter(|f| folded.contains(&fold(f))).cloned().collect()
}

fn monthly(rel: &str) -> bool {
    let parts: Vec<_> = rel.split('/').collect();
    parts.len() == 4
        && parts[0] == "assets"
        && parts[1].len() == 4
        && parts[1].bytes().all(|b| b.is_ascii_digit())
        && parts[2].len() == 2
        && parts[2].parse::<u8>().is_ok_and(|m| (1..=12).contains(&m))
}

/// A generated destination must not pass through a symlinked directory.
pub(crate) fn check_parents(j: &Journal, rel: &str) -> Result<(), String> {
    let mut parent = String::new();
    let parts: Vec<_> = rel.split('/').collect();
    for part in &parts[..parts.len().saturating_sub(1)] {
        if j.vault()
            .list(&parent)?
            .iter()
            .any(|i| i.name == *part && !i.is_dir)
        {
            return Err(format!(
                "Unsafe destination parent for {rel}; originals kept"
            ));
        }
        if !parent.is_empty() {
            parent.push('/');
        }
        parent.push_str(part);
    }
    Ok(())
}

fn verified_write(j: &Journal, rel: &str, bytes: &[u8]) -> Result<(), String> {
    check_parents(j, rel)?;
    j.vault().write(rel, bytes)?;
    if j.vault().read(rel)?.as_deref() != Some(bytes) {
        return Err(format!("Verification failed: {rel}"));
    }
    Ok(())
}

/// Conservative orphan check across all readable markdown, including templates.
/// Unknown reference syntaxes count as references when they mention the path or
/// filename. A failed read/listing aborts the check rather than guessing.
pub fn orphan_media(j: &Journal) -> Result<Vec<String>, String> {
    let files = inventory(j)?;
    let mut referenced = BTreeSet::new();
    // Two nets under the link parser, both compared folded. `whole` is every
    // document as written (and percent-decoded): a file whose full path appears
    // anywhere in it is in use, whatever the parser made of the link around it.
    // `loose` is the same with parsed link targets taken out: there a bare file
    // name counts too, for syntaxes the parser doesn't know (HTML, reference
    // links, prose). The name alone isn't looked for in link targets, or one
    // `30-080000.jpg` would keep every month's file of that name.
    let (mut whole, mut loose) = (String::new(), String::new());
    for file in files.iter().filter(|f| f.to_lowercase().ends_with(".md")) {
        let bytes = j
            .vault()
            .read(file)?
            .ok_or_else(|| format!("File disappeared: {file}"))?;
        let text = String::from_utf8(bytes).map_err(|e| format!("Can't read {file}: {e}"))?;
        for target in link_targets(&text) {
            referenced.extend(candidates(file, &target, &files));
        }
        for form in [text.clone(), crate::journal::percent_decode(&text)] {
            whole.push_str(&fold(&form));
            whole.push('\n');
        }
        loose.push_str(&fold(&crate::journal::percent_decode(&LINK_TARGET_RE.replace_all(&text, ""))));
        loose.push('\n');
    }
    Ok(files
        .into_iter()
        .filter(|f| {
            f.starts_with("assets/")
                && !f.rsplit('/').next().unwrap().starts_with('.')
                && !referenced.contains(f)
                && !whole.contains(&fold(f))
                && !loose.contains(&fold(f.rsplit('/').next().unwrap()))
        })
        .collect())
}

/// Clear only the files shown to the user, and only if still unreferenced.
/// Recovery copies are verified before any original path is removed.
pub fn archive_orphan_media(j: &Journal, offered: &[String]) -> Result<(usize, String), String> {
    // Settle which sidecar is in use before anything is listed: see cleanup_media.
    j.sidecar_mut()?;
    prune_media_recovery(j, RECOVERY_DAYS)?;
    let current: BTreeSet<_> = orphan_media(j)?.into_iter().collect();
    let backup = format!("{}/orphans", new_recovery_run(j)?);
    let selected: Vec<_> = offered.iter().filter(|p| current.contains(*p)).collect();
    for source in &selected {
        let bytes = j
            .vault()
            .read(source)?
            .ok_or_else(|| format!("File disappeared: {source}"))?;
        verified_write(j, &format!("{backup}/{source}"), &bytes)?;
    }
    let current: BTreeSet<_> = orphan_media(j)?.into_iter().collect();
    let mut cleared = 0;
    for source in selected {
        if !current.contains(source) {
            continue;
        }
        let saved = j
            .vault()
            .read(&format!("{backup}/{source}"))?
            .ok_or_else(|| format!("Recovery copy missing for {source}; original kept"))?;
        if j.vault().read(source)?.as_deref() != Some(saved.as_slice()) {
            return Err(format!(
                "{source} changed during cleanup; original kept; recovery: {backup}"
            ));
        }
        cleared += j.remove(source)? as usize;
    }
    Ok((cleared, backup))
}

/// Uses the earliest referencing entry's month, preserving file names. Existing
/// monthly assets stay put. Ambiguous links, missing media and undated assets are
/// reported, never guessed. Unreferenced files are never deleted. All changes
/// use the Vault; originals and original markdown remain in the backup folder.
pub fn cleanup_media(j: &Journal) -> Result<MediaCleanupReport, String> {
    // This run writes to the sidecar, so a journal that only has `.nook/` has
    // it renamed now, before the templates in it are listed: renamed halfway
    // through, they would be read back from a path that is no longer there.
    j.sidecar_mut()?;
    let mut report = MediaCleanupReport {
        pruned: prune_media_recovery(j, RECOVERY_DAYS)?,
        ..Default::default()
    };
    let files = inventory(j)?;
    let mut texts = BTreeMap::new();
    let mut originals = BTreeMap::new();
    // Read everything before making any changes. Keep exact bytes for recovery.
    for file in files.iter().filter(|f| f.to_lowercase().ends_with(".md")) {
        let bytes = j
            .vault()
            .read(file)?
            .ok_or_else(|| format!("File disappeared: {file}"))?;
        let text =
            String::from_utf8(bytes.clone()).map_err(|e| format!("Can't read {file}: {e}"))?;
        texts.insert(file.clone(), text);
        originals.insert(file.clone(), bytes);
    }
    let mut referenced = BTreeSet::new();
    let mut ambiguous = BTreeSet::new();
    let mut dates: BTreeMap<String, String> = BTreeMap::new();
    for (file, text) in &texts {
        for target in link_targets(text) {
            let found = candidates(file, &target, &files);
            if found.len() > 1 {
                ambiguous.extend(found.iter().cloned());
                report
                    .issues
                    .push(format!("Ambiguous link in {file}: {target}; files kept"));
            }
            referenced.extend(found);
            if candidates(file, &target, &files).is_empty()
                && (target.contains("assets/")
                    || crate::media_kind(target_parts(&target).0) != "file")
            {
                report
                    .issues
                    .push(format!("Missing media in {file}: {target}"));
            }
        }
        for entry in parse_entries(text) {
            if entry.ts.len() < 7 {
                continue;
            }
            let month = entry.ts[..7].replace('-', "/");
            for target in link_targets(&entry.raw) {
                let found = candidates(file, &target, &files);
                if found.len() == 1 {
                    dates
                        .entry(found[0].clone())
                        .and_modify(|m| {
                            if month < *m {
                                *m = month.clone();
                            }
                        })
                        .or_insert_with(|| month.clone());
                }
            }
        }
    }
    let mut swaps = BTreeMap::new();
    let mut reserved = files.clone();
    for file in &files {
        if !file.starts_with("assets/") || file.rsplit('/').next().unwrap_or("").starts_with('.') {
            continue;
        }
        report.checked += 1;
        if !referenced.contains(file) {
            report.unreferenced += 1;
            continue;
        }
        if monthly(file) || ambiguous.contains(file) {
            continue;
        }
        let Some(month) = dates.get(file) else {
            report
                .issues
                .push(format!("No dated entry references {file}; kept in place"));
            continue;
        };
        let name = file.rsplit('/').next().unwrap();
        let mut dest = format!("assets/{month}/{name}");
        let (stem, ext) = name.rsplit_once('.').unwrap_or((name, ""));
        let mut n = 2;
        while reserved.contains(&dest) || j.is_file(&dest) || j.is_dir(&dest) {
            dest = if ext.is_empty() {
                format!("assets/{month}/{stem}-{n}")
            } else {
                format!("assets/{month}/{stem}-{n}.{ext}")
            };
            n += 1;
        }
        reserved.insert(dest.clone());
        swaps.insert(file.clone(), dest);
    }
    if swaps.is_empty() {
        report.unreferenced = orphan_media(j)?.len();
        return Ok(report);
    }
    let backup = new_recovery_run(j)?;
    report.backup = Some(backup.clone());
    for (source, dest) in &swaps {
        let bytes = j
            .vault()
            .read(source)?
            .ok_or_else(|| format!("File disappeared: {source}"))?;
        // Back up media too: a failed or interrupted operation retains originals.
        verified_write(j, &format!("{backup}/{source}"), &bytes)?;
        verified_write(j, dest, &bytes)?;
    }
    let mut updated = BTreeMap::new();
    // Media still linked from a file that changed under us and was left alone.
    let mut still_linked: BTreeMap<String, String> = BTreeMap::new();
    for (file, text) in &texts {
        let rewritten = LINK_TARGET_RE
            .replace_all(text, |c: &regex::Captures| {
                let m = c.get(2).or_else(|| c.get(3)).unwrap();
                let found = candidates(file, m.as_str(), &files);
                if found.len() != 1 {
                    return c[0].to_string();
                }
                let Some(dest) = swaps.get(&found[0]) else {
                    return c[0].to_string();
                };
                // Angle brackets handle spaces; percent escapes preserve literal URL punctuation.
                let url = dest
                    .replace('%', "%25")
                    .replace('#', "%23")
                    .replace('?', "%3F")
                    .replace('<', "%3C")
                    .replace('>', "%3E");
                format!("]({}<{}{}>", &c[1], url, target_parts(m.as_str()).1)
            })
            .into_owned();
        if rewritten != *text {
            verified_write(j, &format!("{backup}/{file}"), &originals[file])?;
            // One step: the file is replaced only while it still holds the
            // bytes read at the start, so a save that landed since is not
            // written over. That file is then left as it is, along with every
            // file it links.
            if !j.vault().replace_if_unchanged(file, Some(originals[file].as_slice()), Some(rewritten.as_bytes()))? {
                report.issues.push(format!("{file} changed during cleanup; left as it is"));
                for target in link_targets(text) {
                    for source in candidates(file, &target, &files) {
                        still_linked.insert(source, file.clone());
                    }
                }
                continue;
            }
            if j.vault().read(file)?.as_deref() != Some(rewritten.as_bytes()) {
                return Err(format!("Verification failed: {file}"));
            }
            report.references_updated += 1;
        }
        updated.insert(file.clone(), rewritten);
    }
    // Re-read all documents and destinations before removing any old media path.
    for (file, text) in &updated {
        if j.vault().read(file)?.as_deref() != Some(text.as_bytes()) {
            return Err(format!(
                "{file} changed during cleanup; original media kept; backup: {backup}"
            ));
        }
    }
    for (source, dest) in swaps {
        let original_bytes = j
            .vault()
            .read(&format!("{backup}/{source}"))?
            .ok_or_else(|| format!("Recovery copy missing for {source}; original kept"))?;
        if j.vault().read(&dest)?.as_deref() != Some(original_bytes.as_slice()) {
            return Err(format!(
                "{dest} changed during cleanup; original media kept; backup: {backup}"
            ));
        }
        if let Some(file) = still_linked.get(&source) {
            report.issues.push(format!("{source} is still linked from {file}; original kept alongside organised copy"));
            continue;
        }
        // Unknown reference syntaxes (HTML, reference-style markdown, prose) are
        // deliberately not rewritten; keep the original when its path remains.
        if updated.values().any(|t| {
            let other = crate::journal::percent_decode(&LINK_TARGET_RE.replace_all(t, ""));
            other.contains(&source) || other.contains(source.rsplit('/').next().unwrap())
        }) {
            report.issues.push(format!(
                "Other references to {source}; original kept alongside organised copy"
            ));
            continue;
        }
        if j.vault().read(&source)?.as_deref() != Some(original_bytes.as_slice()) {
            report
                .issues
                .push(format!("{source} changed during cleanup; original kept"));
            continue;
        }
        j.remove(&source)?;
        report.organised += 1;
    }
    report.unreferenced = orphan_media(j)?.len();
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn put(j: &Journal, path: &str, bytes: &[u8]) {
        j.vault().write(path, bytes).unwrap();
    }

    #[test]
    fn organises_updates_all_links_and_preserves_recovery_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let j = Journal::open(temp.path());
        let original =
            b"[2026-09-30 10:00:00] photo\n![](../../../assets/old%20photo.jpg \"Title\")\n";
        put(&j, "assets/old photo.jpg", b"photo bytes");
        put(&j, "journal/2026/09/30.md", original);
        put(
            &j,
            "split/work/2026/10/01.md",
            b"[2026-10-01 08:00:00] shared\n![alt](<assets/old photo.jpg>)\n",
        );
        let r = cleanup_media(&j).unwrap();
        assert_eq!((r.checked, r.organised, r.references_updated), (1, 1, 2));
        assert!(r.issues.is_empty(), "{:?}", r.issues);
        assert_eq!(
            j.vault()
                .read("assets/2026/09/old photo.jpg")
                .unwrap()
                .unwrap(),
            b"photo bytes"
        );
        assert!(!j.is_file("assets/old photo.jpg"));
        assert!(j
            .read("journal/2026/09/30.md")
            .contains("](<assets/2026/09/old photo.jpg> \"Title\")"));
        let backup = r.backup.unwrap();
        assert_eq!(
            j.vault()
                .read(&format!("{backup}/journal/2026/09/30.md"))
                .unwrap()
                .unwrap(),
            original
        );
        assert_eq!(
            j.vault()
                .read(&format!("{backup}/assets/old photo.jpg"))
                .unwrap()
                .unwrap(),
            b"photo bytes"
        );
        let repeat = cleanup_media(&j).unwrap();
        assert_eq!(repeat.organised, 0);
        assert!(repeat.backup.is_none());
    }

    #[test]
    fn keeps_orphans_reports_missing_and_avoids_collisions() {
        let temp = tempfile::tempdir().unwrap();
        let j = Journal::open(temp.path());
        put(&j, "assets/photo.jpg", b"old");
        put(&j, "assets/orphan.jpg", b"orphan");
        put(&j, "assets/2026/09/photo.jpg", b"existing");
        put(
            &j,
            "journal/2026/09/30.md",
            b"[2026-09-30 10:00:00]\n![](assets/photo.jpg) ![](assets/missing.png)\n",
        );
        let r = cleanup_media(&j).unwrap();
        assert_eq!(r.organised, 1);
        assert_eq!(r.unreferenced, 2);
        assert!(r.issues.iter().any(|e| e.contains("Missing media")));
        assert_eq!(
            j.vault().read("assets/2026/09/photo.jpg").unwrap().unwrap(),
            b"existing"
        );
        assert_eq!(
            j.vault()
                .read("assets/2026/09/photo-2.jpg")
                .unwrap()
                .unwrap(),
            b"old"
        );
        assert!(j.is_file("assets/orphan.jpg"));
    }

    #[test]
    fn ambiguity_and_unknown_reference_syntax_keep_originals() {
        let temp = tempfile::tempdir().unwrap();
        let j = Journal::open(temp.path());
        put(&j, "assets/a.jpg", b"a");
        put(&j, "journal/2026/09/assets/a.jpg", b"different a");
        put(&j, "assets/b.jpg", b"b");
        put(&j, "journal/2026/09/30.md", b"[2026-09-30 10:00:00]\n![](assets/a.jpg) ![](assets/b.jpg)\n[extra]: ../../../assets/b.jpg\n");
        let r = cleanup_media(&j).unwrap();
        assert!(r.issues.iter().any(|e| e.contains("Ambiguous")));
        assert!(r.issues.iter().any(|e| e.contains("Other references")));
        assert!(j.is_file("assets/a.jpg"));
        assert!(j.is_file("assets/b.jpg"));
        assert!(j.is_file("assets/2026/09/b.jpg"));
    }

    #[cfg(unix)]
    #[test]
    fn refuses_symlinked_destination_parent() {
        let temp = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let j = Journal::open(temp.path());
        put(&j, "assets/a.jpg", b"a");
        put(
            &j,
            "journal/2026/09/30.md",
            b"[2026-09-30 10:00:00]\n![](assets/a.jpg)\n",
        );
        std::os::unix::fs::symlink(outside.path(), temp.path().join("assets/2026")).unwrap();
        assert!(cleanup_media(&j)
            .unwrap_err()
            .contains("Unsafe destination"));
        assert!(j.is_file("assets/a.jpg"));
        assert!(std::fs::read_dir(outside.path()).unwrap().next().is_none());
    }

    #[test]
    fn orphan_clear_rechecks_selection_and_preserves_exact_recovery_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let j = Journal::open(temp.path());
        put(&j, "assets/orphan.jpg", b"original orphan");
        put(&j, "assets/newly-linked.jpg", b"linked later");
        let offered = orphan_media(&j).unwrap();
        assert_eq!(offered.len(), 2);
        put(&j, "notes.md", b"[reference]: assets/newly-linked.jpg\n");
        put(&j, "assets/arrived-later.jpg", b"not offered");
        let (cleared, recovery) = archive_orphan_media(&j, &offered).unwrap();
        assert_eq!(cleared, 1);
        assert!(!j.is_file("assets/orphan.jpg"));
        assert!(j.is_file("assets/newly-linked.jpg"));
        assert!(j.is_file("assets/arrived-later.jpg"));
        assert_eq!(
            j.vault()
                .read(&format!("{recovery}/assets/orphan.jpg"))
                .unwrap()
                .unwrap(),
            b"original orphan"
        );
        assert_eq!(orphan_media(&j).unwrap(), vec!["assets/arrived-later.jpg"]);
    }

    #[test]
    fn orphan_clear_aborts_if_any_markdown_cannot_be_read() {
        let temp = tempfile::tempdir().unwrap();
        let j = Journal::open(temp.path());
        put(&j, "assets/orphan.jpg", b"original");
        let offered = orphan_media(&j).unwrap();
        put(&j, "bad.md", &[0xff]);
        assert!(archive_orphan_media(&j, &offered).is_err());
        assert!(j.is_file("assets/orphan.jpg"));
    }

    /// Fails the write of one day file; with `refuse`, reports instead that
    /// the file changed since it was read.
    struct FailingVault(crate::vault::FsVault, bool);
    impl crate::vault::Vault for FailingVault {
        fn read(&self, p: &str) -> Result<Option<Vec<u8>>, String> {
            self.0.read(p)
        }
        fn write(&self, p: &str, b: &[u8]) -> Result<(), String> {
            if p == "journal/2026/09/30.md" {
                Err("injected write failure".into())
            } else {
                self.0.write(p, b)
            }
        }
        fn replace_if_unchanged(&self, p: &str, expected: Option<&[u8]>, b: Option<&[u8]>) -> Result<bool, String> {
            if p == "journal/2026/09/30.md" {
                if self.1 {
                    Ok(false)
                } else {
                    Err("injected write failure".into())
                }
            } else {
                self.0.replace_if_unchanged(p, expected, b)
            }
        }
        fn remove(&self, p: &str) -> Result<bool, String> {
            self.0.remove(p)
        }
        fn rename(&self, a: &str, b: &str) -> Result<(), String> {
            self.0.rename(a, b)
        }
        fn list(&self, p: &str) -> Result<Vec<crate::vault::Item>, String> {
            self.0.list(p)
        }
        fn is_dir(&self, p: &str) -> bool {
            self.0.is_dir(p)
        }
        fn is_file(&self, p: &str) -> bool {
            self.0.is_file(p)
        }
        fn len(&self, p: &str) -> u64 {
            self.0.len(p)
        }
        fn modified(&self, p: &str) -> Option<u64> {
            self.0.modified(p)
        }
        fn local_path(&self, p: &str) -> Option<std::path::PathBuf> {
            self.0.local_path(p)
        }
    }

    #[test]
    fn failed_reference_write_keeps_original_media_and_recovery_copy() {
        let temp = tempfile::tempdir().unwrap();
        let normal = Journal::open(temp.path());
        let original = b"[2026-09-30 10:00:00]\n![](assets/a.jpg)\n";
        put(&normal, "assets/a.jpg", b"a");
        put(&normal, "journal/2026/09/30.md", original);
        let j = Journal::with_vault(
            temp.path(),
            std::sync::Arc::new(FailingVault(crate::vault::FsVault::new(temp.path()), false)),
        );
        assert!(cleanup_media(&j)
            .unwrap_err()
            .contains("injected write failure"));
        assert_eq!(
            j.vault().read("journal/2026/09/30.md").unwrap().unwrap(),
            original
        );
        assert_eq!(j.vault().read("assets/a.jpg").unwrap().unwrap(), b"a");
        assert_eq!(
            j.vault().read("assets/2026/09/a.jpg").unwrap().unwrap(),
            b"a"
        );
        assert!(j
            .walk_files(".quire/media-cleanup")
            .iter()
            .any(|f| f.ends_with("/assets/a.jpg")));
    }

    #[test]
    fn recovery_copies_older_than_the_limit_are_pruned() {
        let temp = tempfile::tempdir().unwrap();
        let j = Journal::open(temp.path());
        let old = (chrono::Utc::now() - chrono::Duration::days(RECOVERY_DAYS + 1)).format("%Y%m%dT%H%M%S%.9f");
        let recent = (chrono::Utc::now() - chrono::Duration::days(RECOVERY_DAYS - 1)).format("%Y%m%dT%H%M%S%.9f");
        put(&j, &format!(".quire/media-cleanup/{old}/assets/a.jpg"), b"a");
        put(&j, &format!(".quire/media-cleanup/{old}/orphans/assets/2026/09/b.jpg"), b"b");
        put(&j, &format!(".quire/media-cleanup/{recent}/assets/c.jpg"), b"c");
        put(&j, ".quire/media-cleanup/kept-by-hand/d.jpg", b"d");
        put(&j, "assets/2026/09/e.jpg", b"e");
        assert_eq!(cleanup_media(&j).unwrap().pruned, 1);
        assert!(!j.is_dir(&format!(".quire/media-cleanup/{old}")));
        assert!(j.is_file(&format!(".quire/media-cleanup/{recent}/assets/c.jpg")));
        assert!(j.is_file(".quire/media-cleanup/kept-by-hand/d.jpg"));
        assert!(j.is_file("assets/2026/09/e.jpg"));
        assert_eq!(prune_media_recovery(&j, RECOVERY_DAYS).unwrap(), 0);
    }

    #[test]
    fn unreadable_markdown_stops_before_any_media_changes() {
        let temp = tempfile::tempdir().unwrap();
        let j = Journal::open(temp.path());
        put(&j, "assets/a.jpg", b"a");
        put(
            &j,
            "journal/2026/09/30.md",
            b"[2026-09-30 10:00:00]\n![](assets/a.jpg)\n",
        );
        put(&j, "other.md", &[0xff]);
        assert!(cleanup_media(&j).is_err());
        assert!(j.is_file("assets/a.jpg"));
        assert!(!j.is_file("assets/2026/09/a.jpg"));
    }
    // C4
    #[test]
    fn a_day_file_saved_during_cleanup_is_left_alone_with_its_media() {
        let temp = tempfile::tempdir().unwrap();
        let normal = Journal::open(temp.path());
        let changing = b"[2026-09-30 10:00:00]\n![](assets/a.jpg)\n";
        put(&normal, "assets/a.jpg", b"a");
        put(&normal, "assets/b.jpg", b"b");
        put(&normal, "journal/2026/09/30.md", changing);
        put(&normal, "journal/2026/10/01.md", b"[2026-10-01 10:00:00]\n![](assets/b.jpg)\n");
        let j = Journal::with_vault(temp.path(), std::sync::Arc::new(FailingVault(crate::vault::FsVault::new(temp.path()), true)));
        let r = cleanup_media(&j).unwrap();
        assert_eq!((r.organised, r.references_updated), (1, 1), "{r:?}");
        assert!(r.issues.iter().any(|i| i.contains("journal/2026/09/30.md changed during cleanup")), "{:?}", r.issues);
        assert!(r.issues.iter().any(|i| i.contains("assets/a.jpg is still linked")), "{:?}", r.issues);
        assert_eq!(j.vault().read("journal/2026/09/30.md").unwrap().unwrap(), changing, "not written over");
        assert!(j.is_file("assets/a.jpg"), "its link still works");
        assert!(!j.is_file("assets/b.jpg") && j.is_file("assets/2026/10/b.jpg"));
    }

    // C3
    #[test]
    fn a_linked_file_with_brackets_or_another_case_is_not_unused() {
        let temp = tempfile::tempdir().unwrap();
        let j = Journal::open(temp.path());
        for name in ["2026/09/image(1).jpg", "2026/09/image((2)).jpg", "2026/09/Photo.JPG", "2026/09/caf\u{e9}.jpg", "2026/09/30-080000.jpg", "2026/10/30-080000.jpg", "2026/09/unused(1).jpg"] {
            put(&j, &format!("assets/{name}"), b"x");
        }
        put(
            &j,
            "journal/2026/09/30.md",
            "[2026-09-30 10:00:00]\n![](assets/2026/09/image(1).jpg)\n![](../../../assets/2026/09/image((2)).jpg)\n![](assets/2026/09/photo.jpg) ![](assets/2026/09/cafe\u{301}.jpg)\n![](assets/2026/09/30-080000.jpg)\n".as_bytes(),
        );
        // Only what nothing points at: the other month's file of the same name,
        // and the one never linked.
        assert_eq!(orphan_media(&j).unwrap(), vec!["assets/2026/09/unused(1).jpg", "assets/2026/10/30-080000.jpg"]);
        let offered = orphan_media(&j).unwrap();
        assert_eq!(archive_orphan_media(&j, &offered).unwrap().0, 2);
        assert!(j.is_file("assets/2026/09/image(1).jpg") && j.is_file("assets/2026/09/image((2)).jpg"));
    }

    // C15
    #[test]
    fn a_journal_with_only_nooks_sidecar_keeps_one_sidecar() {
        let temp = tempfile::tempdir().unwrap();
        let j = Journal::open(temp.path());
        put(&j, ".nook/templates/daily.md", b"A template");
        put(&j, "assets/a.jpg", b"a");
        put(&j, "assets/orphan.jpg", b"o");
        put(&j, "journal/2026/09/30.md", b"[2026-09-30 10:00:00]\n![](assets/a.jpg)\n");
        let r = cleanup_media(&j).unwrap();
        assert_eq!(r.organised, 1);
        assert!(r.backup.unwrap().starts_with(".quire/media-cleanup/"));
        assert!(!j.is_dir(".nook"), "renamed, as on any first sidecar write");
        assert_eq!(crate::list_templates(&j).len(), 1, "Nook's templates are still found");
        let (cleared, recovery) = archive_orphan_media(&j, &["assets/orphan.jpg".to_string()]).unwrap();
        assert_eq!(cleared, 1);
        assert!(recovery.starts_with(".quire/media-cleanup/") && j.is_file(&format!("{recovery}/assets/orphan.jpg")));
    }
}
