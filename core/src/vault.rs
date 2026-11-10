//! The one place the core touches storage.
//!
//! Every entry file, sidecar and asset listing goes through a `Vault`, which
//! speaks paths relative to the journal root. The core never opens a file
//! itself, so each shell can supply the access its platform needs:
//!
//! - Linux and the terminal: `FsVault`, plain `std::fs` with temp-and-rename.
//! - macOS / iOS: a Swift implementation that wraps writes in
//!   `NSFileCoordinator` inside the security-scoped bookmark's access, so a
//!   write never races the iCloud daemon.
//! - Android: a Kotlin implementation over the Storage Access Framework,
//!   whose `content://` URIs `std::fs` cannot see at all.
//!
//! Media transcoding and backups need real paths (ffmpeg, copying trees
//! from other folders); they ask for `local_path` and are native on the
//! shells whose vault has none.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// One directory entry as a vault reports it.
#[derive(Debug, Clone)]
pub struct Item {
    pub name: String,
    pub is_dir: bool,
    pub is_file: bool,
    pub len: u64,
}

pub trait Vault: Send + Sync {
    /// File contents, or `None` when there is no such file. Any other
    /// failure (permissions, a directory) is an error — a writer must never
    /// mistake an unreadable file for an empty one.
    fn read(&self, rel: &str) -> Result<Option<Vec<u8>>, String>;
    /// Replace the file atomically, creating parent folders.
    fn write(&self, rel: &str, bytes: &[u8]) -> Result<(), String>;
    /// Compare-and-swap for read-modify-write: replace the file with `bytes`,
    /// or delete it when `bytes` is `None`, only if it still holds exactly
    /// `expected` (`None`: there is still no file). `Ok(false)` when it has
    /// changed, and then nothing was touched: read again and redo the edit.
    ///
    /// The compare and the swap must be as close to one step as the platform
    /// allows, so another device's entry landing mid-edit is never overwritten.
    fn replace_if_unchanged(&self, rel: &str, expected: Option<&[u8]>, bytes: Option<&[u8]>) -> Result<bool, String>;
    /// Delete a file, or an empty folder. `Ok(false)` when it was not there.
    fn remove(&self, rel: &str) -> Result<bool, String>;
    /// Rename a file or folder.
    fn rename(&self, from: &str, to: &str) -> Result<(), String>;
    /// The children of a folder. A missing folder lists as empty. Symlinks
    /// are reported as neither file nor folder, so walkers never follow them.
    fn list(&self, rel: &str) -> Result<Vec<Item>, String>;
    fn is_dir(&self, rel: &str) -> bool;
    fn is_file(&self, rel: &str) -> bool;
    /// Size in bytes, 0 when missing.
    fn len(&self, rel: &str) -> u64;
    /// Seconds since the Unix epoch of the last modification, if known.
    fn modified(&self, rel: &str) -> Option<u64>;
    /// A real filesystem path for `rel`, where one exists.
    fn local_path(&self, rel: &str) -> Option<PathBuf>;
}

/// `std::fs` rooted at a folder.
pub struct FsVault {
    root: PathBuf,
}

impl FsVault {
    pub fn new(root: impl Into<PathBuf>) -> FsVault {
        FsVault { root: root.into() }
    }
    pub fn root(&self) -> &Path {
        &self.root
    }
    fn path(&self, rel: &str) -> PathBuf {
        if rel.is_empty() || rel == "." {
            self.root.clone()
        } else {
            self.root.join(rel)
        }
    }
}

impl Vault for FsVault {
    fn read(&self, rel: &str) -> Result<Option<Vec<u8>>, String> {
        let p = self.path(rel);
        match fs::read(&p) {
            Ok(b) => Ok(Some(b)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(format!("Can't read {}: {}", p.display(), e)),
        }
    }

    fn write(&self, rel: &str, bytes: &[u8]) -> Result<(), String> {
        let path = self.path(rel);
        let dir = path.parent().ok_or("no parent folder")?;
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        let _lock = FolderLock::take(dir);
        write_atomic_bytes(&path, bytes)
    }

    fn replace_if_unchanged(&self, rel: &str, expected: Option<&[u8]>, bytes: Option<&[u8]>) -> Result<bool, String> {
        let path = self.path(rel);
        let dir = path.parent().ok_or("no parent folder")?;
        if bytes.is_some() {
            fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let _lock = FolderLock::take(dir);
        // A writer that has already lost finds out before paying for a sync
        // (a full flush on macOS, tens of milliseconds) with the lock held.
        if self.read(rel)?.as_deref() != expected {
            return Ok(false);
        }
        // Stage before the final compare, so only the rename follows it. The
        // lock shuts out other Quire writers entirely; a sync tool that ignores
        // it can only land in the gap between that compare and the rename.
        let staged = bytes.map(|b| staged_temp(&path, b)).transpose()?;
        if self.read(rel)?.as_deref() != expected {
            return Ok(false);
        }
        match staged {
            Some(tmp) => {
                tmp.persist(&path).map_err(|e| e.to_string())?;
                sync_dir(dir);
            }
            None => {
                self.remove(rel)?;
            }
        }
        Ok(true)
    }

    fn remove(&self, rel: &str) -> Result<bool, String> {
        let p = self.path(rel);
        // A real folder (not a link to one) goes only when empty: remove_dir
        // refuses anything else, so nothing is ever deleted recursively here.
        let is_dir = fs::symlink_metadata(&p).map(|m| m.is_dir()).unwrap_or(false);
        let removed = if is_dir { fs::remove_dir(&p) } else { fs::remove_file(&p) };
        match removed {
            Ok(()) => {
                if let Some(dir) = p.parent() {
                    sync_dir(dir);
                }
                Ok(true)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(format!("Can't delete {}: {}", p.display(), e)),
        }
    }

    fn rename(&self, from: &str, to: &str) -> Result<(), String> {
        let (a, b) = (self.path(from), self.path(to));
        if let Some(parent) = b.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        fs::rename(&a, &b).map_err(|e| format!("Can't rename {} to {}: {}", a.display(), b.display(), e))?;
        for dir in [a.parent(), b.parent()].into_iter().flatten() {
            sync_dir(dir);
        }
        Ok(())
    }

    fn list(&self, rel: &str) -> Result<Vec<Item>, String> {
        let p = self.path(rel);
        let rd = match fs::read_dir(&p) {
            Ok(rd) => rd,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(format!("Can't list {}: {}", p.display(), e)),
        };
        let mut out = Vec::new();
        for e in rd.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            let len = if ft.is_file() { e.metadata().map(|m| m.len()).unwrap_or(0) } else { 0 };
            out.push(Item { name: e.file_name().to_string_lossy().to_string(), is_dir: ft.is_dir(), is_file: ft.is_file(), len });
        }
        out.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(out)
    }

    fn is_dir(&self, rel: &str) -> bool {
        self.path(rel).is_dir()
    }

    fn is_file(&self, rel: &str) -> bool {
        self.path(rel).is_file()
    }

    fn len(&self, rel: &str) -> u64 {
        fs::symlink_metadata(self.path(rel)).map(|m| m.len()).unwrap_or(0)
    }

    fn modified(&self, rel: &str) -> Option<u64> {
        let m = fs::symlink_metadata(self.path(rel)).ok()?.modified().ok()?;
        m.duration_since(std::time::UNIX_EPOCH).ok().map(|d| d.as_secs())
    }

    fn local_path(&self, rel: &str) -> Option<PathBuf> {
        Some(self.path(rel))
    }
}

/// Write via a temp file in the same folder and rename, like jnl's
/// writeFile. Used by `FsVault` and for files outside any journal (settings,
/// an export destination).
pub fn write_atomic_bytes(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let dir = path.parent().ok_or("no parent folder")?;
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    staged_temp(path, bytes)?.persist(path).map_err(|e| e.to_string())?;
    sync_dir(dir);
    Ok(())
}

/// Flush a folder's own entry table, so a rename or removal in it survives a
/// crash that follows. Best effort, Unix only: a filesystem that can't sync a
/// folder (some network mounts) still has the file's own sync.
pub fn sync_dir(dir: &Path) {
    #[cfg(unix)]
    if let Ok(f) = fs::File::open(dir) {
        let _ = f.sync_all();
    }
    #[cfg(not(unix))]
    let _ = dir;
}

/// The permission bits a file written at `path` gets: the ones the file there
/// already has, so a journal someone made private stays private; for a new
/// file, what its folder allows (a 0700 folder gives 0600 files, the usual
/// 0755 gives 0644).
#[cfg(unix)]
pub(crate) fn mode_for(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    if let Ok(m) = fs::metadata(path) {
        if m.is_file() {
            return m.permissions().mode() & 0o777;
        }
    }
    let folder = path.parent().and_then(|d| fs::metadata(d).ok()).map(|m| m.permissions().mode()).unwrap_or(0o755);
    // Always readable and writable by the owner; group and other as the folder has them.
    0o600 | (folder & 0o066)
}

/// `bytes` in a synced temp file beside `path`, ready to rename over it.
fn staged_temp(path: &Path, bytes: &[u8]) -> Result<tempfile::NamedTempFile, String> {
    let dir = path.parent().ok_or("no parent folder")?;
    let mut tmp = tempfile::Builder::new()
        .prefix(".quire-")
        .suffix(".tmp")
        .tempfile_in(dir)
        .map_err(|e| e.to_string())?;
    tmp.write_all(bytes).map_err(|e| e.to_string())?;
    tmp.as_file().sync_all().map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(tmp.path(), fs::Permissions::from_mode(mode_for(path)));
    }
    Ok(tmp)
}

/// An advisory lock on a folder, held while one writer compares and swaps a
/// file in it, so the app, the terminal app and a second process take turns.
/// It locks the folder itself: no lock file lands in the journal, so the format
/// and what syncs are unchanged. Best effort: a filesystem without locks (some
/// network mounts) still gets the compare, just not the exclusion.
pub(crate) struct FolderLock(#[allow(dead_code)] Option<fs::File>);

impl FolderLock {
    #[cfg(unix)]
    pub(crate) fn take(dir: &Path) -> FolderLock {
        // Dropping the file closes it, which releases the lock.
        FolderLock(fs::File::open(dir).ok().filter(|f| f.lock().is_ok()))
    }
    #[cfg(not(unix))]
    pub(crate) fn take(_dir: &Path) -> FolderLock {
        FolderLock(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fs_vault_round_trip() {
        let d = tempfile::tempdir().unwrap();
        let v = FsVault::new(d.path());
        assert_eq!(v.read("a/b.md").unwrap(), None);
        v.write("a/b.md", b"hi").unwrap();
        assert_eq!(v.read("a/b.md").unwrap().unwrap(), b"hi");
        assert!(v.is_file("a/b.md") && v.is_dir("a") && !v.is_dir("a/b.md"));
        assert_eq!(v.len("a/b.md"), 2);
        let items = v.list("a").unwrap();
        assert_eq!(items.len(), 1);
        assert!(items[0].is_file && items[0].name == "b.md");
        v.rename("a/b.md", "c/d.md").unwrap();
        assert!(!v.is_file("a/b.md") && v.is_file("c/d.md"));
        assert!(v.remove("c/d.md").unwrap());
        assert!(!v.remove("c/d.md").unwrap());
        assert!(v.list("nope").unwrap().is_empty());
        assert_eq!(v.local_path("x").unwrap(), d.path().join("x"));
    }

    #[test]
    fn replace_if_unchanged_swaps_only_what_it_expected() {
        let d = tempfile::tempdir().unwrap();
        let v = FsVault::new(d.path());
        // A new file: expects there to be none.
        assert!(v.replace_if_unchanged("a/b.md", None, Some(b"one")).unwrap());
        assert!(!v.replace_if_unchanged("a/b.md", None, Some(b"two")).unwrap());
        assert_eq!(v.read("a/b.md").unwrap().unwrap(), b"one");
        // A stale expectation leaves the file alone.
        assert!(!v.replace_if_unchanged("a/b.md", Some(b"stale"), Some(b"two")).unwrap());
        assert_eq!(v.read("a/b.md").unwrap().unwrap(), b"one");
        assert!(v.replace_if_unchanged("a/b.md", Some(b"one"), Some(b"two")).unwrap());
        assert_eq!(v.read("a/b.md").unwrap().unwrap(), b"two");
        // Deleting is guarded the same way.
        assert!(!v.replace_if_unchanged("a/b.md", Some(b"one"), None).unwrap());
        assert!(v.is_file("a/b.md"));
        assert!(v.replace_if_unchanged("a/b.md", Some(b"two"), None).unwrap());
        assert!(!v.is_file("a/b.md"));
        // A refused swap leaves no temp file behind.
        assert!(v.list("a").unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn writes_keep_a_files_mode_and_follow_the_folder_for_new_ones() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let d = tempfile::tempdir().unwrap();
        let v = FsVault::new(d.path());
        fs::create_dir(d.path().join("open")).unwrap();
        fs::set_permissions(d.path().join("open"), fs::Permissions::from_mode(0o755)).unwrap();
        fs::create_dir(d.path().join("private")).unwrap();
        fs::set_permissions(d.path().join("private"), fs::Permissions::from_mode(0o700)).unwrap();
        v.write("open/a.md", b"one").unwrap();
        v.write("private/a.md", b"one").unwrap();
        assert_eq!(mode(&d.path().join("open/a.md")), 0o644);
        assert_eq!(mode(&d.path().join("private/a.md")), 0o600, "a private folder gets private files");
        // chmod 600 on a file in an open folder survives every kind of save.
        fs::set_permissions(d.path().join("open/a.md"), fs::Permissions::from_mode(0o600)).unwrap();
        v.write("open/a.md", b"two").unwrap();
        assert_eq!(mode(&d.path().join("open/a.md")), 0o600);
        assert!(v.replace_if_unchanged("open/a.md", Some(b"two"), Some(b"three")).unwrap());
        assert_eq!(mode(&d.path().join("open/a.md")), 0o600);
        write_atomic_bytes(&d.path().join("open/a.md"), b"four").unwrap();
        assert_eq!(mode(&d.path().join("open/a.md")), 0o600);
    }
}
