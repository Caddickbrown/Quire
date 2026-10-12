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
    /// Delete a file. `Ok(false)` when it was not there.
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
        write_atomic_bytes(&self.path(rel), bytes)
    }

    fn remove(&self, rel: &str) -> Result<bool, String> {
        let p = self.path(rel);
        match fs::remove_file(&p) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(format!("Can't delete {}: {}", p.display(), e)),
        }
    }

    fn rename(&self, from: &str, to: &str) -> Result<(), String> {
        let (a, b) = (self.path(from), self.path(to));
        if let Some(parent) = b.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        fs::rename(&a, &b).map_err(|e| format!("Can't rename {} to {}: {}", a.display(), b.display(), e))
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
        let _ = fs::set_permissions(tmp.path(), fs::Permissions::from_mode(0o644));
    }
    tmp.persist(path).map_err(|e| e.to_string())?;
    Ok(())
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
}
