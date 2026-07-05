# Jibber — Technical Documentation for AI Agents

> **⚠️ KEEP IN SYNC**: `CLAUDE.md` and `AGENTS.md` are clones. When a change is
> substantial (architecture, data flow, storage/sync, build process, major UX),
> update **both** immediately. Skip churn for trivial tweaks.

## What is Jibber?

Jibber is a native **iOS + macOS** journaling app built with SwiftUI. You write
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
`Documents/` folder, (3) a local `~/Documents/Jibber` fallback (so the app always
works offline / signed out). The chosen folder is used directly as the base — same
as jnl's `JNL_DIR` — so pointing Jibber at an existing jnl notes folder makes both
tools share the same files.

## Architecture

Single **multiplatform target** (`platform: [iOS, macOS]`), deployment iOS 17 /
macOS 14. There is **no hand-maintained `project.pbxproj`** — it is generated:

```
make project   # runs gen_pbxproj.py → Jibber.xcodeproj/project.pbxproj
make icon      # runs tools/make_icon.swift → app icon at all sizes
make check     # compiles + runs Tests/ParserChecks.swift (jnl parity)
make build     # xcodebuild macOS + iOS Simulator (unsigned)
```

### Source layout

```
Jibber/
  JibberApp.swift        @main; registers bundled Lato fonts; theme (auto/light/dark)
  Theme.swift            shared colours, font, line-spacing (freewrite aesthetic)
  Models/
    Entry.swift          the entry value type + tag/preview helpers
    JournalParser.swift  PURE port of jnl parse/render/sort/tags (no I/O; unit-tested)
    JournalStore.swift   @MainActor ObservableObject: iCloud base dir, load/file/sort, atomic writes
  Views/
    RootView.swift       NavigationSplitView: Write/Inbox/Archive/Tags + floating Settings cog;
                         NavigationModel drives selection for keyboard-shortcut commands
    WritingView.swift     composer: title field + date picker + body; continuous autosave to an
                          inbox draft (jnl format); "Import" splits pasted multi-entry text
    InboxView.swift       drafts list; swipe File/Delete; search; sort menu; File All / Sort file
    ArchiveView.swift     days grouped by year with previews; search; sort; Stats + Random sheets
    EntryDetailView.swift view/edit a draft or filed entry; title bar = date · title
    TagsView.swift        tag explorer (searchable) → entries per tag
    SettingsView.swift    appearance, writing font, date format, split tags, folder, cleanup/export
  iOS/Info.plist  macOS/Info.plist  Jibber.entitlements  Assets.xcassets  fonts/
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

The entitlement (`Jibber/Jibber.entitlements`) references container
`iCloud.com.caddickbrown.jibber`. In Xcode → target → **Signing & Capabilities**,
enable **iCloud → iCloud Documents** and select/create that container so the
provisioning profile includes it. Automated builds here use
`CODE_SIGNING_ALLOWED=NO`, which skips this; a real device/App Store build needs it.

The custom-folder picker relies on the sandbox entitlements
`com.apple.security.files.user-selected.read-write` and
`com.apple.security.files.bookmarks.app-scope` (both in `Jibber.entitlements`).

## jnl feature parity

Every jnl command has a jibber equivalent: new→composer, review→Inbox actions,
browse/list→Archive, inbox→Inbox, sort→Inbox "Sort file", log/yesterday→Archive
day, stats→Stats sheet, search→`.searchable`, tags/tag→Tags, random→Random,
cleanup→Settings, export→Settings, transfer→Inbox "File All" + composer "Import",
open→Settings "Show in Finder", config→Settings (incl. JNL_SPLIT_TAGS).

## Deferred (explicit follow-ups)

Video journaling; PDF export; AI-chat; live `NSMetadataQuery` sync refresh; an
XCTest target wired into the project (parser is currently verified via `make check`).

## Conventions

- Never hand-edit `Jibber.xcodeproj/project.pbxproj` — edit `gen_pbxproj.py` and
  run `make project`.
- Keep `JournalParser` pure and jnl-faithful; add a case to `ParserChecks.swift`
  when you touch it.
- Guard platform-specific code with `#if os(macOS)` / `#if os(iOS)`; keep the
  shared path AppKit/UIKit-free so both platforms compile.
