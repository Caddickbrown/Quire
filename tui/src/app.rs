//! The screens, their state, and what every key does. Drawing is in `ui`.

use crate::editor::{Editor, VisualRow};
use crate::paste::{self, Clip};
use crate::theme::{truecolor, Palette};
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent, MouseEventKind};
use quire_core::media;
use quire_core::prompts;
use quire_core::search::Query;
use quire_core::stats;
use quire_core::themes;
use quire_core::*;
use ratatui::layout::{Position, Rect};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{mpsc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Screen {
    Today,
    Inbox,
    Browse,
    Write,
    LookBack,
    Search,
    Settings,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Pick {
    Main,
    All,
    Split(String),
}

pub struct Browse {
    pub pick: Pick,
    /// 0 year · 1 month · 2 day · 3 entries
    pub col: usize,
    pub yi: usize,
    pub mi: usize,
    pub di: usize,
    pub ei: usize,
    pub filter: String,
    pub filtering: bool,
}

pub struct Draft {
    pub ed: Editor,
    pub ts: String,
    pub starred: bool,
    /// (file, index, raw) once it is on disk.
    pub ref_: Option<(String, usize, String)>,
    /// Editing something already filed (or in a split journal).
    pub filed: bool,
    pub saved_at: Option<String>,
    /// A brand-new draft keeps its timestamp "now" until the first keystroke.
    pub floating: bool,
}

#[derive(Clone, PartialEq, Eq)]
pub enum Confirm {
    DeleteSelected,
    DiscardDraft,
    Cleanup,
    FileAll,
    ClearOrphans,
    MergeSplits,
    CompressMedia,
    MergeTags(Vec<String>, String),
    ImportMarkdown(String),
    ImportDayOne(String),
    FileTransfer,
    MergeConflicts,
    /// Restore this backup over the journal.
    Restore(String),
}

/// What a one-line text prompt is for.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Ask {
    BackupDir,
    ExportPath,
    RenameTag,
    ImportMarkdown,
    ImportDayOne,
}

pub enum Modal {
    Retime(String),
    Confirm { text: String, action: Confirm },
    Input { label: &'static str, value: String, ask: Ask },
    /// Pick a backup to restore: (names newest first, chosen).
    Restore(Vec<String>, usize),
    Tags(Vec<TagGroup>, usize),
}

/// What a cell on screen does when clicked. `ui` records these as it draws;
/// the last one drawn over a cell wins.
#[derive(Clone, Debug)]
pub enum Hit {
    /// As if the key were pressed: the hint bar, a modal's answers.
    Key(KeyEvent),
    /// Open this entry (file, index) in the composer.
    Edit(String, usize),
    /// The same click, on a pane of text: no hover highlight.
    Preview(String, usize),
    /// Show this entry in Browse.
    Show(String, usize),
    /// Today's prompt: start writing from it.
    Prompt,
    /// The QUIRE mark: back to Today.
    Home,
    /// A row of the inbox's draft list.
    Draft(usize),
    /// A Browse column (year · month · day · entries), for the wheel.
    Column(usize),
    /// A row in a Browse column: (column, index).
    Item(usize, usize),
    Pick(Pick),
    Result(usize),
    Year(i32),
    /// A row of the composer's text: the visual row, its left edge, and
    /// whether it is the last segment of its line.
    Text(VisualRow, u16, bool),
    /// The composer below its text.
    TextEnd,
    Suggestion(usize),
    /// A row of the settings page.
    Setting(usize),
}

enum Attachment {
    Path(PathBuf),
    Bytes(Vec<u8>, &'static str),
}

pub struct App {
    pub j: Journal,
    pub settings: Settings,
    pub split_tags: Vec<String>,
    pub pal: Palette,
    pub theme_id: String,
    pub entries: Vec<Entry>,
    pub screen: Screen,
    pub stack: Vec<Screen>,
    pub today: String,
    pub prompt_n: usize,
    pub inbox_i: usize,
    pub browse: Browse,
    pub draft: Option<Draft>,
    pub year: i32,
    pub query: String,
    pub search_i: usize,
    pub settings_i: usize,
    pub modal: Option<Modal>,
    pub help: bool,
    pub toast: Option<(String, Instant, bool)>,
    pub quit: bool,
    /// When the running timer ends; `None` when it is off or paused.
    pub timer_end: Option<Instant>,
    /// Time left on a paused timer.
    pub timer_paused: Option<Duration>,
    pub focus: bool,
    pub tag_pick: usize,
    pub width: u16,
    pub height: u16,
    /// Mouse capture on (F2 toggles it; `terminalMouse` in settings.json).
    pub mouse: bool,
    pub hits: RefCell<Vec<(Rect, Hit)>>,
    /// Where the pointer last was, for highlighting what a click would hit.
    pub hover: Option<(u16, u16)>,
    last_check: Instant,
    fingerprint: u64,
    pub maintenance_running: bool,
    maintenance_result: Option<mpsc::Receiver<Result<String, String>>>,
    backup_schedule: crate::backup::Schedule,
    backup_result: Option<mpsc::Receiver<Result<String, String>>>,
}

pub struct Sel {
    pub year: Option<String>,
    pub month: Option<String>,
    pub date: Option<String>,
    pub entry: Option<Entry>,
}

impl App {
    pub fn new(j: Journal, settings: Settings, split_tags: Vec<String>, theme_id: &str) -> App {
        let theme = themes::theme(theme_id);
        let pal = Palette::from_theme(&theme, truecolor());
        let today = stats::today();
        let year: i32 = today[..4].parse().unwrap_or(2026);
        let mouse = settings.ui_bool("terminalMouse").unwrap_or(true);
        let mut a = App {
            j,
            settings,
            split_tags,
            pal,
            theme_id: theme.id,
            entries: Vec::new(),
            screen: Screen::Today,
            stack: Vec::new(),
            today,
            prompt_n: 0,
            inbox_i: 0,
            browse: Browse { pick: Pick::Main, col: 2, yi: 0, mi: 0, di: 0, ei: 0, filter: String::new(), filtering: false },
            draft: None,
            year,
            query: String::new(),
            search_i: 0,
            settings_i: 0,
            modal: None,
            help: false,
            toast: None,
            quit: false,
            timer_end: None,
            timer_paused: None,
            hover: None,
            focus: false,
            tag_pick: 0,
            width: 100,
            height: 30,
            mouse,
            hits: RefCell::new(Vec::new()),
            last_check: Instant::now(),
            fingerprint: 0,
            maintenance_running: false,
            maintenance_result: None,
            backup_schedule: crate::backup::Schedule::default(),
            backup_result: None,
        };
        a.reload();
        a
    }

    pub fn reload(&mut self) {
        self.entries = self.j.load_all();
        let fingerprint = self.fingerprint_now();
        if fingerprint != self.fingerprint { self.backup_schedule.changed(Instant::now()); }
        self.fingerprint = fingerprint;
        self.clamp();
    }

    fn fingerprint_now(&self) -> u64 {
        let mut h: u64 = 1469598103934665603;
        for (rel, _, _) in self.j.entry_files() {
            for b in rel.bytes() {
                h = (h ^ b as u64).wrapping_mul(1099511628211);
            }
            h = (h ^ self.j.vault().modified(&rel).unwrap_or(0)).wrapping_mul(1099511628211);
            h = (h ^ self.j.len(&rel)).wrapping_mul(1099511628211);
        }
        h
    }

    fn clamp(&mut self) {
        let n = self.drafts().len();
        self.inbox_i = if n == 0 { 0 } else { self.inbox_i.min(n - 1) };
        let n = self.results().len();
        self.search_i = if n == 0 { 0 } else { self.search_i.min(n - 1) };
        self.clamp_browse();
    }

    /// Record what a region of the screen does when clicked.
    pub fn hit(&self, r: Rect, h: Hit) {
        if r.width > 0 && r.height > 0 {
            self.hits.borrow_mut().push((r, h));
        }
    }

    pub fn toast(&mut self, msg: String, error: bool) {
        self.toast = Some((msg, Instant::now(), error));
    }

    fn push(&mut self, s: Screen) {
        if self.screen != s {
            self.stack.push(self.screen);
            self.screen = s;
        }
        self.help = false;
    }

    fn back(&mut self) {
        self.screen = self.stack.pop().unwrap_or(Screen::Today);
        self.help = false;
    }

    // ----- data for the screens -----

    pub fn drafts(&self) -> Vec<&Entry> {
        let mut v: Vec<&Entry> = self.entries.iter().filter(|e| e.source == "inbox").collect();
        v.sort_by(|a, b| b.ts.cmp(&a.ts));
        v
    }

    pub fn filed(&self) -> Vec<&Entry> {
        self.entries.iter().filter(|e| e.source != "inbox").collect()
    }

    pub fn current_prompt(&self) -> &'static str {
        prompts::prompt_after(&self.today, self.prompt_n)
    }

    pub fn tag_counts(&self) -> Vec<(String, usize)> {
        stats::count_tags(self.entries.iter())
    }

    pub fn split_names(&self) -> Vec<String> {
        let mut v: Vec<String> = self.entries.iter().filter_map(|e| e.split.clone()).collect();
        v.sort();
        v.dedup();
        v
    }

    pub fn browse_pool(&self) -> Vec<&Entry> {
        self.entries
            .iter()
            .filter(|e| match &self.browse.pick {
                Pick::Main => e.source == "journal",
                Pick::All => true,
                Pick::Split(t) => e.split.as_deref() == Some(t.as_str()),
            })
            .collect()
    }

    fn filtered(&self, items: Vec<(String, usize)>, label: impl Fn(&str) -> String) -> Vec<(String, usize)> {
        if !self.browse.filtering || self.browse.filter.is_empty() {
            return items;
        }
        let f = self.browse.filter.to_lowercase();
        items.into_iter().filter(|(k, _)| k.to_lowercase().starts_with(&f) || label(k).to_lowercase().starts_with(&f)).collect()
    }

    /// Years, newest first, with entry counts.
    pub fn browse_years(&self) -> Vec<(String, usize)> {
        let mut m: BTreeMap<String, usize> = BTreeMap::new();
        for e in self.browse_pool() {
            *m.entry(e.date[..4].to_string()).or_default() += 1;
        }
        let v: Vec<(String, usize)> = m.into_iter().rev().collect();
        if self.browse.col == 0 {
            self.filtered(v, |k| k.to_string())
        } else {
            v
        }
    }

    pub fn browse_months(&self, year: &str) -> Vec<(String, usize)> {
        let mut m: BTreeMap<String, usize> = BTreeMap::new();
        for e in self.browse_pool().into_iter().filter(|e| e.date.starts_with(year)) {
            *m.entry(e.date[5..7].to_string()).or_default() += 1;
        }
        let v: Vec<(String, usize)> = m.into_iter().rev().collect();
        if self.browse.col == 1 {
            self.filtered(v, |k| stats::month_name(k.parse().unwrap_or(1)).to_string())
        } else {
            v
        }
    }

    pub fn browse_days(&self, year: &str, month: &str) -> Vec<(String, usize)> {
        let prefix = format!("{}-{}", year, month);
        let mut m: BTreeMap<String, usize> = BTreeMap::new();
        for e in self.browse_pool().into_iter().filter(|e| e.date.starts_with(&prefix)) {
            *m.entry(e.date.clone()).or_default() += 1;
        }
        let v: Vec<(String, usize)> = m.into_iter().rev().collect();
        if self.browse.col == 2 {
            self.filtered(v, |k| k[8..].to_string())
        } else {
            v
        }
    }

    pub fn browse_day_entries(&self, date: &str) -> Vec<&Entry> {
        let mut v: Vec<&Entry> = self.browse_pool().into_iter().filter(|e| e.date == date).collect();
        v.sort_by(|a, b| a.ts.cmp(&b.ts));
        v
    }

    pub fn browse_sel(&self) -> Sel {
        let years = self.browse_years();
        let year = years.get(self.browse.yi).map(|y| y.0.clone());
        let months = year.as_deref().map(|y| self.browse_months(y)).unwrap_or_default();
        let month = months.get(self.browse.mi).map(|m| m.0.clone());
        let days = match (&year, &month) {
            (Some(y), Some(m)) => self.browse_days(y, m),
            _ => vec![],
        };
        let date = days.get(self.browse.di).map(|d| d.0.clone());
        let entry = date.as_deref().and_then(|d| self.browse_day_entries(d).get(self.browse.ei).map(|e| (*e).clone()));
        Sel { year, month, date, entry }
    }

    fn clamp_browse(&mut self) {
        let years = self.browse_years();
        self.browse.yi = years.len().saturating_sub(1).min(self.browse.yi);
        let Some(y) = years.get(self.browse.yi).map(|y| y.0.clone()) else {
            self.browse.mi = 0;
            self.browse.di = 0;
            self.browse.ei = 0;
            return;
        };
        let months = self.browse_months(&y);
        self.browse.mi = months.len().saturating_sub(1).min(self.browse.mi);
        let Some(m) = months.get(self.browse.mi).map(|m| m.0.clone()) else { return };
        let days = self.browse_days(&y, &m);
        self.browse.di = days.len().saturating_sub(1).min(self.browse.di);
        let Some(d) = days.get(self.browse.di).map(|d| d.0.clone()) else { return };
        let n = self.browse_day_entries(&d).len();
        self.browse.ei = n.saturating_sub(1).min(self.browse.ei);
    }

    pub fn results(&self) -> Vec<&Entry> {
        let q = Query::parse(&self.query);
        if q.is_empty() {
            return vec![];
        }
        let mut v: Vec<&Entry> = self.entries.iter().filter(|e| q.matches(e)).collect();
        v.sort_by(|a, b| b.ts.cmp(&a.ts));
        v.truncate(300);
        v
    }

    /// Matching tags for the `@word` under the caret, most used first.
    pub fn tag_suggestions(&self) -> Vec<String> {
        let Some(d) = &self.draft else { return vec![] };
        let Some((_, prefix)) = d.ed.tag_prefix() else { return vec![] };
        let p = prefix.to_lowercase();
        let want = format!("@{}", p);
        self.tag_counts().into_iter().filter(|(t, _)| t.to_lowercase().starts_with(&want) && t.to_lowercase() != want).map(|(t, _)| t).take(5).collect()
    }

    pub fn words_today(&self) -> usize {
        let mut n: usize = self.entries.iter().filter(|e| e.date == self.today && !self.is_draft_ref(e)).map(|e| e.words).sum();
        if let Some(d) = &self.draft {
            if d.ts.starts_with(&self.today) {
                n += d.ed.word_count();
            }
        }
        n
    }

    fn is_draft_ref(&self, e: &Entry) -> bool {
        self.draft.as_ref().and_then(|d| d.ref_.as_ref()).map(|(f, i, _)| *f == e.file && *i == e.index).unwrap_or(false)
    }

    pub fn destination_of(&self, e: &Entry) -> String {
        split_target(&e.raw, &self.split_tags).unwrap_or_else(|| journal_rel(&e.date))
    }

    // ----- actions -----

    pub fn start_draft(&mut self, title: &str, body: &str) {
        let mut ed = Editor::new(title, body);
        ed.to_end();
        if title.is_empty() && body.is_empty() {
            ed.row = 0;
            ed.col = 0;
        }
        let empty = ed.is_empty();
        self.draft = Some(Draft { ed, ts: now_local(), starred: false, ref_: None, filed: false, saved_at: None, floating: empty });
        self.focus = false;
        self.push(Screen::Write);
    }

    pub fn edit_entry(&mut self, e: &Entry) {
        let mut ed = Editor::new(&e.title, &e.body);
        ed.to_end();
        self.draft = Some(Draft {
            ed,
            ts: e.ts.clone(),
            starred: e.starred,
            ref_: Some((e.file.clone(), e.index, e.raw.clone())),
            filed: e.source != "inbox",
            saved_at: None,
            floating: false,
        });
        self.focus = false;
        self.push(Screen::Write);
    }

    /// Write the composer to disk if anything changed. Ok(true) when it did.
    pub fn save_draft(&mut self) -> Result<bool, String> {
        let Some(d) = self.draft.as_mut() else { return Ok(false) };
        if !d.ed.dirty {
            return Ok(false);
        }
        let (title, body) = (d.ed.title(), d.ed.body());
        if title.trim().is_empty() && body.trim().is_empty() && !d.starred && d.ref_.is_none() {
            return Ok(false);
        }
        let w = match &d.ref_ {
            None => self.j.new_draft(&d.ts, &title, d.starred, &body)?,
            Some((f, i, raw)) => self.j.update_entry(f, *i, raw, &d.ts, &title, d.starred, &body)?,
        };
        d.ref_ = Some((w.file, w.index, w.raw));
        d.ed.dirty = false;
        d.saved_at = Some(stats::now_time());
        self.reload();
        Ok(true)
    }

    fn leave_write(&mut self) {
        match self.save_draft() {
            Ok(_) => {
                self.draft = None;
                self.focus = false;
                self.back();
            }
            Err(e) => self.toast(e, true),
        }
    }

    fn file_from_write(&mut self) {
        if let Err(e) = self.save_draft() {
            self.toast(e, true);
            return;
        }
        let Some(d) = &self.draft else { return };
        if d.filed {
            self.toast("Already filed — Esc to leave it".into(), false);
            return;
        }
        let Some((f, i, raw)) = d.ref_.clone() else {
            self.toast("Nothing to file".into(), false);
            return;
        };
        match self.j.file_draft(&f, i, &raw, &self.split_tags) {
            Ok(dest) => {
                self.draft = None;
                self.focus = false;
                self.reload();
                self.back();
                self.toast(format!("Filed to {}", dest), false);
            }
            Err(e) => self.toast(e, true),
        }
    }

    fn file_selected_draft(&mut self) {
        let Some(e) = self.drafts().get(self.inbox_i).map(|e| (*e).clone()) else { return };
        match self.j.file_draft(&e.file, e.index, &e.raw, &self.split_tags) {
            Ok(dest) => {
                self.reload();
                self.toast(format!("Filed to {}", dest), false);
            }
            Err(err) => self.toast(err, true),
        }
    }

    fn toggle_star_selected(&mut self) {
        let sel = match self.screen {
            Screen::Inbox => self.drafts().get(self.inbox_i).map(|e| (*e).clone()),
            Screen::Browse => self.browse_sel().entry,
            _ => None,
        };
        let Some(e) = sel else { return };
        match self.j.update_entry(&e.file, e.index, &e.raw, &e.ts, &e.title, !e.starred, &e.body) {
            Ok(_) => self.reload(),
            Err(err) => self.toast(err, true),
        }
    }

    fn selected_entry(&self) -> Option<Entry> {
        match self.screen {
            Screen::Inbox => self.drafts().get(self.inbox_i).map(|e| (*e).clone()),
            Screen::Browse => self.browse_sel().entry,
            Screen::Search => self.results().get(self.search_i).map(|e| (*e).clone()),
            _ => None,
        }
    }

    fn delete_selected(&mut self) {
        let Some(e) = self.selected_entry() else { return };
        match self.j.delete_entry(&e.file, e.index, &e.raw) {
            Ok(()) => {
                self.reload();
                self.toast("Deleted".into(), false);
            }
            Err(err) => self.toast(err, true),
        }
    }

    fn unfile_selected(&mut self) {
        let Some(e) = self.browse_sel().entry else { return };
        if e.source == "inbox" {
            self.toast("Already in the inbox".into(), false);
            return;
        }
        match self.j.unfile_entry(&e.file, e.index, &e.raw) {
            Ok(w) => {
                self.reload();
                self.toast(format!("Back in the inbox: {}", w.file), false);
            }
            Err(err) => self.toast(err, true),
        }
    }

    fn apply_retime(&mut self, value: &str) {
        let v = value.trim();
        let ts = if v.len() == 16 { format!("{}:00", v) } else { v.to_string() };
        if check_ts(&ts).is_err() {
            self.toast("Use YYYY-MM-DD HH:MM".into(), true);
            return;
        }
        if self.screen == Screen::Write {
            if let Some(d) = self.draft.as_mut() {
                d.ts = ts;
                d.floating = false;
                d.ed.dirty = true;
            }
            if let Err(e) = self.save_draft() {
                self.toast(e, true);
            }
            return;
        }
        let Some(e) = self.selected_entry() else { return };
        match self.j.update_entry(&e.file, e.index, &e.raw, &ts, &e.title, e.starred, &e.body) {
            Ok(w) => {
                self.reload();
                self.toast(format!("Moved to {}", w.file), false);
            }
            Err(err) => self.toast(err, true),
        }
    }

    pub fn random(&mut self) {
        use rand::Rng;
        let pool: Vec<Entry> = self.filed().into_iter().cloned().collect();
        if pool.is_empty() {
            self.toast("No journal entries yet".into(), false);
            return;
        }
        let e = pool[rand::rng().random_range(0..pool.len())].clone();
        self.goto_entry(&e);
    }

    /// Open Browse with this entry selected.
    pub fn goto_entry(&mut self, e: &Entry) {
        self.browse.pick = match (&e.source[..], &e.split) {
            ("split", Some(t)) => Pick::Split(t.clone()),
            ("inbox", _) => Pick::All,
            _ => Pick::Main,
        };
        self.browse.filtering = false;
        self.browse.filter.clear();
        self.browse.yi = self.browse_years().iter().position(|y| y.0 == e.date[..4]).unwrap_or(0);
        self.browse.mi = self.browse_months(&e.date[..4]).iter().position(|m| m.0 == e.date[5..7]).unwrap_or(0);
        self.browse.di = self.browse_days(&e.date[..4], &e.date[5..7]).iter().position(|d| d.0 == e.date).unwrap_or(0);
        self.browse.ei = self.browse_day_entries(&e.date).iter().position(|x| x.file == e.file && x.index == e.index).unwrap_or(0);
        self.browse.col = 3;
        if self.screen != Screen::Browse {
            self.push(Screen::Browse);
        }
    }

    fn cycle_pick(&mut self) {
        let splits = self.split_names();
        self.browse.pick = match &self.browse.pick {
            Pick::Main => splits.first().map(|s| Pick::Split(s.clone())).unwrap_or(Pick::All),
            Pick::Split(t) => match splits.iter().position(|s| s == t) {
                Some(i) if i + 1 < splits.len() => Pick::Split(splits[i + 1].clone()),
                _ => Pick::All,
            },
            Pick::All => Pick::Main,
        };
        self.browse.yi = 0;
        self.browse.mi = 0;
        self.browse.di = 0;
        self.browse.ei = 0;
        self.clamp_browse();
    }

    // ----- the loop -----

    pub fn tick(&mut self) {
        self.poll_backup();
        self.poll_maintenance();
        if !self.maintenance_running && self.backup_result.is_none() && !self.quit && self.backup_schedule.due(&self.settings, Instant::now()) {
            self.run_backup();
        }
        if let Some((_, at, err)) = &self.toast {
            if at.elapsed() > Duration::from_millis(if *err { 5000 } else { 3000 }) {
                self.toast = None;
            }
        }
        if let Some(end) = self.timer_end {
            if Instant::now() >= end {
                self.timer_end = None;
                if self.settings.ui_bool("chime").unwrap_or(true) {
                    use std::io::Write;
                    let _ = std::io::stdout().write_all(b"\x07").and_then(|_| std::io::stdout().flush());
                }
                self.toast("Time. Finish the sentence.".into(), false);
            }
        }
        let autosave_due = !self.maintenance_running && self.draft.as_ref().map(|d| d.ed.dirty && d.ed.last_edit.elapsed() > Duration::from_millis(700)).unwrap_or(false);
        if autosave_due {
            if let Err(e) = self.save_draft() {
                self.toast(e, true);
                if let Some(d) = self.draft.as_mut() {
                    d.ed.last_edit = Instant::now(); // try again in a while, not every tick
                }
            }
        }
        if self.screen != Screen::Write && self.last_check.elapsed() > Duration::from_secs(4) {
            self.last_check = Instant::now();
            let today = stats::today();
            if today != self.today {
                self.today = today;
            }
            if self.fingerprint_now() != self.fingerprint {
                self.reload();
            }
        }
    }

    pub fn handle_key(&mut self, k: KeyEvent) {
        if k.kind != KeyEventKind::Press && k.kind != KeyEventKind::Repeat {
            return;
        }
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        let alt = k.modifiers.contains(KeyModifiers::ALT);
        if ctrl && k.code == KeyCode::Char('c') {
            self.quit = true;
            return;
        }
        if self.maintenance_running { return; }
        if k.code == KeyCode::F(2) {
            self.toggle_mouse();
            return;
        }
        if self.modal.is_some() {
            self.modal_key(k);
            return;
        }
        if self.help {
            self.help = false;
            return;
        }
        if k.code == KeyCode::F(1) || (k.code == KeyCode::Char('?') && self.screen != Screen::Write && self.screen != Screen::Search && !self.browse.filtering) {
            self.help = true;
            return;
        }
        match self.screen {
            Screen::Today => self.today_key(k),
            Screen::Inbox => self.inbox_key(k),
            Screen::Browse => self.browse_key(k),
            Screen::Write => self.write_key(k, ctrl, alt),
            Screen::LookBack => self.lookback_key(k),
            Screen::Search => self.search_key(k),
            Screen::Settings => self.settings_key(k),
        }
    }

    fn common_nav(&mut self, k: &KeyEvent) -> bool {
        match k.code {
            KeyCode::Char('n') => {
                self.start_draft("", "");
                true
            }
            KeyCode::Char('i') => {
                self.push(Screen::Inbox);
                true
            }
            KeyCode::Char('j') => {
                self.push(Screen::Browse);
                true
            }
            KeyCode::Char('l') => {
                self.push(Screen::LookBack);
                true
            }
            KeyCode::Char('/') => {
                self.push(Screen::Search);
                true
            }
            KeyCode::Char(',') => {
                self.push(Screen::Settings);
                true
            }
            KeyCode::Char('r') => {
                self.random();
                true
            }
            _ => false,
        }
    }

    fn today_key(&mut self, k: KeyEvent) {
        if self.common_nav(&k) {
            return;
        }
        match k.code {
            KeyCode::Char('q') | KeyCode::Esc => self.quit = true,
            KeyCode::Char('p') => self.prompt_n += 1,
            KeyCode::Enter => {
                let p = self.current_prompt();
                self.start_draft("", &format!("> {}\n\n", p));
            }
            _ => {}
        }
    }

    fn inbox_key(&mut self, k: KeyEvent) {
        let n = self.drafts().len();
        match k.code {
            KeyCode::Esc | KeyCode::Char('q') => self.back(),
            KeyCode::Up | KeyCode::Char('k') => self.inbox_i = self.inbox_i.saturating_sub(1),
            KeyCode::Down => {
                if n > 0 {
                    self.inbox_i = (self.inbox_i + 1).min(n - 1)
                }
            }
            KeyCode::Char('f') => self.file_selected_draft(),
            KeyCode::Char('e') | KeyCode::Enter => {
                if let Some(e) = self.drafts().get(self.inbox_i).map(|e| (*e).clone()) {
                    self.edit_entry(&e);
                }
            }
            KeyCode::Char('*') => self.toggle_star_selected(),
            KeyCode::Char('t') => {
                if let Some(e) = self.selected_entry() {
                    self.modal = Some(Modal::Retime(e.ts[..16].to_string()));
                }
            }
            KeyCode::Char('d') => {
                if self.selected_entry().is_some() {
                    self.modal = Some(Modal::Confirm { text: "Delete this draft?".into(), action: Confirm::DeleteSelected });
                }
            }
            _ => {
                self.common_nav(&k);
            }
        }
    }

    fn browse_key(&mut self, k: KeyEvent) {
        if self.browse.filtering {
            match k.code {
                KeyCode::Esc => {
                    self.browse.filtering = false;
                    self.browse.filter.clear();
                    self.clamp_browse();
                }
                KeyCode::Enter => self.browse.filtering = false,
                KeyCode::Backspace => {
                    self.browse.filter.pop();
                    self.clamp_browse();
                }
                KeyCode::Char(c) => {
                    self.browse.filter.push(c);
                    self.clamp_browse();
                }
                _ => {}
            }
            return;
        }
        match k.code {
            KeyCode::Esc | KeyCode::Char('q') => self.back(),
            KeyCode::Left | KeyCode::Char('h') => self.browse.col = self.browse.col.saturating_sub(1),
            KeyCode::Right => self.browse.col = (self.browse.col + 1).min(3),
            KeyCode::Up | KeyCode::Char('k') => {
                match self.browse.col {
                    0 => self.browse.yi = self.browse.yi.saturating_sub(1),
                    1 => self.browse.mi = self.browse.mi.saturating_sub(1),
                    2 => self.browse.di = self.browse.di.saturating_sub(1),
                    _ => self.browse.ei = self.browse.ei.saturating_sub(1),
                }
                self.after_browse_move();
            }
            KeyCode::Down => {
                match self.browse.col {
                    0 => self.browse.yi += 1,
                    1 => self.browse.mi += 1,
                    2 => self.browse.di += 1,
                    _ => self.browse.ei += 1,
                }
                self.after_browse_move();
            }
            KeyCode::Enter => {
                if self.browse.col < 3 {
                    self.browse.col += 1;
                } else if let Some(e) = self.browse_sel().entry {
                    self.edit_entry(&e);
                }
            }
            KeyCode::Char('/') => {
                self.browse.filtering = true;
                self.browse.filter.clear();
            }
            KeyCode::Char('s') => self.cycle_pick(),
            KeyCode::Char('u') => self.unfile_selected(),
            KeyCode::Char('*') => self.toggle_star_selected(),
            KeyCode::Char('t') => {
                if let Some(e) = self.selected_entry() {
                    self.modal = Some(Modal::Retime(e.ts[..16].to_string()));
                }
            }
            KeyCode::Char('d') => {
                if self.selected_entry().is_some() {
                    self.modal = Some(Modal::Confirm { text: "Delete this entry?".into(), action: Confirm::DeleteSelected });
                }
            }
            _ => {
                self.common_nav(&k);
            }
        }
    }

    fn after_browse_move(&mut self) {
        match self.browse.col {
            0 => {
                self.browse.mi = 0;
                self.browse.di = 0;
                self.browse.ei = 0;
            }
            1 => {
                self.browse.di = 0;
                self.browse.ei = 0;
            }
            2 => self.browse.ei = 0,
            _ => {}
        }
        self.clamp_browse();
    }

    /// ^o: start the timer, pause it while it runs, resume it when paused.
    fn toggle_timer(&mut self) {
        if let Some(end) = self.timer_end.take() {
            self.timer_paused = Some(end.saturating_duration_since(Instant::now()));
        } else {
            let left = self.timer_paused.take().unwrap_or_else(|| Duration::from_secs(60 * self.settings.timer_minutes()));
            self.timer_end = Some(Instant::now() + left);
        }
    }

    /// Time left and whether the timer is paused, when one is on.
    pub fn timer_left(&self) -> Option<(Duration, bool)> {
        match (self.timer_end, self.timer_paused) {
            (Some(end), _) => Some((end.saturating_duration_since(Instant::now()), false)),
            (None, Some(left)) => Some((left, true)),
            _ => None,
        }
    }

    fn write_key(&mut self, k: KeyEvent, ctrl: bool, alt: bool) {
        let width = self.editor_width();
        let suggestions = self.tag_suggestions();
        let Some(d) = self.draft.as_mut() else { return };
        if d.floating && matches!(k.code, KeyCode::Char(_) | KeyCode::Enter) && !ctrl {
            d.ts = now_local();
            d.floating = false;
        }
        if alt && k.code == KeyCode::Char('o') {
            self.timer_end = None;
            self.timer_paused = None;
            self.toast("Timer reset".into(), false);
            return;
        }
        if ctrl {
            match k.code {
                KeyCode::Char('s') => match self.save_draft() {
                    Ok(true) => self.toast("Saved".into(), false),
                    Ok(false) => self.toast("Nothing new to save".into(), false),
                    Err(e) => self.toast(e, true),
                },
                KeyCode::Char('j') => self.file_from_write(),
                KeyCode::Char('t') => {
                    let ts = d.ts[..16].to_string();
                    self.modal = Some(Modal::Retime(ts));
                }
                KeyCode::Char('f') => self.focus = !self.focus,
                KeyCode::Char('v') => self.paste_clipboard(),
                KeyCode::Char('p') => {
                    self.prompt_n += 1;
                    let p = self.current_prompt();
                    let d = self.draft.as_mut().unwrap();
                    if d.ed.col > 0 {
                        d.ed.insert_str("\n\n");
                    }
                    d.ed.insert_str(&format!("> {}\n\n", p));
                }
                KeyCode::Char('o') => self.toggle_timer(),
                KeyCode::Char('b') => d.ed.toggle_wrap_word("**", "**"),
                KeyCode::Char('i') => d.ed.toggle_wrap_word("_", "_"),
                KeyCode::Char('g') => d.ed.toggle_wrap_word("`", "`"),
                KeyCode::Char('w') | KeyCode::Backspace => d.ed.delete_word_back(),
                KeyCode::Char('a') => d.ed.home(),
                KeyCode::Char('e') => d.ed.end(),
                KeyCode::Left => d.ed.word_left(),
                KeyCode::Right => d.ed.word_right(),
                KeyCode::Char('d') => {
                    if d.ref_.is_none() && d.ed.is_empty() {
                        self.draft = None;
                        self.back();
                    } else {
                        self.modal = Some(Modal::Confirm { text: "Discard this draft?".into(), action: Confirm::DiscardDraft });
                    }
                }
                _ => {}
            }
            return;
        }
        if alt {
            match k.code {
                KeyCode::Left | KeyCode::Char('b') => d.ed.word_left(),
                KeyCode::Right | KeyCode::Char('f') => d.ed.word_right(),
                KeyCode::Backspace => d.ed.delete_word_back(),
                _ => {}
            }
            return;
        }
        match k.code {
            KeyCode::Esc => {
                if !suggestions.is_empty() {
                    d.ed.insert_char(' ');
                } else {
                    self.leave_write();
                }
            }
            KeyCode::Tab => {
                if let Some(t) = suggestions.get(self.tag_pick.min(suggestions.len().saturating_sub(1))) {
                    d.ed.accept_tag(t);
                    self.tag_pick = 0;
                } else if d.ed.row > 0 && quire_core::editing::list_continuation(&d.ed.lines[d.ed.row]).is_some() {
                    let col = d.ed.col;
                    d.ed.home();
                    d.ed.insert_str("  ");
                    d.ed.col = col + 2;
                }
            }
            KeyCode::BackTab => {
                if d.ed.row > 0 && d.ed.lines[d.ed.row].starts_with("  ") {
                    d.ed.lines[d.ed.row].drain(..2);
                    d.ed.col = d.ed.col.saturating_sub(2);
                    d.ed.dirty = true;
                }
            }
            KeyCode::Enter => {
                if let Some(t) = suggestions.get(self.tag_pick.min(suggestions.len().saturating_sub(1))) {
                    d.ed.accept_tag(t);
                    self.tag_pick = 0;
                } else if d.ed.row == 0 {
                    // Leaving the title: into the body, past the blank line.
                    if d.ed.lines.len() == 1 {
                        d.ed.lines.push(String::new());
                        d.ed.lines.push(String::new());
                        d.ed.dirty = true;
                    }
                    d.ed.row = 2.min(d.ed.lines.len() - 1);
                    d.ed.col = 0;
                } else {
                    d.ed.newline();
                }
            }
            KeyCode::Backspace => d.ed.backspace(),
            KeyCode::Delete => d.ed.delete(),
            KeyCode::Left => d.ed.left(),
            KeyCode::Right => d.ed.right(),
            KeyCode::Up => {
                if !suggestions.is_empty() {
                    self.tag_pick = self.tag_pick.saturating_sub(1);
                } else {
                    d.ed.up(width);
                }
            }
            KeyCode::Down => {
                if !suggestions.is_empty() {
                    self.tag_pick = (self.tag_pick + 1).min(suggestions.len() - 1);
                } else {
                    d.ed.down(width);
                }
            }
            KeyCode::Home => d.ed.home(),
            KeyCode::End => d.ed.end(),
            KeyCode::PageUp => {
                for _ in 0..10 {
                    d.ed.up(width);
                }
            }
            KeyCode::PageDown => {
                for _ in 0..10 {
                    d.ed.down(width);
                }
            }
            KeyCode::Char(c) => {
                d.ed.insert_char(c);
                self.tag_pick = 0;
            }
            _ => {}
        }
    }

    /// The composer's text width: a measure, not the whole terminal.
    pub fn editor_width(&self) -> usize {
        let w = self.width as usize;
        let margin = if w > 90 { 8 } else if w > 60 { 4 } else { 2 };
        (w.saturating_sub(margin * 2)).clamp(20, 72)
    }

    fn lookback_key(&mut self, k: KeyEvent) {
        let years = stats::years(&self.entries, self.today[..4].parse().unwrap_or(2026));
        let i = years.iter().position(|y| *y == self.year).unwrap_or(0);
        match k.code {
            KeyCode::Esc | KeyCode::Char('q') => self.back(),
            KeyCode::Left => {
                if i + 1 < years.len() {
                    self.year = years[i + 1];
                }
            }
            KeyCode::Right => {
                if i > 0 {
                    self.year = years[i - 1];
                }
            }
            _ => {
                self.common_nav(&k);
            }
        }
    }

    fn search_key(&mut self, k: KeyEvent) {
        let n = self.results().len();
        match k.code {
            KeyCode::Esc => {
                if self.query.is_empty() {
                    self.back();
                } else {
                    self.query.clear();
                    self.search_i = 0;
                }
            }
            KeyCode::Enter => {
                if let Some(e) = self.results().get(self.search_i).map(|e| (*e).clone()) {
                    self.edit_entry(&e);
                }
            }
            KeyCode::Up => self.search_i = self.search_i.saturating_sub(1),
            KeyCode::Down => {
                if n > 0 {
                    self.search_i = (self.search_i + 1).min(n - 1)
                }
            }
            KeyCode::Backspace => {
                self.query.pop();
                self.search_i = 0;
            }
            KeyCode::Char(c) => {
                self.query.push(c);
                self.search_i = 0;
            }
            _ => {}
        }
    }

    fn modal_key(&mut self, k: KeyEvent) {
        let Some(m) = self.modal.as_mut() else { return };
        match m {
            Modal::Retime(v) => match k.code {
                KeyCode::Esc => self.modal = None,
                KeyCode::Enter => {
                    let v = v.clone();
                    self.modal = None;
                    self.apply_retime(&v);
                }
                KeyCode::Backspace => {
                    v.pop();
                }
                KeyCode::Char(c) if (c.is_ascii_digit() || c == '-' || c == ':' || c == ' ')
                    && v.len() < 19 => {
                        v.push(c)
                    }
                _ => {}
            },
            Modal::Input { value, ask, .. } => {
                let ask = *ask;
                match k.code {
                    KeyCode::Esc => self.modal = None,
                    KeyCode::Enter => {
                        let v = value.trim().to_string();
                        self.modal = None;
                        self.apply_ask(ask, &v);
                    }
                    KeyCode::Backspace => {
                        value.pop();
                    }
                    KeyCode::Char(c) if !k.modifiers.contains(KeyModifiers::CONTROL) => value.push(c),
                    _ => {}
                }
            }
            Modal::Restore(names, i) => match k.code {
                KeyCode::Esc => self.modal = None,
                KeyCode::Up | KeyCode::Left | KeyCode::Char('k') | KeyCode::Char('h') => *i = i.saturating_sub(1),
                KeyCode::Down | KeyCode::Right | KeyCode::Char('j') | KeyCode::Char('l') => *i = (*i + 1).min(names.len().saturating_sub(1)),
                KeyCode::Enter => {
                    if let Some(name) = names.get(*i).cloned() {
                        let text = format!("Restore {}? A safety copy is made first.", name);
                        self.modal = Some(Modal::Confirm { text, action: Confirm::Restore(name) });
                    }
                }
                _ => {}
            },
            Modal::Tags(groups, index) => match k.code {
                KeyCode::Esc => self.modal = None,
                KeyCode::Up | KeyCode::Left => *index = index.saturating_sub(1),
                KeyCode::Down | KeyCode::Right => *index = (*index + 1).min(groups.len().saturating_sub(1)),
                KeyCode::Enter => {
                    if let Some(group) = groups.get(*index) {
                        let from = group.tags.iter().map(|(tag, _)| tag.clone()).collect::<Vec<_>>();
                        let to = group.suggested.clone();
                        self.modal = Some(Modal::Confirm { text: format!("Merge {} into {}?", from.join(", "), to), action: Confirm::MergeTags(from, to) });
                    }
                }
                _ => {}
            },
            Modal::Confirm { action, .. } => {
                let action = action.clone();
                match k.code {
                    KeyCode::Char('y') | KeyCode::Char('Y') | KeyCode::Enter => {
                        self.modal = None;
                        match action {
                            Confirm::Cleanup => self.run_cleanup(),
                            Confirm::FileAll => self.run_file_all(),
                            Confirm::ClearOrphans => self.run_clear_orphans(),
                            Confirm::MergeSplits => {
                                let tags = self.split_tags.clone();
                                self.start_maintenance(move |j| merge_ex_split(&j, &tags).and_then(|r| if r.errors.is_empty() { Ok(format!("Merged {} entries from {} journals", r.entries, r.journals)) } else { Err(r.errors.join("; ")) }));
                            }
                            Confirm::CompressMedia => {
                                let (id, _) = self.settings.ensure_device_id();
                                self.persist(|s| s.device_id = Some(id.clone()));
                                self.start_maintenance(move |j| {
                                    let r = media::compress_existing(j.local()?, &id, &mut |_, _| {})?;
                                    let message = format!("Compressed {} media; saved {} bytes", r.images + r.videos + r.audio, r.saved_bytes);
                                    if !r.errors.is_empty() { Err(format!("{} — {}", message, r.errors.join("; "))) }
                                    else if !r.skipped_missing_tools.is_empty() { Err(format!("{} — missing {}", message, r.skipped_missing_tools.join(", "))) }
                                    else { Ok(message) }
                                });
                            }
                            Confirm::MergeTags(from, to) => self.start_maintenance(move |j| rename_tags(&j, &from, &to).map(|n| format!("Updated tags in {} files", n))),
                            Confirm::ImportMarkdown(path) => self.start_maintenance(move |j| import_markdown_folder(&j, std::path::Path::new(&path), false).map(|r| format!("Imported {} entries; {} skipped", r.written, r.skipped))),
                            Confirm::ImportDayOne(path) => self.start_maintenance(move |j| import_day_one(&j, std::path::Path::new(&path), false).map(|r| format!("Imported {} entries and {} media", r.written, r.media))),
                            Confirm::MergeConflicts => self.start_maintenance(move |j| {
                                let files = j.conflict_files(); let mut added = 0;
                                for file in &files { added += merge_conflict(&j, file)?; }
                                Ok(format!("Merged {} entries from {} conflict copies", added, files.len()))
                            }),
                            Confirm::FileTransfer => {
                                let tags = self.split_tags.clone();
                                self.start_maintenance(move |j| import_transfer(&j, &now_local(), &tags).map(|n| format!("Filed {} entries from transfer.md", n)));
                            }
                            Confirm::Restore(name) => self.run_restore(&name),
                            Confirm::DeleteSelected => self.delete_selected(),
                            Confirm::DiscardDraft => {
                                if let Some(d) = self.draft.take() {
                                    if let Some((f, i, raw)) = d.ref_ {
                                        if !d.filed {
                                            if let Err(e) = self.j.delete_entry(&f, i, &raw) {
                                                self.toast(e, true);
                                            }
                                        }
                                    }
                                }
                                self.focus = false;
                                self.reload();
                                self.back();
                                self.toast("Discarded".into(), false);
                            }
                        }
                    }
                    _ => self.modal = None,
                }
            }
        }
    }

    // ----- mouse -----

    /// Change a preference here and in the file, read fresh from disk so a
    /// change the desktop app made meanwhile survives.
    fn persist(&mut self, f: impl Fn(&mut Settings)) {
        f(&mut self.settings);
        let mut s = Settings::load();
        f(&mut s);
        if let Err(e) = s.save() {
            self.toast(e, true);
        }
    }

    fn toggle_mouse(&mut self) {
        self.mouse = !self.mouse;
        let on = self.mouse;
        self.persist(|s| s.set_ui("terminalMouse", serde_json::Value::Bool(on)));
        self.toast(if self.mouse { "Mouse on — shift-drag selects text" } else { "Mouse off — the terminal selects text" }.into(), false);
    }

    // ----- settings -----

    pub const SETTING_ROWS: usize = 24;

    /// Where each group of rows starts, with its heading.
    pub const SETTING_GROUPS: [(usize, &'static str); 3] = [(0, "WRITING"), (6, "BACKUPS"), (11, "MAINTENANCE")];

    /// Rows that do something when pressed instead of stepping a value.
    pub fn setting_is_action(i: usize) -> bool {
        i == 6 || i >= 9
    }

    /// The value shown for a row of the settings page.
    pub fn setting_value(&self, i: usize) -> (&'static str, String) {
        let onoff = |b: bool| if b { "on" } else { "off" }.to_string();
        let go = || "↵".to_string();
        match i {
            0 => ("Theme", themes::theme(&self.theme_id).name),
            1 => ("Daily word goal", format!("{} words", self.settings.word_goal())),
            2 => ("Timer", format!("{} minutes", self.settings.timer_minutes())),
            3 => ("Timer chime", onoff(self.settings.ui_bool("chime").unwrap_or(true))),
            4 => ("Mouse", onoff(self.mouse)),
            5 => ("Data Saver", onoff(self.settings.data_saver)),
            6 => ("Backup folder", self.settings.backup_dir.clone().unwrap_or_else(|| "not set".into())),
            7 => ("Automatic backups", match self.settings.interval().as_str() {
                "daily" => "daily (24 hours)", "weekly" => "weekly (7 days)", "monthly" => "monthly (30 days)",
                "change" => "on change (30s idle)", _ => "off",
            }.into()),
            8 => ("Keep backups", format!("{} copies", self.settings.keep())),
            9 => ("Back up now", if self.backup_result.is_some() { "running…".into() } else { self.settings.last_backup.as_ref().map(|t| format!("last {}", &t[..t.len().min(16)])).unwrap_or_else(go) }),
            10 => ("Restore a backup", go()),
            11 => ("Clean up", go()),
            12 => ("Sort inbox", go()),
            13 => ("File all drafts", go()),
            14 => ("Clear orphan media", go()),
            15 => ("Export all", go()),
            16 => ("Merge ex-split", go()),
            17 => ("Compress media", if self.maintenance_running { "running…".into() } else { go() }),
            18 => ("Review tags", go()),
            19 => ("Rename tags", go()),
            20 => ("Import markdown", go()),
            21 => ("Import Day One", go()),
            22 => ("File transfer.md", go()),
            _ => ("Merge conflict copies", go()),
        }
    }

    /// Step row `i` forward (+1) or back (-1); an action row runs on +1.
    fn adjust_setting(&mut self, i: usize, dir: i64) {
        match i {
            0 => {
                let all = themes::themes();
                if all.is_empty() {
                    return;
                }
                let n = all.len() as i64;
                let cur = all.iter().position(|t| t.id == self.theme_id).unwrap_or(0) as i64;
                let t = &all[(cur + dir).rem_euclid(n) as usize];
                self.pal = Palette::from_theme(t, truecolor());
                self.theme_id = t.id.clone();
                let id = t.id.clone();
                self.persist(|s| s.set_ui("theme", serde_json::Value::String(id.clone())));
            }
            1 => {
                let v = (self.settings.word_goal() as i64 + dir * 50).clamp(50, 5000);
                self.persist(|s| s.set_ui("goal", serde_json::Value::from(v)));
            }
            2 => {
                let v = (self.settings.timer_minutes() as i64 + dir * 5).clamp(5, 180);
                self.persist(|s| s.set_ui("timerMins", serde_json::Value::from(v)));
            }
            3 => {
                let on = !self.settings.ui_bool("chime").unwrap_or(true);
                self.persist(|s| s.set_ui("chime", serde_json::Value::Bool(on)));
            }
            4 => self.toggle_mouse(),
            5 => {
                let on = !self.settings.data_saver;
                self.persist(|s| s.data_saver = on);
            }
            7 => {
                let intervals = quire_core::settings::INTERVALS;
                let current = intervals.iter().position(|v| *v == self.settings.interval()).unwrap_or(0) as i64;
                let value = intervals[(current + dir).rem_euclid(intervals.len() as i64) as usize].to_string();
                self.persist(|s| s.backup_interval = Some(value.clone()));
                self.backup_schedule.changed(Instant::now());
            }
            8 => {
                let keep = (self.settings.keep() as i64 + dir).clamp(1, 50) as u32;
                self.persist(|s| s.backup_keep = Some(keep));
            }
            _ if dir < 0 => {}
            6 => {
                let cur = self.settings.backup_dir.clone().unwrap_or_default();
                self.modal = Some(Modal::Input { label: "Backup folder", value: cur, ask: Ask::BackupDir });
            }
            9 => self.run_backup(),
            10 => self.open_restore(),
            11 => self.modal = Some(Modal::Confirm { text: "Standardise punctuation, reorder and dedupe every day file?".into(), action: Confirm::Cleanup }),
            12 => match sort_inbox(&self.j) {
                Ok(true) => {
                    self.reload();
                    self.toast("Inbox sorted by time".into(), false);
                }
                Ok(false) => self.toast("Inbox was already in order".into(), false),
                Err(e) => self.toast(e, true),
            },
            13 => self.modal = Some(Modal::Confirm { text: "File every draft to its day?".into(), action: Confirm::FileAll }),
            14 => self.modal = Some(Modal::Confirm { text: "Delete media no entry links to?".into(), action: Confirm::ClearOrphans }),
            16 => self.modal = Some(Modal::Confirm { text: "Merge journals whose split tags are no longer configured?".into(), action: Confirm::MergeSplits }),
            17 => self.modal = Some(Modal::Confirm { text: "Compress existing media and convert HEIC? Originals are replaced; back up first.".into(), action: Confirm::CompressMedia }),
            18 => {
                let groups = tag_review(&self.j);
                if groups.is_empty() { self.toast("No similar tags found".into(), false); }
                else { self.modal = Some(Modal::Tags(groups, 0)); }
            }
            19 => self.modal = Some(Modal::Input { label: "Rename (old -> new)", value: String::new(), ask: Ask::RenameTag }),
            20 => self.modal = Some(Modal::Input { label: "Markdown folder", value: String::new(), ask: Ask::ImportMarkdown }),
            21 => self.modal = Some(Modal::Input { label: "Day One JSON", value: String::new(), ask: Ask::ImportDayOne }),
            22 => self.modal = Some(Modal::Confirm { text: "File transfer.md into dated entries?".into(), action: Confirm::FileTransfer }),
            23 => self.modal = Some(Modal::Confirm { text: "Merge sync conflict copies, keeping both versions' entries?".into(), action: Confirm::MergeConflicts }),
            _ => {
                let home = dirs::home_dir().unwrap_or_default();
                let dest = home.join(format!("quire-export-{}.md", &now_local()[..10]));
                self.modal = Some(Modal::Input { label: "Export to", value: dest.display().to_string(), ask: Ask::ExportPath });
            }
        }
    }

    fn apply_ask(&mut self, ask: Ask, v: &str) {
        match ask {
            Ask::BackupDir => {
                if v.is_empty() {
                    self.persist(|s| s.backup_dir = None);
                    self.toast("Backup folder cleared".into(), false);
                    return;
                }
                let path = expand_home(v);
                match self.j.local().and_then(|root| check_backup_dir(root, std::path::Path::new(&path))) {
                    Ok(()) => {
                        self.persist(|s| s.backup_dir = Some(path.clone()));
                        self.toast("Backup folder set".into(), false);
                    }
                    Err(e) => self.toast(e, true),
                }
            }
            Ask::RenameTag => {
                let Some((from, to)) = v.split_once("->") else { return self.toast("Use old -> new (several old tags may be separated by spaces)".into(), true); };
                let from: Vec<String> = from.split_whitespace().map(str::to_string).collect();
                let to = to.trim().to_string();
                if from.is_empty() || to.is_empty() { return self.toast("Enter both old and new tags".into(), true); }
                self.modal = Some(Modal::Confirm { text: format!("Rename {} to {} in every entry?", from.join(", "), to), action: Confirm::MergeTags(from, to) });
            }
            Ask::ImportMarkdown | Ask::ImportDayOne => {
                if v.is_empty() { return; }
                let path = expand_home(v);
                let report = if ask == Ask::ImportMarkdown { import_markdown_folder(&self.j, std::path::Path::new(&path), true) }
                    else { import_day_one(&self.j, std::path::Path::new(&path), true) };
                match report {
                    Ok(report) => self.modal = Some(Modal::Confirm { text: format!("Import {} entries ({} already present)?", report.written, report.skipped), action: if ask == Ask::ImportMarkdown { Confirm::ImportMarkdown(path) } else { Confirm::ImportDayOne(path) } }),
                    Err(error) => self.toast(error, true),
                }
            }
            Ask::ExportPath => {
                if v.is_empty() {
                    return;
                }
                match export_all(&self.j, std::path::Path::new(&expand_home(v))) {
                    Ok(n) => self.toast(format!("Exported {} entries", n), false),
                    Err(e) => self.toast(e, true),
                }
            }
        }
    }

    fn backup_dir(&mut self) -> Option<PathBuf> {
        match self.settings.backup_dir.clone() {
            Some(d) => Some(PathBuf::from(d)),
            None => {
                self.toast("Set a backup folder first".into(), true);
                None
            }
        }
    }

    fn run_backup(&mut self) {
        if self.backup_result.is_some() { return self.toast("A backup is already running".into(), false); }
        let Some(dir) = self.backup_dir() else { return };
        let guard = match BackupGuard::acquire() {
            Ok(g) => g,
            Err(e) => { self.backup_schedule.failed(Instant::now()); return self.toast(e, true); }
        };
        let keep = self.settings.keep();
        let journal = self.j.clone();
        let (sender, receiver) = mpsc::channel();
        self.backup_result = Some(receiver);
        self.backup_schedule.started();
        std::thread::spawn(move || {
            let _guard = guard;
            let result = backup(&journal, &dir).and_then(|made| prune_backups(&dir, keep).map(|_| made));
            let _ = sender.send(result);
        });
    }

    fn backup_finished(&mut self, result: Result<String, String>) {
        match result {
            Ok(made) => {
                let now = now_local();
                self.persist(|s| s.last_backup = Some(now.clone()));
                self.toast(format!("Backed up to {}", made), false);
            }
            Err(error) => { self.backup_schedule.failed(Instant::now()); self.toast(error, true); }
        }
    }

    fn poll_backup(&mut self) {
        let result = self.backup_result.as_ref().map(|receiver| receiver.try_recv());
        match result {
            Some(Ok(result)) => { self.backup_result = None; self.backup_finished(result); }
            Some(Err(mpsc::TryRecvError::Disconnected)) => {
                self.backup_result = None;
                self.backup_finished(Err("The backup worker stopped unexpectedly".into()));
            }
            _ => {}
        }
    }

    fn finish_backup(&mut self) {
        if let Some(receiver) = self.backup_result.take() {
            self.backup_finished(receiver.recv().unwrap_or_else(|_| Err("The backup worker stopped unexpectedly".into())));
        }
    }

    fn start_maintenance(&mut self, job: impl FnOnce(Journal) -> Result<String, String> + Send + 'static) {
        if self.maintenance_running || self.backup_result.is_some() { return self.toast("Wait for the current backup or maintenance to finish".into(), true); }
        let guard = match BackupGuard::acquire() { Ok(guard) => guard, Err(error) => return self.toast(error, true) };
        let journal = self.j.clone();
        let (sender, receiver) = mpsc::channel();
        self.maintenance_result = Some(receiver);
        self.maintenance_running = true;
        self.toast("Maintenance running — please leave Quire open".into(), false);
        std::thread::spawn(move || { let _guard = guard; let _ = sender.send(job(journal)); });
    }
    fn maintenance_finished(&mut self, result: Result<String, String>) {
        self.maintenance_running = false;
        self.reload();
        match result { Ok(message) => self.toast(message, false), Err(error) => self.toast(error, true) }
    }
    fn poll_maintenance(&mut self) {
        match self.maintenance_result.as_ref().map(|receiver| receiver.try_recv()) {
            Some(Ok(result)) => { self.maintenance_result = None; self.maintenance_finished(result); }
            Some(Err(mpsc::TryRecvError::Disconnected)) => { self.maintenance_result = None; self.maintenance_finished(Err("Maintenance worker stopped unexpectedly".into())); }
            _ => {}
        }
    }
    fn finish_maintenance(&mut self) {
        if let Some(receiver) = self.maintenance_result.take() {
            self.maintenance_finished(receiver.recv().unwrap_or_else(|_| Err("Maintenance worker stopped unexpectedly".into())));
        }
    }

    fn open_restore(&mut self) {
        let Some(dir) = self.backup_dir() else { return };
        let names = list_backups(&dir);
        if names.is_empty() {
            self.toast("No backups in that folder".into(), true);
        } else {
            self.modal = Some(Modal::Restore(names, 0));
        }
    }

    fn run_restore(&mut self, name: &str) {
        let Some(dir) = self.backup_dir() else { return };
        let _g = match BackupGuard::acquire() {
            Ok(g) => g,
            Err(e) => return self.toast(e, true),
        };
        match restore(&self.j, &dir, name) {
            Ok(safety) => {
                self.draft = None;
                self.reload();
                self.toast(format!("Restored. Previous folder kept as {}", safety), false);
            }
            Err(e) => self.toast(e, true),
        }
    }

    fn run_cleanup(&mut self) {
        match cleanup(&self.j, &self.split_tags) {
            Ok(r) => {
                self.reload();
                let msg = format!("Cleanup: {} moved to their day, {} formatted, {} reordered, {} duplicates removed, {} extracted", r.moved, r.formatted, r.reordered, r.deduped, r.extracted);
                match r.errors.first() {
                    Some(e) => self.toast(format!("{} — {}", msg, e), true),
                    None => self.toast(msg, false),
                }
            }
            Err(e) => self.toast(e, true),
        }
    }

    fn run_file_all(&mut self) {
        match file_all(&self.j, &self.split_tags) {
            Ok(r) => {
                self.reload();
                let skipped = if r.skipped > 0 { format!(", {} empty left", r.skipped) } else { String::new() };
                match r.errors.first() {
                    Some(e) => self.toast(format!("Filed {}{} — {}", r.filed, skipped, e), true),
                    None => self.toast(format!("Filed {} draft(s){}", r.filed, skipped), false),
                }
            }
            Err(e) => self.toast(e, true),
        }
    }

    fn run_clear_orphans(&mut self) {
        match delete_orphans(&self.j) {
            Ok(n) => { self.backup_schedule.changed(Instant::now()); self.toast(format!("Removed {} unlinked file(s)", n), false); }
            Err(e) => self.toast(e, true),
        }
    }

    fn settings_key(&mut self, k: KeyEvent) {
        let last = Self::SETTING_ROWS - 1;
        match k.code {
            KeyCode::Esc | KeyCode::Char('q') => self.back(),
            KeyCode::Up | KeyCode::Char('k') => self.settings_i = self.settings_i.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => self.settings_i = (self.settings_i + 1).min(last),
            KeyCode::Left | KeyCode::Char('h') => self.adjust_setting(self.settings_i, -1),
            KeyCode::Right | KeyCode::Char('l') | KeyCode::Enter | KeyCode::Char(' ') => self.adjust_setting(self.settings_i, 1),
            _ => {}
        }
    }

    fn hit_at(&self, x: u16, y: u16) -> Option<Hit> {
        self.hits.borrow().iter().rev().find(|(r, _)| r.contains(Position::new(x, y))).map(|(_, h)| h.clone())
    }

    /// The rect of the menu-like thing under a cell: hint keys, list rows,
    /// pickers. Not the composer's text or a pane of an entry's text.
    pub fn hit_rect_at(&self, x: u16, y: u16) -> Option<Rect> {
        let hits = self.hits.borrow();
        let (r, h) = hits.iter().rev().find(|(r, _)| r.contains(Position::new(x, y)))?;
        match h {
            // Text you read or write is not a menu.
            Hit::Text(..) | Hit::TextEnd | Hit::Column(_) | Hit::Preview(..) | Hit::Item(3, _) => None,
            _ => Some(*r),
        }
    }

    pub fn handle_mouse(&mut self, m: MouseEvent) {
        if self.maintenance_running { return; }
        match m.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                if self.help {
                    self.help = false;
                    return;
                }
                if let Some(h) = self.hit_at(m.column, m.row) {
                    self.click(h, m.column);
                }
            }
            MouseEventKind::Drag(MouseButton::Left) if self.screen == Screen::Write && self.modal.is_none() => {
                if let Some(h @ Hit::Text(..)) = self.hit_at(m.column, m.row) {
                    self.click(h, m.column);
                }
            }
            MouseEventKind::Moved => self.hover = Some((m.column, m.row)),
            MouseEventKind::ScrollUp => self.wheel(m.column, m.row, KeyCode::Up),
            MouseEventKind::ScrollDown => self.wheel(m.column, m.row, KeyCode::Down),
            _ => {}
        }
    }

    fn entry_at(&self, file: &str, index: usize) -> Option<Entry> {
        self.entries.iter().find(|e| e.file == file && e.index == index).cloned()
    }

    fn click(&mut self, h: Hit, x: u16) {
        match h {
            Hit::Key(k) => self.handle_key(k),
            Hit::Home => {
                if self.screen == Screen::Write {
                    self.leave_write();
                    if self.screen == Screen::Write {
                        return; // the save failed; stay with the draft
                    }
                }
                self.stack.clear();
                self.screen = Screen::Today;
                self.help = false;
            }
            Hit::Edit(f, i) | Hit::Preview(f, i) => {
                if let Some(e) = self.entry_at(&f, i) {
                    self.edit_entry(&e);
                }
            }
            Hit::Show(f, i) => {
                if let Some(e) = self.entry_at(&f, i) {
                    self.goto_entry(&e);
                }
            }
            Hit::Prompt => {
                let p = self.current_prompt();
                self.start_draft("", &format!("> {}\n\n", p));
            }
            Hit::Draft(i) => {
                if self.inbox_i == i {
                    // A second click goes on, as ↵ does.
                    self.handle_key(KeyEvent::from(KeyCode::Enter));
                } else {
                    self.inbox_i = i;
                }
            }
            Hit::Column(c) => self.browse.col = c.min(3),
            Hit::Item(c, i) => {
                let b = &mut self.browse;
                let slot = match c {
                    0 => &mut b.yi,
                    1 => &mut b.mi,
                    2 => &mut b.di,
                    _ => &mut b.ei,
                };
                let again = b.col == c && *slot == i;
                *slot = i;
                b.col = c.min(3);
                if again {
                    // A second click goes on, as ↵ does.
                    self.handle_key(KeyEvent::from(KeyCode::Enter));
                } else {
                    self.after_browse_move();
                }
            }
            Hit::Pick(p) => {
                if self.browse.pick != p {
                    self.browse.pick = p;
                    self.browse.yi = 0;
                    self.browse.mi = 0;
                    self.browse.di = 0;
                    self.browse.ei = 0;
                    self.clamp_browse();
                }
            }
            Hit::Result(i) => {
                if self.search_i == i {
                    self.handle_key(KeyEvent::from(KeyCode::Enter));
                } else {
                    self.search_i = i;
                }
            }
            Hit::Year(y) => self.year = y,
            Hit::Setting(i) => {
                self.settings_i = i;
                self.adjust_setting(i, 1);
            }
            Hit::Text(vr, left, last) => {
                if let Some(d) = self.draft.as_mut() {
                    d.ed.place(vr, x.saturating_sub(left) as usize, last);
                    self.tag_pick = 0;
                }
            }
            Hit::TextEnd => {
                if let Some(d) = self.draft.as_mut() {
                    d.ed.to_end();
                }
            }
            Hit::Suggestion(i) => {
                let suggestions = self.tag_suggestions();
                if let (Some(t), Some(d)) = (suggestions.get(i), self.draft.as_mut()) {
                    d.ed.accept_tag(t);
                    self.tag_pick = 0;
                }
            }
        }
    }

    /// The wheel moves what is under it, three rows at a time in the composer.
    fn wheel(&mut self, x: u16, y: u16, code: KeyCode) {
        if self.help || self.modal.is_some() {
            return;
        }
        let key = KeyEvent::from(code);
        match self.screen {
            Screen::Browse => {
                let col = self.hits.borrow().iter().rev().find_map(|(r, h)| match h {
                    Hit::Column(c) if r.contains(Position::new(x, y)) => Some(*c),
                    _ => None,
                });
                if let Some(c) = col {
                    self.browse.col = c;
                }
                self.handle_key(key);
            }
            Screen::Write => {
                for _ in 0..3 {
                    self.handle_key(key);
                }
            }
            Screen::Inbox | Screen::Search => self.handle_key(key),
            _ => {}
        }
    }

    // ----- paste and attachments -----

    /// A bracketed paste: text into whatever is taking it; in the composer,
    /// dropped media files become attachments.
    pub fn handle_paste(&mut self, s: String) {
        self.help = false;
        let s = s.replace("\r\n", "\n").replace('\r', "\n");
        let line = s.split_whitespace().collect::<Vec<_>>().join(" ");
        match self.modal.as_mut() {
            Some(Modal::Retime(v)) => {
                for c in line.chars().filter(|c| c.is_ascii_digit() || matches!(c, '-' | ':' | ' ')) {
                    if v.len() < 19 {
                        v.push(c);
                    }
                }
                return;
            }
            Some(Modal::Input { value, .. }) => {
                value.push_str(s.trim().lines().next().unwrap_or(""));
                return;
            }
            Some(_) => return,
            None => {}
        }
        match self.screen {
            Screen::Write => self.paste_text(&s),
            Screen::Search => {
                self.query.push_str(&line);
                self.search_i = 0;
            }
            Screen::Browse if self.browse.filtering => {
                self.browse.filter.push_str(&line);
                self.clamp_browse();
            }
            _ => {}
        }
    }

    fn paste_text(&mut self, s: &str) {
        if let Some(paths) = paste::dropped_paths(s) {
            self.attach_to_draft(paths.into_iter().map(Attachment::Path).collect());
            return;
        }
        let Some(d) = self.draft.as_mut() else { return };
        if d.floating {
            d.ts = now_local();
            d.floating = false;
        }
        d.ed.insert_str(s);
        self.tag_pick = 0;
    }

    /// ^V in the composer: an image on the clipboard is attached; text is
    /// pasted (or attached, if it names media files).
    fn paste_clipboard(&mut self) {
        match paste::read_clipboard() {
            Ok(Clip::Image(bytes, ext)) => self.attach_to_draft(vec![Attachment::Bytes(bytes, ext)]),
            Ok(Clip::Text(t)) => self.paste_text(&t.replace("\r\n", "\n")),
            Ok(Clip::Empty) => self.toast("Nothing on the clipboard".into(), false),
            Err(e) => self.toast(e, true),
        }
    }

    /// Copy into assets/ (Data Saver applied, as in the desktop app) and put
    /// each link in the body.
    fn attach_to_draft(&mut self, items: Vec<Attachment>) {
        let Some(d) = self.draft.as_mut() else { return };
        if d.floating {
            d.ts = now_local();
            d.floating = false;
        }
        let ts = d.ts.clone();
        // Fresh from disk: Data Saver is switched in the desktop app.
        let mut s = Settings::load();
        let device = if s.data_saver {
            let (id, new) = s.ensure_device_id();
            if new {
                let _ = s.save();
            }
            id
        } else {
            String::new()
        };
        let n = items.len();
        for it in items {
            let res = match it {
                Attachment::Path(p) => attach_media(&self.j, &p, &ts, s.data_saver, &device),
                Attachment::Bytes(b, ext) => attach_bytes(&self.j, &b, ext, &ts, s.data_saver, &device),
            };
            match res {
                Ok(a) => {
                    if a.compress_later {
                        if let Ok(root) = self.j.local() {
                            compress_in_background(root.to_path_buf(), a.rel.clone(), device.clone());
                        }
                    }
                    if let Some(d) = self.draft.as_mut() {
                        d.ed.insert_block(&a.link);
                    }
                }
                Err(e) => {
                    self.toast(e, true);
                    return;
                }
            }
        }
        self.toast(if n == 1 { "Attached".into() } else { format!("Attached {}", n) }, false);
    }
}

/// Data Saver for video and audio: ffmpeg in the background, one at a time.
fn compress_in_background(root: PathBuf, rel: String, device: String) {
    std::thread::spawn(move || {
        static QUEUE: Mutex<()> = Mutex::new(());
        let _g = QUEUE.lock().unwrap_or_else(|p| p.into_inner());
        let path = root.join(&rel);
        if let Ok(res) = media::compress_file_in_place(&path) {
            media::record_saving(&root, &device, &path, res.unwrap_or(0));
        }
    });
}

fn set_mouse(on: bool) -> std::io::Result<()> {
    use crossterm::event::{DisableMouseCapture, EnableMouseCapture};
    if on {
        crossterm::execute!(std::io::stdout(), EnableMouseCapture)
    } else {
        crossterm::execute!(std::io::stdout(), DisableMouseCapture)
    }
}

pub fn run(mut app: App) -> std::io::Result<()> {
    use crossterm::event::{DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste};
    let mut terminal = ratatui::init();
    // ratatui's panic hook restores the screen; this one first gives the
    // terminal back its mouse and plain paste.
    let restore_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = crossterm::execute!(std::io::stdout(), DisableMouseCapture, DisableBracketedPaste);
        restore_hook(info);
    }));
    crossterm::execute!(std::io::stdout(), EnableBracketedPaste)?;
    let mut mouse_on = false;
    let result = (|| -> std::io::Result<()> {
        let mut redraw = true;
        loop {
            if app.mouse != mouse_on {
                set_mouse(app.mouse)?;
                mouse_on = app.mouse;
            }
            if redraw {
                let size = terminal.size()?;
                app.width = size.width;
                app.height = size.height;
                terminal.draw(|f| crate::ui::draw(f, &mut app))?;
            }
            redraw = true;
            if event::poll(Duration::from_millis(200))? {
                match event::read()? {
                    Event::Key(k) => app.handle_key(k),
                    Event::Paste(s) => app.handle_paste(s),
                    // Bare movement only matters if it lands on something else clickable.
                    Event::Mouse(m) if m.kind == MouseEventKind::Moved => {
                        let before = app.hover.and_then(|(x, y)| app.hit_rect_at(x, y));
                        app.handle_mouse(m);
                        redraw = before != app.hit_rect_at(m.column, m.row);
                    }
                    Event::Mouse(m) => app.handle_mouse(m),
                    Event::Resize(w, h) => {
                        app.width = w;
                        app.height = h;
                    }
                    _ => {}
                }
            }
            app.tick();
            if app.quit {
                app.finish_maintenance();
                if app.draft.is_some() {
                    if let Err(e) = app.save_draft() {
                        eprintln!("  {}", e);
                    }
                }
                break;
            }
        }
        Ok(())
    })();
    app.finish_maintenance();
    app.finish_backup();
    let _ = crossterm::execute!(std::io::stdout(), DisableMouseCapture, DisableBracketedPaste);
    ratatui::restore();
    result
}
