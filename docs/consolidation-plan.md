# Quire — consolidation plan (2026-10-12)

Survey of the four repos as cloned today, what each contributes, what Quire is
missing, and the order to do it in. Nothing here has been merged or deleted yet.

## 1. What exists

| Repo | What it is | Size | Branches beyond main | State |
|---|---|---|---|---|
| **jnl** | Go CLI + bubbletea TUI (review, browse, built-in editor). Defines the on-disk format. | 2.3k Go | none | Clean. Reference format + parser tests (`main_test.go`). |
| **nook** | SwiftUI iOS + macOS, the fullest app (media, widgets, share ext, Spotlight, reminders, external display, importers, PDF, Data Saver, timer Live Activity) + a Tauri Linux port. Generated Xcode project. | 18k Swift, 6.3k Linux | `claude/ios-presentation-mode-bugs-bml512` (+1 commit, 405/88, merges clean) | Clean. CHANGELOG + CLAUDE.md discipline. |
| **Wander** | The designed one. SwiftPM `WanderCore` (parser + file ops, Foundation only), macOS + iOS shells, Android (Kotlin/Compose), Tauri. 14 themes in one `themes.json` shared byte-identical by every build. Markdown styled where you type. | 5.9k Swift, 3.8k Tauri, 4.6k Kotlin | `claude/trusting-clarke-3lld5o` (0 ahead, 10 behind — dead) | Clean. `docs/review-spec.md` (84 findings, most fixed), `docs/from-nook.md` (gap list). |
| **Quire** | Tauri 2 Linux app only, v0.6.2. Rust core (`journal.rs` + `extras.rs` + `media.rs` = 4.1k) already at nook + jnl parity; 7 themes incl. Marathon. Two commits of history. | 4.1k Rust, 3.1k web | `claude/ios-presentation-mode-bugs-bml512` (+1, fast-forward: presentation window), `claude/laughing-archimedes-gn6l9t` (identical to main — dead) | No Swift at all. No CLAUDE.md, no CHANGELOG, no tests beyond `cargo test` round-trips. |

No open pull requests on any of the four. No uncommitted work anywhere.

**Reality check on "Quire is half built":** it is a quarter built. The Linux
half is nearly done (it already absorbed nook's feature list and jnl's
maintenance commands). The Apple half, the TUI, and the Wander design language
do not exist in the Quire repo yet.

## 2. Branch tidy (do first, five minutes)

| Action | Why |
|---|---|
| Merge `nook/claude/ios-presentation-mode-bugs-bml512` → `nook/main` | Editor-mirror on the external display with caret, size setting, locked → idle. `git merge-tree` shows zero conflicts. Not compiled here (no Swift toolchain in the container) — build once in Xcode before trusting. |
| Fast-forward `Quire/main` to `claude/ios-presentation-mode-bugs-bml512` | Linux "presentation window" (Ctrl+Alt+P): the desk-mode shape for every desktop platform. JS not executed here; run `npx tauri dev` once. |
| Delete `Wander/claude/trusting-clarke-3lld5o` | Contains nothing main lacks. |
| Delete `Quire/claude/laughing-archimedes-gn6l9t` | Identical to main. |

Both presentation branches came out of one session on the same day; they are
the same feature on two platforms and should land together.

## 3. Target shape for Quire

One repo, three front ends, one format, shared theme file.

```
Quire/
  CLAUDE.md / AGENTS.md         (nook's discipline — currently absent)
  CHANGELOG.md                  (nook's format)
  themes.json                   Wander's 14 + Quire's Marathon/Marathon Day → ONE source of truth
  apple/
    QuireCore/                  Swift package: parser, store, search grammar, list continuation,
                                templates, importers, backup, media (from nook's Models/, packaged
                                the way WanderCore is)
    Quire/                      SwiftUI views (nook's feature set wearing Wander's type + themes)
    QuireiOS/, QuireWidget/, QuireShare/
    gen_pbxproj.py              (nook's generator; keeps the hand-written iOS scene manifest)
  linux/                        today's src/ + src-tauri/ unchanged, moved down one level
  cli/                          jnl, vendored as-is (Go), renamed `quire` later if wanted
  sample/                       as now
```

### Why nook's Swift is the base, not Wander's

| | nook | Wander |
|---|---|---|
| Features | everything on your list | journal/inbox/starred, themes, focus, editor |
| Store | 3.1k-line `JournalStore` incl. iCloud watcher, conflicts, share drain, backups | 674 lines, polling reload (its own review flags this) |
| Tests | hostless XCTest over real files + parser parity | `CoreTests.swift` 303 lines (recent) |
| Project | generated pbxproj, 4 targets, entitlements done | xcodegen + SwiftPM, cleaner package split |
| Design | freewrite/Lato, functional | the point of Wander |

Take nook's *code*, Wander's *package layout* (`WanderCore` → `QuireCore`), and
Wander's *skin*: `Theme.swift`, `MarkdownStyle.swift`, `ProseEditor.swift`,
`ThemesSheet`/`ThemeSwiper`, `Fonts.swift`, `themes.json`. nook's
`WritingTextEditor` already does tag colouring, inline bold/italic/code and the
mirror mode; Wander's `MarkdownStyle` is the richer styling table (headings,
quotes, code, hairline `##`). Merge the styling table into nook's editor rather
than swapping editors — nook's editor carries the list-continuation, caret
reporting and external-display plumbing you want to keep.

### What each source contributes

| Want | Comes from | Already in Quire-Linux? | Apple |
|---|---|---|---|
| Format + parser + parity tests | jnl `main_test.go` → nook `ParserChecks` / Wander `CoreTests` / Quire `journal.rs` tests | yes | with nook |
| TUI (review, browse, editor) | jnl | no — vendor the Go binary | n/a (CLI runs on macOS already) |
| Editor macros (↩ in lists, ⌘B/I/`, @autocomplete, templates `{{date}}`, promote first line, import as entries) | nook | yes | with nook |
| Desk / presentation mode | nook iOS external display + Quire Linux second window | branch | iOS: nook branch. **macOS: missing** — build it as a second `WindowGroup` fed the same way the Linux window is (one push per frame, caret-follow scroll). |
| Media, Data Saver, importers, backup, cleanup, split journals, saved searches | nook | yes | with nook |
| Widgets, share sheet, Spotlight, reminders, Face ID, Live Activity | nook | n/a | with nook |
| 14 themes from one JSON, drawn-not-listed theme picker, themed app icons | Wander | 7 themes, hand-coded CSS | port |
| Markdown styled in place (headings/quotes/code) | Wander | partly (bold/italic/code/tags) | merge into nook editor |
| Window chrome without title bar, masthead-as-drag-handle | Wander | yes | macOS keeps traffic lights |
| Android | Wander | — | keep Wander's Kotlin as the future `android/`; it already shares `themes.json` |

## 4. Order of work

1. **Branch tidy** (section 2). Then tag `quire-linux-0.6.2` so the Linux-only
   era has a name.
2. **Repo skeleton**: move `src/`, `src-tauri/` under `linux/`; add `cli/` with
   jnl's tree (git subtree so history survives); add `CLAUDE.md`, `AGENTS.md`,
   `CHANGELOG.md` modelled on nook's; promote `themes.json` to the root with a
   check script that the Linux CSS and the Swift theme table both read it.
3. **Apple port, phase 1 — rename, don't redesign**: copy nook's `Nook/`,
   `NookWidget/`, `NookShare/`, `Tests/`, `gen_pbxproj.py`, `Makefile` into
   `apple/`, rename bundle ids to `com.caddickbrown.quire`, App Group and
   iCloud container likewise, build green. This is a day of sed and Xcode, and
   it gets every nook feature into Quire with zero behaviour change. Keep
   `.nook/` as the sidecar directory name on disk (nook, Quire-Linux and the
   savings ledger all already read it; renaming it breaks sync with existing
   journals).
4. **Apple port, phase 2 — Wander's skin**: `themes.json` loader + Wander's
   `Theme.swift`, fonts (Newsreader, IBM Plex, plus Archivo/DM Mono for
   Marathon), the drawn theme picker, `MarkdownStyle` merged into
   `WritingTextEditor`, masthead layout from Wander's `RootView`. Ship Almanac
   as default like Wander.
5. **macOS desk mode**: second window, same payload contract as
   `linux/src/present.js` (kind / title / body / caret / theme / stats), so the
   three platforms share one spec.
6. **TUI decision** (after 1–5, not before): either keep `cli/` as Go for ever
   (cheapest, already works on macOS/Linux/Pi), or rewrite it in Rust with
   ratatui on top of `linux/src-tauri/src/journal.rs` so the desktop app and
   the TUI share one core. Only worth it if you want `quire tui` to gain the
   Linux app's extras (search grammar, templates, media) — jnl's own scope is
   deliberately smaller.
7. **Android**: Wander's `android/` moves in last; it needs the feature pass
   nook never gave it and it is the one platform with no desk mode or media.

## 5. Assumptions

- Quire is the surviving name; nook, Wander and jnl become read-only
  references once their code is in. jnl may stay published as a standalone
  binary because other people use it.
- The on-disk format never changes: `inbox.md`, `journal/YYYY/MM/DD.md`,
  `<tag>.md`, `assets/`, `.nook/` sidecars.
- iOS 17 / macOS 14 floors (nook's), Swift 5.9+.
- You build and sign on your Mac; nothing Apple-side can be compiled in this
  container (no Swift). Rust and Go can be tested here; Tauri itself cannot
  link (no webkit2gtk).
- The two Claude branches are wanted, not experiments. If the iOS one was a
  bug-fix attempt that didn't pan out, say so and it gets closed instead.
