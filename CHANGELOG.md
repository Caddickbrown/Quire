# Changelog

All notable changes to Nook — the SwiftUI app, the WidgetKit extension, and the
Linux (Tauri) port — are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Nook has not shipped a tagged release yet, so everything below the `Unreleased`
section is dated development history rather than versioned releases.

**How to update this file**

- Add a bullet under `## [Unreleased]` in the same change that ships the work —
  not in a later catch-up pass.
- Use the standard buckets, in this order, omitting the empty ones:
  `Added` · `Changed` · `Fixed` · `Removed` · `Deprecated` · `Security`.
- Write one line per user-visible change, in the present tense, describing what
  the user gets — not which files moved. Internal refactors only earn a line if
  they change behaviour, build steps, or on-disk format.
- Lead each bullet with the area it touches in bold (**Inbox**, **Calendar**,
  **Assets**, …) and keep the bullets within a bucket sorted by that area, so a
  long list stays scannable.
- Mark platform-specific entries with a `(macOS)` / `(iOS)` / `(Linux)` suffix.
- Call out anything that changes the on-disk markdown format explicitly — those
  files are shared with `jnl` and hand-editing users.
- On release: rename `[Unreleased]` to `## [x.y.z] — YYYY-MM-DD`, bump
  `MARKETING_VERSION` in `gen_pbxproj.py`, run `make project`, and open a fresh
  empty `[Unreleased]` above it.

---

## [Unreleased]

### Added
- **Assets**: tap an asset to view it full size — images open fitted and zoom
  like the Photos app (pinch, pan, double-tap), video and audio play — plus
  **sort by date, size, kind, or name**.
- **Assets**: video tiles show a real poster frame with a play badge instead of
  a film glyph.
- **Backup**: automatic backups on a schedule (`Settings → Backup`) — Off /
  Daily / Weekly / On every change, with a "keep last N backups" setting that
  prunes older copies. The copy runs off the main thread, so a large assets
  folder never blocks writing; "On every change" waits for a pause in typing and
  won't run more than once every five minutes. Manual "Back Up Now" prunes too,
  and Settings shows the last backup time.
- **Calendar**: days with unfiled inbox drafts shade grey, distinct from the
  accent shading of days you've filed.
- **Entry rows**: image thumbnails in the Inbox and Journal, decoded at
  thumbnail size and cached so long lists stay smooth.
- **Inbox**: a grouping toggle in the sort menu — date headers, or one flat list.
- **Inbox, Journal, Starred**: pull down to open a random entry (iOS). The
  pull indicator is a spinning dice rather than the stock spinner.
- **Lock Screen widget** (iOS): a New Draft button in all three accessory sizes
  (circular, rectangular, inline) that opens Nook straight into the composer.
- **Settings → About**: a **What's New** screen rendering the whole release
  history. `CHANGELOG.md` ships as an app resource, so the screen can't drift
  from the repo.
- **Stats**: a **Sizes** section broken down by text, images, video, and audio,
  plus sizes by location (inbox, archive, media).
- **Preview**: `@tag` highlighting now renders in reading mode, not just the
  editor.
- **Starred**: the same dice + sort toolbar as the Inbox and Journal.

### Changed
- **Assets**: the grid is a photo gallery — uniform square tiles with hairline
  gaps, capped so they stay thumbnail-sized on a wide window, and no uuid
  filename captions.
- **Destructive actions** are red everywhere — Delete in the inbox, journal,
  entry editor and assets menus, Discard in the composer, and Clear Orphan
  Media. `role: .destructive` alone left several of them looking ordinary.
- **Entry rows**: the thumbnail is bigger and sits on the right of the row.
- **Sidebar** (iOS): the "nook" title is gone — the section list stands on its
  own and the title only crowded it. macOS still uses it as the window title.
- **Calendar**: the month/year picker is a real picker — two wheels on iOS, two
  pop-up menus on macOS — instead of a month menu plus a year stepper.
- **Entry view** (iOS): the controls moved into the navigation bar, so an entry
  no longer pays for two rows of chrome before the text starts.
- **Journal**: the toolbar puts the dice before sort, matching the Inbox.

### Fixed
- **Assets**: opening the gallery was very slow. Working out which entries use
  an asset reads every journal file, and that was being done up front for each
  visible tile; it now happens only when "Go to Entry" is pressed. Listing the
  folder also moved off the main thread.
- **Inbox**: the swipe-to-delete action is red on both swipe edges (a
  destructive role alone doesn't tint the leading edge).
- **Widget scheme**: running the widget extension from Xcode failed with
  "Please specify the widget kind … `_XCWidgetKind`" once the bundle held two
  widgets. `gen_pbxproj.py` now generates a shared `NookWidgetExtension` scheme
  carrying that variable.
- **`make check`** compiles again: `Entry`'s media helpers referenced
  `JournalStore`, which isn't in the check's compile set. The pure link-parsing
  and media-kind helpers moved to `Models/Media.swift`.

---

## 2026-07-30 — Widget

### Added
- **WidgetKit extension** (`NookWidgetExtension`) in small, medium, and large
  sizes, showing writing streak and journal stats; embedded into the app bundle
  and built as part of `make build`.
- Widgets deep-link into the composer via the new `nook://` URL scheme.
- Home screen quick actions and a **New Draft** shortcut.
- `NookSnapshot` — a Codable stats payload written to the
  `group.com.caddickbrown.nook` App Group after every reload, so the widget
  never reads the journal files directly.

## 2026-07-28 — Linux port

### Added
- **Linux app** under `linux/`: a Tauri v2 build (Rust core, dependency-free
  vanilla frontend) that reads and writes the same on-disk format as the SwiftUI
  app and `jnl`. The Swift data layer is re-ported as `parser.rs` / `store.rs`,
  with Data Saver compression in `media.rs`.
- Reveal-enclosing-folder context menu in Split Journals (macOS).

### Notes
- iCloud sync and App Intents/Shortcuts have no Linux equivalent — point the
  Linux app at an already-synced folder instead.

## 2026-07-12 — Starred entries & Data Saver

### Added
- **Starred entries**: a trailing `*` on an entry's title marks it starred, so
  the flag round-trips through plain markdown and `jnl`. New **Starred** sidebar
  section collects them across the archive, inbox, and split journals.
- **Data Saver** (`Settings → Media`): opt-in re-compression of attached media
  that preserves each file's format and extension, so `![](assets/…)` links never
  break. Images downsample via ImageIO; video (720p H.264) and `.m4a` audio
  (48 kbps mono AAC) transcode off-main through a serial queue.
- **Compress Existing Media** maintenance action, with a progress row.
- Space-saved tally merged across devices, with each device owning a
  `<base>/.nook/datasaver-<uuid>.json` file so no asset is compressed twice.
- **Reveal in Finder** on entry context menus (macOS).

## 2026-07-07 — Renamed to Nook

### Changed
- The app, bundle identifiers, and iCloud container were renamed from Jibber to
  **Nook**.

## 2026-07-05 — Rebuild on the jnl model

The original freewrite macOS app was rebuilt as a multiplatform iOS + macOS
journaling app backed by the `jnl` on-disk format.

### Added
- **Writing composer** with title, date picker, continuous autosave, ⌘S, Import,
  Discard, promote-first-line-to-title, and drag-and-drop.
- **Inbox** of unfiled drafts — search, sort, File All, Random, configurable
  swipe actions (iOS), and an email-style list + detail layout (macOS).
- **Journal** archive of filed entries grouped by date, with search, sort,
  Random, day view, and browsable tag-routed **Split Journals**.
- **Tags**: a searchable cloud of coloured chips, per-tag entry lists that
  include inbox drafts, and a random tag.
- **Tag Review** (`Settings → Maintenance`): two-tier near-duplicate detection
  with ignore, batch-apply, a live remaining count, and background loading.
- **Media**: attach images, video, and audio as Obsidian-style
  `![](assets/…)` links; in-app voice-memo and video recording; inline playback
  in Preview; media badges on entry rows; an **Assets** browser with reveal,
  delete, and Go to Entry.
- **Mini calendar** in the sidebar — days with entries marked, dots coloured by
  media type, Today shortcut.
- **Stats** as a global sidebar pane: separate inbox / archive / text / media /
  total sizes.
- **Writing timer** in the sidebar bottom bar, with per-entry time in day view.
- **Focus Mode** to hide the sidebar, and a mouse Back button / ⌘[ (macOS).
- **Backup**: choose a folder and copy the whole base folder to a timestamped
  copy, with Show in Finder.
- **Clean Up**: dedupe, retroactive split-tag extraction at full `jnl cmdCleanup`
  parity, and Clear Orphan Media.
- **App Intents** for Shortcuts, Siri, and Spotlight.
- **Settings**: appearance and accent colour, fonts and text size, date format,
  `@tag` highlighting, split tags as an editable chip field, custom storage
  folder via a security-scoped bookmark, keyboard-shortcut reference, and
  expandable how-to guides.
- Custom text editor (caret-aligned, no scroll indicator) with live `_italic_`
  rendering and `@tag` colouring.
- Right-click context menus for Archive and Delete.

### Fixed
- Export produced incomplete output.
- iOS video recording crashed on launch; the recorder now defaults to the front
  camera.
- iOS inbox autosave dropped edits.
- Composer audio recording failed to start, and the Stop banner did not clear.
- iOS code signing failed until entitlements were split per platform.
