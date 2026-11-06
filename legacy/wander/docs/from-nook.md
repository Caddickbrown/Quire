# What we can pull from Nook

[Nook](https://github.com/Caddickbrown/nook) is the older, wider app over the
same jnl folder — iOS and macOS SwiftUI, plus a Tauri port for Linux. It has
been through a parity wave that Wander has not, so a good deal of it is already
written, already ported to Rust, and already argued with.

Wander is the narrower app on purpose. The line in the README — *plain markdown
on disk, no database, no sidecar files, no export* — is the test each of these
has to pass, and a few of them fail it. This is a shopping list, not a plan.

Sources, for anything below: `~/Code/nook/CLAUDE.md` is the architecture,
`Nook/Models/` and `Nook/Views/` the Swift, `linux/src-tauri/src/` the Rust that
already exists for the Tauri side.

---

## Take these

Things that are pure computation or pure editing behaviour: no new files on
disk, no new format, and each one lands on all three builds.

**The parser tests.** `Tests/WanderCoreTests/CoreTests.swift` is one line long —
`import XCTest` — and that is the whole suite. Nook's `Tests/ParserChecks.swift`
(241 lines) is a port of the cases in jnl's own `main_test.go`: the header regex
and its en-dash tolerance, the preamble that has to survive a rewrite, stable
oldest-first sorting, tag splitting, round-tripping. Wander's `JournalParser`
claims the same byte-compatibility and nothing currently holds it to it. This is
the cheapest and most valuable thing on the list, and `tauri/src-tauri/src/`
should get the Rust half of it the same way `linux/src-tauri/src/parser.rs` did.

**A real search grammar.** `JournalLibrary.matches` is substring-over-everything.
Nook's `Models/SearchQuery.swift` is a pure grammar — `tag:`, `before:`,
`after:`, `has:`, `is:starred`, `"quoted phrases"` — with `search.rs` already
written as the Rust twin and both sides sharing test cases. It belongs in
`WanderCore` next to the parser, and the find field in the index gets it for
free.

**List continuation.** `Models/ListContinuation.swift`: pressing return inside a
bullet, an ordered item or a checkbox continues it, and returning on an empty
item ends the list. Pure rules, shared by both platform editors, in Nook's test
suite. Wander is a writing app before it is anything else, and this is the
single most-felt missing behaviour in `ProseEditor`.

**On this day.** Nook computes it in the store from entries already loaded —
same day and month, earlier years. No storage, no index. In Wander it wants to
be a line in the stats column rather than Nook's banner.

**Tags, browsable.** `@tags` are already parsed and deduplicated for the stats
column, and there is no way to click one. Nook's `Views/TagsView.swift` is a
coloured, searchable cloud that opens the entries under a tag. In Wander this is
probably a fourth page in the masthead rather than a sheet — it cuts across
journal and inbox the way Starred does.

**Random.** One line, and it is the best reason to open a journal that is more
than a year old.

**A file watcher instead of a poll.** `reloadIfChanged` stats the folder and
compares a fingerprint. Nook uses `NSMetadataQuery` when the folder is in
iCloud and `DispatchSource` directory watchers otherwise, and merges inbox
conflicts keep-both rather than picking a winner. Wander's folder is very often
someone's iCloud or Dropbox folder with `jnl` writing into it from a terminal;
the poll is a bug waiting for a two-machine day.

**Keyboard navigation that works on iPad.** `Views/KeyboardNavigation.swift` —
↑/↓/↩/⎋ over an entry list. Read its header before porting: it uses
`UIKeyCommand` rather than SwiftUI's `onKeyPress` on iOS, and the header says
why. That is a debugging session already paid for.

**Year in Review.** `Models/YearReview.swift` computes it off-main and
`YearReviewView` renders a shareable card with `ImageRenderer`. Wander already
has a stats column and a *Seismograph* theme that draws the month as a trace
down it, so the heat strip from `TrendsView` (a `Canvas`, not Swift Charts, and
therefore portable) is the piece to take first.

## Take these, but not as Nook built them

**Templates and prompts.** Nook keeps templates in `<base>/.nook/templates/*.md`
with `{{date}}` substitution, and a bundled deck of composer prompts. The prompt
deck is free — it is bundled, it stores nothing, and an empty page in a journal
app is exactly where it earns its keep. The templates are a sidecar directory in
the journal folder, which is the thing the README promises not to do; if we want
them, they should be plain `.md` files somewhere the user already looks, or not
at all.

**Importers.** `Models/Importers.swift` does Day One JSON and dated-markdown
folders, with a prepare → confirm → commit flow and dedupe by raw text on a
second run. The output is ordinary jnl markdown, so this passes the test
cleanly. It is worth having exactly once per user, which argues for putting it
behind Options rather than anywhere near the page.

**Backup.** Nook copies the whole base folder to a timestamped folder, on a
Daily/Weekly/On-change interval with a keep-last-N prune. A folder copy is not
an export — nothing is transformed — so it does not break the promise. The
interval settings and the pruning are more machinery than Wander wants; a single
**Options ▸ Back up now** would do most of the work.

**A share sheet, and a widget.** Both are genuinely useful on iOS and both need
an App Group. Nook's share extension is deliberately self-contained: it cannot
resolve the custom folder's security-scoped bookmark, so it never touches the
journal — it drops a jnl-format draft into `PendingShare/pending.md` in the App
Group and the app drains it at the top of every reload. Copy that shape exactly;
it is the only correct one. The widget reads a `NookSnapshot` written into App
Group `UserDefaults` after each reload, so it never opens a journal file either.
Neither puts anything in the journal folder.

**A daily reminder.** Nook's is streak-aware and carries an inline *Write a
line…* text action that files a draft without opening the app. Wander already
computes the streak. The notification is the whole feature; skip the weekly
resurfacing note until On This Day exists to feed it.

**Spotlight.** Opt-in Core Spotlight indexing with deep-link resolve. No sidecar
in the journal folder — the index is the system's. Apple builds only, which is
fine; the Tauri build has never pretended to parity.

**Face ID lock.** `Models/AppLock.swift`, and the important part is Nook's
decision that it locks the app and not the files: the markdown stays plain, by
design. Take the decision along with the code.

## Probably not

**Media.** Photos, video, audio, an assets gallery, poster frames, a Data Saver
compression pipeline with per-device savings ledgers in `.nook/`. It is the
largest subsystem in Nook by some distance, it wants `<base>/assets/`, it wants
sidecar JSON, and it is aimed at a different app. Wander is set like a page.

**Saved searches.** `<base>/.nook/searches.json`. Straightforwardly a sidecar
file. If pinned queries ever matter, they belong in `UserDefaults` with the
column and paper settings, not in the journal.

**PDF export.** Nook typesets one page per day with vector text through an
`ImageRenderer` into a `CGContext` PDF, and it is genuinely nice. It is also
called *export*, which the README rules out in as many words. Worth a
conversation rather than a port: printing a page is not the same act as
exporting a database, and a theme is a typeset design already.

**Split-tag files.** `<base>/<tag>.md` from jnl's `JNL_SPLIT_TAGS`. Nook has the
routing hook and deferred the UI. A second place for an entry to live
complicates every count in the stats column for a feature neither app has
finished.

**Transcription, Live Activities, App Intents, the external display.** Each is
Apple-only, each is a target or an entitlement, and none of them changes what
the page is like to write on.

## Worth reading even if we take nothing

- `linux/src-tauri/src/store.rs` is 2,697 lines against our `journal.rs`'s 391.
  Whatever we port next, the Rust has probably been written once already.
- `CLAUDE.md`'s **Conventions** — never accept Xcode's *Update to recommended
  settings*, keep the parser pure and jnl-faithful, add a test case when you
  touch it. Wander generates its project too, and will hit all three.
- Nook keeps a `CHANGELOG.md` and ships it as a bundled resource that a
  *What's New* view parses at runtime. Wander has no changelog at all.
