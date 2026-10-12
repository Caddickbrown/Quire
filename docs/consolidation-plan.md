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

## 3. Target shape for Quire — one Rust core, thin native shells

Decision (2026-10-12): every feature lives in the Quire repo and the backend
is Rust. The shells are native: SwiftUI on iOS/macOS, Tauri's webview on
Linux, Compose on Android later, ratatui in the terminal.

### Why this is the right call, with evidence

There are **seven** independent implementations of the jnl format today:

| Port | Language | Lines (parser + store) |
|---|---|---|
| jnl | Go | ~1.7k |
| nook | Swift | 3.5k |
| nook/linux | Rust | 3.2k |
| Wander | Swift | 0.5k |
| Wander/tauri | Rust | 0.6k |
| Wander/android | Kotlin | 1.0k |
| Quire | Rust | 4.1k |

All seven carry the en-dash fix from jnl `1140729` today, but that is luck
and diligence, not structure: every fix has to be made seven times, and every
cleanup/dedupe/split-routing rule is argued seven times. Wander's own review
(`docs/review-spec.md`, 84 findings) spent most of its P0s on the three ports
disagreeing about writes. One core ends that.

Quire's Rust is already that core in all but packaging: `journal.rs`,
`extras.rs` and `media.rs` import nothing from Tauri (0, 0 and 1 reference —
the one is a progress-event emitter). Everything Tauri-specific is in
`lib.rs`. Extracting a `quire-core` crate is a move, not a rewrite.

### The one design rule that makes it work: the core never opens a file itself

```rust
pub trait Vault: Send + Sync {
    fn read(&self, rel: &str) -> io::Result<Vec<u8>>;
    fn write_atomic(&self, rel: &str, bytes: &[u8]) -> io::Result<()>;
    fn list(&self, rel: &str) -> io::Result<Vec<DirEntry>>;
    fn remove(&self, rel: &str) -> io::Result<()>;
    fn modified(&self, rel: &str) -> io::Result<SystemTime>;
}
```

The core speaks paths relative to the journal root over this trait. Each
shell supplies the implementation its platform needs:

| Shell | `Vault` impl | Why it can't be plain `std::fs` |
|---|---|---|
| Linux / TUI | `std::fs` + temp-and-rename (today's code) | it can |
| macOS / iOS | Swift callback: `NSFileCoordinator` around `replaceItemAt`, inside the security-scoped bookmark's access | iCloud sync daemon races uncoordinated writes; nook already coordinates its in-place media swap and should coordinate all of them |
| Android | Kotlin callback over `DocumentFile` / `contentResolver` | SAF hands out `content://` URIs, not paths; Rust `std::fs` cannot see them at all |

Without this trait the Android build is impossible and the iCloud build is
unsafe. With it, the same tested core runs on all five fronts.

### What stays native (shell-side), by necessity

Folder choice and bookmarks · iCloud `NSMetadataQuery` watcher and ubiquity
container discovery · `notify` directory watcher on Linux · AVFoundation /
ImageIO transcoding on Apple (the Rust `media.rs` shells out to `ffmpeg`,
which iOS does not have) · Speech transcription · widgets, share extension,
Spotlight, notifications, Live Activity, Face ID · external display / second
window · the editor widget itself (NSTextView / UITextView / textarea /
Compose TextField) · theme rendering. All of these call into the core for
data and never touch markdown.

### Bridge

[UniFFI](https://mozilla.github.io/uniffi-rs/) generates the Swift and Kotlin
bindings from the Rust API, including callback interfaces (that is how
`Vault` crosses the boundary). The core builds as an `xcframework` for
Apple (`cargo-xcode` or a `make core` step that `gen_pbxproj.py` links) and
as a `.so` via `cargo-ndk` for Android. Tauri links it directly. The TUI is a
second binary in the same workspace.

### Repo layout

```
Quire/
  CLAUDE.md / AGENTS.md / CHANGELOG.md     (nook's discipline)
  themes.json                              Wander's 14 + Marathon ×2 — one source of truth
  core/                                    quire-core crate: parser, store, search grammar,
                                           list continuation, templates, importers, backup,
                                           cleanup, stats, Vault trait. cargo test here.
  bindings/                                UniFFI .udl / proc-macros, xcframework + ndk build
  linux/                                   today's src/ + src-tauri/, lib.rs shrunk to glue
  tui/                                     ratatui: jnl's review / browse / editor over core
  apple/                                   nook's targets renamed, Store/ replaced by core calls,
                                           Views wearing Wander's themes + MarkdownStyle
  android/                                 Wander's Compose shell over core (last)
  sample/
```

## 4. Order of work

1. **Branch tidy** (section 2). Tag `linux-0.6.2`.
2. **Extract `core/`** from `src-tauri/`: move the three files, introduce
   `Vault`, port Quire's `cargo test` + jnl's `main_test.go` cases + nook's
   `ParserChecks` + `search.rs` cases into one suite. Linux app rebuilt on it;
   behaviour identical. Testable in this container.
3. **TUI** in `tui/` over the core: jnl's `review`, `browse`, `log`, `stats`,
   `search`, `random`, the bubbletea editor as ratatui. This is the cheapest
   proof that the core is really shell-agnostic, and it replaces jnl's Go
   (jnl stays published for its users; it is the reference, not a dependency).
4. **Apple, phase 1**: nook's targets into `apple/`, renamed; `JournalStore`
   kept as the `@MainActor` façade but its file logic swapped for core calls
   through UniFFI, with a Swift `Vault` doing coordinated writes. nook's
   hostless XCTest keeps running against the façade, so regressions show.
5. **Apple, phase 2**: Wander's skin — `themes.json`, fonts, drawn theme
   picker, `MarkdownStyle` merged into nook's `WritingTextEditor`, masthead.
6. **Desk mode everywhere**: iOS from nook's branch; macOS as a second
   `WindowGroup`; Linux from Quire's branch; one payload contract.
7. **Android**: Wander's Compose shell over core via a SAF `Vault`.

### What this costs that the two-port plan did not

- A Rust toolchain and an xcframework step in the Apple build. One-time.
- UniFFI's boundary rules: plain data types, no SwiftUI types cross, async is
  `async fn` on both sides. nook's store is already `@MainActor` + value
  types, so this fits.
- Latency of a call across the bridge is microseconds; the only thing that
  must stay out of the per-keystroke path is a full inbox re-render, and
  Quire's Rust already avoids that the way nook's Swift does.

## 5. Assumptions

- Quire is the surviving name; nook and Wander become read-only references
  once their code is in. jnl stays published as a standalone Go binary because
  other people use it, and remains the format's reference implementation.
- The on-disk format never changes: `inbox.md`, `journal/YYYY/MM/DD.md`,
  `<tag>.md`, `assets/`, `.nook/` sidecars (renaming the sidecar breaks
  journals nook already syncs).
- iOS 17 / macOS 14 floors, Swift 5.9+, Rust stable, UniFFI 0.28+.
- You build and sign on your Mac; no Swift here. Rust and Go are testable in
  this container; Tauri itself cannot link (no webkit2gtk).
- The two Claude branches are wanted, not experiments.
