# Quire — Technical Documentation for AI Agents

> **KEEP IN SYNC**: `CLAUDE.md` and `AGENTS.md` are clones. When a change is
> substantial (architecture, data flow, on-disk format, build process, major
> UX), update **both**. Skip churn for trivial tweaks.

## What is Quire?

One journalling app over a plain folder of markdown, in the jnl format. It
is the consolidation of three earlier projects — **jnl** (a Go CLI, the
format's reference), **Nook** (SwiftUI iOS/macOS, the fullest feature set)
and **Wander** (the designed one) — into one repository with **one Rust
core** and thin native shells. Today: the Linux Tauri app and the terminal
app. The native Apple shell is now in `apple/`, brought over from Nook and wired
to the Rust core; its first Apple SDK build is pending. Android from Wander's
Kotlin is next. `docs/consolidation-plan.md` records every decision.

## Data model (jnl's, with drafts in day files)

```
<folder>/
  inbox/YYYY/MM/DD.md      drafts, one file per day (Quire 0.7+)
  inbox.md                 the single-file inbox jnl and Nook write; read when
                           present and folded into inbox/ by migrate_legacy_inbox
  journal/YYYY/MM/DD.md    filed entries
  split/<tag>/YYYY/MM/DD.md split journals (JNL_SPLIT_TAGS), one folder of day
                           files per tag (Quire 0.7+)
  <tag>.md                 the one-file split journal jnl and Nook write; read
                           when present and folded into split/<tag>/ by
                           migrate_legacy_splits (root .md files with no entries
                           are not journals and are left alone)
  transfer.md              jnl's batch file
  assets/YYYY/MM/…         media, linked as ![](assets/…) from entry bodies
  .quire/                  sidecars: templates/, searches.json, datasaver-<id>.json,
                           migration/ (the folded inbox.md and <tag>.md files). `.nook/` is read while
                           only it exists and renamed on the first write.
```

Entry: `[YYYY-MM-DD HH:MM:SS] optional title` + body; blank line between
entries; a trailing ` *` on the title stars it; a preamble before the first
header is preserved on rewrite. Header dates accept an en-dash and are
normalised to hyphens. CRLF and a BOM are normalised on read.

**Entry identity** is `(file, index)` plus the entry's raw text: every edit
presents `expected_raw`, and the store re-locates the entry by it if the
index moved. A day file (inbox, journal or split) that empties is deleted;
the legacy `inbox.md` and a legacy root `<tag>.md` are written empty, as jnl
does.

## Workspace

```
Cargo.toml          workspace: core, tui, linux/src-tauri (default members: core, tui)
themes.json         the looks — one source. core/src/themes.rs compiles it in.
install.sh          Linux + macOS installer (bash 3.2). Asks TUI / GUI / both;
                    detect jnl/Nook/Wander + their folders → ask everything →
                    back up → install deps (rustup, WebKitGTK per package
                    manager, Tauri CLI) → build + install + check → settings +
                    migrate → only then remove old apps (to the Trash). Never
                    deletes a journal; --dry-run prints every command;
                    --uninstall removes Quire.
core/               quire-core
  src/vault.rs      the Vault trait + FsVault. THE RULE: the core never opens a
                    file itself; every entry file and sidecar goes through the
                    vault, so the Apple shell can coordinate writes with
                    NSFileCoordinator and Android can use the Storage Access
                    Framework. Media transcoding and backups need real paths
                    (Journal::local / Journal::path) and are native on shells
                    whose vault has none.
  src/journal.rs    the format (pure functions) + the Journal handle: load,
                    locate, insert_entries, write_file_entries, and the shared
                    operations new_draft / update_entry / delete_entry /
                    file_draft / unfile_entry / import_text /
                    migrate_legacy_inbox; sidecar() / sidecar_mut()
  src/extras.rs     templates, saved searches, assets + orphans, cleanup,
                    sort_inbox, file_all, merge_ex_split, merge_conflict,
                    export, backup/restore, attach (attach_media /
                    attach_bytes: Data Saver + ledger), importers (markdown folder, Day
                    One, transfer.md), tag review/rename, sizes, stats_extra,
                    split-tag + jnl-config resolution. Takes &Journal.
  src/media.rs      Data Saver: image downsampling (image crate), video/audio
                    via the ffmpeg CLI, HEIC→JPEG, the per-device ledger (reads
                    both sidecars, writes .quire/). Path-based: local only.
  src/search.rs     the search grammar shared with Nook's SearchQuery.swift and
                    the Linux app's parseQuery — keep the three in step
  src/stats.rs      streaks, on this day, year stats (Look back), jnl's `stats`
  src/editing.rs    ↩ in a list, wrap toggling, word_at — the editor macros
  src/settings.rs   ~/.config/quire/settings.json, shared by Linux and the TUI
  src/prompts.rs    Nook's PromptDeck; prompt_of_day
  src/themes.rs     Theme struct + themes()/theme(id)/rgb/mix
tui/                quire-tui: lib + two bins (src/bin/quire.rs, src/bin/jnl.rs)
  src/lib.rs        args, folder resolution, jnl-compatible dispatch
  src/app.rs        App state, screens, every key
  src/ui.rs         drawing (ratatui)
  src/editor.rs     the composer buffer: wrapping, caret, macros
  src/md.rs         markdown styled in place, one Style per char
  src/paste.rs      clipboard images (arboard), dropped-path detection
  src/cli.rs        the printed commands (jnl parity)
  src/theme.rs      Palette from a Theme; truecolor or nearest-256
linux/              the Tauri app
  src-tauri/src/lib.rs   commands = thin calls on the Journal; watcher; backups
  src/app.js, style.css, index.html, prompts.js   the front end (no build step)
bindings/           quire-bindings: UniFFI callback Vault + native journal API;
                    JSON transports existing core values, closed request enum;
                    `bindgen` feature builds the Swift generator, not on devices.
apple/              Quire SwiftUI app + widget/share extensions from Nook
  Quire/Models/     JournalStore façade, CoreJournal adapter, AppleVault with
                    NSFileCoordinator; parser/search/list adapters call Rust.
  gen_pbxproj.py    deterministic app + extensions + hostless test project
  build-core.sh     generated Swift/C bindings + macOS/iOS/simulator XCFramework
  Tests/            parser/search checks and journal integration XCTest
  README.md         Mac build, signing, data flow and verification status
tools/
  migrate_journal.py   inbox.md → inbox/, .nook/ → .quire/, from outside the app
  drive_tui.py         pseudo-terminal smoke test of every screen (make smoke)
  make_icon.swift      (Nook's) icon generator
sample/             the sample journal (new layout)
docs/consolidation-plan.md   the plan, decisions, and the TUI spec
```

## Shells

- **Linux** (`linux/`): Tauri 2. `lib.rs` keeps settings (via
  `quire_core::Settings`), the folder watcher, backup scheduling, the
  clipboard, and media glue; everything else is `root(&state)?` → a
  `Journal` → one core call. `load()` folds a legacy `inbox.md` first and
  reports it in the snapshot (`migration`, `migration_error`). The front end
  keys everything off `entry.source` ("inbox" | "journal" | "split") and
  `entry.file`, so day files under `inbox/` needed no view changes. Needs
  `libwebkit2gtk-4.1-dev` to build; `cargo build -p quire-desktop` builds it
  (the desktop binary is `quire-desktop`, so it never collides with the
  terminal's `quire` in the workspace target or on PATH).
- **Terminal** (`tui/`): ratatui 0.30 + crossterm 0.29. Screens: Today,
  Inbox (review), Browse (year/month/day/entries + Main/split/all picker),
  Write, Look back, Search; a help overlay; a one-line modal for date & time
  and confirmations. Autosave 700 ms after the last keystroke, on Esc, and
  on quit. Mouse: `ui` records a `Hit` for each clickable cell as it draws
  (`App::hits`, last drawn wins); `app` turns clicks and the wheel into the
  same actions as keys. F2 toggles capture (`terminalMouse`). Bracketed paste
  is on: dropped media paths and `^v` clipboard images go through
  `extras::attach_media` / `attach_bytes` (`src/paste.rs`).
  `backup.rs` schedules background backups using shared interval/retention settings;
  monthly is 30 days, change waits 30 seconds with a five-minute floor. Maintenance
  workers share the backup guard and suspend editing until complete. Settings also
  exposes imports, tag review/rename, media compression and conflict/split merging.
  The version/build commit is shown in Settings and `--version`.
  Non-tty invocations print (jnl parity). The design the screens
  follow is on the canvas linked from the plan's section 8.
- **Apple** (`apple/`): iOS 17 / macOS 14 SwiftUI. `JournalStore` remains the
  `@MainActor` façade; journal reads and writes call `quire-bindings` / UniFFI.
  `AppleVault` coordinates storage and rejects paths outside the chosen folder.
  Each edit carries `(file, index, raw)` and adopts Rust's returned reference.
  Native media, backup, bookmarks, watchers, widgets, sharing and reminders
  remain Swift. `make apple` builds the Rust XCFramework and both unsigned apps;
  `make apple-test` runs hostless XCTest. Requires macOS, full Xcode and rustup.
  The Apple workflow covers these commands; no Apple SDK build has run on this
  Linux host. Generated bindings/frameworks are ignored, never hand-edited.
  iOS external-display presentation follows the active entry/editor or browse list;
  `ExternalTheme` loads the bundled root `themes.json`. Option-Command +/- changes
  size, T theme, P pause, H hints. Locked/paused displays never render journal text.
- **Android**: not in the repo yet; Wander's Compose shell over a SAF `Vault`.

## Releases

Quire ships tagged releases. A release lives on GitHub Releases at
`Caddickbrown/Quire`: the tag, the CHANGELOG notes, and prebuilt files.
**Linux first**; macOS and Apple builds come later.

- **Version** is `MAJOR.MINOR.PATCH`, one number for the whole workspace:
  `Cargo.toml` (`[workspace.package]`), `linux/src-tauri/Cargo.toml`,
  `linux/src-tauri/tauri.conf.json` and `linux/package.json` always match. A minor bump for a feature or format
  change, a patch for fixes only.
- **Cutting one**: on `main`, rename `## [Unreleased]` in `CHANGELOG.md` to
  `## [x.y.z] — YYYY-MM-DD`, open a fresh `[Unreleased]`, bump the four
  version fields, run `make test`, `make check` and `make smoke`, commit
  "Release x.y.z", then tag `vx.y.z` on that commit and push the tag. Tags are
  never moved or reused; a bad release is fixed by the next patch.
- **Pipeline** (`.github/workflows/release.yml`): pushing a `v*` tag checks
  the tag against the four version fields and that CHANGELOG has the
  section, then
  builds on Ubuntu 22.04 x86_64 and arm64 and publishes the release with the
  CHANGELOG section as notes:
  `quire-<target>.tar.gz` (+ `.sha256`) holding `quire` and `jnl`, and the
  desktop app as `Quire_<v>_<arch>.AppImage`, `.deb` and `.rpm` (+
  `SHA256SUMS-desktop-<arch>`). Asset names for the terminal app carry no
  version, so `releases/latest/download/quire-<target>.tar.gz` is stable.
- **Terminal updates**: `quire update` (also `jnl update`; `--check` only
  reports) reads the latest release from the GitHub API, compares its tag
  with `CARGO_PKG_VERSION`, downloads the tarball for the target baked in as
  `QUIRE_RELEASE_TARGET`, checks the SHA-256 and renames the new binaries over
  the old ones (`tui/src/update.rs`). A build without `QUIRE_RELEASE_TARGET`
  came from source and is told to re-run `install.sh`.
- **Desktop updates**: Settings → About → Updates. The AppImage updates itself
  through `tauri-plugin-updater` (signature-checked, then restart); a .deb or
  .rpm (`QUIRE_RELEASE` set at build) only says a new version is out, as the
  package manager owns it. The updater reads `latest.json` from the latest
  release and checks it against `plugins.updater.pubkey` in tauri.conf.json;
  with an empty pubkey the check is disabled. Signing needs the repo secrets
  `TAURI_SIGNING_PRIVATE_KEY` (+ `_PASSWORD`); without them the release still
  builds but has no `latest.json`. One-time setup: `cd linux && npx tauri
  signer generate -w ~/.tauri/quire.key`; the public key goes in
  `plugins.updater.pubkey` (committed), the private key and its password in
  the two secrets. Lose the private key and existing AppImages can never
  verify another update. The plugin is built without its `zip`
  feature (Windows/macOS only; every zip 2.x/4.x is yanked).
- **Never automatic**: both shells check only when asked. A journal app
  doesn't phone home on its own.
- `install.sh` still builds from source; using the release tarballs there
  is the next step.

## Conventions

- **Update `CHANGELOG.md` in the same change that ships the work** — a bullet
  under `## [Unreleased]`, nook's format (see the file's header). Releases are
  cut from it as described under Releases.
- **The core never touches `std::fs` for entry files or sidecars.** Go
  through the `Journal`/`Vault`. Media and backups are the exception and say
  so (`j.local()?`).
- **Keep the parser jnl-faithful.** `journal::tests::jnl_parity_cases` ports
  jnl's `main_test.go`; add a case there when you touch parsing. The search
  grammar's cases are shared with Nook's Swift and Rust ports.
- **Themes live in `themes.json` only.** The Linux CSS still carries a copy
  of the tokens for now; when you change a colour, change both until the
  CSS is generated from the JSON.
- **Format and layout are decided**: `inbox/YYYY/MM/DD.md`,
  `split/<tag>/YYYY/MM/DD.md`, `.quire/`. `journal/` stays where jnl puts it.
  Don't add a third sidecar name, a second place for drafts, or a second
  place for split journals.
- `make test` (core, TUI and bindings tests), `make check` (clippy, keep it clean; it covers
  the desktop app too where WebKitGTK is installed), `make smoke`
  (the pty driver, must pass 23/23 at 100×30 and 80×24) before a push.
- The one-line Tauri rule from before still holds: the Linux frontend has
  no build step; keep it that way.
