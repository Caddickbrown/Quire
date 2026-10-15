# Changelog

All notable changes to Quire — the core, the terminal app and the Linux app —
are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

**How to update this file**

- Add a bullet under `## [Unreleased]` in the same change that ships the work.
- Buckets, in this order, omitting the empty ones: `Added` · `Changed` ·
  `Fixed` · `Removed` · `Deprecated` · `Security`.
- One line per user-visible change, present tense, what the user gets. Lead
  with the area in bold (**Terminal**, **Linux**, **Core**, **Format**, …).
- Call out anything that changes the on-disk format explicitly — the files
  are shared with jnl, Nook and hand-editing users.
- On release: rename `[Unreleased]` to `## [x.y.z] — YYYY-MM-DD`, bump the
  workspace version in `Cargo.toml` and `linux/src-tauri/tauri.conf.json` +
  `linux/package.json`, and open a fresh `[Unreleased]`.

---

## [Unreleased]

### Added
- **Install**: `install.sh` for Linux and macOS asks for the terminal app,
  the desktop app, or both; finds jnl, Nook and Wander and the journal
  folders they use; backs the chosen journal up; installs what the build
  needs (Rust, WebKitGTK via apt/dnf/pacman/zypper, Tauri's CLI, optionally
  ffmpeg); builds, installs and checks Quire; points it at the journal and
  moves `inbox.md` drafts into `inbox/`; then offers to remove the old apps
  (to the Trash, never deleted; journal folders are never touched).
  `--dry-run` shows every command first; `--uninstall` removes Quire.
  With Quire already installed it offers to build nothing and only retire
  the old apps (`--tidy`), counts what's installed when choosing removal
  defaults, and says when old apps have already stopped seeing drafts.
- **Core**: `quire-core`, one Rust crate every shell shares — the jnl format,
  the store, search, stats, media, maintenance — behind a `Vault` trait so
  the core never opens a file itself (the Apple shell will coordinate writes;
  Android will use the Storage Access Framework).
- **Terminal**: Quire in the terminal, installed as both `quire` and `jnl`.
  Today, Review, Browse (with the Main / split journal / all picker), Write
  (markdown styled where you type, focus, `@` autocomplete, list
  continuation, autosave), Look back (heat strip, words a month, tags, when),
  Search. Every jnl subcommand keeps its spelling and prints jnl's text when
  piped. Themes follow `themes.json`.
- **Format**: drafts live in `inbox/YYYY/MM/DD.md`, the journal's own shape.
  Retiming a draft moves it between inbox days as it moves filed entries
  between journal days; a day file that empties is deleted.
- **Format**: a legacy `inbox.md` is folded into `inbox/` on open — every
  draft verified first, the original kept under `.quire/migration/` — and
  merged again if an older app rewrites it. `tools/migrate_journal.py` does
  the same from outside the app (dry run by default).
- **Themes**: `themes.json` at the repository root, one source for every
  shell: Almanac, Broadsheet, Linen, Cinema, Night, Marathon, Marathon Day.
- **Terminal**: `quire migrate`, `quire import` (drafts from stdin).
- **Tooling**: `make smoke` drives the terminal app through every screen in a
  pseudo-terminal and checks the files it writes.

### Changed
- **Format**: the sidecar is `.quire/` (templates, saved searches, Data Saver
  ledgers). `.nook/` is read while only it exists and renamed on the first
  write; ledgers are read from both. Nook stops seeing templates and saved
  searches after the move — run one app per journal until Nook is retired.
- **Linux**: the app moves under `linux/` and runs on the core; its commands
  are thin calls on the shared store. `file_draft` now takes the draft's
  file. Opening a journal reports an inbox migration as a toast.
- **Linux**: the bundled sample journal is on the new layout.
- **Linux**: the desktop binary is `quire-desktop` (the package name), so it
  no longer shares a name with the terminal's `quire`.
- **Repository**: a Cargo workspace (`core`, `tui`, `linux/src-tauri`);
  `README.md` describes the whole, `linux/README.md` the desktop app.

### Removed
- **Linux**: the presentation window branch (a second desktop window
  mirroring the composer) is parked, not merged.

## [0.6.2] — 2026-10-09
The Linux-only app, as released before the consolidation. See `linux/README.md`.
