use quire_core::{extras, journal, media};

use base64::Engine;
use extras::*;
use journal::*;
use notify::{RecursiveMode, Watcher};
use serde::Serialize;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
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
}

/// Lock even if a previous holder panicked.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn settings_of(state: &AppState) -> Settings {
    lock(&state.settings).clone()
}

fn save_settings(s: &Settings) -> Result<(), String> {
    s.save()
}

/// Change settings: applied to a copy, saved, and only then made live.
fn update_settings(state: &AppState, f: impl FnOnce(&mut Settings)) -> Result<(), String> {
    let mut g = lock(&state.settings);
    let mut next = g.clone();
    f(&mut next);
    save_settings(&next)?;
    *g = next;
    Ok(())
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

/// Back up now, prune, and record the time. Blocks concurrent runs.
fn run_backup(app: &AppHandle) -> Result<String, String> {
    let state = app.state::<AppState>();
    let _g = BackupGuard::acquire()?;
    let s = settings_of(&state);
    let dir = s.backup_dir.clone().ok_or("Choose a backup folder first")?;
    let j = root(&state)?;
    let made = backup(&j, Path::new(&dir))?;
    prune_backups(Path::new(&dir), s.keep())?;
    let now = now_local();
    update_settings(&state, |s| s.last_backup = Some(now))?;
    Ok(made)
}

#[derive(Serialize, Clone)]
struct BackupEvent {
    ok: bool,
    path: Option<String>,
    error: Option<String>,
}

/// After a successful write: in "change" mode, back up 30 s after the last
/// write (and never sooner than 5 min after the previous backup).
fn wrote(app: &AppHandle) {
    let state = app.state::<AppState>();
    let s = settings_of(&state);
    if s.interval() != "change" || s.backup_dir.is_none() {
        return;
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
                    std::thread::sleep(dl - now);
                    continue;
                }
                let last = settings_of(&state).last_backup;
                if let Some(age) = last.as_deref().and_then(secs_since) {
                    if (0..300).contains(&age) {
                        std::thread::sleep(Duration::from_secs((300 - age) as u64));
                        continue;
                    }
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
                    Ok(p) => BackupEvent { ok: true, path: Some(p), error: None },
                    Err(e) => BackupEvent { ok: false, path: None, error: Some(e) },
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
    };
    if missing {
        return Ok(snap);
    }
    let (entries, templates, searches, has_transfer, conflicts, saved, migration) = blocking(move || {
        let j = Journal::open(&r);
        // An inbox.md left by jnl or Nook is folded into inbox/ first, so the
        // load below sees one inbox. Failure is reported, never fatal: the
        // file is still read in place.
        let migration = j.migrate_legacy_inbox();
        Ok((j.load_all(), list_templates(&j), load_searches(&j), !j.read("transfer.md").trim().is_empty(), j.conflict_files(), media::data_saved_total(&r), migration))
    })
    .await?;
    match migration {
        Ok(m) => snap.migration = m,
        Err(e) => snap.migration_error = Some(e),
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
fn set_folder(state: State<AppState>, path: String) -> Result<(), String> {
    let path = path.trim().to_string();
    let p = PathBuf::from(expand_home(&path));
    if !p.is_dir() {
        return Err(format!("Not a folder: {}", path));
    }
    update_settings(&state, |s| s.folder = Some(p.display().to_string()))?;
    sweep_in_background(p);
    Ok(())
}

#[tauri::command]
fn use_sample(state: State<AppState>) -> Result<(), String> {
    let p = state.sample_dir.clone();
    let _ = fs::create_dir_all(&p);
    update_settings(&state, |s| s.folder = Some(p.display().to_string()))?;
    sweep_in_background(p);
    Ok(())
}

#[tauri::command]
fn save_ui(state: State<AppState>, ui: Value) -> Result<(), String> {
    update_settings(&state, |s| s.ui = ui)
}

/// New draft → its day's file under inbox/, in time order.
#[tauri::command]
fn create_draft(app: AppHandle, state: State<AppState>, ts: String, title: String, starred: bool, body: String) -> Result<Written, String> {
    let w = root(&state)?.new_draft(&ts, &title, starred, &body)?;
    wrote(&app);
    Ok(w)
}

/// Edit any entry in place. An entry in a day file whose date changes moves
/// to the new day's file (inbox or journal), kept in time order. A
/// split-journal entry stays in its file.
#[tauri::command]
#[allow(clippy::too_many_arguments)]
fn update_entry(
    app: AppHandle,
    state: State<AppState>,
    file: String,
    index: usize,
    expected_raw: String,
    ts: String,
    title: String,
    starred: bool,
    body: String,
) -> Result<Written, String> {
    let w = root(&state)?.update_entry(&file, index, &expected_raw, &ts, &title, starred, &body)?;
    wrote(&app);
    Ok(w)
}

#[tauri::command]
fn delete_entry(app: AppHandle, state: State<AppState>, file: String, index: usize, expected_raw: String) -> Result<(), String> {
    root(&state)?.delete_entry(&file, index, &expected_raw)?;
    wrote(&app);
    Ok(())
}

/// File a draft: jnl's fileDraft (split tags first, else the day file,
/// appended), then remove it from its inbox file. Returns where it went.
#[tauri::command]
fn file_draft(app: AppHandle, state: State<AppState>, file: String, index: usize, expected_raw: String) -> Result<String, String> {
    let target = root(&state)?.file_draft(&file, index, &expected_raw, &split_tags_of(&state))?;
    wrote(&app);
    Ok(target)
}

/// Nook's "Return to Inbox": move a filed entry back to the queue, into the
/// inbox day file of its own date.
#[tauri::command]
fn unfile_entry(app: AppHandle, state: State<AppState>, file: String, index: usize, expected_raw: String) -> Result<Written, String> {
    let w = root(&state)?.unfile_entry(&file, index, &expected_raw)?;
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
fn new_template(app: AppHandle, state: State<AppState>) -> Result<String, String> {
    let r = root(&state)?;
    let taken: Vec<String> = list_templates(&r).into_iter().map(|t| t.name).collect();
    let mut name = "New template".to_string();
    let mut n = 2;
    while taken.contains(&name) {
        name = format!("New template {}", n);
        n += 1;
    }
    save_template(&r, &name, STARTER_TEMPLATE)?;
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

#[tauri::command]
async fn assets(state: State<'_, AppState>) -> Result<Vec<Asset>, String> {
    let r = root_r(&state)?;
    blocking(move || list_assets(&r)).await
}

#[tauri::command]
fn asset_path(state: State<AppState>, rel: String) -> Result<String, String> {
    let p = safe_rel(root_r(&state)?.root(), &rel)?;
    if !p.exists() {
        return Err("No such asset".into());
    }
    Ok(p.display().to_string())
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
fn attach_file(app: AppHandle, state: State<AppState>, src: String, ts: String, entry_file: String) -> Result<String, String> {
    let r = root(&state)?;
    let src = PathBuf::from(&src);
    let ext = src.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
    let link = if media::is_heic(&ext) || media::is_compressible_image(&ext) {
        let bytes = fs::read(&src).map_err(|e| format!("Can't read {}: {}", src.display(), e))?;
        attach_prepared(&app, &state, &r, &bytes, &ext, &ts, &entry_file)?
    } else {
        let link = attach(&r, &src, &ts, &entry_file)?;
        after_attach(&app, &state, r.root(), &link, None);
        link
    };
    wrote(&app);
    Ok(link)
}

/// Images and HEIC go through Data Saver / HEIC→JPEG in memory first.
fn attach_prepared(app: &AppHandle, state: &AppState, r: &Journal, bytes: &[u8], ext: &str, ts: &str, entry_file: &str) -> Result<String, String> {
    let saver = settings_of(state).data_saver;
    let (out, out_ext) = media::on_attach(bytes, ext, saver);
    let saved = bytes.len() as i64 - out.len() as i64;
    let tmp = tempfile::Builder::new().prefix(".quire-attach-").suffix(&format!(".{}", out_ext.to_lowercase())).tempfile().map_err(|e| e.to_string())?;
    fs::write(tmp.path(), &out).map_err(|e| e.to_string())?;
    let link = attach(r, tmp.path(), ts, entry_file)?;
    after_attach(app, state, r.root(), &link, if saver { Some(saved.max(0)) } else { None });
    Ok(link)
}

/// Ledger bookkeeping for a fresh attachment, and background video/audio
/// compression when Data Saver is on (one at a time, like Nook's serial queue).
fn after_attach(app: &AppHandle, state: &AppState, r: &Path, link: &str, image_saved: Option<i64>) {
    let Some(rel) = link.rsplit_once("](").map(|(_, t)| t.trim_end_matches(')').to_string()) else { return };
    let s = settings_of(state);
    let device = device_id(state);
    let path = r.join(&rel);
    if let Some(saved) = image_saved {
        record_saving(r, &device, &path, saved);
        return;
    }
    let ext = path.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
    if !s.data_saver || !media::is_compressible_av(&ext) || !media::tools().ffmpeg {
        return;
    }
    let (app, r) = (app.clone(), r.to_path_buf());
    std::thread::spawn(move || {
        static QUEUE: Mutex<()> = Mutex::new(());
        let _g = QUEUE.lock().unwrap_or_else(|p| p.into_inner());
        if let Ok(res) = media::compress_file_in_place(&path) {
            let saved = res.unwrap_or(0);
            record_saving(&r, &device, &path, saved);
            let _ = app.emit("media-compressed", serde_json::json!({ "rel": rel, "saved": saved }));
        }
    });
}

fn record_saving(r: &Path, device: &str, path: &Path, saved: i64) {
    let Some(id) = media::asset_id(r, path) else { return };
    let mut l = media::read_ledger(r, device);
    if !l.assets.contains(&id) {
        l.assets.push(id);
        l.saved_bytes += saved.max(0);
        let _ = media::write_ledger(r, device, &l);
    }
}

fn device_id(state: &AppState) -> String {
    if let Some(id) = settings_of(state).device_id {
        return id;
    }
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let id = format!("{:016x}{:08x}", nanos as u64, std::process::id()).to_uppercase();
    let _ = update_settings(state, |s| s.device_id = Some(id.clone()));
    id
}

/// Native clipboard-image paste: WebKitGTK often doesn't hand images to the
/// page's paste event on Linux. Returns the link, or None if the clipboard has
/// no image. Opaque images become JPEG (q92), others PNG; then the usual
/// Data Saver / attach path.
#[tauri::command]
fn paste_image(app: AppHandle, state: State<AppState>, ts: String, entry_file: String) -> Result<Option<String>, String> {
    let r = root(&state)?;
    check_ts(&ts)?;
    let img = match arboard::Clipboard::new().and_then(|mut c| c.get_image()) {
        Ok(i) => i,
        Err(_) => return Ok(None),
    };
    let (w, h) = (img.width as u32, img.height as u32);
    let rgba = image::RgbaImage::from_raw(w, h, img.bytes.into_owned()).ok_or("Clipboard image was malformed")?;
    let opaque = rgba.pixels().all(|p| p.0[3] == 255);
    let mut out = std::io::Cursor::new(Vec::new());
    let ext = if opaque {
        let rgb = image::DynamicImage::ImageRgba8(rgba).to_rgb8();
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 92).encode_image(&rgb).map_err(|e| e.to_string())?;
        "jpg"
    } else {
        image::DynamicImage::ImageRgba8(rgba).write_to(&mut out, image::ImageFormat::Png).map_err(|e| e.to_string())?;
        "png"
    };
    let link = attach_prepared(&app, &state, &r, &out.into_inner(), ext, &ts, &entry_file)?;
    wrote(&app);
    Ok(Some(link))
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
fn attach_bytes(app: AppHandle, state: State<AppState>, name: String, bytes_b64: String, ts: String, entry_file: String) -> Result<String, String> {
    let r = root(&state)?;
    check_ts(&ts)?;
    let b64 = bytes_b64.split_once(";base64,").map(|(_, b)| b).unwrap_or(&bytes_b64);
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64.trim()).map_err(|e| format!("Bad base64: {}", e))?;
    if bytes.is_empty() {
        return Err("Nothing to attach".into());
    }
    let ext = Path::new(name.trim())
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .filter(|e| !e.is_empty() && e.chars().all(|c| c.is_ascii_alphanumeric()))
        .unwrap_or_else(|| "png".into());
    let link = if media::is_heic(&ext) || media::is_compressible_image(&ext) {
        attach_prepared(&app, &state, &r, &bytes, &ext, &ts, &entry_file)?
    } else {
        let tmp = tempfile::Builder::new().prefix(".quire-paste-").suffix(&format!(".{}", ext)).tempfile().map_err(|e| e.to_string())?;
        fs::write(tmp.path(), &bytes).map_err(|e| e.to_string())?;
        let link = attach(&r, tmp.path(), &ts, &entry_file)?;
        after_attach(&app, &state, r.root(), &link, None);
        link
    };
    wrote(&app);
    Ok(link)
}

#[tauri::command]
async fn orphan_count(state: State<'_, AppState>) -> Result<usize, String> {
    let r = root_r(&state)?;
    blocking(move || Ok(list_assets(&r)?.into_iter().filter(|a| !a.referenced).count())).await
}

#[tauri::command]
async fn clear_orphans(app: AppHandle, state: State<'_, AppState>) -> Result<usize, String> {
    let r = root(&state)?;
    let n = blocking(move || delete_orphans(&r)).await?;
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
    if rep.formatted + rep.reordered + rep.deduped + rep.extracted > 0 {
        wrote(&app);
    }
    Ok(rep)
}

#[tauri::command]
fn sort_inbox_cmd(app: AppHandle, state: State<AppState>) -> Result<bool, String> {
    let changed = sort_inbox(&root(&state)?)?;
    if changed {
        wrote(&app);
    }
    Ok(changed)
}

#[tauri::command]
async fn export_cmd(state: State<'_, AppState>, dest: String) -> Result<usize, String> {
    let r = root_r(&state)?;
    blocking(move || export_all(&r, Path::new(&dest))).await
}

#[tauri::command]
async fn backup_now(app: AppHandle) -> Result<String, String> {
    let a = app.clone();
    blocking(move || run_backup(&a)).await
}

/// Called on launch and window focus: runs a daily/weekly backup if one is
/// due. Returns the new backup's path, or null if none was due/possible.
#[tauri::command]
async fn maybe_backup(app: AppHandle) -> Result<Option<String>, String> {
    let s = settings_of(&app.state::<AppState>());
    if s.backup_dir.is_none() || !backup_due(&s.interval(), s.last_backup.as_deref()) || BACKUP_RUNNING.load(Ordering::SeqCst) {
        return Ok(None);
    }
    if root(&app.state::<AppState>()).is_err() {
        return Ok(None);
    }
    let a = app.clone();
    blocking(move || run_backup(&a)).await.map(Some)
}

#[tauri::command]
fn backups(state: State<AppState>) -> Result<Vec<String>, String> {
    let dir = settings_of(&state).backup_dir;
    Ok(dir.map(|d| list_backups(Path::new(&d))).unwrap_or_default())
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
    let rep = blocking(move || import_markdown_folder(&r, Path::new(&dir), dry_run)).await?;
    if !dry_run && rep.written > 0 {
        wrote(&app);
    }
    Ok(rep)
}

#[tauri::command]
async fn import_dayone(app: AppHandle, state: State<'_, AppState>, path: String, dry_run: bool) -> Result<ImportReport, String> {
    let r = root(&state)?;
    let rep = blocking(move || import_day_one(&r, Path::new(&path), dry_run)).await?;
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
fn import_text(app: AppHandle, state: State<AppState>, text: String, now_ts: String) -> Result<usize, String> {
    let n = root(&state)?.import_text(&text, &now_ts)?;
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

#[tauri::command]
fn pin_hash(pin: String) -> String {
    hash_pin(&pin)
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
    std::thread::spawn(move || loop {
        let first = match rx.recv() {
            Ok(ev) => ev,
            Err(_) => break, // watcher dropped
        };
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
    });
    Ok(watcher)
}

#[tauri::command]
fn rewatch(app: AppHandle, state: State<AppState>) -> Result<(), String> {
    let w = start_watcher(app, root_r(&state)?.root().to_path_buf())?;
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

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let data = app.path().app_data_dir()?;
            let sample_dir = data.join("sample-journal");
            if !sample_dir.exists() {
                if let Ok(res) = app.path().resolve("sample", tauri::path::BaseDirectory::Resource) {
                    let _ = copy_dir(&res, &sample_dir);
                }
                let _ = fs::create_dir_all(&sample_dir);
            }
            let mut settings = Settings::load();
            let mut dirty = settings.migrate();
            // Only an unset folder falls back to the sample. A configured
            // folder that's missing stays configured (folder_missing).
            if settings.folder.is_none() {
                settings.folder = Some(sample_dir.display().to_string());
                dirty = true;
            }
            if dirty {
                let _ = save_settings(&settings);
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
                sweep_in_background(f);
            }
            app.manage(AppState {
                settings: Mutex::new(settings),
                sample_dir,
                watcher: Mutex::new(watcher),
                backup_deadline: Mutex::new(None),
                scheduler_running: AtomicBool::new(false),
            });
            Ok(())
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
            asset_path,
            delete_asset,
            attach_file,
            attach_bytes,
            orphan_count,
            clear_orphans,
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
            pin_hash,
            rewatch,
            undecorated,
            set_system_titlebar
        ])
        .run(tauri::generate_context!())
        .expect("error while running Quire");
}
