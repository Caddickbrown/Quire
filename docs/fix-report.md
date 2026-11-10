# Quire: what was fixed from the 9 November review

The work that followed `docs/fix-spec.md`, done on 9 and 10 November 2026 on
top of `main` at `b87666a`. The spec says what was wrong; this says what was
done about it, how it was checked, and what is still open. Item IDs are the
spec's.

## In short

Almost everything in the spec is implemented: the core, the terminal app, the
Linux app, the Apple app, the installer, the release pipeline and the docs.
The automated checks pass and the reworked iOS editor passed a new UI test
suite in the simulator. The build is on Dan's iPhone.

Three things are not proven:

- **The "…" jump on a real phone.** The simulator never showed the fault, with
  or without the fix, so it cannot confirm it.
- **Typing lag and launch time on a device.** Neither was measured.
- **The Linux app.** It compiles and its checks pass on a Mac. It has not been
  launched with these changes.

## How it was checked

| Check | Result |
|---|---|
| `make test` | 129 core, 10 bindings and 37 terminal tests pass |
| `make check` | clean; the desktop crate is skipped on a Mac by the Makefile, and was checked separately with `cargo clippy -p quire-desktop` |
| `make smoke` | 23/23 at 100×30 and 80×24, twice, and once with `QUIRE_SMOKE_WAIT_SCALE=10` |
| `make -C apple test` | 105 hostless tests pass |
| `make -C apple uitest` (new) | 4 editor tests, three full runs in a row, iPhone 17 Pro simulator, iOS 26.5 |
| App builds | iOS Simulator, macOS and a signed iOS device build succeed with no warnings |
| Linux front end | `check_linux_editor.js`, `check_media_library.js` and the new `check_search.js` (55 cases) pass |
| Migration tool | 28 tests pass |

Not run: anything on an iPad, a monitor, a hardware keyboard, or Linux.

## The four known problems

**Tap below the words (E1).** The body's text view now fills the page, so
UIKit's own tap puts the caret after the last word. There is no gesture and no
focus code for it. In the simulator, twenty rounds of tapping the title then
the blank page each put the typed character in the field just tapped.

**The freeze.** Its cause was never proven; the two candidates in the spec
were both removed. Focus between title and body now has one source of truth:
each field's coordinator asks for the keyboard once, when the requested value
changes, on the next run-loop turn, and never inside `updateUIView`. The
composer's `focus` is plain state, not `@FocusState`. The diagnostic
`layoutSubviews` override is gone; the one remaining diagnostic is an
`os.Logger` line in DEBUG builds.

**The "…" jump (E2).** Styling moved into the text storage's own editing pass
(`willProcessEditing`, restricted to the edited paragraph), so attributes
change with the characters. After an edit that replaced text, the paragraph's
layout is invalidated and the viewport laid out again on the next turn. In the
simulator, with the software keyboard really substituting `…`, the first line
of ink stayed at the same point in all four placements. The log read
`first fragment minY 0 -> 0` every time, which means the stale layout never
appeared there: the fix is plausible, not demonstrated.

**Typing lag (E3) and slow launch (E4).**

- An autosave no longer re-reads the inbox or walks the journal's folders; it
  patches the one draft in place (E3b).
- The full rebuild waits until the composer closes (E3c), and iCloud's echo of
  the app's own save no longer triggers a reload (E3d).
- A keystroke re-measures one paragraph, from the styled text (E3e, E5), and
  redraws only the body (E3f).
- `entries(for:)` and On this day read the index in memory instead of loading
  the journal (E4).
- Today draws at launch from a snapshot saved in the app's own container, and
  a snapshot from another day draws as an empty Today (D1).

**Deliberately not done: E3a.** The save itself still runs on the main thread.
Moving it would give up the guarantee that two saves are never in flight, and
that was not worth risking in the same change as the editor rework. If a pause
in typing still stalls on an iCloud folder, this is the next step.

## What else went in

### Where writing or media could be lost (spec section 3)

All twelve are fixed.

- **A1, A8 (Mac).** Stream's inline editor adopts the entry the store returns,
  so it keeps saving; "Return to Inbox" passes the right entry.
- **C1.** A `.webm` or `.ogg` with a video stream is left alone by Data Saver.
- **C2.** HEIC relinking goes through `edit_file`; a HEIC anything still
  mentions is kept, and the rest go to the recovery folder.
- **C3.** Link targets with brackets (`image(1).jpg`) are read correctly, and
  names are compared case-folded and NFC-normalised.
- **C4, C5.** Media cleanup and the legacy inbox fold use compare-and-swap.
- **C6.** Text from outside (conflict copies, paste, imported files) is
  normalised in one place before parsing.
- **C7 (D2).** Data Saver parks each original in `.quire/media-cleanup/` for
  30 days, in the core and on Apple, and skips multi-frame images.
- **T1.** Ctrl-C with a failing save cancels the quit; a second one keeps the
  text as a new draft, or prints it.
- **L1.** The Linux composer follows a reload only on an exact match;
  otherwise it takes the disk version (if untouched) or asks.
- **L2.** A recovery copy is kept while a body line looks like a header;
  failed autosaves retry; an emptied draft asks before it is discarded.
- **A2, A3.** "Write a line" clears only on success; a Media Library delete
  goes to the recovery folder and reports failure.
- **E6, E7.** A composer taken down from outside saves first. Each page is
  written to the app's container before every save and offered back at the
  next launch if the save never landed.

### Stale references and wrong targets (section 4)

All fixed: A4 to A10, T2, T3, C8, C10, L3. The common shape is that each shell
now keeps an entry's identity (`id`, then raw text) instead of an index or a
timestamp, and a question carries the entry it was asked about.

### Backups (section 5)

B1 to B5 are done in the core and mirrored in Swift, the terminal and Linux:
a backup is verified against what was copied, is written under a `.partial`
name until complete, backs off after a failure, and reports it. The restore
safety copy is `Quire before-restore <stamp>` and is never pruned. Older
backups are kept when a new one is under half the size of the last.

### The rest

- **Apple (section 6).** App lock now covers the widget and the weekly
  notification (A11); hidden mode shows no query when locked or paused (A12);
  the day rolls over (A13); text under a heading is no longer cut (A14);
  imports run off the main thread (A15); monitor ownership is a stack (A16);
  iPad rotation keeps the Journal's state and Today's line (A17).
- **Core (section 7).** Settings are never replaced with defaults on a parse
  error, unknown keys survive, and writers go through one locked update (C11,
  C12). Conflict-copy names with non-ASCII letters work (C13). Strict loads
  fail on an unlistable folder (C9). Saves keep a file's permissions and sync
  the parent folder. `unguard_body` exists and every shell now shows bodies
  unguarded.
- **Terminal.** T4 to T7, including grapheme-aware editing, `^d` as "undo this
  visit" (D3), and backups keyed by journal.
- **Linux.** L4 to L9, including the search port checked against the core's
  cases, and the webview confined to the journal folder.
- **Install and release (section 8).** R1 to R8. `make bump V=x.y.z` is new.
  The release pipeline now requires a dated changelog heading and an empty
  `[Unreleased]`.

## Decisions taken

| | Decision | Taken as |
|---|---|---|
| D1 | Today at launch | Saved snapshot |
| D2 | Data Saver originals | Parked for 30 days |
| D3 | Terminal `^d` | Undo this visit; delete only a draft made this session |
| D4 | CI on push | Left manual; the docs now say so |
| D5 | Punctuation in code | Left as jnl does it |
| D6 | The Mac | Its two broken paths fixed now |

D4 and D5 were not recommended either way in the spec; both were taken the
cautious way and are easy to reverse.

## Behaviour that changed and might surprise

- **Terminal:** `^d` no longer deletes an existing entry. `^k` keeps your text
  as a new draft when a save is refused. A journal opened with `--folder`
  backs up into its own subfolder; its older backups stay in the backup
  folder's root and are not listed for restore from the new place.
- **Linux:** the "Lock on launch" switch is gone; with a PIN set, every launch
  locks. File dialogs now open from Rust, and attach, export and import accept
  only paths chosen in a dialog or dropped.
- **Apple:** a starred page with no words no longer becomes a draft. A
  press-and-hold Media Library delete can be undone for 30 days from
  `.quire/media-cleanup/`.
- **Install:** a real Nook or Wander AppImage may now default to "no" for
  removal, because the bundle id is looked for in a file that is usually
  compressed.
- **Releases:** the pipeline refuses the changelog as it stands today
  ("0.12.0 — not yet released" with entries under `[Unreleased]`). Fold them
  together and date the heading when cutting 0.12.0.

## Still open

**Needs a device.**

- The "…" jump, typing lag and launch time on the iPhone.
- With a hardware keyboard: the first chord after touch typing (in the
  simulator the first `^D` did nothing; the second worked), and E12, whether
  ↑/↓ move in the body with no monitor attached.
- The monitor: the composer keeping it through a pause (A16), the hint bar
  changes, the ellipsis and tap-below with `QUIRE_DESK=live`.
- Widgets and the weekly notification with app lock on; day change overnight;
  a cold-launch entry link; the share extension with a large video; restore
  from a user-picked folder in the Mac sandbox (B5).
- The iPad: the UI tests ran on the iPhone simulator only.

**Needs a Linux machine.** A Linux build; media loading under the runtime
asset scope; the Rust-opened dialogs under GTK and the portal; drag-and-drop
attach (the drop must be approved before the page asks for the file); close
with a backup running or owed; clipboard image paste; the popover focus trap.

**Not done.**

- E3a, as above.
- ~~`.heif` is still a plain file, not an image, in the core's `media_kind`.~~
  Done on 10 November, with the Linux mirror (`coreMediaKind`).
- The Mac's File All and Clean Up buttons still block while they run.
- Scroll position is still lost when an iPad crosses the size class.
- The layout repair after an edit also runs on ordinary typing after a focus
  change. Harmless in the tests; it could cost something in one very long
  paragraph.
- An asset moved by media cleanup gets a new Data Saver id and can be
  compressed twice.
- `tools/check_tui_settings.py` is isolated now but its key sequence has not
  been checked since 0.7.
- `linux/src-tauri/Cargo.lock` and `linux/src-tauri/gen/schemas/` are tracked
  but unused or generated; candidates for removal.

## Things to know on this Mac

- `make -C apple core` fails on the default PATH: Homebrew's cargo shadows
  rustup's and has no iOS targets. Run
  `PATH="$HOME/.cargo/bin:$PATH" make -C apple core`. The XCFramework on disk
  had been stale since 6 November for this reason.
- The UI tests need the simulator's software keyboard. It appeared after
  `xcrun simctl spawn booted defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool false`;
  whether that write is what did it is not certain.
- If the new editor misbehaves on the phone, the last build known to work is
  `b87666a`.

## Second pass, 10 November

A read-through of the core, the terminal app and the Linux app after `main`
(`f42d15b`, the Apple calendar sheets) was merged into `review-fixes`. It
started from one report: split journals were showing in On this day in the
terminal app. Nothing here touches Swift.

### How it was checked

| Check | Result |
|---|---|
| `make test` | 131 core, 10 bindings and 44 terminal tests pass |
| `make check` | clean, with the new `tools/check_linux_views.js`; the desktop crate is skipped on a Mac and was not checked separately this time (`lib.rs` is unchanged) |
| `make smoke` | 23/23 at 100×30 and 80×24 |
| `make -C apple test` | 105 hostless tests pass on the merged tree |
| `make -C apple build-ios` | the iOS Simulator build succeeds on the merged tree |

Not run: the Linux app itself (its changes are checked in node only), the
Apple UI tests, anything on a device.

### On this day

`stats::on_this_day` took every entry that was not a draft, so a split
journal's entries were memories on the terminal's Today. It now takes the main
journal only. The Linux app had the same filter in two places (Today and Look
back) and now uses one `onThisDay()` helper with the core's rule. The Apple
app already read the main journal only. Both new tests were confirmed to fail
against the old filter.

### What else was fixed

**Terminal**

- `quire new Call the dentist` (and `jnl Call the dentist`) lost the title
  unless something more was typed: leaving, `^s` and `^j` all saved nothing.
- `^p` from the title made the prompt the header line, or cut the title in two.
  It goes in the body, as Today's ↵ puts it.
- Text on the row under the title (a paste into the title, a line joined with
  Backspace) was drawn over by the rule, and ↵ from the title skipped it.
- `t` then ↵ on an untouched date prompt rewrote the entry's seconds as `:00`
  and said it had moved.
- The column filter: Esc goes back to where `/` was pressed; the DAY column is
  matched by what it shows (`wed`, `4`); `/` from the entries filters the days
  instead of opening a prompt that ignored typing; a click on QUIRE with a
  filter open no longer leaves `?` dead on Today.
- Today's summary line was cut off at 80 columns with a four-figure entry
  count. Search reported its cap of 300 as the number of results. Look back
  was a week short for a leap year starting on a Sunday (2012, 2040). `stats`
  in a pipe ended the current streak's range on today even when the streak
  ended yesterday. Plurals ("1 words", "1 entries", "1 copies").
- A tag suggestion wider than the window overflowed a `u16` (a panic in debug
  builds only).

**Core**

- `.heif` is an image (the open item above).
- A HEIC attached with Data Saver on and no converter installed was written to
  the ledger as done, so "Compress existing media" never converted it later.
- A root `.md` with no entries was counted and weighed as a split journal on
  Look back.
- Media cleanup parsed un-normalised text, so a byte-order mark hid a file's
  first entry and the media it linked was reported as undated.

**Linux**

- ↑/↓ with the focus off the text, and the list's Random button, replaced the
  composer without saving: edits to a filed entry were dropped silently.
- An entry with a date that doesn't exist (`2026-06-31`, which the parser
  keeps) threw in `fmtDate` and stopped the list drawing; an impossible month
  or hour turned Look back's charts into `NaN`.
- The reader's link pattern stopped at the first `)`, so `image(1).jpg` was a
  broken link and stray text. It is the core's pattern now.
- ↵ on Cancel, Now or Yesterday in the date popover saved.
- "Yesterday" was 24 hours ago, wrong for an hour around a clock change. The
  heat map lost 31 December where clocks change at midnight.
- The Journal picker showed "Main journal" over an empty list once the split
  journal it was filtering by had no entries left. Look back's year picker
  could show a year that wasn't the one on the page. Plurals.

### Behaviour that changed

- **Terminal:** `/` pressed on the entries column moves to the day column and
  filters there. `quire new <title>` followed by Esc now leaves a draft.
  Search's masthead reads "1,000 results · the newest 300 listed" past the cap.
- **Linux:** the Journal picker can change by itself, to the main journal,
  when a split journal empties.

### Found and left alone

These came out of the same read-through. None is fixed; the first group needs
a decision before anyone writes code.

**Main journal or every journal?** On this day is now the main journal's. The
figures around it are not consistent with it or with each other:

- Terminal Today's "N entries since …", Look back's totals, heat strip, tags
  and year list (`year_stats`, `years`), and `stats_extra` (Linux Look back)
  count split journals. `jnl_stats` (`quire stats` in a pipe) does not, so the
  same command gives different totals on a terminal and in a pipe.
- The streak on Today and Look back counts drafts and split journals
  (`days_written`); the piped one counts journal days only. On Linux the
  reminder's streak counts drafts and Look back's tile does not.
- Random draws from split journals too, in the terminal and on Linux.
- Terminal `list` and `log` are main-only, `tag` includes split journals, and
  `tags` also counts drafts, so a tag's count can exceed what `tag` prints.
- Linux: tag chips count every journal while the list they filter may be the
  main one; the calendar and the day page include split-only days the list
  beside them doesn't; the Marathon counters include split journals.
- `export_all` interleaves the main journal and every split journal into one
  file. `cleanup` re-homes split day files but never sorts or dedupes them.
  The markdown-folder and Day One imports write to the main journal whatever
  the split tags are, until `cleanup` moves the entries.

**Terminal**

- `^i` (italic) cannot be pressed: a terminal sends Tab for it. It needs
  another key or the kitty keyboard protocol.
- `h` and `k` move in the columns; `j` and `l` leave the screen.
- ↑/↓ do nothing while a column filter is open.
- Under about 54 columns the DAY column is clipped. In 15 rows or fewer Look
  back's heat strip is drawn onto the hint row.
- Look back's years run newest-first left to right, so ← moves the highlight
  right, and only six years are drawn.
- One-line prompts (a backup folder, an import path) don't scroll.
- The help overlay misses several working keys on every screen, and Search
  shows no help key. `quire migrate`'s help says it folds `.nook/`; alone, it
  doesn't.
- Ctrl+letter types the letter in Search and in the column filter.

**Core**

- `migrate_legacy_inbox` does not rebase `./assets/…` links as
  `migrate_legacy_splits` does, so such a link in `inbox.md` breaks for
  display once folded (the asset is still counted as used).
  `tools/migrate_journal.py` behaves the same way.
- An e-mail address makes a tag: `boss@work.com` gives the entry `@work`, and
  with a split tag `work` files it there, while `rename_tags` refuses the same
  token. Whether that is jnl's behaviour was not checked. A search for
  `@gmail.com` can never match.
- 29 February entries surface in On this day only on 29 February.
- `tif`, `tiff` and `weba` are compressible media in `media.rs` and plain
  files in `media_kind`.
- An entry dated month 13 has its media renamed again on every cleanup run
  (traced, not run). A failed relink after a HEIC conversion makes a second
  JPEG on the next run.

**Linux**

- Print and Export PDF show `[image · name]` for pictures not yet loaded; a
  second print works.
- Below 860 px wide the Journal's Stream and Media views show nothing.
- Lists stop at 500 rows and the Stream at 300 without saying so.
- After "Import as separate entries…" the list beside the composer is not
  redrawn, so a later row in that day file can open the wrong draft.
- A hand-edited entry not in Quire's exact shape looks edited as soon as it is
  opened, and is rewritten on leaving.
- Not confirmed: the PIN not locking after a failed first load; an update's
  restart not saving a composer opened during the download.
