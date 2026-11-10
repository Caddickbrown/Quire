use quire_core::{extras, journal, media};

use base64::Engine;
use extras::*;
use journal::*;
use notify::{RecursiveMode, Watcher};
use serde::Serialize;
use serde_json::Value;
use std::fs;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, State};

use quire_core::settings::{Settings, INTERVALS};

struct AppState {
    settings: Mutex<Settings>,
    sample_dir: PathBuf,
    /// The live folder watcher. Replacing it drops the old one, which ends
    /// its thread (the channel sender lives inside the watcher).
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
    /// "change" backups: when the debounced backup should run.
    backup_deadline: Mutex<Option<Instant>>,
    scheduler_running: AtomicBool,
    /// When the last scheduled backup was tried, and how many have failed in
    /// a row: a failing backup is retried with a growing wait, not on every save.
    backup_attempt: Mutex<Option<Instant>>,
    backup_failures: AtomicU32,
    /// The journal changed since the last backup that verified. Mirrored in
    /// the settings file (`PENDING_KEY`) so an "on change" backup that was
    /// still waiting when the window closed runs at the next launch.
    backup_pending: AtomicBool,
    /// Paths the person chose in a file dialog or dropped on the window. The
    /// commands that read or write outside the journal (attach, export,
    /// import) take only these, so the page can't name a path of its own.
    approved: Mutex<HashSet<PathBuf>>,
    /// Why the settings file couldn't be used at launch, for the window to show.
    settings_warning: Mutex<Option<String>>,
}

/// Lock even if a previous holder panicked.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn settings_of(state: &AppState) -> Settings {
    lock(&state.settings).clone()
}

/// Change settings: read from disk, changed and written back under the core's
/// lock (so the terminal app's changes are kept), and only then made live.
fn update_settings(state: &AppState, f: impl FnOnce(&mut Settings)) -> Result<(), String> {
    let next = Settings::update(f)?;
    *lock(&state.settings) = next;
    Ok(())
}

/// The settings key (kept in `Settings::extra`) for "changed since the last backup".
const PENDING_KEY: &str = "backup_pending";

/// Let the webview's asset protocol read this folder. Scopes only grow: a
/// folder used earlier in this run stays readable until Quire closes.
fn allow_assets(app: &AppHandle, folder: &Path) {
    let _ = app.asset_protocol_scope().allow_directory(folder, true);
}

fn approve(state: &AppState, p: &Path) {
    lock(&state.approved).insert(p.to_path_buf());
}

/// A path the page handed back: only one a dialog or a drop gave it.
fn approved(state: &AppState, p: &str) -> Result<PathBuf, String> {
    let p = PathBuf::from(p);
    if lock(&state.approved).contains(&p) {
        Ok(p)
    } else {
        Err("Choose the file or folder in the dialog first".into())
    }
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::create_dir_all(to)?;
    for e in fs::read_dir(from)? {
        let e = e?;
        let t = to.join(e.file_name());
        if e.path().is_dir() {
            copy_dir(&e.path(), &t)?;
        } else if !t.exists() {
            fs::copy(e.path(), t)?;
        }
    }
    Ok(())
}

const UNAVAILABLE: &str = "Journal folder unavailable — nothing was saved";

/// The journal for a write. Errors if its folder is unset or missing.
fn root(state: &AppState) -> Result<Journal, String> {
    let f = lock(&state.settings).folder.clone().ok_or("No journal folder set")?;
    let p = PathBuf::from(f);
    if !p.is_dir() {
        return Err(UNAVAILABLE.into());
    }
    Ok(Journal::open(p))
}

/// The journal for a read.
fn root_r(state: &AppState) -> Result<Journal, String> {
    root(state).map_err(|e| if e == UNAVAILABLE { "Journal folder unavailable".into() } else { e })
}

fn split_tags_of(state: &AppState) -> Vec<String> {
    split_tags_from(&lock(&state.settings).split_tags)
}

/// Run blocking work off the UI and async threads.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f).await.map_err(|e| e.to_string())?
}

// ---------- backups ----------

#[derive(Serialize, Clone, Default)]
struct BackupDone {
    path: String,
    removed: usize,
    /// Why no older backup was pruned although there were more than "keep".
    held: Option<String>,
    /// Pruning failed; the backup itself is good.
    prune_error: Option<String>,
    /// The backup is good but its time couldn't be recorded.
    settings_error: Option<String>,
}

/// Back up now, record the time, then prune. Blocks concurrent runs. The time
/// is recorded as soon as the copy has verified: a prune that fails is
/// reported beside the backup, and never makes the next focus start another.
fn run_backup(app: &AppHandle) -> Result<BackupDone, String> {
    let state = app.state::<AppState>();
    let _g = BackupGuard::acquire()?;
    let s = settings_of(&state);
    let dir = s.backup_dir.clone().ok_or("Choose a backup folder first")?;
    let j = root(&state)?;
    *lock(&state.backup_attempt) = Some(Instant::now());
    // Cleared first: a write that lands during the copy sets it again.
    state.backup_pending.store(false, Ordering::SeqCst);
    let made = match backup(&j, Path::new(&dir)) {
        Ok(m) => m,
        Err(e) => {
            state.backup_pending.store(true, Ordering::SeqCst);
            state.backup_failures.fetch_add(1, Ordering::SeqCst);
            return Err(e);
        }
    };
    state.backup_failures.store(0, Ordering::SeqCst);
    let now = now_local();
    let still_pending = state.backup_pending.load(Ordering::SeqCst);
    let settings_error = update_settings(&state, |s| {
        s.last_backup = Some(now);
        if still_pending {
            s.extra.insert(PENDING_KEY.into(), Value::Bool(true));
        } else {
            s.extra.remove(PENDING_KEY);
        }
    })
    .err();
    let (pruned, prune_error) = match prune_backups_checked(Path::new(&dir), s.keep()) {
        Ok(p) => (p, None),
        Err(e) => (Pruned::default(), Some(e)),
    };
    Ok(BackupDone { path: made, removed: pruned.removed, held: pruned.held, prune_error, settings_error })
}

/// How long to leave a failing backup alone: 5 minutes, doubling to an hour.
fn backup_backoff(state: &AppState) -> Duration {
    let fails = state.backup_failures.load(Ordering::SeqCst);
    if fails == 0 {
        return Duration::ZERO;
    }
    Duration::from_secs((300u64 << (fails - 1).min(4)).min(3600))
}

/// Time still to wait before a scheduled backup may be tried again.
fn backup_wait(state: &AppState) -> Option<Duration> {
    let wait = backup_backoff(state);
    let since = (*lock(&state.backup_attempt))?.elapsed();
    (since < wait).then(|| wait - since)
}

#[derive(Serialize, Clone)]
struct BackupEvent {
    ok: bool,
    done: Option<BackupDone>,
    error: Option<String>,
}

/// After a successful write: note that the journal has changed since the last
/// backup and, in "change" mode, back up 30 s after the last write (and never
/// sooner than 5 min after the previous backup).
fn wrote(app: &AppHandle) {
    let state = app.state::<AppState>();
    let s = settings_of(&state);
    if s.interval() != "change" || s.backup_dir.is_none() {
        return;
    }
    // Persisted once per backup, not once per save.
    if !state.backup_pending.swap(true, Ordering::SeqCst) || s.extra.get(PENDING_KEY) != Some(&Value::Bool(true)) {
        let _ = update_settings(&state, |s| {
            s.extra.insert(PENDING_KEY.into(), Value::Bool(true));
        });
    }
    *lock(&state.backup_deadline) = Some(Instant::now() + Duration::from_secs(30));
    if state.scheduler_running.swap(true, Ordering::SeqCst) {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || {
        let state = app.state::<AppState>();
        loop {
            loop {
                let Some(dl) = *lock(&state.backup_deadline) else { break };
                let now = Instant::now();
                if now < dl {
                    std::thread::sleep((dl - now).min(Duration::from_secs(30)));
                    continue;
                }
                let last = settings_of(&state).last_backup;
                if let Some(age) = last.as_deref().and_then(secs_since) {
                    if (0..300).contains(&age) {
                        std::thread::sleep(Duration::from_secs((300 - age) as u64));
                        continue;
                    }
                }
                if let Some(wait) = backup_wait(&state) {
                    std::thread::sleep(wait.min(Duration::from_secs(30)));
                    continue;
                }
                if BACKUP_RUNNING.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_secs(5));
                    continue;
                }
                *lock(&state.backup_deadline) = None;
                let s = settings_of(&state);
                if s.interval() != "change" || s.backup_dir.is_none() {
                    break;
                }
                let ev = match run_backup(&app) {
                    Ok(d) => BackupEvent { ok: true, done: Some(d), error: None },
                    Err(e) => {
                        // Still owed: try again once the wait is over.
                        *lock(&state.backup_deadline) = Some(Instant::now());
                        BackupEvent { ok: false, done: None, error: Some(e) }
                    }
                };
                let _ = app.emit("backup-finished", ev);
            }
            state.scheduler_running.store(false, Ordering::SeqCst);
            // A write that landed between the last check and the store above.
            if lock(&state.backup_deadline).is_some() && !state.scheduler_running.swap(true, Ordering::SeqCst) {
                continue;
            }
            break;
        }
    });
}

fn sweep_in_background(folder: PathBuf) {
    std::thread::spawn(move || {
        sweep_temps(&folder, Duration::from_secs(3600));
    });
}

// ---------- snapshot ----------

#[derive(Serialize)]
struct Snapshot {
    folder: String,
    is_sample: bool,
    /// The configured folder doesn't exist (unmounted drive, sync not yet
    /// arrived). Entries are empty and every write errors.
    folder_missing: bool,
    entries: Vec<Entry>,
    ui: Value,
    split_tags: Vec<String>,
    /// "settings" | "env" | "jnl config" | "none"
    split_tags_source: String,
    backup_dir: Option<String>,
    backup_interval: String,
    backup_keep: usize,
    last_backup: Option<String>,
    backup_running: bool,
    templates: Vec<Template>,
    searches: Vec<SavedSearch>,
    has_transfer: bool,
    /// JNL_DIR from the environment or jnl's config file when it names an
    /// existing folder: a hint for Settings only, never used automatically.
    jnl_dir: Option<String>,
    /// Sync-conflict copies awaiting merge_conflict (root-relative).
    conflicts: Vec<String>,
    data_saver: bool,
    /// Bytes saved by compression, summed over every device's ledger.
    data_saved: i64,
    media_tools: media::ToolStatus,
    /// Set when this load folded a legacy `inbox.md` into `inbox/`.
    migration: Option<InboxMigration>,
    /// Why a legacy `inbox.md` could not be folded in (it is still read).
    migration_error: Option<String>,
    /// Set when this load folded root `<tag>.md` split journals into `split/`.
    split_migration: Option<SplitMigration>,
    /// Why a root `<tag>.md` could not be folded in (it is still read).
    split_migration_error: Option<String>,
    /// `.quire-restore-old-*` folders an interrupted restore left in the
    /// journal: each may hold the only copy of something.
    restore_leftovers: Vec<String>,
}

#[tauri::command]
async fn load(state: State<'_, AppState>) -> Result<Snapshot, String> {
    let s = settings_of(&state);
    let folder = s.folder.clone().ok_or("No journal folder set")?;
    let r = PathBuf::from(&folder);
    let missing = !r.is_dir();
    let sample = state.sample_dir.clone();
    let (split_tags, src) = split_tags_resolved(&s.split_tags);
    let mut snap = Snapshot {
        is_sample: r == sample,
        folder: if missing { folder } else { r.display().to_string() },
        folder_missing: missing,
        entries: vec![],
        ui: s.ui.clone(),
        split_tags,
        split_tags_source: src.into(),
        backup_dir: s.backup_dir.clone(),
        backup_interval: s.interval(),
        backup_keep: s.keep(),
        last_backup: s.last_backup.clone(),
        backup_running: BACKUP_RUNNING.load(Ordering::SeqCst),
        templates: vec![],
        searches: vec![],
        has_transfer: false,
        jnl_dir: jnl_dir_hint(),
        conflicts: vec![],
        data_saver: s.data_saver,
        data_saved: 0,
        media_tools: media::tools(),
        migration: None,
        migration_error: None,
        split_migration: None,
        split_migration_error: None,
        restore_leftovers: vec![],
    };
    if missing {
        return Ok(snap);
    }
    let (entries, templates, searches, has_transfer, conflicts, saved, migration, split_migration, leftovers) = blocking(move || {
        let j = Journal::open(&r);
        // An inbox.md or <tag>.md left by jnl or Nook is folded into inbox/
        // or split/ first, so the load below sees one layout. Failure is
        // reported, never fatal: the file is still read in place.
        let migration = j.migrate_legacy_inbox();
        let split_migration = j.migrate_legacy_splits();
        // Strict: a file or folder that can't be read is an error the window
        // shows, never a journal that is silently shorter.
        let entries = j.try_load_all().map_err(|e| format!("Part of the journal couldn't be read, so nothing was reloaded: {}", e))?;
        // What a restore cut short left behind: staged copies an hour old go, displaced content is reported.
        let leftovers = restore_leftovers(&r, Duration::from_secs(3600)).old;
        Ok((entries, list_templates(&j), load_searches(&j), !j.read("transfer.md").trim().is_empty(), j.conflict_files(), media::data_saved_total(&r), migration, split_migration, leftovers))
    })
    .await?;
    snap.restore_leftovers = leftovers;
    match migration {
        Ok(m) => snap.migration = m,
        Err(e) => snap.migration_error = Some(e),
    }
    match split_migration {
        Ok(m) => snap.split_migration = m,
        Err(e) => snap.split_migration_error = Some(e),
    }
    snap.data_saved = saved;
    snap.entries = entries;
    snap.templates = templates;
    snap.searches = searches;
    snap.has_transfer = has_transfer;
    snap.conflicts = conflicts;
    Ok(snap)
}

#[tauri::command]
fn set_folder(app: AppHandle, state: State<AppState>, path: String) -> Result<(), String> {
    let path = path.trim().to_string();
    let p = PathBuf::from(expand_home(&path));
    if !p.is_dir() {
        return Err(format!("Not a folder: {}", path));
    }
    update_settings(&state, |s| s.folder = Some(p.display().to_string()))?;
    allow_assets(&app, &p);
    sweep_in_background(p);
    Ok(())
}

#[tauri::command]
fn use_sample(app: AppHandle, state: State<AppState>) -> Result<(), String> {
    let p = state.sample_dir.clone();
    let _ = fs::create_dir_all(&p);
    update_settings(&state, |s| s.folder = Some(p.display().to_string()))?;
    allow_assets(&app, &p);
    sweep_in_background(p);
    Ok(())
}

/// The PIN's hash is set through `set_pin` only, which asks for the current one.
const PIN_KEY: &str = "pinHash";

/// Save the window's preferences. Only the keys that differ from what this
/// window last saw are written, so a preference the terminal app changed in
/// the meantime is kept.
#[tauri::command]
fn save_ui(state: State<AppState>, ui: Value) -> Result<(), String> {
    let Value::Object(new) = ui else { return Err("Preferences must be an object".into()) };
    let prev = settings_of(&state).ui;
    let changed: Vec<(String, Value)> = new.into_iter().filter(|(k, v)| k != PIN_KEY && prev.get(k) != Some(v)).collect();
    if changed.is_empty() {
        return Ok(());
    }
    update_settings(&state, |s| {
        for (k, v) in changed {
            s.set_ui(&k, v);
        }
    })
}

/// What the window should say once it is up: why the settings file couldn't
/// be used. Given once.
#[tauri::command]
fn startup_notice(state: State<AppState>) -> Option<String> {
    lock(&state.settings_warning).take()
}

/// Open a file dialog from here, so the path it returns is known to have come
/// from the person: `kind` is "file", "folder" or "save".
#[tauri::command]
async fn pick_path(app: AppHandle, window: tauri::WebviewWindow, kind: String, title: String, default_name: Option<String>) -> Result<Option<String>, String> {
    use tauri_plugin_dialog::DialogExt;
    let a = app.clone();
    blocking(move || {
        let mut d = a.dialog().file().set_title(title).set_parent(&window);
        if let Some(n) = default_name {
            d = d.set_file_name(n);
        }
        let picked = match kind.as_str() {
            "file" => d.blocking_pick_file(),
            "folder" => d.blocking_pick_folder(),
            "save" => d.blocking_save_file(),
            other => return Err(format!("Unknown dialog {:?}", other)),
        };
        let Some(path) = picked.and_then(|p| p.into_path().ok()) else { return Ok(None) };
        approve(&a.state::<AppState>(), &path);
        Ok(Some(path.display().to_string()))
    })
    .await
}

/// Open a journal file or folder in the desktop's own app, or show it in the
/// file manager. `rel` is root-relative ("" for the journal folder itself)
/// and must stay inside the journal once symlinks are followed.
#[tauri::command]
async fn open_rel(app: AppHandle, state: State<'_, AppState>, rel: String, reveal: bool) -> Result<(), String> {
    use tauri_plugin_opener::OpenerExt;
    let j = root_r(&state)?;
    blocking(move || {
        let target = inside_journal(j.root(), &rel)?;
        if reveal {
            app.opener().reveal_item_in_dir(&target).map_err(|e| e.to_string())
        } else {
            app.opener().open_path(target.display().to_string(), None::<&str>).map_err(|e| e.to_string())
        }
    })
    .await
}

/// `rel` under `root` as a real path: checked as a relative path, then again
/// after symlinks are followed, so a link inside the journal can't lead out of it.
fn inside_journal(root: &Path, rel: &str) -> Result<PathBuf, String> {
    let base = root.canonicalize().map_err(|e| e.to_string())?;
    if rel.trim().is_empty() {
        return Ok(base);
    }
    let target = safe_rel(&base, rel)?.canonicalize().map_err(|_| format!("No such file: {}", rel))?;
    if !target.starts_with(&base) {
        return Err(format!("Refusing a path outside the journal: {:?}", rel));
    }
    Ok(target)
}

/// A `settings.json.bad-<stamp>` beside the settings file: an earlier launch
/// could not parse the settings and moved them aside.
fn settings_set_aside() -> Option<String> {
    let path = Settings::path();
    let mut names: Vec<String> = fs::read_dir(path.parent()?).ok()?.flatten().map(|e| e.file_name().to_string_lossy().to_string()).filter(|n| n.starts_with("settings.json.bad-")).collect();
    names.sort();
    names.pop()
}

// ----- the composer's recovery copy -----

/// Text the composer can't save as an entry yet (it holds header-shaped
/// lines, or the save keeps failing) is kept here, one file per device, in
/// the sidecar: never in an entry file.
fn recovery_rel(j: &Journal, device: &str, write: bool) -> Result<String, String> {
    let dir = if write { j.sidecar_mut()? } else { j.sidecar() };
    Ok(format!("{}/recovery-{}.json", dir, device))
}

#[tauri::command]
async fn save_recovery(state: State<'_, AppState>, draft: Value) -> Result<String, String> {
    let j = root(&state)?;
    let device = device_id(&state);
    blocking(move || {
        let rel = recovery_rel(&j, &device, true)?;
        j.write(&rel, &serde_json::to_string_pretty(&draft).map_err(|e| e.to_string())?)?;
        Ok(rel)
    })
    .await
}

#[tauri::command]
async fn read_recovery(state: State<'_, AppState>) -> Result<Option<Value>, String> {
    let j = root_r(&state)?;
    let device = device_id(&state);
    blocking(move || {
        let rel = recovery_rel(&j, &device, false)?;
        if !j.is_file(&rel) {
            return Ok(None);
        }
        Ok(serde_json::from_str(&j.try_read(&rel)?).ok())
    })
    .await
}

#[tauri::command]
async fn clear_recovery(state: State<'_, AppState>) -> Result<(), String> {
    let j = root(&state)?;
    let device = device_id(&state);
    blocking(move || {
        let rel = recovery_rel(&j, &device, false)?;
        if j.is_file(&rel) {
            j.remove(&rel)?;
        }
        Ok(())
    })
    .await
}

/// New draft → its day's file under inbox/, in time order.
#[tauri::command]
async fn create_draft(app: AppHandle, state: State<'_, AppState>, ts: String, title: String, starred: bool, body: String) -> Result<Written, String> {
    let j = root(&state)?;
    let w = blocking(move || j.new_draft(&ts, &title, starred, &body)).await?;
    wrote(&app);
    Ok(w)
}

/// Edit any entry in place. An entry in a day file whose date changes moves
/// to the new day's file (inbox or journal), kept in time order. A
/// split-journal entry stays in its file.
#[tauri::command]
#[allow(clippy::too_many_arguments)]
async fn update_entry(
    app: AppHandle,
    state: State<'_, AppState>,
    file: String,
    index: usize,
    expected_raw: String,
    ts: String,
    title: String,
    starred: bool,
    body: String,
) -> Result<Written, String> {
    let j = root(&state)?;
    let w = blocking(move || j.update_entry(&file, index, &expected_raw, &ts, &title, starred, &body)).await?;
    wrote(&app);
    Ok(w)
}

#[tauri::command]
async fn delete_entry(app: AppHandle, state: State<'_, AppState>, file: String, index: usize, expected_raw: String) -> Result<(), String> {
    let j = root(&state)?;
    blocking(move || j.delete_entry(&file, index, &expected_raw)).await?;
    wrote(&app);
    Ok(())
}

/// File a draft: jnl's fileDraft (split tags first, else the day file,
/// appended), then remove it from its inbox file. Returns where it went.
#[tauri::command]
async fn file_draft(app: AppHandle, state: State<'_, AppState>, file: String, index: usize, expected_raw: String) -> Result<String, String> {
    let j = root(&state)?;
    let tags = split_tags_of(&state);
    let target = blocking(move || j.file_draft(&file, index, &expected_raw, &tags)).await?;
    wrote(&app);
    Ok(target)
}

/// Nook's "Return to Inbox": move a filed entry back to the queue, into the
/// inbox day file of its own date.
#[tauri::command]
async fn unfile_entry(app: AppHandle, state: State<'_, AppState>, file: String, index: usize, expected_raw: String) -> Result<Written, String> {
    let j = root(&state)?;
    let w = blocking(move || j.unfile_entry(&file, index, &expected_raw)).await?;
    wrote(&app);
    Ok(w)
}

#[tauri::command]
async fn file_all(app: AppHandle, state: State<'_, AppState>) -> Result<FileAllReport, String> {
    let r = root(&state)?;
    let tags = split_tags_of(&state);
    let rep = blocking(move || extras::file_all(&r, &tags)).await?;
    if rep.filed > 0 {
        wrote(&app);
    }
    Ok(rep)
}

#[tauri::command]
async fn merge_ex_split(app: AppHandle, state: State<'_, AppState>) -> Result<MergeReport, String> {
    let r = root(&state)?;
    let tags = split_tags_of(&state);
    let rep = blocking(move || extras::merge_ex_split(&r, &tags)).await?;
    if rep.entries > 0 {
        wrote(&app);
    }
    Ok(rep)
}

#[tauri::command]
fn conflict_files(state: State<AppState>) -> Result<Vec<String>, String> {
    Ok(root_r(&state)?.conflict_files())
}

#[tauri::command]
async fn merge_conflict(app: AppHandle, state: State<'_, AppState>, rel: String) -> Result<usize, String> {
    let r = root(&state)?;
    let n = blocking(move || extras::merge_conflict(&r, &rel)).await?;
    wrote(&app);
    Ok(n)
}

// ---------- settings ----------

#[tauri::command]
fn set_split_tags(state: State<AppState>, tags: String) -> Result<(), String> {
    check_split_tags(&tags)?;
    update_settings(&state, |s| s.split_tags = if tags.trim().is_empty() { None } else { Some(tags) })
}

#[tauri::command]
fn set_backup_dir(state: State<AppState>, path: Option<String>) -> Result<(), String> {
    let path = path.map(|p| expand_home(p.trim())).filter(|p| !p.is_empty());
    if let (Some(p), Ok(j)) = (&path, root(&state)) {
        check_backup_dir(j.root(), Path::new(p))?;
    }
    update_settings(&state, |s| s.backup_dir = path)
}

#[tauri::command]
fn set_backup_prefs(state: State<AppState>, interval: String, keep: u32) -> Result<(), String> {
    if !INTERVALS.contains(&interval.as_str()) {
        return Err(format!("Unknown backup interval {:?}", interval));
    }
    if !(1..=50).contains(&keep) {
        return Err("Keep between 1 and 50 backups".into());
    }
    update_settings(&state, |s| {
        s.backup_interval = Some(interval);
        s.backup_keep = Some(keep);
    })
}

// ---------- templates / searches ----------

#[tauri::command]
fn save_template_cmd(app: AppHandle, state: State<AppState>, name: String, body: String) -> Result<(), String> {
    save_template(&root(&state)?, &name, &body)?;
    wrote(&app);
    Ok(())
}

#[tauri::command]
async fn new_template(app: AppHandle, state: State<'_, AppState>) -> Result<String, String> {
    let r = root(&state)?;
    let name = blocking(move || {
        let taken: Vec<String> = list_templates(&r).into_iter().map(|t| t.name).collect();
        let mut name = "New template".to_string();
        let mut n = 2;
        while taken.contains(&name) {
            name = format!("New template {}", n);
            n += 1;
        }
        save_template(&r, &name, STARTER_TEMPLATE)?;
        Ok(name)
    })
    .await?;
    wrote(&app);
    Ok(name)
}

#[tauri::command]
fn delete_template_cmd(app: AppHandle, state: State<AppState>, name: String) -> Result<(), String> {
    delete_template(&root(&state)?, &name)?;
    wrote(&app);
    Ok(())
}

#[tauri::command]
fn rename_template(app: AppHandle, state: State<AppState>, from: String, to: String) -> Result<(), String> {
    extras::rename_template(&root(&state)?, &from, &to)?;
    wrote(&app);
    Ok(())
}

#[tauri::command]
fn save_searches_cmd(app: AppHandle, state: State<AppState>, list: Vec<SavedSearch>) -> Result<(), String> {
    save_searches(&root(&state)?, &list)?;
    wrote(&app);
    Ok(())
}

// ---------- media ----------

/// An asset and where it is on disk, so the page needs no call per file.
#[derive(Serialize)]
struct AssetOut {
    #[serde(flatten)]
    asset: Asset,
    path: String,
}

#[tauri::command]
async fn assets(state: State<'_, AppState>) -> Result<Vec<AssetOut>, String> {
    let r = root_r(&state)?;
    blocking(move || {
        let base = r.root().to_path_buf();
        Ok(list_assets(&r)?.into_iter().map(|asset| AssetOut { path: base.join(&asset.rel).display().to_string(), asset }).collect())
    })
    .await
}

/// Absolute paths for root-relative files, in one call: null for one that
/// isn't there or isn't a safe path.
#[tauri::command]
async fn asset_paths(state: State<'_, AppState>, rels: Vec<String>) -> Result<Vec<Option<String>>, String> {
    let r = root_r(&state)?;
    blocking(move || Ok(rels.iter().map(|rel| safe_rel(r.root(), rel).ok().filter(|p| p.exists()).map(|p| p.display().to_string())).collect())).await
}

#[tauri::command]
fn delete_asset(app: AppHandle, state: State<AppState>, rel: String) -> Result<(), String> {
    extras::delete_asset(&root(&state)?, &rel)?;
    wrote(&app);
    Ok(())
}

/// Copy a user-chosen file into assets/. Returns the markdown to insert
/// (`![](assets/…)`, or `[name](assets/…)` for non-media), base-relative.
#[tauri::command]
async fn attach_file(app: AppHandle, state: State<'_, AppState>, src: String, ts: String, entry_file: String) -> Result<String, String> {
    let _ = entry_file;
    let r = root(&state)?;
    let src = approved(&state, &src)?;
    let (saver, device) = (settings_of(&state).data_saver, device_id(&state));
    let r2 = r.clone();
    let a = blocking(move || extras::attach_media(&r2, &src, &ts, saver, &device)).await?;
    compress_later(&app, &state, &r, &a);
    wrote(&app);
    Ok(a.link)
}

/// Background video/audio compression when Data Saver is on (one at a time,
/// like Nook's serial queue).
fn compress_later(app: &AppHandle, state: &AppState, r: &Journal, a: &extras::Attached) {
    if !a.compress_later {
        return;
    }
    let (app, root, rel, device) = (app.clone(), r.root().to_path_buf(), a.rel.clone(), device_id(state));
    std::thread::spawn(move || {
        static QUEUE: Mutex<()> = Mutex::new(());
        let _g = QUEUE.lock().unwrap_or_else(|p| p.into_inner());
        let path = root.join(&rel);
        if let Ok(res) = media::compress_asset(&root, &path) {
            let saved = res.unwrap_or(0);
            media::record_saving(&root, &device, &path, saved);
            let _ = app.emit("media-compressed", serde_json::json!({ "rel": rel, "saved": saved }));
        }
    });
}

fn device_id(state: &AppState) -> String {
    if let Some(id) = settings_of(state).device_id {
        return id;
    }
    // Made under the settings lock, so two windows never mint two ids.
    let _ = update_settings(state, |s| {
        s.ensure_device_id();
    });
    // If that couldn't be saved, an id for this run still keeps the ledger apart.
    let mut s = lock(&state.settings);
    s.ensure_device_id().0
}

/// Native clipboard-image paste: WebKitGTK often doesn't hand images to the
/// page's paste event on Linux. Returns the link, or None if the clipboard has
/// no image; then the usual Data Saver / attach path.
#[tauri::command]
async fn paste_image(app: AppHandle, state: State<'_, AppState>, ts: String, entry_file: String) -> Result<Option<String>, String> {
    let _ = entry_file;
    let r = root(&state)?;
    check_ts(&ts)?;
    let (saver, device) = (settings_of(&state).data_saver, device_id(&state));
    let link = blocking(move || {
        let img = match arboard::Clipboard::new().and_then(|mut c| c.get_image()) {
            Ok(i) => i,
            Err(_) => return Ok(None),
        };
        let (bytes, ext) = media::encode_clipboard_image(img.width as u32, img.height as u32, img.bytes.into_owned())?;
        Ok(Some(extras::attach_bytes(&r, &bytes, ext, &ts, saver, &device)?.link))
    })
    .await?;
    if link.is_some() {
        wrote(&app);
    }
    Ok(link)
}

#[tauri::command]
fn set_data_saver(state: State<AppState>, on: bool) -> Result<(), String> {
    update_settings(&state, |s| s.data_saver = on)
}

#[tauri::command]
async fn data_saved(state: State<'_, AppState>) -> Result<i64, String> {
    let r = root(&state)?;
    blocking(move || Ok(media::data_saved_total(r.root()))).await
}

/// Nook's "Compress Existing Media": HEIC→JPEG with relinking first, then
/// every image/video/audio not yet in any device's ledger.
#[tauri::command]
async fn compress_existing(app: AppHandle, state: State<'_, AppState>) -> Result<media::CompressReport, String> {
    let r = root(&state)?;
    let device = device_id(&state);
    let a2 = app.clone();
    let rep = blocking(move || {
        media::compress_existing(r.root(), &device, &mut |done, total| {
            let _ = a2.emit("media-progress", serde_json::json!({ "done": done, "total": total }));
        })
    })
    .await?;
    wrote(&app);
    Ok(rep)
}

/// Attach in-memory bytes (clipboard image paste). `name` only supplies the
/// extension; the stored name comes from `ts` as in attach_file.
#[tauri::command]
async fn attach_bytes(app: AppHandle, state: State<'_, AppState>, name: String, bytes_b64: String, ts: String, entry_file: String) -> Result<String, String> {
    let _ = entry_file;
    let r = root(&state)?;
    check_ts(&ts)?;
    let (saver, device) = (settings_of(&state).data_saver, device_id(&state));
    let r2 = r.clone();
    let a = blocking(move || {
        let b64 = bytes_b64.split_once(";base64,").map(|(_, b)| b).unwrap_or(&bytes_b64);
        let bytes = base64::engine::general_purpose::STANDARD.decode(b64.trim()).map_err(|e| format!("Bad base64: {}", e))?;
        if bytes.is_empty() {
            return Err("Nothing to attach".into());
        }
        let ext = Path::new(name.trim()).extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
        extras::attach_bytes(&r2, &bytes, &ext, &ts, saver, &device)
    })
    .await?;
    compress_later(&app, &state, &r, &a);
    wrote(&app);
    Ok(a.link)
}

#[tauri::command]
async fn orphan_count(state: State<'_, AppState>) -> Result<usize, String> {
    let r = root_r(&state)?;
    blocking(move || Ok(quire_core::orphan_media(&r)?.len())).await
}

/// The orphan files themselves, so the confirmation can name what it clears.
#[tauri::command]
async fn orphan_files(state: State<'_, AppState>) -> Result<Vec<String>, String> {
    let r = root_r(&state)?;
    blocking(move || quire_core::orphan_media(&r)).await
}

/// Clears `offered` (what the user was shown and confirmed) where each is still
/// unreferenced; without it, every current orphan.
#[tauri::command]
async fn clear_orphans(app: AppHandle, state: State<'_, AppState>, offered: Option<Vec<String>>) -> Result<usize, String> {
    let r = root(&state)?;
    let n = blocking(move || match offered {
        Some(list) => quire_core::archive_orphan_media(&r, &list).map(|(n, _)| n),
        None => delete_orphans(&r),
    })
    .await?;
    if n > 0 {
        wrote(&app);
    }
    Ok(n)
}

// ---------- maintenance ----------

#[tauri::command]
async fn run_cleanup(app: AppHandle, state: State<'_, AppState>) -> Result<CleanupReport, String> {
    let r = root(&state)?;
    let tags = split_tags_of(&state);
    let rep = blocking(move || cleanup(&r, &tags)).await?;
    if rep.moved + rep.formatted + rep.reordered + rep.deduped + rep.extracted > 0 {
        wrote(&app);
    }
    Ok(rep)
}

#[tauri::command]
async fn sort_inbox_cmd(app: AppHandle, state: State<'_, AppState>) -> Result<bool, String> {
    let j = root(&state)?;
    let changed = blocking(move || sort_inbox(&j)).await?;
    if changed {
        wrote(&app);
    }
    Ok(changed)
}

#[tauri::command]
async fn export_cmd(state: State<'_, AppState>, dest: String) -> Result<usize, String> {
    let r = root_r(&state)?;
    let dest = approved(&state, &dest)?;
    blocking(move || export_all(&r, &dest)).await
}

#[tauri::command]
async fn backup_now(app: AppHandle) -> Result<BackupDone, String> {
    let a = app.clone();
    blocking(move || run_backup(&a)).await
}

/// For the window's close: is a backup being copied, and is one owed?
#[derive(Serialize)]
struct BackupState {
    running: bool,
    /// "On change" is on and the journal changed since the last backup.
    pending: bool,
}

#[tauri::command]
fn backup_state(state: State<AppState>) -> BackupState {
    let s = settings_of(&state);
    BackupState {
        running: BACKUP_RUNNING.load(Ordering::SeqCst),
        pending: s.interval() == "change" && s.backup_dir.is_some() && state.backup_pending.load(Ordering::SeqCst) && root(&state).is_ok(),
    }
}

/// Called on launch and window focus: runs a daily/weekly backup if one is
/// due. Returns the new backup's path, or null if none was due/possible.
#[tauri::command]
async fn maybe_backup(app: AppHandle) -> Result<Option<BackupDone>, String> {
    let state = app.state::<AppState>();
    let s = settings_of(&state);
    // "On change" has nothing due by the clock: it is owed when a change was
    // still waiting for its backup the last time the window closed.
    let owed = s.interval() == "change" && state.backup_pending.load(Ordering::SeqCst) && lock(&state.backup_deadline).is_none();
    if s.backup_dir.is_none() || !(owed || backup_due(&s.interval(), s.last_backup.as_deref())) || BACKUP_RUNNING.load(Ordering::SeqCst) || backup_wait(&state).is_some() {
        return Ok(None);
    }
    if root(&state).is_err() {
        return Ok(None);
    }
    let a = app.clone();
    blocking(move || run_backup(&a)).await.map(Some)
}

#[tauri::command]
async fn backups(state: State<'_, AppState>) -> Result<Vec<BackupItem>, String> {
    let dir = settings_of(&state).backup_dir;
    blocking(move || {
        let Some(d) = dir else { return Ok(vec![]) };
        // Half-made copies a day old were abandoned (the window was closed mid-copy).
        sweep_partial_backups(Path::new(&d), PARTIAL_MAX_AGE);
        Ok(list_backups(Path::new(&d)).into_iter().map(|name| BackupItem { safety: name.starts_with(SAFETY_PREFIX), name }).collect())
    })
    .await
}

#[derive(Serialize)]
struct BackupItem {
    name: String,
    /// A "Quire before-restore …" copy: what the journal held before a restore. Never pruned.
    safety: bool,
}

/// Restore a backup over the journal folder. Returns the name of the safety
/// copy taken first (listed by `backups`).
#[tauri::command]
async fn restore_backup(state: State<'_, AppState>, name: String) -> Result<String, String> {
    let dir = settings_of(&state).backup_dir.ok_or("No backup folder")?;
    let r = root(&state)?;
    blocking(move || {
        let _g = BackupGuard::acquire().map_err(|_| "A backup is running — try again in a moment. Nothing was changed.".to_string())?;
        restore(&r, Path::new(&dir), &name)
    })
    .await
}

// ---------- imports ----------

#[tauri::command]
async fn import_markdown(app: AppHandle, state: State<'_, AppState>, dir: String, dry_run: bool) -> Result<ImportReport, String> {
    let r = root(&state)?;
    let dir = approved(&state, &dir)?;
    let rep = blocking(move || import_markdown_folder(&r, &dir, dry_run)).await?;
    if !dry_run && rep.written > 0 {
        wrote(&app);
    }
    Ok(rep)
}

#[tauri::command]
async fn import_dayone(app: AppHandle, state: State<'_, AppState>, path: String, dry_run: bool) -> Result<ImportReport, String> {
    let r = root(&state)?;
    let path = approved(&state, &path)?;
    let rep = blocking(move || import_day_one(&r, &path, dry_run)).await?;
    if !dry_run && rep.written > 0 {
        wrote(&app);
    }
    Ok(rep)
}

#[tauri::command]
async fn file_transfer(app: AppHandle, state: State<'_, AppState>, now_ts: String) -> Result<usize, String> {
    let r = root(&state)?;
    let tags = split_tags_of(&state);
    let n = blocking(move || import_transfer(&r, &now_ts, &tags)).await?;
    if n > 0 {
        wrote(&app);
    }
    Ok(n)
}

/// Split pasted text into drafts: per [header] when present, else one draft.
#[tauri::command]
async fn import_text(app: AppHandle, state: State<'_, AppState>, text: String, now_ts: String) -> Result<usize, String> {
    let j = root(&state)?;
    let n = blocking(move || j.import_text(&text, &now_ts)).await?;
    if n > 0 {
        wrote(&app);
    }
    Ok(n)
}

// ---------- tags / stats ----------

#[tauri::command]
async fn tag_review_cmd(state: State<'_, AppState>) -> Result<Vec<TagGroup>, String> {
    let r = root_r(&state)?;
    blocking(move || Ok(tag_review(&r))).await
}

#[tauri::command]
async fn merge_tags(app: AppHandle, state: State<'_, AppState>, from: Vec<String>, to: String) -> Result<usize, String> {
    let r = root(&state)?;
    let n = blocking(move || rename_tags(&r, &from, &to)).await?;
    if n > 0 {
        wrote(&app);
    }
    Ok(n)
}

#[tauri::command]
async fn sizes_cmd(state: State<'_, AppState>) -> Result<Sizes, String> {
    let r = root_r(&state)?;
    blocking(move || Ok(sizes(&r))).await
}

#[tauri::command]
async fn stats_extra(state: State<'_, AppState>) -> Result<StatsExtra, String> {
    let r = root_r(&state)?;
    blocking(move || Ok(extras::stats_extra(&r))).await
}

// ---------- lock ----------

#[tauri::command]
fn pin_check(state: State<AppState>, pin: String) -> Result<bool, String> {
    let s = settings_of(&state);
    let want = s.ui.get("pinHash").and_then(|v| v.as_str()).unwrap_or("");
    Ok(want.is_empty() || hash_pin(&pin) == want)
}

/// Set, change or remove the PIN. When one is set already, `current` must be
/// it. Returns the new hash ("" when removed).
#[tauri::command]
fn set_pin(state: State<AppState>, current: Option<String>, pin: Option<String>) -> Result<String, String> {
    let s = settings_of(&state);
    let have = s.ui.get(PIN_KEY).and_then(|v| v.as_str()).unwrap_or("");
    if !have.is_empty() && current.as_deref().map(hash_pin).as_deref() != Some(have) {
        return Err("That isn't the current PIN".into());
    }
    let hash = match pin.as_deref() {
        Some(p) if p.chars().count() >= 4 => hash_pin(p),
        Some(_) => return Err("Use at least 4 characters".into()),
        None => String::new(),
    };
    let h = hash.clone();
    update_settings(&state, |s| {
        s.set_ui(PIN_KEY, Value::String(h));
        if pin.is_none() {
            s.set_ui("lockOn", Value::Bool(false));
        }
    })?;
    Ok(hash)
}

fn hash_pin(pin: &str) -> String {
    // Not security against an attacker with the disk: a lock against a
    // family member glancing. A simple FNV-1a over a salt is enough here.
    let mut h: u64 = 0xcbf29ce484222325;
    for b in format!("quire:{}", pin).bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{:016x}", h)
}

// ---------- watcher / window ----------

/// Watch the journal folder and tell the window when files change there.
/// Returns the watcher; dropping it closes the channel and ends the thread.
fn start_watcher(app: AppHandle, folder: PathBuf) -> Result<notify::RecommendedWatcher, String> {
    let (tx, rx) = mpsc::channel();
    let mut watcher = notify::recommended_watcher(move |res: Result<notify::Event, notify::Error>| {
        let _ = tx.send(res);
    })
    .map_err(|e| e.to_string())?;
    watcher.watch(&folder, RecursiveMode::Recursive).map_err(|e| e.to_string())?;
    let is_own = {
        let nook = folder.join(LEGACY_SIDECAR);
        let quire = folder.join(SIDECAR);
        let assets = folder.join("assets");
        move |ev: &Result<notify::Event, notify::Error>| match ev {
            // Sidecar and media writes, and temp files, never change entries.
            Ok(e) => {
                !e.paths.is_empty()
                    && e.paths.iter().all(|p| {
                        let n = p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                        p.starts_with(&nook) || p.starts_with(&quire) || p.starts_with(&assets) || n.ends_with(".tmp") || n.starts_with("._tmp_")
                    })
            }
            Err(_) => false,
        }
    };
    // Ends when the watcher is dropped: recv() then fails.
    std::thread::spawn(move || {
        while let Ok(first) = rx.recv() {
            let mut relevant = !is_own(&first);
            // Coalesce bursts (a save is several events) into one notice, but
            // never sit on a change for more than ~2s during a sustained storm.
            let deadline = Instant::now() + Duration::from_secs(2);
            while let Ok(ev) = rx.recv_timeout(Duration::from_millis(400)) {
                relevant |= !is_own(&ev);
                if Instant::now() >= deadline {
                    break;
                }
            }
            if relevant {
                let _ = app.emit("journal-changed", ());
            }
        }
    });
    Ok(watcher)
}

#[tauri::command]
fn rewatch(app: AppHandle, state: State<AppState>) -> Result<(), String> {
    let folder = root_r(&state)?.root().to_path_buf();
    allow_assets(&app, &folder);
    let w = start_watcher(app, folder)?;
    // Assigning drops the previous watcher (and so its thread).
    *lock(&state.watcher) = Some(w);
    Ok(())
}

/// True when the window has no bar of its own and the front end must draw the
/// controls and the drag region. macOS always keeps its title bar.
#[tauri::command]
fn undecorated(state: State<AppState>) -> bool {
    cfg!(not(target_os = "macos")) && !lock(&state.settings).system_titlebar
}

#[tauri::command]
fn set_system_titlebar(app: AppHandle, state: State<AppState>, on: bool) -> Result<bool, String> {
    update_settings(&state, |s| s.system_titlebar = on)?;
    let custom = cfg!(not(target_os = "macos")) && !on;
    if let Some(w) = app.get_webview_window("main") {
        w.set_decorations(!custom).map_err(|e| e.to_string())?;
    }
    Ok(custom)
}

// ----- updates -----

const RELEASES_URL: &str = "https://github.com/Caddickbrown/Quire/releases";

/// How this copy was installed, which decides what an update can do: an
/// AppImage replaces itself; a .deb or .rpm belongs to the package manager;
/// a source build is updated by re-running install.sh. CI release builds set
/// QUIRE_RELEASE.
fn install_kind() -> &'static str {
    if std::env::var_os("APPIMAGE").is_some() {
        "appimage"
    } else if option_env!("QUIRE_RELEASE").is_some() {
        "package"
    } else {
        "source"
    }
}

/// The updater checks signatures against `plugins.updater.pubkey` in
/// tauri.conf.json; without one there is nothing to check against.
fn updater_ready(app: &AppHandle) -> bool {
    app.config()
        .plugins
        .0
        .get("updater")
        .and_then(|u| u.get("pubkey"))
        .and_then(|k| k.as_str())
        .is_some_and(|k| !k.trim().is_empty())
}

#[derive(Serialize)]
struct AppInfo {
    version: String,
    kind: &'static str,
    updates: bool,
    releases: &'static str,
}

#[tauri::command]
fn app_info(app: AppHandle) -> AppInfo {
    AppInfo { version: app.package_info().version.to_string(), kind: install_kind(), updates: updater_ready(&app), releases: RELEASES_URL }
}

#[derive(Serialize)]
struct UpdateCheck {
    latest: Option<String>,
    notes: Option<String>,
    can_install: bool,
}

/// Asks the latest release's latest.json whether there is a newer version.
/// Only ever runs when the person presses Check: Quire doesn't phone home.
#[tauri::command]
async fn check_update(app: AppHandle) -> Result<UpdateCheck, String> {
    use tauri_plugin_updater::UpdaterExt;
    if !updater_ready(&app) {
        return Err(format!("This build has no update key, so it can't check. Releases are at {RELEASES_URL}"));
    }
    let update = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())?;
    let latest = update.as_ref().map(|u| u.version.clone());
    Ok(UpdateCheck { can_install: latest.is_some() && install_kind() == "appimage", latest, notes: update.and_then(|u| u.body) })
}

/// Downloads the new AppImage, checks its signature, replaces this one and
/// restarts. The front end saves any open draft first.
#[tauri::command]
async fn install_update(app: AppHandle) -> Result<(), String> {
    use tauri_plugin_updater::UpdaterExt;
    if install_kind() != "appimage" {
        return Err("Only the AppImage updates itself; a .deb or .rpm updates through your package manager.".into());
    }
    let update = app.updater().map_err(|e| e.to_string())?.check().await.map_err(|e| e.to_string())?.ok_or("Quire is already up to date")?;
    update.download_and_install(|_, _| {}, || {}).await.map_err(|e| e.to_string())?;
    app.restart()
}

/// An AppImage run on its own has no launcher entry, so the dock has no icon
/// to show for its window. Write one (and the icon) the first time it runs,
/// unless a package already left one (install.sh writes the same `Quire.desktop`). `Quire.desktop` matches the
/// app id set in `run`; StartupWMClass covers X11 and shells that ask for it.
///
/// One Exec argument as the desktop-entry spec wants it: `%` doubled (field
/// codes); quoted when it holds a reserved character, with `"`, `` ` ``, `$` and
/// `\` escaped inside the quotes; then the value's own string escaping, which
/// doubles every backslash.
#[cfg(any(target_os = "linux", test))]
fn desktop_exec_arg(arg: &str) -> String {
    const RESERVED: &[char] = &[' ', '\t', '\n', '"', '\'', '\\', '>', '<', '~', '|', '&', ';', '$', '*', '?', '#', '(', ')', '`'];
    let arg = arg.replace('%', "%%");
    if !arg.contains(RESERVED) {
        return arg;
    }
    let mut quoted = String::from("\"");
    for c in arg.chars() {
        if matches!(c, '"' | '`' | '$' | '\\') {
            quoted.push('\\');
        }
        quoted.push(c);
    }
    quoted.push('"');
    quoted.replace('\\', "\\\\")
}

#[cfg(target_os = "linux")]
fn ensure_launcher() {
    let Ok(appimage) = std::env::var("APPIMAGE") else { return };
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else { return };
    let data = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".local/share"));
    let apps = data.join("applications");
    // Older installs wrote `quire.desktop`, which the shell can't pair with the
    // window (its app id is `Quire`) and which would show as a second entry.
    let _ = fs::remove_file(apps.join("quire.desktop"));
    let icon = data.join("icons/hicolor/128x128/apps/quire.png");
    if !icon.exists() {
        let _ = fs::create_dir_all(icon.parent().unwrap());
        let _ = fs::write(&icon, include_bytes!("../icons/128x128.png"));
    }
    let entry = apps.join("Quire.desktop");
    let old = fs::read_to_string(&entry).ok();
    // install.sh wraps the AppImage in `env APPIMAGE_EXTRACT_AND_RUN=1` on a
    // system without FUSE; that wrapper is kept, even when the path is redone.
    let wrapped = old.as_deref().is_some_and(|o| o.contains("APPIMAGE_EXTRACT_AND_RUN=1"));
    let exec = desktop_exec_arg(&appimage);
    let exec = if wrapped { format!("env APPIMAGE_EXTRACT_AND_RUN=1 {exec}") } else { exec };
    let body = format!(
        "[Desktop Entry]\nType=Application\nName=Quire\nComment=Journalling over a plain folder of markdown\nExec={exec}\nIcon=quire\nCategories=Office;\nTerminal=false\nStartupWMClass=Quire\n");
    // Rewritten when the AppImage has moved, so the entry never points at a stale path.
    if old.as_deref() == Some(body.as_str()) { return; }
    let _ = fs::create_dir_all(&apps);
    let _ = fs::write(&entry, body);
}

pub fn run() {
    // The Wayland app id (and X11 WM_CLASS) come from the program name. The
    // binary is quire-desktop; naming the program after Quire.desktop lets
    // the shell pair the window with its launcher, and so its icon.
    #[cfg(target_os = "linux")]
    {
        glib::set_prgname(Some("Quire"));
        ensure_launcher();
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .setup(|app| {
            let data = app.path().app_data_dir()?;
            let sample_dir = data.join("sample-journal");
            if !sample_dir.exists() {
                if let Ok(res) = app.path().resolve("sample", tauri::path::BaseDirectory::Resource) {
                    let _ = copy_dir(&res, &sample_dir);
                }
                let _ = fs::create_dir_all(&sample_dir);
            }
            // Only a settings file that isn't there means a first run. One
            // that can't be read or parsed is said so in the window, and the
            // sample journal is not put in its place: the person chooses.
            let (mut settings, mut warning) = match Settings::try_load() {
                Ok(s) => (s, None),
                Err(e) => (Settings { unread: Settings::path().exists().then(|| e.clone()), ..Default::default() }, Some(e)),
            };
            // Settings written since (a theme change, say) have no folder either:
            // still the person's to choose, not the sample's to take.
            if warning.is_none() && settings.folder.is_none() {
                if let Some(bad) = settings_set_aside() {
                    warning = Some(format!("Quire’s settings couldn’t be read at an earlier launch and were kept as {}. No journal folder is set now: choose yours again.", bad));
                }
            }
            if warning.is_none() {
                // Only an unset folder falls back to the sample. A configured
                // folder that's missing stays configured (folder_missing).
                let sample = sample_dir.display().to_string();
                let mut probe = settings.clone();
                if probe.migrate() || probe.folder.is_none() {
                    let fixed = Settings::update(|s| {
                        s.migrate();
                        if s.folder.is_none() {
                            s.folder = Some(sample.clone());
                        }
                    });
                    match fixed {
                        Ok(s) => settings = s,
                        // Can't be written (a read-only home): run on what was worked out.
                        Err(_) => {
                            if probe.folder.is_none() {
                                probe.folder = Some(sample);
                            }
                            settings = probe;
                        }
                    }
                }
            }
            #[cfg(not(target_os = "macos"))]
            if !settings.system_titlebar {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.set_decorations(false);
                }
            }
            let folder = settings.folder.clone().map(PathBuf::from).filter(|f| f.is_dir());
            let watcher = folder.clone().and_then(|f| start_watcher(app.handle().clone(), f).ok());
            if let Some(f) = folder {
                // The asset protocol starts with no folder at all (tauri.conf.json).
                allow_assets(app.handle(), &f);
                sweep_in_background(f);
            }
            let pending = settings.extra.get(PENDING_KEY) == Some(&Value::Bool(true));
            app.manage(AppState {
                settings: Mutex::new(settings),
                sample_dir,
                watcher: Mutex::new(watcher),
                backup_deadline: Mutex::new(None),
                scheduler_running: AtomicBool::new(false),
                backup_attempt: Mutex::new(None),
                backup_failures: AtomicU32::new(0),
                backup_pending: AtomicBool::new(pending),
                approved: Mutex::new(HashSet::new()),
                settings_warning: Mutex::new(warning),
            });
            Ok(())
        })
        // Files dropped on the window were chosen by the person: attach_file may take them.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) = event {
                if let Some(state) = window.try_state::<AppState>() {
                    paths.iter().for_each(|p| approve(&state, p));
                }
            }
        })
        .on_webview_event(|webview, event| {
            if let tauri::WebviewEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) = event {
                if let Some(state) = webview.try_state::<AppState>() {
                    paths.iter().for_each(|p| approve(&state, p));
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            set_data_saver, data_saved, compress_existing, paste_image,
            load,
            set_folder,
            use_sample,
            save_ui,
            create_draft,
            update_entry,
            delete_entry,
            file_draft,
            unfile_entry,
            file_all,
            merge_ex_split,
            conflict_files,
            merge_conflict,
            set_split_tags,
            set_backup_dir,
            set_backup_prefs,
            save_template_cmd,
            new_template,
            delete_template_cmd,
            rename_template,
            save_searches_cmd,
            assets,
            asset_paths,
            delete_asset,
            attach_file,
            attach_bytes,
            orphan_count,
            clear_orphans,
            orphan_files,
            run_cleanup,
            sort_inbox_cmd,
            export_cmd,
            backup_now,
            maybe_backup,
            backups,
            restore_backup,
            import_markdown,
            import_dayone,
            file_transfer,
            import_text,
            tag_review_cmd,
            merge_tags,
            sizes_cmd,
            stats_extra,
            pin_check,
            set_pin,
            startup_notice,
            pick_path,
            open_rel,
            save_recovery,
            read_recovery,
            clear_recovery,
            backup_state,
            rewatch,
            undecorated,
            set_system_titlebar,
            app_info,
            check_update,
            install_update
        ])
        .run(tauri::generate_context!())
        .expect("error while running Quire");
}

#[cfg(test)]
mod tests {
    use super::{desktop_exec_arg, inside_journal};

    #[test]
    fn opened_paths_stay_inside_the_journal() {
        let top = std::env::temp_dir().join(format!("quire-desktop-open-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&top);
        let (journal, outside) = (top.join("journal-folder"), top.join("outside"));
        std::fs::create_dir_all(journal.join("assets")).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(journal.join("assets/a.pdf"), b"x").unwrap();
        std::fs::write(outside.join("secret.txt"), b"x").unwrap();
        let base = journal.canonicalize().unwrap();
        assert_eq!(inside_journal(&journal, "").unwrap(), base);
        assert_eq!(inside_journal(&journal, "assets/a.pdf").unwrap(), base.join("assets/a.pdf"));
        assert!(inside_journal(&journal, "../outside/secret.txt").is_err());
        assert!(inside_journal(&journal, outside.join("secret.txt").to_str().unwrap()).is_err());
        assert!(inside_journal(&journal, "assets/missing.pdf").is_err());
        // A link inside the journal that points out of it is refused once followed.
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&outside, journal.join("assets/out")).unwrap();
            assert!(inside_journal(&journal, "assets/out/secret.txt").is_err());
            std::os::unix::fs::symlink(journal.join("assets/a.pdf"), journal.join("assets/b.pdf")).unwrap();
            assert!(inside_journal(&journal, "assets/b.pdf").is_ok());
        }
        let _ = std::fs::remove_dir_all(&top);
    }

    #[test]
    fn exec_args_follow_the_desktop_entry_spec() {
        assert_eq!(desktop_exec_arg("/home/a/Applications/Quire.AppImage"), "/home/a/Applications/Quire.AppImage");
        assert_eq!(desktop_exec_arg("/home/a/My Apps/Quire.AppImage"), "\"/home/a/My Apps/Quire.AppImage\"");
        // `"` and `$` escaped inside the quotes, then the backslash doubled.
        assert_eq!(desktop_exec_arg("/x/a\"b$c"), "\"/x/a\\\\\"b\\\\$c\"");
        // A literal backslash: \\ in the quotes, \\\\ in the file.
        assert_eq!(desktop_exec_arg("/x/a\\b"), "\"/x/a\\\\\\\\b\"");
        assert_eq!(desktop_exec_arg("/x/100%/Q"), "/x/100%%/Q");
    }
}
