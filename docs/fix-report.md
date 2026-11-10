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
- `.heif` is still a plain file, not an image, in the core's `media_kind`.
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
