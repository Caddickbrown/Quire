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
use std::collections::{BTreeMap, VecDeque};
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
    /// The column and the place (year, month, day, entry) when `/` was
    /// pressed: what Esc goes back to, since each letter typed moves the
    /// selection.
    pub before_filter: Option<(usize, usize, usize, usize, usize)>,
}

impl Default for Browse {
    fn default() -> Self {
        Browse { pick: Pick::Main, col: 2, yi: 0, mi: 0, di: 0, ei: 0, filter: String::new(), filtering: false, before_filter: None }
    }
}

/// Where an entry is on disk and the text it had there: what every edit of
/// it presents, so the core acts on that entry or refuses.
pub type EntryRef = (String, usize, String);

/// An entry as it stood when the composer opened it: what ^D puts back.
#[derive(Clone)]
pub struct Opened {
    pub raw: String,
    pub ts: String,
    pub title: String,
    pub starred: bool,
    pub body: String,
}

pub struct Draft {
    pub ed: Editor,
    pub ts: String,
    pub starred: bool,
    /// (file, index, raw) once it is on disk.
    pub ref_: Option<EntryRef>,
    /// Editing something already filed (or in a split journal).
    pub filed: bool,
    pub saved_at: Option<String>,
    /// A brand-new draft keeps its timestamp "now" until the first keystroke.
    pub floating: bool,
    /// Set for an entry that was already on disk when it was opened; `None`
    /// for a draft started in this session, the only kind ^D deletes.
    pub opened: Option<Opened>,
    /// Why the last save was refused, until one works.
    pub save_error: Option<String>,
}

/// The entry a question is about: its reference, and a name to ask with.
#[derive(Clone, PartialEq, Eq)]
pub struct Target {
    pub at: EntryRef,
    pub name: String,
}

#[derive(Clone, PartialEq, Eq)]
pub enum Confirm {
    /// Delete this entry: the one that was selected when the question was
    /// asked, whatever is selected when it is answered.
    DeleteSelected(EntryRef),
    /// Delete the draft started in this session.
    DiscardDraft,
    /// Put an existing entry back as it was when the composer opened it.
    RestoreDraft,
    /// Leaving an existing entry with nothing left in it: delete it.
    DeleteEmptied,
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
    /// The typed date and time, and the entry it is for (`None`: the
    /// composer's own draft).
    Retime(String, Option<Target>),
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
    /// Show this entry in Browse.
    Show(String, usize),
    /// Today's prompt: start writing from it.
    Prompt,
    /// The QUIRE mark: back to Today.
    Home,
    /// A row of the inbox's draft list.
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
    pub inbox: Browse,
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
    /// `None` until the folder has been read once: the first reading is where
    /// things stand, not a change to back up.
    fingerprint: Option<u64>,
    /// The last strict load's failure, so it is said once and not every check.
    load_error: Option<String>,
    pub maintenance_running: bool,
    maintenance_result: Option<mpsc::Receiver<Result<String, String>>>,
    backup_schedule: crate::backup::Schedule,
    backup_result: Option<mpsc::Receiver<BackupDone>>,
    /// Why the last backup left every older one in place, for Settings.
    backup_note: Option<String>,
    /// This folder is not the settings' own journal: its backups go in a
    /// folder of their own (`backup_dir_for`) and its last backup is recorded
    /// under its own key, so two journals never prune each other's.
    pub keyed_backups: bool,
    /// Things to say that came before there was a window, or while another
    /// toast was up: shown one after another.
    notices: VecDeque<(String, bool)>,
    /// A quit was refused because the composer couldn't be saved; the next
    /// Ctrl-C goes anyway.
    quit_refused: bool,
    force_quit: bool,
    /// The user moved the tag popover's selection, so ↵ and ↹ take it even
    /// when what is typed is already a tag.
    tag_moved: bool,
    /// Said on the terminal after the screen is given back.
    exit_notes: Vec<String>,
}

/// A finished backup: where it is, and what pruning did after it.
type BackupDone = Result<(String, Result<Pruned, String>), String>;

/// A staged restore this old belongs to no restore still running.
const RESTORE_LEFTOVER_AGE: Duration = Duration::from_secs(3600);
/// Where the last backup of each journal other than the settings' own is
/// kept in settings.json: `{ "<journal key>": "YYYY-MM-DD HH:MM:SS" }`.
const LAST_BACKUPS: &str = "last_backups";
/// Search lists the newest this many matches; the count above it is of them all.
pub const RESULTS_LISTED: usize = 300;
/// The composer needs a title row, a text row and its status lines.
pub const COMPOSER_MIN_ROWS: u16 = 9;
pub const COMPOSER_MIN_COLS: u16 = 30;

/// A day as the DAY column shows it, "Wed 04": what is drawn and what the
/// column's filter matches are the same text.
pub fn day_label(date: &str) -> String {
    stats::parse_date(date).map(|d| d.format("%a %d").to_string()).unwrap_or_else(|| date.to_string())
}

/// The noun for a count: `noun(1, "entry", "entries")` is "entry".
pub fn noun(n: usize, one: &'static str, many: &'static str) -> &'static str {
    if n == 1 {
        one
    } else {
        many
    }
}

/// The date, time and title of an entry, to ask about it by name.
pub fn entry_name(e: &Entry) -> String {
    let title = if e.title.trim().is_empty() {
        unguard_body(&e.body).lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim().to_string()
    } else {
        e.title.trim().to_string()
    };
    let short: String = if title.chars().count() > 24 { title.chars().take(23).chain(std::iter::once('…')).collect() } else { title };
    let when = format!("{} {}", e.date, e.ts.get(11..16).unwrap_or(&e.time));
    if short.is_empty() { format!("{} (untitled)", when) } else { format!("{} “{}”", when, short) }
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
            inbox: Browse::default(),
            browse: Browse::default(),
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
            fingerprint: None,
            load_error: None,
            maintenance_running: false,
            maintenance_result: None,
            backup_schedule: crate::backup::Schedule::default(),
            backup_result: None,
            backup_note: None,
            keyed_backups: false,
            notices: VecDeque::new(),
            quit_refused: false,
            force_quit: false,
            tag_moved: false,
            exit_notes: Vec::new(),
        };
        a.reload();
        a
    }

    /// Read the journal again. Strictly: a folder that can't be listed or a
    /// file that can't be read keeps what was shown before and says so,
    /// rather than drawing a shorter journal as if it were the whole one.
    pub fn reload(&mut self) {
        match self.j.try_load_all() {
            Ok(entries) => {
                self.entries = entries;
                self.load_error = None;
            }
            Err(e) => {
                if self.load_error.as_deref() != Some(e.as_str()) {
                    self.toast(format!("Can't read the whole journal: {}", e), true);
                }
                self.load_error = Some(e);
            }
        }
        let fingerprint = self.fingerprint_now();
        if self.fingerprint.is_some_and(|was| was != fingerprint) {
            self.backup_schedule.changed(Instant::now());
        }
        self.fingerprint = Some(fingerprint);
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

    /// Say this when the toast is free: now, or after the one that is up.
    pub fn notice(&mut self, msg: String, error: bool) {
        self.notices.push_back((msg, error));
    }

    /// What an interrupted restore left in the journal folder: staged copies
    /// are swept by the core; folders of what the journal held before are
    /// only ever reported.
    pub fn report_restore_leftovers(&mut self) {
        let Ok(root) = self.j.local() else { return };
        let left = restore_leftovers(root, RESTORE_LEFTOVER_AGE);
        if left.old.is_empty() {
            return;
        }
        self.notice("A restore was cut short. What the journal held before it is still in its folder:".into(), true);
        self.notice(format!("{} — nothing was removed; look inside before you delete it", left.old.join(", ")), true);
    }

    /// The Inbox and the Journal draw the entries beside the columns only
    /// when there is room.
    pub fn browse_wide(&self) -> bool {
        self.width.saturating_sub(4) >= 96
    }

    /// Is the entry that `f`, `u` and `*` would act on marked on screen?
    fn entry_marked(&self) -> bool {
        self.nav().col == 3 || (self.browse_wide() && self.screen == Screen::Inbox)
    }

    /// Entry keys act on the marked entry. When none is marked (the entries
    /// are a column away, or not drawn at all in a narrow window), the key
    /// goes to the entries instead. True when the entry is marked.
    fn at_entries(&mut self) -> bool {
        if self.entry_marked() {
            return true;
        }
        if let Some(e) = self.browse_sel().entry {
            self.nav_mut().col = 3;
            self.toast(format!("On {} — press again to act on it", entry_name(&e)), false);
        }
        false
    }

    pub fn composer_fits(&self) -> bool {
        self.height >= COMPOSER_MIN_ROWS && self.width >= COMPOSER_MIN_COLS
    }

    fn push(&mut self, s: Screen) {
        if self.screen != s {
            self.stack.push(self.screen);
            self.screen = s;
            self.clamp_browse();
        }
        self.help = false;
    }

    fn back(&mut self) {
        self.screen = self.stack.pop().unwrap_or(Screen::Today);
        self.clamp_browse();
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

    /// The Inbox and the Journal are the same year, month, day and entries
    /// columns over different entries, each keeping its own place.
    pub fn nav(&self) -> &Browse {
        if self.screen == Screen::Inbox { &self.inbox } else { &self.browse }
    }

    fn nav_mut(&mut self) -> &mut Browse {
        if self.screen == Screen::Inbox { &mut self.inbox } else { &mut self.browse }
    }

    pub fn browse_pool(&self) -> Vec<&Entry> {
        let (inbox, pick) = (self.screen == Screen::Inbox, &self.browse.pick);
        self.entries
            .iter()
            .filter(|e| match pick {
                _ if inbox => e.source == "inbox",
                Pick::Main => e.source == "journal",
                Pick::All => true,
                Pick::Split(t) => e.split.as_deref() == Some(t.as_str()),
            })
            .collect()
    }

    fn filtered(&self, items: Vec<(String, usize)>, label: impl Fn(&str) -> String) -> Vec<(String, usize)> {
        if !self.nav().filtering || self.nav().filter.is_empty() {
            return items;
        }
        // By what the column shows as well as its key, a word at a time and
        // with or without a leading zero: "wed" and "4" both find "Wed 04",
        // "5" finds May.
        let f = self.nav().filter.to_lowercase();
        let hit = |s: String| s.split_whitespace().any(|w| w.starts_with(&f) || w.trim_start_matches('0').starts_with(&f));
        items.into_iter().filter(|(k, _)| hit(k.to_lowercase()) || hit(label(k).to_lowercase())).collect()
    }

    /// Years, newest first, with entry counts.
    pub fn browse_years(&self) -> Vec<(String, usize)> {
        let mut m: BTreeMap<String, usize> = BTreeMap::new();
        for e in self.browse_pool() {
            *m.entry(e.date[..4].to_string()).or_default() += 1;
        }
        let v: Vec<(String, usize)> = m.into_iter().rev().collect();
        if self.nav().col == 0 {
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
        if self.nav().col == 1 {
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
        if self.nav().col == 2 {
            self.filtered(v, day_label)
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
        let year = years.get(self.nav().yi).map(|y| y.0.clone());
        let months = year.as_deref().map(|y| self.browse_months(y)).unwrap_or_default();
        let month = months.get(self.nav().mi).map(|m| m.0.clone());
        let days = match (&year, &month) {
            (Some(y), Some(m)) => self.browse_days(y, m),
            _ => vec![],
        };
        let date = days.get(self.nav().di).map(|d| d.0.clone());
        let entry = date.as_deref().and_then(|d| self.browse_day_entries(d).get(self.nav().ei).map(|e| (*e).clone()));
        Sel { year, month, date, entry }
    }

    fn clamp_browse(&mut self) {
        let years = self.browse_years();
        self.nav_mut().yi = years.len().saturating_sub(1).min(self.nav().yi);
        let Some(y) = years.get(self.nav().yi).map(|y| y.0.clone()) else {
            self.nav_mut().mi = 0;
            self.nav_mut().di = 0;
            self.nav_mut().ei = 0;
            return;
        };
        let months = self.browse_months(&y);
        self.nav_mut().mi = months.len().saturating_sub(1).min(self.nav().mi);
        let Some(m) = months.get(self.nav().mi).map(|m| m.0.clone()) else { return };
        let days = self.browse_days(&y, &m);
        self.nav_mut().di = days.len().saturating_sub(1).min(self.nav().di);
        let Some(d) = days.get(self.nav().di).map(|d| d.0.clone()) else { return };
        let n = self.browse_day_entries(&d).len();
        self.nav_mut().ei = n.saturating_sub(1).min(self.nav().ei);
    }

    pub fn results(&self) -> Vec<&Entry> {
        let q = Query::parse(&self.query);
        if q.is_empty() {
            return vec![];
        }
        let mut v: Vec<&Entry> = self.entries.iter().filter(|e| q.matches(e)).collect();
        v.sort_by(|a, b| b.ts.cmp(&a.ts));
        v.truncate(RESULTS_LISTED);
        v
    }

    /// How many entries match the query, however many of them are listed.
    pub fn result_count(&self) -> usize {
        let q = Query::parse(&self.query);
        if q.is_empty() {
            return 0;
        }
        self.entries.iter().filter(|e| q.matches(e)).count()
    }

    /// Matching tags for the `@word` under the caret, most used first.
    pub fn tag_suggestions(&self) -> Vec<String> {
        let Some(d) = &self.draft else { return vec![] };
        let Some((_, prefix)) = d.ed.tag_prefix() else { return vec![] };
        let p = prefix.to_lowercase();
        let want = format!("@{}", p);
        self.known_tags().into_iter().filter(|(t, _)| t.to_lowercase().starts_with(&want) && t.to_lowercase() != want).map(|(t, _)| t).take(5).collect()
    }

    /// The tags of every entry but the one in the composer. That one's own
    /// text is saved as it is typed, so the half-typed `@gar` is on disk a
    /// moment later: counted, it would be offered back as a tag, and would
    /// pass for one already complete.
    fn known_tags(&self) -> Vec<(String, usize)> {
        stats::count_tags(self.entries.iter().filter(|e| !self.is_draft_ref(e)))
    }

    /// Will ↵ or ↹ take the popover's tag? Not when what is typed is already
    /// a tag in its own right (`@run`, with `@running` on offer), unless the
    /// selection was moved to say so.
    pub fn tag_accepts(&self) -> bool {
        if self.tag_moved {
            return true;
        }
        let Some((_, prefix)) = self.draft.as_ref().and_then(|d| d.ed.tag_prefix()) else { return false };
        let want = format!("@{}", prefix.to_lowercase());
        !self.known_tags().iter().any(|(t, _)| t.to_lowercase() == want)
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
        self.draft = Some(Draft { ed, ts: now_local(), starred: false, ref_: None, filed: false, saved_at: None, floating: empty, opened: None, save_error: None });
        self.focus = false;
        self.tag_pick = 0;
        self.tag_moved = false;
        self.push(Screen::Write);
    }

    /// A draft whose title was typed on the command line (`quire new Call the
    /// dentist`). The title is the writer's own text, so it counts as unsaved
    /// from the start: leaving, ^s and ^j keep it even if nothing more is
    /// typed. (Today's prompt draft is Quire's text, and stays unwritten until
    /// something is added to it.)
    pub fn start_titled_draft(&mut self, title: &str) {
        self.start_draft(title, "");
        if let Some(d) = self.draft.as_mut().filter(|d| !d.ed.is_empty()) {
            d.ed.dirty = true;
        }
    }

    pub fn edit_entry(&mut self, e: &Entry) {
        // As written, not as stored: a body line that looks like a header is
        // kept with a backslash on disk, and the save puts it back.
        let body = unguard_body(&e.body);
        let mut ed = Editor::new(&e.title, &body);
        ed.to_end();
        self.draft = Some(Draft {
            ed,
            ts: e.ts.clone(),
            starred: e.starred,
            ref_: Some((e.file.clone(), e.index, e.raw.clone())),
            filed: e.source != "inbox",
            saved_at: None,
            floating: false,
            opened: Some(Opened { raw: e.raw.clone(), ts: e.ts.clone(), title: e.title.clone(), starred: e.starred, body }),
            save_error: None,
        });
        self.focus = false;
        self.tag_pick = 0;
        self.tag_moved = false;
        self.push(Screen::Write);
    }

    /// Write the composer to disk if anything changed. Ok(true) when it did.
    /// A composer with nothing in it is never written: for a new draft there
    /// is nothing to keep, and for an entry already on disk it would leave a
    /// bare `[timestamp]` behind (leaving asks what to do with it instead).
    pub fn save_draft(&mut self) -> Result<bool, String> {
        let Some(d) = self.draft.as_mut() else { return Ok(false) };
        if !d.ed.dirty {
            return Ok(false);
        }
        let (title, body) = (d.ed.title(), d.ed.body());
        if title.trim().is_empty() && body.trim().is_empty() {
            return Ok(false);
        }
        let written = match &d.ref_ {
            None => self.j.new_draft(&d.ts, &title, d.starred, &body),
            Some((f, i, raw)) => self.j.update_entry(f, *i, raw, &d.ts, &title, d.starred, &body),
        };
        let w = match written {
            Ok(w) => w,
            Err(e) => {
                d.save_error = Some(e.clone());
                return Err(e);
            }
        };
        d.ref_ = Some((w.file, w.index, w.raw));
        d.ed.dirty = false;
        d.save_error = None;
        d.saved_at = Some(stats::now_time());
        self.reload();
        Ok(true)
    }

    /// A refused save, said with the way out when there is one.
    fn save_refused(&mut self, e: String) {
        let on_disk = self.draft.as_ref().is_some_and(|d| d.ref_.is_some());
        self.toast(if on_disk { format!("Not saved. ^k keeps yours as a new draft. ({})", e) } else { format!("Not saved: {}", e) }, true);
    }

    /// ^K after a refused save: the composer's text becomes a new draft of
    /// its own in the inbox, and the entry on disk is left as it is. The
    /// composer carries on with the new draft.
    fn keep_as_new_draft(&mut self) {
        let Some(d) = self.draft.as_mut() else { return };
        if d.save_error.is_none() || d.ref_.is_none() {
            return self.toast("^k is for a save that was refused: it keeps your text as a new draft".into(), false);
        }
        let ts = if check_ts(&d.ts).is_ok() { d.ts.clone() } else { now_local() };
        match self.j.new_draft(&ts, &d.ed.title(), d.starred, &d.ed.body()) {
            Ok(w) => {
                let file = w.file.clone();
                d.ts = ts;
                d.ref_ = Some((w.file, w.index, w.raw));
                d.filed = false;
                d.opened = None;
                d.ed.dirty = false;
                d.save_error = None;
                d.saved_at = Some(stats::now_time());
                self.quit_refused = false;
                self.reload();
                self.toast(format!("Yours is now a new draft in {}; the other entry is as it was", file), false);
            }
            Err(e) => self.toast(e, true),
        }
    }

    /// The composer's text as a new draft of its own, when it could not be
    /// saved where it belongs and Quire is closing anyway. If even that
    /// fails, the text is kept to print once the terminal is given back.
    fn rescue_draft(&mut self, why: &str) {
        let Some(d) = self.draft.as_ref() else { return };
        let (title, body) = (d.ed.title(), d.ed.body());
        if title.trim().is_empty() && body.trim().is_empty() {
            return;
        }
        let ts = if check_ts(&d.ts).is_ok() { d.ts.clone() } else { now_local() };
        match self.j.new_draft(&ts, &title, d.starred, &body) {
            Ok(w) => self.exit_notes.push(format!("  Quire couldn't save what you were writing ({}).\n  It is kept as a new draft in {}.", why, w.file)),
            Err(e) => {
                let text = if title.trim().is_empty() { body } else { format!("{}\n\n{}", title.trim(), body) };
                self.exit_notes.push(format!(
                    "  Quire couldn't save what you were writing ({}),\n  nor a recovery copy ({}). Here it is:\n\n{}\n",
                    why, e, text
                ));
            }
        }
    }

    /// Ctrl-C with the composer open. True when Quire may close: the text is
    /// saved, or this is the second ask and a recovery copy has been tried.
    /// A first failure cancels the quit and says why.
    fn settle_for_quit(&mut self) -> bool {
        if self.draft.is_none() {
            return true;
        }
        match self.save_draft() {
            Ok(_) => true,
            Err(e) if self.force_quit => {
                self.rescue_draft(&e);
                true
            }
            Err(e) => {
                self.quit = false;
                self.quit_refused = true;
                self.toast(format!("Not saved, so Quire is still open. ^c again quits and keeps your text as a new draft. ({})", e), true);
                false
            }
        }
    }

    /// The loop stopped on an error: save what is in the composer, or keep it
    /// as a recovery copy.
    fn rescue_on_error(&mut self) {
        if self.draft.is_some() {
            if let Err(e) = self.save_draft() {
                self.rescue_draft(&e);
            }
        }
    }

    fn leave_write(&mut self) {
        // Everything was deleted from something that is on disk.
        if let Some(d) = self.draft.as_ref().filter(|d| d.ed.dirty && d.ed.is_empty()) {
            match (&d.ref_, &d.opened) {
                (Some(_), Some(_)) => {
                    self.modal = Some(Modal::Confirm { text: "This entry is empty now. Delete it? (^d puts it back)".into(), action: Confirm::DeleteEmptied });
                    return;
                }
                (Some((f, i, raw)), None) => {
                    // A draft from this session, emptied: there is nothing to keep.
                    return match self.j.delete_entry(f, *i, raw) {
                        Ok(()) => {
                            self.close_composer();
                            self.toast("Empty draft removed".into(), false);
                        }
                        Err(e) => self.toast(e, true),
                    };
                }
                _ => {}
            }
        }
        match self.save_draft() {
            Ok(_) => {
                self.draft = None;
                self.focus = false;
                self.back();
            }
            Err(e) => self.save_refused(e),
        }
    }

    /// Drop the composer and show what is on disk now.
    fn close_composer(&mut self) {
        self.draft = None;
        self.focus = false;
        self.reload();
        self.back();
    }

    /// ^D. A draft started in this session can be deleted; an entry that was
    /// already there goes back to how it was when it was opened.
    fn ask_discard(&mut self) {
        let Some(d) = self.draft.as_ref() else { return };
        match (&d.ref_, &d.opened) {
            (None, _) if d.ed.is_empty() => {
                self.draft = None;
                self.focus = false;
                self.back();
            }
            (Some((_, _, raw)), Some(o)) if !d.ed.dirty && *raw == o.raw => {
                self.draft = None;
                self.focus = false;
                self.back();
                self.toast("Nothing had changed".into(), false);
            }
            (Some(_), Some(_)) => {
                self.modal = Some(Modal::Confirm { text: "Undo this visit's changes? The entry goes back as it was.".into(), action: Confirm::RestoreDraft });
            }
            _ => {
                self.modal = Some(Modal::Confirm { text: "Delete this new draft? Nothing of it is kept.".into(), action: Confirm::DiscardDraft });
            }
        }
    }

    /// The answer to ^D's question, and to leaving an emptied entry.
    fn discard(&mut self, action: Confirm) {
        let Some(d) = self.draft.as_ref() else { return };
        let (done, said) = match (action, &d.ref_, &d.opened) {
            (Confirm::RestoreDraft, Some((f, i, raw)), Some(o)) => {
                // Nothing was written this time: the entry is already as it was.
                let put_back = if *raw == o.raw { Ok(()) } else { self.j.update_entry(f, *i, raw, &o.ts, &o.title, o.starred, &o.body).map(|_| ()) };
                (put_back.map_err(|e| format!("Couldn't put it back: {}", e)), "Changes undone: the entry is as it was when you opened it")
            }
            (Confirm::DeleteEmptied, Some((f, i, raw)), _) => (self.j.delete_entry(f, *i, raw), "Deleted"),
            (Confirm::DiscardDraft, Some((f, i, raw)), None) => (self.j.delete_entry(f, *i, raw), "Draft deleted"),
            (Confirm::DiscardDraft, None, _) => (Ok(()), "Draft deleted"),
            _ => return,
        };
        match done {
            Ok(()) => {
                self.close_composer();
                self.toast(said.into(), false);
            }
            // Still in the composer, with the text.
            Err(e) => self.toast(e, true),
        }
    }

    fn file_from_write(&mut self) {
        if let Err(e) = self.save_draft() {
            self.save_refused(e);
            return;
        }
        let Some(d) = &self.draft else { return };
        if d.filed {
            self.toast("Already filed — Esc to leave it".into(), false);
            return;
        }
        if d.ed.is_empty() {
            self.toast("Nothing to file".into(), false);
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
        let Some(e) = self.selected_entry() else { return };
        match self.j.file_draft(&e.file, e.index, &e.raw, &self.split_tags) {
            Ok(dest) => {
                self.reload();
                self.toast(format!("Filed to {}", dest), false);
            }
            Err(err) => self.toast(err, true),
        }
    }

    fn toggle_star_selected(&mut self) {
        let Some(e) = self.selected_entry() else { return };
        match self.j.update_entry(&e.file, e.index, &e.raw, &e.ts, &e.title, !e.starred, &e.body) {
            Ok(_) => self.reload(),
            Err(err) => self.toast(err, true),
        }
    }

    fn selected_entry(&self) -> Option<Entry> {
        match self.screen {
            Screen::Inbox | Screen::Browse => self.browse_sel().entry,
            Screen::Search => self.results().get(self.search_i).map(|e| (*e).clone()),
            _ => None,
        }
    }

    /// Delete the entry the question was asked about.
    fn delete_at(&mut self, at: &EntryRef) {
        match self.j.delete_entry(&at.0, at.1, &at.2) {
            Ok(()) => {
                self.reload();
                self.toast("Deleted".into(), false);
            }
            Err(err) => {
                self.reload();
                self.toast(err, true);
            }
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

    /// Apply a typed date and time to `target`, or to the composer's draft.
    /// False when the value is not a real date and time: the prompt stays.
    fn apply_retime(&mut self, value: &str, target: Option<&Target>) -> bool {
        let v = value.trim();
        // The time it has now. The prompt shows it to the minute, so a value
        // still in that minute keeps the seconds it had: ↵ on an untouched
        // prompt must not rewrite 10:15:42 as 10:15:00 (which could also
        // reorder two entries from the same minute).
        let was: Option<String> = match target {
            Some(t) => parse_entries(&t.at.2).into_iter().next().map(|r| r.ts),
            None => self.draft.as_ref().map(|d| d.ts.clone()),
        };
        let ts = match &was {
            Some(w) if v.len() == 16 && w.get(..16) == Some(v) => w.clone(),
            _ if v.len() == 16 => format!("{}:00", v),
            _ => v.to_string(),
        };
        if check_ts_shape(&ts).is_err() {
            self.toast("Use YYYY-MM-DD HH:MM".into(), true);
            return false;
        }
        if check_ts(&ts).is_err() {
            self.toast(format!("{} is not a real date and time", v), true);
            return false;
        }
        let Some(target) = target else {
            if let Some(d) = self.draft.as_mut() {
                d.ts = ts;
                d.floating = false;
                d.ed.dirty = true;
            }
            if let Err(e) = self.save_draft() {
                self.save_refused(e);
            }
            return true;
        };
        // The entry the prompt was opened for, from its own text: whatever is
        // selected now, and whatever a reload has done to the list.
        let (f, i, raw) = &target.at;
        let Some(r) = parse_entries(raw).into_iter().next() else { return true };
        if r.ts == ts {
            return true; // the time it already has: nothing to move
        }
        match self.j.update_entry(f, *i, raw, &ts, &strip_star(&r.suffix), has_star(&r.suffix), &r.body) {
            Ok(w) => {
                self.reload();
                self.toast(format!("Moved to {}", w.file), false);
            }
            Err(err) => {
                self.reload();
                self.toast(err, true);
            }
        }
        true
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
        self.push(Screen::Browse);
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
        // A copy taken while words are still landing is a copy of half a
        // sentence, and its own write would start the next one: wait until
        // the composer is saved and has been still for a while.
        let writing = self.draft.as_ref().is_some_and(|d| d.ed.dirty || d.ed.last_edit.elapsed() < crate::backup::QUIET);
        if !self.maintenance_running && self.backup_result.is_none() && !self.quit && !writing && self.backup_schedule.due(&self.settings, self.last_backup().as_deref(), Instant::now()) {
            self.run_backup();
        }
        if let Some((_, at, err)) = &self.toast {
            if at.elapsed() > Duration::from_millis(if *err { 5000 } else { 3000 }) {
                self.toast = None;
            }
        }
        if self.toast.is_none() {
            if let Some((msg, error)) = self.notices.pop_front() {
                self.toast(msg, error);
            }
        }
        // Midnight passes in the composer too: the word count and the goal
        // are today's.
        let today = stats::today();
        if today != self.today {
            self.today = today;
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
                self.save_refused(e);
                if let Some(d) = self.draft.as_mut() {
                    d.ed.last_edit = Instant::now(); // try again in a while, not every tick
                }
            }
        }
        if self.screen != Screen::Write && self.last_check.elapsed() > Duration::from_secs(4) {
            self.last_check = Instant::now();
            if Some(self.fingerprint_now()) != self.fingerprint {
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
            // A quit the composer refused (its save failed) is forced by
            // asking again; the loop then tries a recovery copy first.
            self.force_quit = self.quit_refused;
            self.quit = true;
            return;
        }
        self.quit_refused = false;
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
        if k.code == KeyCode::F(1) || (k.code == KeyCode::Char('?') && self.screen != Screen::Write && self.screen != Screen::Search && !self.nav().filtering) {
            self.help = true;
            return;
        }
        match self.screen {
            Screen::Today => self.today_key(k),
            Screen::Inbox | Screen::Browse => self.browse_key(k),
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

    fn browse_key(&mut self, k: KeyEvent) {
        let inbox = self.screen == Screen::Inbox;
        if self.nav().filtering {
            match k.code {
                KeyCode::Esc => {
                    // Back to where `/` was pressed: typing moved the
                    // selection through the matches, and Esc undoes that.
                    let nav = self.nav_mut();
                    nav.filtering = false;
                    nav.filter.clear();
                    if let Some((col, yi, mi, di, ei)) = nav.before_filter.take() {
                        (nav.col, nav.yi, nav.mi, nav.di, nav.ei) = (col, yi, mi, di, ei);
                    }
                    self.clamp_browse();
                }
                KeyCode::Enter => self.keep_filtered(),
                KeyCode::Backspace => {
                    self.nav_mut().filter.pop();
                    self.clamp_browse();
                }
                KeyCode::Char(c) => {
                    self.nav_mut().filter.push(c);
                    self.clamp_browse();
                }
                _ => {}
            }
            return;
        }
        match k.code {
            KeyCode::Esc | KeyCode::Char('q') => self.back(),
            KeyCode::Left | KeyCode::Char('h') => self.nav_mut().col = self.nav().col.saturating_sub(1),
            KeyCode::Right => self.nav_mut().col = (self.nav().col + 1).min(3),
            KeyCode::Up | KeyCode::Char('k') => {
                match self.nav().col {
                    0 => self.nav_mut().yi = self.nav().yi.saturating_sub(1),
                    1 => self.nav_mut().mi = self.nav().mi.saturating_sub(1),
                    2 => self.nav_mut().di = self.nav().di.saturating_sub(1),
                    _ => self.nav_mut().ei = self.nav().ei.saturating_sub(1),
                }
                self.after_browse_move();
            }
            KeyCode::Down => {
                match self.nav().col {
                    0 => self.nav_mut().yi += 1,
                    1 => self.nav_mut().mi += 1,
                    2 => self.nav_mut().di += 1,
                    _ => self.nav_mut().ei += 1,
                }
                self.after_browse_move();
            }
            KeyCode::Enter => {
                if self.nav().col < 3 {
                    self.nav_mut().col += 1;
                } else if let Some(e) = self.browse_sel().entry {
                    self.edit_entry(&e);
                }
            }
            KeyCode::Char('/') => {
                // The filter narrows the year, month or day column. From the
                // entries it has nothing to narrow, so it goes to the days
                // (as `t` and `d` go to the entries) instead of opening a
                // prompt that ignores what is typed. Esc comes back.
                let nav = self.nav_mut();
                nav.before_filter = Some((nav.col, nav.yi, nav.mi, nav.di, nav.ei));
                nav.col = nav.col.min(2);
                nav.filtering = true;
                nav.filter.clear();
            }
            KeyCode::Char('s') if !inbox => self.cycle_pick(),
            // These act at once, so only on an entry that is marked on
            // screen; from a column away the key goes to the entries first.
            KeyCode::Char('u') if !inbox => {
                if self.at_entries() {
                    self.unfile_selected();
                }
            }
            KeyCode::Char('f') if inbox => {
                if self.at_entries() {
                    self.file_selected_draft();
                }
            }
            KeyCode::Char('e') => {
                if self.at_entries() {
                    if let Some(e) = self.selected_entry() {
                        self.edit_entry(&e);
                    }
                }
            }
            KeyCode::Char('*') => {
                if self.at_entries() {
                    self.toggle_star_selected();
                }
            }
            // These ask first, and the question names the entry and carries
            // its reference: it goes to the entries and asks in one press.
            KeyCode::Char('t') => {
                if let Some(e) = self.selected_entry() {
                    self.nav_mut().col = 3;
                    let target = Target { at: (e.file.clone(), e.index, e.raw.clone()), name: entry_name(&e) };
                    self.modal = Some(Modal::Retime(e.ts[..16].to_string(), Some(target)));
                }
            }
            KeyCode::Char('d') => {
                if let Some(e) = self.selected_entry() {
                    self.nav_mut().col = 3;
                    let text = format!("Delete the {} {}?", if e.source == "inbox" { "draft" } else { "entry" }, entry_name(&e));
                    self.modal = Some(Modal::Confirm { text, action: Confirm::DeleteSelected((e.file.clone(), e.index, e.raw.clone())) });
                }
            }
            _ => {
                self.common_nav(&k);
            }
        }
    }

    /// ↵ in a column filter: the filter goes and the row it had selected
    /// stays selected, wherever that row is in the whole list.
    fn keep_filtered(&mut self) {
        let sel = self.browse_sel();
        let col = self.nav().col;
        self.nav_mut().filtering = false;
        self.nav_mut().filter.clear();
        self.nav_mut().before_filter = None;
        let find = |items: Vec<(String, usize)>, key: &Option<String>| key.as_ref().and_then(|k| items.iter().position(|i| i.0 == *k));
        match col {
            0 => {
                if let Some(i) = find(self.browse_years(), &sel.year) {
                    self.nav_mut().yi = i;
                }
            }
            1 => {
                if let Some(i) = sel.year.as_deref().and_then(|y| find(self.browse_months(y), &sel.month)) {
                    self.nav_mut().mi = i;
                }
            }
            2 => {
                if let (Some(y), Some(m)) = (sel.year.as_deref(), sel.month.as_deref()) {
                    if let Some(i) = find(self.browse_days(y, m), &sel.date) {
                        self.nav_mut().di = i;
                    }
                }
            }
            _ => {}
        }
        self.clamp_browse();
    }

    fn after_browse_move(&mut self) {
        match self.nav().col {
            0 => {
                self.nav_mut().mi = 0;
                self.nav_mut().di = 0;
                self.nav_mut().ei = 0;
            }
            1 => {
                self.nav_mut().di = 0;
                self.nav_mut().ei = 0;
            }
            2 => self.nav_mut().ei = 0,
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
        // Too small to draw the text: take nothing that would change it.
        if !self.composer_fits() {
            match k.code {
                KeyCode::Esc => self.leave_write(),
                KeyCode::Char('s') if ctrl => {
                    if let Err(e) = self.save_draft() {
                        self.save_refused(e);
                    }
                }
                _ => {}
            }
            return;
        }
        let width = self.editor_width();
        let suggestions = self.tag_suggestions();
        let accept = !suggestions.is_empty() && self.tag_accepts();
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
                    Err(e) => self.save_refused(e),
                },
                KeyCode::Char('j') => self.file_from_write(),
                KeyCode::Char('k') => self.keep_as_new_draft(),
                KeyCode::Char('t') => {
                    let ts = d.ts[..16].to_string();
                    self.modal = Some(Modal::Retime(ts, None));
                }
                KeyCode::Char('f') => self.focus = !self.focus,
                KeyCode::Char('v') => self.paste_clipboard(),
                KeyCode::Char('p') => {
                    self.prompt_n += 1;
                    let p = self.current_prompt();
                    let d = self.draft.as_mut().unwrap();
                    // Into the body, as Today's ↵ puts it: from the title it
                    // would otherwise become the header line (or cut it in two).
                    d.ed.insert_block(&format!("> {}\n\n", p));
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
                KeyCode::Char('d') => self.ask_discard(),
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
                    self.tag_moved = false;
                } else {
                    self.leave_write();
                }
            }
            KeyCode::Tab => {
                if let Some(t) = suggestions.get(self.tag_pick.min(suggestions.len().saturating_sub(1))).filter(|_| accept) {
                    d.ed.accept_tag(t);
                    self.tag_pick = 0;
                    self.tag_moved = false;
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
                if let Some(t) = suggestions.get(self.tag_pick.min(suggestions.len().saturating_sub(1))).filter(|_| accept) {
                    d.ed.accept_tag(t);
                    self.tag_pick = 0;
                    self.tag_moved = false;
                } else if d.ed.row == 0 {
                    // Leaving the title: into the body, past the blank line.
                    if d.ed.lines.len() == 1 {
                        d.ed.lines.push(String::new());
                        d.ed.lines.push(String::new());
                        d.ed.dirty = true;
                    }
                    // The body starts on the row under the title when that
                    // row has text (a paste, or a joined line), not past it.
                    let first = if d.ed.lines[1].trim().is_empty() { 2 } else { 1 };
                    d.ed.row = first.min(d.ed.lines.len() - 1);
                    d.ed.col = 0;
                } else {
                    d.ed.newline();
                }
            }
            KeyCode::Backspace => {
                d.ed.backspace();
                self.tag_moved = false;
            }
            KeyCode::Delete => d.ed.delete(),
            KeyCode::Left => {
                d.ed.left();
                self.tag_moved = false;
            }
            KeyCode::Right => {
                d.ed.right();
                self.tag_moved = false;
            }
            KeyCode::Up => {
                if !suggestions.is_empty() {
                    self.tag_pick = self.tag_pick.saturating_sub(1);
                    self.tag_moved = true;
                } else {
                    d.ed.up(width);
                }
            }
            KeyCode::Down => {
                if !suggestions.is_empty() {
                    // The first ↓ takes the row that is shown first.
                    self.tag_pick = if self.tag_moved || accept { (self.tag_pick + 1).min(suggestions.len() - 1) } else { 0 };
                    self.tag_moved = true;
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
                self.tag_moved = false;
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
            Modal::Retime(v, target) => match k.code {
                KeyCode::Esc => self.modal = None,
                KeyCode::Enter => {
                    let (v, target) = (v.clone(), target.clone());
                    // A date that doesn't exist leaves the prompt up to be put right.
                    if self.apply_retime(&v, target.as_ref()) {
                        self.modal = None;
                    }
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
                                self.start_maintenance(move |j| merge_ex_split(&j, &tags).and_then(|r| if r.errors.is_empty() { Ok(format!("Merged {} {} from {} {}", r.entries, noun(r.entries, "entry", "entries"), r.journals, noun(r.journals, "journal", "journals"))) } else { Err(r.errors.join("; ")) }));
                            }
                            Confirm::CompressMedia => {
                                // Minted under the settings lock, so two
                                // windows never give this install two ids.
                                self.persist(|s| {
                                    s.ensure_device_id();
                                });
                                let (id, _) = self.settings.ensure_device_id();
                                self.start_maintenance(move |j| {
                                    let r = media::compress_existing(j.local()?, &id, &mut |_, _| {})?;
                                    let message = format!("Compressed {} media; saved {} bytes", r.images + r.videos + r.audio, r.saved_bytes);
                                    if !r.errors.is_empty() { Err(format!("{} — {}", message, r.errors.join("; "))) }
                                    else if !r.skipped_missing_tools.is_empty() { Err(format!("{} — missing {}", message, r.skipped_missing_tools.join(", "))) }
                                    else { Ok(message) }
                                });
                            }
                            Confirm::MergeTags(from, to) => self.start_maintenance(move |j| rename_tags(&j, &from, &to).map(|n| format!("Updated tags in {} {}", n, noun(n, "file", "files")))),
                            Confirm::ImportMarkdown(path) => self.start_maintenance(move |j| import_markdown_folder(&j, std::path::Path::new(&path), false).map(|r| format!("Imported {} {}; {} skipped", r.written, noun(r.written, "entry", "entries"), r.skipped))),
                            Confirm::ImportDayOne(path) => self.start_maintenance(move |j| import_day_one(&j, std::path::Path::new(&path), false).map(|r| format!("Imported {} {} and {} media", r.written, noun(r.written, "entry", "entries"), r.media))),
                            Confirm::MergeConflicts => self.start_maintenance(move |j| {
                                let files = j.conflict_files(); let mut added = 0;
                                for file in &files { added += merge_conflict(&j, file)?; }
                                Ok(format!("Merged {} {} from {} conflict {}", added, noun(added, "entry", "entries"), files.len(), noun(files.len(), "copy", "copies")))
                            }),
                            Confirm::FileTransfer => {
                                let tags = self.split_tags.clone();
                                self.start_maintenance(move |j| import_transfer(&j, &now_local(), &tags).map(|n| format!("Filed {} {} from transfer.md", n, noun(n, "entry", "entries"))));
                            }
                            Confirm::Restore(name) => self.run_restore(&name),
                            Confirm::DeleteSelected(at) => self.delete_at(&at),
                            a @ (Confirm::DiscardDraft | Confirm::RestoreDraft | Confirm::DeleteEmptied) => self.discard(a),
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
        // Read, changed and written under the settings lock: only this
        // change goes in, whatever else has been saved since Quire started.
        match Settings::update(&f) {
            // What is on disk now, the other shell's changes included.
            Ok(saved) => self.settings = saved,
            Err(e) => self.toast(e, true),
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
            8 => ("Keep backups", format!("{} {}", self.settings.keep(), noun(self.settings.keep(), "copy", "copies"))),
            9 => ("Back up now", if self.backup_result.is_some() { "running…".into() } else {
                let last = self.last_backup().map(|t| format!("last {}", &t[..t.len().min(16)])).unwrap_or_else(go);
                match &self.backup_note { Some(note) => format!("{} · {}", last, note), None => last }
            }),
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
            12 => self.run_sort_inbox(),
            13 => self.modal = Some(Modal::Confirm { text: "File every draft to its day?".into(), action: Confirm::FileAll }),
            14 => self.modal = Some(Modal::Confirm { text: "Delete media no entry links to?".into(), action: Confirm::ClearOrphans }),
            16 => self.modal = Some(Modal::Confirm { text: "Merge journals whose split tags are no longer configured?".into(), action: Confirm::MergeSplits }),
            17 => self.modal = Some(Modal::Confirm { text: format!("Compress existing media and convert HEIC? Originals are kept {} days.", RECOVERY_DAYS), action: Confirm::CompressMedia }),
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

    /// Where this journal's backups go: the backup folder itself for the
    /// settings' own journal, a folder of its own inside it for any other.
    fn backup_dir(&mut self) -> Option<PathBuf> {
        let Some(dir) = self.settings.backup_dir.clone().map(PathBuf::from) else {
            self.toast("Set a backup folder first".into(), true);
            return None;
        };
        if !self.keyed_backups {
            return Some(dir);
        }
        match self.j.local() {
            Ok(root) => Some(backup_dir_for(&dir, root)),
            Err(e) => {
                self.toast(e, true);
                None
            }
        }
    }

    /// When this journal was last backed up. The settings' own journal uses
    /// `last_backup`, as every version has; another folder has its own time
    /// under `last_backups.<journal key>`, which older versions carry along
    /// untouched and the desktop app never reads.
    pub fn last_backup(&self) -> Option<String> {
        if !self.keyed_backups {
            return self.settings.last_backup.clone();
        }
        let key = journal_key(self.j.root());
        self.settings.extra.get(LAST_BACKUPS)?.get(&key)?.as_str().map(str::to_string)
    }

    fn record_backup(&mut self, when: String) {
        if !self.keyed_backups {
            return self.persist(|s| s.last_backup = Some(when.clone()));
        }
        let key = journal_key(self.j.root());
        self.persist(|s| {
            let all = s.extra.entry(LAST_BACKUPS.to_string()).or_insert_with(|| serde_json::json!({}));
            if !all.is_object() {
                *all = serde_json::json!({});
            }
            if let Some(map) = all.as_object_mut() {
                map.insert(key.clone(), serde_json::Value::String(when.clone()));
            }
        });
    }

    /// One at a time with a backup or restore, which copy the folder file by
    /// file: a job that rewrites day files meanwhile would be half in the copy.
    fn guard(&mut self) -> Option<BackupGuard> {
        if self.backup_result.is_some() {
            self.toast("A backup is running — try again when it has finished".into(), true);
            return None;
        }
        match BackupGuard::acquire() {
            Ok(g) => Some(g),
            Err(e) => {
                self.toast(format!("{} — try again when it has finished", e), true);
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
            // The copy is the backup; pruning comes after and is reported apart,
            // so a prune that fails or holds back never unmakes a good copy.
            let result: BackupDone = backup(&journal, &dir).map(|made| (made, prune_backups_checked(&dir, keep)));
            let _ = sender.send(result);
        });
    }

    fn backup_finished(&mut self, result: BackupDone) {
        match result {
            Ok((made, pruned)) => {
                self.backup_schedule.succeeded();
                self.record_backup(now_local());
                match pruned {
                    Ok(Pruned { held: Some(_), .. }) => {
                        self.backup_note = Some("older backups all kept: the new one is much smaller".into());
                        self.toast("Backed up, but no older backup was removed: the new one is much smaller than the last".into(), true);
                        self.notice("Check the journal folder is the right one and complete".into(), true);
                    }
                    Ok(_) => {
                        self.backup_note = None;
                        self.toast(format!("Backed up to {}", made), false);
                    }
                    Err(e) => {
                        self.backup_note = Some("older backups could not be removed".into());
                        self.toast(format!("Backed up, but older backups couldn't be removed: {}", e), true);
                    }
                }
            }
            // Each failure in a row waits twice as long before the next try.
            Err(error) => { self.backup_schedule.failed(Instant::now()); self.toast(format!("Backup failed: {}", error), true); }
        }
    }

    pub fn backup_running(&self) -> bool {
        self.backup_result.is_some()
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
        let Some(_guard) = self.guard() else { return };
        match restore(&self.j, &dir, name) {
            Ok(safety) => {
                self.draft = None;
                self.reload();
                self.toast(format!("Restored. Previous folder kept as {}", safety), false);
            }
            Err(e) => self.toast(e, true),
        }
    }

    fn run_sort_inbox(&mut self) {
        let Some(_guard) = self.guard() else { return };
        match sort_inbox(&self.j) {
            Ok(true) => {
                self.reload();
                self.toast("Inbox sorted by time".into(), false);
            }
            Ok(false) => self.toast("Inbox was already in order".into(), false),
            Err(e) => self.toast(e, true),
        }
    }

    fn run_cleanup(&mut self) {
        let Some(_guard) = self.guard() else { return };
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
        let Some(_guard) = self.guard() else { return };
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
        let Some(_guard) = self.guard() else { return };
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
            Hit::Text(..) | Hit::TextEnd | Hit::Column(_) | Hit::Item(3, _) => None,
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
                // A column filter left open would follow to Today, where it
                // can't be seen or closed and it swallows `?`.
                if self.nav().filtering {
                    self.keep_filtered();
                }
                self.stack.clear();
                self.screen = Screen::Today;
                self.help = false;
            }
            Hit::Edit(f, i) => {
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
            Hit::Column(c) => self.nav_mut().col = c.min(3),
            Hit::Item(c, i) => {
                let b = self.nav_mut();
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
            Screen::Inbox | Screen::Browse => {
                let col = self.hits.borrow().iter().rev().find_map(|(r, h)| match h {
                    Hit::Column(c) if r.contains(Position::new(x, y)) => Some(*c),
                    _ => None,
                });
                if let Some(c) = col {
                    self.nav_mut().col = c;
                }
                self.handle_key(key);
            }
            Screen::Write => {
                for _ in 0..3 {
                    self.handle_key(key);
                }
            }
            Screen::Search => self.handle_key(key),
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
            Some(Modal::Retime(v, _)) => {
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
            Screen::Write if !self.composer_fits() => {}
            Screen::Write => self.paste_text(&s),
            Screen::Search => {
                self.query.push_str(&line);
                self.search_i = 0;
            }
            Screen::Inbox | Screen::Browse if self.nav().filtering => {
                self.nav_mut().filter.push_str(&line);
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
        self.tag_moved = false;
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
        // Fresh from disk: Data Saver is switched in the desktop app. If the
        // file can't be read just now, what this session started with.
        let mut s = Settings::try_load().unwrap_or_else(|_| self.settings.clone());
        let device = if s.data_saver {
            if s.device_id.is_none() {
                // Minted and written under the settings lock, so the desktop
                // app and this one never end up with an id each.
                match Settings::update(|s| {
                    s.ensure_device_id();
                }) {
                    Ok(saved) => s = saved,
                    Err(e) => self.toast(e, true),
                }
            }
            s.ensure_device_id().0
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
        // The original is parked in the journal's recovery folder first.
        if let Ok(res) = media::compress_asset(&root, &path) {
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
    if let Err(e) = crossterm::execute!(std::io::stdout(), EnableBracketedPaste) {
        // The screen was already taken: give it back before saying why.
        ratatui::restore();
        return Err(e);
    }
    let mut mouse_on = false;
    let mut step = |app: &mut App, terminal: &mut ratatui::DefaultTerminal, redraw: &mut bool| -> std::io::Result<bool> {
        if app.mouse != mouse_on {
            set_mouse(app.mouse)?;
            mouse_on = app.mouse;
        }
        if *redraw {
            let size = terminal.size()?;
            app.width = size.width;
            app.height = size.height;
            terminal.draw(|f| crate::ui::draw(f, app))?;
        }
        *redraw = true;
        if event::poll(Duration::from_millis(200))? {
            match event::read()? {
                Event::Key(k) => app.handle_key(k),
                Event::Paste(s) => app.handle_paste(s),
                // Bare movement only matters if it lands on something else clickable.
                Event::Mouse(m) if m.kind == MouseEventKind::Moved => {
                    let before = app.hover.and_then(|(x, y)| app.hit_rect_at(x, y));
                    app.handle_mouse(m);
                    *redraw = before != app.hit_rect_at(m.column, m.row);
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
            if app.maintenance_running {
                // The wait below can be long: say what it is for first.
                app.toast("Finishing the maintenance job before closing…".into(), false);
                terminal.draw(|f| crate::ui::draw(f, app))?;
            }
            app.finish_maintenance();
            // A save that fails cancels the quit and says why; asked again,
            // it goes, with the text kept as a new draft.
            return Ok(app.settle_for_quit());
        }
        Ok(false)
    };
    let mut redraw = true;
    let result = loop {
        match step(&mut app, &mut terminal, &mut redraw) {
            Ok(false) => {}
            Ok(true) => break Ok(()),
            Err(e) => break Err(e),
        }
    };
    if result.is_err() {
        // The terminal went away under the loop, not the journal: what is in
        // the composer is saved, or kept as a recovery copy.
        app.finish_maintenance();
        app.rescue_on_error();
    }
    if app.maintenance_running || app.backup_running() {
        app.toast(if app.backup_running() { "Finishing the backup before closing…" } else { "Finishing the maintenance job before closing…" }.into(), false);
        let _ = terminal.draw(|f| crate::ui::draw(f, &mut app));
    }
    app.finish_maintenance();
    app.finish_backup();
    let _ = crossterm::execute!(std::io::stdout(), DisableMouseCapture, DisableBracketedPaste);
    ratatui::restore();
    // Only now can anything printed be read.
    for note in &app.exit_notes {
        eprintln!("{}", note);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn app_in(dir: &std::path::Path, settings: Settings) -> App {
        let mut a = App::new(Journal::open(dir), settings, vec![], "almanac");
        a.width = 80;
        a.height = 24;
        a
    }

    fn press(a: &mut App, code: KeyCode) {
        a.handle_key(KeyEvent::from(code));
    }

    fn ctrl(a: &mut App, c: char) {
        a.handle_key(KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL));
    }

    fn type_in(a: &mut App, s: &str) {
        for c in s.chars() {
            press(a, KeyCode::Char(c));
        }
    }

    fn inbox_text(a: &App) -> String {
        a.j.walk_md(INBOX_DIR).iter().map(|f| a.j.read(f)).collect::<Vec<_>>().join("\n")
    }

    fn confirm_text(a: &App) -> String {
        match &a.modal {
            Some(Modal::Confirm { text, .. }) => text.clone(),
            _ => String::new(),
        }
    }

    /// Someone else rewrites the entry the composer has open.
    fn change_on_disk(a: &App, file: &str, from: &str, to: &str) {
        let path = a.j.root().join(file);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains(from));
        std::fs::write(&path, text.replace(from, to)).unwrap();
    }

    /// T1: a quit with a failing save is refused and says so; asked again it
    /// goes, and the text is in the inbox as a draft of its own.
    #[test]
    fn a_failing_save_cancels_the_quit_and_the_second_ask_keeps_a_copy() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        let w = j.new_draft("2026-03-04 10:00:00", "Mine", false, "first words").unwrap();
        let mut a = app_in(d.path(), Settings::default());
        let e = a.entries[0].clone();
        a.edit_entry(&e);
        type_in(&mut a, " and more");
        change_on_disk(&a, &w.file, "first words", "the phone's words");
        ctrl(&mut a, 'c');
        assert!(a.quit);
        assert!(!a.settle_for_quit(), "the save failed, so Quire stays");
        assert!(!a.quit && a.draft.is_some());
        let said = a.toast.as_ref().unwrap().0.clone();
        assert!(said.contains("^c again"), "{said}");
        assert!(a.exit_notes.is_empty());
        // Any other key in between means the next ^c is a first ask again.
        press(&mut a, KeyCode::Char('!'));
        ctrl(&mut a, 'c');
        assert!(!a.settle_for_quit());
        ctrl(&mut a, 'c');
        assert!(a.settle_for_quit(), "the second ask goes");
        let inbox = inbox_text(&a);
        assert!(inbox.contains("the phone's words"), "the other version is untouched: {inbox}");
        assert!(inbox.contains("first words and more!"), "and mine is a draft of its own: {inbox}");
        assert!(a.exit_notes[0].contains("kept as a new draft"), "{:?}", a.exit_notes);
    }

    #[test]
    fn a_lost_terminal_and_a_folder_that_is_gone_still_hand_back_the_text() {
        let d = tempfile::tempdir().unwrap();
        let journal = d.path().join("j");
        std::fs::create_dir(&journal).unwrap();
        let mut a = app_in(&journal, Settings::default());
        a.start_draft("Title", "");
        type_in(&mut a, " and a thought");
        // Nowhere to write: a file where the folder was.
        std::fs::remove_dir_all(&journal).unwrap();
        std::fs::write(&journal, "not a folder").unwrap();
        a.rescue_on_error();
        assert_eq!(a.exit_notes.len(), 1);
        assert!(a.exit_notes[0].contains("Title and a thought"), "{:?}", a.exit_notes);
    }

    #[test]
    fn ctrl_k_keeps_a_refused_save_as_a_new_draft() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        let w = j.new_draft("2026-03-04 10:00:00", "Mine", false, "first words").unwrap();
        let mut a = app_in(d.path(), Settings::default());
        let e = a.entries[0].clone();
        a.edit_entry(&e);
        ctrl(&mut a, 'k');
        assert!(a.toast.as_ref().unwrap().0.contains("refused"), "nothing to keep while saves work");
        type_in(&mut a, " plus mine");
        change_on_disk(&a, &w.file, "first words", "theirs");
        ctrl(&mut a, 's');
        assert!(a.toast.as_ref().unwrap().0.contains("^k"));
        ctrl(&mut a, 'k');
        let inbox = inbox_text(&a);
        assert!(inbox.contains("theirs") && inbox.contains("first words plus mine"), "{inbox}");
        let dr = a.draft.as_ref().unwrap();
        assert!(!dr.ed.dirty && dr.save_error.is_none() && dr.opened.is_none());
        // The composer now edits the copy: the next save goes through.
        type_in(&mut a, "!");
        assert_eq!(a.save_draft(), Ok(true));
        assert_eq!(a.entries.len(), 2);
    }

    /// T2: at 80 columns the drafts are a column away and not drawn.
    #[test]
    fn entry_keys_go_to_the_entries_before_they_act() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        j.new_draft("2026-03-04 10:00:00", "Hidden", false, "body").unwrap();
        let mut a = app_in(d.path(), Settings::default());
        a.screen = Screen::Inbox;
        assert_eq!(a.nav().col, 2);
        for key in ['f', '*', 'e'] {
            a.inbox.col = 2;
            press(&mut a, KeyCode::Char(key));
            assert_eq!((a.nav().col, a.screen), (3, Screen::Inbox), "{key} only moved");
            assert_eq!(a.entries.iter().filter(|e| e.source == "inbox" && !e.starred).count(), 1, "{key} changed nothing");
            assert!(a.toast.as_ref().unwrap().0.contains("“Hidden”"));
        }
        press(&mut a, KeyCode::Char('f'));
        assert!(a.entries.iter().all(|e| e.source == "journal"), "the second press files it");
        // In the journal the same holds for `u`, wide or narrow.
        a.screen = Screen::Browse;
        a.width = 120;
        a.browse.col = 2;
        press(&mut a, KeyCode::Char('u'));
        assert!(a.entries.iter().all(|e| e.source == "journal"));
        press(&mut a, KeyCode::Char('u'));
        assert!(a.entries.iter().all(|e| e.source == "inbox"));
        // A wide inbox marks the selected draft from any column: `f` acts.
        a.screen = Screen::Inbox;
        a.inbox.col = 0;
        press(&mut a, KeyCode::Char('f'));
        assert!(a.entries.iter().all(|e| e.source == "journal"));
    }

    /// T3: the answer is about the entry the question named.
    #[test]
    fn delete_and_retime_act_on_the_entry_they_asked_about() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        j.new_draft("2026-03-04 10:00:00", "First", false, "a").unwrap();
        j.new_draft("2026-03-04 11:00:00", "Second", false, "b").unwrap();
        let mut a = app_in(d.path(), Settings::default());
        a.screen = Screen::Inbox;
        press(&mut a, KeyCode::Char('d'));
        assert_eq!(a.nav().col, 3, "the question brings the entries up");
        assert!(confirm_text(&a).contains("draft 2026-03-04 10:00 “First”"), "{}", confirm_text(&a));
        // A sync lands behind the question and the selection is elsewhere.
        j.new_draft("2026-03-04 09:00:00", "Synced in", false, "c").unwrap();
        a.reload();
        a.inbox.ei = 2;
        press(&mut a, KeyCode::Char('y'));
        let titles: Vec<&str> = a.entries.iter().map(|e| e.title.as_str()).collect();
        assert_eq!(titles, ["Synced in", "Second"]);
        // Retime: the prompt names it, refuses a date that isn't one, and
        // moves the entry it was opened for.
        a.inbox.ei = 1;
        press(&mut a, KeyCode::Char('t'));
        let Some(Modal::Retime(v, Some(t))) = a.modal.as_mut() else { panic!("no prompt") };
        assert!(t.name.contains("“Second”"));
        *v = "2026-02-31 25:99".into();
        press(&mut a, KeyCode::Enter);
        assert!(a.modal.is_some(), "an impossible date keeps the prompt up");
        assert!(a.toast.as_ref().unwrap().0.contains("not a real date"));
        let Some(Modal::Retime(v, _)) = a.modal.as_mut() else { panic!("no prompt") };
        *v = "2026-03-05 08:30".into();
        a.inbox.ei = 0;
        press(&mut a, KeyCode::Enter);
        assert!(a.modal.is_none());
        let moved = a.entries.iter().find(|e| e.title == "Second").unwrap();
        assert_eq!((moved.ts.as_str(), moved.file.as_str()), ("2026-03-05 08:30:00", "inbox/2026/03/05.md"));
        assert_eq!(a.entries.iter().find(|e| e.title == "Synced in").unwrap().ts, "2026-03-04 09:00:00");
    }

    /// T5.
    #[test]
    fn keeping_a_filter_keeps_the_row_it_selected() {
        let d = tempfile::tempdir().unwrap();
        for (day, text) in [("2026/01/02", "[2026-01-02 10:00:00] new\nx\n"), ("2023/05/06", "[2023-05-06 10:00:00] old\nx\n"), ("2023/07/08", "[2023-07-08 10:00:00] older\nx\n")] {
            let p = d.path().join("journal").join(format!("{day}.md"));
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        }
        let mut a = app_in(d.path(), Settings::default());
        a.screen = Screen::Browse;
        a.browse.col = 0;
        press(&mut a, KeyCode::Char('/'));
        type_in(&mut a, "2023");
        assert_eq!(a.browse_years().len(), 1);
        press(&mut a, KeyCode::Enter);
        assert!(!a.nav().filtering);
        assert_eq!(a.browse_years().len(), 2);
        assert_eq!(a.browse_sel().year.as_deref(), Some("2023"), "not the first year of the whole list");
        // The same a column on: May, by name.
        a.browse.col = 1;
        press(&mut a, KeyCode::Char('/'));
        type_in(&mut a, "may");
        press(&mut a, KeyCode::Enter);
        assert_eq!(a.browse_sel().date.as_deref(), Some("2023-05-06"));
    }

    #[test]
    fn a_filter_given_up_goes_back_to_where_it_started() {
        let d = tempfile::tempdir().unwrap();
        for (day, text) in [
            ("2026/01/02", "[2026-01-02 10:00:00] new\nx\n"),
            ("2023/05/06", "[2023-05-06 10:00:00] a Saturday\nx\n"),
            ("2023/05/10", "[2023-05-10 10:00:00] a Wednesday\nx\n"),
        ] {
            let p = d.path().join("journal").join(format!("{day}.md"));
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        }
        let mut a = app_in(d.path(), Settings::default());
        a.screen = Screen::Browse;
        // 2023 is marked; typing a filter for 2026 moves the mark, Esc undoes it.
        a.browse.col = 0;
        a.browse.yi = 1;
        press(&mut a, KeyCode::Char('/'));
        type_in(&mut a, "2026");
        assert_eq!(a.browse_sel().year.as_deref(), Some("2026"));
        press(&mut a, KeyCode::Esc);
        assert!(!a.nav().filtering);
        assert_eq!(a.browse_sel().year.as_deref(), Some("2023"), "Esc puts the selection back");
        // The day column is found by what it shows: "Wed 10", "Sat 06".
        a.browse.col = 2;
        for (typed, day) in [("wed", "2023-05-10"), ("sat", "2023-05-06"), ("6", "2023-05-06"), ("10", "2023-05-10")] {
            press(&mut a, KeyCode::Char('/'));
            type_in(&mut a, typed);
            assert_eq!(a.browse_days("2023", "05").iter().map(|d| d.0.as_str()).collect::<Vec<_>>(), [day], "{typed}");
            press(&mut a, KeyCode::Esc);
        }
        // From the entries the filter is the day column's, not a prompt that
        // ignores typing; Esc goes back to the entries.
        a.browse.col = 3;
        press(&mut a, KeyCode::Char('/'));
        assert!(a.nav().filtering);
        assert_eq!(a.nav().col, 2);
        type_in(&mut a, "wed");
        assert_eq!(a.browse_sel().date.as_deref(), Some("2023-05-10"));
        press(&mut a, KeyCode::Esc);
        assert_eq!((a.nav().col, a.nav().filtering), (3, false));
        // A click on QUIRE with a filter open closes it: `?` works on Today.
        a.browse.col = 0;
        press(&mut a, KeyCode::Char('/'));
        type_in(&mut a, "2023");
        a.click(Hit::Home, 0);
        assert_eq!(a.screen, Screen::Today);
        assert!(!a.browse.filtering && a.browse.filter.is_empty());
        press(&mut a, KeyCode::Char('?'));
        assert!(a.help, "the help overlay opens");
    }

    #[test]
    fn a_title_from_the_command_line_is_kept() {
        let d = tempfile::tempdir().unwrap();
        let mut a = app_in(d.path(), Settings::default());
        a.start_titled_draft("Call the dentist");
        press(&mut a, KeyCode::Esc);
        assert!(a.draft.is_none());
        assert!(inbox_text(&a).contains("] Call the dentist"), "left with nothing more typed, it is still a draft: {}", inbox_text(&a));
        // No title is no draft, and Today's prompt alone is still not one.
        a.start_titled_draft("");
        press(&mut a, KeyCode::Esc);
        a.screen = Screen::Today;
        press(&mut a, KeyCode::Enter);
        press(&mut a, KeyCode::Esc);
        assert_eq!(a.entries.len(), 1);
    }

    #[test]
    fn a_prompt_asked_for_from_the_title_goes_in_the_body() {
        let d = tempfile::tempdir().unwrap();
        let mut a = app_in(d.path(), Settings::default());
        a.start_draft("", "");
        type_in(&mut a, "My day");
        press(&mut a, KeyCode::Left); // the caret inside the title
        ctrl(&mut a, 'p');
        let ed = &a.draft.as_ref().unwrap().ed;
        assert_eq!(ed.title(), "My day", "the title is whole and still the title");
        assert!(ed.body().starts_with("> "), "{:?}", ed.lines);
        // From an empty title too: the prompt is not the header line.
        a.draft = None;
        a.start_draft("", "");
        ctrl(&mut a, 'p');
        let ed = &a.draft.as_ref().unwrap().ed;
        assert!(ed.title().is_empty() && ed.body().starts_with("> "), "{:?}", ed.lines);
    }

    #[test]
    fn a_date_prompt_left_as_it_was_changes_nothing() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        j.new_draft("2026-03-04 10:15:42", "Timed", false, "x").unwrap();
        let mut a = app_in(d.path(), Settings::default());
        a.screen = Screen::Inbox;
        let before = inbox_text(&a);
        press(&mut a, KeyCode::Char('t'));
        assert!(matches!(&a.modal, Some(Modal::Retime(v, _)) if v == "2026-03-04 10:15"));
        press(&mut a, KeyCode::Enter);
        assert!(a.modal.is_none());
        assert_eq!(inbox_text(&a), before, "the seconds are not rewritten as :00");
        assert!(a.toast.is_none(), "and nothing is said to have moved");
        // Another minute is a move, on the minute as typed.
        press(&mut a, KeyCode::Char('t'));
        let Some(Modal::Retime(v, _)) = a.modal.as_mut() else { panic!("no prompt") };
        *v = "2026-03-04 10:16".into();
        press(&mut a, KeyCode::Enter);
        assert_eq!(a.entries[0].ts, "2026-03-04 10:16:00");
    }

    /// T6, decision D3.
    #[test]
    fn discard_undoes_this_visit_and_only_deletes_a_draft_made_in_it() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        let w = j.new_draft("2026-03-04 10:00:00", "Kept", false, "from before").unwrap();
        let mut a = app_in(d.path(), Settings::default());
        let e = a.entries[0].clone();
        a.edit_entry(&e);
        ctrl(&mut a, 'd');
        assert!(a.modal.is_none() && a.draft.is_none(), "nothing changed: nothing to ask");
        a.edit_entry(&e);
        type_in(&mut a, " and today's");
        assert_eq!(a.save_draft(), Ok(true));
        type_in(&mut a, " and unsaved");
        ctrl(&mut a, 'd');
        assert!(confirm_text(&a).starts_with("Undo"), "{}", confirm_text(&a));
        press(&mut a, KeyCode::Char('y'));
        assert!(a.draft.is_none());
        assert_eq!(a.entries.len(), 1);
        assert_eq!(a.entries[0].raw.trim_end(), w.raw, "as it was when opened");
        assert!(a.toast.as_ref().unwrap().0.contains("as it was"));
        // A draft made in this visit is deleted, and asked about as that.
        a.start_draft("Fresh", "");
        type_in(&mut a, " words");
        assert_eq!(a.save_draft(), Ok(true));
        assert_eq!(a.entries.len(), 2);
        ctrl(&mut a, 'd');
        assert!(confirm_text(&a).starts_with("Delete this new draft"), "{}", confirm_text(&a));
        press(&mut a, KeyCode::Char('n'));
        assert!(a.draft.is_some() && a.entries.len() == 2, "n keeps it");
        ctrl(&mut a, 'd');
        press(&mut a, KeyCode::Char('y'));
        assert_eq!(a.entries.iter().map(|e| e.title.as_str()).collect::<Vec<_>>(), ["Kept"]);
    }

    #[test]
    fn an_emptied_entry_is_never_left_as_a_bare_timestamp() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        let w = j.new_draft("2026-03-04 10:00:00", "Was here", false, "text").unwrap();
        let mut a = app_in(d.path(), Settings::default());
        let empty = |a: &mut App| {
            let ed = &mut a.draft.as_mut().unwrap().ed;
            ed.lines = vec![String::new()];
            ed.row = 0;
            ed.col = 0;
            ed.dirty = true;
        };
        let e = a.entries[0].clone();
        a.edit_entry(&e);
        empty(&mut a);
        assert_eq!(a.save_draft(), Ok(false), "an autosave writes nothing");
        assert_eq!(a.j.read(&w.file).trim(), w.raw);
        press(&mut a, KeyCode::Esc);
        assert!(confirm_text(&a).contains("empty"), "leaving asks");
        press(&mut a, KeyCode::Char('n'));
        assert!(a.draft.is_some() && a.screen == Screen::Write);
        assert_eq!(a.j.read(&w.file).trim(), w.raw, "and n changes nothing");
        press(&mut a, KeyCode::Esc);
        press(&mut a, KeyCode::Char('y'));
        assert!(a.draft.is_none() && a.entries.is_empty());
        assert!(a.j.walk_md(INBOX_DIR).is_empty(), "the emptied day file is gone");
        // A draft from this visit, emptied: removed without a question.
        a.start_draft("", "");
        type_in(&mut a, "x");
        assert_eq!(a.save_draft(), Ok(true));
        press(&mut a, KeyCode::Backspace);
        press(&mut a, KeyCode::Esc);
        assert!(a.modal.is_none() && a.draft.is_none() && a.entries.is_empty());
        assert!(a.j.walk_md(INBOX_DIR).is_empty());
    }

    #[test]
    fn a_complete_tag_is_not_swapped_for_a_longer_one() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        j.new_draft("2026-03-04 10:00:00", "a", false, "@run @running @running").unwrap();
        let mut a = app_in(d.path(), Settings::default());
        a.start_draft("", "");
        type_in(&mut a, "@run");
        assert_eq!(a.tag_suggestions(), ["@running"]);
        assert!(!a.tag_accepts());
        press(&mut a, KeyCode::Tab);
        press(&mut a, KeyCode::Enter);
        assert_eq!(a.draft.as_ref().unwrap().ed.lines[0], "@run", "↹ and ↵ left it alone");
        // Asked for with ↓, it is taken.
        a.start_draft("", "");
        type_in(&mut a, "@run");
        press(&mut a, KeyCode::Down);
        assert!(a.tag_accepts());
        press(&mut a, KeyCode::Enter);
        assert_eq!(a.draft.as_ref().unwrap().ed.lines[0], "@running ");
        // A prefix that is not itself a tag completes as before.
        a.start_draft("", "");
        type_in(&mut a, "@runn");
        press(&mut a, KeyCode::Enter);
        assert_eq!(a.draft.as_ref().unwrap().ed.lines[0], "@running ");
        // And still does once the autosave has put the half-typed tag on
        // disk: the composer's own entry is not where tags are looked up.
        a.start_draft("", "");
        type_in(&mut a, "x @runn");
        assert_eq!(a.save_draft(), Ok(true));
        assert!(a.tag_accepts() && a.tag_suggestions() == ["@running"]);
        press(&mut a, KeyCode::Tab);
        assert_eq!(a.draft.as_ref().unwrap().ed.lines[0], "x @running ");
    }

    #[test]
    fn a_guarded_line_is_edited_as_written_and_saved_as_stored() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        let w = j.new_draft("2026-03-04 10:00:00", "Quote", false, "said:\n[2026-10-01 09:00:00] note").unwrap();
        assert!(w.raw.contains("\\[2026-10-01"));
        let mut a = app_in(d.path(), Settings::default());
        let e = a.entries[0].clone();
        a.edit_entry(&e);
        assert_eq!(a.draft.as_ref().unwrap().ed.body(), "said:\n[2026-10-01 09:00:00] note");
        type_in(&mut a, "d");
        assert_eq!(a.save_draft(), Ok(true), "the reference still matches what is on disk");
        assert_eq!(a.entries.len(), 1);
        assert_eq!(a.entries[0].raw.trim_end(), format!("{}d", w.raw));
    }

    /// B4: opening a journal is not a change to it.
    #[test]
    fn the_first_reading_of_the_folder_is_not_a_change_to_back_up() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        j.new_draft("2026-03-04 10:00:00", "a", false, "b").unwrap();
        let settings = Settings { backup_dir: Some("/nowhere".into()), backup_interval: Some("change".into()), ..Settings::default() };
        let mut a = app_in(d.path(), settings);
        let later = Instant::now() + Duration::from_secs(120);
        assert!(!a.backup_schedule.due(&a.settings, None, later), "a read-only session makes no backup");
        a.reload();
        assert!(!a.backup_schedule.due(&a.settings, None, later));
        j.new_draft("2026-03-04 11:00:00", "c", false, "d").unwrap();
        a.reload();
        assert!(a.backup_schedule.due(&a.settings, None, later), "a change does");
    }

    #[test]
    fn a_folder_that_cannot_be_read_keeps_what_was_shown() {
        let d = tempfile::tempdir().unwrap();
        let j = Journal::open(d.path());
        let w = j.new_draft("2026-03-04 10:00:00", "a", false, "b").unwrap();
        let mut a = app_in(d.path(), Settings::default());
        assert_eq!(a.entries.len(), 1);
        std::fs::write(d.path().join(&w.file), [0xff, 0xfe, 0x00, 0xc3]).unwrap();
        a.reload();
        assert_eq!(a.entries.len(), 1, "not an empty journal");
        assert!(a.toast.as_ref().unwrap().0.contains("Can't read"));
    }

    #[test]
    fn a_small_window_takes_no_typing_it_cannot_show() {
        let d = tempfile::tempdir().unwrap();
        let mut a = app_in(d.path(), Settings::default());
        a.start_draft("", "");
        a.height = COMPOSER_MIN_ROWS - 1;
        type_in(&mut a, "lost?");
        a.handle_paste("pasted".into());
        assert!(a.draft.as_ref().unwrap().ed.is_empty());
        a.height = COMPOSER_MIN_ROWS;
        type_in(&mut a, "seen");
        assert_eq!(a.draft.as_ref().unwrap().ed.lines[0], "seen");
        a.height = COMPOSER_MIN_ROWS - 1;
        press(&mut a, KeyCode::Esc);
        assert!(a.draft.is_none() && a.entries.len() == 1, "esc still saves and leaves");
    }

    /// B4: a journal opened with --folder keeps its own backup folder and
    /// its own "last backup", and never touches the settings' journal's.
    #[test]
    fn another_journal_has_its_own_backup_folder_and_time() {
        static CONFIG: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
        let config = CONFIG.get_or_init(|| {
            let dir = tempfile::tempdir().unwrap();
            // Never the real settings, however the tests were started.
            std::env::set_var(CONFIG_DIR_ENV, dir.path());
            dir
        });
        let d = tempfile::tempdir().unwrap();
        let backups = tempfile::tempdir().unwrap();
        let settings = Settings { backup_dir: Some(backups.path().display().to_string()), last_backup: Some("2026-01-01 00:00:00".into()), ..Settings::default() };
        std::fs::write(config.path().join("settings.json"), serde_json::to_string(&settings).unwrap()).unwrap();
        let mut a = app_in(d.path(), settings);
        assert_eq!(a.backup_dir().unwrap(), backups.path());
        assert_eq!(a.last_backup().as_deref(), Some("2026-01-01 00:00:00"));
        a.keyed_backups = true;
        let own = a.backup_dir().unwrap();
        assert_eq!(own.parent().unwrap(), backups.path());
        assert_eq!(own, backup_dir_for(backups.path(), d.path()));
        assert_eq!(a.last_backup(), None, "never backed up, whatever the other journal's time says");
        a.record_backup("2026-03-04 05:06:07".into());
        assert_eq!(a.last_backup().as_deref(), Some("2026-03-04 05:06:07"));
        let on_disk = Settings::try_load().unwrap();
        assert_eq!(on_disk.last_backup.as_deref(), Some("2026-01-01 00:00:00"), "the settings' journal's time is untouched");
        assert_eq!(on_disk.extra[LAST_BACKUPS][journal_key(d.path())], "2026-03-04 05:06:07");
    }
}
