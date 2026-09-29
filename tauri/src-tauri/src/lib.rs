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
    // The lock only ever guards a clone and an assignment, neither of which can
    // panic; if it were poisoned anyway, the path inside is still good.
    let base = state.base.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let library = Library::new(base);
    library.ensure();
    library
}

/// The file the webview named, if it is one this library may write.
fn owned(library: &Library, source: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(source);
    if library.owns(&path) {
        Ok(path)
    } else {
        Err("That file isn't in the journal folder.".to_string())
    }
}

/// A stamp from the webview, checked before it can name a file or a header.
fn checked(ts: &str) -> Result<&str, String> {
    journal::stamp_date(ts).ok_or_else(|| format!("\"{}\" isn't a timestamp", ts))
}

// Every command that touches the disk is `async` in Tauri's sense: it runs on a
// worker thread, not the one the window is drawn on, so reading ten years of
// journal doesn't freeze the page while it happens.

#[tauri::command(async)]
fn load(state: tauri::State<State>) -> Journal {
    let library = library(&state);
    Journal {
        base: library.base.to_string_lossy().to_string(),
        entries: library.load(),
    }
}

/// A blank entry, stamped now, waiting in the inbox — new writing rarely
/// belongs to a day on the spot, so filing it is left to the writer.
#[tauri::command(async)]
fn create(state: tauri::State<State>) -> Result<Entry, String> {
    let library = library(&state);
    let stamp = Local::now().format(journal::STAMP).to_string();
    let target = library.inbox();
    let free = library.free_stamp(&stamp, &target, None)?;
    Ok(library.compose(&free, "", "", false, &target))
}

#[tauri::command(async)]
fn save(
    state: tauri::State<State>,
    ts: String,
    source: String,
    title: String,
    body: String,
    starred: bool,
) -> Result<Option<Entry>, String> {
    let library = library(&state);
    checked(&ts)?;
    let target = owned(&library, &source)?;
    let entry = library.compose(&ts, &title, &body, starred, &target);
    // An entry with neither title nor body is never left on disk.
    if entry.suffix.is_empty() && entry.body.is_empty() {
        library.remove(&entry)?;
        return Ok(None);
    }
    library.persist(&entry).map(Some)
}

#[tauri::command(async)]
fn remove(state: tauri::State<State>, ts: String, source: String) -> Result<(), String> {
    let library = library(&state);
    checked(&ts)?;
    let target = owned(&library, &source)?;
    let entry = library.compose(&ts, "", "", false, &target);
    library.remove(&entry)
}

/// Move an entry to another file and/or another timestamp — the one primitive
/// behind retiming, filing and unfiling.
#[tauri::command(async)]
fn relocate(
    state: tauri::State<State>,
    ts: String,
    source: String,
    new_ts: Option<String>,
    to_inbox: Option<bool>,
) -> Result<Entry, String> {
    let library = library(&state);
    checked(&ts)?;
    let from = owned(&library, &source)?;
    // Only the file that owns the entry, not the whole folder: relocating one
    // entry has no business parsing ten years of journal to find it.
    let existing = library.find(&from, &ts)?;

    let stamp = new_ts.unwrap_or_else(|| existing.ts.clone());
    let date = checked(&stamp)?;
    let dated = || library.day_file(date).ok_or_else(|| "bad date".to_string());
    let target = match to_inbox {
        Some(true) => library.inbox(),
        Some(false) => dated()?,
        // Retiming keeps a draft in the inbox: inbox.md isn't dated, so a new
        // date must not quietly file it.
        None if existing.unfiled => library.inbox(),
        None => dated()?,
    };

    let free = library.free_stamp(&stamp, &target, Some(&existing.ts))?;
    let moved = library.compose(&free, &existing.title, &existing.body, existing.starred, &target);
    // An entry with neither title nor body is never written: moving an untouched
    // new entry to another day must not leave a stub behind.
    let blank = moved.suffix.is_empty() && moved.body.is_empty();

    // Within one file it is a single rewrite: out under the old stamp, in under
    // the new, with no moment at which the entry is in neither.
    if from == target {
        library.rewrite(&target, Some(&existing.ts), (!blank).then_some(&moved))?;
        return Ok(moved);
    }
    // Across files the destination is written first. If taking it out of the
    // source then fails, the entry is in both — a duplicate the reader can
    // delete, where the other order would leave it in neither.
    if !blank {
        library.persist(&moved)?;
    }
    library.remove(&existing).map_err(|e| {
        format!(
            "The entry was written to {} but couldn't be taken out of {}, so it is now in both: {}",
            target.display(),
            from.display(),
            e
        )
    })?;
    Ok(moved)
}

#[tauri::command(async)]
fn set_folder(state: tauri::State<State>, path: String) -> Journal {
    {
        let mut base = state.base.lock().unwrap_or_else(|e| e.into_inner());
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

/// Hand WebKit a .woff and its web process spins at 100% of a core, paints
/// nothing, and says nothing: the window opens blank and stays that way. WOFF
/// is a web format that has no business on the system font path, but some
/// distributions put it there anyway — Zorin's `fonts-opendyslexic` installs
/// four alongside the .otf copies of the same faces — and that takes down every
/// WebKit app on the machine, this one included.
///
/// So the font path is checked, and if any are found the app runs against a
/// fontconfig of its own that keeps the system's and drops the web fonts. The
/// .otf copies are untouched, so nothing is actually lost. Fontconfig is read
/// when GTK starts, so this has to happen before the builder runs.
#[cfg(target_os = "linux")]
fn reject_woff_system_fonts() {
    const SYSTEM: &str = "/etc/fonts/fonts.conf";
    // Anyone who has pointed FONTCONFIG_FILE somewhere themselves means it.
    if std::env::var_os("FONTCONFIG_FILE").is_some() || !std::path::Path::new(SYSTEM).exists() {
        return;
    }
    let offenders = woff_on_font_path();
    if offenders.is_empty() {
        return;
    }
    let Some(dir) = journal::config_file().parent().map(|p| p.to_path_buf()) else {
        return;
    };
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    // A glob is matched from the start of the path, so each file is named in
    // full: `*.woff` matches nothing.
    let globs = offenders
        .iter()
        .map(|path| format!("      <glob>{}</glob>\n", xml_escape(path)))
        .collect::<String>();
    let file = dir.join("fonts.conf");
    let config = format!(
        r#"<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <include>{SYSTEM}</include>
  <selectfont>
    <rejectfont>
{globs}    </rejectfont>
  </selectfont>
</fontconfig>
"#
    );
    if std::fs::write(&file, config).is_ok() {
        std::env::set_var("FONTCONFIG_FILE", &file);
    }
}

#[cfg(target_os = "linux")]
fn woff_on_font_path() -> Vec<String> {
    let mut roots = vec![
        PathBuf::from("/usr/share/fonts"),
        PathBuf::from("/usr/local/share/fonts"),
    ];
    if let Ok(home) = std::env::var("HOME") {
        roots.push(PathBuf::from(&home).join(".local/share/fonts"));
        roots.push(PathBuf::from(&home).join(".fonts"));
    }
    roots
        .iter()
        .flat_map(|root| walkdir::WalkDir::new(root).into_iter().filter_map(Result::ok))
        .filter(|entry| {
            entry
                .path()
                .extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| {
                    ext.eq_ignore_ascii_case("woff") || ext.eq_ignore_ascii_case("woff2")
                })
        })
        .map(|entry| entry.path().to_string_lossy().into_owned())
        .collect()
}

#[cfg(target_os = "linux")]
fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    #[cfg(target_os = "linux")]
    reject_woff_system_fonts();
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
