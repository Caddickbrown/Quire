# Nook for Linux

A native Linux port of Nook (the iOS/macOS SwiftUI journaling app), built with
**Tauri v2** — a small Rust core (the jnl-compatible data layer) plus a
dependency-free vanilla HTML/CSS/JS frontend. The on-disk format is **identical**
to the macOS/iOS app and the `jnl` CLI, so all three can share the same folder.

```
linux/
  src/                     frontend (no build step, no node_modules)
    index.html  styles.css  app.js
    assets/                Lato fonts + favicon
  src-tauri/
    src/
      parser.rs            pure jnl parse/render/sort/tags (port of JournalParser)
      search.rs            pure global-search grammar (port of SearchQuery),
                           unit-tested with the same cases as the Swift port
      store.rs             the data layer (port of JournalStore) — all file ops
      media.rs             image downsample (image crate) + video/audio (ffmpeg)
      lib.rs               Tauri command layer + native dialogs/reveal
      main.rs
    tauri.conf.json  capabilities/  icons/  Cargo.toml
```

`cargo test --lib` runs the parser/search/store checks, including the same
jnl-parity cases the Swift `ParserChecks` cover. Keep `parser.rs`, `search.rs`
and `store.rs` faithful to jnl and to the Swift port when touching either side.

## What works

- **Composer** with continuous autosave, title/date, promote-to-title, import-as-
  separate-entries, discard, **templates** (`<folder>/.nook/templates/*.md`,
  `{{date}}`/`{{time}}`/`{{weekday}}`) and optional **writing prompts**.
- **Inbox** (list + detail), file / file-all / sort-file, star, delete, search, sort,
  random, right-click actions.
- **Journal** (archive) grouped by day, search, sort, random, day view,
  **On This Day**.
- **Global search** (`tag:` / `before:` / `after:` / `has:` / `is:starred` /
  `"phrases"`) with **saved searches** pinned into the sidebar.
- **Starred**, **Split Journals** (tag routing), **Tags** (coloured chips) + Tag
  Review (merge near-duplicate tags), **Assets** grid with "Go to Entry".
- **Entry editor** with Edit/Preview, inline media rendering, editable captions.
- **Media**: attach (file picker / drag-drop), record audio & video
  (`getUserMedia`/`MediaRecorder`), inline image/video/audio playback,
  **Data Saver** compression (images in pure Rust, video/audio via `ffmpeg`).
- **Calendar** (sidebar mini-calendar, starred marker + media-typed dots),
  **focus timer**, **Stats**, **word goal**, **Year in Review**.
- **Importers**: Day One JSON exports and folders of dated markdown/text
  (Obsidian daily notes), with a preview before anything is written.
- **Cleanup**, **Merge ex-split journals**, **Export**, **Backup** and
  **Restore**, custom-folder picker, appearance (theme / accent / font / size /
  date format).

Deliberately **not ported** (see the "Linux port" section of `CLAUDE.md`):
**iCloud Documents sync** — instead point Nook at any synced folder
(Dropbox / Nextcloud / Syncthing) or your existing `jnl` folder via
**Settings → Journal folder → Choose Folder…**; Apple **App Intents /
Shortcuts / Siri**; **widgets**, the **Live Activity**, **notifications** and the
**share extension**; on-device **transcription**; **PDF export** (the webview
can print); and the **Trends** charts.

## Build & run

Prerequisites (Debian/Ubuntu/Zorin):

```sh
sudo apt install -y libwebkit2gtk-4.1-dev build-essential curl wget file \
  libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev ffmpeg
# Rust (if not present):
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
```

Then:

```sh
cd src-tauri
cargo run            # dev build + launch
cargo build --release   # optimized binary at target/release/nook
cargo tauri build    # (optional, needs `cargo install tauri-cli`) → .deb + AppImage
```

Data lives in `~/Documents/Nook` by default (or your chosen folder). Backend
preferences (folder, split tags, data-saver, etc.) are stored in
`~/.config/Nook/settings.json`; UI has no other hidden state.

If a chosen folder isn't there when Nook starts — an unmounted drive, a folder
that has been renamed — Nook says so and refuses every write rather than
quietly recreating it or falling back to `~/Documents/Nook`, so nothing lands
where the real journal will never see it.
