# Quire: suggestion guide

A full review from reading the README, CLAUDE.md, the docs and the code on
2026-11-06. Nothing was built or run, so anything marked "check" is a question
for a real device, not a confirmed fault. File references are to `main` at
`05f99fb`.

**A newer review exists.** `docs/fix-spec.md` (2026-11-09) is the review to work
from: it is written as a spec, and its section 9 lists which faults from this
document are still open.

**Status, 2026-11-06, corrected 2026-11-09.** Done since this was written: item 1
(restore is staged and swapped), item 3 in part (`ci.yml` exists and `release.yml` runs
it on a release tag before building; it does not run on a push to `main`, only when
asked through `workflow_dispatch`, so between releases the checks are run by hand), item 9
(`ParserChecks.swift` is gone), items 11 and 13, and the `legacy/` move. Item 2 has its
own piece of work. Not done, and each needs a decision or a careful change of its own:
items 4 to 8, 10 and 12, and everything from section 3 on. `legacy/` stays where it is
and the hidden mode's Windows logo stays: both are Dan's call, so sections 11, 14 and 15
are out of date on those points.

The short version: the architecture is the best thing here and the Apple app has
caught up with its ambition. The biggest risks are no longer in the format. They
are in the seams around it: restore, unguarded read-modify-write, a release
pipeline that runs no tests, and docs that describe a project from three weeks
ago.

## 1. What's great and should be protected

- **The Vault rule.** "The core never opens a file itself" is the decision that
  makes five shells possible. `core/src/vault.rs` is small and honest; keep it
  that way, and resist adding convenience methods that leak paths.
- **`expected_raw` entry identity.** Every edit presents what it thinks is on
  disk, and `Journal::locate` refuses if it isn't there. A stale editor can't
  silently overwrite, and that is rarer in journalling apps than it should be.
- **Destination-first moves.** `update_entry` and `unfile_entry` write the new
  place before removing the old: "a failure leaves a duplicate, never a loss".
  Keep that sentence as a rule for every future move.
- **The format stays plain and jnl-faithful.** `jnl_parity_cases`, the refusal to
  treat an unreadable file as empty (`try_read` versus `read`, `append_raw`
  refusing unreadable files), and the header guard in `guard_body` are all right.
- **Save failure in the composer.** `ComposerScreen.swift` keeps the editor open,
  says so, and offers a recovery copy to the Inbox. Don't let a redesign lose it.
- **Media cleanup's caution.** Verified copies, 30-day recovery, orphans cleared
  only on an explicit yes, and "missing or ambiguous links are reported rather
  than guessed".
- **Hidden mode.** VS Code on a monitor is the most memorable feature in the
  whole family, and it is also genuinely useful. It deserves its polish.
- **The Esc rule.** "Esc on the monitor always reaches Today", a step at a time:
  what's on top closes first, a question is always cancelled, never answered, an
  open entry goes back to its list, and the list goes to Today. Simple and learnable.
- **"Never automatic" updates.** A journal app that doesn't phone home on its own
  is a stance, not an omission. Keep it.
- **The whimsy pass.** It is restrained, respects Reduce Motion, and nothing
  animates per keystroke. Hold that line.
- **The AppleVault comment about plain reads.** The reasoning is written next to
  the code. Good practice; the "keep it that way" is earned.

## 2. Bugs and risks found

### Serious

1. **Restore deletes the live journal before copying the backup in.**
   `JournalStore.replaceTree` (`apple/Quire/Models/JournalStore.swift:588`)
   removes every item in the journal folder, then copies. A failure partway (full
   disk, an evicted iCloud file in the backup, a removed drive) leaves a half
   empty journal, and on an iCloud folder those deletions propagate to every
   device straight away. The safety copy means data survives, but only if the
   person finds it. None of this goes through file coordination either, so it is
   the one large write that ignores the rule `AppleVault` exists for.
   Fix: copy the backup to a sibling staging folder, verify file count and bytes,
   then swap item by item under `NSFileCoordinator`; delete the old content last.

2. **Read-modify-write has no guard between reading and writing.** `insert_entries`,
   `append_raw` and `update_entry` (`core/src/journal.rs:831`, `855`, `930`) read
   the file, work on it, and write it whole. `AppleVault.write` coordinates the
   write only, and reads are deliberately uncoordinated. So if iCloud lands another
   device's entry, or a Shortcut or the TUI appends to the same day file between the
   read and the write, the newer content is overwritten. Day files shrink the window
   a lot but today's file is exactly the one everything touches at once (the app's
   autosave, `AddJournalEntryIntent` via `quickAddDraft`, a second device). `locate`
   protects the entry being edited, not its neighbours.
   Fix: add a compare-and-swap to the Vault, for example `write_if_unchanged(rel,
   bytes, expected_hash)`. The core retries the small merge on a mismatch. On Apple,
   do the read inside the same coordination block for the writing path only, so the
   fast read path stays as it is.

3. **`release.yml` runs no tests.** Grepping it finds no `cargo test`, `make test`
   or clippy. The checks exist only as a line in CLAUDE.md. `apple.yml` runs on pull
   requests and by hand, and the log shows work going straight to `main`, so the
   Apple build and the hostless tests may effectively never run. There is no CI at
   all on a push to `main`. For an app that rewrites people's journals, a tag should
   not be able to publish a release that fails `make test`.

### Medium

4. **The On this day widget ignores the app lock.** `writeWidgetSnapshot`
   (`JournalStore.swift:808`) always writes the entry's title and a 140-character
   excerpt into the App Group, and nothing under `apple/QuireWidget/` mentions the
   lock, `privacySensitive` or redaction. Someone with Face ID lock on can still have
   an old, private entry sitting on their Home Screen. Spotlight is handled well
   (opt-in, off by default); the widget should meet the same bar. When the lock is
   on, leave `onThisDayPreview` and `onThisDayExcerpt` out of the snapshot, or show
   "A memory from 3 years ago" and add `.privacySensitive()` to the text.

5. **Every write forces the file to 0644.** `write_atomic_bytes`
   (`core/src/vault.rs:164`) sets `0o644` on the temp file, which replaces whatever
   the original had. A Linux user who did `chmod 600` on their journal gets their
   files silently widened to world-readable on the next save. Copy the mode from the
   existing file, and default to 0600 for new ones, or at the least honour the
   folder's mode.

6. **`write_atomic_bytes` doesn't sync the parent directory** after the rename. On
   Linux a crash shortly after a save can lose the rename even though the temp file
   was synced. Small fix with `File::open(dir)?.sync_all()`.

7. **`deleteAsset` swallows failure and skips coordination.**
   `JournalStore.swift:1349` is `try? fm.removeItem(at: url)`. The Media Library will
   show it as gone, then it comes back from iCloud, or it stays with no explanation.
   It also has no recovery copy, unlike `delete_orphans`. Route it through the core's
   recovery area, so a mistaken delete in the Media Library is undoable for 30 days.

8. **Data Saver replaces originals with no recovery path.** `compressInPlace`
   (`JournalStore.swift:2555`) swaps a 720p re-encode over the original. It is opt-in
   and the swap itself is coordinated, but it is the only destructive media path that
   doesn't use the 30-day recovery folder. "Compress existing media" should at least
   say plainly that it is one-way, or park originals in `.quire/media-cleanup/`
   when there is room.

9. **`ParserChecks.swift` is orphaned.** Its header says `make check` compiles it, but
   `make check` is clippy now and `apple/Makefile` doesn't mention it. It is listed in
   the Xcode project "for visibility" only. Either wire it in or delete it; a test
   file that looks live and isn't is worse than none. The parser it checks is now an
   adapter over Rust, so deleting is probably right.

10. **`\[` guards are only undone on Linux.** `linux/src/app.js:498` calls `unguard`
    before showing a body; nothing in `apple/` or `tui/src/` does (grep finds no
    equivalent). Check how a body line such as a pasted `[2026-10-01 09:00:00] note`
    reads in the Apple reader and the TUI. If the backslash shows, move `unguard`
    into the core so every shell gets it.

### Small

11. `tauri.conf.json` still says `"shortDescription": "Quire prototype"`, and that
    string goes into the .deb and .rpm metadata.
12. The Tauri asset protocol allows `**` and `opener:allow-open-path` allows `**`
    (`linux/src-tauri/capabilities/default.json`). The CSP blocks inline script and
    `esc` is used consistently, so this isn't an open door, but anything that ever
    gets script into that webview can read every file the user can. Scope assets at
    runtime to the chosen journal folder with `asset_protocol_scope().allow_directory`.
13. Stale docs, which matter here because agents read them as truth:
    - README's opening and "Native iOS and macOS" say the Apple shell is awaiting
      its first SDK build; CLAUDE.md says it runs on an iPhone.
    - README says the Media Library is at "Journal → Media Library". The changelog
      moved it to a masthead icon.
    - `docs/iphone-duo.md` says the camera isn't reachable from the iPhone design;
      the changelog added Take Photo and Record Video to the composer's paperclip.
    - `docs/maintenance.md` still says Apple builds can't be verified.
    - CLAUDE.md lists `tools/make_icon.swift`, which isn't in `tools/`.
    - The plan's "Not done" list (section 9) stops at 2026-10-12.

## 3. UX and flows

- **Today is the home, so make the "one more line" path shorter still.** A person
  coming back at 22:00 wants the entry they started this morning, not a new page.
  Add "Carry on with this morning's entry" when there is a draft from today.
- **Inbox zero moment.** The composer's footer counts drafts left. When the last draft
  is filed, give that a quiet line of its own, in the manner of the "Goal met" stamp.
- **Undo after filing, deleting and returning to Inbox.** Deletion asks first, which
  is safe but slow. A five-second "Filed to Tuesday. Undo" toast is both safer and
  faster, and the core's `(file, index, raw)` model makes the reverse operation easy.
  On the monitor it could be `u`.
- **Conflict story for ordinary people.** "That entry changed on disk since Quire
  last read it. Reloaded, try again." is accurate, but it is a dead end while the
  writer's words are open. Offer "Keep mine as a new draft" right there, reusing the
  recovery copy path.
- **The Mac is now the odd one out.** CLAUDE.md says the Mac still uses the earlier
  shell. Writing a journal on a real keyboard on the Mac is an obvious home for this
  app, and it is currently the least "Quire" place to do it. It should be the next
  shell pass, ahead of Android.
- **Linux has no quick capture.** The phone has a widget, a control and Shortcuts. On
  Linux a global hotkey or a tiny `quire add "text"` plus a `.desktop` action would
  match. `quire new` opens the editor, so an append-and-exit form is the missing piece
  (check `jnl` parity first).
- **Search results lack context.** Consider showing the matched line, not only the
  entry preview, and highlight the term.
- **Tag autocomplete** exists in the TUI; check that the same behaviour and ordering
  (most recent first) holds in the iPhone composer, so moving between shells isn't a
  surprise.

## 4. Visual design

- Newsreader, IBM Plex and the Almanac family are a real identity, and the widget
  pass was right to bring them in. Keep Quire out of system-default territory.
- The Linux CSS still carries a copy of the tokens (`docs/consolidation-plan.md`,
  section 9, item 1 and the conventions in CLAUDE.md). It is a small script and the
  only remaining break in "one source for every shell". Do it before adding another
  theme.
- Wander had fourteen looks; "Quire-ify one at a time" is the right rule. Seven is
  plenty at the moment, so only add one that has a reason to exist, such as a true
  high-contrast theme (see below), rather than another palette.
- Icons replaced words in the masthead, the entry actions and the composer in this
  last run of commits. Each was sensible; together they risk an unlabelled row. Have a
  look at the masthead on the smallest phone with the largest text, and consider
  keeping a word for the least obvious icon.
- `docs/iphone-duo.md` is good, disciplined thinking. The hinge check is the only
  visual risk left there.

## 5. Accessibility

- Good: `Font.custom(_:size:)` scales with Dynamic Type, `uiArchivo` uses
  `UIFontMetrics`, and Reduce Motion is respected throughout `QuireMotion.swift`.
- Thin: 29 accessibility modifiers across all of `apple/Quire/Design/` is low for the
  amount of hand-built chrome (custom tab bar, icon-only masthead,
  the `qKeyList` rows). The icons added lately are the priority: check each has a
  label. The themed audio scrubber already gets this right with an adjustable
  action, so copy that care to the rest.
- The `kicker`, count-up figures and arrival animations should present a final
  value to VoiceOver, not mid-animation numbers.
- The weekday bars and figures in Look back need a text equivalent. "Busiest day
  Tuesday, 41 entries" is one label, and it's nicer for everyone.
- Add one high-contrast theme and check `Increase Contrast`. Muted labels on Linen
  and Marathon Day are the likely failures. A contrast check over `themes.json` is a
  ten-line test, and because themes are data it would cover every shell at once.
- Linux has 58 `aria-`/`role` uses, which is a decent start. The popovers set
  `innerHTML` and focus by hand, so check that focus returns to the trigger when they
  close, and that the lock screen announces "Wrong PIN" via a live region.
- TUI: `NO_COLOR` handling isn't documented. Worth a line and a check.

## 6. Monitor Mode and keyboard

Quire is the benchmark for this across the family. Remaining ideas:

- **Make the hint bar data, not prose.** CLAUDE.md says the bar "must list exactly the
  keys that work", enforced by discipline, and the changelog shows it drifting ("Search
  no longer lists keys its sheet doesn't take"). Declare each screen's keys once in a
  table, and draw both the handler and the hint from it. It also gives you the `?`
  overlay for free.
- **Add `?` on the monitor** for a full key sheet. The TUI has one; hints are trimmed by
  width ("step down in size"), so some keys can't be discovered there at all.
- **`/` in the composer's context** to jump straight to search from a list, and `[` `]`
  for the previous and next day in the Journal: both are natural in a keyboard-led app.
- **Hidden mode extras.** A fake terminal tab showing `git log`-style entry titles would
  be a delight, and a boss-key that switches instantly to an innocuous file is the
  obvious next step. Keep it monitor-only as decided.
- **Monitor on Mac and Linux** was parked, reasonably, and "nobody asked for it" still
  holds. Leave it parked until someone asks.
- **Keyboard on iPad without a monitor.** Check that the `KeyCommandCatcher` letters work
  at regular width with no external display. It is an easy mode to leave untested.

## 7. Performance

- `reload()` re-reads the corpus and the Spotlight pass rebuilds the whole domain on
  each change. Move to incremental: per-file cache keyed by size and mtime in the Rust
  core (`load_all_with`), so a single-day change reparses one file. The Linux and TUI
  shells gain too. Most of the machinery is already there in `contentFingerprint`.
- `contentFingerprint` builds and sorts a large joined string on every activation. A
  rolling hash avoids the allocations; the walk is the real cost, though, so measure
  first. A journal of several thousand day files is where it would start to show.
- `reindexNow` deletes the domain then re-adds everything. Index only changed
  identifiers. It also stops Spotlight results vanishing mid-rebuild.
- Bridge calls pass JSON (`bindings`, "JSON transports existing core values"). Fine for
  edits, potentially noticeable for `load` at tens of thousands of entries. Profile it
  before changing it; the separate Rust trials should say more.
- `allAssets` plus `usages(ofAsset:)` walks entries per asset. A one-pass reverse index
  will keep the Media Library quick as it grows.

## 8. Reliability and data safety

Beyond items 1, 2, 5, 6, 7 and 8 above:

- **A journal doctor.** One command (`quire doctor`, and a Settings row) that reports
  unparseable day files, entries whose date disagrees with their file, duplicate
  `(ts, raw)` pairs, conflict copies, broken asset links and leftover `.quire-*.tmp`
  files, and changes nothing by default. Most of the parts exist in cleanup.
- **Backups on Apple only run when the app does.** Make the last backup's age visible
  on Today when it passes a threshold, and consider a `BGProcessingTask`.
- **Verify a backup.** `copyTree` could check file counts and sizes afterwards.
  `restoreBackup`'s `guard` only checks that the folder looks like a journal, so a
  truncated backup passes.
- **Test restore for real** in the integration suite: a failure halfway, and that the
  safety copy is intact. Today's restore is the most dangerous untested path.
- **`quire update` replaces binaries by rename** with SHA-256 checks. The hash comes
  from the same release as the file, so it protects against corruption, not compromise.
  The desktop AppImage is signature-checked; sign the terminal tarball with the same
  minisign key for parity.

## 9. Privacy and security

- Stated honestly in the app: lock is a lock on the app, not on the files. Good. Keep
  that copy.
- The widget gap is item 4 above. The timer Live Activity shows word counts only, which
  is fine.
- Journals on iCloud are the user's own, but a line in Settings saying what is and isn't
  covered by Advanced Data Protection would be a nice honest touch.
- Permissions: 0644 is item 5. Backups made to `~/` (`quire-preinstall-<stamp>.tar.gz`)
  should be 0600 too; check `install.sh`.
- `curl | bash` is offered for install. It's normal, and the script is careful
  (`--dry-run`, Trash not `rm`). Leave it.
- Optional encryption of `.quire/` sidecars isn't worth it. Encryption of entries would
  break "a plain folder of markdown", and that is the product. Don't do it.

## 10. Testing

- Add a `ci.yml`: `make test`, `make check` and `make smoke` on every push to `main`.
  Then make `release.yml` depend on the same job. Item 3 above.
- `search.rs` has one `#[test]` and `stats.rs` one (each may hold many cases, but the
  grammar is ported to JS in `parseQuery`). Run a shared JSON file of cases against
  both the Rust and the JS, using `tools/check_linux_editor.js` as the model. Better
  still, expose the core's parser as a Tauri command and delete the JS copy.
- Add a property test: `parse(render(entries)) == entries` over generated bodies with
  headers, en-dashes, CRLF and BOMs. The format is the crown jewels and `proptest`
  would find what hand-written cases can't.
- Fuzz `parse_entries` and `resolve_link`, as they take untrusted file content.
- Add a two-writer test against a Vault with an injected delay, once the
  compare-and-swap exists.
- `make smoke` at 23/23 is great; keep the two terminal sizes.
- A golden-file screenshot pass over `QUIRE_DESK` states would protect hidden mode from
  regressions; the launch hints are already there for it.

## 11. Code health

- **`legacy/nook/` and `legacy/wander/` are 35 MB and 500-odd tracked files that nothing builds.**
  The Makefile, the Cargo workspace, `gen_pbxproj.py` and CI don't reference them.
  Their histories were merged in, so a tag preserves them. Agents' greps hit them,
  so does your own, and `legacy/nook/Nook/Models/JournalStore.swift` looks exactly like the
  live file. Tag `archive/nook-wander` and delete both, keeping `legacy/wander/android` only
  if Android is truly next.
- **`JournalStore.swift` at 2,646 lines** is still the façade plus backup, media, Data
  Saver, sync and stats. Split out `BackupService` and `MediaStore` first. They are
  already nearly static.
- **`apple/Quire/Views/` versus `Design/`:** once the Mac gets its pass, the old views
  can go. Mark which are Mac-only today, so nobody polishes a dead screen.
- **`CLAUDE.md` and `AGENTS.md` are clones** by hand. A symlink ends that chore.
- **`linux/src/app.js` at 2,274 lines with very long single lines.** No build step is a
  rule worth keeping, but ES modules need no build step either. Splitting into a few
  files would help.
- `install.sh` at 1,398 lines of bash 3.2 is impressive and scary. It has earned its
  keep through the migration period; once jnl, Nook and Wander detection has done its
  job, cut it down.

## 12. New feature ideas

Small delights:

- "A year ago today you wrote about…" as a gentle line on Today, not just a card.
- A first-entry anniversary and a quiet "1,000th entry" moment, in the style of the goal
  stamp.
- `@tag` colour picked per tag, stored in `.quire/`.
- A "weather of the week" sparkline of word counts on Today.
- Bring the old composer's typewriter scrolling setting to the iPhone design and the monitor (check it survived the move to `ComposerScreen.swift`).
- Copy an entry as a nicely set image, using the theme, to share one paragraph.

Medium:

- **Weekly review as a flow, not just a template.** Settings suggests a weekly review
  template; go further with Sunday prompts and the week's entries beside the composer,
  saved as a normal entry.
- **Prompts as a file.** `.quire/prompts.md` so people can write their own deck, read by
  every shell through the core.
- **Linked entries.** `[[2026-03-14]]` opens that day. Plain text, degrades gracefully,
  no format change.
- **A `{{prompt}}` template variable**, joining `{{date}}`, `{{time}}` and `{{weekday}}`.
- **Import from Apple Journal's export.** Day One and folders of dated markdown (Obsidian daily notes) are covered; Apple Journal is the one people will actually have.
- **PDF/book export of a year**, typeset in Newsreader. A year in a real bound book is
  the sort of thing people pay for.

Bigger bets:

- **Quire on Mac, in the Quire design, with a real writing room.** See section 3.
- **A memory-surfacing layer**, all on device: "you often write about X in November".
- **Voice journal.** Dictate a walk, get a transcript and an audio asset, filed as one
  entry. Transcription already exists, so this is mostly flow.
- **Android.** Be honest about it: it has been "next" since October, and `legacy/wander/android`
  costs attention. If nobody is waiting, take it off the plan.

## 13. Platform features worth using

Already there, so not suggestions: widgets, Lock Screen accessories, Control Center
controls, Live Activity, Spotlight (opt-in), App Intents for add and inbox count, share
extension, Face ID, reminders, home screen quick actions.

Worth adding:

- **JournalingSuggestions framework.** Not used anywhere. Apple's picker of moments
  (workouts, photos, places) is designed for precisely this app and is on-device.
- **Foundation Models, on device.** Not used. Good fits: a summary of a week for review,
  title suggestions for an untitled draft, and "ask my journal". All offline, which
  suits the privacy stance. Label output clearly and keep it out of entries unless asked.
- **Writing Tools.** Check `WritingTextEditor` opts in sensibly. For a journal, some
  people will want it off, so a setting is worth having.
- **`AppEntity` and `IndexedEntity`.** The intents only add and count. With an entry
  entity, Shortcuts can find entries, Siri can answer "what did I write last Tuesday",
  and Spotlight results can have actions.
- **Interactive widget:** "Write a Line" already exists as a control. A one-tap mood or
  "file next draft" in the widget would fit.
- **State of Mind in HealthKit.** Log a mood as part of an entry. Optional and private.
- **Assistive Access and Stage Manager:** check the iPad sidebar in a small window.
- **Handoff** (`NSUserActivity`) of the open draft between iPhone and Mac. Natural once
  the Mac shell is done.
- **Quick Note / Mac Services** for "Send to Quire".

## 14. App Store readiness

Quire is not in the store and the docs treat releases as Linux first. If it goes:

- The LICENSE for inherited code is at `apple/LICENSE.nook`, and the fonts carry OFL
  files. Check that a licences screen shows them, and that the bundle has a privacy
  manifest (`PrivacyInfo.xcprivacy`) for the required-reason APIs: UserDefaults, file
  timestamps, disk space.
- Hidden mode: reviewers may balk at something that imitates VS Code and Windows 11
  ("look-alike app icons"). Trademark and impersonation risk is real, so use generic
  shapes in the taskbar and describe it as a "code editor" theme in the listing.
- Explain the external folder and iCloud model in review notes, along with what needs a
  monitor and hardware keyboard to test.
- The name "Quire" is worth a trademark and store search before investing further.

## 15. What to cut

- `nook/` and `wander/` from the tree (tag first).
- `ParserChecks.swift`.
- The Linux "presentation window" branch, if it's still around. It was parked as unasked
  for, so delete it or decide.
- The `CLAUDE.md`/`AGENTS.md` double maintenance.
- Eventually, the legacy format detection in `install.sh`.

## 16. Top 10

| # | Suggestion | Effort | Impact |
|---|---|---|---|
| 1 | Add CI on push (`make test`, `check`, `smoke`) and make `release.yml` depend on it | small | high |
| 2 | Make restore staged and coordinated, then swap; test failure partway | medium | high |
| 3 | Add compare-and-swap to the Vault so appends can't overwrite newer content | medium | high |
| 4 | Respect the app lock in the On this day widget | small | high |
| 5 | Preserve file modes in `write_atomic_bytes`, sync the parent folder | small | medium |
| 6 | Tag and remove `nook/` and `wander/`; bring README and docs up to date | small | medium |
| 7 | Add a property test for parse and render, and shared search cases for Rust and JS | small | high |
| 8 | Give the Mac the Quire design, ahead of Android | large | high |
| 9 | Generate hint bars and key handling from one table per screen, add `?` on the monitor | medium | medium |
| 10 | Adopt JournalingSuggestions and an `AppEntity` for entries, then on-device weekly review | large | high |
