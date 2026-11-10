//! Automatic-backup timing; actual copies use the shared core.
use quire_core::{backup_due, secs_since, Settings};
use std::time::{Duration, Instant};

/// The first retry after a failed backup, doubled for each failure in a row
/// up to `RETRY_MAX`: a folder that is unplugged or full is not hammered, and
/// a writing session is not spent copying.
const RETRY_FIRST: Duration = Duration::from_secs(60);
const RETRY_MAX: Duration = Duration::from_secs(3600);
/// A scheduled backup waits until the composer has been still this long.
pub(crate) const QUIET: Duration = Duration::from_secs(30);

#[derive(Default)]
pub(crate) struct Schedule {
    changed: Option<Instant>,
    retry: Option<Instant>,
    failures: u32,
}
impl Schedule {
    pub fn changed(&mut self, now: Instant) {
        self.changed = Some(now + Duration::from_secs(30));
    }
    pub fn failed(&mut self, now: Instant) {
        self.failures = self.failures.saturating_add(1);
        self.retry = Some(now + Self::backoff(self.failures));
        self.changed.get_or_insert(now);
    }
    /// How long to wait after the `failures`th failure in a row.
    pub fn backoff(failures: u32) -> Duration {
        let doubled = RETRY_FIRST.saturating_mul(1u32.checked_shl(failures.saturating_sub(1)).unwrap_or(u32::MAX));
        doubled.min(RETRY_MAX)
    }
    pub fn succeeded(&mut self) {
        self.failures = 0;
        self.retry = None;
    }
    /// `last` is this journal's last backup, where one is recorded.
    pub fn due(&self, settings: &Settings, last: Option<&str>, now: Instant) -> bool {
        if settings.backup_dir.is_none() || self.retry.is_some_and(|retry| now < retry) {
            return false;
        }
        if settings.interval() == "change" {
            self.changed.is_some_and(|deadline| now >= deadline) && !last.and_then(secs_since).is_some_and(|age| (0..300).contains(&age))
        } else {
            backup_due(&settings.interval(), last)
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
        assert!(schedule.due(&s, s.last_backup.as_deref(), now));
        s.last_backup = Some(now_local());
        assert!(!schedule.due(&s, s.last_backup.as_deref(), now));
        s.last_backup = Some(add_secs(&now_local(), -2 * 86_400).unwrap());
        assert!(schedule.due(&s, s.last_backup.as_deref(), now));
        s.backup_interval = Some("weekly".into());
        assert!(!schedule.due(&s, s.last_backup.as_deref(), now));
        s.backup_interval = Some("monthly".into());
        s.last_backup = Some(add_secs(&now_local(), -8 * 86_400).unwrap());
        assert!(!schedule.due(&s, s.last_backup.as_deref(), now));
        s.last_backup = Some(add_secs(&now_local(), -31 * 86_400).unwrap());
        assert!(schedule.due(&s, s.last_backup.as_deref(), now));
        s.last_backup = None;
        schedule.failed(now);
        assert!(!schedule.due(&s, s.last_backup.as_deref(), now + Duration::from_secs(59)));
        assert!(schedule.due(&s, s.last_backup.as_deref(), now + Duration::from_secs(61)));
        // Each failure in a row doubles the wait, up to an hour; a success clears it.
        schedule.failed(now + Duration::from_secs(61));
        assert!(!schedule.due(&s, None, now + Duration::from_secs(61 + 119)));
        assert!(schedule.due(&s, None, now + Duration::from_secs(61 + 121)));
        assert_eq!(Schedule::backoff(3), Duration::from_secs(240));
        assert_eq!(Schedule::backoff(7), Duration::from_secs(3600));
        assert_eq!(Schedule::backoff(u32::MAX), Duration::from_secs(3600));
        schedule.failed(now);
        schedule.succeeded();
        assert!(schedule.due(&s, None, now));
        s.backup_dir = None;
        assert!(!schedule.due(&s, s.last_backup.as_deref(), now + Duration::from_secs(61)));
        assert!(!Schedule::default().due(&prefs("off"), None, now));
    }
    #[test]
    fn changes_debounce_and_observe_five_minute_floor() {
        let now = Instant::now();
        let mut schedule = Schedule::default();
        let mut s = prefs("change");
        assert!(!schedule.due(&s, s.last_backup.as_deref(), now));
        schedule.changed(now);
        schedule.changed(now + Duration::from_secs(20));
        assert!(!schedule.due(&s, s.last_backup.as_deref(), now + Duration::from_secs(49)));
        assert!(schedule.due(&s, s.last_backup.as_deref(), now + Duration::from_secs(51)));
        s.last_backup = Some(now_local());
        assert!(!schedule.due(&s, s.last_backup.as_deref(), now + Duration::from_secs(51)));
        s.last_backup = Some(add_secs(&now_local(), -301).unwrap());
        assert!(schedule.due(&s, s.last_backup.as_deref(), now + Duration::from_secs(51)));
        schedule.started();
        assert!(!schedule.due(&s, s.last_backup.as_deref(), now + Duration::from_secs(51)));
        schedule.changed(now + Duration::from_secs(52));
        assert!(schedule.due(&s, s.last_backup.as_deref(), now + Duration::from_secs(83)));
    }
}
