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
- On release: rename `[Unreleased]` to `## [x.y.z] — YYYY-MM-DD`, bump the
  module-level `MARKETING_VERSION` constant near the top of `gen_pbxproj.py`
  (and `CURRENT_PROJECT_VERSION` for a new build of the same version) — one
  edit each, applied to every target — run `make project`, and open a fresh
  empty `[Unreleased]` above it.

---

## [Unreleased]

### Added
- **Journal**: **Return to Inbox** — right-click (or long-press) a filed entry
  in the Journal, a day, Starred, Tags, Search or the Stream, or pick it from
  an open entry's ⋯ menu, to un-file it back into the inbox as a draft. The
  entry moves byte-for-byte (split-journal entries too), and it's written to
  the inbox before it leaves its day file, so a failed write can't lose it.
  Also in the Linux app.
- **App icon**: a dark-appearance variant (iOS 18+) — a green journal on a
  near-black ground, used when the Home Screen switches to dark or dimmed. (iOS)
- **Stream**: full keyboard navigation — ↑/↓ walk the page, ↩ opens the
  selected entry's in-place editor, ⎋ closes it — with the selection mirrored
  to the external display like every other list; rows also expose VoiceOver
  actions for File and Delete.
- **Tags**: a rendered `@tag` in Preview or the Stream is now a link — tapping
  it opens that tag's page.
- **Calendar**: grey days (unfiled drafts only) are tappable and open the
  Inbox; day cells carry VoiceOver labels.
- **Timer**: finishing plays a soft cue (haptic on iOS, a chime on macOS), and
  in Focus Mode a small countdown pill keeps the session visible while the
  sidebar is hidden.
- **Assets**: tap an asset to view it full size — images open fitted and zoom
  like the Photos app (pinch, pan, double-tap), video and audio play — plus
  **sort by date, size, kind, or name**.
- **Assets**: video tiles show a real poster frame with a play badge instead of
  a film glyph.
- **Assets**: a grouping toggle in the sort menu — no grouping, or date headers
  by day, month, or year (the headers stay pinned while you scroll).
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
- **External display** (iOS): plug into a monitor or TV and Nook gives it its
  own screen instead of mirroring the phone. It follows what you're doing —
  the composer puts your text up as a live wall with a blinking caret, word
  count, and tags; an open entry is laid out with its photos, video, and audio
  inline; with neither on screen it rests on the date and your current streak.
  Type is sized off the monitor, not the phone, and kept clear of TV overscan.
- **Keyboard**: ↑/↓ move a selection through the Inbox, Journal, Starred, a day,
  and a split journal; ↩ opens it, ⎋ clears it, `?` shows or hides the hint bar.
  The selected row is highlighted and scrolled into view. From the section menu
  the first ↑/↓ opens the Journal, so there's always something to browse. Works
  with any hardware keyboard, monitor or not; typing in a search or writing
  field keeps the keys for itself.
- **External display** (iOS): with nothing selected the monitor shows the
  journal at a glance — streak, days written, words, drafts — and turns into an
  entry browser on the first ↑/↓, tracking the selection on the device so you
  can pick an entry without looking at it.
- **External display** (iOS): a hint bar along the bottom lists the keys that
  are live on the current screen, since the device screen is dimmed and there's
  nowhere else to read them. `?` hides and shows it.
- **External display** (iOS): **Settings → External display → Dim this screen**
  turns the device's own brightness down while a display is connected, with a
  slider for how far, and puts it back when you unplug or quit. Off by default.
  Because Nook no longer mirrors, dimming the phone doesn't dim the monitor.
- **Composer** (iOS): a Done button (and ⎋) to save the draft and go back to the
  menu. The composer is opened by switching section rather than by pushing, so
  it never had a back button — there was no way out of it.
- **Composer / entry editor**: **Take Photo** in the attach menu — snap a
  picture with the camera and it attaches like any other asset (the system
  camera on iOS, a live preview with a shutter button on macOS).
- **Inbox**: a grouping toggle in the sort menu — date headers, or one flat list.
- **Journal, split journals, Starred**: the same grouping toggle as the Inbox —
  date headers, or one flat list where each row carries its own date.
- **Inbox, Journal, Starred**: pull down to open a random entry (iOS). The
  pull indicator is a spinning dice rather than the stock spinner.
- **Control** (iOS 18+): a New Draft control for Control Center, the Lock Screen
  control slots, and the Action Button — the same one-tap jump into the composer
  as the Lock Screen widget.
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
- **Stream**: a new sidebar section below Starred — the whole corpus on one
  scrolling page, oldest first, like reading straight down a paper journal. Times sit in a narrow margin — rotated bottom-to-top along
  the edge on iPhone, the way a book spine reads — with a star and a draft
  pencil beneath them, prose runs full-length with no previews and no
  truncation, and the day's date stays pinned at the top of the page while its
  entries scroll underneath.
  Tapping an entry edits it in place — title and body, autosaved, no push and
  no modal. The tray button chooses what's on the page: filed entries only,
  filed entries and unfiled drafts interleaved by time, or drafts only; drafts
  read at reduced opacity so they're clearly unfiled. Swipe left to delete,
  swipe right to file a draft (iOS); right-click for File, Star, Reveal in
  Finder and Delete.
- **App lock** (`Settings → Privacy`): Face ID / Touch ID / passcode gates the
  app, with a relock delay (immediately / 1 / 5 / 15 minutes) and a veil that
  hides entry text in the app switcher. The lock covers the app only — the
  files stay plain markdown on disk, and the setting says so.
- **Composer**: **writing prompts** (`Settings → Writing`) — the empty composer
  shows a question ("What surprised you today?"), stable per day, with a
  New Prompt reroll in the ⋯ menu.
- **Composer**: **templates** — plain markdown files in
  `<folder>/.nook/templates/` (managed in `Settings → Templates`, synced with
  the journal, hand-editable), inserted from the ⋯ menu with `{{date}}`,
  `{{time}}` and `{{weekday}}` filled in.
- **Editor**: **typewriter scrolling** (the line you're typing stays centred)
  and **focus mode for paragraphs** (everything but the current paragraph
  dims), both off by default in `Settings → Writing`.
- **Editor**: `**bold**` and `` `code` `` now render live while editing (as
  `_italic_` already did); ⌘B/⌘I wrap the selection in the markers; and ↩
  inside a `- `, `1. ` or `- [ ]` line continues the list (↩ on an empty item
  ends it).
- **Preview**: `- [ ]` task lines draw as real checkboxes — tappable wherever
  the entry is editable, writing the `x` back into the markdown.
- **Entries**: **Transcribe Voice Memos** in the composer's and entry editor's
  ⋯ menu — on-device speech recognition (nothing uploaded) inserts each
  memo's transcript beneath its audio link as ordinary searchable text.
- **Journal**: **On This Day** — a banner above the list whenever this
  calendar day has entries in past years, opening them grouped by year. The
  large widget and the external display's idle screen carry a one-line teaser.
- **Search**: a new sidebar section (⌘⇧F) searching the inbox, journal and
  split journals together, with an operator grammar — `tag:work`,
  `before:2026-03`, `after:2025`, `has:image|video|audio|media`, `is:starred`,
  and `"exact phrases"` (verified in `make check`).
- **Settings → Privacy**: opt-in **Spotlight indexing** — entries appear in
  system search (title, text, tags) and open in Nook; off by default.
- **Reminder** (`Settings → Reminder`): one daily notification at a chosen
  time, streak-aware — writing an entry cancels that day's nudge, and the copy
  carries the streak.
- **Word goal** (`Settings → Writing`, off by default): a daily target with a
  quiet progress ring next to the sidebar timer, a Today section in Stats, and
  progress on the medium/large widgets.
- **Stats**: **Year in Review** — per-year words, days, entries, longest
  streak, busiest day, top tags, media counts, plus a shareable card
  (stats-only unless you include the year's first line).
- **Export**: **PDF export** — a typeset PDF (entries, inline photos, the
  writing font) of a year or the whole journal from `Settings → Maintenance`,
  or one day from the day view's toolbar.
- **Import** (`Settings → Maintenance`): **Day One** JSON exports (dates,
  text, tags → `@tags`, photos/videos into `assets/`) and **folders of dated
  markdown/text files** (Obsidian daily notes work) become ordinary filed
  entries, with a count-and-confirm step; re-running an import skips entries
  already present.
- **Share extension**: share text, links, photos or video from any app and it
  becomes an inbox draft (media attached the usual `![](assets/…)` way). A new
  `NookShareExtension` target embedded next to the widget; shares land via an
  App Group handoff the app drains on next launch/foreground.
- **Sync**: **live refresh** — on iCloud an `NSMetadataQuery` reloads the
  store when another device changes a journal file (no relaunch); local and
  custom folders get a directory watcher on the base and journal folders.
  iCloud conflict versions of `inbox.md` merge as "keep both" (Clean Up
  removes exact duplicates), never last-writer-wins.
- **Widget**: the medium widget shows word-goal progress and the large one
  adds a today cell and the On This Day line.
- **Backup**: **Restore** — `Settings → Backup → Restore…` lists the
  timestamped copies and swaps one in; a safety copy of the current journal is
  always taken first, so a restore is itself restorable. (Also Linux.)
- **Composer / entry editor**: **tag autocompletion** — typing `@` offers your
  existing tags (frequency-ordered): a native completion list on macOS, a chip
  bar above the keyboard on iOS. Fixes near-duplicate tags at the source.
- **Editor** (iOS): the writing font follows **Dynamic Type** — the system
  text-size setting scales the px preference, so accessibility sizes reach the
  editor (SwiftUI text already scaled).
- **Media**: **auto-transcribe** (`Settings → Writing`, off by default) — a
  just-recorded voice memo transcribes itself, the words landing beneath the
  link; and **Transcribe All Voice Memos** (`Settings → Maintenance`) sweeps
  existing memos, with a merged per-device record in `<base>/.nook/` so no
  memo is transcribed twice across devices.
- **Print** (macOS): an entry (from its ⋯ menu) or a whole day (from the day
  view) prints through the PDF renderer's typeset layout.
- **Reminder**: **write from the banner** — the daily reminder carries a
  "Write a line…" text action that lands straight in the inbox, no app launch;
  and an opt-in **weekly "From your journal"** note resurfaces one entry
  (starred first, then this day in past years), tap-through to the entry.
- **Search**: **saved searches** — pin a query and it appears under Saved
  Searches in the sidebar, stored as `<base>/.nook/searches.json` so pins sync
  across devices and stay hand-editable. (Also Linux.)
- **Stats**: **Trends** — a GitHub-style year heat strip (words per day, also
  on the Year in Review sheet and its shareable card), words per month, and
  the top tags' monthly counts, drawn with Swift Charts.
- **Timer** (iOS): a **Live Activity** — the writing session counts down in
  the Dynamic Island and on the Lock Screen (word-goal progress alongside when
  the goal is on), ending itself with the timer.
- **Welcome**: a one-screen first-run sheet — where the words live, the
  inbox→journal flow, the import pointer, the privacy stance — skippable and
  never seen again.
- **Widget**: the On This Day line now **opens that entry** (via the new
  `nook://entry` deep link, which notifications share) instead of the
  composer, and the medium widget gains a Start Timer link (`nook://timer`).
- **Linux**: the parity wave — global search with the full operator grammar
  (ported to `search.rs`, unit-tested), saved-search pins in the sidebar,
  templates + writing prompts, On This Day banner, words-today + word goal in
  Stats, Year in Review, Day One / markdown-folder importers with the same
  count-and-confirm step, and backup Restore. (Linux)
- **Calendar**: day cells carry media-typed dots, matching the Apple apps. (Linux)
- **Settings**: "Compress Existing Media" reports its progress while it runs. (Linux)
- **Share extension**: audio files can be shared into Nook from other apps.
- **Storage**: a journal folder Nook can't reach — an unplugged drive, a folder
  moved or deleted — is now called out in a banner offering **Locate Folder…**
  and **Use Default**, with the same recovery in Settings → Journal folder.

### Changed
- **Performance** (large journals): section switches and edits no longer wait
  on background work — every mutation patches the on-screen lists instantly
  from the file it just wrote, and the full re-index runs debounced behind it;
  the index, corpus cache, and stats all come from a single read of each file
  (it was two full passes, three with Spotlight on — Spotlight now indexes
  from the cache instead of re-reading the journal); returning to the app
  only reloads when a cheap stat-walk fingerprint says something on disk
  actually changed; and a per-row identity rebuild that made 4,000-entry lists
  O(n²) is computed once per list change. iCloud download checks are skipped
  entirely for local folders.
- **Export**: the combined markdown export now includes the split journals
  after the dated days — they're filed entries too, and were silently left
  out. (Also Linux.)
- **Performance**: the parsed journal is cached alongside the index (built
  off-main), so the Journal, Starred, Stream, Search, Tags, Random, and
  asset-usage lookups no longer re-read every file on the main thread; the
  editor re-styles only the edited paragraph per keystroke instead of the
  whole document; date formatters are cached per style; entry-row thumbnails
  decode off the main thread; and "File All" writes each destination file
  once instead of once per draft. (File All batching also Linux.)
- **Inbox / Stream** (iOS): filing or deleting by swipe confirms with a light
  haptic.
- **Stats**: the streak no longer reads 0 all morning — until today's entry is
  written, the current streak counts back from yesterday, in the app, the
  Stats sheet, and the widget. (Also Linux.)
- **Performance**: the full-corpus stats pass (word counts, streaks, size
  breakdowns) runs off the main thread alongside the index rebuild instead of
  re-reading every journal file on the main thread after every change; the
  Tags pane loads a tag's entries once per change instead of on every
  keystroke; and the widget snapshot is only written (and WidgetKit only asked
  to reload) when a number the widget shows actually changed.
- **Assets**: the grid is a photo gallery — uniform square tiles with hairline
  gaps, capped so they stay thumbnail-sized on a wide window, and no uuid
  filename captions.
- **Assets**: the gallery dates media by the entry that uses it, not by when
  the file landed on disk — so a photo imported today into a back-dated entry
  sorts and groups under that entry's day. Media no entry references still
  falls back to the file's own date.
- **Inbox**: the right-click menu says "File", matching the swipe action, the
  entry editor's button, and jnl's own vocabulary — it used to say "Archive".
- **Destructive actions** are red everywhere — Delete in the inbox, journal,
  entry editor and assets menus, Discard in the composer, and Clear Orphan
  Media. `role: .destructive` alone left several of them looking ordinary.
- **Entry editor**: Preview lines up with the editor instead of sitting 8pt
  further in, so toggling Edit/Preview no longer shifts the text sideways; the
  editor's header now matches the composer's spacing exactly.
- **Build**: the project carries Xcode 26's recommended settings — the
  recommended warning set, dead-code stripping, app-group registration, user
  script sandboxing, string-catalog symbols, asset symbol extensions, and a
  project-level `DEVELOPMENT_TEAM` both targets inherit — so Xcode stops
  offering to update them. They live in `gen_pbxproj.py`; accepting Xcode's
  sheet instead would be undone by the next `make project`.
- **Build**: `gen_pbxproj.py` now emits a third target, `NookShareExtension`
  (the share extension), embedded into the app beside the widget; its scheme
  autocreation is suppressed like the widget's, so the selector still shows
  just `Nook`.
- **Check**: `make check` also compiles `Models/SearchQuery.swift` and
  `Models/ListContinuation.swift`, running the search-grammar and
  list-continuation cases alongside the jnl-parity ones.
- **Build**: a real **XCTest target** (`NookTests`, generated like the rest) —
  hostless logic tests over the pure model files (parser parity, the search
  grammar, list continuation), run via the Nook scheme's Test action
  (`xcodebuild test -scheme Nook -destination 'platform=macOS'`).
- **Editor**: list-continuation rules moved to `Models/ListContinuation.swift`
  (pure) so both platforms share one tested implementation.
- **Linux**: the portable features are now ported (see the Linux bullet under
  Added); still Apple-only by nature or by choice: transcription (would go via
  a whisper CLI), PDF export (use the webview's print instead), Spotlight, app
  lock, widgets/Live Activity, notifications, and the share extension. The
  on-disk format is unchanged throughout.
- **Build**: Xcode's scheme selector shows one scheme, `Nook`, instead of also
  offering `NookWidgetExtension`. The widget was never separate to ship — the
  app depends on it and embeds the `.appex`, so building `Nook` builds it — and
  running the extension's scheme only ever popped an app-picker dialog. Set
  `GENERATE_WIDGET_SCHEME = True` in `gen_pbxproj.py` to get it back for widget
  work.
- **Entry rows**: one row template everywhere — the Inbox, Journal, Starred,
  days, and split journals all share the same layout (title, body snippet,
  a date/time · words · media meta line, tags) instead of two near-identical
  ones; only the meta line's date/time varies by list. The Inbox gains the
  body snippet, the Journal loses the date crammed onto the title line,
  untitled entries no longer repeat their first line in the snippet, and the
  tag line's height is kept even on untagged entries, so tagged and untagged
  rows stand the same height.
- **Entry rows**: the thumbnail is bigger and sits on the right of the row,
  bleeding slightly into the row's margins so the picture, not whitespace,
  fills the corner.
- **Sidebar** (iOS): the "nook" title is gone — the section list stands on its
  own and the title only crowded it. macOS still uses it as the window title.
- **Calendar**: the month/year picker is a real picker — two wheels on iOS, two
  pop-up menus on macOS — instead of a month menu plus a year stepper.
- **Entry view** (iOS): the controls moved into the navigation bar, so an entry
  no longer pays for two rows of chrome before the text starts.
- **Journal**: the toolbar puts the dice before sort, matching the Inbox.
- **Journal, split journals, Starred**: entry rows show their `@tags`, as the
  Inbox rows already did.
- **Calendar**: the month/year picker has no "Done" button — the wheels apply as
  you spin them and the popover closes on a tap outside.
- **Build**: the marketing version and build number are defined once at the top
  of `gen_pbxproj.py` instead of being repeated per target, so a release bump is
  a single edit.
- **Media**: `webm`, `weba`, `mkv`, `ogg`, `oga`, `opus` and `flac` are
  recognised everywhere, so recordings made by the Linux port are shown as video
  or audio on Apple platforms too rather than as images.
- **Performance**: autosave no longer re-parses the whole entry two or three
  times per save to check for pasted `[timestamp]` headers — one scan, and the
  header pattern only for lines that could be one. Re-running a Day One import
  no longer compiles a fresh pattern for every entry it compares; the daily
  reminder is only re-planned when something that shapes it has changed
  (before, ~15 notification-centre calls after every editing pause); and the
  streak, same-second-twin lookup and two-pane resync each do less work per
  call.
- **Performance**: `settings.json` is read and parsed once and kept until the
  next write, instead of on every single command. A hand edit to the file
  while Nook is running is picked up on the next write or relaunch. (Linux)
- **Templates**: `{{date}}` and `{{time}}` always render as an ISO date and
  24-hour time whatever the device's locale or calendar; `{{weekday}}` stays
  localised.

### Changed
- **Tests**: the XCTest bundle now covers `JournalStore` as well as the pure
  model files. It stays hostless — a store can be rooted at a temporary folder,
  so its read-modify-write paths are exercised against real files without
  launching the app or being able to reach iCloud. The two defects that reached
  `main` both lived in that layer and neither was reachable by a test before.

### Fixed
- **Performance**: typing no longer stutters in a large journal. Autosaving a
  draft re-read and re-parsed the whole inbox every time (~28 ms on the main
  thread with ~900 drafts); it now reuses the parse when the file on disk is
  byte-identical to what Nook last wrote (~1.5 ms). Separately, every autosave
  was echoing back through the file watcher and triggering a full conflict scan
  and corpus reload a couple of seconds later — around 200 ms of stall, on
  repeat, for the length of a writing session. The echo is suppressed again,
  with a 20-second ceiling so a change from another device still lands promptly,
  and the conflict scan now runs off the main thread and only looks at files
  iCloud has actually flagged.
- **Return to Inbox**: returning an entry while `inbox.md` couldn't be read
  replaced every draft in it with the returned entry. An unreadable file (one
  stray non-UTF-8 byte from a hand edit or `jnl`) was indistinguishable from an
  empty one, so the append had nothing to append to. Both reads now refuse
  instead, leaving the file untouched and reporting it — and a failed return
  says so rather than doing nothing. (Also Linux.)
- **Search / Starred / Tags**: an edit made from one of these lists can no
  longer land in the wrong file. They merge entries from the inbox, the archive
  and the split journals into one list, and an inbox draft that shared its
  second with a filed entry collapsed onto it — the pair drew as a single row,
  and saving the draft overwrote the filed entry instead. The merged list is
  renumbered so the two stay distinct.
- **Performance**: lists, the open editor and the Stream no longer rebuild
  themselves every time anything is saved. Entries used to be re-identified on
  every parse, so nothing on screen ever matched what the store held; entry
  identity is now the timestamp plus a twin index, stable across reloads.
- **Settings** (iOS): ⌘, works again on an iPad keyboard — Nook was registering
  a second Settings shortcut alongside the system's, and the menu builder
  discarded one of them.
- **Reminders**: tapping the daily writing reminder now opens the composer
  instead of just launching the app where you left it, and a tap that launches
  the app cold is no longer dropped — the resurfacing note's entry link lands
  reliably too.
- **Write** (iOS): the composer no longer shows two back chevrons on iPhone —
  the collapsed navigation stack already supplies one, so its own Done arrow now
  appears only at regular width (iPad), where there is no system back button.
- **Backup**: choosing a backup folder inside the journal folder (or the
  reverse) is refused — backing up would recurse, and restoring would delete
  its own source partway. (Also Linux.)
- **Sync**: iCloud version conflicts on day files and split journals now merge
  as keep-both, like the inbox — a two-device day used to resolve silently to
  whichever version won; Data Saver's in-place media swap is coordinated
  through NSFileCoordinator so it can't race a sync of the same file.
- **Spotlight**: two entries sharing a second no longer collide in the index
  (occurrence-suffixed identifiers, resolved back to the right twin).
- **Data safety**: journal writes are truly atomic now (an in-place
  `replaceItemAt` swap instead of remove-then-move), so a crash mid-save can no
  longer leave an entry file existing only as a hidden temp file; stale
  `.nook-*.tmp` strays are swept on launch. (Also Linux.)
- **Inbox**: "File All" removes only the drafts that actually filed — a draft
  whose write failed stays in the inbox instead of being deleted with it, and
  drafts added by Siri or jnl since the last load are never touched. (Also
  Linux.)
- **Entries**: two entries sharing the same second can no longer be edited or
  deleted as one — edits and deletes match on the entry's full text first, a
  delete removes exactly one entry, and the composer nudges a new draft off an
  already-taken second instead of overwriting an unrelated draft. Lists render
  same-second twins as their own rows too. (Also Linux.)
- **Lists**: filing, deleting, starring, and in-place edits refresh the
  Journal, Starred, and Stream immediately — a deleted or renamed entry could
  previously linger in a list until the next full reload.
- **Tags** (Linux): renaming or merging tags did nothing — the rename pattern
  never compiled (the regex engine has no lookahead). Rewritten so whole-token
  renames work.
- **Maintenance**: Clean Up's punctuation pass no longer reaches inside
  `![](…)` media links, so a filename or URL containing "..." can't be
  rewritten into an ellipsis and broken. (Also Linux.)
- **Media**: a voice memo still recording when its editor closes is stopped and
  attached instead of silently lost, and the microphone session is released
  afterwards so other apps' audio un-ducks. (iOS)
- **Media**: videos picked from the Photos library or dropped onto an editor
  stream to disk as files instead of being buffered whole in memory.
- **Sync**: the app reloads on foreground/activation, picking up edits from
  another device, the jnl CLI, or a Siri quick-add; not-yet-downloaded iCloud
  files (`.icloud` placeholders) now trigger a download instead of reading as
  missing days.
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
- **App Lock**: the veil now covers the app on the way to the background, so
  entry text no longer shows in the app switcher, and it sits above any open
  sheet instead of underneath it. Returning within the grace period stops
  asking for Face ID again.
- **App Lock**: locking blanks a connected external display back to its idle
  screen instead of leaving the open entry on the monitor.
- **App Lock**: with more than one Nook window open (Split View or Stage
  Manager on iPad, ⌘N on the Mac) the lock covered only one of them; every
  window is veiled now, including one opened while locked.
- **Assets**: deleting a file asks first and says how many entries still link
  it — the links break, and nothing else warned about it.
- **Assets**: inline video no longer restarts from the beginning on every
  redraw, and stops playing when scrolled away.
- **Backup**: "On every change" no longer skips the last edit of a burst. An
  edit inside the five-minute floor was dropped rather than deferred.
- **Build**: `make project` is reproducible — object ids are derived from their
  names instead of randomised per run, so regenerating no longer rewrites every
  line of `project.pbxproj`.
- **Build**: the generator no longer crashes when Finder leaves a `.DS_Store`
  in `Nook.xcodeproj/xcuserdata/`.
- **Build**: the generated scheme is stamped for the current Xcode rather than
  1600, and builds the `NookTests` bundle as part of its build action.
- **Build**: the app declares an App Store category, which macOS requires in
  `Info.plist`. (macOS)
- **Composer**: the draft's timestamp is taken at the first keystroke rather
  than when the composer was created. Writing the next morning on a Mac left
  running stamped the entry with yesterday and filed it to yesterday.
- **Composer**: pasting text that already carries `[timestamp]` headers
  multiplied drafts on every autosave — three, then five, then seven. The
  composer now asks **Import** or **Keep as one** and writes nothing until you
  choose; "Keep as one" escapes the pasted headers as `\[…]`, which renders as
  written and stays one entry.
- **Composer**: dropping a non-media file no longer attaches it as an image
  link the renderer can't show; it's refused with a note.
- **Composer**: clearing or half-typing the date deleted the entry it was meant
  to save. The date is now picked from an in-app popover that can only hand back
  a whole timestamp, and a malformed one is refused before it's written rather
  than saved as an entry-less `[]` header. (Linux)
- **Composer**: a fast autosave could fork the draft in two; writes are
  serialised. (Linux)
- **Composer**: "Done" did nothing. It now saves the draft and opens the Inbox.
  (iPad)
- **Composer**: a date picked in the composer before typing is kept — the
  first-keystroke stamp no longer overwrites it with "now".
- **Composer**: choosing **Import** for a paste that carried `[timestamp]`
  headers dropped anything typed above them; that note (and the title) now
  stay in the composer as the working draft.
- **Data Saver**: photos smaller than 2048px were *enlarged* rather than left
  alone, and the re-encode wrote over the original in place; it is now atomic.
  (Linux)
- **Editor**: changing an entry's date silently dropped every edit made after
  the change, and left Delete and File doing nothing on that entry.
- **Editor**: re-dating a filed entry now moves it into the right day's file —
  it appears under the new day in Journal, Stream and Calendar instead of
  staying behind under a foreign date header.
- **Editor**: two entries written in the same second no longer overwrite each
  other when you edit or delete the second one.
- **Editor**: opening an entry no longer rewrites its file before you have
  typed anything.
- **Editor**: Undo no longer replays edits from a previous entry after the
  editor's text is swapped (entry switch, template insert, incoming sync).
- **Editor**: ↩ continues a list correctly on Windows (CRLF) lines and on
  zero-padded numbers like `007.`.
- **Editor**: edits made in one section no longer go missing when switching
  sections — the pending autosave is awaited first. (Linux)
- **Editor**: the ★ button, Preview and the Stream editor use the same star
  rule as the model — a markdown-bold title like `**Important**` is no longer
  shown starred or mangled by toggling it there either.
- **Import**: re-running a Day One import duplicated every entry that had a
  photo, and re-copied the photos. Imports now skip entries already filed,
  media included.
- **Import**: Day One entries honour their own time zone, photo-only entries
  are counted in the preview, and undated markdown files fall back to the
  file's own date instead of being skipped. (Linux)
- **Inbox**: starring an open draft from its row no longer loses the star on
  the next keystroke.
- **Inbox**: searching or re-sorting could re-open a just-edited draft from a
  stale copy, and typing then overwrote the saved edit. (Linux)
- **Journal**: deleting an entry in the two-pane view no longer leaves an
  editor open on an entry that is gone, and an entry changed on another device
  is picked up in place. (macOS)
- **Journal**: a day's page no longer re-reads its file from disk on every
  redraw.
- **Journal**: re-dating an entry in the two-pane view no longer closes the
  editor under you when the entry moves to another day. (macOS)
- **Keyboard**: arrow-key list navigation no longer jumps to a list that is off
  screen behind a pushed view. (iOS)
- **Maintenance**: leftover `.nook-*.tmp` files from interrupted writes are
  swept on launch. (Linux)
- **Navigation**: opening an entry or a day from a link or notification could
  be wiped by the section-change reset landing after it.
- **PDF export**: a day whose content exceeds PDF's 14,400 pt page limit is
  split across pages instead of producing an invalid one.
- **Performance**: File All, cleanup, tag rename and merge, split-journal
  merge, backup and reload no longer freeze the window. (Linux)
- **Recording**: tapping Record twice no longer strands the first recording,
  and a recording that fails to start no longer shows a running timer.
- **Recording**: audio and video cross to the backend as raw bytes rather than
  as a JSON array of integers. (Linux)
- **Recording**: voice memos captured in a WebM container are saved as `.weba`
  and treated as audio rather than video. (Linux)
- **Reminders**: the daily reminder stopped appearing after the first day you
  wrote before it fired, until Nook was opened again. It now plans a rolling
  two-week window.
- **Reminders**: an entry still sitting unfiled in the Inbox counts as having
  written today, so the reminder doesn't nag.
- **Reminders**: tapping the weekly "From your journal" note could open nothing
  when it teased an entry from a split journal.
- **Search**: a plain term searches an entry's title and body, not its
  timestamp header — searching `2025` no longer returns every entry written
  that year. Use `before:` / `after:` for dates.
- **Search**: `Before:` and `After:` work in any case, matching the Apple
  apps. (Linux)
- **Share extension**: sharing to Nook from another Mac app opened an empty
  sheet and captured nothing. (macOS)
- **Share extension**: a share captured while Nook was draining shared items is
  no longer lost.
- **Share extension**: audio files can actually be shared in — the activation
  rule now uses the file key, since Apple's dictionary form has no audio key.
  Nook therefore appears in the share sheet for any single file, and quietly
  completes for one it can't use.
- **Shortcuts**: "New Draft" from Siri, Shortcuts or the Control Center control
  could land on the journal instead of a blank composer when it launched the
  app.
- **Shortcuts**: Ctrl+N starts a new entry in the composer, and the button and
  how-to text match the key that actually works. (Linux)
- **Starred**: a markdown-bold title like `**Important**` read as starred, and
  un-starring it dropped one `*` and left the title mangled. The marker is a
  standalone `*` — either the whole title or preceded by a space.
- **Starred**: starring an entry that shares its second with another one
  starred the wrong twin. (Linux)
- **Stats**: a single future-dated entry no longer resets the current writing
  streak to zero in Stats, the widget and the daily reminder.
- **Storage**: a journal file that can't be read — a stray non-UTF-8 byte from
  a hand edit, an evicted iCloud file — was treated as empty and replaced by
  the next append. Every append, and Cleanup and tag rename/merge, now refuse
  and report instead. Cleanup was rebuilding such a file from nothing.
- **Storage**: a custom folder that can't be resolved silently fell back to
  iCloud, so entries went into a second journal that seemed to vanish on the
  next launch. Writes are blocked until it is found again, and a folder that
  was renamed or moved has its bookmark refreshed automatically.
- **Storage**: writes that don't reach disk surface a message instead of
  failing silently and leaving the app showing a change that was never saved.
- **Storage**: failed writes reported "Saved"; they now show an error and keep
  the entry unsaved so the next save retries. (Linux)
- **Storage**: an unavailable journal folder is reported and blocks writes
  instead of silently writing into `~/Documents/Nook`, and `settings.json` is
  written atomically under a lock so a crash can't lose the folder. (Linux)
- **Sync**: updates from another device were discarded for as long as you kept
  typing, and iCloud conflicts were never resolved.
- **Timer**: the `nook://timer` link started a one-minute session instead of
  the default 15 on a fresh install.
- **Transcription**: "Transcribe All" no longer reverts edits you make while it
  runs — each file is re-read after recognition finishes.
- **Video**: recording on a device with no available camera crashed; it falls
  back to the photo library, as taking a photo already did.
- **Widget**: a change to the shared snapshot's shape could leave the widget
  showing blank stats.

### Security
- **Linux**: file names coming from the UI can no longer escape the journal
  folder, the webview's file access is scoped to that folder, and a Content
  Security Policy is enforced.

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
