# Quire

One journalling app over a plain folder of markdown. jnl's format, Nook's
features, Wander's care — Linux and terminal apps, plus a native iOS/macOS
SwiftUI shell over the Rust core (awaiting its first Apple SDK build). Android
comes next.

Everything that is not a window lives in one Rust core. Every shell is a
thin native face over it.

```
Quire/
  core/        quire-core: the format, the store, search, stats, media,
               maintenance — behind a Vault so no shell opens a file itself
  tui/         quire in the terminal; installed as `quire` and as `jnl`
  linux/       the Tauri 2 desktop app (Rust glue + HTML/CSS/JS, no build step)
  themes.json  the looks, one source for every shell
  tools/       migrate_journal.py (inbox.md → inbox/, .nook/ → .quire/), the
               pseudo-terminal smoke test, the icon generator
  sample/      a sample journal the Linux app opens on first launch
  docs/        the consolidation plan: what came from where, and what is next
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
by default.

## Native iOS and macOS

The SwiftUI app is in [`apple/`](apple/README.md), brought over from Nook and
connected to Quire's Rust core. On a Mac with Xcode and rustup, run `make apple`
and `make apple-test`. Apple SDK compilation and device testing are still
pending; the Linux checks verify the Rust bridge and project wiring.

## Installing

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
  against its published SHA-256, and checks it runs: the terminal app into
  `~/.local/bin` (onto your PATH if it isn't; `quire update` keeps it
  current), the desktop app as the AppImage + launcher entry, which updates
  itself from Settings › About. An installed .deb/.rpm is offered the switch;
  `fuse3` and optionally ffmpeg + HEIC tools are offered when missing.
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
  have no Quire equivalent yet). Removed apps go to the Trash (or
  `~/.local/state/quire/`), never `rm`. Journal folders, jnl's config, and
  any settings folder holding a journal are never touched.

Without a checkout:
`curl -fsSL https://raw.githubusercontent.com/Caddickbrown/Quire/main/install.sh | bash`.

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
| Review | `↑↓` drafts · `f` file · `e` edit · `*` star · `t` date & time · `d` delete |
| Browse | `← →` columns · `↑↓` move · `↵` open · `/` filter · `s` main / split / all · `u` return to inbox |
| Write | `^j` file · `^s` save · `^t` date & time · `^f` focus · `^p` prompt · `^o` timer (start · pause · resume, `alt-o` resets) · `^b ^i ^g` bold / italic / code · `@` tag autocomplete · `↹` indent · `↵↵` ends a list · `^v` paste (a clipboard image is attached) · `esc` back (saved) |
| Look back | `← →` year |
| Anywhere | `?` or `F1` keys · `esc` back |

The folder is `--folder`, else `$JNL_DIR`, else Quire's settings, else
jnl's config, else `~/notes`. The theme is Quire's setting or `--theme`
(`almanac broadsheet linen cinema night marathon marathon-day`).

## Linux

```sh
cd linux && npm install && npx tauri build      # → linux/src-tauri/target/release/bundle/
```

`linux/README.md` has the features, the themes, and the keys.

## Building and testing

```sh
make test        # Rust core, terminal app and native bindings tests
make check       # clippy
make smoke       # drive the terminal app through every screen in a pseudo-terminal
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
