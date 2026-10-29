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

### Added
- **Apple**: attach media on iPhone and iPad again. The composer has a paperclip (Photo Library, Take Photo, Record Video, Voice Note, Choose File) and accepts dropped photos, video, audio and files, as the Mac does.
- **Apple**: paste a copied image (or a copied photo, video or audio file on Mac) into any editor to attach it, as `^v` does in the terminal app.
- **Apple**: attachments land where the cursor is, as their own paragraph, not at the end of the entry.
- **Apple**: hidden mode for the monitor. Choose "VS Code (hidden)" as the monitor theme (Settings → External display, `,` on the monitor, or ⌥⌘T) and the monitor looks like VS Code on Windows 11 above a light taskbar of look-alike app icons: the entry you're writing or reading is its day file, with line numbers and a caret; a list is the Explorer, with the selected entry in a preview tab; Today is a README; settings is the Settings tab. Paused or locked, it is an empty editor. The phone is unchanged.
- **Apple**: iPad runs Quire's design. At regular width the tab words become a narrow sidebar that folds to a strip (the sidebar button or ⌃⌘S; remembered) and, where there is room (iPad landscape, an iPhone that opens out), an entry opens beside the list instead of over it; layout follows the size class, not the device.
- **Apple**: an On this day widget, a Lock Screen Today accessory (a ring of today's words against the goal, or the streak; figures; an inline line), and a Write a Line control that opens Today with its one-line field ready.
- **Apple**: the Today widget's "Another prompt" button rerolls the prompt for the app and every widget.

### Changed
- **Apple**: on the Mac, attaching has its own paperclip button instead of sitting in the ⋯ menu.
- **Apple**: the widgets, the Lock Screen New Draft accessory and the writing-timer Live Activity are set in Quire's design instead of Nook's: the app's theme (Marathon included), Newsreader and IBM Plex, and the mark. Small shows today's words, Medium opens on today's prompt, Large is the Today page in miniature; they turn over at midnight on their own and tint on a tinted Home Screen.

### Fixed
- **Apple**: the composer's control keys (`^j` file, `^s` save, `^t`, `^f`, `^p`, `^d`) work while you type; they only reached the app when no field had the cursor, and the text field read some of them as cursor moves.
- **Apple**: a new page's time is fixed at the first keystroke, so typing and deleting before the first save no longer moves it.
- **Apple**: with the word goal on but never changed, the widget compared today's words against a goal of 1 instead of 750.
- **Apple**: the Mac camera sheet fits the preview instead of cropping it and keeps it level as a Continuity Camera iPhone turns; recordings and photos are saved the same way up.

## [0.11.0] — 2026-10-26

### Changed
- **iPhone**: the composer styles emphasis, bold, code and theme-coloured tags as you type, starts new entries in the title, moves Return to the body, and lets you change the date without leaving the editor.

### Fixed
- **iPhone**: lists select a row automatically only with an external display connected; unplugging clears the selection, while phone-only keyboard navigation still highlights the row you move to.
- **iPhone**: failed saves keep edits open with retry and recovery-copy actions; retiming carries the entry's new reference into subsequent edits, and filing, closing and save confirmations respect write failures.
- **iPhone**: external desk mode stays awake while active, opens Inbox drafts for editing, follows list navigation even when empty, tracks the actual body caret without jumping between layouts, and shows draft filing shortcuts. On this day uses the same entries as the phone.
- **iPhone**: calendars follow the chosen theme, classic mastheads include the Quire mark, selected rows leave room for the time, Marathon's final tab has no trailing divider, and tag badges use theme colours.

## [0.10.1] — 2026-10-25

### Fixed
- **Apple**: App Lock covers the iPhone app again: since the iPhone design (0.9.0) the Face ID veil was never shown there, so a locked app showed the open entry and its app-switcher snapshot. Keys do nothing while locked.
- **Apple**: Spotlight results, notification taps and widget entry links open the entry on iPhone (they reached only the iPad/Mac shell).
- **Apple**: on iPhone the composer keeps its keys (Esc, ^S, ^J…) when the list behind it gets its first entry; opening an entry without changing it no longer rewrites it on disk; leaving the reader or composer no longer blanks a list the external display had just shown; two key catchers no longer trade focus back and forth.
- **Apple**: media usage counts and entry dates hold when iOS reports the journal folder as `/private/var/…` (an attached photo was shown as unused); the vault re-checks a cached folder for having become a symlink.
- **Linux**: "Search everything" (Today, Ctrl+Shift+F) finds inbox drafts and split-journal entries again; opening an entry from the Media Library or lightbox selects it in a list that shows it; filing a draft during an Inbox search selects the next draft in the results.
- **Linux**: Marathon draws in its `themes.json` colours (a later CSS block still set the old ones, so Linux and the other shells differed).
- **Linux**: the editor's bold, italic and code keep each character's width, so the caret no longer drifts on lines with them in proportional writing fonts.
- **Linux**: pasting several lines into a title keeps the caret where it was; clearing orphan media clears exactly the files the confirmation listed (still rechecked first).
- **Linux**: the launcher entry keeps install.sh's no-FUSE wrapper when the AppImage moves, and both quote and escape the AppImage path as the desktop-entry spec requires (a path with a space broke the no-FUSE launcher).

### Changed
- **Media**: recovery copies under `.quire/media-cleanup/` are kept for 30 days, then removed the next time media cleanup or orphan clearing runs (nothing runs in the background). Clearing orphans now frees their space after that, and the folder no longer grows in every backup and sync.

## [0.10.0] — 2026-10-20

### Added
- **Linux / Apple**: a discoverable Media Library with filename search, media-type filters, sorting, date grouping, previews and links back to entries; Linux has its own tab, iPhone opens it from Journal or Settings, and Mac/iPad expose it in the sidebar.
- **Terminal**: cleanup organises older assets into `assets/YYYY/MM/` using the earliest referencing entry, updates markdown links, reports missing media, asks before clearing orphan media (default: keep; recovery copies are retained) and keeps recovery copies under `.quire/media-cleanup/`.
- **Terminal**: `quire cleanup` (also `jnl`) removes `.DS_Store` files throughout the journal folder, reporting the count and any failures.

### Changed
- **Media**: clearing orphan media from Settings or the library rechecks references and retains verified recovery copies under `.quire/media-cleanup/`.

### Fixed
- **Linux**: long editor titles wrap and grow on screen while remaining a single line in the markdown file; italic markdown stays styled while the caret is inside it.
- **Linux**: typing batches editor painting and avoids recounting the full journal on every keystroke; draft autosaves wait 1.2 seconds after typing stops, write off the UI thread and still flush when leaving or closing.
- **Linux**: the Inbox has its own search, and the Journal opens directly on its first entry instead of unexpectedly showing a whole-day overview.
- **Linux / Apple**: cleaned-up media links support angle brackets, spaces, percent escapes and optional titles; Apple library dates and entry navigation distinguish files with the same name in different folders.

## [0.9.1] — 2026-10-17

### Fixed
- **Linux**: the launcher entry is `Quire.desktop`, matching the window's app id, so the dock and pinned icon show. The installer and first run replace an old `quire.desktop`, and `quire update` finds the AppImage from either name.
- **Linux**: the window opens in your theme instead of flashing the light one first: the resolved theme is remembered and applied before the first paint, and the window itself starts dark.

## [0.9.0] — 2026-10-17

### Added
- **iPhone**: the external display is a desk mode in Quire's own design: it follows the phone's theme (or its own), in Newsreader and Plex with ruled pages. Today with the readouts and a prompt when idle, the list beside a preview of the selected entry while browsing, the page when reading or writing. It is driven from the keyboard alone: `n i j l / r` from Today, `,` for Settings on the monitor.
- **Apple (iPhone):** with a monitor attached, `,` opens Settings on the monitor instead of a sheet on the phone: ↑↓ (or j/k) move, ↵ changes the row, `,` or Esc closes. Dark mode, theme, monitor theme, text size, key hints, dimming the phone, prompts and Back up now are all there. The monitor's hint bars list `,`.
- **iPhone**: Quire's own design replaces the Nook look on iPhone: Today, a list-style Inbox, the Journal by month, a reader and composer set as a page, Look back, Search and Settings, in Newsreader and IBM Plex, ruled rather than boxed, in your theme. Times in lists are plain text; they only change inside an entry. Random entry on the Inbox and Journal; swipe from the edge to go back.
- **iPhone**: the Marathon themes are a full look, not just colours: wide heavy Archivo capitals, DM Mono readouts, numbered-style ruled tabs with an inverted current page, a signal-colour brand block, chamfered new-entry slab, dot field and hazard stripe, and a words/streak/inbox readout on Today.
- **iPhone**: Settings picks a theme from light and dark groups with swatches; the earlier settings (folder, backups, import and export, maintenance, reminders, privacy, media, split tags, external display, help) are pages in Quire's own style, and the Nook-only options that no longer apply are hidden.
- **iPhone**: the external display mirrors the composer as you type and shows an entry while you read it.
- **iPhone**: the terminal app's keys on a hardware keyboard, printed along the bottom of a connected monitor: ↑/↓ or `j`/`k` move through the Inbox, Journal and Search, Return opens, Esc lets go and then goes back to Today; in lists `f` files, `e` edits, `*` stars, `t` sets the date and time, `u` returns an entry to the inbox, `d` deletes; on Today `n` new, `i` inbox, `j` journal, `l` look back, `/` search, `r` random, `p` another prompt, `,` settings, Return writes from the prompt; while writing `^J` files the draft, `^S` saves, `^T` sets the date and time, `^F` focuses, `^P` inserts a prompt, `^D` discards, Esc is done. The first ↑/↓ from Today opens the Journal's top or bottom entry. The selection is mirrored to the monitor as a browse list with a preview. Letters never fire while you are typing.
- **Apple**: a new app icon (the gathering mark) for iOS, light and dark, and macOS; `tools/make_apple_icon.swift` regenerates it.
- **Terminal**: `quire update` updates the desktop app too: the AppImage is downloaded, checked against the release's SHA-256 and swapped in place (restart it if it's open); a .deb or .rpm gets the command for your package manager. `--terminal` or `--desktop` updates just one.

### Changed
- **Apple**: opening a journal is much faster. On a journal of 5,100 entries in a file-provider folder the full index went from 55 s to about 1.2 s and the inbox from 5 s to 0.3 s: reads no longer go through file coordination (writes still do), the folder's real path and verified directories are worked out once, and the app stops loading the whole journal twice at launch.
- **Core**: `themes.json` carries Marathon's real colours (they had drifted from the Linux CSS) and optional `signal`, `on_signal` and `flag` tokens for that family.
- **Install**: on Linux (x86_64, arm64) `install.sh` downloads the latest release instead of compiling it, checking every file against its published SHA-256: no Rust, WebKitGTK or Tauri needed, and seconds instead of minutes. The desktop app installs as the AppImage, which updates itself; an installed .deb or .rpm is offered the switch (removed only once the AppImage is in place), and `fuse3` is offered when missing. The terminal app goes to `~/.local/bin`, or replaces a source-built `~/.cargo/bin/quire`; `quire update` keeps it current. `--build` compiles from source as before, as do `--source`, `QUIRE_REF` and macOS.

### Fixed
- **Linux**: the AppImage has an icon in the dock: on first run it writes its own launcher entry and icon (when no `quire.desktop` exists), and the installer's entry sets `StartupWMClass`.
- **Linux**: the Journal opens on the Main journal, with the split journals and All journals in the picker after it.
- **Linux**: a draft in the composer has a visible Done button (Esc did this, but nothing said so), and each entry on the Journal's day page has an Edit link, so a filed entry can be edited without finding the time link first.
- **iPhone**: the keyboard shortcuts now reach the app: the key catcher sits at the root of the app and takes the keys back after a push or a sheet, instead of relying on the app delegate (which isn't in the responder chain under SwiftUI). Esc, letters and the arrows work on Today and after opening an entry.
- **iPhone**: Today and Look back no longer re-read the whole journal each time they redraw; "on this day" is read from what is already loaded, so typing in the quick-capture line stays smooth.
- **iPhone**: a large inbox no longer pushes the page sideways, and a single enormous paragraph can't break a list or the reader.

## [0.8.1] — 2026-10-16

### Fixed
- **Terminal**: `quire update` follows GitHub's download redirect itself; letting the HTTP client follow it failed with "chunk expected crlf" behind an HTTPS proxy, so 0.8.0 may not be able to update itself there (download 0.8.1 by hand once if so).

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
