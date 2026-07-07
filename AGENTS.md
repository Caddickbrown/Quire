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

## Architecture

Single **multiplatform target** (`platform: [iOS, macOS]`), deployment iOS 17 /
macOS 14. There is **no hand-maintained `project.pbxproj`** — it is generated:

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
    RootView.swift       NavigationSplitView (path-based); sidebar = Write/Inbox/Journal/Split/
                         Tags/Assets + mini calendar + timer/Stats/Settings footer. NavigationModel
                         owns section, NavigationPath (mouse Back / ⌘[), focus mode, timer.
    WritingView.swift     composer: title + date picker + body; continuous autosave; Import;
                          attach/record media; drag-drop
    InboxView.swift       macOS email-style (list + open draft); iOS push. Search / sort / File All
    ArchiveView.swift     "Journal": days by year with previews; search; sort; Random; DayView;
                          SplitJournalsView; JournalFileView; StatsView
    EntryDetailView.swift edit a draft/filed/split entry; autosaves; Edit/Preview modes; inline
                          controls; attach/record media; drag-drop
    TagsView.swift        tag cloud (coloured, searchable) → entries per tag; random tag
    CalendarView.swift    MiniCalendarView (sidebar) — days with entries, media-typed dots
    AssetsView.swift      media grid; right-click Reveal / Delete / Go to Entry
    MediaPreview.swift    render body markdown + inline images/video/audio
    WritingTextEditor.swift  NSTextView/UITextView wrapper: zero insets, no scrollbar, @tag colour
    AudioRecorder.swift   voice memo (AVAudioRecorder) + RecordingBanner
    VideoRecorderView.swift  iOS camera controller / macOS AVCaptureSession recorder
    SettingsView.swift    appearance, accent colour, fonts, date format, tag highlight, split tags (chips),
                          folder, backup, cleanup/export, shortcuts + how-to guides
  iOS/Info.plist  macOS/Info.plist  Nook.entitlements  Assets.xcassets  fonts/
gen_pbxproj.py   tools/make_icon.swift   Tests/ParserChecks.swift   Makefile
_parked/video/   ← freewrite's video views, excluded from the build
```

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
in-app; Preview renders them inline. `JournalStore.saveAsset`/`importAsset`/
`assetURL`/`allAssets`/`usages(ofAsset:)` manage them. Entitlements: audio-input +
camera; usage strings generated. Backup (`Settings → Backup`) copies the whole
base folder to a timestamped folder in a chosen location.

## Deferred (explicit follow-ups)

PDF export; AI-chat; live `NSMetadataQuery` sync refresh; iPhone Live Activity for
the timer (needs a widget extension target); extend the macOS email-style
list+detail beyond Inbox; an XCTest target (parser verified via `make check`).

## Conventions

- Never hand-edit `Nook.xcodeproj/project.pbxproj` — edit `gen_pbxproj.py` and
  run `make project`.
- Keep `JournalParser` pure and jnl-faithful; add a case to `ParserChecks.swift`
  when you touch it.
- Guard platform-specific code with `#if os(macOS)` / `#if os(iOS)`; keep the
  shared path AppKit/UIKit-free so both platforms compile.
