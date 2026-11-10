# Quire: what's wrong and what to fix

A review of the whole app on 2026-11-09, at `main` `b87666a`, written as a
spec: each item says what is wrong, how it shows, the fix, and how to know it
is fixed. It follows `docs/suggestions.md` (2026-11-06) and does not repeat
that document's ideas; section 9 lists which of its faults are still open.

**Status, 2026-11-10.** Most of this is done: `docs/fix-report.md` says what
was fixed, how it was checked and what is still open.

**How it was done.** Eight independent read-throughs, one per area (core
storage, core media and maintenance, terminal, Linux, the iOS editor, the Apple
model layer and extensions, the Apple screens and monitor, install and
release). Every source file outside `legacy/` was in scope; six of the older
Mac views (`ArchiveView`, `InboxView`, `PDFExport`, `VideoRecorderView`,
`YearReviewView`, `Attachments`) were only scanned for crashes and write calls.
`make test` passes. Nothing else was built or run, and no device was used.

**How sure each item is.**

- **Checked**: I re-read the code after the reviewer and it is as described.
- **Read**: one reviewer traced the path through the code; not re-checked.
- **Hypothesis**: the code allows it, but it needs a device or a debugger to
  prove. These say what evidence would settle them.

IDs are stable so work can refer to them: `E` editor, `A` Apple, `C` core,
`T` terminal, `L` Linux, `R` release and install.

---

## 1. Order of work

1. **The iOS editor (section 2).** It is what is broken in daily use, and two
   attempts have already gone wrong. Do E1 to E4 first, each proven on the
   simulator before it reaches a phone.
2. **Anything that can lose writing or media (section 3).** Twelve items,
   most of them small changes.
3. **Stale references and wrong targets (section 4).** Actions landing on the
   wrong entry, or refused with a false "changed on disk".
4. **Backups (section 5).** The same three faults exist in all three shells.
5. **The rest by shell (sections 6 and 7), then release and docs (section 8).**

Six decisions are Dan's and are collected in section 10.

---

## 2. The iOS editor

Four known problems. The first two were attempted on 9 November; the build
froze the composer and `b87666a` took the editor back to `cb5379c`.

### E1. Tap below the words does nothing, and the attempt froze the app

**Wrong.** On a new page the body's `UITextView` is about two lines tall.
`sizeThatFits` returns the measured text height
(`Views/WritingTextEditor.swift:789`), and `.frame(minHeight: 360)`
(`Design/ComposerScreen.swift:261`) pads the SwiftUI frame around it, not the
text view. A tap in the padding hits nothing. *(Checked.)*

**Why the attempt froze (hypothesis, two candidates).**

- *Most likely: a first-responder fight.* The attempt added a background tap
  that set `focus = .body`, which called `becomeFirstResponder()` inside
  `updateUIView`. The file's own comment forbids that
  (`WritingTextEditor.swift:629-637`). Focus has four arbiters that each force
  the keyboard to match their view of it: `.focused($focus)` on both fields, a
  manual `Binding` on both, an async block queued on every `updateUIView` of
  both, and `KeyCommandController`, which takes first responder when nobody
  holds it (`Views/KeyboardNavigation.swift:252-273`). If the writes land out
  of order, title and body take the keyboard from each other in turn.
  `ComposerScreen.swift:613-618` already records this failure once. "Caret
  left in the title" fits the title winning.
- *Second: the temporary log.* Its `layoutSubviews` override forced glyph
  layout on every pass and opened, appended and closed a file twice per pass
  (its de-duplication compared two alternating lines, so it never matched).
  Under TextKit 1 that can loop inside one layout commit.

**To settle it:** look for a hang report from 9 November on the phone
(Settings › Privacy › Analytics Data), or rebuild `4a4aba1` in the simulator,
reproduce, pause, and read the main-thread stack. Alternating
`becomeFirstResponder` frames mean the first; `layoutSubviews` → `caretRect`
means the second.

**Fix.**

1. No focus code for this at all. Pass a minimum height into
   `WritingTextEditor` and return `max(measured, minHeight)` from
   `sizeThatFits`. The text view then covers the page and UIKit's own tap
   handling puts the caret after the last word.
2. Never change first responder inside `updateUIView`.
3. One source of truth for focus: UIKit's first responder. Keep either
   `.focused()` or the manual binding, not both, and have the coordinator act
   only when the requested value changes, not on every update.
4. Diagnostics go through `Logger` under `#if DEBUG`. No file I/O and no
   forced layout in `layoutSubviews`.

**Done when,** on iPhone and iPad simulators and then a device: on a new page,
twenty taps below the placeholder each put the caret in the body; Return from
the title moves to the body; ^T and ^D round trips leave the keyboard where it
was; the same with a hardware keyboard and with `QUIRE_DESK=live`; Instruments'
Hangs template shows nothing.

### E2. The "…" jump

**Wrong.** When the keyboard turns `...` into `…`, the body sits about 20
points low until the next key. `eabc030` fixed the iPad by pinning
`contentOffset`; the phone still does it.

**What is established.**

- It is not a fallback font: every bundled font has U+2026, the editor faces
  included. *(Read, measured with fontTools.)*
- 20 points is exactly one bare line of Newsreader at the default size, not
  the 28-point pitch with line spacing.
- The earlier log showed the view, its bounds, the font and the line height
  unchanged while the text sat low. So it is not the scroll view or SwiftUI's
  sizing.
- The height cache from `ae271e3` is keyed on the text, so it is not stale.

**Mechanism (hypothesis).** TextKit 2 lays the paragraph out with one extra
empty line fragment and keeps that stale geometry until the next edit. The
styling code makes this likely: it rewrites `textStorage` attributes from
`textViewDidChange` outside any editing transaction, one `addAttribute` per
match (`WritingTextEditor.swift:692-723, 854-857`), while TextKit 2 is still
reconciling the keyboard's multi-character replacement. When the edit range is
unknown it goes further and resets `tv.font`, `tv.textColor` and every
attribute in the document (`:725-735`).

**Fix, in order of preference. None needs TextKit 1.**

1. Stop editing storage attributes on keystrokes. Keep the storage in base
   attributes and supply styled paragraphs through
   `NSTextContentStorageDelegate.textContentStorage(_:textParagraphWith:)`.
   Start with a short spike to confirm `UITextView` accepts a delegate on its
   content storage.
2. Failing that, restyle in `NSTextStorageDelegate.didProcessEditing`, limited
   to the edited paragraph, so attributes change in the same transaction as
   the characters. Never set `tv.font` or `tv.textColor` on a non-empty view.
3. As a safety net either way: after an edit whose replaced range is non-empty
   or unknown, invalidate that paragraph's layout and call
   `textViewportLayoutController.layoutViewport()`.

**Done when:** with the software keyboard (a hardware keyboard does not
autocorrect, and XCUITest's `typeText` may not either, so by hand), on an
iPhone simulator and a device, typing `...` leaves the first line where it
was in each of: alone on line one; at the end of line one with a tag line
below; mid-paragraph; in a wrapped paragraph. A DEBUG log of the first layout
fragment's `minY` reads 0 before and after.

### E3. Typing lag

The two-second wait in `1daf9fb` delays the full rebuild. These costs remain.

**On every pause in typing (0.7 s):**

- **E3a. The save runs on the main thread.** `saveNow` parses the entry twice,
  round-trips JSON, then does Rust's read and compare-and-swap through an
  `NSFileCoordinator` write (`ComposerScreen.swift:445-480`,
  `JournalStore.swift:175-221`). On an iCloud folder the coordinated write
  waits for iCloud. *(Read.)*
- **E3b. Every autosave walks the whole journal.** `publishAutosave` calls
  `loadInbox()`, which calls `core.migrate()` each time
  (`JournalStore.swift:230-233, 812-816`). The migrate request lists the
  inbox, journal and split trees in full, then the inbox is read and parsed
  again. *(Checked.)*

  Fix for both: run the write and the inbox refresh on a serial background
  queue, the composer awaiting the returned reference. Patch `inboxDrafts`
  from the returned entry instead of re-reading. Call `migrate()` once when a
  folder is opened.

**After the pause:**

- **E3c. The rebuild lands mid-typing** if typing resumes more than two
  seconds later: six `@Published` values at once
  (`JournalStore.swift:898-923`). Hold it while a composer is open;
  `settlePendingRebuild` already runs on close.
- **E3d. iCloud echoes our own write.** About 3.5 s after a save, and every
  20 s during continuous typing, the metadata query triggers a conflict scan
  and a full reload (`JournalStore.swift:2404-2468`). *(Read; the timing of
  iCloud's notifications is not verified.)* Compute the content fingerprint
  off the main thread and reload only when a file other than the one just
  written changed.

**On every key:**

- **E3e. The whole document is typeset to measure its height.** The cache
  misses on any text change and `boundingRect` runs over the full text
  (`WritingTextEditor.swift:789-813`). *(Checked.)* Measure per paragraph from
  the real attributed text and re-measure only the edited one. This also
  fixes E5.
- **E3f. The whole composer body re-evaluates,** because it reads
  `text.isEmpty` (`ComposerScreen.swift:248`): the drafts-left count, the title
  font, and the title field's setters all run again. Move the placeholder's
  check into a small child view.

**Done when:** Instruments (Time Profiler and Hangs) on a device, with a
5,000-word entry in an iCloud folder, shows no main-thread block over 16 ms
per key or 50 ms per pause, typing continuously and in bursts with pauses of
1, 3 and 5 seconds.

### E4. Today is slow at launch

**Wrong.** Today waits for the whole journal (5,422 entries) to be read:
about 2.3 s. The launch path itself was not profiled in this review, so the
cost split below is from reading.

**What adds to it.**

- `entries(for:)` loads the entire journal to return one day
  (`JournalStore.swift:1123-1127`), and `onThisDay()` calls it once per earlier
  year (`:2378-2387`), on the main thread, on every activation.
  *(Checked for `entries(for:)`; the loop is read.)* Serve both from the
  index already in memory.
- Every `load` lists the three trees twice across the bridge: once as a
  strictness pre-check in the bindings, once for real
  (`bindings/src/lib.rs:254-277`). Fix C9 removes the first.
- The first launch over a Nook journal folds `inbox.md` and every `<tag>.md`
  into day files on the main thread, one coordinated write per day. That
  risks a watchdog kill. Move it off the main thread with a progress line.

**The larger change (decision D1).** Two routes, not exclusive:

- *A saved snapshot of Today.* Draw Today at launch from what was saved last
  time, then reconcile when the journal has loaded. The app already writes
  `QuireSnapshot` to the App Group for the widgets with the day's figures.
  Near-instant, small change. The risks are showing yesterday's page for a
  moment (the snapshot must carry its day, and a stale one must draw as empty,
  as the widget's `isCurrent` does) and rows a person can tap before the real
  entries exist.
- *A per-file cache in the core,* keyed by size and modified time, so a load
  re-parses only files that changed. Helps every shell and every reload, not
  only launch. Larger change; needs a place to keep the cache that is not the
  journal folder.

Recommendation: the snapshot now, the cache when reloads are next the
bottleneck.

**Done when:** a cold launch on the phone shows Today's own content in under
half a second, and the page never shows a previous day's figures as today's.

### E5 to E12. Other faults in the writing path

| ID | Wrong | How it shows | Fix | Sure |
|---|---|---|---|---|
| E5 | Height is measured in the plain base font (`WritingTextEditor.swift:803-813`), but bold, code and italic runs wrap differently | In a bold-heavy entry at a large text size the last lines are clipped in a view that cannot scroll | E3e | Read; not reproduced |
| E6 | The composer can be torn down without saving. A widget, reminder, quick action or `quire://write` replaces `composing` (`PhoneRoot.swift:120`); an open request sets it to nil (`:432`). `onDisappear` cancels the pending save (`ComposerScreen.swift:153-161`) | The last 0.7 s of typing is lost, a voice recording in progress is dropped, and if saves were already failing every unsaved word goes | Route both through the composer's own `close()`, as ⌘K does. Add a final save in `onDisappear` | Checked |
| E7 | When the save and the recovery copy both fail (folder unreachable), the words exist only in memory and `close()` refuses to leave | Killed in the background, the text is gone | Write title, text, stamp and target to a file in the app's own container before each vault write; clear it on success; offer it at next launch. Add "Copy text" to the failure banner | Read |
| E8 | On iPad split, `onUpdate`/`onRemove` act on `path.last` (`PhoneRoot.swift:73-77`), but `e` on a list row can edit an entry that is not the open page | Saving entry B swaps A's reader for B; filing B closes A | Act only when `path.last` is the entry being edited | Read |
| E9 | Attachment links, ^P prompts and transcripts assign the whole `text`, so `updateUIView` resets `tv.text` | The caret jumps to the end, undo is cleared, and an input-method composition in progress is destroyed | Apply them as ranged edits through the coordinator | Read |
| E10 | Restyling overwrites a paragraph's attributes with no `markedTextRange` check (`WritingTextEditor.swift:701`) | Marked-text styling is wiped while composing Chinese, Japanese or Korean | Skip the restyle while there is marked text | Read |
| E11 | A title ending in ` *` is passed through unchanged | It is saved as a starred entry and the two characters vanish on reload | Escape or strip in `headerTitle` | Read |
| E12 | The app delegate declares ↑/↓ with priority over the system (`QuireApp.swift:71-83`), and the composer's handlers for them are empty | With a hardware keyboard and no monitor, ↑/↓ may do nothing in the body | One device check. If so, don't declare them while a text input is first responder | Hypothesis |

---

## 3. Where writing or media can be lost

Ranked. All but the last two are confirmed in the code.

**A1. Mac: the Stream view's inline editor stops saving after its first
autosave.** *(Checked.)* After a successful write, `commit()` replaces
`current` with a freshly parsed entry, which has no file or index
(`Views/StreamView.swift:655`). Every later autosave, the flush on leaving the
row, and File all fail with "This entry has no journal location". Everything
typed after the first half-second pause is lost. Fix: adopt the store's
returned entry, as `EntryDetailView.commit` does, or use `saveEditorEntry`.
Add a test that saves the same row twice.

**C1. Data Saver deletes the picture from `.webm` videos.** *(Checked.)*
`core/src/media.rs:43` lists `webm` as audio and `:470` re-encodes it with
`-vn`. The audio-only result is smaller, so it replaces the original. Linux and
the terminal both reach this on attach (with Data Saver on) and in "Compress
existing media"; `extras::media_kind` and the Linux front end call the same
file a video. Fix: only `.weba` is audio. For `.webm` and `.ogg`, probe for a
video stream and skip or use a video recipe. Test with a webm that has both
tracks.

**L1. Linux: an open composer overwrites another device's edit.**
*(Checked.)* After every reload, the draft's reference is re-resolved by raw
text, and when that fails, by file and timestamp (`linux/src/app.js:187`). If
the phone changed the entry, the reference silently becomes the phone's
version, so the next save presents the phone's text as the expected one and
passes the core's check. No typing is needed: the composer now differs from
its reference, so leaving it writes the stale text back. Fix: keep the
reference only on a raw match. If the composer is clean, take the disk
version into it. If it is dirty, leave the reference alone so the save is
refused, then offer "keep mine as a new draft" or "take theirs".

**C2. HEIC conversion rewrites entry files directly and can delete a photo
that is still linked.** *(Checked for the direct write.)* `relink_heics` uses
`fs::read_to_string` and `write_atomic` on inbox, journal and split files
(`core/src/media.rs:853-866`). It bypasses the vault, the folder lock and
`edit_file`, which the project's first rule forbids, so a save landing between
the read and the write is overwritten. Separately, every converted HEIC is
treated as safe to delete once the files were readable, whether or not its
link was rewritten: one referenced from `transfer.md`, a template, a plain
`[x](…)` link or an `<img>` keeps its `.heic` link and loses the file. Fix:
take a `&Journal` and rewrite through `edit_file`. Before deleting, require
that nothing scanned still mentions the file. Move it to the recovery folder
instead of unlinking it.

**T1. Terminal: Ctrl-C drops the buffer when the save is failing.**
*(Checked.)* On quit, a failed `save_draft()` is printed with `eprintln!`
while the alternate screen is still up, then the loop breaks
(`tui/src/app.rs:1955-1963`). The message is never seen and the text is gone.
A persistent failure is exactly when someone reaches for Ctrl-C, because Esc
correctly refuses to leave. Fix: a failed save cancels the quit and says so; a
second Ctrl-C forces it. Before a forced exit, write a recovery copy as a new
draft; if that fails too, print the error and the text after
`ratatui::restore()`. Do the same on the loop's error path, which today
attempts no save at all.

**C3. Unused-media detection calls a linked file unused.** *(Read.)* A bare
link target stops at the first `)`, so `![](assets/2026/09/image(1).jpg)`
parses as `image(1` and matches nothing; the fallback then searches text with
the link targets already stripped (`core/src/media_cleanup.rs:157-173`). The
file is listed as unused and "Clear unused media" removes it after one
confirmation, for good after 30 days. Names with brackets are common from
browser downloads. Fix: balanced brackets in the bare-target rule, and run the
fallback over the unstripped text too. Compare case-folded and NFC-normalised
(a name whose case or accent form differs is flagged the same way on macOS;
that part is a hypothesis).

**C4. Media cleanup rewrites day files with compare, then write.** *(Read.)*
`media_cleanup.rs:353-359` reads, compares, and writes as separate steps, so a
save between them is lost. Fix: `replace_if_unchanged`; on refusal skip that
file and keep its sources.

**C5. The legacy inbox is moved without a re-check.** *(Read.)*
`migrate_legacy_inbox` reads `inbox.md`, folds it, then renames whatever is at
that path now (`core/src/journal.rs:1124-1164`; the same for `<tag>.md` at
`:1180-1229`). A draft that jnl, Nook or a sync wrote in between goes into
`.quire/migration/` and never reaches `inbox/`. `tools/migrate_journal.py`
has the same shape. Fix: keep the bytes read; after verifying, write the
backup, then `replace_if_unchanged(inbox.md, those bytes, None)`; on refusal
fold again.

**C6. Merging a conflict copy can drop or duplicate entries.** *(Read.)*
`merge_content` and `import_text` parse text that was never normalised
(`bindings/src/lib.rs:388-399`, `core/src/journal.rs:1098-1113`). With a BOM,
the first header does not match, the first entry is discarded as preamble, and
Swift still marks the iCloud version resolved. With CRLF, no entry matches
what is on disk, so every multi-line entry is inserted again. The markdown
folder importer has the same gap (`core/src/extras.rs:1224-1234`). Fix: call
`normalised()` in one helper that every "text from outside" entry point uses.

**C7. Data Saver's other one-way losses** (item 8 of the earlier review, still
open). *(Read.)* Beyond the intended re-encode, with no recovery copy: animated
PNGs and multi-page TIFFs keep one frame; every recompressed JPEG loses its
EXIF (capture date, location); audio is forced to mono. On Apple,
`compressInPlace` and two sibling paths do the same, and the sibling paths are
not coordinated (`JournalStore.swift:2705-2733, 1769-1771, 1737`). Fix:
decision D2.

**A2. Apple: "Write a line" clears the field when the write fails.** *(Read.)*
`upsertDraft` returns nil on failure and the result is ignored
(`Design/TodayScreen.swift:316-323`). Fix: clear only on success.

**A3. Apple: deleting from the Media Library is silent and permanent** (item 7
of the earlier review, still open). *(Read.)* `deleteAsset` is
`try? fm.removeItem` (`JournalStore.swift:1485`): no coordination, no error,
no recovery copy. Fix: rename into `.quire/media-cleanup/<stamp>/`,
coordinated, and report failure.

**L2. Linux: some typing is never autosaved.** *(Read.)* While any body line
looks like a `[YYYY-MM-DD HH:MM:SS]` header, nothing saves at all, however
long the writing continues (`app.js:883-893`); a crash loses it. Clearing all
the text of a saved draft is never written, yet the pill says "saved". A
failed autosave is a four-second toast with no retry. Fix: keep saving what is
above the header-shaped line, or a recovery copy in `.quire/`; treat an
emptied draft as dirty; retry with backoff and keep a "Not saved" pill.

---

## 4. Stale references and wrong targets

Edits carry `(file, index, raw)` and the core refuses a stale one. These are
the places a shell hands it the wrong reference, or a correct refusal turns
into a duplicate.

| ID | Shell | Wrong | How it shows | Fix | Sure |
|---|---|---|---|---|---|
| A4 | Apple | After an editor autosave of a filed entry, the caches keep the old text until the rebuild (2 s plus build time). A comment at `JournalStore.swift:834-836` says they are patched; nothing does it | Reopen, star, delete or retime that entry in the window: "changed on disk", and the recovery path makes a duplicate Inbox copy | Patch the one cached entry from the write's return value | Read |
| A5 | iPhone, iPad | The reader re-finds its entry by timestamp alone (`Design/ReaderScreen.swift:196-204`) | Two entries sharing a second (imports make these): the page flips to the first, and Star, Delete and Edit act on it | Match the id, then the raw, then a unique timestamp | Read |
| A6 | iPad | The split pane's reader keeps one identity across entries (`PhoneRoot.swift:320-324`). Its key handlers are registered once | Open a draft, then a filed entry: `f` tries to file a filed entry, `e` edits it as a draft, audio from the previous entry keeps playing | `.id(ref.id)` on the pane's reader | Read |
| A7 | Apple | The keyboard selection in lists is an index (`Design/QuireKeys.swift:153-157`) | A sync or widget capture inserts a row above; the highlight is now on a different entry and `f`, `u`, `*` act on it without asking | Remember the selected entry's id | Read |
| A8 | Mac | "Return to Inbox" passes an entry with no file or index (`Views/EntryDetailView.swift:597`) | It always fails | Pass `current` after `flush()` | Read |
| T2 | Terminal | Below 100 columns the entries pane is hidden, but `f`, `d`, `*`, `t` still act on the hidden selection (`tui/src/app.rs:871-890`) | At 80×24, `f` in the Inbox files a draft that is not on screen, with no question | Move to the entries column first; name the entry in the question | Read |
| T3 | Terminal | Delete and retime act on whatever is selected when answered (`app.rs:885-890`); the four-second reload still runs behind the question | A sync lands while "Delete this entry?" is up; `y` deletes a different entry | Carry `(file, index, raw)` in the question | Read |
| C8 | Core | `make_raw` keeps CRLF in a body; every read normalises it (`journal.rs:354-365`) | The reference returned by a new draft can never match again: the next save is refused and a duplicate is made | Normalise in `make_raw`; add a round-trip test | Read |
| C10 | Core | Single-entry moves write the destination without `skip_existing` (`journal.rs:1025, 1074, 1091`) | The destination write lands, the removal fails, the person retries: two copies | Use `insert_entries(…, true)`, as the batch paths do | Read |
| L3 | Linux | Reloads are applied in arrival order, with no sequence number (`app.js:171-194`) | An older snapshot lands after a save: false "changed on disk", then a second draft | A counter; drop older responses | Hypothesis |
| A9 | iPad | An entry link sets the tab and the page together, and the tab's `onChange` then clears the page (`PhoneRoot.swift:280, 428-440`) | Tap a notification, widget or Spotlight result for an entry on another tab: "Nothing open" | Reset the page in the tab's setters, not in `onChange` | Checked |
| A10 | Apple | Entry links are resolved before the folder is open | From a cold launch, a widget, notification or Spotlight tap lands on Today. Split-journal entries fail every time | Hold the target until the index is built | Read |

---

## 5. Backups

The same faults in three shells. Fix them once in the core where the core
does the copy (Linux, terminal), and mirror the rules in Swift.

**B1. A backup verifies against the live folder, so typing fails it.**
*(Checked on Apple.)* The copy is compared with the journal after copying
(`JournalStore.swift:576-581`, `core/src/extras.rs:887`). The trigger is a
write, so an autosave during the copy fails the check, the copy is deleted,
and the next autosave starts another, with no backoff and no message. With
gigabytes of media this loops for a whole writing session. Fix: record sizes
as files are copied and verify against those. Keep a last-attempt time with
backoff. Show the failure. In the terminal, don't start a scheduled backup
while a draft is dirty.

**B2. A half-finished backup looks complete.** *(Read.)* The copy is made
under its final name. If the Linux window is closed or the terminal app is
killed mid-copy, the partial folder is listed, takes a retention slot, and
passes restore's check. Fix: copy to `.<name>.partial` and rename after
verifying; listing and pruning ignore partials.

**B3. The restore safety copy is pruned like any backup.** *(Read.)* It is
named `Quire backup …` (`extras.rs:1019`), though the comment above says it is
not pruned and a test still expects the old `Quire before-restore …` name.
With "keep 1", the next scheduled backup deletes both the safety copy and the
backup that was restored from. Fix: name it `Quire before-restore <stamp>`,
list it, never prune it with the others.

**B4. Retention can rotate out every good backup.** *(Read.)*

- The terminal's first reload always counts as a change (`app.rs:233`), so in
  "on change" mode every launch makes a backup; ten read-only sessions push
  out ten real states.
- Nothing notices a journal that suddenly shrank.
- On Linux, a prune error stops `last_backup` being recorded
  (`linux/src-tauri/src/lib.rs:96-107`), so every focus makes another full
  backup and nothing is pruned.
- The terminal keeps one backup folder and one `last_backup` for every
  journal it opens with `--folder`, so a second journal prunes the first's
  backups.

  Fix: set the first fingerprint without marking a change; skip a backup
  identical to the last; refuse to prune when the new backup is far smaller
  than the previous one; record `last_backup` when the copy verifies; key
  backups by journal.

**B5. Smaller.** Linux "on change" backups pending at quit are never taken.
Scheduled failures on Linux only reach the console. Apple's restore may lack
access to the backup folder in the sandbox, because it starts security scope
on a derived URL (`JournalStore.swift:657-658`; hypothesis, one device check).
A restore interrupted mid-swap leaves `.quire-restore-old-*` or `-new-*`
behind in every shell and nothing looks for them on open: sweep `-new-`,
report `-old-`.

---

## 6. Apple, the rest

**A11. The app lock does not cover the widget or the weekly notification**
(item 4 of the earlier review, still open). *(Read.)* With Face ID lock on,
the On this day widget shows a title and a 140-character excerpt
(`JournalStore.swift:966-972`), and "From your journal" puts an entry's first
line on the Lock Screen (`Models/Reminders.swift:263-268`). That notification
is also chosen up to a week ahead and never cancelled, so a deleted entry's
title can still arrive. Fix: with the lock on, write "A memory from 3 years
ago" and a generic notification body; add `.privacySensitive()`; cancel the
pending request when its entry is deleted or edited.

**A12. Hidden mode shows the search query on a locked or paused monitor.**
*(Read.)* The empty VS Code window still draws its title bar, which reads the
query directly (`Design/DeskCode.swift:220, 338-342`). This breaks the rule
that a locked or paused display shows no journal text. Fix: pass the query
only from the live page.

**A13. Nothing rebuilds when the day changes.** *(Read.)* Reopen the suspended
app the next morning and, with no file changed, Today shows yesterday's words
as today's and the On this day widget stays blank until something is written.
The Marathon header's date has the same fault (`TodayScreen.swift:184-200`).
Fix: remember the day the index was built for; rebuild on
`NSCalendarDayChanged` and on activation when it differs.

**A14. The reader cuts text under a heading at 300 characters.** *(Checked.)*
A block that starts with `#` becomes a heading whole
(`ReaderScreen.swift:229-232`), so `## Morning` followed directly by a
paragraph shows the paragraph in heading type and drops the rest. Fix: the
first line is the heading; the remainder goes through the normal path.

**A15. Importing a large archive freezes the app.** *(Read.)* `commitImport`
calls `entries(for:)`, a full journal load, once per distinct date, on the
main thread (`Models/Importers.swift:214`). A five-year Day One export is
about 1,800 full loads. Fix with E4's first point, and run the import off the
main thread against one snapshot.

**A16. The monitor flips from the composer to the reader after a pause.**
*(Hypothesis; needs a device.)* The reader under the composer re-publishes on
every store revision and takes monitor ownership back
(`ReaderScreen.swift:70, 133-138`). Fix: make ownership a stack.

**A17. Rotating or resizing an iPad drops the page's state.** *(Read.)* The
face is built in three structural branches (`PhoneRoot.swift:245-283`), so
crossing the size class gives it a new identity: Today's half-typed line, the
Journal's starred filter and split choice, the selection and the scroll
position all reset. Fix: hoist that state into `PhoneRoot`.

**A18. Fingerprint recorded too early.** *(Read.)* `reloadIfChanged` stores
the new fingerprint before the reload (`JournalStore.swift:786`). If the
reload then fails (an iCloud file still downloading), the next activation sees
no change and skips, and the journal stays stale. Fix: store it on success.

**A19. Smaller, all read.**

- Clearing unused media reads each whole file into memory two or three times
  on the main thread; one 1 GB video gets the app killed. Archive by rename.
- The Data Saver batch runs on the main thread with no progress, records
  transient failures as handled for good, and re-reads every journal file
  once per HEIC.
- Monitor Settings keep taking keys while the monitor says "Display paused"
  (`Views/ExternalDisplayView.swift:206-216`).
- Settings: "Merge Ex-Split Journals" runs on tap with no question; a
  template's trash icon deletes at once; File all, transfer and conflict
  merging block the main thread with no progress; the restore sheet can be
  swiped away mid-restore (`Views/SettingsView.swift`).
- The reader loads full-size images and compiles its regex inside `body`.
- The Journal title's count bypasses the months cache, re-grouping a split
  journal on every autosave (`Design/JournalScreen.swift:184-186`).
- Hint bar mismatches: ↑/↓ work on idle but are not listed; ⌥⌘H is never
  listed; an empty Journal lists Random (`Design/DeskViews.swift:100-167`).
- Reduce Motion is ignored by the prompt transition, the sidebar fold and the
  four animated `scrollTo` calls.
- Share extension: a claimed file that cannot be read is treated as empty and
  deleted; the extension's read-then-rewrite of `pending.md` can duplicate.
- The Add Entry intent does not tell a running app, so the Inbox is stale
  until the next activation.
- Re-importing a markdown folder can duplicate, because same-day offsets
  follow directory order. Sort by path first.
- Dead code: `askDelete` in `TodayScreen.swift` is never called.
- No accessibility label: the Media Library tile (`Views/AssetsView.swift:180`),
  the template trash button, the calendar's three buttons, the media
  checkbox. Every icon button in `Design/` has one.

---

## 7. Core, terminal and Linux, the rest

### Core

- **C11. A settings file that fails to parse is replaced with defaults.**
  *(Checked.)* `Settings::load()` maps a missing file, an I/O error and any
  parse error to defaults (`core/src/settings.rs:48-50`). One trailing comma
  and the next save erases the folder, backup folder, split tags and device
  id; the Linux app then opens the sample journal and the terminal an empty
  `~/notes`. `install.sh:1342-1347` does the same. Unknown keys are dropped
  on every save, so an older binary erases a newer one's settings. Fix: only
  "not found" means defaults; on a parse error move the file to
  `settings.json.bad-<stamp>` and say so; keep unknown keys in a flattened
  map.
- **C12. Settings writers overwrite each other.** *(Read.)* The Linux app
  loads once and saves its copy whole; the terminal re-reads with no lock. A
  lost device id fragments the Data Saver ledger. Fix: one
  `Settings::update(|s| …)` under a lock, used by both.
- **C13. Conflict-copy names with some non-ASCII letters break the merge.**
  *(Checked.)* `conflict_main_name` slices the name with offsets found in its
  lowercased copy (`journal.rs:105-116`), and lowercasing changes byte
  lengths for `İ`, `ẞ` and others. A Dropbox copy named after "İlker" is
  refused; some names merge into a stray file; some panic. Through the
  bindings a panic also poisons the journal lock until restart
  (`bindings/src/lib.rs:243-246`). Fix: `to_ascii_lowercase()`; take the lock
  with `unwrap_or_else(|e| e.into_inner())`.
- **C9. Strict loads are not strict about directory listings.** *(Read.)* An
  unreadable subfolder gives a silently shorter journal on Linux and the
  terminal. Propagate listing errors; the bindings' pre-check can then go.
- **C14. The Data Saver ledger loses entries.** *(Read.)* An unparsable ledger
  reads as empty and is overwritten, so everything is re-encoded; ids are the
  path without extension, so a file moved by cleanup is compressed twice and
  `x.jpg` and `x.mp4` share one id.
- **C15. Smaller.** Text above the first header is dropped by `import_text`
  and the folder importer. The folder importer descends into `.trash/`,
  `.stversions/` and `.obsidian/`. Day One re-import duplicates entries whose
  titles have doubled spaces. Cleanup's punctuation pass and tag rename
  rewrite inside code blocks and link targets. Media cleanup on a journal
  that has only `.nook/` creates `.quire/` beside it and hides Nook's
  templates. `Request::Write` can overwrite any path, entry files included,
  with no check; limit it to `.quire/`.

### Terminal

- **T4. Up gets stuck in wrapped paragraphs.** *(Checked.)* The branch meant
  to keep the caret off a wrapped row's trailing space assigns
  `self.col = r.end`, which is what it already was (`tui/src/editor.rs:269-273`).
  It should be `r.end - 1`. The caret lands at the start of the same row, and
  further presses stay there. Add the test.
- **T5. The column filter's "↵ keep" selects the wrong row.** *(Read.)* Enter
  drops the filter but keeps the filtered index, nearly always 0
  (`app.rs:825`). Type `/2023`, press Enter: 2026 is selected.
- **T6. ^D "Discard this draft?" means two things.** *(Read.)* For a draft
  opened from the Inbox it deletes the whole entry, including text from
  before this session; for a filed entry it deletes nothing. Decision D3.
- **T7. Smaller.** The date prompt accepts `2026-02-31 25:99` and files it
  under `02/31.md`. Tag autocomplete takes Enter when the typed tag is
  complete but prefixes another (`@run` becomes `@running`). `quire log
  2026-11` panics. Tabs are invisible but counted, and multi-codepoint emoji
  move the caret off. Under nine rows the composer takes typing it cannot
  show. `update.rs` writes fixed temporary names and swaps `quire` and `jnl`
  one after the other, so a failure between leaves mixed versions.

### Linux

- **L4. Attaching blocks the window.** *(Read.)* `attach_file`, `paste_image`
  and `attach_bytes` are not `async`, so Tauri runs them on the main thread
  (`lib.rs:502, 543, 588`). A large video freezes the window until the copy
  ends. Wrap them in `blocking(…)` as `create_draft` is.
- **L5. Ctrl+L does not survive a restart.** *(Read.)* The locked state is in
  memory; boot locks only when "Lock on launch" is on. Lock, walk away, and
  anyone can close and reopen the window. Also, changing or removing the PIN
  does not ask for the current one. Fix: lock at launch whenever a PIN is set.
- **L6. Every window focus rebuilds the page.** *(Read.)* Alt-tab away and
  back and a long entry is at the top again; ticking a task far down an entry
  jumps to the top; the Media Library re-lists every file. Skip the render
  when the snapshot is unchanged and keep scroll positions.
- **L7. Search has drifted from the core.** *(Read.)* Ten cases differ,
  listed in the reviewer's table; the ones people will meet are that an
  unclosed quote or a half-typed `before:` date gives zero results on every
  keystroke until finished, and `has:media` excludes an entry whose only
  attachment is a PDF. Fix: port `tokenize` literally and run the core's test
  cases against the JS in `make check`. Better, call the core's parser through
  a command and delete the copy.
- **L8. The webview can reach every file** (item 12 of the earlier review,
  still open, with more surface). *(Read.)* The asset protocol and
  `opener:allow-open-path` are scoped `**`. In addition `attach_file`,
  `export_cmd`, `import_markdown` and `import_dayone` take any path from the
  page with no check it came from a dialog. The CSP blocks inline script, so
  this is defence in depth. Fix: scope both to the journal folder at runtime;
  keep a server-side set of dialog-approved paths; add `base-uri`,
  `form-action` and `object-src` to the CSP.
- **L9. Smaller.** A template name is put into an attribute unescaped
  (`app.js:1127`); markup can be injected, script cannot. No watcher is
  started if the folder is missing at launch. Popovers have no focus trap and
  do not return focus. Ctrl+I writes `__x__`, which the terminal app writes
  as `_x_` and standard markdown reads as bold. The desktop crate does not
  compile off Linux: a `cfg` sits on the wrong function (`lib.rs:952-974`).

---

## 8. Install, release and docs

- **R1. The installer overwrites the old `jnl`, then trashes the new one.**
  *(Read; the removal step is checked.)* An old jnl at `~/.local/bin/jnl` is
  recorded for removal. Quire's `jnl` is then installed over it, and step 7
  moves the recorded path to the Trash without looking at what is there now
  (`install.sh:631, 1175-1177`). The run ends "jnl works too" with no `jnl`.
  Fix: move the old one aside before installing; in step 7 skip any path that
  now classifies as Quire's.
- **R2. Nook and Wander are removed although Quire's desktop app failed to
  install.** *(Read.)* Removal defaults are set before the build
  (`install.sh:1061-1065`). Reset them when the desktop install did not
  finish.
- **R3. `make smoke` on a Mac uses the real settings.** *(Checked.)* The
  driver isolates with `XDG_CONFIG_HOME` (`tools/drive_tui.py:18`), which
  `dirs::config_dir()` ignores on macOS. With a backup folder set, each run
  would back up the sample journal into the real backup folder, prune a real
  backup and mark the real journal as backed up. No backup folder is set on
  this Mac today, so nothing has been lost. Fix: a `QUIRE_CONFIG_DIR`
  override in `Settings::path()`, used by both drivers.
- **R4. CI does not run on push.** *(Checked.)* `ci.yml` triggers only on
  `workflow_dispatch` and `workflow_call`. Its own header, `CLAUDE.md`,
  `AGENTS.md` and the status line of `docs/suggestions.md` all say every push
  to `main`. `apple.yml` last ran on 2026-10-28. The 239 commits since
  v0.11.0 have had no automated check. Decision D4.
- **R5. The changelog is in a shape the release step does not expect.**
  *(Read.)* `## [0.12.0] — not yet released` sits under a newer
  `[Unreleased]`. Tagging 0.12.0 as things stand publishes notes headed "not
  yet released" without the newest bullets. Fold `[Unreleased]` into 0.12.0
  when cutting, and have `release.yml` require a dated heading.
- **R6. A release touches seven files, not four.** *(Read.)* `Cargo.lock`,
  `linux/package-lock.json` and the generated Xcode project also change;
  `make check` fails until the project is regenerated. Add a `make bump`.
- **R7. Smaller.** The AppImage copy is not checked before the old .deb is
  removed. The pre-install backup of the whole journal is written
  world-readable in `$HOME`. `--keep-nook` in the Python fallback hides
  Nook's sidecar. AppImages to remove are identified by filename only.
  `--uninstall` moves `jnl` aside without checking whose it is. Several of
  the 23 smoke checks cannot fail, because they search all output since
  launch for text an earlier screen already printed.
  `dtolnay/rust-toolchain@stable` is an unpinned branch in the job that holds
  the signing key.
- **R8. Docs that no longer match.** `CLAUDE.md`/`AGENTS.md`: the CI line
  (R4), the workspace line omits `bindings`, the tree omits
  `tui/src/backup.rs`, `tui/src/update.rs` and `linux/src/boot.js`.
  `linux/README.md` is titled "(0.7)" and installs 0.6.2. `apple/README.md`
  contradicts itself about the iPad. `docs/consolidation-plan.md` says the
  first Apple build is pending. The three newest commits change iOS behaviour
  with no changelog bullet.

**Release state now.** All four version fields say 0.11.0, the latest tag is
`v0.11.0` (2026-10-26) and its release has all fifteen files, signed. `main`
is 239 commits ahead, three of them unpushed, and a build from it reports
0.11.0 while carrying 0.12 features.

---

## 9. Still open from the 6 November review

| Its item | State | Here |
|---|---|---|
| 4. On this day widget ignores the app lock | Open | A11 |
| 5. Every write forces the file to 0644 | Open (`core/src/vault.rs:212-216`) | Fix as written there |
| 6. No parent-directory sync after a rename | Open (`vault.rs:123, 198`) | Fix as written there |
| 7. `deleteAsset` swallows failure | Open | A3 |
| 8. Data Saver replaces originals | Open, and worse than stated | C1, C2, C7 |
| 10. `\[` guards only undone on Linux | Open: nothing in the core, terminal or Apple strips them | Add `unguard_body` to the core and expose it |
| 12. Tauri scopes are `**` | Open, with more surface | L8 |
| 13. Stale docs | Its six points are fixed; new drift | R8 |

---

## 10. Decisions for Dan

- **D1. Today at launch (E4).** A saved snapshot, a per-file cache in the
  core, or both. Recommended: the snapshot now.
- **D2. Data Saver originals (C7).** Park each original in
  `.quire/media-cleanup/` for 30 days, which costs the disk space Data Saver
  was meant to save for that month; or keep it one-way and say so plainly in
  the setting, skipping multi-frame images either way. Recommended: park
  them, since the recovery folder and its pruning already exist.
- **D3. Terminal ^D (T6).** Discard should mean "undo this session's
  changes" for an existing entry, and delete only for a draft made in this
  session. Confirm, or keep delete-on-discard and reword the question.
- **D4. CI (R4).** Restore the run on every push to `main`, or keep the tag
  run as the only gate and correct the three documents. The commit that
  turned it off cites Actions minutes; the repo is public, where minutes are
  normally free, so it is worth checking what the limit actually was.
- **D5. Punctuation in code (C15).** Cleanup turns `...` into `…` inside code
  blocks too. Skipping code departs from jnl; keeping it alters code samples.
- **D6. The Mac.** A1 and A8 are real data-loss and broken-action faults in a
  shell due to be replaced. Fix both now (small), or bring the Mac's design
  pass forward and retire `Views/`.

---

## 11. Tests to add with the fixes

- A two-save test of the Stream row (A1) and a new-draft CRLF round trip (C8).
- A webm with video and audio through Data Saver (C1).
- `image(1).jpg` through the unused-media check (C3).
- A BOM and a CRLF conflict copy through `merge_content` (C6).
- A backup taken while a file is appended to, and one killed mid-copy (B1, B2).
- A restore followed by a scheduled backup with "keep 1" (B3).
- Up across a wrapped row whose text is shorter than the caret column (T4).
- The core's search cases run against the Linux `parseQuery` (L7).
- A settings file with a trailing comma, then a save (C11).
- Smoke checks that search only output since the last action (R7).
