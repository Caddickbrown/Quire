# Changelog

All notable changes to Quire — the core, the terminal app and the Linux app —
are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

**How to update this file**

- Add a bullet under `## [Unreleased]` in the same change that ships the work.
- Buckets, in this order, omitting the empty ones: `Added` · `Changed` ·
  `Fixed` · `Removed` · `Deprecated` · `Security`.
- One line per user-visible change, present tense, what the user gets. Lead
  with the area in bold (**Terminal**, **Linux**, **Core**, **Format**, …).
- Call out anything that changes the on-disk format explicitly — the files
  are shared with jnl, Nook and hand-editing users.
- On release: rename `[Unreleased]` to `## [x.y.z] — YYYY-MM-DD`, bump the
  workspace version in `Cargo.toml`, `linux/src-tauri/Cargo.toml`,
  `linux/src-tauri/tauri.conf.json` and `linux/package.json`, open a fresh `[Unreleased]`, then tag the release
  commit `vx.y.z` and push the tag (see Releases in `CLAUDE.md`).

---

## [Unreleased]

## [0.8.1] — 2026-10-16

### Changed
- **Releases**: built with GitHub's Node 24 actions (the Node 20 ones are being retired), and the desktop app's build uses Node 24. Nothing in the apps changes; this release is the first chance for 0.8.0 to update itself.

## [0.8.0] — 2026-10-16

### Added
- **Releases**: pushing a `vX.Y.Z` tag builds and publishes Linux x86_64 and arm64 releases on GitHub: the terminal app as a tarball with a checksum, the desktop app as AppImage, .deb and .rpm.
- **Terminal**: `quire update` (and `jnl update`) installs the latest release over the running one after checking its SHA-256; `--check` only reports. Source builds are pointed at `install.sh`.
- **Linux**: Settings → About shows the version and how Quire was installed, checks for updates on request, and the AppImage installs a signed update and restarts.
- **Core**: Cleanup moves an entry stored in the wrong day file (say, the 14th's entries pasted into `inbox/…/20.md`) to the day file its header gives, in the same inbox, journal or split journal; one already there counts as a duplicate. Every shell's Cleanup reports how many moved.
- **Backups**: configure automatic backups (off, daily, weekly, monthly or on change) and retention in Terminal Settings; monthly means 30 days in every shell. The terminal runs backups in the background and keeps 10 copies by default.
- **Terminal**: Settings adds tag review/rename, media compression, ex-split merging, Markdown/Day One/transfer imports and conflict-copy merging through the shared Rust core. Show the version and build commit in Settings and `quire --version`.
- **Linux**: Settings adds File All Drafts and Print / Export PDF for the filed journal.
- **Apple**: Settings adds sorting, filing all drafts, transfer imports and conflict-copy merging through Rust. iOS external displays gain shared Quire themes, keyboard controls for size/theme/pause/hints, and an independent paused screen.
- **Apple**: bring Nook's native iOS/macOS SwiftUI app, widget and share
  extension into `apple/` as Quire; journal parsing, search, editing, filing,
  migration and maintenance use the shared Rust core through UniFFI and a
  coordinated Swift `Vault`. Add an XCFramework build, hostless Swift tests
  and an Apple CI workflow; Apple SDK compilation still awaits a Mac run.
- **Install**: `install.sh` for Linux and macOS asks for the terminal app,
  the desktop app, or both; finds jnl, Nook and Wander and the journal
  folders they use; backs the chosen journal up; installs what the build
  needs (Rust, WebKitGTK via apt/dnf/pacman/zypper, Tauri's CLI, optionally
  ffmpeg); builds, installs and checks Quire; points it at the journal and
  moves `inbox.md` drafts into `inbox/`; then offers to remove the old apps
  (to the Trash, never deleted; journal folders are never touched).
  `--dry-run` shows every command first; `--uninstall` removes Quire.
  With Quire already installed it offers to build nothing and only retire
  the old apps (`--tidy`), counts what's installed when choosing removal
  defaults, and says when old apps have already stopped seeing drafts.
- **Terminal**: Today's On this day rows show an entry's first tag, as the inbox rows do.
- **Terminal**: the timer pauses and resumes (`^o`), resets with `alt-o`, shows
  `paused` in the status line, rings the terminal bell when it ends (Settings ›
  Timer chime), and `^o timer` is on the Write hint bar.
- **Terminal**: Settings gains Backups (folder, back up now, restore with a
  safety copy) and Maintenance (clean up, sort inbox, file all drafts, clear
  orphan media, export all), over the same core calls as the desktop app.
- **Terminal**: menu items (hint keys, list rows, pickers) are underlined as you move over
  them; the text of an entry, in the composer or the inbox preview, is not.
- **Terminal**: a settings page (`,`) — theme (applied live), daily word goal,
  timer length, mouse and Data Saver — saved to `settings.json`, shared with
  the desktop app.
- **Core**: `quire-core`, one Rust crate every shell shares — the jnl format,
  the store, search, stats, media, maintenance — behind a `Vault` trait so
  the core never opens a file itself (the Apple shell will coordinate writes;
  Android will use the Storage Access Framework).
- **Terminal**: Quire in the terminal, installed as both `quire` and `jnl`.
  Today, Review, Browse (with the Main / split journal / all picker), Write
  (markdown styled where you type, focus, `@` autocomplete, list
  continuation, autosave), Look back (heat strip, words a month, tags, when),
  Search. Every jnl subcommand keeps its spelling and prints jnl's text when
  piped. Themes follow `themes.json`.
- **Format**: drafts live in `inbox/YYYY/MM/DD.md`, the journal's own shape.
  Retiming a draft moves it between inbox days as it moves filed entries
  between journal days; a day file that empties is deleted.
- **Format**: a legacy `inbox.md` is folded into `inbox/` on open — every
  draft verified first, the original kept under `.quire/migration/` — and
  merged again if an older app rewrites it. `tools/migrate_journal.py` does
  the same from outside the app (dry run by default).
- **Themes**: `themes.json` at the repository root, one source for every
  shell: Almanac, Broadsheet, Linen, Cinema, Night, Marathon, Marathon Day.
- **Terminal**: `quire migrate`, `quire import` (drafts from stdin).
- **Tooling**: `make smoke` drives the terminal app through every screen in a
  pseudo-terminal and checks the files it writes.
- **Terminal**: the mouse. Click hints, list rows, Browse columns, the
  journal picker, Look back's years, a modal's answers and tag suggestions;
  click in the composer to place the caret; the wheel moves through lists and
  the text. F2 turns it off (and back on) so the terminal can select text;
  the choice is kept in `settings.json` as `terminalMouse`.
- **Terminal**: images in the composer. `^v` attaches an image on the
  clipboard to `assets/` and links it; dropping photos, video or audio onto
  the window (terminals paste their paths) attaches them too. Data Saver
  applies as in the desktop app. Pasted text arrives as typed, without list
  continuation firing on every line.
- **Core**: `attach_media` / `attach_bytes` — the attach path (HEIC→JPEG,
  Data Saver, the device ledger) the desktop app had, now shared — and
  `media::encode_clipboard_image`.

### Changed
- **Format**: split journals live in `split/<tag>/YYYY/MM/DD.md`, one file
  per day, instead of one root `<tag>.md`. A `<tag>.md` written by jnl or
  Nook is folded in on open (every entry read back first; the original kept
  in `.quire/migration/`), and root `.md` files with no entries are no longer
  mistaken for split journals. `journal/` is unchanged. jnl and Nook won't
  see split entries in `split/` until taught to; `tools/migrate_journal.py`
  does the move from outside the app.
- **Terminal**: Browse's year, month and day columns are wide enough for their
  longest label and biggest count (no more `Septemb…` or a cut-off year), and
  the entries beside them no longer highlight under the pointer.
- **Terminal**: clicking QUIRE in the masthead goes back to Today (saving a
  draft first).
- **Terminal**: dates on Today (the inbox and On this day rows, "entries since"),
  the inbox list and its open draft, in Browse's day header, in Look back's
  streak dates and in search results are ISO 8601, as in the entries; the long
  dates in the mastheads stay.
- **Terminal**: the inbox is a list of drafts beside the open one (above it on
  a narrow terminal), as Browse is. Filing or deleting keeps the selection in
  place, so the next draft is up; a second click opens it. The draft dots and
  their 12-draft cap are gone.
- **Format**: the sidecar is `.quire/` (templates, saved searches, Data Saver
  ledgers). `.nook/` is read while only it exists and renamed on the first
  write; ledgers are read from both. Nook stops seeing templates and saved
  searches after the move — run one app per journal until Nook is retired.
- **Linux**: the app moves under `linux/` and runs on the core; its commands
  are thin calls on the shared store. `file_draft` now takes the draft's
  file. Opening a journal reports an inbox migration as a toast.
- **Linux**: the bundled sample journal is on the new layout.
- **Linux**: the desktop binary is `quire-desktop` (the package name), so it
  no longer shares a name with the terminal's `quire`.
- **Repository**: a Cargo workspace (`core`, `tui`, `linux/src-tauri`);
  `README.md` describes the whole, `linux/README.md` the desktop app.

### Fixed
- **Core**: ↩ in a list works on a line that still carries its `\r\n` or `\n` ending (the Apple editor passes one).
- **Apple**: the vault refuses a new file under a symlinked folder that points outside the journal (Foundation left such paths unresolved), and reminders no longer crash a process that isn't an app (hostless tests).
- **Apple**: the Xcode project no longer defines the `QuireCoreFFI` module twice (a project-wide header path duplicated the one the XCFramework provides), which broke every Apple build.
- **Terminal**: align tags and word counts in Today, Inbox and Browse, including rows with different digit counts.
- **Apple**: external monitors show a neutral screen while the journal is locked, including when an On this day preview is available.
- **Editor**: continuing an ordered list at the largest supported number
  repeats the number instead of overflowing.
- **Linux**: the running window shows Quire's icon again. Since the binary
  became `quire-desktop` its Wayland app id no longer matched `Quire.desktop`,
  so GNOME showed a generic one; the program now names itself `Quire`.
- **Linux**: text inputs in Settings (folder path, split tags, template name,
  reminder time) had no styling of their own, so dark themes showed pale text
  on the browser's white field; they now use the theme's ground, border and ink.
- **Terminal**: the selected tag suggestion uses the theme's on-accent colour,
  so it is black on Marathon's green instead of white.
- **Linux**: the welcome card says where drafts live now —
  `inbox/YYYY/MM/DD.md`, one file a day — and that an `inbox.md` from jnl
  or Nook is folded in, instead of pointing at `inbox.md`.

### Removed
- **Linux**: the presentation window branch (a second desktop window
  mirroring the composer) is parked, not merged.

## [0.6.2] — 2026-10-09
The Linux-only app, as released before the consolidation. See `linux/README.md`.
