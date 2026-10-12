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

Four **multiplatform targets** (`platform: [iOS, macOS]`), deployment iOS 17 /
macOS 14: the **Nook** app, the **NookWidgetExtension** WidgetKit extension,
the **NookShareExtension** share extension (both embedded into the app), and
**NookTests** — a hostless XCTest bundle (run via the Nook scheme's Test
action: `xcodebuild test -scheme Nook -destination 'platform=macOS'`). It
compiles the model files listed in `gen_pbxproj.py`'s `test_shared_models`,
which covers parser parity, search grammar and list continuation, and also
**`JournalStore`** — `init(testingBase:)` roots a store at a temp folder, so
its read-modify-write paths are tested against real files with no app host and
no way to reach iCloud or the user's journal. Keep that list closed over its
own dependencies: if a view type leaks in, it belongs in `Models/` instead
(that is why `EntrySource` moved out of `EntryDetailView.swift`).
There is **no hand-maintained `project.pbxproj`** — it is generated (all
targets, the embed phase, and the app→extension dependencies all come out of
`gen_pbxproj.py`):

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
    Entry.swift          the entry value type + `EntrySource` (which file an
                         entry lives in) + tag/preview helpers; `id` is
                         ts + twin `occurrence`, stable across re-parses (a fresh
                         UUID per parse re-identified every row on every save).
                         Unique per *file* only — a view merging pools (Search,
                         Starred, Tags) must renumber via `mergedEntrySources`
    JournalParser.swift  PURE port of jnl parse/render/sort/tags (no I/O; unit-tested)
    Media.swift          PURE media-link paths + MediaKind (used by Entry; in `make check`)
    SearchQuery.swift    PURE global-search grammar (tag:/before:/after:/has:/is:starred/
                         "phrases") + entry matching; cases in ParserChecks / `make check`
    ListContinuation.swift  PURE ↩-in-a-list rules (continue bullet/ordered/checkbox,
                         end on empty item); shared by both platform editors; in `make check`
    JournalStore.swift   @MainActor ObservableObject: iCloud base dir, load/file/sort, atomic
                         writes; also the share-extension drain, appendFiledEntries (imports),
                         onThisDay, and the live-sync watcher (NSMetadataQuery on iCloud,
                         DispatchSource dir watchers otherwise; inbox conflicts merge keep-both).
                         Every inbox rewrite goes through inboxForRewrite/writeInbox, which
                         re-read the file but skip the parse while its bytes still match the
                         cache — autosave is O(edit), not O(inbox). The watcher suppresses the
                         echo of our own writes (with a 20s ceiling so remote changes still
                         land) and scans for conflicts off-main, resource-value flag first.
    Templates.swift      entry templates (<base>/.nook/templates/*.md, {{date}} substitution)
                         + the PromptDeck of composer prompts
    Importers.swift      Day One JSON + dated-markdown-folder importers (prepare → confirm →
                         commitImport; media through saveAsset; dedupe by raw on re-run)
    Transcription.swift  on-device voice-memo transcription (Speech framework)
    SpotlightIndexer.swift  opt-in Core Spotlight indexing + deep-link resolve
    Reminders.swift      notifications: streak-aware daily reminder with an inline
                         "Write a line…" text action (→ quickAddDraft), the weekly
                         "From your journal" resurfacing note, and the
                         UNUserNotificationCenter delegate wiring both
    SavedSearches.swift  pinned queries (<base>/.nook/searches.json, synced; sidebar rows)
    TimerActivity.swift  the writing-timer Live Activity's app side (iOS; attributes in
                         NookShared.swift, rendering in NookWidget.swift)
    AppLock.swift        Face ID/Touch ID app lock (LocalAuthentication) — app-only, files
                         stay plain markdown by design
    YearReview.swift     per-year retrospective computation (off-main)
  Views/
    RootView.swift       NavigationSplitView (path-based); sidebar = Write/Inbox/Journal/
                         Starred/Stream/Split/Tags/Assets + mini calendar + timer/Stats/Settings footer. NavigationModel
                         owns section, NavigationPath (mouse Back / ⌘[), focus mode, timer.
    WritingView.swift     composer: title + date picker + body; continuous autosave; Import;
                          attach/record media; drag-drop
    InboxView.swift       macOS email-style (list + open draft); iOS push. Search / sort / File All
    SearchView.swift      global search section (⌘⇧F) over inbox + archive + splits,
                          using Models/SearchQuery
    OnThisDayView.swift   the Journal's "On this day" banner + years sheet
    YearReviewView.swift  Stats → Year in Review sheet + the shareable ImageRenderer card
    TrendsView.swift      Stats → Trends (Swift Charts: words/month, tag lines) +
                          HeatStripView, the Canvas year heat strip shared with the
                          Year in Review card
    WelcomeView.swift     the one-screen first-run sheet (shown once; "welcomeShown")
    PDFExport.swift       typeset PDF export (one page per day, vector text via
                          ImageRenderer into a CGContext PDF) + PDFExportDocument
    StreamView.swift      "Stream": the whole corpus on one page, oldest first — pinned day
                          headers, times in a narrow margin (a bottom-to-top spine on iPhone),
                          full prose, tap-to-edit in place; drafts foldable into the flow
    ArchiveView.swift     "Journal": days by year with previews; search; sort; Random; DayView;
                          SplitJournalsView; JournalFileView; StarredView; StatsView
    EntryDetailView.swift edit a draft/filed/split entry; autosaves; Edit/Preview modes (drafts
                          open in Edit, filed entries in Preview); star toggle; inline controls;
                          attach/record media; drag-drop
    TagsView.swift        tag cloud (coloured, searchable) → entries per tag; random tag
    CalendarView.swift    MiniCalendarView (sidebar) + MonthYearPicker — days with entries,
                          media-typed dots; grey draft-days open the Inbox
    AssetsView.swift      photo-gallery grid (video poster frames); tap → AssetViewer
                          (Photos-style zoom); sort + group by day/month/year;
                          Reveal / Delete / Go to Entry
    ExternalDisplayView.swift  iOS second screen — the external-display scene
                          delegate + the window shown on a connected monitor
                          (entry / browse list / idle stats / hint bar), and
                          the optional device-screen dimming
    KeyboardNavigation.swift  ↑/↓/↩/⎋ selection over an entry list, shared by
                          InboxView and EntryTwoPane; mirrors to the monitor.
                          iOS uses UIKeyCommand, NOT SwiftUI onKeyPress — see
                          the file header for why
    ChangelogView.swift   "What's New" — parses the bundled CHANGELOG.md resource
    MediaPreview.swift    MediaBody renders body markdown + inline images/video/audio;
                          MediaPreview wraps it in a scroll view (Stream renders the body
                          directly, inside its own scroll)
    WritingTextEditor.swift  NSTextView/UITextView wrapper: zero insets, no scrollbar, @tag colour;
                          `sizeToFit` makes it non-scrolling and self-measuring (Stream)
    AudioRecorder.swift   voice memo (AVAudioRecorder) + RecordingBanner
    VideoRecorderView.swift  camera capture — video + stills; iOS camera controller /
                          macOS AVCaptureSession (movie + photo output)
    SettingsView.swift    appearance, accent colour, fonts, date format, tag highlight, split tags (chips),
                          folder, backup, cleanup/merge-ex-split/export, shortcuts + how-to guides
  iOS/Info.plist  macOS/Info.plist  Assets.xcassets  fonts/
  Nook-{iOS,macOS}.entitlements   iCloud + App Group (macOS also sandboxed)
  NookShared.swift     `NookSnapshot` — Codable stats shared app↔widget
NookWidget/          WidgetKit extension (own target, embedded in the app)
  NookWidget.swift       small/medium/large widgets; deep-links `nook://write`
  NookLockScreenWidget.swift  iOS-only Lock Screen accessory: a New Draft button
  NookControlWidget.swift  iOS 18+ Control Center control: the same New Draft button
  NookWidgetBundle.swift @main WidgetBundle; registers bundled Lato fonts
  Info.plist             NSExtension point `com.apple.widgetkit-extension`
  NookWidget-{iOS,macOS}.entitlements   App Group (macOS also sandboxed)
NookShare/           share extension (own target, embedded in the app)
  ShareViewController.swift  captures shared text/URLs/media into the App Group
                     PendingShare/ handoff (self-contained; no shared model code)
  Info.plist         NSExtension point `com.apple.share-services` + activation rule
  NookShare-{iOS,macOS}.entitlements    App Group (macOS also sandboxed)
gen_pbxproj.py   tools/make_icon.swift   Makefile
Tests/ParserChecks.swift   Tests/NookTests.swift
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
both app `Info.plist`s, handled by `NookApp.onOpenURL`). The same bundle also
ships a **Control Center control** (`NookControlWidget.swift`) — iOS 18+, so it is
`@available`-gated and registered behind `if #available` in the bundle body; its
`ControlWidgetButton` runs a local `AppIntent` that returns an `OpenURLIntent` for
`nook://write` (the app's own `OpenNewDraftIntent` isn't compiled into the widget
target). Custom `Lato-*` fonts are
bundled into the widget and registered at runtime in `NookWidgetBundle.init`
(a separate process can't inherit the app's font registration).

> Requires the App Group `group.com.caddickbrown.nook` to exist on the signing
> account; Xcode automatic signing normally registers it on first build. If the
> widget doesn't appear, confirm it was actually built + embedded (it's in
> `Nook.app/PlugIns/NookWidgetExtension.appex`).

### Share extension (NookShareExtension)

A second embedded extension (`NookShare/`, point
`com.apple.share-services`): sharing text, a URL, or media from any app writes
a jnl-format draft into the App Group's `PendingShare/pending.md` (media into
`PendingShare/assets/<uuid>.<ext>`, already linked as `![](assets/…)` so the
paths are correct once moved). The extension is deliberately self-contained —
it can't resolve a custom journal folder's security-scoped bookmark, so it
never touches the journal; `JournalStore.drainPendingShares()` (called at the
top of every `reload()`) moves the media into `<base>/assets/` and appends the
drafts to the inbox. Like the widget, it gets no Xcode scheme (autocreation
suppressed); building `Nook` builds it.

### External display (iOS second screen)

Connected to a monitor, iOS mirrors an app unless the app declares an
external-display scene. Nook declares one, so it gets its own window there
instead — which also decouples the device panel, letting Nook dim it to save
power without dimming what's on the monitor.

The wiring, all in `Views/ExternalDisplayView.swift`:
- `Nook/iOS/Info.plist` carries a **hand-written `UIApplicationSceneManifest`**
  (`UIApplicationSupportsMultipleScenes` + a
  `UIWindowSceneSessionRoleExternalDisplayNonInteractive` configuration naming
  `$(PRODUCT_MODULE_NAME).ExternalDisplaySceneDelegate`). It is written by hand
  because `INFOPLIST_KEY_UIApplicationSceneManifest_Generation` can't express
  the extra scene — that build setting is deliberately **absent** from
  `gen_pbxproj.py`, and adding it back would collide with the plist. The
  application role is omitted; SwiftUI's `WindowGroup` supplies it.
- `ExternalDisplaySceneDelegate` builds a `UIWindow` hosting
  `ExternalDisplayRoot` (shown, never made key).
- `ExternalDisplayModel.shared` is the bridge: the scene delegate can't reach
  the app scene's environment, so `RootView` hands it the `JournalStore` **and
  its resolved `colorScheme`** (an external scene has its own trait collection
  and won't follow the device's appearance on its own). Views push content with
  `.externalDisplay(...)` — a no-op on macOS, and it only republishes while a
  display is attached, so the composer doesn't broadcast every keystroke into
  the void. `WritingView` pushes `.composing`, `EntryDetailView` pushes
  `.editing` in Edit and `.reading` in Preview, the keyboard-navigation
  modifier pushes `.browsing`; otherwise
  `.idle`, a stats screen fed by the App Group `NookSnapshot` rather than by
  touching the journal.
- Composing and reading share one `ExternalEntryView` (a `live` flag is the only
  difference) — they were two views once and drifted apart on the same screen.
  Keep it that way. The live body is **`WritingTextEditor` in `mirror` mode**:
  a read-only `MirrorTextView` styled by the editor's own regexes (tags,
  `_italic_`, `**bold**`, code — so the monitor can't drift from the phone),
  with no Dynamic Type scaling, a caret of its own at `mirrorCaret`, and
  scroll-to-caret. The caret comes from the live editor's `onCaretChange`
  (UTF-16 offset, nil when the body isn't focused) through `WritingView` /
  `EntryDetailView` into `.composing(caret:)` / `.editing(caret:)`. Text is
  merged into the mirror as one prefix/suffix diff edit, never assigned
  wholesale (that reset the scroll). Type is sized off the panel height ×
  `ExternalTextSize` (Settings → External display → Text size); all the fonts
  there use `Theme.font(_:size:fixed: true)` so Dynamic Type stays out of it.
- Dimming (`Settings → External display`, off by default) writes the app
  scene's `UIScreen.brightness`, remembers the user's level, and restores it on
  disconnect *and* on `willTerminate`.

Only the scene plumbing and brightness control are `#if os(iOS)`; the content
model and views compile on macOS so the shared views stay guard-free.

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

The entitlements (`Nook/Nook-iOS.entitlements`, `Nook/Nook-macOS.entitlements`)
reference container `iCloud.com.caddickbrown.nook`. In Xcode → target → **Signing & Capabilities**,
enable **iCloud → iCloud Documents** and select/create that container so the
provisioning profile includes it. Automated builds here use
`CODE_SIGNING_ALLOWED=NO`, which skips this; a real device/App Store build needs it.

The custom-folder picker relies on the sandbox entitlements
`com.apple.security.files.user-selected.read-write` and
`com.apple.security.files.bookmarks.app-scope` (both in `Nook-macOS.entitlements`;
they are macOS-only — the iOS document picker needs no sandbox entitlement).

## jnl feature parity

Every jnl command has a nook equivalent: new→composer, review→Inbox actions,
browse/list→Archive, inbox→Inbox, sort→Inbox "Sort file", log/yesterday→Archive
day, stats→Stats sheet, search→`.searchable`, tags/tag→Tags, random→Random,
cleanup→Settings, export→Settings, transfer→Inbox "File All" + composer "Import",
open→Settings "Show in Finder", config→Settings (incl. JNL_SPLIT_TAGS).

## Media

Photos/video/audio are stored as files in `<base>/assets/` and referenced from
entry bodies as Obsidian-style `![](assets/<uuid>.<ext>)` markdown links (never
embedded). Attach via picker or drag-drop; record audio (mic), take a photo or
record video (camera) in-app; Preview renders them inline (image captions come
from the link's alt text).
`JournalStore.saveAsset`/`importAsset`/`assetURL`/`allAssets`/`usages(ofAsset:)`
manage them. Entitlements: audio-input + camera; usage strings generated. Backup
(`Settings → Backup`) copies the whole base folder to a timestamped folder in a
chosen location. It can also run **automatically** — `BackupInterval` (Off /
Daily / Weekly / On every change, in `JournalStore`) plus a keep-last-N prune.
The copy runs off the main actor (`runBackup` → `copyTree`/`prune`); scheduled
runs fire from `autoBackupIfDue()` (app launch + foreground via `scenePhase`),
and `writeFile` calls `journalDidChange()` to drive the change-triggered ones.

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

The 2026-08 parity wave added `search.rs` (the SearchQuery grammar,
unit-tested with the same cases as the Swift port — keep them in step), plus
store/commands/frontend for global search, saved-search pins, templates +
prompts, On This Day, words-today/word goal, Year in Review, the Day One /
markdown-folder importers, and backup Restore.

**Not ported** (no Linux equivalent, or deliberately skipped): iCloud
Documents sync — point Nook at a synced folder instead; App
Intents/Shortcuts/Siri; widgets/Live Activity/notifications/share extension;
transcription (offer via a `whisper` CLI shell-out if ever wanted); PDF export
(the webview can print); the Trends charts. The parser passes the same
jnl-parity cases the Swift `ParserChecks` do. Keep `parser.rs`/`store.rs`
faithful to jnl when touching either side.

## Deferred (explicit follow-ups)

AI-chat ("Ask Your Journal" — deserves its own spec; on-device only via Apple
Foundation Models is the shape worth speccing, and explicitly not before 1.0);
extend the macOS email-style list+detail beyond Inbox; Apple Watch quick
capture (parked — no device to verify against); Linux gaps that are deliberate
(transcription via a whisper CLI shell-out, PDF via webview print, the Trends
charts/heat strip). Shipped and no longer deferred: PDF export, live
`NSMetadataQuery` sync refresh, the timer Live Activity, the XCTest target,
and the Linux parity wave (search/templates/importers/On This Day/word
goal/Year in Review/saved searches/restore).

## Conventions

- **Update `CHANGELOG.md` in the same change that ships the work.** Add a bullet
  under `## [Unreleased]` for anything user-visible (features, behaviour, fixes,
  on-disk format, build steps); see the "How to update this file" block at the
  top of that file for the buckets and phrasing.
- **Never accept Xcode's "Update to recommended settings" sheet.** It writes
  straight into `project.pbxproj`, which the next `make project` regenerates
  from scratch — the changes vanish and the sheet comes back. Hit Cancel, then
  add the settings to `gen_pbxproj.py` instead. The recommended warning set,
  `DEAD_CODE_STRIPPING`, `REGISTER_APP_GROUPS`, `ENABLE_USER_SCRIPT_SANDBOXING`,
  `STRING_CATALOG_GENERATE_SYMBOLS`,
  `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` and a
  project-level `DEVELOPMENT_TEAM` (targets inherit it) are already there. Watch
  the setting names: a wrong one is accepted silently as a user-defined key and
  even echoes back from `-showBuildSettings`, so confirm against Xcode's own
  `.xcspec` files rather than `-showBuildSettings` when the sheet won't go away.
  Also bump
  `LastUpgradeCheck` / `LastSwiftUpdateCheck` to the Xcode you're on — a stale
  stamp raises the sheet on its own, whatever the settings say. (Currently 2650
  for Xcode 26.5; the encoding is major × 100 + minor × 10.)
- Never hand-edit `Nook.xcodeproj/project.pbxproj` — edit `gen_pbxproj.py` and
  run `make project`. Don't re-add
  `INFOPLIST_KEY_UIApplicationSceneManifest_Generation`: the iOS scene manifest
  is hand-written (see "External display" above).
- **Schemes are generated too, and there is deliberately only one: `Nook`.**
  `gen_pbxproj.py` writes the shared `Nook.xcscheme` plus the per-user
  `xcuserdata/…/xcschememanagement.plist`, whose `SuppressBuildableAutocreation`
  entry stops Xcode helpfully recreating a `NookWidgetExtension` scheme (it is
  keyed by target id, which this generator re-rolls each run — hence generating
  it rather than leaving it to Xcode). The widget needs no scheme of its own:
  the app target depends on it and embeds the `.appex`, so building `Nook`
  builds the widget. To work on a widget in isolation, set
  `GENERATE_WIDGET_SCHEME = True` and re-run `make project` — that restores
  `NookWidgetExtension.xcscheme` and its `_XCWidgetKind` variable, which picks
  which widget `Run` previews (Xcode can't infer it once a bundle holds
  several).
- Keep `JournalParser` pure and jnl-faithful; add a case to `ParserChecks.swift`
  when you touch it.
- Guard platform-specific code with `#if os(macOS)` / `#if os(iOS)`; keep the
  shared path AppKit/UIKit-free so both platforms compile.
