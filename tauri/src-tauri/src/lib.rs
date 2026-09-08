//! wander — the Tauri build.
//!
//! The window is the same journal the macOS app opens: the commands here are
//! the file half, and the look lives in `../src`. Every write goes through
//! `journal::Library`, so the folder stays jnl-compatible.

mod journal;

use journal::{Entry, Library};
use tauri::Manager;
use chrono::Local;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::Mutex;

struct State {
    base: Mutex<PathBuf>,
}

#[derive(Serialize)]
struct Journal {
    base: String,
    entries: Vec<Entry>,
}

fn library(state: &tauri::State<State>) -> Library {
    let base = state.base.lock().unwrap().clone();
    let library = Library::new(base);
    library.ensure();
    library
}

#[tauri::command]
fn load(state: tauri::State<State>) -> Journal {
    let library = library(&state);
    Journal {
        base: library.base.to_string_lossy().to_string(),
        entries: library.load(),
    }
}

/// A blank entry, stamped now — in a day file, or in the inbox when it's a draft.
#[tauri::command]
fn create(state: tauri::State<State>, draft: bool) -> Result<Entry, String> {
    let library = library(&state);
    let stamp = Local::now().format(journal::STAMP).to_string();
    let target = if draft {
        library.inbox()
    } else {
        library
            .day_file(&stamp[..10])
            .ok_or_else(|| "bad date".to_string())?
    };
    let free = library.free_stamp(&stamp, &target, None);
    Ok(library.compose(&free, "", "", false, &target))
}

#[tauri::command]
fn save(
    state: tauri::State<State>,
    ts: String,
    source: String,
    title: String,
    body: String,
    starred: bool,
) -> Result<Option<Entry>, String> {
    let library = library(&state);
    let target = PathBuf::from(&source);
    let entry = library.compose(&ts, &title, &body, starred, &target);
    // An entry with neither title nor body is never left on disk.
    if entry.suffix.is_empty() && entry.body.is_empty() {
        library.remove(&entry).map_err(|e| e.to_string())?;
        return Ok(None);
    }
    library.persist(&entry).map(Some).map_err(|e| e.to_string())
}

#[tauri::command]
fn remove(state: tauri::State<State>, ts: String, source: String) -> Result<(), String> {
    let library = library(&state);
    let target = PathBuf::from(&source);
    let entry = library.compose(&ts, "", "", false, &target);
    library.remove(&entry).map_err(|e| e.to_string())
}

/// Move an entry to another file and/or another timestamp — the one primitive
/// behind retiming, filing and unfiling.
#[tauri::command]
fn relocate(
    state: tauri::State<State>,
    ts: String,
    source: String,
    new_ts: Option<String>,
    to_inbox: Option<bool>,
) -> Result<Entry, String> {
    let library = library(&state);
    let from = PathBuf::from(&source);
    let existing = library
        .load()
        .into_iter()
        .find(|e| e.ts == ts && e.source == source)
        .ok_or_else(|| "entry not found".to_string())?;

    let stamp = new_ts.unwrap_or_else(|| existing.ts.clone());
    let target = match to_inbox {
        Some(true) => library.inbox(),
        Some(false) => library
            .day_file(&stamp[..10])
            .ok_or_else(|| "bad date".to_string())?,
        // Retiming keeps a draft in the inbox: inbox.md isn't dated, so a new
        // date must not quietly file it.
        None => {
            if existing.unfiled {
                library.inbox()
            } else {
                library
                    .day_file(&stamp[..10])
                    .ok_or_else(|| "bad date".to_string())?
            }
        }
    };

    let free = library.free_stamp(&stamp, &target, Some(&existing.ts));
    let moved = library.compose(&free, &existing.title, &existing.body, existing.starred, &target);
    if from != target || free != existing.ts {
        library.remove(&existing).map_err(|e| e.to_string())?;
    }
    // An entry with neither title nor body is never written: moving an untouched
    // new entry to another day must not leave a stub behind.
    if moved.suffix.is_empty() && moved.body.is_empty() {
        return Ok(moved);
    }
    library.persist(&moved).map_err(|e| e.to_string())
}

#[tauri::command]
fn set_folder(state: tauri::State<State>, path: String) -> Journal {
    {
        let mut base = state.base.lock().unwrap();
        *base = PathBuf::from(&path);
    }
    // Remembered for next launch, the way the Apple builds remember theirs.
    journal::remember_folder(&PathBuf::from(&path));
    load(state)
}

/// Whether the window is drawing its own chrome. The macOS build keeps the
/// system title bar — its traffic lights are better than anything drawn here —
/// while Linux and Windows go borderless, so the masthead is the only bar.
/// `WANDER_DECORATIONS=0` or `=1` overrides either way.
fn hides_decorations() -> bool {
    match std::env::var("WANDER_DECORATIONS").as_deref() {
        Ok("0") => true,
        Ok("1") => false,
        _ => !cfg!(target_os = "macos"),
    }
}

#[tauri::command]
fn undecorated() -> bool {
    hides_decorations()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // A folder named on the command line wins; then the one last chosen in the
    // app; then $JNL_DIR; then ~/Documents/Wander.
    let base = journal::resolve_base(
        std::env::args().nth(1).or_else(journal::remembered_folder),
    );
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(State {
            base: Mutex::new(base),
        })
        .setup(|app| {
            if hides_decorations() {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.set_decorations(false);
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            load, create, save, remove, relocate, set_folder, undecorated
        ])
        .run(tauri::generate_context!())
        .expect("error while running wander");
}
