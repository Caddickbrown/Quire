# Wander — full review and fix specification

A review of all four builds (macOS, iOS/iPadOS, Android, Tauri/Linux-Windows) plus
the three ports of the jnl format they share, done by reading every source file
and confirming the load-bearing claims by execution where the platform allowed it.

**Status of the tree at the time of review:** `main` at `21614f2`. The Tauri work
that was in progress when this was first drafted is now committed as `a256277` ("Let
every entry begin undated") and `21614f2` ("Give each theme the ornament it asks
for"), and is the baseline. The only untracked file is `design/theme-demo.html`.

**Validation pass (2026-09-29).** Every item below was re-checked one by one against
`21614f2`, because a first draft had stale line numbers and several claims that did
not hold up. The Rust and JavaScript claims were confirmed by execution: a scratch
crate built from `journal.rs`, `cargo test`, `node`, and a headless-Chromium render
of `styles.css`. There is no Swift or Android toolchain on the validating host, so
the Swift and Kotlin claims were checked by reading the code. Where an item was
wrong, overstated, or had a flawed fix, it carries a **Validation** note and the
text has been corrected. Claims that did not survive were moved to
[Appendix A](#appendix-a--checked-and-dismissed). Findings that were new to the pass
are in [New findings](#new-findings-from-the-validation-pass), numbered from S-68.

**Fixed on the working tree (uncommitted, 2026-09-29).** How far each is verified
differs by platform:

| Build | Fixed | Verified |
|---|---|---|
| Tauri (Rust) | S-01, S-02, S-06, S-21, S-31, S-38 (poison), S-52, S-56 (`rust-version`), S-71, S-73, S-74, Rust `remove` ignoring a failed delete | `cargo test` — 10 tests green; `cargo build` clean |
| Tauri (web) | S-03, S-04, S-07, S-08, S-09, S-10, S-11 (minimal), S-19, S-48, S-58, S-63, S-70, S-72 | `node --check`; styliser cases in node; styling in headless Chromium. Close-flush, clipboard and shortcuts **not yet run in the app** |
| Android | S-68, S-69, S-01, S-05 (app-scope, `NonCancellable`, `fd.sync()`), S-06, S-12, S-14, S-21, S-29, S-75, S-76; also a second race where a late save re-pointed the open entry at the old one | Core + `ParserTest` compiled and green under kotlinc (17 tests); store type-checked against android.jar. UI files **not compiled**, nothing run on a device |
| Swift | S-01 (+ `writeAtomically` guard), S-06, S-12, S-13 (header comment), S-16, S-21 (+ BOM), S-44, S-46, S-51, S-77 | **Not compiled** — no Swift toolchain on the review host. Run `swift test` before trusting any of it |

Still open from the P0/P1 list: S-05's temp-document swap (truncate-in-place
remains, now with sync and rollback), S-15, S-17, S-18, S-20, S-22, S-23, S-24, S-82.

**How to read this.** Every item has an ID, a severity, a location and a concrete
change. Severities:

| | |
|---|---|
| **P0** | Data loss, crash, or a wrong thing rendered to the reader |
| **P1** | A documented or promised behaviour that no build actually delivers |
| **P2** | Measurable cost on the keystroke path or at launch |
| **P3** | Dead code, duplication, hygiene, build correctness |
| **P4** | Tests, CI, tooling |
| **P5** | Accessibility |
| **P6** | Documentation accuracy |

Findings that turned out **not** to be defects after checking are listed in
[Appendix A](#appendix-a--checked-and-dismissed) rather than silently dropped, so
the next reviewer does not repeat the work.

---

## Summary

Counts cover all 84 items: S-01 to S-83, plus S-43a. Items the validation re-rated
stay in their original section and say so in their heading, but the count here uses
the **new** rating. S-83, a table of small items, is counted once, as P3.

| Severity | Count | Headline |
|---|---|---|
| P0 | 8 | Any unreadable day file (not only non-UTF-8) loses every other entry in it on the next save, in all three ports; Android can lose the last edits when an entry is filed (S-68) |
| P1 | 18 | The Tauri build draws body text in the wrong colour and hides every ornament (S-70); the README describes behaviours no build implements |
| P2 | 20 | The tag regex runs on every keystroke on Apple and Android; the Tauri commands run on the main thread |
| P3 | 19 | Dead API across the ports; `build.sh`'s ad-hoc fallback is unreachable; the Tauri commands trust any path the webview sends |
| P4 | 9 | The macOS test target is empty, `cargo test` is red, and there is no CI or shared conformance fixture |
| P5 | 6 | Focus rings are removed with no replacement; sheets are not dialogs; nothing has an accessible name |
| P6 | 4 | The README's key table and failure modes do not match the builds |

Re-rated by the validation pass: S-02 (P0 → P2), S-03 (P0 → P1), S-09 (P0 → P1),
S-10 (P0 → P3), S-12 (P0 → P2), S-47 (P3, hygiene only), S-38 and S-41 (P2 → P3).
S-23 is a documentation item filed under P1, and S-51 is P4. The earlier draft's
summary had put their headlines in P6 and P3.

The single most valuable change is **S-01 together with S-68 and S-05**. Today, a
write to a day file that cannot be read rewrites that file from an empty parse, and
every entry in it that the writer was not editing is destroyed. The unreadable case
is not only invalid UTF-8: any read error, such as a permission error or an iCloud
placeholder, does it. On Android, filing an entry races its own pending save. These
are the failure modes that would make a journal stop being a journal.

---

## P0 — Data loss, crashes, and wrong rendering

### S-01 · An unreadable (e.g. non-UTF-8) day file is destroyed on the next save (all three ports)

**Where**
- `WanderCore/Sources/WanderCore/JournalLibrary.swift:133` — `let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""`
- `tauri/src-tauri/src/journal.rs:239` — `let existing = fs::read_to_string(&target).unwrap_or_default();`
- `android/.../data/JournalLibrary.kt:108` — `val existing = tree.readText(target) ?: ""`

**The bug.** All three treat "this file is not valid UTF-8" identically to "this file
is empty". `String(contentsOf:encoding:)` throws on invalid UTF-8 and `try?`
swallows it. `fs::read_to_string` documents that it "returns an error if the contents
are not valid UTF-8" and `unwrap_or_default()` turns that into `""` — confirmed by
execution:

```
read_to_string on invalid utf-8 => Some("stream did not contain valid UTF-8")
```

`persist` then parses `""` (zero entries), appends the one entry being saved, and
writes the file. Every other entry in that day is gone, with no error shown.

This is not exotic: a file touched by a Windows editor, a CP-1252 smart quote, a
Latin-1 note, or an emoji sequence damaged by an old sync client all produce it.
Kotlin is different but not safer — `String(bytes, Charsets.UTF_8)` decodes
lossily, so it silently rewrites the offending bytes as U+FFFD on every save.

**Validation.** Confirmed by execution in Rust: a day file holding a Latin-1 `é`
and two entries, followed by a `persist` of a third entry, left only the third on
disk. The problem is wider than UTF-8, though:

- In all three ports, *any* read error counts as an empty file, not just a decode
  failure. That covers EIO, EISDIR, permission errors and iCloud placeholders.
- On Android, `SafTree.readText` (`SafTree.kt:129-131`) is
  `runCatching { … }.getOrNull()`. A `SecurityException`, an IO error or a stale
  document id becomes `null`, and `persist` turns that into `""`. So a transient
  read failure wipes the file too. That is the same data-loss path as Swift and Rust,
  and "Kotlin is different but not safer" understated it. The rollback copy in
  `writeText` (`SafTree.kt:142`, `:153`) is decoded lossily as well.
- A concrete loss on Apple: if `inbox.md` is not valid UTF-8, `load()` skips it
  (`JournalLibrary.swift:88`). The next ⌘N save then `persist`s into it and
  overwrites every inbox draft.
- The neighbours have the same shape:
  - Swift: `remove()` at `:153-154` and `freeStamp` at `:168`.
  - Rust: `free_stamp` at `journal.rs:278-281`, and `remove` at `:256-259`, which
    returns `Ok(())` on a read error.

The earlier fix, which counted U+FFFD after a lossy decode, is **unsound**. It gives
a false positive on a file that legitimately contains U+FFFD, and it is a
roundabout way of asking "did the read work?".

**The fix**, in all three ports, on the write path and in `remove` and `freeStamp`:

1. A missing file (`NotFound` / `ENOENT` / no document) reads as `""`.
2. Any other read error, and any failed **strict** decode, is an error:
   - Swift: `String(data:encoding: .utf8) == nil`.
   - Rust: `ErrorKind::InvalidData` from `read_to_string`.
   - Kotlin: a `CharsetDecoder` with `CodingErrorAction.REPORT`.
3. On Android, `readText` must tell *absent* (null) apart from *failed* (throw).

The refusal has to be loud, not silent: add a new `SaveState` / error path
("This file isn't valid UTF-8 — it hasn't been saved") rather than folding it into
the generic failure string, because the user's remedy is different (open the file
in an editor and re-save it as UTF-8).

> Note on scope: `JournalLibrary.load()` skipping undecodable files (`try?` on the
> read at `JournalLibrary.swift:93`) is *acceptable* — the entry is invisible but the
> bytes are untouched. That holds only once the write path refuses. Today the
> skipped inbox is exactly the file the next save destroys.

### S-02 · `relocate` panics on a short `new_ts` (Tauri) — *re-rated P2 (hardening)*

**Where** — `tauri/src-tauri/src/lib.rs:105, 114` — `library.day_file(&stamp[..10])`,
where `stamp` is `new_ts.unwrap_or_else(...)` and `new_ts: Option<String>` arrives
from the webview. `journal.rs:102` — `date: ts[..10].to_string()`. `save` and
`remove` also reach that slice, through `compose` → `build` with a webview-supplied
`ts`.

**Validation.** Both panics reproduced: `"2026"` is out of bounds, and `"2026-09-0é"`
is not a char boundary. But the shipped UI always sends a well-formed 19-character
stamp: `stampOf` at `app.js:97` builds it from a guarded `Date`, and `commitTime`
validates. So reaching the panic needs a malformed or compromised `invoke`. That
makes this hardening, not P0.

**The bug.** `&str[..10]` is a byte slice and panics if the string is shorter or
lands mid-character. Confirmed by execution:

```
thread 'main' panicked: end byte index 10 is out of bounds for string of length 2
```

Every other value in the format layer is validated (`dayFile` in Swift splits on `-`
and checks the count; `JournalPaths.dayFile` in Kotlin does the same), so this is
the one place a malformed input reaches an index. It is reachable from the
frontend, and `day_file` is the only guard between it and the slice.

**The fix.** An earlier draft proposed
`fn day_of(ts) = ts.get(..10).filter(|d| d.as_bytes()[4] == b'-')`. That does not
panic, but it is too weak:

- `"../.-..-.."` passes it, and `day_file` then yields a path outside the journal.
- A `ts` such as `"NaN-NaN-…"` is written as a header that `parse_entries` will not
  match, so the entry becomes preamble text and disappears (S-73).

Instead, validate `ts` with `NaiveDateTime::parse_from_str(ts, STAMP)` at the start
of `save`, `remove` and `relocate`, reject it if it does not parse, and derive the
date from the parsed value. Add `#[cfg(test)]` cases for `""`, `"2026"`,
`"2026-09-0é"`, `"../.-..-.."` and `"2026-09-08 10:00:00"`.

### S-03 · `--prose` names a colour and a font stack; the Tauri build loses the prose colour — *re-rated P1*

**Where**
- `tauri/src/styles.css:14` — `--prose: #453d33;` (the colour)
- `tauri/src/styles.css:22` — `--prose: 'Newsreader', Georgia, serif;` (the face) — **dead**, overridden four lines later in the same block
- `tauri/src/styles.css:58` — `--prose: #d2c8b7;` in the dark block — **dead**
- `tauri/src/app.js:988-993` — `applyTheme()` sets `--prose` from the palette (a colour) and then **overwrites it** with the face stack
- `tauri/src/styles.css:327` — `.prose { color: var(--prose); }`
- `tauri/src/styles.css:363` — `.prose.focus .ln.live { color: var(--prose); }`

**The bug.** `--prose` ends up as a font stack, because `applyTheme` assigns it
twice and the face stack is assigned last. `color: var(--prose)` with a
`'Newsreader', Georgia, serif` value is invalid at computed-value time, so the
declaration is dropped and `color` inherits. Body prose therefore renders in
`--ink`, not `--prose`, in all fourteen themes in both appearances. In Almanac
light that is `#171310` instead of `#453d33` — the warm grey the whole palette is
built around is not being drawn. In focus mode the lit paragraph
(`.prose.focus .ln.live`) loses its colour too, so the one live line is
indistinguishable from the headings.

The two declarations at `:14` and `:58` are the intent surviving as dead code, which
is how this survived a working app.

**Validation.** Confirmed in headless Chromium. The final `--prose` is
`'Newsreader', Georgia, serif`, and `.prose` computes to `rgb(23,19,16)`, which is
`--ink`. One correction: `:58` is not strictly dead. If `themes.json` fails to load,
`applyTheme` returns early at `:985`. With a dark paper, `--prose` is then
`#d2c8b7`, so `font-family: var(--prose)` (`:108`, `:324`) is invalid and the prose
falls back to the label sans. The damage is a colour and not data, so the item is
re-rated **P1**. `.marginalia` (`:108`) also needs switching to `--prose-face`.

**The fix.** Rename the face variable and leave the palette key alone:

```css
:root { --prose-ink: #453d33; --prose-face: 'Newsreader', Georgia, serif; }
```
```js
root.style.setProperty('--prose-ink', palette.prose);          // from the palette loop
root.style.setProperty('--prose-face', stack(theme.type.prose, 'Georgia, serif'));
```
```css
.prose  { font-family: var(--prose-face); color: var(--prose-ink); }
.marginalia { font-family: var(--prose-face); }
.prose.focus .ln.live { color: var(--prose-ink); }
```

**Guard it.** Add a unit test that parses `styles.css`, collects every
`--<name>:` declared in `:root`, and fails if any name is declared twice or is used
by both a `color:` and a `font-family:` declaration. Four builds and one palette
table is exactly the situation where a variable collision goes unnoticed.

### S-04 · `beforeunload` cannot flush an async save (Tauri)

**Where** — `tauri/src/app.js:1374` — `window.addEventListener('beforeunload', () => { save(); })`

**The bug.** `save()` is `async` and awaits `invoke('save', …)`. The document is
torn down the instant `beforeunload` returns; the IPC round trip never completes.
The last edit before closing the window is lost — up to a full 700 ms debounce
window, plus whatever the reader typed in that window. The Tauri build is the only
one of the four that does not write on the way out (the Apple builds write in
`willResignActive`/`scenePhase`, Android in `onStop`).

**The fix.** Use Tauri's close-requested event, which can be *prevented* while a
write is in flight:

```js
const unlisten = await appWindow.onCloseRequested(async (event) => {
  if (state.saveState !== 'Writing…') return;
  event.preventDefault();
  await save();
  await unlisten();
  await appWindow.close();          // second time through, now clean
});
```
Permissions. `core:event:allow-listen` is already in `core:default`. Checked
against tauri 2.11.5: `core:default` is every core plugin's `:default` set, and
`core:event:default` covers listen, unlisten, emit and emit-to. What must be added
to `tauri/src-tauri/capabilities/default.json` is **`core:window:allow-destroy`**,
which is not in `core:window:default`. `onCloseRequested` calls `destroy()`
whenever the handler does not `preventDefault`, so without that permission *every*
normal close fails. Keep a `beforeunload` handler only as a last-resort
`setTimeout(save, 0)`, and be honest in the comment that it is best-effort.

**Validation.** Confirmed in substance, with two corrections:

- "The IPC round trip never completes" is too strong: the request may reach Rust
  before teardown. The accurate claim is that nothing guarantees it.
- The snippet needs `try/finally` around `save()`. Otherwise a failed save leaves
  the window unclosable, or closes it having lost the edit, depending on where it
  throws.

The custom close button (`app.js:1363`) goes through close-requested, so the same
handler covers it.

### S-05 · Android's "save on the way out" is not durable

**Where**
- `android/.../MainActivity.kt:38-41` — `override fun onStop() { store.flushNow() }`
- `android/.../store/JournalStore.kt:304` — `fun flushNow() = flush()`
- `android/.../store/JournalStore.kt:280-300, 340` — the writes run in `viewModelScope`
- `android/.../data/SafTree.kt:139-160` — `writeText` truncates in place, with a rollback write that is itself un-fsynced

There is also an `ON_PAUSE` `flushNow` at `ui/RootScreen.kt:100`, and `writeText`
opens with mode `"wt"` at `SafTree.kt:146` and `:153`.

**The bug (as corrected by validation).** The earlier draft's mechanism was wrong in
two ways:

- Rotation does not clear the `ViewModel`. The manifest handles `orientation` and
  `screenSize`, and a `ViewModel` survives configuration changes anyway. It is
  cleared only when the activity *finishes*, for example on back-out.
- Coroutine cancellation cannot stop `writeText` part-way. Blocking IO inside
  `withContext(IO)` runs to completion, so cancellation can only stop a save from
  *starting*. On back-out that means a dropped save, in a window of milliseconds.

The real half-written-file risk is **process death** during the truncate-then-write.
The rollback path in `writeText` makes it worse, because it truncates again with
`"wt"`. (`"wt"` is itself the right mode; `"w"` is the one known not to truncate on
some providers.) S-01's refusal path is the model here: a partial write should be
impossible, not merely unlikely.

**The fix.**
1. Give the store an application-scoped `CoroutineScope`
   (`ProcessLifecycleOwner.get().lifecycleScope`, or a scope held by `WanderApp`),
   and run flushes there, wrapped in `withContext(NonCancellable)`. That is enough
   for the `onStop` path. **Do not `runBlocking` in `onStop`**: on the main thread,
   with a cloud or network provider, it risks an ANR.
2. In `SafTree.writeText`, `fd.sync()` the stream before closing, and do not
   truncate the live file in place:
   - Write a sibling document (`<name>.wander-tmp`), delete the original, then
     `DocumentsContract.renameDocument` the temp into place.
   - SAF *does* have a rename (API 21+, optional per provider). What it lacks is
     rename-over-an-existing-file.
   - `createDocument` with a name that already exists is auto-suffixed ("DD (1).md"),
     so the sequence has to be tmp → delete → rename.
   - Where a provider does not support rename, fall back to today's in-place write.

### S-06 · `move` is remove-then-persist, so a failure between the two loses the entry

**Where**
- `Sources/Wander/Store/JournalStore.swift:311-345` — `remove` at `:320`, `persist` at `:328`
- `android/.../store/JournalStore.kt:337-368` — `remove` at `:343`, `persist` at `:347`
- `tauri/src-tauri/src/lib.rs:122-130` — `remove` at `:122-124`, `persist` at `:130`

**The bug.** Filing, unfiling and retiming all remove the entry from its old file
and then write it to the new one. If the process dies, the disk fills, or the SAF
grant is revoked between the two, the entry exists in neither file. This is the one
operation a reader will notice immediately, because it is the one they invoke on
purpose (⌘J).

**The fix.** Write the destination first, then remove from the source. If the
second step fails, the entry exists twice rather than not at all — a duplicate is
recoverable, a loss is not — and the error message should say so. Better still,
write the destination to a temp document, remove from the source, then commit the
temp; that narrows the window to a single rename that each platform can already do.

**Validation: one caveat for the same-file case.** In Swift and Rust, persist-first
is sound even when source and target are the same file (a same-day retime, or inbox
to inbox), because `remove` re-reads the file and filters by the *old* `ts`.

On Android, `freeStamp` excludes `current.ts` (`JournalLibrary.kt:138`), so the free
stamp can come back **equal** to `current.ts`. With persist-first, `persist` replaces
the entry, and the `remove` that follows then deletes the entry just written. Handle
"same file and same ts" as a single rewrite, or skip the remove when source, target
and ts all match.

This item interacts with S-68, the Android flush race, which feeds `move` a stale
entry.

### S-07 · The Tauri markdown styliser corrupts its own markup

**Where** — `tauri/src/app.js:210-223` (`inlineStyle`), used by `renderLine` at 226-246.

**The bug.** Five regexes are applied in sequence, each re-scanning the **output of
the previous one** — which is HTML, not markdown. Three confirmed failures:

```
A) mailto url:
   <span class="url">mailto:me<span class="tag">@example</span>.com</span>
   → a <span> injected inside a span; the @tag rule matched a URL

B) nested code + link:
   <span class="code">…<span class="link">a</span>…<span class="url">http://x.y</span>…</span>
   → `[a](http://x.y)` inside backticks is styled as a live link

C) ***both***:
   <span class="mark">*<span class="mark">*</span><span class="em"></span>
   <span class="strong"></span><span class="mark">*</span>both</span>…
   → the `**` rule fires first, captures `*` as its content, and the result is
     both unbalanced and unreadable
```

(C) is the common case — bold-italic is ordinary markdown and it renders as garbage
on Linux and Windows. The Apple and Android builds use the same rule order with
matching patterns, so `***x***` is wrong there too, but *span-based*, so the damage
is contained to the run's colours rather than its structure.

**Validation.** All three examples reproduced with `node`, with one correction to
(A). A bare `mailto:me@example.com` gets a tag span in plain text. The nested-in-`.url`
output shown above only happens inside a link, e.g. `[x](mailto:me@example.com)` or
`(http://a.b/@c)`.

It is **worse than stated**. Plain `**a**` followed by anything on the same line is
also mangled. The `*…*` rule matches from the second `*` of the `**` marker across
the `</span><span class="strong">` that the strong rule emitted. So in `**a** and *b*`,
" and " renders in the faded marker colour and `*b*` is not italic.

The text content is preserved, so the caret arithmetic still works; the damage is
to styling only. There is no attribute injection.

Replaying the Swift (`MarkdownStyle.swift:31-35`) and Kotlin
(`MarkdownStyler.kt:38-39`) regexes on `***both***`:

- One strong match covers the first 9 characters, with the inner `*both` in bold.
- Emphasis never matches: in Kotlin the `(?<![*\w])` lookbehind fails.
- The result is bold with no italic, and a stray `*` drawn in prose colour rather
  than marker colour.

**The fix.** Replace the chain with a single left-to-right scan that consumes the
input once and appends to an output buffer — the obvious implementation is a
single combined `RegExp` with named alternatives ordered code → strong → emphasis →
link → tag, scanned with `exec` in a loop, escaping each literal chunk as it is
emitted. This is both correct and faster, because it is one pass over the line
instead of five.

Apply the same fix to `MarkdownStyle.swift:31-35` and
`MarkdownStyler.kt:38-42` for the `***` case, or accept the divergence and note it.

### S-08 · The Tauri calendar skips February (and can skip any 31-day month)

**Where** — `tauri/src/app.js:1292, 1296` — `state.calendarMonth.setMonth(state.calendarMonth.getMonth() ± 1)`

**The bug.** `setMonth` operates on the day-of-month, so it overflows. Confirmed:

```
Jan 31 -> setMonth(+1) = Tue Mar 03 2026      (expected 28 Feb)
Jan 15 -> setMonth(+1) = Sun Feb 15 2026      (fine — only day > 28 is affected)
```

Anyone who opens the reschedule sheet on the 29th, 30th or 31st and presses `›`
jumps straight past the next month. Going backwards has the mirror bug
(31 Mar → 3 Mar).

**Validation.** Confirmed with `node` (Jan 31 +1 → Mar 03, and Mar 31 −1 → Mar 03).
`calendarMonth` is never pinned to the 1st: it is set to `new Date(sheetDate)` at
`:1064` (`openSheet`), `:1108` (day click) and `:1303` (Today). So what triggers the
bug is the *entry's or chosen* date falling on the 29th–31st, not today's date.

**The fix.** The grid reads only the year and month of `calendarMonth`, so no
clamping is needed. Pin it to the 1st at the three sites above, and plain `setMonth`
is then correct:

```js
state.calendarMonth = new Date(d.getFullYear(), d.getMonth(), 1);
```

The Swift (`CalendarPicker.shiftMonth`) and Kotlin sheets use
`Calendar.date(byAdding:)` / `LocalDateTime.plusMonths`, which clamp correctly, so
this is Tauri-only.

### S-09 · Tauri actions fail silently: no error handling on copy, star, remove, move — *re-rated P1*

**Where** — `tauri/src/app.js:1172-1175`, `navigator.clipboard.writeText(rawOf(entry))`
with no `.catch`. Also `toggleStar` (599-609), `removeEntry` (633-637), `moveEntry`
(639-646), `newEntry`, `toggleFiling`, `refresh` and the `o-folder` handler.

**The bug.** None of these handles a rejected promise. When one fails, nothing
appears on screen and the reader concludes the button is broken.

**Validation: the earlier root cause was wrong.** The first draft blamed a missing
clipboard capability, and that does not hold:

- Tauri's ACL gates IPC commands only. `navigator.clipboard` is a web API and does
  not pass through it.
- `core:webview:allow-write-clipboard` does not exist; checked against the full
  core:webview permission list in tauri 2.11.5.
- `clipboard-manager:allow-write-text` gates only the clipboard-manager plugin's
  commands, and that plugin is not a dependency.
- The real switch is `WebviewWindowBuilder::enable_clipboard_access()`, which cannot
  be set from `tauri.conf.json` in tauri-utils 2.9.3.
  - On WebKitGTK it sets `javascript-can-access-clipboard`. An async `writeText`
    inside a click, on the secure `tauri://` scheme, should work without it.
  - On WebView2 it only auto-grants clipboard **read**.

So "silently does nothing on Linux and Windows" is **unverified**, and needs a
runtime test on WebKitGTK.

**The fix.** Give every async action a `.catch` that shows the failure in the save
line. If the clipboard write does fail on WebKitGTK, adopt
`tauri-plugin-clipboard-manager` and its JS API, along with its permission.

### S-10 · Windows paths are split on `/` — *re-rated P3 (display only)*

**Where** — `tauri/src/app.js:826` and `:915` — `entry.source.split('/').pop()`

**The bug.** The delete confirmation and the Stats "File" row show the wrong
filename on Windows, where the separator is `\`. `JournalPaths.name` in Kotlin uses
`substringAfterLast('/')` over a relative path, so it is correct by construction;
this is the port that lost the invariant.

**The fix.** `entry.source.split(/[\\/]/).pop()`, or a `basename()` helper. Worth a
one-line comment, because the next person will "simplify" it back.

**Validation.** Confirmed. Rust sends an absolute path via `to_string_lossy()`
(`journal.rs:110`), so Windows paths contain `\`. It is display-only.

### S-11 · The custom undo stack can never reach the pre-first-keystroke state

**Where** — `tauri/src/app.js:377-387` (`snapshot`), `400-410` (the ⌘Z handler), `570` (`loadDraft`)

**The bug.** `snapshot` is debounced 400 ms and pushed *after* an edit, so the
oldest entry in the stack is the text as it stood after the first keystroke.
Pressing ⌘Z repeatedly therefore bottoms out one character in, never at empty, and
the final press pops nothing and does nothing. The stack is also global rather than
per entry and is cleared outright on every selection change (570), so ⌘Z after
switching entries cannot reach back into the previous one. There is no redo at all.

The custom stack exists because `renderProse` replaces DOM nodes and so invalidates
the browser's own undo. That is the real problem; the stack is a patch for it.

**The fix.** Stop replacing nodes. Handle `beforeinput` on `#prose` and apply
`insertText` / `deleteContentBackward` / `insertFromPaste` (as plain text)
yourself, then apply spans as *wrapper elements around the affected text node* — the
approach `MarkdownStyler` already takes on Android and which keeps the browser's
undo intact. If that is too large to do now, then at minimum: seed the stack with
the loaded text in `loadDraft`, add a redo stack behind ⌘⇧Z, and key the stacks by
entry id. Whichever is chosen, the current behaviour should be documented, because
"undo" that cannot undo the first keystroke is worse than the browser default.

**Validation.** Confirmed: the undo handler is at `:398-410`. It is worse than
stated:

- The top of the stack equals the current text, so the first ⌘Z after a pause does
  nothing.
- A pending 400 ms snapshot timer can push the edited text back on after an undo.
- `wrapSelection` (⌘B/⌘I) never snapshots.
- ⌘⇧Z also *undoes*, because the key is lower-cased.

The minimal fix is the realistic one: seed the stack in `loadDraft`, keep one stack
per entry, add redo, and cancel the pending snapshot on undo.

### S-12 · The macOS/iOS store drops the unsaved new entry on reload — *re-rated P2*

**Where** — `Sources/Wander/Store/JournalStore.swift:171-174`

```swift
if let draft = draftEntry, draft.source == nil,
   !entries.contains(where: { $0.id == draft.id }) {
    entries.insert(draft, at: 0)
}
```

**The bug.** `newEntry()` (425-432) sets `entry.source = library.inboxURL`, so
`source` is never `nil` for a new entry and this branch never runs. A `⌘N` followed
by a folder reload (or any `reloadIfChanged` that lands first) drops the entry from
the list and moves the selection away from it.

The Android port's guard at `android/.../store/JournalStore.kt:170-172` works, but
not for the reason the earlier draft gave. `kept.source != null` is just as vacuous
there, because `newEntry` sets `source = INBOX` at `:435`. What makes it work is the
*emptiness* test (suffix and body both empty), together with `draftEntry` staying
the blank copy from before the flush. The Swift guard should use the same emptiness
test.

Related: `EditorView.saveLabel` (`EditorView.swift:170`) decides "Unsaved draft"
from `selectedEntry?.source == nil`, which is also never true for a new entry. So a
brand-new unsaved entry is labelled **Saved**. Android has the same bug at
`ui/EditorScreen.kt:163`. Use one "not on disk yet" predicate for both, in both
ports.

**Validation: re-rated P2.** Only an *untouched, empty* ⌘N entry can be dropped:

- `reloadIfChanged` is guarded by `!dirty` (`:185`).
- Typed text is written by `flush` before any reload.
- The emptied-draft path sets `source = nil` (`:263`), which the existing guard
  does catch.

Nothing is lost. The blank row vanishes and the selection jumps.

---

## P1 — Promised behaviour that no build delivers

### S-13 · "Picking a theme brings its type size and leading with it" — no build does this

`README.md:119-120` says picking a theme takes its type size and leading with it.
All three theme pickers explicitly do the opposite, with comments saying so:

- `Sources/Wander/Views/ThemesSheet.swift:102-108` — *"Type size and leading are the
  reader's settings, not the look's: a theme change leaves them exactly where they were."*
- `Sources/WanderiOS/ThemeSwiper.swift:137-142` — *"Type size and leading stay as the reader set them."*
- `tauri/src/app.js:1266-1268` — same.

Android is a third thing again: it applies the theme on swipe, never touches the
user's `typeSize`/`leading`, but previews the spread with `theme.proseSize`
(`ThemeSwiper.kt:77-85`), so the preview shows a size the app will not use.

**Validation.** The earlier draft said the `typeSize`/`leading` bindings were never
used. That is wrong:

- `ThemesSheet` passes `leading` to `ThemeCard` (`:34`), which uses it at `:180`.
- `ThemeSwiper` uses both bindings (`:31`, `:252`).
- Only `ThemesSheet.typeSize` is unused.

Missed by the earlier draft: the **header comment of `ThemesSheet.swift` (`:6-8`)**
repeats the README's claim ("Picking one also takes its type size and leading"), and
so contradicts `pick()` in the same file. On Android, `proseStyle()`
(`ui/Components.kt:38, 45`) also previews with `theme.lineHeight`, so the preview's
leading differs from the editor's as well as its size.

**Decide, then make all four match.** Every picker's comment says the reader's
settings stay put, so the code's intent is the comments', not the README's. So:

1. **Fix the README** and the `ThemesSheet.swift:6-8` header.
2. Delete the unused `ThemesSheet.typeSize` binding.
3. Make Android's swiper preview with the reader's `typeSize`/`leading`.

If instead the README is right, the four pickers each need
`typeSize = entry.proseSize` and `leading = entry.lineHeight - 1` on pick. Either is
a small change; leaving it split is not.

### S-14 · Filing moves the reader on Android and not on the other three

- `Sources/Wander/Store/JournalStore.swift:381-398` (`toggleFiling`) — stays on the
  page and selects `successorID(of:)`, so the inbox is cleared one ⌘J at a time.
- `tauri/src/app.js:615-631` — the same, via `successorId`.
- `android/.../store/JournalStore.kt:413-419` — **switches page**:

```kotlin
val page = _state.value.page
if (page == Page.JOURNAL && !wasUnfiled) show(Page.INBOX)
else if (page == Page.INBOX && wasUnfiled) show(Page.JOURNAL)
```

`README.md:54-58` documents the macOS behaviour: the index "stays in the inbox …
rather than throwing you over to the journal and back". So Android is the outlier.

Worse, `file()`/`unfile()` are `launch`ed on `Main.immediate` and suspend inside
`move`'s `withContext(IO)`. The sequence is:

1. `show()` runs against the *pre-move* state.
2. `select()` jumps to another entry and flushes.
3. `move` then selects the moved entry again, which shows as a flicker.

If the move fails, the page has already switched. This is S-06's data model showing
up as a UI race, and S-68 is the data-loss half of the same race.

**The fix.** Give Android the same `successorId` as Swift, call `show` only if the
entry is not on the page after the move, and make `file`/`unfile` `suspend` so the
page decision happens after the move completes.

### S-15 · Android's stats "Figures" panel shows the wrong numbers

- `Sources/Wander/Views/StatsPanel.swift:36-41` — for `statsStyle == .figures`, the
  four tiles are a **mix**: Words (this entry), Days running, This month, and
  Reading (this entry). The earlier draft said all four were entry-level, and that
  was wrong.
- `android/.../ui/StatsSheet.kt:110-149` — `Figures(state, draft)` takes `draft` and
  **never reads it**. The three tiles are `Entries`, `Words` and `Streak`: journal
  totals that duplicate the Journal section beneath them. The Android rows style
  also lacks a "This entry" section entirely.

So a `figures` theme shows a different set of numbers on each platform. And
`StatsSheet(store, state, store.draft)` at `RootScreen.kt:149` passes a draft it
will not use, so the sheet does not update as you type, the way the Apple one does.

**The fix.** Make Android's `Figures` show the same four tiles as
`StatsPanel.swift:36-41`: entry words and entry reading minutes from `draft.body`,
plus days running and this month. Memoise on `draft.body`, the way
`EditorScreen.Status` already does at `EditorScreen.kt:143`.

### S-16 · iOS shows three dead rows in Options

`Sources/WanderiOS/RootViewPhone.swift:113-115` passes
`showIndex: .constant(true), showStats: .constant(true), showOptions: .constant(true)`.
`OptionsPanel.columns` (`Sources/Wander/Views/OptionsPanel.swift:83-97`) renders all
three, and the toggles write to a constant — a no-op. The reader sees Index / Stats /
Options all reading "Open", and pressing them does nothing.

**The fix.** Add `showsColumns: Bool = true` to `OptionsPanel` and pass `false` from
iOS, or hoist the three bindings into the platform shells rather than hard-coding.

### S-17 · The same setting is presented three different ways

| | macOS / iOS | Android | Tauri |
|---|---|---|---|
| Leading | `1 + leading`, "1.30" | raw, **"0.30"** | `1 + lead`, "1.30" |
| Type size | `%.1f`, 13–28 | `.toInt()` pt, 12–30, step 0.5 | `.toFixed(1)`, 13–28 |
| Appearance labels | Auto / Light / Dark | **System** / Light / Dark | Auto / Light / Dark |
| Leading step / range | 0.06, 0.10–1.20 | 0.05, 0–1.2 | 0.06, 0.10–1.20 |
| Measure | from theme | none (parsed, unused) | user stepper, 520–1100 |
| Typewriter | yes | yes | **absent** |
| Focus shortcut | ⌘⇧F | Options sheet only | **none — ⌘⇧F runs Find** (S-63) |

`android/.../ui/OptionsSheet.kt:47` — `String.format("%.2f", settings.leading)` also
uses the default locale, so a comma-decimal locale shows `0,30`. On Android the type
size moves in steps of 0.5 but is shown with `.toInt()` (`OptionsSheet.kt:40-42`),
so every other tap appears to change nothing (17.5 shows as "17"). The "System"
label is at `ui/AppearanceSettings.kt:37`. The earlier draft's Tauri leading of
"1.42" was the static HTML placeholder; the live default is 1.30.

**The fix.** Pick one model and one set of numbers, put them in the README, and
match all four. The "leading is quoted the way a typesetter would: a multiple of the
type size" comment at `OptionsPanel.swift:63-64` is the right answer — Android should
show `1 + leading` too. `String.format` should take `Locale.US` explicitly, as
`Formats.groupNumber` already does on the Kotlin side.

### S-18 · The Tauri build ignores half of every theme

`applyTheme` (`tauri/src/app.js:984-1017`) sets the palette, the three faces, label
size/tracking, display scale, corner, border, masthead rule and eight `data-`
attributes. It does **not** set, and the stylesheet does not read:

- `displayTracking` — the wordmark (`styles.css:166-172`) hard-codes
  `letter-spacing: -.015em` at `:170`, and `.title` (`:307-313`) sets none at all.
  Cinema (0.4) is the one theme with wide tracking, and it shows none. The others
  are negative. (The earlier draft also named Broadsheet, which has no display
  tracking.)
- `displayUppercase` — no `text-transform` anywhere except `.smallcaps` and
  `.pv-meta`. Cinema is an Oswald-caps theme; its masthead is not capitalised.
- `displayWeight` — hard-coded `600` on the wordmark at `:169`. `.title` has no
  `font-weight` at all; `:309` is its font-size.
- `proseWeight`, `proseSize`, `labelWeight`, `labelUppercase`.
- Also set but never read: `--border` (set at `:999`), and the `data-stats` and
  `data-kicker` attributes. `chrome.filledButtons` is honoured only in the theme
  previews.

`styles.css` also hard-codes the serif in four places that should be themed:
`:236` (the find placeholder), `:370` (`.blank h1`), `:432` (`.sheet h2`) and `:438`
(`.cal-month`). All say `'Newsreader', Georgia, serif` rather than `var(--display)`;
the variable is `--display`, not `--display-face`. So the "Nothing open" heading and
the sheet headings ignore the chosen theme.

**The fix.** Add `--display-tracking`, `--display-weight`, `--label-weight` and
`--label-transform`, and set them in `applyTheme`. A custom property cannot be fed
a boolean, so `--label-transform` takes the value `uppercase` or `none`. Use them at
`:169`, `:170` and in `.title`, and replace the four hard-coded font stacks.

### S-19 · Two of the five masthead styles are approximations, and `band` can be unreadable

- `centred` (Swift `RootView.swift:190-207`) is a running-head row, then a centred
  wordmark, then the page switches, then a rule. `:root[data-masthead='centred']`
  (`styles.css:542-543`) just makes `.masthead-row` a flex column, so the DOM order
  (wordmark, pages, spacer, running-head, toggles) is preserved and the layout is
  visibly different.
- `double` (Swift `RootView.swift:210-233`) is a 3 pt rule, a hairline 3 pt below it,
  two slugs flanking the wordmark, then the switches. `styles.css:545` is
  `box-shadow: 0 4px 0 -3px var(--ink)`. Broadsheet's rule is 3 px, so the negative
  spread shrinks the shadow to nothing. **Chromium draws no second line at all**, and
  there are no slugs and no second row.
- `band`: `styles.css:537` sets `.pages button.on { color: var(--accent) }`
  unconditionally. Apple uses `theme.accentOnBand`, which exists precisely because
  Brutalist's accent *is* its ink (contrast 1.00 in both modes). On the Tauri build,
  an active page tab in a `band` theme is the same colour as the band and vanishes.
  (The earlier draft said Android uses `accentOnBand` too. It does not: Android has
  no `band` or `centred` masthead at all, and `RootScreen.kt:278-286` falls through to
  a plain rule. See S-82.)
- `band`, further: `.pages button:hover { color: var(--ink) }` (`:176`) makes a
  hovered tab ink-on-ink, and invisible, in every `band` theme. The inactive page and
  column buttons are `--muted` on the ink band, at contrast 3.1–4.3 in Cinema, Bauhaus
  and Brutalist.

**The fix.** Publish the derived, contrast-checked tones as custom properties from
`applyTheme`: `--accent-on-band`, computed with the existing `readableOn()` in
`app.js:948-951`, and a `--muted-on-band`. Use them for the active, hover and
inactive states under `[data-masthead='band']`. For `centred`, add a
`.masthead-slugs` row. For `double`, give `.rule-heavy` a `::after` hairline,
positioned rather than drawn with a shadow.

### S-20 · Word and character counts disagree across the four builds

Four implementations, three answers:

| | `words` | `characters` |
|---|---|---|
| Swift (`Entry.swift:126-140`) | splits on `\x20 \n \t \r` only — a non-breaking space does **not** separate words | `s.count` — grapheme clusters, so 👍 is 1 |
| Kotlin (`Entry.kt:116-130`) | identical to Swift | `s.length` (`:130`) — **UTF-16 code units, so 👍 is 2** |
| Rust (`journal.rs:74-76`) | `split_whitespace()` — Unicode-aware, so a non-breaking space **does** separate | *not computed* — Tauri's character count is the JS one |
| JS (`app.js:77`, `:864`) | `/\s+/` — Unicode-aware, so NBSP **does** separate | `.length` — UTF-16, so 👍 is 2 |

(An earlier draft said Rust counts characters as `body.len()` bytes. Rust computes
no character count at all.)

Within the Tauri build itself, the row meta and the journal total come from Rust's
word count (`app.js:804`, `:918`), while the status line and panel use the JS count.
The two also differ at the edges: U+0085 separates words in Rust but not in JS
`\s`, and U+FEFF does the reverse.

Confirmed by execution:
```
words("a\u00a0b") = 2   (Swift and Kotlin count 1)
"👍".length      = 2   (Swift s.count = 1)
```

So the status line under an entry reads differently on the Mac and on Linux, and
the "Words" total in the Stats panel — a sum over the whole journal — differs
permanently between the two families. A reader who syncs one folder across Mac and
Linux sees two different totals forever.

**The fix.** One definition, stated once: words are maximal runs of characters that
are not in `{' ', '\t', '\r', '\n'}`; characters are Unicode scalar values. Then
implement it identically in all four:

- Rust: split on the four ASCII whitespace characters rather than using
  `split_whitespace`.
- JS: `[...text].length` for characters.
- Kotlin: `s.codePointCount(0, s.length)` for characters.
- Swift: `s.unicodeScalars.count` for characters. Swift must change too, because
  code points are not Swift's grapheme `count`.

Add these to the cross-port conformance fixture (S-67), so that a divergence fails a
build rather than a reader's eye.

### S-21 · CRLF files are read and re-written with mixed line endings

All three parsers split on `\n` only. A file written on Windows with CRLF keeps its
`\r` on every interior line, and `renderEntries` then joins the entries with `\n`.
The result is a file that is half CRLF and half LF, and whose bytes change on the
first save even if nothing was edited — which a sync client sees as a modification
to every entry, on every platform, forever.

**Validation.** Confirmed by execution in Rust. A CRLF file after one `persist` came
out as `"[..] one\nline a\r\nline b\n\n[..] two\nbody\n"`, which is mixed endings.
The header's `\r` is eaten by `.trim()` on the suffix, and the last body line's by
`.trim()` on the body. The splits on `"\n"` are at:

- `JournalParser.swift:56, 78`
- `JournalParser.kt:51, 76`
- `journal.rs:124, 146`

Swift's `trimRightNewlines` (`JournalParser.swift:115-121`) compares `Character`s,
and `"\r\n"` is a single grapheme. So Swift's CRLF behaviour may also differ from
Kotlin's `trimEnd('\n')`. That could not be run on the validating host.

**The fix.** Decide and state it: normalise `\r\n` → `\n` on read, and write `\n`.
Do it once, at the point where the file's text is read, in all three ports.
`leading_preamble` (`journal.rs:143`) splits the content independently of
`parseEntries`, so normalising only inside `parseEntries` is not enough. Add a CRLF
fixture to the conformance suite (S-67). The Android `README.md` (`:25-26`) already
claims byte-for-byte compatibility, and this is where that claim is currently false.

### S-22 · Tauri claims Windows and ships no Windows installer

`tauri/src-tauri/tauri.conf.json:28-29` — `"targets": ["deb", "appimage", "rpm", "dmg"]`,
so there is no Windows installer format. `README.md:240` is a build-table row,
"Linux, Windows, macOS | `cargo run`". It promises that the app runs there, not an
installer, but a reader will reasonably expect one.

(An earlier draft said every `tauri build` tries all four formats regardless of
host, and fails. That is **unverified and probably wrong**: the bundler filters the
configured types down to those the host supports, so `dmg` is skipped on Linux. It
is still true that rpm and AppImage need host tooling on Linux.)

**The fix.** Add `"msi"`, `"nsis"` to the list; move the per-platform bundling to a
small script or document `--bundles <target>` in the README.

### S-23 · README overclaims byte compatibility in the one place it does not hold

*A documentation item, filed here because it describes a promise.*

`README.md:15` — "read and write the same folder, byte for byte". The same absolute
claim is made at `README.md:252-253` ("kept byte-compatible on purpose"),
`android/README.md:25-26` and the `journal.rs:1-5` module doc. It is true in the
happy path and false in three ways this review found:

- non-UTF-8 (S-01)
- CRLF (S-21)
- count divergence (S-20). This is a read-side divergence, but it proves the ports
  are not the same program. Rewrite as "the same folder, and the same bytes for anything
written as UTF-8 with LF endings" once S-01 and S-21 are fixed, and keep the
qualifier — the format is shared with third-party tools and the claim should not be
absolute.

### S-24 · The Android README describes a build step that does not exist

`android/README.md:14` — "`themes.json  copied from ../Resources — the same table
all four builds read`", and again at `:46`. The claim that the build *writes*
`fonts.json` is not in the README (an earlier draft misquoted it). It is in code
comments: `ui/Fonts.kt:19` ("the build writes …") and `ui/Theme.kt:185` ("copied in
by the build").

Neither `android/app/build.gradle.kts`, `android/build.gradle.kts` nor
`settings.gradle.kts` contains any copy task. Both `themes.json` and `fonts.json`
are committed. `md5` confirms the three `themes.json` copies are currently
byte-identical (`c87b5a85…`), but nothing keeps them that way.

Also in `android/README.md` (`:73-76`): "The Gradle wrapper jar is not checked in"
is false. `android/gradle/wrapper/gradle-wrapper.jar` is tracked.

**The fix.** Pick one: add a Gradle `Copy` task + `preBuild.dependsOn` (and a
verification task that fails on mismatch), or delete the claim and add a
`tools/check-parity.sh` to CI. The first is better — one source of truth.

---

## P2 — Performance on the keystroke path

These are ordered by how much they cost per keystroke with the Stats column open on
a journal of a few thousand entries. The recurring theme: **something is recomputed
per render that could be computed once at parse time, and something is walked two or
three times when once would do.**

### S-25 · `Entry.tags` runs a regex over the whole entry, several times per render

`Entry.tags` (`Entry.swift:93-96`, `Entry.kt:62-66`) is a computed property that runs
`JournalParser.splitTags(raw)` — a regex over the entry's **entire raw text** — every
time it is read. Call sites:

| | per render of |
|---|---|
| `EditorView.swift:147` (`kickerText`) | 1 |
| `EditorView.swift:154` (`dateline`) | 1 |
| `StatsPanel.swift:120` and `:181` | 2 |
| `EditorScreen.kt:195` (`kickerText`) | 1 |
| `EditorScreen.kt:202` (`dateline`) | 1 |
| `StatsSheet.kt:60` and `:61` | 2 |

`EditorView`'s header recomposes on every title keystroke, so typing in the **title**
bar runs two full regex passes over the **body**. This is the same reasoning that
already produced `wordCount` and `createdDate` as stored properties — the comment at
`Entry.swift:32-39` explains why, and `tags` was missed.

**Validation.** Confirmed, and understated:

- `EditorView` observes the whole `Draft`, so the tag regex runs on every keystroke
  in the **body** as well as the title. Over `selectedEntry.raw`, which does not
  change while you type:
  - `dateline`, always
  - `kickerText`, when `theme.kicker` is on
  - two more in `StatsPanel` while it is mounted
- On Android, `Draft` and `JournalStore` are unstable types, so `Header` is not
  skippable and recomposes on every body keystroke too (`EditorScreen.kt:62` reads
  `draft.body`).

**The fix.** Do not compute it eagerly in `init`. That adds a regex per entry at
parse time, which slows launch (S-31). Instead:

- Swift: keep a `selectedTags` in `rebuildSelection`, recomputed only when the
  selection or its `raw` changes.
- Kotlin: use `val tags by lazy { … }` on `Entry`.

Either way every call site above becomes free.

### S-26 · The status line walks the body three times per keystroke

`EditorView.counts` (`EditorView.swift:159-166`):

```swift
let words = Counts.words(draft.body)         // walk 1
let characters = Counts.characters(draft.body)
let minutes = Counts.readingMinutes(draft.body)   // walk 2 — calls words() again
```

`StatsPanel.thisEntry` (`StatsPanel.swift:36-51`) adds three more, including
`Counts.paragraphs`, which allocates an array of substrings via
`components(separatedBy:)` — the exact cost `Counts.words`' own comment says it
avoids. The same pattern is in the Tauri `renderCounts` (`app.js:862-868`: three
`words()` walks, because `readingMinutes` calls it again at `:79`) and in
`renderPanels` (`887-905`: four walks, though only `renderCounts` runs per
keystroke).

On Android, `liveCounts()` (`JournalStore.kt:582-592`) is **never called**. It is
dead code (S-43), not on the keystroke path. The real path is
`ui/EditorScreen.kt:143-151`, which is memoised but still walks `words` twice.

**The fix.** Make `Counts` return a single value:

```swift
public struct Counts { let words, characters, paragraphs, readingMinutes: Int }
public static func of(_ s: String) -> Counts   // one walk
```

and cache it on the `Draft` (a `@Published` recomputed only when `body` changes), or
`remember(body)` in Compose as `EditorScreen.Status` already does correctly at
`EditorScreen.kt:143`. Use it in the Apple status line, `StatsPanel`, Android's
`liveCounts` and `Status`, and the Tauri `renderCounts`/`renderPanels`.

### S-27 · `MarkdownStyle.apply` copies the whole document once per rule

`Sources/Wander/Support/MarkdownStyle.swift:74-78`:

```swift
func each(_ rule: NSRegularExpression, _ handle: ...) {
    rule.enumerateMatches(in: storage.string, range: target) { ... }
}
```

`storage.string` is evaluated once per `each` call. It is the argument, not
something inside the per-match closure. There are ten rules (`heading`, `quote`,
`bullet`, `divider`, `strong`, `emphasis`, `code`, `fence`, `link`, `tag`;
`MarkdownStyle.swift:86-156`). In Swift, bridging a *mutable* `NSString` to `String`
copies it (`CFStringCreateCopy`), so each call is one O(n) copy.

**Validation: real, but the effect was overstated.** For an 8 000-character entry
this is about 16 KB × 10 per restyle, which is microseconds next to the regex work.

**The fix.** It is simpler than the earlier draft proposed. `ns` already exists at
`:53` as an immutable snapshot, so pass `ns as String` into `each`, which is an O(1)
bridge. The length has not changed since the edit was made, so every match index
remains valid. It is a one-line change; do it, but do not expect a large effect.

### S-28 · Focus mode restyles the entire document on every caret move

`MarkdownStyle.apply:57` — the per-keystroke paragraph optimisation is disabled when
`dimInactive` is true, because dimming needs the whole text. So:

- `ProseEditor.textViewDidChangeSelection` (`ProseEditor.swift:171-175`) calls
  `restyle(tv, all: true)` on **every** caret movement.
- `textDidChange` (164-169) then calls `restyle(tv, all: false)` on the same
  keystroke.

**Two full-document restyles per keystroke in focus mode**, and the first one is
triggered by moving the caret. Validation adds two things:

- Below 8 000 UTF-16 units, *every* keystroke is already a full restyle even without
  focus mode, because the paragraph path applies only above that length.
- `textDidBeginEditing` and `textDidEndEditing` (`ProseEditor.swift:177-185`) also
  do full restyles.

On Android,
`ProseEditText.onSelectionChanged` (`ProseEditor.kt:77-83`) does the same
`restyleAll = true`. On Android `MarkdownStyler.kt:68` additionally does
`text.substring(from, to)` — a full copy of the document when the target is
`whole` — before running ten regexes over it.

**The fix.**
1. In focus mode, dim the two *ranges* (before and after the live paragraph) rather
   than restyling everything: the expensive rules only need to run on the live
   paragraph, and the fade is two `addAttribute` calls. Restructure `apply` as
   `styleBlock(range)` + `fade(range)` so focus mode costs one paragraph restyle
   plus two attribute writes.
2. Track the last live paragraph range in the coordinator; skip the selection-change
   restyle when the caret has not left its paragraph. That alone removes the
   duplicate work on the common case of typing within a paragraph.

### S-29 · Android restyles the whole document on every recomposition

`android/.../editor/ProseEditor.kt:189` — inside `AndroidView`'s `update` block:

```kotlin
view.text?.let { view.restyle(it, restyleAll = true) }
```

`update` runs on **every recomposition** of the composable, and `EditorScreen`
recomposes on every keystroke because `draft.body` changes. So each keystroke does a
paragraph restyle (from `afterTextChanged`) **and** a whole-document restyle (from
`update`). The styler is correctly memoised on line 152, which shows the pattern is
understood; the restyle call just was not gated on it.

**The fix.** Remember the last applied style key on the view and only restyle when
it changes:

```kotlin
if (view.styler !== styler) { view.styler = styler; view.text?.let { view.restyle(it, true) } }
```

`MarkdownStyler` is already `remember`ed on exactly those inputs, so identity
comparison is sufficient. Move the `setTextSize`/`setLineSpacing`/`typeface`
assignments into the same branch for the same reason.

**Validation: a gap in the fix.** Gating on the styler alone is not enough. After a
`setText` of an entry longer than 8 000 characters (not in focus mode),
`afterTextChanged` passes `restyleAll = false`, so only the caret paragraph would be
styled. A `setText`, meaning switching entries, must also force the full restyle.
Separately, in focus mode `onSelectionChanged` (`ProseEditor.kt:81`) adds a third
full restyle.

### S-30 · Search is not debounced, and a keystroke rebuilds the whole index

`query.didSet` (`JournalStore.swift:59-61`) calls `rebuildIndex()` on every
character. `rebuildIndex` (597-647) then:

- filters the whole journal (`$0.raw.lowercased().contains(needle)` — a full
  lowercased copy of every entry's raw text **per keystroke**),
- partitions into three arrays,
- rebuilds `days` (a `Set<String>` over every entry),
- sums `wordCount` over every entry,
- recomputes `streak` (another `Set` over every entry),
- regroups into month sections,
- then calls `rebuildSelection()` once. (An earlier draft said twice: `selection.didSet`
  does not fire here.)

`move()` assigns `entries` three times (`:330-332`), so a move runs `rebuildIndex`
three times. `reload()` and `newEntry()` run it twice each (S-80).

Identical in Kotlin (`search()` at `JournalStore.kt:229-233` → `rebuildIndex()`,
`510-558`, including `streak = JournalIndex.streak(it.entries)` **inside** the
`_state.update { }` lambda, which `MutableStateFlow.update` may re-run) and in JS
(`app.js:1150-1155` → `render()` → `renderPanels`).

Four fixes, each worth having:
1. **Debounce the query** by ~150 ms, the same way the save is debounced. The find
   box is not a per-character interaction.
2. **Precompute the search key per entry.** `Entry.folded`, like `wordCount` and
   `createdDate`. In the Tauri build, `haystack()` (`app.js:70-73`) already caches a
   lowercased copy of `rawOf(entry)` on the entry, which roughly doubles the
   journal's memory. The earlier draft said `touch()` invalidates it, but `touch()`
   only bumps `revision`. `entry.folded` survives until the entry object is
   replaced: one entry per save, or every entry on a refresh.
3. **Hoist the invariants.** `totalWords`, `datesWithEntries` and `entriesThisMonth`
   depend only on `entries`, not on `query` or `page`. Compute them in the `entries`
   `didSet` (and the Kotlin equivalent) rather than in `rebuildIndex`, and compute
   the filtered set separately. `streak` too.
4. Move `JournalIndex.streak(...)` out of the Kotlin `_state.update` lambda
   (`JournalStore.kt:554`). A `StateFlow` update should be pure. Every caller is on
   Main, so the CAS lambda never actually re-runs; this point is hygiene, not cost.
   The cost is that streak, words and this month (`:543-554`) are recomputed on
   every search keystroke and every save, which point 3 addresses.

### S-31 · Both stores read the entire journal synchronously at launch

- `Sources/Wander/WanderApp.swift:18` — `@StateObject private var store = JournalStore()`,
  and `JournalStore.init` (141-157) calls `reload()` (166-178) → `library.load()`,
  which walks the tree and reads and parses every file. `WanderiOSApp.swift:17` is the
  same. `@StateObject` builds the store lazily, just before the first scene body
  rather than in `App.init`, but it still runs before the first frame. On a ten-year
  journal that is seconds of beachball.
- `tauri/src-tauri/src/lib.rs:33-40` — `load` is a **synchronous** Tauri command.
  Non-async commands run on the main thread, so `library.load()` blocks the window
  for the whole parse. The comment at `journal.rs:45-48` shows how long that is
  known to take. The same is true of **every** command here: `set_folder`, `save`
  and `relocate` are all synchronous too.

Android gets this right already: `JournalStore.reload` (157-181) uses
`viewModelScope.launch` + `withContext(Dispatchers.IO)`, and `JournalState` has
`ready`/`loading` flags so the shell can show a spinner. **The other two should do
the same.**

**The fix.**
- Swift: make `reload()` `async`, run `library.load()` on a detached task, and add a
  `isLoaded` flag the sidebar reads to show "Reading the journal…" rather than an
  empty list. The `fingerprint()` in the same function is already
  `Task.detached`-based (`refreshFingerprint`, 281-294) — follow that pattern.
- Rust: mark every command `#[tauri::command(async)]`, which is the simplest option.
  An `async fn` that takes `tauri::State<State>` would need a `Result` return,
  because of the macro's check on borrowed arguments. Consider streaming: a `load`
  that returns the count and the first N entries, then pages, so the window paints
  in 16 ms.

### S-32 · The Linux WOFF workaround walks `/usr/share/fonts` on every launch

`tauri/src-tauri/src/lib.rs:199-237` (the whole workaround is `:152-237`) —
`woff_on_font_path` recursively walks `/usr/share/fonts`, `/usr/local/share/fonts`,
`~/.local/share/fonts` and `~/.fonts` before the window opens. It does so whenever
`/etc/fonts/fonts.conf` exists and `FONTCONFIG_FILE` is unset. That is thousands of
`stat` calls on a typical desktop, on the critical path to first paint, to work
around a bug that is fixed by the time it is next needed. It rewrites
`~/.config/wander/fonts.conf` only when offending fonts exist (an earlier draft said
"on every run"). It also puts a fontconfig file in the same directory as the folder
setting, which is a confusing place for it. Low severity.

**The fix.** Write a small marker alongside the generated `fonts.conf` recording the
offending paths; if the marker matches, skip the walk. Or scope the walk to
`/usr/share/fonts` only, with `WalkDir::max_depth(4)`. Move the file to
`~/.config/wander/fontconfig/fonts.conf` and note that `std::env::set_var` becomes
`unsafe` in edition 2024 (`Cargo.toml` is on 2021 today — worth a comment).

### S-33 · The Android fingerprint and the load are two full tree walks

`JournalLibrary.load()` (43-55) calls `tree.invalidate()` then `markdownFiles()` then
reads every file. `fingerprint()` (82-96) calls `markdownFiles()` again and stats
every node. `reload()` (157-181) does `library.load() to library.fingerprint()` — two
walks — and `reloadIfChanged()` (188-198) walks once, then calls `reload()` which
walks twice more. So a resume on an unchanged journal costs one walk, and a resume
on a changed one costs three. The most frequent walk was missed by the earlier
draft: `refreshFingerprint()` (`JournalStore.kt:311-319`) walks the whole tree after
**every save**, move and delete.

**The fix.** Have `load()` return the fingerprint alongside the entries — it has
every node in hand — and delete `fingerprint()`'s walk. The Swift and Rust ports
have the same shape (`fingerprint()` at `JournalLibrary.swift:102-119` and
`refreshFingerprint`) but at least run theirs off the main actor.

### S-34 · Unbounded and unsynchronised caches

- `Sources/Wander/Support/Fonts.swift:105` — `platformFonts` keyed by
  `family|size|weight|italic`. It is not unbounded, as an earlier draft said: the
  size is clamped to 13–28 in 0.5 steps, so the cache is small and finite.
  `Fonts.registered` (`:22`), `Fonts.installed` (`:39`) and `DockIcon.current` have
  the same shape, as do the two `HashMap`s in Android's `Fonts.kt`.
- `Sources/Wander/Support/Theme.swift:339` — `ThemeFile.built`, a mutable static
  dictionary.
- `WanderCore/.../JournalLibrary.swift:228` — `JournalIndex.monthTitles`, a mutable
  static dictionary.
- `android/.../core/JournalParser.kt:149` — `monthTitles`, a plain `HashMap`.

All of these are read and written without synchronisation. They happen to be
main-thread-only today, which is exactly the sort of invariant that stops being true
the moment someone moves work off the main actor — and the code already does that
for the fingerprint.

**Under Swift 6 language mode all of the Swift ones are compile errors**, including
the three `Fonts` and `DockIcon` statics above. In Swift 5 mode with the default
minimal checking there are no diagnostics at all. (An earlier draft said "warnings
at best"; also, `SWIFT_VERSION: "5.9"` is not a real language mode; see S-56.) So
they are latent races.

The Kotlin `monthTitles` also caches `Locale.getDefault()` names for the life of the
process, so they go stale after a locale change.

**The fix.**
- Swift: isolate the caches to `@MainActor`, or use `let` + `Sendable` where
  possible.
- **Keep the `monthTitles` cache.** An earlier draft said to drop it, and that was
  wrong: it is two formatter calls per month per rebuild. A ten-year journal has
  about 120 months, which is roughly 10 ms per search keystroke without the cache.
- `ThemeFile.built`: 28 themes, built once, is not a cache worth the race.
- Kotlin: key `monthTitles` on the locale as well, and confine it to Main or use a
  `ConcurrentHashMap`.

### S-35 · Tauri recomputes O(n) aggregates and writes `localStorage` on every render

- `app.js:664` — `state.entries.reduce(...)` for the inbox badge, on every
  `renderMasthead`.
- `app.js:677` and `:908` — `state.entries.findIndex(e => idOf(e) === …)`, and `idOf`
  builds a template string per entry, so each is O(n) *string allocations*. Twice per
  render.
- `app.js:892` — `state.entries.filter(e => e.date.startsWith(prefix)).length`.
- `app.js:918` — `state.entries.reduce((sum, e) => sum + e.words, 0)`.
- `app.js:1048` — `persistSettings()` inside `applySettings()`, which `render()` calls
  on **every save** (every 700 ms) and on every theme change. A synchronous
  `localStorage.setItem` + `JSON.stringify` each time.

`render()` is called from `absorb()` after every save, so all of the above runs on
the debounce timer, not just on user action. `streak()` and `visibleEntries()` are
already cached against `state.revision`; the rest should be too.

**The fix.** One `derived()` function memoised on `state.revision` that returns
`{ inboxCount, number, monthCount, totalWords }`. Move `persistSettings()` out of
`applySettings` and into the individual handlers that change a setting:
`data-column`, `data-step`, `data-paper`, `o-focus`, `o-paper`, the theme-card click
(`:1266-1274`) and the `⌘\` shortcut (`:1342-1347`). `o-folder` changes no setting,
so it needs no call.

### S-36 · The windowed index rebuilds from zero on every render

`renderList` (709-750) clears the list, rebuilds `listItems` from `sections()` and
re-grows to the old scroll position — on every `render()`, i.e. on every save. The
comment at 711-712 says the intent is that "most re-renders are a word count or a
title changing", but `renderList` runs unconditionally from `render()`. The
`listKey` check only preserves the scroll offset; it does not avoid the work.

**The fix.** Return early from `renderList` when `key === listKey` **and** the
selection changed only in a way that is already reflected in the DOM. Selection
changes are the one case that must re-render (the `.on` class), so track a
`selectionKey` and update just the two affected rows — `list.querySelectorAll('.row.on')`
and the new one — rather than all 7 000.

### S-37 · Both stores rebuild `pageCounts` from scratch under an active search

`JournalStore.swift:630-639` — when a query is active the counts are computed by a
*second* full pass over `entries`, in addition to the first pass that built `visible`.
The Android equivalent is `JournalStore.kt:532-541`. Both branches produce the same
numbers when the query is empty; the point of the second is to exclude the filter, so
the honest fix is to compute both counts in the single pass that already iterates
every entry:

```swift
for entry in entries {
    let unfiled = library.isUnfiled(entry)
    allCounts[unfiled ? .inbox : .journal, default: 0] += 1
    if entry.isStarred { allCounts[.starred, default: 0] += 1 }
    if needle.isEmpty || entry.raw.lowercased().contains(needle) {
        // also into visibleCounts
    }
}
```

### S-38 · `library()` in Rust re-locks, re-clones and re-creates the directory on every command — *re-rated P3*

`tauri/src-tauri/src/lib.rs:26-31`:

```rust
fn library(state: &tauri::State<State>) -> Library {
    let base = state.base.lock().unwrap().clone();
    let library = Library::new(base);
    library.ensure();      // create_dir_all on EVERY command
    library
}
```

`lock().unwrap()` panics if a thread ever panicked while holding the lock, taking the
app with it. `ensure()` is a `create_dir_all` syscall per `load`, per `save`, per
`remove`, per `relocate` — it only needs to happen in `set_folder` and at startup.

**Validation: overstated.** Poisoning is practically impossible here. The only
critical sections are a `PathBuf` clone and an assignment (`lib.rs:27`, `:135-137`),
and neither can panic. `ensure()` is one `mkdir -p`, which is noise next to `load`.

**The fix.** `State { base: RwLock<PathBuf> }` with a read lock. (A `OnceCell`, as an
earlier draft suggested, cannot be re-set on `set_folder`.) Call `ensure()` only in
`run()`'s setup and in `set_folder`. Use `.lock().unwrap_or_else(|e| e.into_inner())`
as cheap insurance.

### S-39 · Theme application forces a full style recalculation

`applyTheme()` (984-1017) sets ~30 custom properties and eight `data-` attributes on
`<html>` on every `applySettings()`, i.e. on every save, every type-size step and
every theme change. Changing a custom property on the root invalidates the computed
style of **every element in the document**.

**Validation.** The code is as described: about 28 properties and 7 data attributes
in `applyTheme`, plus 2 more in `applySettings` (`:1040-1041`), on every render. But
the claim of a full style recalculation on every save is unverified. WebKit and
Blink generally skip invalidation when `setProperty` or an attribute receives an
identical value. The certain cost is the JS work. The memoisation below is still
worth doing.

**The fix.** Split it: `applyThemePalette()` (the ~30 palette properties, memoised on
`theme.id` + resolved scheme) and `applyTypeMetrics()` (the six size properties,
memoised on the numeric settings). Call each only when its key changes. This is the
same revision-key pattern `renderProse` already uses at `app.js:296-313`, so the
technique is already in the file.

### S-40 · `Theme` recomputes contrast on every access (Kotlin)

`android/.../ui/Theme.kt:141-156` — `accentInk`, `accentOnBand` and `figureFills` are
`get()` properties (`:141`, `:144`, `:152-160`) that each build a `listOf(...)` of
four `Tone`s and run contrast arithmetic on **every read**, which is about four
luminance computations. They are read in:

- `IndexSheet`: 84, 141, 182, 196
- `EditorScreen`: 93, 127, 131
- `StatsSheet`: 61, and `figureFills` at 112
- `RootScreen`: 199, 243, 247
- most often, `Components.kt:127` and `:143`, on every `QuietButton` and
  `AccentBlock`

`accentOnBand` is never read on Android. The cost per read is small, so this sits at
the low end of P2.

`Theme` is `@Immutable data class`, so these are not cached by Compose; only the
constructor arguments are stable.

**The fix.** `val accentInk: Tone by lazy { … }` (and the other two), or compute
them in `Themes.parse` and store them on the instance. `Tone` is a `data class` of two
`Float`s/`Int`s so `lazy` costs one pointer indirection and nothing else.

### S-41 · The Apple builds do not memoise the tone → colour conversion — *re-rated P3*

**Validation.** This is real, but very cheap. A memo table would cost about as much
as building the `Color` it saves, so the value is low. The named-tone cleanup below
is worth doing for readability, not for speed.

`Tone.color` (`Theme.swift:41-43`) constructs a `Color(.sRGB, red:green:blue:opacity:)`
on every read, and `Tone.platform` (46-52) constructs an `NSColor`/`UIColor`. A
`RootView` body pass reads `theme.paper.color`, `theme.ink.color`,
`theme.muted.color`, `theme.rule.color`, `theme.accent.color` and their `.opacity()`
variants dozens of times, several of them per subview. Each `.opacity()` allocates a
new `Tone` first.

**The fix.** `@MainActor` memo table keyed on `(hex, alpha)`, or — cheaper and
simpler — have `Theme` precompute the handful of derived tones it actually uses
(`accentInk`, `accentOnBand`, `figureFills`, the marker grey) as stored properties,
and reduce the `.opacity()` call sites to a fixed set of named tones on `Theme`
(`markerTone`, `faintTone`, `hoverTone`). The patterns are stable; only the
construction is repeated.

---

## P3 — Dead code, duplication and hygiene

### S-42 · `statsTrace` is parsed by Swift and used by nothing

`Resources/themes.json` declares it for all fourteen themes; one, Seismograph, sets
it `true`. Swift parses it, across four lines of `Theme.swift`: the field (`:156`),
the default (`:270`), the Codable struct (`:317`) and the assignment (`:381`).
Kotlin, Rust and JS do not parse it at all. No build reads it. (An earlier draft's
title and body contradicted each other on this point.)

`docs/from-nook.md` says Seismograph "draws the month as a trace down it". No build
does that.

**The fix.** Either implement it (a trace/grid background behind the stats figures is
an obvious reading, given "Seismograph") or delete it from `themes.json` and stop
mentioning it. Deleting is 14 lines of JSON and one Swift field.

### S-43 · Dead API surface in the shared core

- `JournalIndex.matches(_:query:)` — `JournalLibrary.swift:258-261`,
  `JournalParser.kt:174-177`. Never called; the three UI layers each do their own
  filtering.
- `JournalParser.isHeaderLine(_:)` — `JournalParser.swift:37`,
  `JournalParser.kt:27`. Never called.
- `Entry.header` (`Entry.swift:65`, `Entry.kt:32`) — no callers in Swift or Kotlin.
- `Fold.halfOpen` (`Fold.kt:35, 73`) — set, never read. Either use it (book posture
  is currently inferred from `separating && !vertical`, which is a weaker signal) or
  delete it.
- Android, found in validation:
  - `liveCounts()` (`JournalStore.kt:582-592`, never called)
  - `forgetFolder` (`JournalStore.kt:150`)
  - `Theme.accentOnBand`
  - the Theme fields `measure`, `centred`, `figureBlocks`, `pageCard`, `rowColours`
    and `ornament`, all parsed and unused on Android (see S-82)
  - the unused dependencies `documentfile` and `material-icons-core`
- `SchemeDot` is defined **twice** with different memberwise signatures:
  `ThemesSheet.swift:240` (`hint:theme:host:`, and `theme` is unused) and
  `ThemeSwiper.swift:338` (`hint:host:`). Both are `private` at file scope, so this
  is duplication, not a conflict.

Moved out of this item, since none is dead code:
- The unused `draft` passed to `StatsSheet` is part of S-15.
- The `months` precondition is in Appendix A.
- The Tauri `core:default` capability is below, under S-43a.

**The fix.** Delete the dead members; collapse `SchemeDot` into
`Sources/Wander/Views/Components.swift` (where `SmallCaps`, `Rule`, `AccentBlock` and
the rest of the vocabulary live) and have the iOS sheet use it; add a precondition
assertion to `months`.

### S-43a · The Tauri capability is broad, and the real write surface is ungated

`tauri/src-tauri/capabilities/default.json` grants `core:default`, `dialog:allow-open`
and four window permissions. `core:default` is mostly read-only getters plus event
emit and listen, so narrowing it gains little. If it is narrowed, S-04 needs
`core:event:allow-listen` listed explicitly.

The real exposure is the app's own commands. In Tauri v2 with no app manifest they
are allowed by default, and a capability does not gate them. The commands also trust
any path the webview sends them; see S-71, which matters more than narrowing
`core:default`.

### S-44 · `build.sh`'s ad-hoc fallback is unreachable, and `TEAM` is never used

**`build.sh:29-41`:**

```bash
set -euo pipefail
…
IDENTITY=${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -m1 "Apple Development" | sed 's/.*"\(.*\)"/\1/')}
if [ -n "$IDENTITY" ]; then … else … ad-hoc … fi
```

**The bug.** `grep -m1` exits 1 when there is no match. Under `set -e -o pipefail`,
a failing command substitution in an assignment aborts the script. Verified with
bash 5.2. `build.sh` is `#!/bin/bash`, and the earlier draft's `sh -c` test was
invalid: dash rejects `-o pipefail`, which is where its exit 2 came from.

```
$ bash -c 'set -euo pipefail; X=${Y:-$(echo hi | grep -m1 nomatch | sed s/a/b/)}; echo survived'
exit=1    (nothing printed)
$ bash -c 'set -eu;          X=${Y:-$(echo hi | grep -m1 nomatch | sed s/a/b/)}; echo survived'
survived  (sed is last in the pipe and exits 0)
```

So it is the `pipefail` that makes the ad-hoc fallback unreachable.

So on a machine with no Apple Development certificate — the exact case the `else`
branch and `README.md:242-245` describe — **`./build.sh` exits non-zero and never
reaches the ad-hoc signing.** The fallback is dead code, and the README documents
behaviour that does not happen.

`TEAM` (line 29) is used only in the `echo` at `:37`. It is never passed to
anything: `codesign` takes the identity, and without a provisioning profile there is
no team to bind.

**The fix.**

```bash
IDENTITY=${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 "Apple Development" | sed 's/.*"\(.*\)"/\1/' || true)}
```

and delete `TEAM`, or use it to select a provisioning profile. Then verify both
branches on a machine with and without a certificate.

### S-45 · Generated Info.plists are committed and will fight `xcodegen`

`Resources/Info-iOS.plist` and `Resources/Info-macOS.plist` are written by
`xcodegen generate` from the `info:` blocks in `project.yml:46-66` and `111-123` —
the comment at line 44 says so explicitly — and both are tracked. Every generate
dirties the working tree, and the committed copy is a second source of truth for
values that live in `project.yml`.

Worse, there are now **three** macOS Info.plists: `Resources/Info.plist` (hand-written,
used by `build.sh:15`), `Resources/Info-macOS.plist` (xcodegen, used by the Xcode
target), and the xcodegen properties block. They already differ: `Info.plist` has
`NSPrincipalClass`, `Info-macOS.plist` does not.

**The fix.** Add `Resources/Info-iOS.plist` and `Resources/Info-macOS.plist` to
`.gitignore`. The "generated from project.yml" comment at `project.yml:44-45` is
correct where it is; `.gitignore` just needs the two entries. Then either
delete `Resources/Info.plist` and have `build.sh` copy `Info-macOS.plist`, or keep it
and add a comment on the other two that it is the SwiftPM path. One path, one file.

### S-46 · `SlidingColumn` can unmount itself while it is open

`Sources/Wander/Views/Components.swift:267-273`:

```swift
.onChange(of: open) { _, isOpen in
    guard !isOpen else { return mounted = true }
    Task {
        try? await Task.sleep(for: Motion.columnDuration)
        if !open { mounted = false }      // reads the *captured* open, which is false
    }
}
```

`open` inside the `Task` is the value captured when `onChange` fired — always `false`
in this branch. The guard therefore never checks the *current* value. Sequence:
close (task A scheduled) → open (`mounted = true`) → task A fires 220 ms later →
`mounted = false` while the column is open. The column is open, animating in, and
rendering nothing. Nothing re-arms it until the next toggle.

**The fix.** Use the `isOpen`/`open` value from the current render, not the captured
one:

```swift
.onChange(of: open) { _, isOpen in
    if isOpen { mounted = true; return }
    let token = unmountToken
    Task {
        try? await Task.sleep(for: Motion.columnDuration)
        if unmountToken == token { mounted = false }
    }
}
```
with `@State private var unmountToken = 0` incremented on every open. This works
because `@State` reads go through shared storage, not the captured struct.
Alternatively, store the `Task` in `@State` and cancel it on reopen. (An earlier
draft justified the token by a retain cycle. There is none, because `self` is a
struct.)

### S-47 · `Theme.==` ignores almost every field — *hygiene, no bug today*

**Validation.** Themes are static, and all fourteen have different light and dark
paper and ink; this was checked against `themes.json`. So `id + paper + ink`
identifies every resolved theme uniquely. The collision scenario described below
does not occur today. It becomes a bug only when a theme is added whose two
appearances share both paper and ink.

`Sources/Wander/Support/Theme.swift:167-169`:

```swift
static func == (lhs: Theme, rhs: Theme) -> Bool {
    lhs.id == rhs.id && lhs.paper.hex == rhs.paper.hex && lhs.ink.hex == rhs.ink.hex
}
```

`Theme` is `Equatable` and is embedded in `ProseStyle`, which `updateNSView` compares
via `style.key` (which *does* include `theme.id` — so the editor is safe). But
SwiftUI's own view diffing uses `Equatable` on some paths, and any two themes that
share an id, a paper and an ink compare equal. A `dark`/`light` pair within one theme
differ only in palette, and if a theme's light and dark halves share `paper` and
`ink` (some do — the README says "Every theme below carries both, so the setting
stays a switch"), the two compare **equal** and SwiftUI can skip an update.

The comment at 336-338 explains the cache that makes `resolve` cheap; the `==` looks
like an over-reach from the same optimisation. `Theme` has ~40 fields; comparing them
all is a handful of integer compares.

**The fix.** Delete the custom `==` and use the synthesised one. If the cost shows
up in a profile, compare `id` plus a `paletteHash: UInt32` computed once at decode
time from all twelve colour values, rather than three fields.

### S-48 · `escapeHtml` does not escape quotes

`tauri/src/app.js:205-206` handles `&`, `<`, `>` only. Every current call site puts
the result in element content, not in an attribute, so it is not exploitable today —
but `rowNode` builds `innerHTML` from a template, and the next person to add a
`title="…"` attribute will have an injection. There are also unescaped `innerHTML`
interpolations: `sectionNode` at `:787`, and the theme name and note in
`renderThemes` at `:1262-1263`. Their data is generated or comes from `themes.json`,
so it is trusted, but the pattern is the same. Fix it while changing `inlineStyle`
(S-07), and add `"` and `'` plus a comment that attributes are never built from
escaped text.

### S-49 · Duplicated prompts, parsers and fonts need one home

- `Prompts.all` is a 12-entry table in **three** places: `StatsPanel.swift:189-203`,
  `StatsSheet.kt:155-169` and `app.js:106-119`. Each port also has its own
  day-of-year index formula: `ordinality(of: .day, in: .year)`,
  `LocalDate.now().dayOfYear` and a JS `dayOfYear % count`.
  - They **already disagree**: `app.js` uses a curly ’ in two prompts ("Tomorrow’s",
    "day’s") where Swift and Kotlin use a straight '. See S-79.
  - Move the table to a generated file next to `themes.json`, the way the themes are.
- The **parser is written three times**, in `JournalParser.swift` (122 lines),
  `journal.rs` (the parser portion ends at line 173 of 391) and `JournalParser.kt`
  (ends at 108 of 178). They are kept in sync by hand. The README calls this
  deliberate, and it is the right call (no shared runtime across three platforms),
  but it means the *contract* needs to be executable, not documented. See S-67.
- The fonts:
  - `Resources/Fonts` has 60 TTF files (8.0 MB).
  - `android/app/src/main/assets/fonts` holds the same 60 TTFs, byte-identical,
    plus `fonts.json`.
  - `tauri/src/fonts` has 2.1 MB of woff2 (56 files), three of which are referenced nowhere
    (S-78).
  - Git stores identical files as one blob, so the duplication costs checkout size
    (8 MB of 32 MB tracked), **not** repository size. An earlier draft's "halve the
    repository" was wrong.
  - Do not simply point Android's `sourceSets` at `../Resources/Fonts`. That puts the
    fonts at the assets root, but `Fonts.kt` opens `fonts/…`, and `fonts.json` exists
    only on the Android side. Generate the copy with a Gradle `Sync` task into a
    generated assets directory, the same fix as S-24.
- `design/` holds 17 tracked files (18 on disk with the untracked
  `theme-demo.html`). Two of them are 11 009-line HTML files
  (`wander-shortlist.html`, 2.66 MB; `wander-look-directions.html`, 2.57 MB), which
  make up almost all of `design/`'s 5.2 MB. Move them out or drop them.

### S-50 · Smaller cleanups, in one list

| Where | What |
|---|---|
| `RootView.swift:105,107` | `// MARK: Masthead` appears twice, 2 lines apart |
| `Appearance.swift:36-39` + `DockIcon.swift:33-35` | `Notification.Name.openThemes` is defined in two files under complementary `#if`s; move it to one |
| `StatsPanel.swift:137-155` | the `figures` branch and the `else` branch are two near-identical `VStack`s. (An earlier draft said the `figures` branch drops This month and Streak; it does not, because the figure tiles at `:39-40` already show them.) |
| `StatsPanel.swift:60-62` | `figureIndex` does `firstIndex(of:)` over a fresh array literal per figure; pass the index. Trivial. |
| `StatsSheet.kt:103` | `Column(Modifier.padding(bottom = 16.dp)) {}` is an empty `Spacer` |
| `index.html:116` | `data-toggle="focus"` on `#o-focus` is never read. (An earlier draft said `app.js:116`, which is a prompt line.) |
| `app.js:1367` | `undecorated` never changes within a process, but it is decided at runtime by `WANDER_DECORATIONS` (`lib.rs:147-159`), so it cannot be a build-time constant. An init-script `data-` attribute on the root would do. The window is also created with `"decorations": true` (conf `:15`) and stripped in `setup` (`lib.rs:260-266`), which can flash; a per-platform config overlay would avoid that. |
| `android/app/src/main/AndroidManifest.xml:9` | `allowBackup="true"` on a journal app. Google backup would upload the app's `SharedPreferences`, including the remembered `content://` tree URI string. Persisted URI grants do **not** survive a restore, and `rememberedFolder()` checks `persistedUriPermissions`, so only the URI string leaks, not the grant. Low severity, but make it a deliberate decision with `dataExtractionRules`. |
| `Wander-macOS.entitlements` | an empty dict, while the code carefully threads security-scoped bookmarks through `adopt`/`resolveRememberedFolder`. Without App Sandbox the scoped-bookmark path is inert (`startAccessingSecurityScopedResource` returns false and the code handles that). **Keep the bookmark machinery either way**: iOS `fileImporter` needs security scope, and a bookmark follows a moved folder even without the sandbox. Whether to enable the sandbox (with `com.apple.security.files.user-selected.read-write`) should be a decision recorded in the README, not an accident. |

Rows dropped from this list by the validation pass (see Appendix A): the
`SidebarView.swift:42-47` "dead modifier", the `EditorView.swift:85-86` `onChange`
deprecation, the `StatsSheet.kt:88, 91` redundant check, the `frontendDist`
self-containment claim, and TextKit 1 being "deprecated on macOS 15".

---

## P4 — Tests, CI and tooling

### S-51 · The macOS test target is empty

`Tests/WanderCoreTests/CoreTests.swift` is **one line**: `import XCTest`. The target
is wired up (`Package.swift:21-25`) so `swift test` succeeds and reports green while
testing nothing. `docs/from-nook.md` already identifies this and points at Nook's
241-line `ParserChecks.swift` as the model.

This is the highest-leverage item in P4: the format is a contract between five
programs, and the contract has no executable specification on two of the three ports
that ship it.

**The fix.** Port `ParserTest.kt`'s 14 cases to Swift first (they are already the
right cases), then add the ones the Kotlin suite is missing — the byte-identity ones
from S-01, S-20 and S-21 specifically:

- a non-UTF-8 input is refused, not silently rewritten
- CRLF input normalises to LF on the next write
- `Counts.words` on NBSP, emoji, and combining marks matches the fixture
- `parseEntries` ∘ `renderEntries` is idempotent on every fixture

Once these exist, they belong in the shared fixture (S-67), not only in Swift.

### S-52 · The Rust and JavaScript ports have no tests at all

`tauri/src-tauri/` has no `#[cfg(test)]` module; `tauri/src/app.js` has no test file
and no test runner. The two ports with the least test coverage are also the two with
the most platform-specific hazards (byte slicing in S-02, markup generation in
S-07, calendar arithmetic in S-08).

**The fix.**
- Rust: `#[cfg(test)] mod tests` in `journal.rs` for the parser and `day_file`,
  plus `tests/conformance.rs` for the shared fixture. `cargo test` is wired up by
  convention, but an earlier draft's "nothing else is needed" was wrong: **`cargo
  test` fails today**. The indented block in the `journal.rs:7-8` module doc is
  compiled as a doctest ("expected identifier, found `<`"). Fence it as ```` ```text ````
  first (S-74).
- JS: the functions that need testing are pure and already are
  (`inlineStyle`, `renderLine`, `words`, `parseStamp`, `stampOf`, `dayOf`, `countStreak`,
  `visibleEntries`, `readableOn`, `figureFills`, `escapeHtml`, `renderCalendar`'s
  date maths). `node --test` (built in since Node 18) needs no dependencies:
  extract the pure ones into `tauri/src/format.js` as ES modules and test them
  directly. That also makes the file smaller and the `app.js` globals stop leaking.

### S-53 · There is no CI

No `.github`, and no GitLab, Circle, Travis or Buildkite file in `git ls-files`. Four platforms, three hand-synced ports, a
byte-compatibility contract with a fifth program (`jnl`), and nothing that checks
any of it. Every item in this document that says "the three copies are currently
identical" is a manual observation that will not survive a quiet week.

**The fix.** One workflow, cheapest-first:

```yaml
jobs:
  rust:     cargo fmt --check && cargo clippy -- -D warnings && cargo test
  js:       node --test
  android:  ./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease
  parity:   sha256sum Resources/themes.json tauri/src/themes.json \
            android/app/src/main/assets/themes.json | awk '{print $1}' | sort -u | wc -l
            # must print 1
  macos:    swift build && swift test          # runners: macos-14
  ios:      xcodegen generate && xcodebuild -scheme 'wander (iOS)' \
            -destination 'generic/platform=iOS' build
```

The `parity` job is five lines and catches the single most likely silent break.

### S-54 · No linters or formatters for any of the four

No `.swiftlint.yml`, no `.swiftformat`, no `rustfmt.toml`/`clippy.toml` (Rust's are
built in and unused), no `ktlint`/`detekt`, no `eslint`/`prettier`, no `.editorconfig`.

The comments throughout are in a consistent house voice, which suggests these were
once enforced. Rust is the cheapest win: `rustfmt.toml` with
`max_width = 96` (roughly the width the files are written to; `journal.rs` has lines
up to 101 characters and `lib.rs` up to 99) and a
`clippy.toml` allowing the few pedantic lints the code deliberately trips.

### S-55 · The release builds are unverified

- Android `buildTypes.release` has `isMinifyEnabled = true` and
  `isShrinkResources = true`, with a `proguard-rules.pro` containing one
  `-dontwarn`. R8 on a Compose app with a JSON-parsed asset manifest and
  `DocumentsContract` reflection-free code will probably be fine, but "probably" is
  not a shipping posture, and nothing in the repo builds it.
- Android also has no release `signingConfig`.
- The Tauri release profile (`Cargo.toml:25-28`) is
  `lto = true, strip = true, opt-level = 3`, and `Cargo.lock` is committed, which is
  correct for an app.
  - The absence of `panic = "abort"` is an observation, not a defect.
  - `strip = true` removes the symbols needed for crash backtraces. That is a
    trade-off worth stating.

**The fix.** Add `assembleRelease` to CI (S-53). If R8 breaks something, the fix is
keep rules; find out now rather than at release.

### S-56 · Nothing pins or verifies the toolchain

- Swift:
  - `Package.swift` and `WanderCore/Package.swift` are `swift-tools-version:5.9`.
    That is a minimum, not a pin.
  - `project.yml:25` sets `SWIFT_VERSION: "5.9"`, but `SWIFT_VERSION` is a *language
    mode* (4, 4.2, 5 or 6), and "5.9" is not one of them.
  - There is no `.swift-version` file.
- Rust:
  - `Cargo.toml:7` has `rust-version = "1.77"`, and **that is false**. The locked
    dependencies declare MSRV 1.88: `time` 0.3.55, `darling` 0.24.1, `plist` 1.10.1
    and `serde_with_macros` 3.23.0. (Local rustc is 1.97.1.)
  - There is no `rust-toolchain.toml`.
- Android:
  - `android/gradle/wrapper/gradle-wrapper.properties` pins Gradle 8.9, and
    `android/build.gradle.kts` pins AGP 8.7.3 and Kotlin 2.0.21.
  - Nothing *verifies* the toolchain: there is no `distributionSha256Sum` and no
    `jvmToolchain`.
  - `settings.gradle.kts:4-7` applies content filters only to `pluginManagement`'s
    `google()`. The dependency repositories are unfiltered.
- The team id:
  - `project.yml:19` pins `DEVELOPMENT_TEAM: 52W73J6V95` at the **project** level,
    so every target inherits it.
  - `build.sh:29` has `TEAM=${DEVELOPMENT_TEAM:-52W73J6V95}`, the same default
    again.
  - So a fork must edit both files.

**The fix.**
- Bump `rust-version` to at least 1.88, and add `rust-toolchain.toml` and
  `.swift-version`.
- Set `SWIFT_VERSION` to `"5"`.
- Add `distributionSha256Sum`.
- Move the team id to a single place. `build.sh` already reads `DEVELOPMENT_TEAM`
  from the environment, which is the right instinct; make `project.yml` read an
  xcconfig, or document the edit.

### S-57 · The theme icons are generated by hand and can go stale silently

`DockIcon` (`DockIcon.swift:22-30`) looks up `Icons/<theme>-<light|dark>.png` and
falls back to `AppIcon-light/dark`. `Resources/Icons` holds 28 PNGs (644 KB) committed
by hand, and `tools/make_icon.swift` generates them. The build does not run the
generator, so a `themes.json` change can leave the icons stale — and the fallback
means a *missing* icon is silent.

`project.yml:80-93` hard-codes the 13 alternate icon names, which is one more place
that can drift from `themes.json`. (An earlier draft's title said only `ThemesSheet`
and the generator read `themes.json` on Apple. In fact `ThemeFile` in `Theme.swift`
reads it for the whole app.)

**The fix.** Do **not** run the generator from `build.sh`. It rewrites tracked files
on every run: the xcassets, `tauri/src-tauri/icons` and `AppIcon-*.png`. Instead:

- add a CI check that regenerates the icons and fails on a diff
- log a warning in the fallback path, so a missing icon is not silent

### S-67 · There is no shared conformance fixture across the ports

S-20, S-21, S-49 and S-51 all refer to this. The format is implemented three times:
Swift, Kotlin and Rust, with JS counting words on top. It is shared with `jnl` and
Nook. Yet the only executable specification is `ParserTest.kt`'s 14 cases, which run
on one port.

**The fix.** Add a `fixtures/` directory at the repository root holding input files
and the expected outputs:

- parsed entries (ts, suffix, body, starred, tags)
- the re-rendered bytes
- the word and character counts

Cover at least:

- the preamble
- a trailing newline
- CRLF (S-21)
- a BOM (S-76)
- NBSP, emoji and combining marks (S-20)
- a starred bold title
- `***x***` (S-07)
- a same-second collision
- a file that is not UTF-8 (S-01), which must be *refused*

Each port loads the directory in its own test runner:

- `swift test`
- `./gradlew testDebugUnitTest`
- `cargo test` (`tests/conformance.rs`)
- `node --test`

CI (S-53) runs all four.

---

## P5 — Accessibility

### S-58 · Focus rings are removed and never replaced (Tauri)

`tauri/src/styles.css:87` — `input { … outline: none; }`, and `.prose { outline:
none }` at `:323`. There is not one `:focus-visible` rule in the file. So the find
box, the time field and the editor have no visible keyboard focus, and
`outline: none` removes the UA default outright. (An earlier draft said every
*button* has no visible focus too. That is wrong: buttons reset only border and
background, so they keep the UA focus ring.) For a keyboard-driven app (thirteen shortcuts, an
undecorated window, a custom calendar) that is a real barrier.

**The fix.** Add one rule and stop removing outlines:

```css
:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
input:focus-visible { outline: 2px solid var(--accent); }
```

### S-59 · The sheets are not dialogs (Tauri)

`#scrim`, `#themes` and `#confirm` (`index.html:138-194`) are `div`s with
`position: fixed`. They have no `role="dialog"`, no `aria-modal`, no
`aria-labelledby`, no focus trap, and no focus restore — pressing Tab from the
calendar walks out of the sheet and into the page behind it, which is still in the
tab order and still focusable. Escape works (there is a handler at `app.js:1326-1328`),
which is the only thing making them usable by keyboard. Two related problems:
Escape does not clear `pendingDelete`, and the global ⌘ shortcuts (⌘N, ⌘J, ⌘D) stay
live while a sheet is open.

**The fix.** `role="dialog" aria-modal="true"` on each `.scrim`, an `aria-labelledby`
pointing at the `<h2>`, `inert` on `<main>` while a sheet is open, focus the first
control on open, restore focus to the opener on close, and a `keydown` trap for Tab.
The macOS and iOS builds get this from SwiftUI's `.sheet`; the Android build gets it
from `ModalBottomSheet`. Only the Tauri build has to do it by hand.

### S-60 · Icon-only and symbol controls have no accessible names

- `android/.../ui/RootScreen.kt:245-249` — `SmallCaps("B")`, `SmallCaps("I")` and
  `SmallCaps("New")` are clickable `Text`s. `Modifier.clickable` does expose an
  action ("double-tap to activate"), but there is no `Role.Button`, and the names
  "B" and "I" are meaningless.
  - The same applies to "⋯" at `:252`, "Index" at `:237`, and the Stepper "−" and
    "+" at `OptionsSheet.kt:94` and `:100`.
  - The touch targets are about 24 dp, under the 48 dp minimum.
  - There is no `semantics` or `contentDescription` anywhere in the app.
- `Sources/Wander/Views/OptionsPanel.swift:131-133` — the `−` and `+` in `Stepper`
  have no `.accessibilityLabel`, so VoiceOver reads "minus" and "plus" in a row of
  three with no context.
- `tauri/src/index.html:25-27` — the window controls are `&#8211; &#9723; &#10005;`
  with only a `title`. `title` is a weak name; add `aria-label`.
- `tauri/src/index.html:66` — `#prose` is a `contenteditable` with no
  `role="textbox"`/`aria-multiline` and no label.
- `tauri/src/index.html` — the `−`/`+` steppers (`:111`, `:114`, `:118`, `:158`) and
  the calendar's ‹ › buttons (`:150-151`) have no names either.

**The fix.** `contentDescription` in Compose, `.accessibilityLabel` in SwiftUI,
`aria-label` in HTML, on every one.

### S-61 · The Apple and Android builds have no accessibility audit either

Neither has been checked. Given the number of "small caps over a numeral" figures
(whose meaning is carried entirely by proximity to a label) and hairline rules (which
carry the structure of a screen reader will never see), this needs a pass:

- `Sources/Wander/Views/StatsPanel.swift:56-103` — a `figure` is a label and a value
  with no combined element; group them with `.accessibilityElement(children: .combine)`.
- `Sources/Wander/Views/SidebarView.swift:134-203` — each row is a `Button` whose
  label is the title, so the date, word count and draft state are announced only if
  read in order. Add an explicit `.accessibilityLabel` and `.accessibilityValue`.
- Every theme's contrast pair should be checked: `Theme.legible` and `Tone.contrast`
  already exist for that, and `accentInk`/`accentOnBand` are the right mechanism —
  but nothing asserts a minimum ratio anywhere, and `legible`'s default `minimum:
  3.2` (`Theme.swift:75`) is below the WCAG AA 4.5:1 for body text.
- There are no accessibility modifiers anywhere in `Sources/`.
- Before any WCAG floor can be asserted, see S-81: `Tone.luminance` and `contrast`
  do not compute WCAG ratios.

### S-62 · RTL is claimed but not designed for

`android/app/src/main/AndroidManifest.xml` sets `android:supportsRtl="true"`. Compose's
`Row`/`Column` and `TextAlign.Start` do respect layout direction by default, so the
Android build is probably fine, and `Gravity.START` is fine too. The Swift build
uses `HStack(alignment: .firstTextBaseline, spacing: 13)` with no `layoutDirection`
handling.

`styles.css` uses physical rather than logical properties:

- `text-align: left` on `.row` (`:258`) and `.theme-card` (`:491`). An earlier draft
  said `.theme-caption`.
- `.row`'s `border-left` (`:261`, `:264`)
- `.quote`'s `padding-left` (`:347`)
- the rail's `padding-left` (`:229`)
- the index's `border-right` (`:228`)

The `padding: 22px 34px 8px` the earlier draft cited is left/right symmetric and
harmless. The Tauri build does not claim RTL, so this is low priority there.

**The fix.** Either drop `supportsRtl` from the manifest, or convert the physical
properties to logical ones (`padding-inline`, `margin-inline-start`, `text-align:
start`) in the CSS and add `LayoutDirection` handling where the Swift layout depends
on reading order. The macOS/iOS builds are English-only today, so this is cheap now
and expensive later.

---

## P6 — Documentation accuracy

### S-63 · The keys table lists shortcuts the Tauri build does not have

`README.md:267-279` lists ⌘N, ⌘1/2/3, ⌘J, ⌘D/⌘⇧D, ⌘F, ⌘\ ⌘⇧\ ⌘⌥\, `⌘⇧F`
(focus) and `⌘⇧T` (typewriter), ⌘B/⌘I (wrapping in `**` and `_`), and `⌘⌥↑`/`⌘⌥↓`
(prev/next entry).

The global map in `tauri/src/app.js:1332-1348` handles `n s f d j 1 2 3 t \`. The
prose handler at `:398-413` adds ⌘Z, ⌘B and ⌘I. (An earlier draft said "and nothing
else".) So the Tauri build has no focus-mode shortcut, no typewriter scrolling at
all, and no prev/next entry. Its Options panel adds a **Measure** stepper that the
Mac build does not have.

Validation found it is worse than missing:

- Keys are lower-cased and Shift is ignored. So **⌘⇧F runs Find** and **⌘⇧T opens
  Themes**, rather than doing nothing.
- **⌘⇧\ never toggles Stats**: with Shift held, `event.key` is `|`, not `\`.
- ⌘⌥\ on macOS produces `«`, so it is likely dead too.
- Tauri's ⌘I wraps in `*` (`app.js:413`), while the README and `ProseEditor.swift:225`
  use `_`.

The README table also *omits* macOS shortcuts that exist: ⌘S, ⌘R, ⌘⇧R, ⌘⇧C, ⌘⌫, ⌘+
and ⌘−, and ⌘T (`WanderApp.swift:45-126`).

**The fix.**

1. Match on `event.code` or check `event.shiftKey`, so that Shift-variants are
   distinct and ⌘⇧\ works.
2. Add the three missing shortcuts to `app.js`. Focus is already a setting at
   `settings.focus`, and prev/next can be built on `successorId`; there is no `step`
   helper, as an earlier draft suggested. Typewriter needs a real implementation.
3. Make ⌘I wrap in `_`.
4. Complete the README table.

Or mark the table as macOS-only and give the Tauri build its own. The first is better: typewriter scrolling is ~15 lines of
`scroll-margin`-style logic on the `.ln.live` element, and the README promises
"drawn to match".

### S-64 · `README.md:240` sends you to `cargo run` for macOS

Two rows of the build table mention macOS, and they build **different apps**.
`build.sh` produces the SwiftUI `build/wander.app`, with resources copied in and a
signature. `cargo run` in `tauri/` runs the Tauri build. (An earlier draft said
"three rows, same binary".) The problem is the ambiguity: say which macOS app a
reader should build, and that the Tauri one is there for parity testing.

### S-65 · `docs/from-nook.md` is a shopping list with no decisions recorded

It is a good document. It identifies the empty Swift test file, the missing shared
tests and the parser cases to port, and it does record reasoned rejections under
"Probably not" (media, saved searches, PDF export, split tags). But it calls itself
"a shopping list, not a plan" (`:10`), and it has no dates and no "Decided" section.

It also has stale bits:

- It says `JournalLibrary.matches`, where the code has `JournalIndex.matches`.
- It says "all three builds"; there are four.
- It describes a Seismograph trace that no build draws (S-42).

Add a "Decided" section with a date, so the next reader knows which items were
considered and rejected, and which are still open.

### S-66 · The README does not say what happens when the disk is full, the folder moves, or the grant lapses

These are the three failure modes a reader will actually hit. The README has no
section on any of them, and only the first is handled well in code:

- **Disk full.** `persist` throws, and `saveState` shows "Not saved — <error>"
  (`EditorView.swift:173`). The reader's text is still in the editor. Good, and
  undocumented.
- **Folder moved or renamed.**
  - `resolveRememberedFolder` re-mints a stale bookmark (`JournalStore.swift:562-590`)
    and returns nil if that fails.
  - `init` (`:141-150`) then silently keeps `resolveBase(nil)`: `$JNL_DIR`, or else
    `~/Documents/Wander`. The reader is looking at an empty journal with no
    explanation. **This should say so on screen.**
  - A bookmark also follows a folder moved to the Trash, and keeps writing there.
  - See also S-77.
- **Android grant revoked** (SD card pulled, folder deleted). An earlier draft called
  this handled, and it is **not**.
  - `JournalStore.kt:133-143` would set `folderChosen = false` with "That folder
    can't be opened any more." But it is gated on `SafTree.isReachable()`
    (`SafTree.kt:182`), which wraps `children()`, and `children()` swallows every
    exception with `runCatching` (`:63`). So `isReachable` always returns true, and
    the reader gets a silently empty journal, the same failure as macOS. See S-75.
  - A grant lost *across launches* is caught by `rememberedFolder()` and sends the
    reader to the folder screen, but with no message.

**The fix.** A short "If something goes wrong" section, and — more usefully — surface
the folder-moved and grant-lost cases in the app. `adopt` and `resolveRememberedFolder` both know
when the remembered folder is unreachable; say "the folder Wander was using can't be
opened" rather than showing an empty journal.

---

## New findings from the validation pass

Found while re-checking S-01 to S-66. Severities use the same scale.

### S-68 · Android: filing, retiming or starring an entry can lose its last edits — **P0**

**Where** — `android/.../store/JournalStore.kt:263` (`flush`), `:375-409`
(`reschedule`, `file`, `unfile`), `:337-368` (`move`), `:477-480`
(`toggleStarOnSelection`), `:495-500` (`copyMarkdown`).

**The bug.** `flush()` is not a suspend function. It hands the write to
`viewModelScope.launch { … }` and returns at once. `file`, `unfile` and `reschedule`
each call `flush()` and then immediately read `_state.value.entries`, but
`replaceInMemory` has not run yet, so they read the entry as it was *before* the
pending edits. They pass that stale entry to `move()`, whose IO runs **concurrently**
with the flush's `persist`. Depending on the interleaving:

- `move` persists the old body into the day file and then resets `draft.body` to it
  (`:353-354`). The last edits, up to the 700 ms debounce plus whatever was typed,
  are lost from the editor and from disk.
- Or the flush's `persist` lands in `inbox.md` after `move` has removed the entry,
  and the entry exists twice.

`toggleStarOnSelection` and `copyMarkdown` read the same stale entry, so the star
toggle can write an old body, and the copy copies one.

**The fix.** Split `flush` into a `suspend fun flushAndWait()`, which performs the
write inline and returns once `replaceInMemory` has run, and a fire-and-forget
wrapper for the debounce and lifecycle paths. `file`, `unfile`, `reschedule`,
`toggleStarOnSelection` and `copyMarkdown` call the suspending one first. Pair this
with S-14: once `file`/`unfile` are `suspend`, the page decision can follow the move.

### S-69 · Android: an external edit to the open entry is shown stale and then overwritten — **P1**

**Where** — `JournalStore.kt:188-198` (`reloadIfChanged` → `reload`), `:206`
(`select(keep)` returns early).

**The bug.** On resume, a changed folder is reloaded, but `draftEntry` and the draft
for the *selected* entry are never refreshed. `select(keep)` returns early when the
id is unchanged. So an edit made to the open entry by `jnl`, or arriving by sync, is
not shown. On the reader's next keystroke, the save rewrites the entry from the stale
draft and silently discards the external edit.

**The fix.** After a reload, if the selected entry's `raw` differs from `draftEntry.raw`
and the draft is not dirty, reload the draft from disk. If the draft *is* dirty, keep
it, but say so in the save line: "Changed elsewhere — your version will be saved".

### S-70 · Tauri: the theme ornaments from `21614f2` are invisible — **P1**

**Where** — `tauri/src/styles.css:583`,
`.ornament { position: absolute; inset: 0; z-index: -1; … }`, together with `.editor`
(`:284-291`) and `.theme-preview` (`:499-509`).

**The bug.** `z-index: -1` places the ornament beneath the nearest ancestor that
forms a stacking context. Neither `.editor` nor `.theme-preview` forms one, so the
ornament paints underneath their opaque backgrounds. Wash, letterbox, wedge, ghost
and confetti never show, on the page or in the theme cards. Only the rail
(`z-index: 0`, `:662`) is visible. The comment at `:581` states the intent, which is
correct, but it relies on a stacking context that is not there. Verified in headless
Chromium.

**The fix.** Add `isolation: isolate` to `.editor` and `.theme-preview`. That was
confirmed to make the wash appear.

### S-71 · Tauri: the commands trust any path the webview sends — **P3 (security hardening)**

**Where** — `tauri/src-tauri/src/lib.rs:63` (`save`), `:76` (`remove`), `:92`
(`relocate`).

**The bug.** Each command takes a `source` path from the frontend, then reads,
rewrites or deletes that file. Nothing checks that it lies under `base`. `remove`
deletes a file whose re-render is empty. The CSP limits the exposure to a compromised
frontend, but the check is cheap. This matters more than narrowing `core:default`
(S-43a).

**The fix.** Canonicalise `source` and require `source.starts_with(base)` in every
command, and validate `ts` (S-02) at the same entry points.

### S-72 · Tauri: saves are not ordered — **P2**

**Where** — `tauri/src/app.js`, `save()` and the 700 ms debounce.

**The bug.** If one `invoke('save')` takes longer than 700 ms, the next debounced
save starts while the first is still in flight, and nothing orders them. A slow
first write can land after a faster second one.

**The fix.** Keep a single in-flight promise. Chain each save onto it, or coalesce:
while a save is in flight, record that another is needed and run it once the first
settles.

### S-73 · Rust: a `ts` that is not a timestamp produces an entry that vanishes — **P3**

**Where** — `journal.rs` `compose`/`build`, reached from `save`, `remove` and
`relocate`.

**The bug.** A `ts` that does not match `\d{4}-\d{2}-\d{2} …` (e.g. `"NaN-NaN-…"`) is
written as a header line that `parse_entries` will not recognise. The entry's text
becomes preamble and disappears from the app, though it is still on disk.

**The fix.** The same as S-02: parse `ts` with `NaiveDateTime::parse_from_str` and
reject it before writing anything.

### S-74 · `cargo test` is red — **P4**

**Where** — `tauri/src-tauri/src/journal.rs:7-8`.

The module doc indents two path lines by four spaces, which rustdoc compiles as a
doctest. It fails with "expected identifier, found `<`". Mark the block as text (a
fenced ```` ```text ```` block). Until this is fixed, S-52's Rust tests cannot run
green.

### S-75 · Android: `SafTree.isReachable()` always returns true — **P1**

**Where** — `data/SafTree.kt:182`, which wraps `children()` (`:63`, `runCatching`).

`children()` turns every exception into an empty list, so `isReachable` never
reports an unreachable folder. That makes the revoked-grant handling at
`JournalStore.kt:133-143` dead code, and a lost folder shows as an empty journal
(S-66).

**The fix.** Have `isReachable` query the tree root's document directly and return
`false` on `SecurityException`, `FileNotFoundException` and
`IllegalArgumentException`, rather than going through `children()`.

### S-76 · Android: a UTF-8 BOM hides the first entry — **P2**

On Android, a file that begins with a byte-order mark fails `^\[` on its first header
line. The first entry is parsed as preamble and never shown, though it is preserved
on disk. Strip a leading U+FEFF when reading, and preserve it when writing, or not,
by the same rule as CRLF (S-21). Add the case to S-67. Whether Swift and Rust behave
the same has not been checked.

### S-77 · macOS: `~/Documents/Wander` is created on every launch — **P3**

`JournalStore.init` (`JournalStore.swift:141-150`) always calls
`resolveBase(preferred: nil)` first. When `JNL_DIR` is not set, that creates
`~/Documents/Wander` on every launch, even if the reader chose another folder. Resolve
the remembered folder first, and create the default only when it is actually used.

### S-78 · Tauri: three woff2 files are shipped and referenced nowhere — **P3**

`tauri/src/fonts/newsreader-italic-300600.woff2`, `newsreader-normal-300600.woff2`
and `plex-normal-400.woff2`, about 319 KB together, are referenced by nothing. The
first is md5-identical to `Newsreader-italic-300-600.woff2`. Delete them.

### S-79 · The daily prompts have already drifted — **P3**

`app.js:106-119` uses a curly ’ in "Tomorrow’s" and "day’s", where
`StatsPanel.swift:189-203` and `StatsSheet.kt:155-169` use a straight '. This is the
drift S-49 predicts. Pick one and generate the table.

### S-80 · Swift: `move()` rebuilds the index three times — **P2**

`JournalStore.swift` `move()` assigns `entries` three times (`:330-332`), and each
assignment runs `entries.didSet` → `rebuildIndex`. `reload()` and `newEntry()` run it
twice each. Build the new array locally and assign it once.

### S-81 · Swift: `Tone.contrast` is not a WCAG ratio — **P5**

`Tone.luminance` and `contrast` (`Theme.swift:57`, `:67-70`) use gamma-encoded sRGB
channel values, not WCAG relative luminance, which requires linearisation. So the
ratios that `legible` and `accentInk` compare are not WCAG ratios. Any "4.5:1 floor"
assertion (S-61) needs the linearised formula first. Check whether Kotlin's `Tone`
has the same formula.

### S-82 · Android ignores several theme styles — **P1**

Android has no `band` and no `centred` masthead (`RootScreen.kt:278-286` falls
through to a plain rule). It also parses and ignores `ornament`, `measure`,
`figureBlocks`, `pageCard` and `rowColours` (S-43). These are the same parity gaps
that S-18 and S-19 record for Tauri, and the earlier draft did not record them for
Android. Decide which theme fields every build must honour, then list them in the
README.

### S-83 · Smaller items found in passing

| Where | What | Severity |
|---|---|---|
| `journal.rs:268` | `remove` ignores a failed delete (`let _ = fs::remove_file`); the caller believes the file is gone | P3 |
| `ProseEditor.swift` `textViewDidChange` / `textDidChange` | `MarkdownStyle.apply` runs over marked (IME composing) text. Guard with `markedTextRange == nil` / `hasMarkedText()`. See the IME row in Appendix A. | P2 |
| `JournalLibrary.swift:180-185` | if `replaceItemAt` throws, the `.wander-*.tmp` file is left behind; remove it on failure | P3 |
| Android `ui/RootScreen.kt:401`, `:425-428` | the stacked fold layout uses the hinge's `positionPx`, which is in window coordinates, inside a `statusBarsPadding()` column. So the page overruns the hinge by the status-bar height. | P2 |
| Android manifest `:19` | `configChanges` omits `locale`, `fontScale`, `keyboard` and `layoutDirection`, so those changes recreate the activity. The ViewModel survives, but the caret resets to the end (`ProseEditor.kt:187`). | P3 |
| `JournalLibrary.swift:7` | the comment mentions a "Linux terminal build" that does not exist | P6 |
| `Theme.swift:6` | the comment says "thirteen" themes; there are fourteen | P6 |
| `Resources/Info.plist` vs `Info-macOS.plist` | the SwiftPM path sets `NSPrincipalClass` and the Xcode path does not. Harmless for a SwiftUI app, but a divergence (S-45). | P3 |

---

## Suggested order

Roughly two weeks of focused work, in the order that stops the bleeding first.

**Week 1 — do not lose anyone's journal**
1. **S-68** Android: make `flush` awaitable before `move`, star and copy
2. **S-01** refuse the write on any read or decode failure, in all three ports, with
   tests (S-51, S-67). Include `remove` and `freeStamp`, and Android's `readText`.
3. **S-05** Android durable flush and write-then-rename, then **S-06**
   write-destination-first in all three (with the Android same-file case)
4. **S-04** Tauri close-requested flush (`core:window:allow-destroy`), **S-72** save
   ordering, and **S-09** the missing error handling
5. **S-69** Android external-edit overwrite, and **S-75** / **S-66** make a lost
   folder visible
6. **S-02** / **S-73** / **S-71** validate `ts` and `source` at the Rust command
   boundary, with tests. **S-74** first, so that `cargo test` is green.
7. **S-12** the Swift reload guard and the one shared "is this on disk" predicate, in
   both ports

**Week 2 — make it right, then make it fast**
8. **S-70** the invisible ornaments, **S-03** the `--prose` collision (plus the
   CSS-variable guard test), **S-19** the `band`/`double` mastheads
9. **S-07** the single-pass inline styliser, then **S-08** the calendar, then
   **S-10**, **S-11**, **S-63** the Tauri key collisions
10. **S-20** / **S-21** / **S-76** the counting, CRLF and BOM definitions, with the
    shared fixture (S-67)
11. **S-53** CI, in the order given — it protects everything above
12. Performance:
    - First **S-25** `tags` and **S-26** `Counts`. They are a few lines each and the
      largest per-keystroke win on two of the four platforms.
    - Then **S-30** debounced search, **S-31** async launch (all Tauri commands),
      **S-29** the gated Android restyle (with `setText` forcing a full restyle),
      **S-28** focus-mode scoping, **S-33** the Android walks, and **S-80**.
    - **S-27** is a one-liner; do it in passing.

**Then, in the order the readers will notice**
13. **S-13** decide the theme-size question and make the README, the
    `ThemesSheet.swift` header and all four builds agree; **S-14** Android's filing
    behaviour; **S-15** the Android figures; **S-17** the setting labels; **S-18** /
    **S-82** the theme fields each build honours
14. **S-42**–**S-50** the dead code and the real bugs hiding in it (**S-44**
    `build.sh`, **S-46** `SlidingColumn`), plus **S-77**–**S-79**. **S-47** is
    hygiene only.
15. **S-58**–**S-60** accessibility on the Tauri build, then the Apple and Android
    passes (S-61, with **S-81** first)
16. **S-23**, **S-63**–**S-66** documentation, once the behaviour is settled

---

## Appendix A — checked and dismissed

Recorded so the next review does not repeat them.

| Checked | Finding |
|---|---|
| Global keyboard shortcuts firing while typing in the find box (`app.js:1323`) | **Not a bug.** Every shortcut is gated on `meta` at line 1325, so plain letters in `#query` and `#time` are unaffected. |
| `JournalIndex.months` assuming its input is sorted | **Correct**, and the assumption holds: `ts` begins with the date, `sortedByTimestamp` is a lexicographic compare on a fixed-width string, and all three call sites pass a ts-descending list. The precondition is documented at `JournalLibrary.swift:206-209` but unenforced; add an assertion (S-43). Not a bug. |
| `Entry.isStarred` matching a bold title | **Correct.** `suffix == "*" \|\| suffix.hasSuffix(" *")` requires a standalone marker; `**Important**` does not match. Covered by `ParserTest.kt:99-101`. |
| Two entries sharing a timestamp in one file | **Prevented.** `freeStamp` advances by a second until free, in all three ports. |
| `renderEntries` adding a trailing newline on every save | **Idempotent**, and `ParserTest.kt:60-71` proves it. |
| The preamble before the first header being lost on rewrite | **Preserved** in all three ports, and tested (`ParserTest.kt:46-58`). |
| `ProseEditor.updateNSView` clobbering the IME's composing region on iOS | **Not via `updateNSView`**: `tv.text = text` is guarded by `tv.text != text` (line 286), so it runs only when the bound value genuinely differs, which during composition it does not. The actual risk is the *restyle* running over marked text; that is listed in S-83. |
| `SlidingColumn` re-rendering hidden panels | **Already handled** — `@State mounted` unmounts after the animation (Components.swift:237-273). The *race* is real (S-46); the re-render concern is not. |
| `Theme.legible`'s `minimum: 3.2` being below WCAG AA | **By design** (it is choosing between two already-chosen theme colours, and the alternative is the wrong one). But nothing asserts a floor anywhere — see S-61. |
| `escapeHtml` being XSS-exploitable | **Not today** — every call site is element content, not an attribute. Fix as defence in depth (S-48). |
| `std::sync::Mutex::lock().unwrap()` in the Tauri state (`lib.rs:14, 27, 136`) | **Panics on poisoning**, which only happens after a prior panic. Here it is effectively unreachable: the critical sections are a `PathBuf` clone and an assignment. Trivial fix (S-38). |
| `AndroidManifest.xml` `configChanges` | **Correct for what it lists.** `orientation|screenSize|screenLayout|smallestScreenSize|keyboardHidden|uiMode|density` covers rotation, resizing, re-folding and dark mode, and `README.md:174-176` is right that the activity is not restarted for those. It does not list `locale`, `fontScale`, `keyboard` or `layoutDirection`; see S-83. |
| The Android R8 configuration | **Probably fine, certainly unverified** (S-55). |
| `writeAtomically` in Swift using `replaceItemAt` on a file that does not exist (`JournalLibrary.swift:180-185`) | **Unverified, and almost certainly fine in practice**, because every first entry of a day takes this path. The guard is still cheap: `if FileManager.default.fileExists(atPath: url.path) { replaceItemAt } else { moveItem }`. Also remove the temp file on failure (S-83). |
| `contenteditable="plaintext-only"` in WebKitGTK | **Low risk.** The earlier draft's version history was wrong. `plaintext-only` started as a WebKit value and has long been in WebKit and Chromium; Firefox was the late one. A runtime feature check is still cheap insurance, since the whole editor is built on that attribute. |
| `themes.json` byte-identity across the three copies | **Currently identical** (`md5 c87b5a855490c1bca1feb1f989ed76d4`, re-checked at `21614f2`). Nothing enforces it (S-24, S-53). |
| `ParserTest.kt`'s case count | **14 `@Test` cases**, as stated. The line references above hold (`46-58`, `60-71`; the starred-title case is at `98-100`). |

### Dismissed or corrected by the validation pass

| Earlier claim | Finding |
|---|---|
| S-09: "copy markdown" fails because a clipboard capability is missing | **Wrong root cause.** Tauri capabilities gate IPC, not `navigator.clipboard`. `core:webview:allow-write-clipboard` does not exist, and `clipboard-manager:allow-write-text` belongs to a plugin that is not a dependency. The missing `.catch` is real and remains S-09. |
| S-20: Rust counts characters as `body.len()` bytes | **Wrong.** Rust computes no character count; Tauri uses the JS one. |
| S-24: `android/README.md` says "the build writes assets/fonts/fonts.json" | **Misquote.** That text is in code comments (`Fonts.kt:19`, `Theme.kt:185`), not the README. |
| S-66: Android's revoked-grant handling works | **Wrong.** It is gated on `isReachable()`, which always returns true (S-75). |
| S-50: `SidebarView.swift:42-47` sets a font and colour twice, and the first is dead | **Wrong.** The first `.font`/`.foregroundColor` style the `prompt:` Text; the second pair style the TextField. |
| S-50: `EditorView.swift:85-86` uses the deprecated `onChange(of:perform:)` | **Wrong.** The zero-argument closures resolve to the macOS 14 `onChange(of:initial:_:)`. |
| S-50: `StatsSheet.kt:88, 91` has a redundant `entry != null` | **Wrong.** There is no outer `if`, and the check is needed for the smart-cast inside the lambda. |
| S-50: `frontendDist: "../src"` makes the debug binary not self-contained | **Wrong.** With no `devUrl`, tauri-codegen embeds `frontendDist` even in debug (`tauri-codegen-2.6.3/src/context.rs:178-194`). |
| S-50: TextKit 1 is deprecated on macOS 15 | **Wrong.** It is not formally deprecated. Moving to TextKit 2 is optional. |
| S-50: the `allowBackup` risk is the folder grant | **Overstated.** Persisted URI grants do not survive a restore; only the URI string leaks. |
| S-05: rotation cancels `viewModelScope`, and cancellation can interrupt `writeText` part-way | **Wrong on both counts.** The real risk is process death mid-write. |
| S-05: SAF has no rename | **Wrong.** `DocumentsContract.renameDocument` exists (API 21+, optional per provider). |
| S-13: the `leading` bindings passed to the theme cards are unused | **Wrong.** They are used (`ThemesSheet.swift:180`, `ThemeSwiper.swift:31, 252`). Only `ThemesSheet.typeSize` is unused. |
| S-22: `tauri build` tries every configured format regardless of host, and fails | **Probably wrong, and unverified.** The bundler filters by host. |
| S-27: ten full copies per keystroke is a large cost | **Overstated.** It is ten O(n) memcpys, microseconds next to the regex work. |
| S-34: the font cache is unbounded; `monthTitles` is cheap enough to drop | **Wrong on both counts.** The size is clamped to 13–28 in 0.5 steps, and dropping `monthTitles` costs about 10 ms per keystroke on a ten-year journal. |
| S-38: lock poisoning could abort the app | **Effectively unreachable.** Kept as P3 insurance. |
| S-44: the `sh -c` evidence (exit 2) | **Invalid evidence.** dash rejects `pipefail`. Re-verified under bash (exit 1); the conclusion stands. |
| S-47: a theme's light and dark halves can compare equal | **Does not occur** with the fourteen shipped themes. |
| S-49: removing the duplicate fonts would halve the repository | **Wrong.** Git stores identical files as one blob. |
| S-56: `rust-version = "1.77"` is good | **Wrong.** The locked dependencies need 1.88. |
| S-57: run the icon generator from `build.sh` | **Unsound fix.** It rewrites tracked files on every build. |
| S-58: every button lacks visible focus | **Wrong.** Buttons keep the UA focus ring; the inputs and `.prose` do not. |
| S-64: three build-table rows cover the same binary | **Wrong.** Two rows, two different apps. |
