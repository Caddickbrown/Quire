# Quire

One journalling app over a plain folder of markdown. jnl's format, Nook's
features, Wander's care — Linux and terminal apps, plus a native iOS/macOS
SwiftUI shell over the Rust core, running on an iPhone and iPad in Quire's own
design. Android comes later.

Everything that is not a window lives in one Rust core. Every shell is a
thin native face over it.

```
Quire/
  core/        quire-core: the format, the store, search, stats, media,
               maintenance — behind a Vault so no shell opens a file itself
  tui/         quire in the terminal; installed as `quire` and as `jnl`
  linux/       the Tauri 2 desktop app (Rust glue + HTML/CSS/JS, no build step)
  apple/       the SwiftUI app, widgets and share extension, over the Rust core
  bindings/    UniFFI bindings to the core, for the Apple shell
  themes.json  the looks, one source for every shell
  tools/       migrate_journal.py (inbox.md → inbox/, .nook/ → .quire/), the
               pseudo-terminal smoke test, the installer's dry-run tests, the
               icon generator
  sample/      a sample journal the Linux app opens on first launch
  docs/        the consolidation plan: what came from where, and what is next
  legacy/      Nook and Wander, the apps Quire replaced, kept for reference;
               nothing here is built or shipped
```

## The folder

```
<folder>/
  inbox/YYYY/MM/DD.md      drafts, one file per day
  journal/YYYY/MM/DD.md    filed entries, one file per day
  split/<tag>/YYYY/MM/DD.md split journals (jnl's JNL_SPLIT_TAGS), one file per day
  transfer.md              jnl's batch file; Quire files it from Today or Settings
  assets/YYYY/MM/…         photos, audio, video, files
  .quire/templates/*.md    templates
  .quire/searches.json     saved searches
  .quire/datasaver-*.json  Data Saver ledgers, one per device
  .quire/migration/        the inbox.md and <tag>.md files Quire folded in, kept
```

Each entry is a timestamp header and a body:

```
[2026-05-10 08:00:00] Optional title *
Body text here. @tags live inline. A trailing * on the title stars it.
```

Writes are atomic (temp file and rename). A journal written by jnl or Nook
opens as it is: an `inbox.md` is folded into `inbox/` on first open (every
draft verified before the original is moved, never deleted), a root
`<tag>.md` split journal is folded into `split/<tag>/` the same way, and `.nook/`
is read until the first write renames it `.quire/`. jnl and Nook will not
see drafts in `inbox/` or split entries in `split/` until taught to;
`tools/migrate_journal.py` does the same moves from outside the app, dry run
by default (close Quire before `--apply`).

## Native iOS and macOS

The SwiftUI app is in [`apple/`](apple/README.md), brought over from Nook and
connected to Quire's Rust core. On a Mac with Xcode and rustup, run `make apple`
and `make apple-test`. It builds with Xcode and runs on an iPhone and iPad, in
Quire's own design; the Mac still uses the earlier shell. With a monitor and a
hardware keyboard the phone becomes a desk: the page is on the monitor, the keys
work as in the terminal app, and ⌘K goes anywhere.

## Installing

One line, on Linux (x86_64, arm64) or a Mac (Apple silicon, Intel):

```sh
curl -fsSL https://raw.githubusercontent.com/Caddickbrown/Quire/main/install.sh | bash
```

It downloads the latest release, checks it against its SHA-256 and asks before
each step. On Linux that is the terminal app and the desktop app (the AppImage);
on a Mac the terminal app is downloaded and the desktop app, if you pick it, is
built from source (it needs Rust and Xcode's command-line tools; add `-s --
--tui` after `bash` to skip it). From a checkout:

```sh
./install.sh --dry-run     # see what it finds and every command it would run
./install.sh               # ask before each step
./install.sh --both --yes  # terminal + desktop, every default
./install.sh --uninstall   # remove Quire (journal and settings kept)
```

Also `--tui` / `--gui` to skip the question (`--tidy` when Quire is already installed: build nothing, just retire the old apps), `--folder DIR`, `--bundle
deb|rpm|appimage`, `--keep-old`, `--no-backup`, `--verbose`; `--help` for
the rest. Every step is logged to `~/.local/state/quire/install-<stamp>.log`.

Linux and macOS. It asks what to install: the **terminal app** (`quire`,
and `jnl` with every jnl command as before), the **desktop app**, or
**both**. (On the Mac the desktop app is the Tauri build, a preview until the
Swift Mac app passes its Apple build checks; see `apple/README.md`.) Then, all questions first:

- **Finds** jnl (the Go CLI or the bash script), Nook and Wander — deb/rpm
  packages, AppImages, launcher entries, `.app` bundles — and the journal
  folders they point at, and asks which one Quire opens (the biggest by
  default).
- **Backs up** that journal to `~/quire-preinstall-<stamp>.tar.gz`.
- **Downloads the latest release** on Linux (x86_64, arm64), each file checked
  against its published SHA-256: the terminal app into `~/.local/bin` (onto
  your PATH if it isn't; `quire update` keeps it current), run once before
  anything is replaced; the desktop app as the AppImage + launcher entry,
  which updates itself from Settings › About. The desktop app is checked as a
  file and never started by the installer. An installed .deb/.rpm is offered
  the switch; `fuse3` and optionally ffmpeg + HEIC tools are offered when
  missing. An old `jnl` sitting where Quire's goes is moved aside only once
  Quire's own is downloaded and checked (or built).
- **Or builds from source** with `--build` (and on macOS, or with `--source`
  or `QUIRE_REF`): Rust (rustup), the Xcode command-line tools, WebKitGTK and
  friends via apt / dnf / pacman / zypper, Tauri's CLI (Node if you have it,
  else cargo); the terminal app into `~/.cargo/bin`, the desktop app as a
  .deb, .rpm, AppImage or `Quire.app`.
- **Sets it up**: the folder into Quire's settings; `inbox.md` drafts into
  `inbox/`.
- **Only then removes the old apps**, defaulting to yes for what your choice
  replaces (jnl → terminal; Nook, Wander → desktop) and no for the rest, and
  always no for Nook on the Mac (its widgets, share sheet and iCloud set-up
  have no Quire equivalent yet). Removed apps and their settings go to the
  Trash (or `~/.local/state/quire/`); they are not deleted. The only things
  the installer deletes are its own: its download folder, and the launcher
  entry an earlier Quire left under its old name (`quire.desktop`). Journal
  folders, jnl's config, and any settings folder holding a journal are never
  touched.

**What the checksum proves.** The SHA-256 files are published in the same
GitHub release as the files they describe. A match means the download arrived
whole; it does not prove who built it, since anyone able to replace a release
file could replace its checksum too. The AppImage is also signed with a key
that is not on GitHub, and the desktop app checks that signature every time it
updates itself from Settings › About. `install.sh` checks the SHA-256 only.
Releases built by the current pipeline put a `.sig` beside each AppImage and
each terminal tarball (the updater's key; base64 of a minisign signature), so
the stronger check can be made by hand; `quire update` always makes it, and
refuses a release that has no signature (the release pipeline won't publish
one without).

## The terminal

```sh
cargo install --path tui        # installs quire and jnl
quire                           # Today: words, streak, on this day, a prompt, the inbox
quire new "A title"             # write; ^j files it
quire review                    # one draft at a time
quire browse                    # year · month · day · entries; s cycles split journals
quire stats                     # Look back on a terminal, jnl's text in a pipe
quire search tag:work after:2026-03 "exact phrase"
jnl log 2026-09-30              # every jnl command keeps its spelling
```

| Screen | Keys |
|---|---|
| Today | `n` new · `↵` write from the prompt · `p` another · `i` inbox · `j` journal · `l` look back · `/` search · `r` random · `q` quit |
| Review | `↑↓` drafts · `space` / `PgUp` read on / back · `f` file · `e` edit · `*` star · `t` date & time · `d` delete |
| Browse | `← →` columns · `↑↓` move · `space` / `PgUp` read on / back · `↵` open · `/` filter · `s` main / split / all · `u` return to inbox |
| Write | `^j` file · `^s` save · `^t` date & time · `^f` focus · `^p` prompt · `^o` timer (start · pause · resume, `alt-o` resets) · `^b ^g` bold / code (`^i` italic, where the terminal can tell it from `↹`) · `@` tag autocomplete · `↹` indent · `↵↵` ends a list · `^v` paste (a clipboard image is attached) · `esc` back (saved) |
| Look back | `← →` year |
| Anywhere | `?` or `F1` keys · `esc` back (it never quits; `q` on Today does) · questions take `y` only |

The folder is `--folder`, else `$JNL_DIR`, else Quire's settings, else
jnl's config, else `~/notes`. The theme is Quire's setting or `--theme`
(`almanac broadsheet linen cinema night marathon marathon-day`).

`quire cleanup` formats, sorts and deduplicates entries, removes `.DS_Store`
files, and checks media links. Older assets are organised into `assets/YYYY/MM/`
using the earliest referencing entry; existing monthly assets stay put. Changed
markdown and original media are preserved under `.quire/media-cleanup/` for 30
days; older recovery folders are removed the next time cleanup or orphan
clearing runs.
Missing or ambiguous links are reported rather than guessed. At the end, an
interactive terminal asks whether to clear orphan media: Enter keeps it; yes
moves it out of `assets/` with verified recovery copies in the same recovery
area. Piped or unattended runs always keep orphan media.

The **Media Library** is a primary tab on Linux (`Ctrl+6`). On iPhone and iPad, use
the icon in the Today or Journal masthead, or the link in Settings; on the Mac, the
sidebar.
Search filenames, filter photos/video/audio (and files or orphans on Linux), sort
or group by date, preview a file, and use its menu to go to the entry that uses it.

## Linux

The Inbox has its own search. In the editor, long titles wrap on screen while
remaining a single header line in the file, and markdown italics display as you
type. Drafts save after 1.2 seconds without typing and immediately when leaving
or closing; filed entries save on Ctrl+S or when leaving the editor.

```sh
cd linux && npm install && npx tauri build      # → target/release/bundle/ (the workspace's target folder)
```

`linux/README.md` has the features, the themes, and the keys.

## Building and testing

```sh
make test        # Rust core, terminal app and native bindings tests
make check       # clippy, the frontend checks, the Apple project wiring, the installer's dry runs
make check-scripts   # the part of check that needs no Rust build
make smoke       # drive the terminal app through every screen in a pseudo-terminal
make apple-test  # hostless XCTest against the Rust core (macOS with Xcode)
make tui         # a release build of quire and jnl into target/release/
make linux       # the Tauri bundle (needs libwebkit2gtk-4.1-dev; see linux/README.md)
```

## Where it came from

[jnl](https://github.com/Caddickbrown/jnl) is the format and the reference
parser; its tests are the parity suite the core passes.
[Nook](https://github.com/Caddickbrown/nook) is the feature set, and the
Swift used by the Apple shell. [Wander](https://github.com/Caddickbrown/Wander)
is where the care came from, and a library of looks to Quire-ify one at a
time. `docs/consolidation-plan.md` is the plan.

Open Terminal Settings with `,` to choose a backup folder, automatic interval
(Off, Daily, Weekly, Monthly or On change) and the number of copies to keep
(1–50, default 10). Automatic backups are off until configured; monthly means
30 days, and On change waits 30 seconds after changes with a five-minute minimum
between copies. The terminal must be running for its scheduler to run.

`quire --version` prints the version and build commit; Settings shows it too.
`install.sh` installs the latest release; `./install.sh --build` builds the
checked-out source instead (run `git pull` first for newer commits).
See [maintenance coverage](docs/maintenance.md) for the available settings.
