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
      store.rs             the data layer (port of JournalStore) — all file ops
      media.rs             image downsample (image crate) + video/audio (ffmpeg)
      lib.rs               Tauri command layer + native dialogs/reveal
      main.rs
    tauri.conf.json  capabilities/  icons/  Cargo.toml
```

## What works

Everything in the macOS/iOS app except the two Apple-only pieces:

- **Composer** with continuous autosave, title/date, promote-to-title, import-as-
  separate-entries, discard.
- **Inbox** (list + detail), file / file-all / sort-file, star, delete, search, sort,
  random, right-click actions.
- **Journal** (archive) grouped by day, search, sort, random, day view.
- **Starred**, **Split Journals** (tag routing), **Tags** (coloured chips) + Tag
  Review (merge near-duplicate tags), **Assets** grid with "Go to Entry".
- **Entry editor** with Edit/Preview, inline media rendering, editable captions.
- **Media**: attach (file picker / drag-drop), record audio & video
  (`getUserMedia`/`MediaRecorder`), inline image/video/audio playback,
  **Data Saver** compression (images in pure Rust, video/audio via `ffmpeg`).
- **Calendar** (sidebar mini-calendar with media dots), **focus timer**,
  **Stats**, **Cleanup**, **Merge ex-split journals**, **Export**, **Backup**,
  custom-folder picker, appearance (theme / accent / font / size / date format).

Not ported (no Linux equivalent): **iCloud Documents sync** — instead point Nook
at any synced folder (Dropbox / Nextcloud / Syncthing) or your existing `jnl`
folder via **Settings → Journal folder → Choose Folder…**. Apple **App Intents /
Shortcuts / Siri** are macOS/iOS-only.

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
