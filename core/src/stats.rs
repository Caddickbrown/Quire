//! Streaks, totals and the Look back figures, computed from loaded entries.
//! Pure: no I/O, no clock except where a `today` is passed in.
//!
//! One rule for every figure here: they are the main journal's. A split
//! journal is kept apart from the main one, so its entries are in no streak,
//! total, year or On this day; `split_stats` gives the split journals' own
//! figures, all of them taken together, for the section each shell shows
//! beside the main ones. Drafts are not filed yet and count only where a
//! function says so: `words_on` (today's words) and `days_written` (the
//! streak on Today and Look back, where writing a draft keeps the day).

use crate::journal::Entry;
use chrono::{Datelike, Duration, Local, NaiveDate};
use std::collections::{BTreeMap, BTreeSet};

pub fn today() -> String {
    Local::now().format("%Y-%m-%d").to_string()
}

pub fn now_time() -> String {
    Local::now().format("%H:%M").to_string()
}

pub fn parse_date(d: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(d, "%Y-%m-%d").ok()
}

/// "Monday 12 October 2026"
pub fn long_date(d: &str) -> String {
    parse_date(d).map(|x| x.format("%A %-d %B %Y").to_string()).unwrap_or_else(|| d.to_string())
}

/// "Mon 12 Oct"
pub fn short_date(d: &str) -> String {
    parse_date(d).map(|x| x.format("%a %-d %b").to_string()).unwrap_or_else(|| d.to_string())
}

/// "12 Oct 2026"
pub fn day_year(d: &str) -> String {
    parse_date(d).map(|x| x.format("%-d %b %Y").to_string()).unwrap_or_else(|| d.to_string())
}

pub fn month_name(m: u32) -> &'static str {
    ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"][(m.clamp(1, 12) - 1) as usize]
}

/// Is this entry in the main journal: filed, and not in a split journal.
pub fn is_main(e: &Entry) -> bool {
    e.source == "journal"
}

/// Words written on `date`, wherever they are: drafts and split journals
/// included (the day's writing, for the word goal).
pub fn words_on(entries: &[Entry], date: &str) -> usize {
    entries.iter().filter(|e| e.date == date).map(|e| e.words).sum()
}

/// The days written in the main journal, oldest first: what the streak on
/// Today and Look back is counted over. A day with only a draft counts (it
/// was written, and filing it comes later), unless the draft carries one of
/// `split_tags` and so is on its way to a split journal. jnl's `stats`
/// counts filed days only: see `jnl_stats`.
pub fn days_written(entries: &[Entry], split_tags: &[String]) -> BTreeSet<String> {
    entries
        .iter()
        .filter(|e| is_main(e) || (e.source == "inbox" && crate::journal::split_tag(&e.raw, split_tags).is_none()))
        .map(|e| e.date.clone())
        .collect()
}

/// The split journals taken together: how many there are, and their
/// entries, words and days written as one figure each.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SplitStats {
    /// The journals' tags, by name.
    pub names: Vec<String>,
    pub entries: usize,
    pub words: usize,
    /// Days with an entry in any of them.
    pub days: usize,
}

impl SplitStats {
    pub fn is_empty(&self) -> bool {
        self.entries == 0
    }
}

/// Every split journal's entries as one set of figures; with a `year`, that
/// year's only.
pub fn split_stats(entries: &[Entry], year: Option<i32>) -> SplitStats {
    let ys = year.map(|y| format!("{:04}", y));
    let mut s = SplitStats::default();
    let mut names: BTreeSet<&str> = BTreeSet::new();
    let mut days: BTreeSet<&str> = BTreeSet::new();
    for e in entries.iter().filter(|e| e.source == "split" && ys.as_ref().is_none_or(|y| e.date.starts_with(y.as_str()))) {
        s.entries += 1;
        s.words += e.words;
        days.insert(&e.date);
        if let Some(t) = &e.split {
            names.insert(t);
        }
    }
    s.days = days.len();
    s.names = names.into_iter().map(str::to_string).collect();
    s
}

/// Consecutive days up to today, or up to yesterday if nothing is written
/// yet today (the streak is not broken until the day ends).
pub fn current_streak(days: &BTreeSet<String>, today: &str) -> usize {
    let Some(mut d) = parse_date(today) else { return 0 };
    if !days.contains(today) {
        d -= Duration::days(1);
    }
    let mut n = 0;
    while days.contains(&d.format("%Y-%m-%d").to_string()) {
        n += 1;
        d -= Duration::days(1);
    }
    n
}

/// The longest run of consecutive days, and its first and last day.
pub fn longest_streak(days: &BTreeSet<String>) -> (usize, Option<(String, String)>) {
    let mut best = 0;
    let mut best_span = None;
    let mut run = 0;
    let mut start: Option<NaiveDate> = None;
    let mut prev: Option<NaiveDate> = None;
    for d in days {
        let Some(dt) = parse_date(d) else { continue };
        if prev.map(|p| dt - p == Duration::days(1)).unwrap_or(false) {
            run += 1;
        } else {
            run = 1;
            start = Some(dt);
        }
        if run > best {
            best = run;
            best_span = start.map(|s| (s.format("%Y-%m-%d").to_string(), d.clone()));
        }
        prev = Some(dt);
    }
    (best, best_span)
}

/// Tags with counts, most used first, then by name.
pub fn count_tags<'a>(entries: impl Iterator<Item = &'a Entry>) -> Vec<(String, usize)> {
    let mut m: BTreeMap<String, usize> = BTreeMap::new();
    for e in entries {
        for t in &e.tags {
            *m.entry(t.clone()).or_default() += 1;
        }
    }
    let mut v: Vec<(String, usize)> = m.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    v
}

/// Main-journal entries from the same day and month in earlier years, newest
/// first. Drafts aren't filed yet, and a split journal is kept apart from the
/// main one, so neither is a memory here (the Apple app reads the same pool).
pub fn on_this_day<'a>(entries: &'a [Entry], today: &str) -> Vec<&'a Entry> {
    let Some(md) = today.get(4..) else { return Vec::new() };
    let mut v: Vec<&Entry> = entries.iter().filter(|e| e.source == "journal" && e.date.len() == 10 && e.date.get(4..) == Some(md) && e.date.as_str() < today).collect();
    v.sort_by(|a, b| b.ts.cmp(&a.ts));
    v
}

/// What Look back shows for one year.
#[derive(Debug, Default, Clone)]
pub struct YearStats {
    pub year: i32,
    pub entries: usize,
    pub words: usize,
    pub days: usize,
    pub month_words: [usize; 12],
    pub weekday_entries: [usize; 7],
    pub hour_entries: [usize; 24],
    pub tags: Vec<(String, usize)>,
    /// Words per day for the year, by date.
    pub day_words: BTreeMap<String, usize>,
    /// Quartile cuts for the heat strip (words ≤ cut → level).
    pub cuts: [usize; 3],
    pub starred: usize,
}

impl YearStats {
    /// 0 (nothing) to 4 (top quartile).
    pub fn level(&self, words: usize) -> u8 {
        if words == 0 {
            0
        } else if words <= self.cuts[0] {
            1
        } else if words <= self.cuts[1] {
            2
        } else if words <= self.cuts[2] {
            3
        } else {
            4
        }
    }
}

/// Over the main journal only, like the Linux app's Look back.
pub fn year_stats(entries: &[Entry], year: i32) -> YearStats {
    let ys = format!("{:04}", year);
    let mut s = YearStats { year, ..Default::default() };
    let filed: Vec<&Entry> = entries.iter().filter(|e| is_main(e) && e.date.starts_with(&ys)).collect();
    for e in &filed {
        s.entries += 1;
        s.words += e.words;
        *s.day_words.entry(e.date.clone()).or_default() += e.words;
        if let Some(d) = parse_date(&e.date) {
            s.month_words[(d.month() - 1) as usize] += e.words;
            s.weekday_entries[d.weekday().num_days_from_monday() as usize] += 1;
        }
        if let Ok(h) = e.time[..2].parse::<usize>() {
            s.hour_entries[h.min(23)] += 1;
        }
        if e.starred {
            s.starred += 1;
        }
    }
    s.days = s.day_words.len();
    s.tags = count_tags(filed.iter().copied());
    let mut vals: Vec<usize> = s.day_words.values().copied().collect();
    vals.sort_unstable();
    let q = |p: f32| if vals.is_empty() { 0 } else { vals[((p * (vals.len() as f32 - 1.0)).floor()) as usize] };
    s.cuts = [q(0.25), q(0.5), q(0.75)];
    s
}

/// The years with entries in the main journal, newest first, the current year always present.
pub fn years(entries: &[Entry], this_year: i32) -> Vec<i32> {
    let mut v: BTreeSet<i32> = entries.iter().filter(|e| is_main(e)).filter_map(|e| e.date.get(..4)?.parse().ok()).collect();
    v.insert(this_year);
    v.into_iter().rev().collect()
}

/// jnl's `stats` figures, over journal day files only (its definition of
/// "days written"), plus the inbox count and, apart from all of those, the
/// split journals taken together.
#[derive(Debug, Default, Clone)]
pub struct JnlStats {
    pub split: SplitStats,
    pub days: usize,
    pub entries: usize,
    pub words: usize,
    pub longest_day: Option<(String, usize)>,
    pub busiest_day: Option<(String, usize)>,
    pub drafts: usize,
    pub current_streak: usize,
    pub current_start: Option<String>,
    pub best_streak: usize,
    pub best_span: Option<(String, String)>,
    pub per_year: Vec<(String, usize, usize)>,
    pub dow: [usize; 7],
}

pub fn jnl_stats(entries: &[Entry], today: &str) -> JnlStats {
    let mut s = JnlStats { split: split_stats(entries, None), ..Default::default() };
    let mut per_day: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for e in entries {
        if e.source == "inbox" {
            s.drafts += 1;
            continue;
        }
        if e.source != "journal" {
            continue;
        }
        let d = per_day.entry(e.date.clone()).or_default();
        d.0 += 1;
        d.1 += e.words;
    }
    let days: BTreeSet<String> = per_day.keys().cloned().collect();
    s.days = days.len();
    let mut years: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for (d, (ec, wc)) in &per_day {
        s.entries += ec;
        s.words += wc;
        if s.longest_day.as_ref().map(|l| *wc > l.1).unwrap_or(true) {
            s.longest_day = Some((d.clone(), *wc));
        }
        if *ec > 1 && s.busiest_day.as_ref().map(|b| *ec > b.1).unwrap_or(true) {
            s.busiest_day = Some((d.clone(), *ec));
        }
        let y = years.entry(d[..4].to_string()).or_default();
        y.0 += ec;
        y.1 += wc;
        if let Some(dt) = parse_date(d) {
            s.dow[dt.weekday().num_days_from_monday() as usize] += 1;
        }
    }
    s.per_year = years.into_iter().map(|(y, (e, w))| (y, e, w)).collect();
    s.current_streak = current_streak(&days, today);
    if s.current_streak > 0 {
        let end = if days.contains(today) { parse_date(today) } else { parse_date(today).map(|d| d - Duration::days(1)) };
        s.current_start = end.map(|e| (e - Duration::days(s.current_streak as i64 - 1)).format("%Y-%m-%d").to_string());
    }
    let (best, span) = longest_streak(&days);
    s.best_streak = best;
    s.best_span = span;
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::Journal;

    fn entries(spec: &[(&str, &str, &str)]) -> Vec<Entry> {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        for (file, ts, body) in spec {
            j.append_raw(file, &format!("[{}]\n{}", ts, body)).unwrap();
        }
        j.load_all()
    }

    #[test]
    fn streaks_and_years() {
        let es = entries(&[
            ("journal/2026/10/10.md", "2026-10-10 08:00:00", "a b @x"),
            ("journal/2026/10/11.md", "2026-10-11 09:00:00", "a b c @x @y"),
            ("inbox/2026/10/12.md", "2026-10-12 21:00:00", "draft"),
            ("journal/2025/10/12.md", "2025-10-12 08:00:00", "last year"),
            ("journal/2026/01/01.md", "2026-01-01 08:00:00", "new year"),
        ]);
        let days = days_written(&es, &[]);
        assert_eq!(current_streak(&days, "2026-10-12"), 3, "today's draft counts");
        assert_eq!(current_streak(&days, "2026-10-13"), 3, "not broken until the day ends");
        assert_eq!(current_streak(&days, "2026-10-14"), 0);
        assert_eq!(longest_streak(&days).0, 3);
        assert_eq!(words_on(&es, "2026-10-11"), 5);
        let otd: Vec<&str> = on_this_day(&es, "2026-10-12").iter().map(|e| e.date.as_str()).collect();
        assert_eq!(otd, vec!["2025-10-12"]);
        let y = year_stats(&es, 2026);
        assert_eq!((y.entries, y.words, y.days), (3, 10, 3), "tags count as words, as everywhere else");
        assert_eq!(y.month_words[9], 8);
        assert_eq!(y.tags[0], ("@x".to_string(), 2));
        assert_eq!(years(&es, 2026), vec![2026, 2025]);
        let j = jnl_stats(&es, "2026-10-12");
        assert_eq!((j.days, j.entries, j.words, j.drafts), (4, 4, 12, 1));
        assert_eq!(j.current_streak, 2, "jnl counts journal days only");
        assert_eq!(j.current_start.as_deref(), Some("2026-10-10"));
        assert_eq!(j.per_year.len(), 2);
        assert_eq!(long_date("2026-10-12"), "Monday 12 October 2026");
        assert_eq!(short_date("2026-10-12"), "Mon 12 Oct");
    }

    #[test]
    fn on_this_day_is_the_main_journal_only() {
        let es = entries(&[
            ("journal/2025/10/12.md", "2025-10-12 08:00:00", "last year"),
            ("journal/2024/10/12.md", "2024-10-12 08:00:00", "two years ago"),
            ("split/work/2025/10/12.md", "2025-10-12 09:00:00", "standup @work"),
            ("split/work/2023/10/12.md", "2023-10-12 09:00:00", "retro @work"),
            ("inbox/2025/10/12.md", "2025-10-12 10:00:00", "an old draft"),
            ("journal/2026/10/12.md", "2026-10-12 08:00:00", "today"),
            ("journal/2025/10/13.md", "2025-10-13 08:00:00", "the day after"),
        ]);
        assert!(es.iter().any(|e| e.source == "split"), "the split entries were read as split");
        let otd: Vec<(&str, &str)> = on_this_day(&es, "2026-10-12").iter().map(|e| (e.source.as_str(), e.date.as_str())).collect();
        assert_eq!(otd, vec![("journal", "2025-10-12"), ("journal", "2024-10-12")]);
        assert!(on_this_day(&es, "").is_empty(), "a date that isn't one finds nothing");
    }

    /// Every figure is the main journal's; the split journals have one set of
    /// their own, all of them together.
    #[test]
    fn split_journals_are_counted_apart_and_together() {
        let es = entries(&[
            ("journal/2026/10/10.md", "2026-10-10 08:00:00", "a b @x"),
            ("journal/2026/10/11.md", "2026-10-11 09:00:00", "a b c"),
            ("split/work/2026/10/11.md", "2026-10-11 10:00:00", "one two three four @work"),
            ("split/work/2026/10/12.md", "2026-10-12 10:00:00", "one two @work"),
            ("split/home/2026/10/12.md", "2026-10-12 11:00:00", "one @home"),
            ("split/home/2024/02/03.md", "2024-02-03 11:00:00", "long ago @home"),
            ("inbox/2026/10/12.md", "2026-10-12 21:00:00", "a draft for @work"),
        ]);
        // The main journal's figures don't move for a split entry, or for a
        // draft that will be filed into a split journal.
        let tags = vec!["work".to_string(), "home".to_string()];
        let days = days_written(&es, &tags);
        assert_eq!(days.iter().map(String::as_str).collect::<Vec<_>>(), ["2026-10-10", "2026-10-11"]);
        assert_eq!(current_streak(&days, "2026-10-12"), 2, "a split entry today is not the journal's day");
        assert!(days_written(&es, &[]).contains("2026-10-12"), "with no split tags that draft is the main journal's");
        let y = year_stats(&es, 2026);
        assert_eq!((y.entries, y.words, y.days), (2, 6, 2));
        assert_eq!(y.tags, vec![("@x".to_string(), 1)], "@work and @home are the split journals' tags");
        assert_eq!(years(&es, 2026), vec![2026], "2024 has only a split entry");
        let j = jnl_stats(&es, "2026-10-12");
        assert_eq!((j.days, j.entries, j.words, j.drafts), (2, 2, 6, 1));
        // The split journals, as one.
        let all = split_stats(&es, None);
        assert_eq!(all.names, ["home", "work"]);
        assert_eq!((all.entries, all.words, all.days), (4, 13, 3), "two of them share the 12th: one day");
        assert_eq!(j.split, all, "`stats` carries the same figures");
        let this_year = split_stats(&es, Some(2026));
        assert_eq!((this_year.entries, this_year.words, this_year.days), (3, 10, 2));
        assert_eq!(split_stats(&es, Some(2024)).names, ["home"]);
        assert!(split_stats(&es, Some(2020)).is_empty());
        assert!(split_stats(&es[..2], None).is_empty() && split_stats(&es[..2], None).names.is_empty());
    }
}
