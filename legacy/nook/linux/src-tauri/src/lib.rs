//! Tauri command layer — thin wrappers over `store::Store`, plus native folder/
//! file/save dialogs and reveal-in-file-manager (done Rust-side so the frontend
//! needs no plugin JS bindings). Every command resolves the journal base fresh.

mod media;
mod parser;
mod search;
mod store;

use parser::Entry;
use serde_json::{json, Value};
use store::{
    resolve_store, AssetItem, CleanupResult, DatedEntry, MediaCompressionResult, MergeResult,
    Snapshot, Source, SourcedEntry, Stats, TagGroup,
};
use tauri::{Emitter, Manager};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;

/// Let the webview's `asset:` protocol read the journal folder — and nothing
/// else. `tauri.conf.json` ships an empty scope, so the only readable paths are
/// the ones added here; the base can change at runtime (Settings → Choose
/// Folder), hence a function rather than a static config glob.
fn allow_base_asset_access(app: &tauri::AppHandle) {
    let _ = app
        .asset_protocol_scope()
        .allow_directory(&resolve_store().base, true);
}

// ---- Preferences ----

#[tauri::command]
fn get_prefs() -> Value {
    store::read_prefs()
}

#[tauri::command]
fn set_pref(key: String, value: Value) {
    store::set_pref(&key, value);
}

#[tauri::command]
fn now_ts() -> String {
    store::now_ts()
}

// ---- Snapshot / loading ----

/// Run a whole-corpus job on a worker thread. A synchronous Tauri command runs
/// on the GTK main thread, so anything that walks or rewrites every journal
/// file froze the window while it worked.
async fn off_main<T, F>(job: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    tauri::async_runtime::spawn_blocking(job)
        .await
        .map_err(|_| "That job stopped unexpectedly.".to_string())
}

#[tauri::command]
async fn reload() -> Result<Snapshot, String> {
    off_main(|| resolve_store().snapshot()).await
}

#[tauri::command]
fn entries_for_day(date: String) -> Vec<Entry> {
    resolve_store().entries_for_day(&date)
}

#[tauri::command]
fn all_entries_by_day() -> Vec<Value> {
    resolve_store().all_entries_by_day()
}

#[tauri::command]
fn entries_tagged_with(name: String) -> Vec<DatedEntry> {
    resolve_store().entries_tagged_with(&name)
}

#[tauri::command]
fn entries_in_journal(name: String) -> Vec<Entry> {
    resolve_store().entries_in_journal(&name)
}

#[tauri::command]
fn starred_entries() -> Vec<SourcedEntry> {
    resolve_store().starred_entries()
}

#[tauri::command]
fn search(query: String) -> Vec<DatedEntry> {
    resolve_store().search(&query)
}

#[tauri::command]
fn global_search(query: String) -> Vec<SourcedEntry> {
    resolve_store().global_search(&query)
}

#[tauri::command]
fn saved_searches() -> Value {
    resolve_store().saved_searches()
}

#[tauri::command]
fn add_saved_search(name: String, query: String) {
    resolve_store().add_saved_search(&name, &query);
}

#[tauri::command]
fn remove_saved_search(name: String) {
    resolve_store().remove_saved_search(&name);
}

#[tauri::command]
fn on_this_day() -> Vec<Value> {
    resolve_store().on_this_day()
}

#[tauri::command]
fn year_review(year: String) -> Value {
    resolve_store().year_review(&year)
}

#[tauri::command]
fn years_with_entries() -> Vec<String> {
    resolve_store().years_with_entries()
}

// ---- Templates ----

#[tauri::command]
fn template_names() -> Vec<String> {
    resolve_store().template_names()
}

#[tauri::command]
fn template_body(name: String) -> Option<String> {
    resolve_store().template_body(&name)
}

#[tauri::command]
fn create_template() -> Option<String> {
    resolve_store().create_template()
}

#[tauri::command]
fn delete_template(name: String) {
    resolve_store().delete_template(&name);
}

#[tauri::command]
fn random_entry() -> Option<DatedEntry> {
    resolve_store().random_entry()
}

// ---- Composer / drafts ----

#[tauri::command]
fn upsert_draft(
    previous: Option<String>,
    timestamp: String,
    title: String,
    body: String,
) -> Result<Option<String>, String> {
    resolve_store().upsert_draft(previous.as_deref(), &timestamp, &title, &body)
}

#[tauri::command]
fn remove_draft(timestamp: String) -> Result<(), String> {
    resolve_store().remove_draft(&timestamp)
}

#[tauri::command]
fn update_draft(ts: String, raw: String, new_text: String) -> Result<(), String> {
    resolve_store().update_draft(&ts, &raw, &new_text)
}

#[tauri::command]
fn delete_draft(ts: String, raw: String) -> Result<(), String> {
    resolve_store().delete_draft(&ts, &raw)
}

#[tauri::command]
fn import_drafts(text: String) -> Result<usize, String> {
    resolve_store().import_drafts(&text)
}

#[tauri::command]
fn sort_inbox() -> Result<(), String> {
    resolve_store().sort_inbox()
}

#[tauri::command]
fn file_draft(ts: String, raw: String) -> Result<Option<String>, String> {
    resolve_store().file_draft(&ts, &raw)
}

#[tauri::command]
fn return_to_inbox(source: Source, ts: String, raw: String) -> bool {
    resolve_store().return_to_inbox(&source, &ts, &raw)
}

#[tauri::command]
async fn file_all_drafts() -> Result<usize, String> {
    off_main(|| resolve_store().file_all_drafts()).await?
}

// ---- Filed / journal editing ----

#[tauri::command]
fn update_filed_entry(
    date: String,
    ts: String,
    raw: String,
    new_text: String,
) -> Result<(), String> {
    resolve_store().update_filed_entry(&date, &ts, &raw, &new_text)
}

#[tauri::command]
fn delete_filed_entry(date: String, ts: String, raw: String) -> Result<(), String> {
    resolve_store().delete_filed_entry(&date, &ts, &raw)
}

#[tauri::command]
fn update_journal_entry(
    name: String,
    ts: String,
    raw: String,
    new_text: String,
) -> Result<(), String> {
    resolve_store().update_journal_entry(&name, &ts, &raw, &new_text)
}

#[tauri::command]
fn delete_journal_entry(name: String, ts: String, raw: String) -> Result<(), String> {
    resolve_store().delete_journal_entry(&name, &ts, &raw)
}

#[tauri::command]
fn toggle_star(source: Source, ts: String, raw: String) -> Result<(), String> {
    resolve_store().toggle_star(&source, &ts, &raw)
}

// ---- Tags ----

#[tauri::command]
async fn rename_tag(old: String, new: String) -> Result<usize, String> {
    off_main(move || resolve_store().rename_tag(&old, &new)).await?
}

#[tauri::command]
async fn merge_tags(pairs: Vec<(String, String)>) -> Result<(), String> {
    off_main(move || resolve_store().merge_tags(&pairs)).await?
}

#[tauri::command]
fn similar_tag_groups() -> Vec<TagGroup> {
    resolve_store().similar_tag_groups()
}

#[tauri::command]
fn ignore_tag_group(id: String) {
    resolve_store().ignore_tag_group(&id);
}

// ---- Assets ----

#[tauri::command]
fn all_assets() -> Vec<AssetItem> {
    resolve_store().all_assets()
}

#[tauri::command]
fn delete_asset(rel: String) {
    resolve_store().delete_asset(&rel);
}

#[tauri::command]
fn assets_bytes() -> u64 {
    resolve_store().assets_bytes()
}

#[tauri::command]
fn orphan_assets() -> Vec<String> {
    resolve_store().orphan_assets()
}

#[tauri::command]
fn delete_orphan_assets() -> usize {
    resolve_store().delete_orphan_assets()
}

#[tauri::command]
fn asset_usages(file_name: String) -> Vec<SourcedEntry> {
    resolve_store().asset_usages(&file_name)
}

#[tauri::command]
fn asset_abs(rel: String) -> String {
    resolve_store().asset_abs(&rel)
}

/// Media captured in the webview (audio/video recordings) arrives as the raw
/// request body, not as JSON. A ten-megabyte take used to cross the IPC bridge
/// as a JSON array of ten million integers — tens of megabytes of text to
/// serialise and parse, which stalled the window for seconds.
#[tauri::command]
fn save_asset(request: tauri::ipc::Request<'_>) -> Result<Option<String>, String> {
    let tauri::ipc::InvokeBody::Raw(bytes) = request.body() else {
        return Err("Expected the recording's bytes as the request body.".into());
    };
    let ext = request
        .headers()
        .get("ext")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("bin")
        .to_string();
    Ok(resolve_store().save_asset(bytes, &ext))
}

#[tauri::command]
fn import_asset(src: String) -> Option<String> {
    resolve_store().import_asset(&src)
}

#[tauri::command]
fn total_data_saved() -> u64 {
    resolve_store().total_data_saved()
}

#[tauri::command]
async fn compress_existing_media(app: tauri::AppHandle) -> MediaCompressionResult {
    tauri::async_runtime::spawn_blocking(move || {
        resolve_store().compress_existing_media(|done, total| {
            let _ = app.emit("media-progress", json!({ "done": done, "total": total }));
        })
    })
    .await
    .unwrap_or_default()
}

// ---- Stats / cleanup / export ----

#[tauri::command]
fn stats() -> Stats {
    resolve_store().stats()
}

#[tauri::command]
async fn cleanup() -> Result<CleanupResult, String> {
    off_main(|| resolve_store().cleanup()).await?
}

#[tauri::command]
async fn merge_ex_split_journals() -> Result<MergeResult, String> {
    off_main(|| resolve_store().merge_ex_split_journals()).await?
}

#[tauri::command]
fn export_markdown() -> String {
    resolve_store().export_markdown()
}

// ---- Folder / backup / dialogs / reveal ----

#[tauri::command]
async fn pick_journal_folder(app: tauri::AppHandle) -> Option<Snapshot> {
    let (tx, mut rx) = tauri::async_runtime::channel(1);
    app.dialog().file().pick_folder(move |f| {
        let _ = tx.blocking_send(f);
    });
    let folder = rx.recv().await.flatten()?;
    let path = folder.into_path().ok()?;
    store::set_pref("customFolder", json!(path.to_string_lossy()));
    let snap = off_main(|| resolve_store().snapshot()).await.ok()?;
    allow_base_asset_access(&app);
    Some(snap)
}

#[tauri::command]
async fn use_default_folder(app: tauri::AppHandle) -> Result<Snapshot, String> {
    store::set_pref("customFolder", Value::Null);
    let snap = off_main(|| resolve_store().snapshot()).await?;
    allow_base_asset_access(&app);
    Ok(snap)
}

#[tauri::command]
async fn pick_backup_folder(app: tauri::AppHandle) -> Option<String> {
    let (tx, mut rx) = tauri::async_runtime::channel(1);
    app.dialog().file().pick_folder(move |f| {
        let _ = tx.blocking_send(f);
    });
    let folder = rx.recv().await.flatten()?;
    let path = folder.into_path().ok()?;
    store::set_pref("backupFolder", json!(path.to_string_lossy()));
    Some(path.to_string_lossy().to_string())
}

#[tauri::command]
fn backup_folder_info() -> Value {
    match store::read_prefs().get("backupFolder").and_then(|v| v.as_str()) {
        Some(p) if !p.is_empty() => {
            let name = std::path::Path::new(p)
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or(p)
                .to_string();
            json!({ "name": name, "path": p })
        }
        _ => json!({ "name": null, "path": null }),
    }
}

#[tauri::command]
async fn backup_now() -> Value {
    off_main(|| {
        let (ok, message) = resolve_store().backup_now();
        json!({ "ok": ok, "message": message })
    })
    .await
    .unwrap_or_else(|e| json!({ "ok": false, "message": e }))
}

#[tauri::command]
fn list_backups() -> Vec<String> {
    resolve_store().list_backups()
}

#[tauri::command]
async fn restore_backup(name: String) -> Value {
    tauri::async_runtime::spawn_blocking(move || {
        let (ok, message) = resolve_store().restore_backup(&name);
        json!({ "ok": ok, "message": message })
    })
    .await
    .unwrap_or_else(|_| json!({ "ok": false, "message": "Restore failed." }))
}

// ---- Importers ----

/// Pick a Day One Journal.json (or the export folder) / a markdown folder.
#[tauri::command]
async fn pick_import_path(app: tauri::AppHandle, folder: bool) -> Option<String> {
    let (tx, mut rx) = tauri::async_runtime::channel(1);
    if folder {
        app.dialog().file().pick_folder(move |f| {
            let _ = tx.blocking_send(f);
        });
    } else {
        app.dialog().file().add_filter("Day One export", &["json"]).pick_file(move |f| {
            let _ = tx.blocking_send(f);
        });
    }
    let picked = rx.recv().await.flatten()?;
    let path = picked.into_path().ok()?;
    Some(path.to_string_lossy().to_string())
}

#[tauri::command]
async fn import_day_one(path: String, commit: bool) -> Value {
    tauri::async_runtime::spawn_blocking(move || resolve_store().import_day_one(&path, commit))
        .await
        .unwrap_or_else(|_| json!({ "ok": false, "message": "Import failed." }))
}

#[tauri::command]
async fn import_md_folder(path: String, commit: bool) -> Value {
    tauri::async_runtime::spawn_blocking(move || resolve_store().import_md_folder(&path, commit))
        .await
        .unwrap_or_else(|_| json!({ "ok": false, "message": "Import failed." }))
}

#[tauri::command]
async fn pick_media_files(app: tauri::AppHandle) -> Vec<String> {
    let (tx, mut rx) = tauri::async_runtime::channel(1);
    app.dialog()
        .file()
        .add_filter(
            "Media",
            &[
                "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "mov",
                "mp4", "m4v", "webm", "mkv", "m4a", "mp3", "wav", "aac", "ogg", "oga", "opus",
                "flac", "weba",
            ],
        )
        .pick_files(move |list| {
            let _ = tx.blocking_send(list);
        });
    rx.recv()
        .await
        .flatten()
        .map(|list| {
            list.into_iter()
                .filter_map(|f| f.into_path().ok())
                .map(|p| p.to_string_lossy().to_string())
                .collect()
        })
        .unwrap_or_default()
}

#[tauri::command]
async fn export_to_file(app: tauri::AppHandle) -> Value {
    let content = resolve_store().export_markdown();
    if content.is_empty() {
        return json!({ "ok": false, "message": "Nothing to export." });
    }
    let (tx, mut rx) = tauri::async_runtime::channel(1);
    app.dialog()
        .file()
        .set_file_name("nook-export.md")
        .add_filter("Markdown", &["md"])
        .save_file(move |f| {
            let _ = tx.blocking_send(f);
        });
    let Some(target) = rx.recv().await.flatten() else {
        return json!({ "ok": false, "message": "" }); // cancelled
    };
    let Ok(path) = target.into_path() else {
        return json!({ "ok": false, "message": "Bad path." });
    };
    match std::fs::write(&path, content) {
        Ok(_) => json!({ "ok": true, "message": format!("Exported to {}", path.to_string_lossy()) }),
        Err(e) => json!({ "ok": false, "message": format!("Export failed: {}", e) }),
    }
}

/// Paths reaching the file manager come from the frontend, so they are pinned
/// to the journal folder — the app has no business revealing anything else.
fn within_base(base: &std::path::Path, path: &std::path::Path) -> bool {
    let canon = |p: &std::path::Path| p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
    canon(path).starts_with(canon(base))
}

#[tauri::command]
fn reveal_path(app: tauri::AppHandle, path: String) {
    let store = resolve_store();
    let path = std::path::PathBuf::from(&path);
    if !within_base(&store.base, &path) {
        return;
    }
    let _ = app.opener().reveal_item_in_dir(path.to_string_lossy().to_string());
}

#[tauri::command]
fn reveal_entry(app: tauri::AppHandle, source: Source) {
    let store = resolve_store();
    let path = match source.kind.as_str() {
        "inbox" => Some(store.base.join("inbox.md")),
        "archive" => source.arg.as_ref().and_then(|d| store.journal_file_for(d)),
        "journal" => source.arg.as_ref().and_then(|n| store.split_file_for(n)),
        _ => None,
    };
    let Some(p) = path else { return };
    if !within_base(&store.base, &p) {
        return;
    }
    let _ = app.opener().reveal_item_in_dir(p.to_string_lossy().to_string());
}

#[tauri::command]
fn reveal_base(app: tauri::AppHandle) {
    let store = resolve_store();
    let _ = app
        .opener()
        .reveal_item_in_dir(store.base.join("journal").to_string_lossy().to_string());
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            allow_base_asset_access(app.handle());
            // Leftover `.nook-*.tmp` files from writes that never finished
            // (a crash, a yanked drive). Off-thread: it walks the folder.
            std::thread::spawn(|| store::sweep_stale_temp_files(&resolve_store().base));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_prefs,
            set_pref,
            now_ts,
            reload,
            entries_for_day,
            all_entries_by_day,
            entries_tagged_with,
            entries_in_journal,
            starred_entries,
            search,
            global_search,
            saved_searches,
            add_saved_search,
            remove_saved_search,
            on_this_day,
            year_review,
            years_with_entries,
            template_names,
            template_body,
            create_template,
            delete_template,
            random_entry,
            upsert_draft,
            remove_draft,
            update_draft,
            delete_draft,
            import_drafts,
            sort_inbox,
            file_draft,
            return_to_inbox,
            file_all_drafts,
            update_filed_entry,
            delete_filed_entry,
            update_journal_entry,
            delete_journal_entry,
            toggle_star,
            rename_tag,
            merge_tags,
            similar_tag_groups,
            ignore_tag_group,
            all_assets,
            delete_asset,
            assets_bytes,
            orphan_assets,
            delete_orphan_assets,
            asset_usages,
            asset_abs,
            save_asset,
            import_asset,
            total_data_saved,
            compress_existing_media,
            stats,
            cleanup,
            merge_ex_split_journals,
            export_markdown,
            pick_journal_folder,
            use_default_folder,
            pick_backup_folder,
            backup_folder_info,
            backup_now,
            list_backups,
            restore_backup,
            pick_import_path,
            import_day_one,
            import_md_folder,
            pick_media_files,
            export_to_file,
            reveal_path,
            reveal_entry,
            reveal_base,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Nook");
}
