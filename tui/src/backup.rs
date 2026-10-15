//! Automatic-backup timing; actual copies use the shared core.
use quire_core::{backup_due, secs_since, Settings};
use std::time::{Duration, Instant};

#[derive(Default)]
pub(crate) struct Schedule {
    changed: Option<Instant>,
    retry: Option<Instant>,
}
impl Schedule {
    pub fn changed(&mut self, now: Instant) {
        self.changed = Some(now + Duration::from_secs(30));
    }
    pub fn failed(&mut self, now: Instant) {
        self.retry = Some(now + Duration::from_secs(60));
        self.changed.get_or_insert(now);
    }
    pub fn due(&self, settings: &Settings, now: Instant) -> bool {
        if settings.backup_dir.is_none() || self.retry.is_some_and(|retry| now < retry) {
            return false;
        }
        if settings.interval() == "change" {
            self.changed.is_some_and(|deadline| now >= deadline)
                && !settings
                    .last_backup
                    .as_deref()
                    .and_then(secs_since)
                    .is_some_and(|age| (0..300).contains(&age))
        } else {
            backup_due(&settings.interval(), settings.last_backup.as_deref())
        }
    }
    /// A new change during a copy must still get its own later backup.
    pub fn started(&mut self) {
        self.changed = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use quire_core::{add_secs, now_local};
    fn prefs(interval: &str) -> Settings {
        Settings {
            backup_dir: Some("backups".into()),
            backup_interval: Some(interval.into()),
            ..Settings::default()
        }
    }
    #[test]
    fn periodic_backups_respect_interval_folder_and_retry() {
        let now = Instant::now();
        let mut schedule = Schedule::default();
        let mut s = prefs("daily");
        assert!(schedule.due(&s, now));
        s.last_backup = Some(now_local());
        assert!(!schedule.due(&s, now));
        s.last_backup = Some(add_secs(&now_local(), -2 * 86_400).unwrap());
        assert!(schedule.due(&s, now));
        s.backup_interval = Some("weekly".into());
        assert!(!schedule.due(&s, now));
        s.backup_interval = Some("monthly".into());
        s.last_backup = Some(add_secs(&now_local(), -8 * 86_400).unwrap());
        assert!(!schedule.due(&s, now));
        s.last_backup = Some(add_secs(&now_local(), -31 * 86_400).unwrap());
        assert!(schedule.due(&s, now));
        s.last_backup = None;
        schedule.failed(now);
        assert!(!schedule.due(&s, now + Duration::from_secs(59)));
        assert!(schedule.due(&s, now + Duration::from_secs(61)));
        s.backup_dir = None;
        assert!(!schedule.due(&s, now + Duration::from_secs(61)));
        assert!(!Schedule::default().due(&prefs("off"), now));
    }
    #[test]
    fn changes_debounce_and_observe_five_minute_floor() {
        let now = Instant::now();
        let mut schedule = Schedule::default();
        let mut s = prefs("change");
        assert!(!schedule.due(&s, now));
        schedule.changed(now);
        schedule.changed(now + Duration::from_secs(20));
        assert!(!schedule.due(&s, now + Duration::from_secs(49)));
        assert!(schedule.due(&s, now + Duration::from_secs(51)));
        s.last_backup = Some(now_local());
        assert!(!schedule.due(&s, now + Duration::from_secs(51)));
        s.last_backup = Some(add_secs(&now_local(), -301).unwrap());
        assert!(schedule.due(&s, now + Duration::from_secs(51)));
        schedule.started();
        assert!(!schedule.due(&s, now + Duration::from_secs(51)));
        schedule.changed(now + Duration::from_secs(52));
        assert!(schedule.due(&s, now + Duration::from_secs(83)));
    }
}
