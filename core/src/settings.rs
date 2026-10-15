//! `~/.config/quire/settings.json`, shared by the Linux app and the terminal.
//! `folder` is the journal folder; `ui` is preferences owned by the front
//! ends (theme, goal, timer, …), kept as JSON so each shell reads what it
//! understands.

use crate::journal::{check_ts, write_atomic};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;

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
}

impl Settings {
    pub fn path() -> PathBuf {
        dirs::config_dir().unwrap_or_else(|| PathBuf::from(".")).join("quire").join("settings.json")
    }

    /// The file as it is, or defaults when missing or unreadable.
    pub fn load() -> Settings {
        std::fs::read_to_string(Self::path()).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
    }

    pub fn save(&self) -> Result<(), String> {
        write_atomic(&Self::path(), &serde_json::to_string_pretty(self).map_err(|e| e.to_string())?)
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
}
