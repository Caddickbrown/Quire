# Nook — Technical Documentation for AI Agents

> **⚠️ KEEP IN SYNC**: `CLAUDE.md` and `AGENTS.md` are clones. When a change is
> substantial (architecture, data flow, storage/sync, build process, major UX),
> update **both** immediately. Skip churn for trivial tweaks.

## What is Nook?

Nook is a native **iOS + macOS** journaling app built with SwiftUI. You write
freely into a distraction-free composer; entries land in an **inbox** as drafts,
then you **file** them into a date-organised **archive**. All data is plain
markdown in an **iCloud Documents** container, so it syncs across devices and stays
readable/editable by hand — and by the `jnl` CLI (see below).

It descends from two projects:
- **freewrite** — the original macOS-only distraction-free writing app (the
  writing aesthetic, Lato font, theme). Its video-journaling subsystem is parked
  under `_parked/video/` (out of the build) for a possible later pass.
- **jnl** (`~/Code/jnl`, a Go CLI) — the backend model this app reuses: an inbox
  of unfiled drafts plus a `journal/YYYY/MM/DD.md` archive, with `@tags`.

## Data model (identical to jnl — byte-compatible on disk)

```
<base>/
  inbox.md                     ← unfiled drafts
  journal/YYYY/MM/DD.md        ← filed entries, one file per day
```

Each entry is a timestamp header + body:

```
[2026-05-10 08:00:00] Optional title
Body text here.
```

`<base>` is resolved in order: (1) a **custom folder** the user picks in Settings
(persisted as a security-scoped bookmark), (2) the **iCloud** ubiquity container's
`Documents/` folder, (3) a local `~/Documents/Nook` fallback (so the app always
works offline / signed out). The chosen folder is used directly as the base — same
as jnl's `JNL_DIR` — so pointing Nook at an existing jnl notes folder makes both
tools share the same files.

**Starred entries**: an entry is "starred" when its title (the header suffix)
ends with a trailing `*` — stored in the plain markdown so it round-trips through
jnl. `Entry.isStarred` / `displayTitle` read it; `JournalStore.toggleStar` and the
star button / context menus add/remove the marker; the **Starred** sidebar section
(`StarredView`) collects them across archive + inbox + split journals.

## Architecture

Two **multiplatform targets** (`platform: [iOS, macOS]`), deployment iOS 17 /
macOS 14: the **Nook** app and the **NookWidgetExtension** WidgetKit extension
(embedded into the app). There is **no hand-maintained `project.pbxproj`** — it
is generated (both targets, the embed phase, and the app→widget dependency all
come out of `gen_pbxproj.py`):

```
make project   # runs gen_pbxproj.py → Nook.xcodeproj/project.pbxproj
make icon      # runs tools/make_icon.swift → app icon at all sizes
make check     # compiles + runs Tests/ParserChecks.swift (jnl parity)
make build     # xcodebuild macOS + iOS Simulator (unsigned)
```

### Source layout

```
Nook/
  NookApp.swift        @main; registers bundled Lato fonts; theme (auto/light/dark)
  Theme.swift            shared colours, font, line-spacing (freewrite aesthetic)
  Models/
    Entry.swift          the entry value type + tag/preview helpers
    JournalParser.swift  PURE port of jnl parse/render/sort/tags (no I/O; unit-tested)
    JournalStore.swift   @MainActor ObservableObject: iCloud base dir, load/file/sort, atomic writes
  Views/
    RootView.swift       NavigationSplitView (path-based); sidebar = Write/Inbox/Journal/Starred/
                         Split/Tags/Assets + mini calendar + timer/Stats/Settings footer. NavigationModel
                         owns section, NavigationPath (mouse Back / ⌘[), focus mode, timer.
    WritingView.swift     composer: title + date picker + body; continuous autosave; Import;
                          attach/record media; drag-drop
    InboxView.swift       macOS email-style (list + open draft); iOS push. Search / sort / File All
    ArchiveView.swift     "Journal": days by year with previews; search; sort; Random; DayView;
                          SplitJournalsView; JournalFileView; StarredView; StatsView
    EntryDetailView.swift edit a draft/filed/split entry; autosaves; Edit/Preview modes (drafts
                          open in Edit, filed entries in Preview); star toggle; inline controls;
                          attach/record media; drag-drop
    TagsView.swift        tag cloud (coloured, searchable) → entries per tag; random tag
    CalendarView.swift    MiniCalendarView (sidebar) — days with entries, media-typed dots
    AssetsView.swift      media grid; right-click Reveal / Delete / Go to Entry
    MediaPreview.swift    render body markdown + inline images/video/audio
    WritingTextEditor.swift  NSTextView/UITextView wrapper: zero insets, no scrollbar, @tag colour
    AudioRecorder.swift   voice memo (AVAudioRecorder) + RecordingBanner
    VideoRecorderView.swift  iOS camera controller / macOS AVCaptureSession recorder
    SettingsView.swift    appearance, accent colour, fonts, date format, tag highlight, split tags (chips),
                          folder, backup, cleanup/merge-ex-split/export, shortcuts + how-to guides
  iOS/Info.plist  macOS/Info.plist  Nook.entitlements  Assets.xcassets  fonts/
gen_pbxproj.py   tools/make_icon.swift   Tests/ParserChecks.swift   Makefile
  Nook/NookShared.swift  `NookSnapshot` — Codable stats shared app↔widget
NookWidget/          WidgetKit extension (own target, embedded in the app)
  NookWidget.swift       small/medium/large widgets; deep-links `nook://write`
  NookWidgetBundle.swift @main WidgetBundle; registers bundled Lato fonts
  Info.plist             NSExtension point `com.apple.widgetkit-extension`
  NookWidget-{iOS,macOS}.entitlements   App Group (macOS also sandboxed)
gen_pbxproj.py   tools/make_icon.swift   Tests/ParserChecks.swift   Makefile
_parked/video/   ← freewrite's video views, excluded from the build
```

### Widget (WidgetKit extension)

`NookWidgetExtension` is a separate multiplatform target embedded in the app's
`PlugIns/`. It shows writing-streak + journal stats and never touches the
journal files directly — instead the app writes a **`NookSnapshot`** (defined in
`Nook/NookShared.swift`, compiled into *both* targets) into an **App Group**
UserDefaults suite (`group.com.caddickbrown.nook`) after every reload via
`JournalStore.writeWidgetSnapshot()`, then calls `WidgetCenter.reloadAllTimelines()`;
the widget reads it on its 30-min timeline refresh. The App Group entitlement is
in `Nook-iOS.entitlements` / `Nook-macOS.entitlements` and both widget
entitlements files. Widgets deep-link via the `nook://` URL scheme (registered in
both app `Info.plist`s, handled by `NookApp.onOpenURL`). Custom `Lato-*` fonts are
bundled into the widget and registered at runtime in `NookWidgetBundle.init`
(a separate process can't inherit the app's font registration).

> Requires the App Group `group.com.caddickbrown.nook` to exist on the signing
> account; Xcode automatic signing normally registers it on first build. If the
> widget doesn't appear, confirm it was actually built + embedded (it's in
> `Nook.app/PlugIns/NookWidgetExtension.appex`).

### Data-layer port (jnl main.go → Swift)

`JournalParser` mirrors jnl exactly and is verified by `Tests/ParserChecks.swift`
against the cases in `~/Code/jnl/main_test.go`:
- `parseEntries` — header regex `^\[(\d{4}[-–]\d{2}[-–]\d{2}) (\d{2}:\d{2}:\d{2})\](.*)`, preamble dropped
- `leadingPreamble` — content before the first header (preserved on rewrite)
- `sortedByTimestamp` — stable, oldest-first (lexicographic == chronological)
- `renderEntries` — round-trips raw text + preamble
- `splitTags` — `@[a-zA-Z][a-zA-Z0-9_-]*`

`JournalStore` ports `fileDraft`/`cmdSort`/atomic `writeFile`. Filing appends an
entry to its day file (or a `<base>/<tag>.md` split-tag file — routing hook present,
config UI deferred), then rewrites the inbox without it. It also owns storage-folder
resolution and `setCustomFolder` / `useDefaultFolder`; `FolderAccess` (same file)
makes/resolves cross-platform security-scoped bookmarks for the custom folder.

## iCloud setup (manual, one-time)

The entitlement (`Nook/Nook.entitlements`) references container
`iCloud.com.caddickbrown.nook`. In Xcode → target → **Signing & Capabilities**,
enable **iCloud → iCloud Documents** and select/create that container so the
provisioning profile includes it. Automated builds here use
`CODE_SIGNING_ALLOWED=NO`, which skips this; a real device/App Store build needs it.

The custom-folder picker relies on the sandbox entitlements
`com.apple.security.files.user-selected.read-write` and
`com.apple.security.files.bookmarks.app-scope` (both in `Nook.entitlements`).

## jnl feature parity

Every jnl command has a nook equivalent: new→composer, review→Inbox actions,
browse/list→Archive, inbox→Inbox, sort→Inbox "Sort file", log/yesterday→Archive
day, stats→Stats sheet, search→`.searchable`, tags/tag→Tags, random→Random,
cleanup→Settings, export→Settings, transfer→Inbox "File All" + composer "Import",
open→Settings "Show in Finder", config→Settings (incl. JNL_SPLIT_TAGS).

## Media

Photos/video/audio are stored as files in `<base>/assets/` and referenced from
entry bodies as Obsidian-style `![](assets/<uuid>.<ext>)` markdown links (never
embedded). Attach via picker or drag-drop; record audio (mic) / video (camera)
in-app; Preview renders them inline (image captions come from the link's alt text).
`JournalStore.saveAsset`/`importAsset`/`assetURL`/`allAssets`/`usages(ofAsset:)`
manage them. Entitlements: audio-input + camera; usage strings generated. Backup
(`Settings → Backup`) copies the whole base folder to a timestamped folder in a
chosen location.

**Data Saver** (opt-in, `Settings → Media`): when on, attached media is
re-compressed, keeping each file's format/extension so `![](assets/…)` links never
break. Images downsample synchronously via `ImageDownsampler` (ImageIO). Video
(720p H.264) and `.m4a` audio (48kbps mono AAC) transcode via `MediaTranscoder`
(AVFoundation) — long-running, so they run off-main through a serial
`MediaTranscodeQueue` and swap the file in place when done: `saveAsset`/`importAsset`
call `scheduleCompression` on attach (iOS wraps it in a background-task assertion).
`Compress Existing Media` (Maintenance) batch-processes `assets/` in place
(`compressExistingMedia`, async, `store.mediaProgress` drives a progress row).
Savings are a merged, no-double-count tally: each device owns one
`<base>/.nook/datasaver-<uuid>.json` (`{savedBytes, assets[]}`); `store.dataSaved`
sums all device files, and an asset uuid recorded on any device is never
re-compressed elsewhere. On macOS, entry context menus expose
`revealEntry(source:)` → "Reveal in Finder".

## Linux port (`linux/`)

A separate **Tauri v2** app (Rust core + dependency-free vanilla HTML/CSS/JS
frontend, no build step) lives under `linux/`. It reuses the jnl on-disk format
byte-for-byte, so it reads/writes the same folders as the SwiftUI app and `jnl`.
The Swift data layer is re-ported to Rust: `linux/src-tauri/src/parser.rs`
mirrors `JournalParser`, `store.rs` mirrors `JournalStore` (all file ops,
star/split/tags/assets/stats/cleanup/backup/search/random/export/dedupe/merge),
`media.rs` does Data-Saver compression (images via the `image` crate, video/audio
via the `ffmpeg` CLI), and `lib.rs` exposes them as Tauri commands plus native
folder/file/save dialogs and reveal-in-file-manager. The frontend (`linux/src/`)
recreates every view. Backend prefs live in `~/.config/Nook/settings.json`;
default data folder is `~/Documents/Nook`. Build/run: `cd linux/src-tauri &&
cargo run` (needs `libwebkit2gtk-4.1-dev` + Rust + `ffmpeg`; see `linux/README.md`).

**Not ported** (no Linux equivalent): iCloud Documents sync — point Nook at a
synced folder instead; and App Intents/Shortcuts/Siri. The parser passes the same
jnl-parity cases the Swift `ParserChecks` do. Keep `parser.rs`/`store.rs` faithful
to jnl when touching either side.

## Deferred (explicit follow-ups)

PDF export; AI-chat; live `NSMetadataQuery` sync refresh; iPhone Live Activity for
the timer (could reuse the `NookWidgetExtension` target); extend the macOS
email-style list+detail beyond Inbox; an XCTest target (parser verified via
`make check`).

## Conventions

- Never hand-edit `Nook.xcodeproj/project.pbxproj` — edit `gen_pbxproj.py` and
  run `make project`.
- Keep `JournalParser` pure and jnl-faithful; add a case to `ParserChecks.swift`
  when you touch it.
- Guard platform-specific code with `#if os(macOS)` / `#if os(iOS)`; keep the
  shared path AppKit/UIKit-free so both platforms compile.
