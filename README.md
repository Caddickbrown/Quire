# Quire — Linux (0.6.2)

One journalling app over a plain jnl folder: jnl's format, Nook's features, Wander's writing room. Tauri 2 (Rust back end, HTML/JS front end), x86_64 Linux.

## Run it

**.deb (Debian / Ubuntu / Mint / Pop!_OS):** `sudo apt install ./Quire_0.6.2_amd64.deb`, then open Quire from your launcher.

**AppImage (any x86_64 distro):** join the parts, then run:

```sh
cat Quire_0.6.2_amd64.AppImage.part0* > Quire.AppImage
sha256sum -c Quire_0.6.2_amd64.AppImage.sha256   # optional, after renaming to match
chmod +x Quire.AppImage && ./Quire.AppImage
```

First launch opens a **sample journal** (copied to `~/.local/share/com.caddickbrown.quire/sample-journal`, so nothing of yours is touched). Settings › Folder › Choose… points it at a **copy** of your real `JNL_DIR`. Settings live in `~/.config/quire/settings.json`.

## The folder

```
<folder>/
  inbox.md                 drafts (jnl)
  journal/YYYY/MM/DD.md    filed days (jnl)
  <tag>.md                 split journals (jnl's JNL_SPLIT_TAGS)
  transfer.md              jnl's batch file; Quire files it from Today or Settings
  assets/YYYY/MM/…         photos, audio, video, files (Quire; jnl ignores)
  .nook/templates/*.md     templates (Quire; jnl ignores)
  .nook/searches.json      saved searches (Quire; jnl ignores)
```

Writes are atomic (temp file and rename), as in jnl. The journal layer is never rewritten to fit the sidecar layer.

## What's in 0.4

| Area | Features |
|---|---|
| Writing | Title + body, autosave to the inbox (Ctrl+S saves and stays, Ctrl+Enter saves and starts a new draft), Tab / Shift+Tab indent list items, Focus (dims other paragraphs, typewriter scrolling), prompts, word goal ring, timer with chime, live bold/italic/code/@tag highlighting |
| Editor macros | ↵ continues `- `, `1. ` and `- [ ]` lists (empty item ends it); Ctrl+B / Ctrl+I / Ctrl+\` wrap the selection; `@` autocompletes tags (↹ or ↵ accepts); templates insert with `{{date}}`, `{{time}}`, `{{weekday}}` filled in; Promote first line to title; Import as separate entries; Copy text; Print; Discard |
| Filing | File (Ctrl+J), File all, Return to inbox, Sort inbox, split-tag routing, transfer.md |
| Date & time | Change any entry's date and time; filed entries move to the new day's file in time order |
| Reading | Day page (every entry of a day stacked, ‹ › between days, Print day); lightbox for photos; "Open file in your editor" and "Show file" on the ··· menu; Markdown: headings, lists, task checkboxes you can tick (written back to the file), quotes, code, links; photos, video and audio from assets/ inline; `@tags` are links; context menu on any row |
| Journal | List · Stream · Media gallery; tag chips; calendar with marked days (filed, drafts-only, media); day filter; All / Main / split-journal picker; newest/oldest; grouped or flat |
| Search | words · `"exact phrase"` · `tag:x` or `@x` · `before:2026-03` · `after:2025` · `has:image/video/audio/media` · `is:starred`; pin searches (right-click to remove) |
| Starred | Across journal, inbox and split journals; Random (Ctrl+R) |
| Look back | Streaks, days, words; words-per-day heat strip (click a day); words per month; weekday and hour-of-day; top tags; year in review; On this day; storage by type |
| Media | Attach from the composer, drop files onto a draft, or paste an image (all copied into assets/); gallery; orphan check and clean-up |
| Settings | Folder, split tags, templates editor, 7 themes (Almanac, Broadsheet, Linen, Cinema, Night, Marathon, Marathon Day) + Nook's 8 accents, fonts, sizes, follow-system-dark; writing options; daily reminder (system notification); PIN lock (Ctrl+L, lock on launch); backups (choose folder — not inside the journal —, back up now, daily/weekly on launch, keeps the 10 newest, restore); JNL_DIR offered as the folder when set; maintenance |
| Maintenance | Clean up (jnl's cleanup + duplicate removal + retroactive split routing), sort inbox, clear orphan media, export all, import a markdown folder, import a Day One JSON export, tag review (merge near-duplicate tags) |
| Live | Watches the folder: edits from jnl, Nook or sync show up; narrow windows get a phone-style one-pane layout |

## What's new in 0.6

A full parity pass against Nook and jnl, plus a bug review. Highlights:

| Area | Change |
|---|---|
| Media compression | Settings › Media › **Data Saver** (Nook's): photos to 2048 px, videos to 720p H.264, voice memos to low-bitrate audio, original formats kept so links stay valid. **Compress existing media** does the backlog with a progress count. **HEIC → JPEG** always (and relinks entries). Savings are tallied in Nook's `.nook/datasaver-<device>.json`, so both apps share one total and never recompress each other's files. Needs `ffmpeg` (video/audio) and `heif-convert` (libheif) or ImageMagick (HEIC); the .deb recommends them |
| Maintenance macros | **Merge ex-split journals** (Nook's), **File all** in one pass, **Clean up** at full jnl + Nook parity (punctuation outside links, re-sort, dedupe, split extraction, inbox sort/dedupe; skips unreadable files and carries on), **Sort inbox** only rewrites when needed, **sync-conflict** files (Syncthing/Dropbox) detected and merged keep-both |
| Split journals | Reads jnl's own config file (`~/.config/jnl/config`) for `JNL_SPLIT_TAGS` and `JNL_DIR`, so routing matches jnl even when launched from a menu. Reserved names (inbox, transfer, export) can't be split tags |
| Media links | Written Nook-style (`assets/…`, relative to the journal), read either way; moving entries between files keeps links working; orphan check is conservative |
| Safety | A pasted log line like `[2026-01-02 08:00:00] …` no longer splits an entry: autosave pauses and asks Import or Keep as one. Edits to filed entries save when you click away. Failed saves ask before discarding. Unreachable folder shows a banner and blocks writes instead of silently switching to the sample. Restore replaces the folder (hidden folders like .git/.stfolder left alone) after a listed safety copy. Stale temp files swept |
| Backups | Off / Daily / Weekly / **On every change**, keep last N (1–50), last backup time, checked on launch and focus; Nook backups listed too |
| Imports | Day One: real time zones, videos and audio, safe paths, tag cleanup, re-run dedupe. Markdown folders: file creation date fallback, no timestamp collisions |
| Everyday | Paste images from the clipboard (native fallback for Linux), media gallery sort/group/delete/go-to-entry, date format, week start and numbers, prompt of the day, tag review "not a match", Look back library stats, Tab only indents lists (keyboard users can leave the editor), focus refresh no longer wipes Settings input, Settings keeps its scroll position |

## Marathon theme

0.6.1 rebuilds Marathon (dark) from the game's own menu: charcoal grounds, grey chip tabs with the selected one solid white, a brand pill and a counter strip (filed entries, drafts, words) top left, framed panels with a "•••" tab and micro-text, wide upper-case titles over tracked mono text, dark progress strips (Today's words), blue cross-hatch behind photos, small solid blue media badges, and the left-edge bracket. Writing is set in DM Mono unless you pick another face in Settings › Appearance. Marathon Day gets the same structure in light.

**0.6.2, alerts.** Destructive confirmations (delete an entry or file, discard, remove, restore) open a panel after the game's end-of-run card: a wide title ("Permanent deletion"), column labels, the thing being destroyed as a hot-red row with its date or location, a red Delete button, and micro-text. In every theme, Cancel now has focus so Enter can't delete, and errors show as red toasts. Successes get a lime //BANNER with registration ticks: //ENTRY_FILED, //INBOX_CLEARED (File all), //GOAL_COMPLETE (once a day, when you pass your word goal). Other themes show a plain toast.

### First version (0.5)

Settings › Appearance › **Marathon** (dark) or **Marathon Day** (light). After Bungie's 2026 Marathon: wide Archivo Expanded headlines, DM Mono readouts, square corners, numbered tabs, one signal colour (lime; the accent picker changes it on the dark side), a dot-dither field on Today, a lattice behind photos, a segmented rule under titles. Marathon Day uses lime only as a fill, never as text, because lime on pale grey is unreadable. With "Go dark when the system is dark" on, Marathon Day switches to Marathon (other themes still go to Cinema). The writing font follows the theme unless you pick Sans, System or Mono. Fonts are bundled (SIL Open Font Licence); no marks or names from the game.

## Window chrome (0.4.1)

As in Wander: on Linux the window has no system title bar. Quire's top bar is the drag handle (drag anywhere that isn't a button; double-click to maximise or restore) and carries its own minimise, maximise and close at the right. In Focus the bar goes but the controls stay, faint until you hover, with a thin drag strip along the top. Close waits for the last edit to be saved. Settings › Appearance › "Use the system title bar" switches back to your desktop's bar, live, and is remembered.

## 0.4 review pass

Three reviews (Rust, JS, design) ran over 0.3. Fixed: tag merge could panic on some names; a file that failed to read could be overwritten; bad timestamps could panic; moving an entry removed before inserting (data loss on a crash in between); transfer.md ignored split tags; empty drafts could be written; orphan scan missed links in titles and preambles; Day One re-import duplicated entries; a backup folder inside the journal would recurse; the file watcher leaked a thread on folder change; task checkboxes could tick the wrong line; tags inside links were linkified twice; streaks were off by one across DST; Enter in dialogs leaked into the editor; the list pane lost its scroll on every save.

## Not here

Voice recording and on-device transcription, iCloud sync, widgets and share sheet, the iPhone app, desk mode, Wander's other eleven themes (need its source). PDF export is the print dialog's "Save as PDF".

## Keys

`Ctrl+N` new · `Ctrl+J` file · `Ctrl+S` save · `Ctrl+Enter` save & new · `Ctrl+[` back · `Tab` indent · `Ctrl+B` `Ctrl+I` `` Ctrl+` `` wrap · `Ctrl+Alt+F` focus · `Ctrl+Shift+F` search · `Ctrl+T` date & time · `Ctrl+R` random · `Ctrl+P` print · `Ctrl+L` lock · `Ctrl+1–5` tabs · `Ctrl+,` settings · `↑ ↓ ↵` lists · `Esc` back out.

## Build from source

```sh
sudo apt install libwebkit2gtk-4.1-dev build-essential libssl-dev libayatana-appindicator3-dev librsvg2-dev patchelf
npm install && npx tauri build      # → src-tauri/target/release/bundle/
cd src-tauri && cargo test          # format round-trip tests
```

`src-tauri/src/journal.rs` is the format; `extras.rs` is templates, media, cleanup, backup, imports and tag review; `lib.rs` the commands and file watcher; `src/app.js` + `style.css` the UI.
