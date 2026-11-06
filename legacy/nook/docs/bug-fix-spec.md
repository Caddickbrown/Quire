# Nook — Bug Fix Specification

**Date:** 2026-09-04 · **Baseline:** commit `6b27c29` on `main` · **Status:** delivered

> **2026-09-23:** all 67 findings implemented (`f5b07e5`, `3bfdea7`, `4eb9513`)
> and re-verified against `main` after the merge. Two notes on how the code
> reached the "done when" line by a different route than the spec proposed:
> **L1** — the Linux composer no longer has a text date field to clear, so the
> frontend validation the spec asked for is gone; the in-app popover can only
> emit a whole timestamp and the Rust `BAD_TIMESTAMP` refusal backs it.
> **D1** — `returnToInbox`, added after this review, reintroduced the defect on
> a new path and was fixed with the same `readForRewrite` helper.

This is the output of a full-project defect review (Swift app, WidgetKit + Share
extensions, Linux/Tauri port, build tooling). Every finding below was verified by
reading the code path end to end; items that could not be confirmed without a
device or a running build are marked **PLAUSIBLE**. Style and refactoring notes
were deliberately excluded — this is a fix list, not a wishlist.

## How to read this

- **Severity**: *Critical* = data loss or crash on a mainstream path · *High* =
  wrong behaviour a normal user will hit · *Medium* = edge case or degraded
  feature · *Low* = latent / cosmetic / docs.
- **Effort**: S ≤ 2h · M ≤ 1 day · L > 1 day.
- IDs are stable; reference them in commit messages (`Fix D1: …`).
- Each bug has a **Done when** line — that is the acceptance test. Where the
  code is pure (parser, search, list continuation) the test goes into both
  `Tests/NookTests.swift` and `Tests/ParserChecks.swift` (they must stay in
  step), and into `linux/src-tauri/src/search.rs` / `parser.rs` when the Rust
  side is affected.

## Summary

| ID | Sev | Area | Defect | Effort |
|----|-----|------|--------|--------|
| D1 | Critical | Store | Unreadable file is treated as empty and overwritten by the next append | S |
| E1 | Critical | Editor | Changing an entry's date silently drops every later autosave (and Delete/File) | M |
| L1 | Critical | Linux | Clearing the date field deletes the entry | S |
| E2 | High | Editor | Same-second twins: the `ts` fallback edits or deletes the wrong twin | M |
| E3 | High | Composer | Draft timestamp frozen at view creation; overnight Mac files to yesterday | S |
| E15 | High | Composer | Pasting text with `[timestamp]` headers multiplies entries on every autosave | M |
| D2 | High | Store | Custom folder that fails to resolve silently falls back to another journal | M |
| D3 | High | Transcription | Batch transcription rewrites files from a stale snapshot | S |
| S1 | High | Share (macOS) | macOS share extension never runs; sheet is blank | S |
| S2 | High | Import | Re-running a Day One import duplicates every entry with media | M |
| P1 | High | App Lock | Veil never covers the app in the switcher; `lock()` has no callers | S |
| P2 | High | App Lock | Veil sits under presented sheets (PLAUSIBLE) | M |
| N1 | High | Reminders | Daily reminder goes dark after the first "already written" day | S |
| L2 | High | Linux | Inbox search/sort re-seeds the editor from a stale snapshot; typing overwrites the saved edit | M |
| L3 | High | Linux | `toggle_star` picks the wrong same-second twin | S |
| L4 | High | Linux | Write failures swallowed; UI toasts "Saved" | M |
| D4 | Medium | Store | Cache patched as if the write succeeded | S |
| D5 | Medium | Backup | "On every change" skips the last change of a burst permanently | S |
| D6 | Medium | Sync | Remote updates dropped while typing; conflicts left unresolved | S |
| D7 | Medium | Stats | One future-dated entry zeroes the current streak | S |
| D8 | Medium | Model | Markdown-bold titles read as starred and get mangled by toggling | S |
| E4 | Medium | Journal (macOS) | Two-pane detail keeps a ghost editor after Delete / reload | S |
| E5 | Medium | Keyboard (iOS) | A hidden list re-registers on top and steals arrow keys | S |
| E6 | Medium | Preview | New `AVPlayer` allocated on every body evaluation | S |
| E7 | Medium | Navigation | `open`/`openDay` race the section-change path reset (PLAUSIBLE) | S |
| E8 | Medium | Editor | Programmatic text replacement bypasses undo (PLAUSIBLE) | M |
| N2 | Medium | Reminders | Today's unfiled drafts don't count as "written" | S |
| N3 | Medium | Reminders | Weekly note can pick a split-journal entry the tap can't open | S |
| N4 | Medium | Widget | `nook://timer` starts a 1-minute session on a fresh install | S |
| M1 | Medium | Assets | Delete removes files still referenced, no confirmation | S |
| M2 | Medium | Search | Plain terms match the timestamp header | S |
| M3 | Medium | Camera | `UIImagePickerController` `.camera` set without availability check (crash) | S |
| M4 | Medium | PDF | One page per day exceeds the PDF page-size limit (PLAUSIBLE) | M |
| P3 | Medium | App Lock | Entry text stays on the external display while locked | S |
| L5 | Medium | Linux | Heavy commands block the GTK main thread | M |
| L6 | Medium | Linux | Data Saver upscales images smaller than 2048px; non-atomic swap | S |
| L7 | Medium | Linux | `settings.json` written non-atomically and racily; lost folder silently falls back | S |
| L8 | Medium | Linux | Edits invisible after a section switch (flush not awaited) | S |
| L9 | Medium | Linux | Recordings cross IPC as a JSON number array | M |
| L10 | Medium | Linux | Inbox context menu dead after an in-place edit | S |
| L11 | Medium | Linux | Importer parity gaps (undated files, Day One timezone, preview count) | M |
| B1 | Medium | Build | `gen_pbxproj.py` output is non-deterministic and `make build` regenerates it | S |
| B2 | Medium | Build | Generator crashes when `xcuserdata/` holds `.DS_Store` | S |
| B3 | Medium | Build | Version numbers hard-coded four times | S |
| B4 | Medium | Build | macOS `Info.plist` lacks `LSApplicationCategoryType` | S |
| S3 | Low | Share | Activation rule omits audio | S |
| S4 | Low | Share | Read-then-delete window can drop a share (PLAUSIBLE) | S |
| S5 | Low | Intents | Cold-launch `OpenNewDraftIntent` notification can be lost (PLAUSIBLE) | S |
| D9 | Low | Templates | `{{date}}` uses `Locale.current` | S |
| E9 | Low | Lists | Ordered-list `Int.max` overflow; CRLF lines never continue | S |
| E10 | Low | Editor | Opening an entry can rewrite it without any edit | S |
| E11 | Low | Composer (iPad) | "Done" is a no-op | S |
| E12 | Low | Inbox | Starring an open draft from the row loses the star on next keystroke | S |
| E13 | Low | Journal | `DayView` re-reads the day file in `body` | S |
| E14 | Low | Attach | Non-media drops attach as broken image links | S |
| M5 | Low | Audio | `AudioRecorder.start()` not idempotent | S |
| M6 | Low | Widget | `NookSnapshot` decode has no field defaults (latent) | S |
| L12 | Low | Linux | Search/parser divergences (`BEFORE:` casing, media extension lists) | S |
| L13 | Low | Linux | Composer can fork a draft under load (PLAUSIBLE) | S |
| L14 | Low | Linux | Commands trust frontend paths; no CSP | M |
| L15 | Low | Linux | Byte-slicing dir names panics on non-ASCII | S |
| L16 | Low | Linux | Documented-but-missing: temp sweep, calendar dots, progress events, Ctrl+S label | S |
| L17 | Low | Linux | Audio memos saved as `.webm` treated as video | S |
| B5 | Low | Docs | `linux/README.md` stale vs the parity wave | S |
| B6 | Low | Docs | `CLAUDE.md`/`AGENTS.md` cite a non-existent `Nook/Nook.entitlements` | S |
| B7 | Low | Tests | `ParserChecks.swift` header command doesn't compile; test sets drifted | S |
| B8 | Low | Build | Scheme `LastUpgradeVersion` ≠ `LastUpgradeCheck`; `NookTests` not a build entry (PLAUSIBLE) | S |

## Assumptions

1. jnl byte-compatibility is non-negotiable: no fix may change the on-disk
   format. Where a fix touches format semantics (D8's star marker) the stricter
   reading is still valid jnl.
2. The "keep both" iCloud conflict merge is intended behaviour (it resurrects
   deletions and duplicates edited entries). It is listed under *Known
   behaviours* rather than as a bug; revisit only if users report it.
3. No Swift toolchain was available in the review environment, so Swift
   findings are code-verified, not run-verified. The Rust parser/search tests
   were run in a Tauri-free scratch crate and pass; the full `cargo test`
   needs `libwebkit2gtk`.
4. Priorities assume a pre-1.0 product whose worst outcome is silent data
   loss; anything that loses or duplicates text outranks anything visual.

---

## Workstream D — Data integrity (JournalStore)

### D1 · Unreadable file treated as empty and overwritten — **Critical**
- **Where:** `Nook/Models/JournalStore.swift:1757` (`fileEntry`), `:1727`
  (`appendEntries`), `:1125` (`upsertDraft`), `:1178` (`importDrafts`),
  `:2164` (`drainPendingShares`), `:1555` (`quickAddDraft`).
- **Cause:** every append does `(try? String(contentsOf:encoding:.utf8)) ?? ""`
  then writes `existing + new`. A read failure (non-UTF-8 byte from a
  hand edit or jnl, an evicted iCloud file — PLAUSIBLE — a transient permission
  error) is indistinguishable from an empty file, and the atomic replace then
  discards the original.
- **Repro:** put one Latin-1 byte in `journal/2026/09/01.md`; file a draft dated
  2026-09-01 → the day file now contains only the new entry.
- **Fix:** add a `readForRewrite(url) throws -> String` helper: if the file
  exists and cannot be decoded, throw and abort the write. Use it in all six
  sites. Optionally fall back to lossy decode only behind an explicit
  "repair" action in Settings → Maintenance.
- **Done when:** a unit-testable helper returns `.failure` for a non-UTF-8 file
  and every append path leaves the original file untouched in that case.

### D2 · Custom folder that fails to resolve silently falls back — **High**
- **Where:** `JournalStore.swift:173-187` (`resolveBase`), `:1548`, `:1567`
  (`quickAddDraft` / `inboxDraftCount`), `FolderAccess.resolve` (same file,
  ignores `bookmarkDataIsStale`).
- **Cause:** if the bookmark exists but does not resolve (volume unmounted,
  folder renamed, stale bookmark) the app silently uses iCloud or the local
  fallback, keeping the bookmark. The user writes into a second journal; the
  next launch flips back and the interim entries "vanish".
- **Fix:** introduce a `.unavailable(reason)` storage mode when a bookmark is
  present but unresolvable: show a banner with "Locate folder…" / "Use default",
  block writes until resolved. Re-mint the bookmark when `isStale` is true.
  Siri quick-add returns a "journal unavailable" error instead of writing.
- **Done when:** unmounting the custom volume and launching shows the banner
  and no file is written to the fallback location.

### D3 · Batch transcription rewrites files from a stale snapshot — **High**
- **Where:** `Nook/Models/Transcription.swift:149-155`.
- **Cause:** `content` is read, then `await transcribe(...)` runs for seconds
  to minutes, then `rewriteContentFile(file, insert(in: content))`. Any
  autosave to that file during the await (the composer writes `inbox.md`
  every 500 ms) is overwritten.
- **Fix:** re-read the file after the await; skip if the media link is no
  longer present; insert into the fresh content.
- **Done when:** typing in a draft during "Transcribe All" never reverts.

### D4 · Cache patched as if the write succeeded — **Medium**
- **Where:** `JournalStore.swift:1692-1693`, `:1707`, `:1041-1042`, `:1055-1056`.
- **Fix:** `guard (try? writeFile(...)) != nil else { report; return }` before
  `patchArchiveCache` / `patchSplitCache`. Surface the error through a new
  `@Published lastWriteError` that the root view shows as a toast.

### D5 · "On every change" backup skips the last change of a burst — **Medium**
- **Where:** `JournalStore.swift:282-295` (`journalDidChange`).
- **Cause:** the 30 s debounce fires inside the 300 s floor and *returns*
  without rescheduling. Edit at 10:00 (backup 10:00:30), edit at 10:02, stop →
  the 10:02 edit is never backed up.
- **Fix:** when inside the floor, sleep `floor - elapsed` then run.

### D6 · Remote sync updates dropped while typing — **Medium**
- **Where:** `JournalStore.swift:2307-2316` (`scheduleSyncReload`).
- **Cause:** returns when a local write happened < 2 s ago and never re-arms.
  With continuous autosave, every `NSMetadataQueryDidUpdate` during a writing
  session is discarded and `resolveFileConflicts()` never runs.
- **Fix:** on suppression, reschedule for `2 - elapsed` seconds; better, compare
  `contentFingerprint` rather than wall-clock.

### D7 · A future-dated entry zeroes the current streak — **Medium**
- **Where:** `JournalStore.swift:2028-2037` (`finishHeavyStats`).
- **Cause:** `dates` sorted ascending; a future date makes `anchor` yesterday
  and the back-walk starts at the future date, mismatches, breaks with 0.
  Widget, Stats and the streak-aware reminder all read it.
- **Fix:** filter `dates` to `<= today` before computing `currentStreak`.
- **Done when:** a test with `[today-2, today-1, today, today+30]` yields 3.

### D8 · Markdown-bold titles read as starred — **Medium**
- **Where:** `Nook/Models/Entry.swift:31` (`isStarred`),
  `JournalStore.swift:1063-1075` (`toggleStar`), Linux `store.rs:975`.
- **Cause:** `suffix.hasSuffix("*")`, so `**Important**` shows starred;
  un-starring drops one `*` → `**Important*`, still starred, title mangled.
- **Fix:** the marker is a standalone token: `suffix == "*" || suffix.hasSuffix(" *")`;
  strip exactly that. Mirror in `parser.rs`/`store.rs`.
- **Done when:** parser tests cover `"**bold**"` (not starred), `"title *"`,
  `"*"`, and toggle round-trips.

### D9 · `{{date}}` uses `Locale.current` — **Low**
- **Where:** `Nook/Models/Templates.swift:82`.
- **Fix:** `en_US_POSIX` for the ISO date/time tokens; keep `.current` for
  `{{weekday}}`-style display tokens only.

---

## Workstream E — Editor and save path

### E1 · Changing an entry's date drops every later autosave — **Critical**
- **Where:** `Nook/Views/EntryDetailView.swift:33` (`let entry`), `:342`
  (DatePicker), `:398-406` (`commit`), `:584` (`delete`), `:328-337` (File);
  `JournalStore.swift:1652-1665` (`updateDraft`), `:1685-1695`
  (`updateFiledEntry`), `:1034-1043` (`updateJournalEntry`).
- **Cause:** `commit()` always passes the immutable original `entry` as the
  lookup key. The store matches by `raw`, then falls back to `ts`. After the
  user changes date/time, commit #1 succeeds (raw match) and writes a new ts;
  commit #2 matches neither → silent `return`. The view still sets
  `baselineRaw = composedRaw`, so `isDirty` is false and nothing retries.
  Delete no-ops the same way; File appends but cannot remove from the inbox →
  duplicate. For `.archive`, the re-dated entry also stays in the *old* day file
  with a foreign-date header (there is no move-between-day-files path).
- **Repro:** open any entry → change the date → keep typing → close. Text typed
  after the date change is gone.
- **Fix:**
  1. `EntryDetailView` keeps `@State private var current: Entry` and passes
     it to the store; after each successful write set
     `current = JournalParser.parseEntries(composedRaw).first ?? current`.
  2. Store update methods return `Bool` (or the resulting `Entry`); the view
     advances `baselineRaw` only on success.
  3. In `updateFiledEntry`, when the parsed entry's `date != date`, remove
     from the old file and `fileEntry(routeSplit: false)` into the new day;
     return the new source so the view updates `source`.
- **Done when:** date change + typing + close preserves all text; the entry
  appears under the new day in Journal, Stream and Calendar; Delete works
  after a date change.

### E2 · Same-second twins: `ts` fallback hits the other twin — **High**
- **Where:** `EntryDetailView.swift:401-403`, `StreamView.swift:631-640`,
  delete paths `EntryDetailView.swift:584`, `StreamView.swift:439`,
  `ArchiveView.swift:376`; store lookups `JournalStore.swift:1657-1658, 1690,
  1039, 1052, 1702`.
- **Cause:** after the first commit the original raw no longer exists, so the
  ts fallback returns the *first* twin. Editing twin #2 overwrites twin #1.
- **Fix:** E1's "track the current entry" removes the fallback dependency.
  Additionally have the store fall back to ts only when exactly one entry has
  that ts; otherwise fail loudly.
- **Done when:** a day file with two `[08:00:00]` entries: editing the second
  three times only ever changes the second.

### E3 · Composer timestamp frozen at view creation — **High**
- **Where:** `Nook/Views/WritingView.swift:52` (`@State date = Date()`),
  `:525-530` (`reset`).
- **Cause:** `date` only resets after `newEntry()`/`discard()`. On macOS the
  Write section lives for the whole app lifetime; write the next morning →
  stamped with yesterday's launch time, filed to yesterday.
- **Fix:** stamp at first keystroke (`activeTS == nil && !hasText` → `date =
  Date()`), matching `jnl new`; also refresh on `scenePhase == .active` when
  the draft is empty.

### E15 · Pasting text with `[timestamp]` headers multiplies entries on every autosave — **High**
- **Where:** `Nook/Views/WritingView.swift:387-396` (`commit` → `upsertDraft`),
  `Nook/Models/JournalStore.swift:1117-1148` (`upsertDraft`), `:1098-1108`
  (`makeEntry`), `:1652-1665` (`updateDraft`, same shape), `:432-437`
  (`importEntries`).
- **Cause:** the composer treats its text as *one* draft, but the on-disk
  format has no way to escape a header line. `makeEntry` writes
  `[ts]\n<body>` verbatim; if the body contains two pasted entries, the next
  `parseEntries` of `inbox.md` yields three drafts. On the following autosave
  `upsertDraft` finds the composer's own draft by `ts`, replaces just that one
  with a fresh `[ts]\n<body-with-both-headers>` and leaves the two already
  split-out drafts in place. Each save therefore adds two more copies.
  Simulated: paste → 3 drafts, then 5, 7, 9, 11 after four keystrokes.
  "Import as separate entries" afterwards makes it worse: it removes only the
  composer's own `[ts]` entry, then appends the pasted entries again on top of
  the copies the autosaves already produced. `EntryDetailView` → `updateDraft`
  has the same shape (`replaceSubrange(idx...idx, with: parsed)`), so the
  same paste into an open draft also multiplies.
- **Repro:** copy two entries from a day file (or from jnl output), paste
  into Write, type a few characters, open Inbox.
- **Fix (recommended):** keep the composer's draft a single entry on disk.
  In `upsertDraft` and `updateDraft`, when the composed text parses to more
  than one entry, do **not** write it as-is: either (a) detect headers on the
  text change and surface the existing "Import as separate entries" action
  as a banner ("This looks like N entries — Import / Keep as one"), writing
  nothing until the user chooses, or (b) for "keep as one", neutralise the
  embedded headers on write (e.g. prefix with a zero-width space or indent by
  one space) so they no longer match the header regex, and strip that on
  read. (a) is the jnl-faithful option and reuses `importDrafts`; (b) changes
  bytes the user pasted. Whichever is chosen, `importEntries()` must remove
  every draft that came from the working text, not just `activeTS`.
- **Done when:** pasting two entries and typing ten characters leaves the
  inbox with either exactly one draft (kept as one) or exactly two (imported),
  never more; a `ParserChecks`/`NookTests` case covers `upsertDraft` with a
  multi-header body.

### E4 · Two-pane ghost editor after Delete / reload — **Medium** (macOS)
- **Where:** `Nook/Views/ArchiveView.swift:220, 253-263, 317, 376-382`.
- **Fix:** on `onChange(of: entries.map(\.id))` re-resolve `openEntry` by
  key/ts and nil it when absent; clear `selectedTS`/`openEntry` in `delete`.

### E5 · Hidden list re-registers on top and steals arrow keys — **Medium** (iOS)
- **Where:** `Nook/Views/KeyboardNavigation.swift:81-84` (`register`),
  re-registration at `:241-246`, `:277-284`.
- **Cause:** `register` = `removeAll` + `append`, and lists re-register on any
  `entries.map(\.ts)` change, which a `store.revision` bump triggers under a
  pushed view.
- **Fix:** replace handlers in place when the id already exists; append only
  when new.

### E6 · New `AVPlayer` on every body evaluation — **Medium**
- **Where:** `Nook/Views/MediaPreview.swift:367`.
- **Fix:** a `VideoView` holding `@State player`, created in `onAppear`,
  paused in `onDisappear` (mirror `AudioPlayerView`, `:572`).

### E7 · `open`/`openDay` race the section-change reset — **Medium, PLAUSIBLE**
- **Where:** `Nook/Views/RootView.swift:106-118`, `:234`.
- **Fix:** reset the path inside `open` itself and drop the generic
  `onChange(of: nav.section)` reset (or reset only from the sidebar binding).

### E8 · Programmatic replacement bypasses undo — **Medium, PLAUSIBLE**
- **Where:** `Nook/Views/WritingTextEditor.swift:140` (`tv.string = text`),
  `:472` (`tv.text = text`).
- **Fix:** route through `shouldChangeText` → `textStorage.replaceCharacters`
  → `didChangeText`, clamping the selection; or `undoManager?.removeAllActions()`
  on programmatic replacement.

### E9 · `ListContinuation` overflow and CRLF — **Low**
- **Where:** `Nook/Models/ListContinuation.swift:48` (`number + 1` traps on
  `Int.max`); `WritingTextEditor.swift:372`, `:735` (`hasSuffix("\n")` false
  for `\r\n`).
- **Fix:** `number &+ 1` (or clamp); trim `\r\n` as well as `\n`. Add the
  `Int.max` and CRLF cases to both test files. Note: `Int("007")` also
  produces a `prefixLength` shorter than the actual prefix — use the matched
  range length instead of re-rendering the number.

### E10 · Opening an entry can rewrite it — **Low**
- **Where:** `EntryDetailView.swift:70-72, 84, 411-418`.
- **Fix:** compute `baselineRaw` from `makeEntry(...)` of the *parsed* entry so
  non-canonical files are not dirty on open; set dirty only from `onChange`.

### E11 · iPad "Done" is a no-op — **Low**
- **Where:** `WritingView.swift:136-146`, `RootView.swift:332`.

### E12 · Star from Inbox row while open in the pane — **Low**
- **Where:** `InboxView.swift:203` + `EntryDetailView` `@State title`.
- **Fix:** sync `title/text/date` from `entry` on change when not dirty.

### E13 · `DayView` re-reads the day file in `body` — **Low**
- **Where:** `ArchiveView.swift:397` → `JournalStore.swift:866-870`.
- **Fix:** load once via `.task(id: store.revision)` or serve from
  `archiveEntries`.

### E14 · Non-media drops attach as broken image links — **Low**
- **Where:** `WritingView.swift:483-490`, `EntryDetailView.swift:503-510`.
- **Fix:** gate `.fileURL` drops on `UTType` conforming to image/movie/audio.

---

## Workstream P — Privacy (App Lock)

### P1 · Veil never covers the app on the way to the background — **High**
- **Where:** `Nook/Models/AppLock.swift:42-45` (`lock()`, no callers),
  `:68-71` (`didEnterBackground` only stamps a date), `RootView.swift:504`
  (veil doc claims it hides text "in the app switcher").
- **Fix:** on `.inactive`/`.background` with lock enabled set a `veiled` flag
  rendered by the same veil immediately; on `didBecomeActive` inside the grace
  period clear it without prompting, outside it prompt.
- **Done when:** the app-switcher snapshot shows the veil, not entry text.

### P2 · Veil sits under presented sheets — **High, PLAUSIBLE**
- **Where:** `RootView.swift:287-289` (`.overlay`).
- **Fix:** iOS: a separate `UIWindow` at `.alert` level; macOS: dismiss sheets
  on lock or use a window-level overlay.

### P3 · Entry text stays on the external display while locked — **Medium**
- **Where:** `AppLock.swift` never touches `ExternalDisplayModel`;
  `ExternalDisplayView.swift:102-105` keeps publishing.
- **Fix:** on lock `ExternalDisplayModel.shared.present(.idle)` and suppress
  `present` while locked.

---

## Workstream N — Reminders, widget, intents

### N1 · Daily reminder goes dark after the first "already written" day — **High**
- **Where:** `Nook/Models/Reminders.swift:153-164`.
- **Cause:** when `hasEntryToday`, the repeating request is replaced by a
  one-shot for tomorrow, relying on tomorrow's launch to re-plan. Don't open
  the app tomorrow → no reminders until the next launch.
- **Fix:** keep the repeating request under a second identifier and add the
  one-shot alongside; or schedule 7 dated one-shots per refresh.

### N2 · Today's unfiled drafts don't count as written — **Medium**
- **Where:** `JournalStore.swift:780-782` (`hasEntryToday` from day files
  only); `Reminders.swift:132`.
- **Fix:** OR with `inboxDrafts.contains { $0.date == todayISO }` (the
  word-goal path already does this).

### N3 · Weekly note can pick an entry the tap can't open — **Medium**
- **Where:** `Reminders.swift:219-222` (pool includes `.journal(name:)`),
  `NookApp.swift:264-274` (`openEntry` only searches archive + inbox).
- **Fix:** encode the source in `userInfo` and route `.journal`, or restrict
  the pool.

### N4 · `nook://timer` starts a 1-minute session on a fresh install — **Medium**
- **Where:** `NookApp.swift:196-197` (`integer(forKey:)` → 0 → `max(0,1)`),
  `RootView.swift:385` (`@AppStorage` default 15).
- **Fix:** `object(forKey:) as? Int ?? 15`, shared constant.

### S5 · Cold-launch `OpenNewDraftIntent` can be lost — **Low, PLAUSIBLE**
- **Where:** `NookIntents.swift:394-399` posts `.nookOpenWrite` synchronously.
- **Fix:** set `NotificationRouter.shared.pending = .write` (the pattern
  `Reminders.swift:38` already uses).

### M6 · `NookSnapshot` decode has no defaults — **Low, latent**
- **Where:** `Nook/NookShared.swift` (synthesized `Decodable`).
- **Fix:** custom `init(from:)` with `decodeIfPresent`, so a schema change
  never blanks the widget.

---

## Workstream S — Share extension and importers

### S1 · macOS share extension never runs — **High**
- **Where:** `NookShare/ShareViewController.swift:61-73` — the macOS class
  overrides only `loadView()`; `Task { await run() }` exists only in the iOS
  `viewDidLoad` (`:45-49`).
- **Fix:** add `viewDidLoad` calling `run()` on macOS (or hoist the call out of
  the `#if`).
- **Done when:** Share → Nook from Safari on macOS lands a draft.

### S2 · Re-running a Day One import duplicates media entries — **High**
- **Where:** `Nook/Models/Importers.swift:194-231` (`commitImport`) →
  `JournalStore.swift:2186` (`appendFiledEntries` dedupes by `raw`).
- **Cause:** media is copied through `saveAsset`/`importAsset` (fresh UUID
  path) and the body rewritten *before* the dedupe, so `raw` never matches
  on a re-run; every photo entry and every photo is duplicated.
- **Fix:** dedupe before copying media on a key that survives the rewrite:
  timestamp + body with media links stripped (or the original
  `dayone-moment://` id). Skip media copy for entries that will be skipped.
- **Done when:** importing the same export twice adds 0 entries and 0 files.

### S3 · Activation rule omits audio — **Low**
- **Where:** `NookShare/Info.plist:13-22` vs `ShareViewController.swift`
  handling `UTType.audio`.
- **Fix:** add `NSExtensionActivationSupportsAudioWithMaxCount = 1`.

### S4 · Read-then-delete window can drop a share — **Low, PLAUSIBLE**
- **Where:** `JournalStore.swift:2147-2183`, `ShareViewController.swift:305-311`.
- **Fix:** the app renames `pending.md` to a unique `.processing` name first
  and drains that; the extension only ever appends to `pending.md`. Or
  `NSFileCoordinator` on both sides.

---

## Workstream M — Media, search, export

### M1 · Asset delete with no reference check or confirmation — **Medium**
- **Where:** `Nook/Views/AssetsView.swift:171-178` → `JournalStore.swift:1291`.
- **Fix:** run `usages(ofAsset:)`; confirm, naming the N entries; refuse or
  offer "remove links too". `.destructiveAction()` only colours the label.

### M2 · Plain search terms match the timestamp header — **Medium**
- **Where:** `Nook/Models/SearchQuery.swift:66-67` matches on `entry.raw`.
  Same in `linux/src-tauri/src/search.rs:75`.
- **Repro:** search `2025` → every entry written in 2025.
- **Fix:** match terms on `suffix + "\n" + body`; keep `raw` for tags. Add the
  case to all three test sets.

### M3 · Camera picker without availability check — **Medium** (crash)
- **Where:** `Nook/Views/VideoRecorderView.swift:36` (`sourceType = .camera`
  unguarded; the photo path at `:73` checks).
- **Fix:** guard `isSourceTypeAvailable(.camera)`, dismiss with a message.

### M4 · PDF page exceeds the 14,400 pt limit — **Medium, PLAUSIBLE**
- **Where:** `Nook/Views/PDFExport.swift:39-46` (page height = content height).
- **Fix:** paginate: cap `pageHeight`, `beginPage` repeatedly translating the
  context by `-pageHeight * n`.

### M5 · `AudioRecorder.start()` not idempotent — **Low**
- **Where:** `Nook/Views/AudioRecorder.swift` (`start`).
- **Fix:** `guard !isRecording`, honour `rec.record()`'s Bool.

---

## Workstream L — Linux (Tauri) port

Test status: `cargo test --lib` cannot build here (`gdk-3.0` missing). The
parser and search tests pass in a Tauri-free scratch crate (2/2, plus 4
ad-hoc parity cases: en-dash, CRLF, round-trip, unparseable header).

### L1 · Clearing the date field deletes the entry — **Critical**
- **Where:** `linux/src/app.js:992-1001` (`composedRaw` builds `[${ts}]` with no
  validation; `inputToTs("")` returns `""`), `store.rs:920-926`
  (`update_filed_entry`), `:689` (`update_draft`), `:953`
  (`update_journal_entry`) — `splice(idx..idx+1, parse_entries(new_text))`
  with zero parsed entries removes the entry. Composer mirror: `app.js:442-472`
  sends `timestamp: ""`, `store.rs:604-617, 661` push `[] title` into
  `inbox.md`, which is absorbed into the previous draft on next parse.
- **Fix:** JS refuses to save unless `st.date` matches the full timestamp
  regex; Rust `update_*` and `upsert_draft` return `Err` when `new_text` is
  non-blank but parses to zero entries.
- **Done when:** clearing the date shows a validation state and the file is
  untouched.

### L2 · Inbox search/sort re-seeds the editor from a stale snapshot — **High**
- **Where:** `app.js:678-685` (`rebuild` maps fresh item objects), `:636-637`,
  `:388` (`teardownEditor` → `flush()` not awaited), `:1067`.
- **Fix:** `rebuild()` reuses item objects / applies `patchEntry` to
  `S.snap.inbox_drafts`; `flush` returns the commit promise and callers await.

### L3 · `toggle_star` picks the wrong twin — **High**
- **Where:** `store.rs:975` (`e.ts == ts || e.raw == raw`, ts first).
- **Fix:** use `find_entry` (raw-first, `:306-311`).

### L4 · Write failures swallowed — **High**
- **Where:** 18× `let _ = write_file(...)` in `store.rs`; `lib.rs` commands
  return `()`; `app.js:1056-1057` toast "Saved"/"Filed" unconditionally.
- **Fix:** `Result<_, String>` through store → command → `invoke`; surface
  rejections as an error toast and keep the editor dirty.

### L5 · Heavy commands block the main thread — **Medium**
- **Where:** `lib.rs:365` `backup_now`, `:303` `cleanup`, `:308`
  `merge_ex_split_journals`, `:179` `file_all_drafts`, `:213/218`
  rename/merge tags, `:40` `reload`.
- **Fix:** `async` + `spawn_blocking`, as `restore_backup` already does.

### L6 · Data Saver upscales small images; non-atomic swap — **Medium**
- **Where:** `media.rs:34` (`thumbnail(2048, 2048)` upscales anything smaller
  — `resize_dimensions(fill=false)` ratio > 1), `store.rs:1421` (`fs::write`
  over the asset).
- **Fix:** skip when both dimensions ≤ 2048; write temp + rename.

### L7 · `settings.json` non-atomic and racy; lost folder falls back silently — **Medium**
- **Where:** `store.rs:46-59`, `:88-95` (`set_pref` from a background
  thread), `:243-262` (`resolve_store` fallback).
- **Fix:** temp + rename; a mutex around read-modify-write; when
  `customFolder` is set but missing, report `storage_mode: "missing"` and
  block writes (pairs with D2).

### L8 · Edits invisible after a section switch — **Medium**
- **Where:** `app.js:388-389`. **Fix:** await the flush (see L2).

### L9 · Recordings cross IPC as a JSON number array — **Medium**
- **Where:** `app.js:523, 541` (`Array.from(buf)`) → `lib.rs:270` `Vec<u8>`.
- **Fix:** raw-body `tauri::ipc::Request`.

### L10 · Inbox context menu dead after an in-place edit — **Medium**
- **Where:** `app.js:690-693` vs `onSaved` `:607-616` rewriting `_key`.
- **Fix:** look up via the pane's item, not the captured `drafts` array.

### L11 · Importer parity gaps — **Medium/Low**
- **Where:** `store.rs:2185-2190` (skips undated markdown files; Swift falls
  back to file creation date, `Importers.swift:155-159`), `:2096` (Day One
  `creationDate` converted with `Local`, ignoring `timeZone` that Swift honours
  at `Importers.swift:89`), `:2144` (media-only entries dropped from the
  preview count).
- **Fix:** add `timeZone` to `DOEntry`; fall back to mtime; count media-only.

### L12 · Search/parser divergences — **Low**
- **Where:** `search.rs:50, 54` (`before:`/`Before:` only; Swift is
  case-insensitive); `parser.rs:93-94`, `search.rs:103-104`,
  `store.rs:399-400, 1954-1955` classify `webm/mkv/ogg/opus/flac` differently
  from `Media.swift:29-31`.
- **Fix:** `lower.strip_prefix`; one shared extension list per platform kept
  in step (add `webm`/`ogg` to the Swift lists too, since Linux records them).

### L13 · Composer can fork a draft under load — **Low, PLAUSIBLE**
- **Where:** `app.js:440-446` (debounced, not serialised), `store.rs:657-661`.
- **Fix:** chain commits on a promise.

### L14 · Commands trust frontend paths; no CSP — **Low**
- **Where:** `store.rs:1163` (`delete_asset(rel)`), `:1854/1878` (template
  name), `:946/957` (split name), `lib.rs:376` (backup name);
  `tauri.conf.json` `csp: null`, `assetProtocol.scope: ["**"]`.
- **Fix:** validate single path components / `starts_with(base)` after
  canonicalise; set a CSP; scope the asset protocol to the base folder.

### L15 · Byte-slicing directory names panics on non-ASCII — **Low**
- **Where:** `store.rs:1996` (`[..4]`), `:387`. **Fix:** `chars().take(4)`.

### L16 · Documented but missing — **Low**
- No `.nook-*.tmp` sweep (CHANGELOG says "Also Linux"); `linux/README.md:37`
  promises calendar media dots (`app.js:367` draws only the star);
  `app.js:1406` discards `media-progress` events; "New (Ctrl+S)" label vs
  Ctrl+N behaviour (`app.js:448, 1330, 1390`).

### L17 · Audio memos saved as `.webm` treated as video — **Low**
- **Where:** `app.js:531-532`, `media.rs:105-110`.
- **Fix:** distinct extension (`.weba`/`.opus`) or sniff for a video track.

---

## Workstream B — Build, tests, docs

### B1 · Non-deterministic generator; `make build` regenerates — **Medium**
- **Where:** `gen_pbxproj.py:21-22` (`uuid4` per run), `Makefile:24, 28`
  (`build-*: project`). Two runs differ from line 10; one run produces a
  722-line diff.
- **Fix:** `uuid5(NAMESPACE_URL, "nook:" + key)`. Committed output is
  currently *not* stale (byte-identical after masking ids).

### B2 · Generator crashes on `.DS_Store` in `xcuserdata/` — **Medium**
- **Where:** `gen_pbxproj.py:1128-1131` (`existing[0]` unfiltered).
- **Fix:** filter to `*.xcuserdatad` directories.

### B3 · Version numbers hard-coded four times — **Medium**
- **Where:** `gen_pbxproj.py:692, 716, 739, 749, 773, 783, 803, 807`;
  `CHANGELOG.md:25-27` says to bump one value.
- **Fix:** two module constants emitted once; reword the changelog note.

### B4 · macOS `Info.plist` lacks `LSApplicationCategoryType` — **Medium**
- **Fix:** `INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.lifestyle"`
  in `target_config`.

### B5 · `linux/README.md` stale — **Low**
- Omits `search.rs`; "everything except two Apple-only pieces" contradicts
  CLAUDE.md's Not-ported list; parity-wave features absent from "What works".

### B6 · Docs cite `Nook/Nook.entitlements` — **Low**
- Real files are `Nook-iOS.entitlements` / `Nook-macOS.entitlements`; sandbox
  keys are macOS-only. Tree listing repeats a line and omits
  `Tests/NookTests.swift`. Apply to both `CLAUDE.md` and `AGENTS.md`.

### B7 · Test hygiene — **Low**
- `Tests/ParserChecks.swift:6-7` header command omits three model files (use
  `make check`). `NookTests` has list-continuation cases `ParserChecks` lacks
  and vice versa for `leadingPreamble`/`renderEntries`. Copy each way.

### B8 · Scheme stamps — **Low, PLAUSIBLE**
- `gen_pbxproj.py:910, 1032` emit `LastUpgradeVersion = "1600"` vs
  `LastUpgradeCheck = 2650`; `NookTests` is only under `Testables`, not
  `BuildActionEntries`. Emit one `XCODE_STAMP` constant; add the test bundle
  as a build entry with `buildForTesting = YES`.

---

## Known behaviours (not scheduled)

- **iCloud conflict merge is "keep both"** (`JournalStore.swift:2332-2352`):
  a deletion on one device is resurrected by the other's version, and an
  edited entry appears twice (old + new); Clean Up removes only exact
  duplicates. Documented intent; revisit if it generates support noise.
- **Local/custom-folder watcher** only watches `<base>` and `<base>/journal`;
  in-place edits to existing day files by jnl are picked up on foreground,
  not live. Documented in the code.
- **`MediaLinks` treats any non-video/audio link as an image**, including
  `![](https://…)` remote links, so `has:image` matches them and thumbnails
  try to resolve them under `assets/`. Cosmetic until remote links are a
  feature.

## Checked and cleared

`toggleStar` on empty/whitespace titles · `upsertDraft` same-second nudging ·
`fileDraft` ordering (file first, remove second — failure yields a duplicate,
never loss) · `prune`/`nestingProblem`/`restoreBackup` · `resolveConflicts`
keep-both · DispatchSource cancel/close and `NSMetadataQuery` start/stop
balance · `MediaTranscodeQueue` serialisation and coordinated swap · Data
Saver per-device tally · `appendFiledEntries` dedupe · streak/DST math apart
from D7 · App Group / iCloud container ids across all six entitlements ·
`nook` scheme in both plists · usage strings · `SearchQuery` date boundaries
and whole-token tag matching · Day One timezone handling (Swift) · calendar
grid math · YearReview leap years · Spotlight rebuild/resolve · external
display brightness restore · `rowKeys` twin disambiguation · `tintTags` /
`parseMediaSegments` emoji safety · all AppKit/UIKit behind `#if` ·
committed `project.pbxproj` matches the generator · `CLAUDE.md` = `AGENTS.md`
· every Unreleased CHANGELOG bullet exists in code · no XSS in `app.js`
(every dynamic string passes `esc()`).

## Delivery plan

| Phase | Goal | Bugs | Gate |
|-------|------|------|------|
| 1 | Stop silent loss | D1, E1, E2, E15, L1, L4, D3 | `make check` + NookTests green; twin/date-change tests added |
| 2 | Platform-dead features | S1, S2, P1, N1, L2, L3 | manual: macOS share, Day One re-import, app switcher, reminder over 3 days |
| 3 | Correctness | D2, D4–D8, E3–E6, N2–N4, M1–M3, L5–L11 | unit tests for D7, D8, M2 in Swift + Rust |
| 4 | Hygiene | remaining Low + all B | `make project` idempotent; docs in sync |

Phase 1 and 2 are independent and can run in parallel. E1/E2 and L1/L4 are the
same design decision on two platforms (the store returns success and the
resulting entry; the view tracks it) — implement Swift first, port the shape.

## Next actions

1. Land Phase 1 as one PR per platform (Swift: D1/E1/E2/E15/D3; Rust+JS: L1/L4),
   each adding the acceptance tests named above.
2. Fix S1 in a two-line PR now; it unblocks macOS share testing for S2–S4.
3. Decide D2's UX (banner + "Locate folder…") before coding; it changes
   `storageMode` and Settings copy.
4. Add `webm`/`ogg` to the Swift media lists and unify the extension tables
   across `Media.swift`, `Entry.swift`, `parser.rs`, `search.rs`, `store.rs`.
5. Make `gen_pbxproj.py` deterministic (B1) before any further project edits,
   so later PRs stop carrying id-churn diffs.
