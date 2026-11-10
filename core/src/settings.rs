//! `~/.config/quire/settings.json`, shared by the Linux app and the terminal.
//! `folder` is the journal folder; `ui` is preferences owned by the front
//! ends (theme, goal, timer, …), kept as JSON so each shell reads what it
//! understands.

use crate::journal::{check_ts, write_atomic};
use crate::vault::FolderLock;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;

/// Set to a folder to keep `settings.json` there instead of the platform's
/// config folder: for tests and the smoke drivers, which must never read or
/// write a person's real settings (`XDG_CONFIG_HOME` does nothing on macOS).
pub const CONFIG_DIR_ENV: &str = "QUIRE_CONFIG_DIR";

/// What the last `Settings::load` could not hand to its caller.
static LOAD_WARNING: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

pub const INTERVALS: &[&str] = &["off", "daily", "weekly", "monthly", "change"];

#[derive(Default, Serialize, Deserialize, Clone, Debug)]
pub struct Settings {
    pub folder: Option<String>,
    #[serde(default)]
    pub ui: Value,
    #[serde(default)]
    pub split_tags: Option<String>,
    #[serde(default)]
    pub backup_dir: Option<String>,
    /// Use the desktop's own title bar instead of Quire's (Linux app).
    #[serde(default)]
    pub system_titlebar: bool,
    /// "off" | "daily" | "weekly" | "monthly" | "change"
    #[serde(default)]
    pub backup_interval: Option<String>,
    /// How many "Quire backup …" folders to keep (1–50).
    #[serde(default)]
    pub backup_keep: Option<u32>,
    /// Local "YYYY-MM-DD HH:MM:SS" of the last successful backup.
    #[serde(default)]
    pub last_backup: Option<String>,
    /// Nook's Data Saver: compress media as it's attached.
    #[serde(default)]
    pub data_saver: bool,
    /// This install's id for the shared <sidecar>/datasaver-<id>.json ledger.
    #[serde(default)]
    pub device_id: Option<String>,
    /// Keys this version doesn't know, kept as they are and written back, so
    /// an older Quire doesn't erase what a newer one saved.
    #[serde(flatten)]
    pub extra: serde_json::Map<String, Value>,
    /// Set when the file exists but could not be read: `save` then refuses,
    /// rather than write defaults over settings it never saw.
    #[doc(hidden)]
    #[serde(skip)]
    pub unread: Option<String>,
}

impl Settings {
    /// `$QUIRE_CONFIG_DIR/settings.json` when that is set, else
    /// `<config dir>/quire/settings.json`.
    pub fn path() -> PathBuf {
        match std::env::var_os(CONFIG_DIR_ENV).filter(|d| !d.is_empty()) {
            Some(dir) => PathBuf::from(dir).join("settings.json"),
            None => dirs::config_dir().unwrap_or_else(|| PathBuf::from(".")).join("quire").join("settings.json"),
        }
    }

    /// The settings, for callers with nowhere to put an error. A missing file
    /// is defaults. So is a file that could not be used, but then `save`
    /// refuses until a load succeeds, so the defaults never replace it (a file
    /// that didn't parse has been moved aside by `try_load`, and the next load
    /// starts clean). Prefer `try_load`, which says what happened.
    pub fn load() -> Settings {
        match Self::try_load() {
            Ok(s) => s,
            Err(e) => {
                *LOAD_WARNING.lock().unwrap_or_else(|p| p.into_inner()) = Some(e.clone());
                Settings { unread: Self::path().exists().then_some(e), ..Default::default() }
            }
        }
    }

    /// The reason the last `load` fell back to defaults, once: for a shell to
    /// show after it has a window to show it in.
    pub fn take_load_warning() -> Option<String> {
        LOAD_WARNING.lock().unwrap_or_else(|p| p.into_inner()).take()
    }

    /// The settings file as it is. Only a file that isn't there means
    /// defaults. One that can't be read is an error and is left alone. One
    /// that doesn't parse (a trailing comma from a hand edit) is moved to
    /// `settings.json.bad-<stamp>` beside it, so nothing in it is lost, and
    /// the error names that file; loading again then gives defaults.
    pub fn try_load() -> Result<Settings, String> {
        let path = Self::path();
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Settings::default()),
            Err(e) => return Err(format!("Can't read {}: {}", path.display(), e)),
        };
        match serde_json::from_str(text.strip_prefix('\u{FEFF}').unwrap_or(&text)) {
            Ok(s) => Ok(s),
            Err(e) => {
                let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S");
                let mut bad = path.with_file_name(format!("settings.json.bad-{}", stamp));
                let mut n = 1;
                while bad.exists() {
                    n += 1;
                    bad = path.with_file_name(format!("settings.json.bad-{}-{}", stamp, n));
                }
                match std::fs::rename(&path, &bad) {
                    Ok(()) => Err(format!("The settings file couldn't be read ({}). It was kept as {} and Quire is using its defaults.", e, bad.display())),
                    Err(mv) => Err(format!("The settings file {} couldn't be read ({}), and couldn't be moved aside ({}).", path.display(), e, mv)),
                }
            }
        }
    }

    pub fn save(&self) -> Result<(), String> {
        if let Some(why) = &self.unread {
            return Err(format!("Settings were not saved, so the file that couldn't be read is not replaced. {}", why));
        }
        write_atomic(&Self::path(), &serde_json::to_string_pretty(self).map_err(|e| e.to_string())?)
    }

    /// Change the settings on disk: read them, apply `change`, write them
    /// back, all under a lock on the config folder, and return what was
    /// written. Every writer that goes through here (the app, the terminal
    /// app, a second window) changes only what it means to; a copy loaded
    /// earlier and saved whole would undo the others' changes, a new device id
    /// among them.
    pub fn update(change: impl FnOnce(&mut Settings)) -> Result<Settings, String> {
        let path = Self::path();
        let dir = path.parent().ok_or("no config folder")?;
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        let _lock = FolderLock::take(dir);
        let mut s = Self::try_load()?;
        change(&mut s);
        s.save()?;
        Ok(s)
    }

    pub fn interval(&self) -> String {
        self.backup_interval.clone().filter(|i| INTERVALS.contains(&i.as_str())).unwrap_or_else(|| "off".into())
    }

    pub fn keep(&self) -> usize {
        self.backup_keep.unwrap_or(10).clamp(1, 50) as usize
    }

    /// Pull backup prefs the front end used to keep in `ui`. Returns true if
    /// anything changed.
    pub fn migrate(&mut self) -> bool {
        let mut changed = false;
        if self.backup_interval.is_none() {
            let v = self.ui.get("backupEvery").and_then(|v| v.as_str()).filter(|v| INTERVALS.contains(v)).unwrap_or("off");
            self.backup_interval = Some(v.to_string());
            changed = true;
        }
        if self.last_backup.is_none() {
            if let Some(d) = self.ui.get("lastBackup").and_then(|v| v.as_str()) {
                let ts = if d.len() == 10 { format!("{} 00:00:00", d) } else { d.to_string() };
                if check_ts(&ts).is_ok() {
                    self.last_backup = Some(ts);
                    changed = true;
                }
            }
        }
        changed
    }

    // ----- ui preferences the terminal shares with the Linux app -----

    pub fn ui_str(&self, key: &str) -> Option<String> {
        self.ui.get(key).and_then(|v| v.as_str()).map(|s| s.to_string())
    }

    pub fn ui_u64(&self, key: &str) -> Option<u64> {
        self.ui.get(key).and_then(|v| v.as_u64())
    }

    pub fn ui_bool(&self, key: &str) -> Option<bool> {
        self.ui.get(key).and_then(|v| v.as_bool())
    }

    pub fn set_ui(&mut self, key: &str, value: Value) {
        if !self.ui.is_object() {
            self.ui = Value::Object(Default::default());
        }
        if let Some(o) = self.ui.as_object_mut() {
            o.insert(key.to_string(), value);
        }
    }

    pub fn theme(&self) -> String {
        self.ui_str("theme").unwrap_or_else(|| "almanac".into())
    }

    pub fn word_goal(&self) -> usize {
        self.ui_u64("goal").unwrap_or(500) as usize
    }

    pub fn timer_minutes(&self) -> u64 {
        self.ui_u64("timerMins").unwrap_or(25)
    }

    /// This install's Data Saver device id, minted on first use (the caller
    /// saves the settings when the bool says it is new).
    pub fn ensure_device_id(&mut self) -> (String, bool) {
        if let Some(id) = &self.device_id {
            return (id.clone(), false);
        }
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let id = format!("{:016x}{:08x}", nanos as u64, std::process::id()).to_uppercase();
        self.device_id = Some(id.clone());
        (id, true)
    }

    /// Is `folder` the Linux app's bundled sample journal?
    pub fn is_sample_folder(folder: &str) -> bool {
        folder.ends_with("/sample-journal") || folder.ends_with("\\sample-journal")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ui_helpers() {
        let mut s = Settings::default();
        assert_eq!(s.theme(), "almanac");
        assert_eq!(s.word_goal(), 500);
        s.set_ui("theme", Value::String("cinema".into()));
        s.set_ui("goal", Value::from(250));
        assert_eq!(s.theme(), "cinema");
        assert_eq!(s.word_goal(), 250);
        assert!(Settings::is_sample_folder("/home/x/.local/share/com.caddickbrown.quire/sample-journal"));
        let mut m = Settings { ui: serde_json::json!({"backupEvery": "daily", "lastBackup": "2026-01-02"}), ..Default::default() };
        assert!(m.migrate());
        assert_eq!(m.interval(), "daily");
        assert_eq!(m.last_backup.as_deref(), Some("2026-01-02 00:00:00"));
    }

    /// The config folder comes from the environment, which is the whole
    /// process's: the tests that set it take turns.
    fn with_config_dir<T>(f: impl FnOnce(&std::path::Path) -> T) -> T {
        static TURN: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _turn = TURN.lock().unwrap_or_else(|e| e.into_inner());
        let d = tempfile::tempdir().unwrap();
        std::env::set_var(CONFIG_DIR_ENV, d.path());
        let out = f(d.path());
        std::env::remove_var(CONFIG_DIR_ENV);
        out
    }

    #[test]
    fn config_dir_override_and_unknown_keys_survive_a_save() {
        with_config_dir(|dir| {
            assert_eq!(Settings::path(), dir.join("settings.json"));
            assert!(Settings::try_load().unwrap().folder.is_none(), "no file means defaults");
            std::fs::write(dir.join("settings.json"), r#"{"folder":"/j","from_the_future":{"a":[1,2]},"ui":{"theme":"cinema"}}"#).unwrap();
            let s = Settings::update(|s| s.data_saver = true).unwrap();
            assert_eq!(s.folder.as_deref(), Some("/j"));
            let back: Value = serde_json::from_str(&std::fs::read_to_string(dir.join("settings.json")).unwrap()).unwrap();
            assert_eq!(back["from_the_future"]["a"][1], 2, "a newer version's key is written back");
            assert_eq!((back["data_saver"].clone(), back["ui"]["theme"].clone()), (Value::Bool(true), Value::from("cinema")));
            assert!(back.get("unread").is_none() && back.get("extra").is_none());
        });
    }

    #[test]
    fn a_settings_file_that_does_not_parse_is_kept_not_replaced() {
        with_config_dir(|dir| {
            let broken = "{\n  \"folder\": \"/home/dan/journal\",\n  \"device_id\": \"ABC\",\n}\n";
            std::fs::write(dir.join("settings.json"), broken).unwrap();
            let e = Settings::try_load().unwrap_err();
            assert!(e.contains("settings.json.bad-"), "{e}");
            let kept: Vec<_> = std::fs::read_dir(dir).unwrap().flatten().map(|e| e.file_name().to_string_lossy().to_string()).filter(|n| n.starts_with("settings.json.bad-")).collect();
            assert_eq!(kept.len(), 1, "{kept:?}");
            assert_eq!(std::fs::read_to_string(dir.join(&kept[0])).unwrap(), broken, "the folder and device id are still there to copy back");
            assert!(!dir.join("settings.json").exists());
            // Now a save starts a new file; the broken one is untouched.
            assert!(Settings::take_load_warning().is_none());
            let mut s = Settings::load();
            s.folder = Some("/new".into());
            s.save().unwrap();
            assert_eq!(Settings::try_load().unwrap().folder.as_deref(), Some("/new"));
            assert_eq!(std::fs::read_to_string(dir.join(&kept[0])).unwrap(), broken);
        });
    }

    #[cfg(unix)]
    #[test]
    fn settings_that_could_not_be_read_are_never_saved_over() {
        with_config_dir(|dir| {
            // A folder where the file should be: reading fails, and not with "not found".
            std::fs::create_dir(dir.join("settings.json")).unwrap();
            assert!(Settings::try_load().is_err());
            let mut s = Settings::load();
            assert!(Settings::take_load_warning().unwrap().contains("Can't read"));
            assert!(s.folder.is_none());
            s.folder = Some("/x".into());
            assert!(s.save().unwrap_err().contains("not saved"));
            assert!(Settings::update(|s| s.data_saver = true).is_err());
            assert!(dir.join("settings.json").is_dir());
        });
    }
}
