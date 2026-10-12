# Quire

One journalling app over a plain folder of markdown. jnl's format, Nook's
features, Wander's care — on Linux today, in the terminal today, on iOS and
macOS next, Android after.

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
  <tag>.md                 split journals (jnl's JNL_SPLIT_TAGS)
  transfer.md              jnl's batch file; Quire files it from Today or Settings
  assets/YYYY/MM/…         photos, audio, video, files
  .quire/templates/*.md    templates
  .quire/searches.json     saved searches
  .quire/datasaver-*.json  Data Saver ledgers, one per device
  .quire/migration/        the inbox.md Quire folded into inbox/, kept
```

Each entry is a timestamp header and a body:

```
[2026-05-10 08:00:00] Optional title *
Body text here. @tags live inline. A trailing * on the title stars it.
```

Writes are atomic (temp file and rename). A journal written by jnl or Nook
opens as it is: an `inbox.md` is folded into `inbox/` on first open (every
draft verified before the original is moved, never deleted), and `.nook/`
is read until the first write renames it `.quire/`. jnl and Nook will not
see drafts in `inbox/` until taught to; `tools/migrate_journal.py` does the
same move from outside the app, dry run by default.

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
| Write | `^j` file · `^s` save · `^t` date & time · `^f` focus · `^p` prompt · `^o` timer · `^b ^i ^g` bold / italic / code · `@` tag autocomplete · `↹` indent · `↵↵` ends a list · `esc` back (saved) |
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
make test        # cargo test: the core and the terminal app
make check       # clippy
make smoke       # drive the terminal app through every screen in a pseudo-terminal
make tui         # a release build of quire and jnl into target/release/
make linux       # the Tauri bundle (needs libwebkit2gtk-4.1-dev; see linux/README.md)
```

## Where it came from

[jnl](https://github.com/Caddickbrown/jnl) is the format and the reference
parser; its tests are the parity suite the core passes.
[Nook](https://github.com/Caddickbrown/nook) is the feature set, and the
Swift the Apple shell will be built from. [Wander](https://github.com/Caddickbrown/Wander)
is where the care came from, and a library of looks to Quire-ify one at a
time. `docs/consolidation-plan.md` is the plan.
