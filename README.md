# wander

A journal and writing app. Entries are plain markdown in the jnl layout, so the
same folder opens in any of the three builds — or in the `jnl` CLI, or in Nook.

```
<journal>/journal/YYYY/MM/DD.md   one file per day
<journal>/inbox.md                undated drafts
```

An entry is a `[YYYY-MM-DD HH:MM:SS] optional title` header line and its body.
A trailing `*` on the title means starred; `@tags` live inline. Nothing else is
stored — no database, no sidecar files.

## The builds

| | where | how |
|---|---|---|
| macOS | `Sources/Wander` | `./build.sh --run` |
| iOS / iPadOS | `Sources/WanderiOS` | `xcodegen generate && open Wander.xcodeproj` |
| Linux, Windows, macOS | `tauri/` | `cd tauri/src-tauri && cargo run` |

`Sources/WanderCore` is the shared Swift core — the model, the jnl parser and
every file operation — used by both Apple builds. The Tauri build carries its
own port of the same format in `tauri/src-tauri/src/journal.rs`; the two are
kept byte-compatible on purpose, so a folder written by one reads identically in
the other.

SwiftUI doesn't run on Linux, which is why the Linux build is a Tauri app rather
than a port. It is drawn to match: the same palette, the same rules, Newsreader
and IBM Plex Sans bundled so it looks the same on a machine that has neither.

## Where the journal lives

An explicitly chosen folder, else `$JNL_DIR` (so an existing jnl or Nook journal
opens as-is), else `~/Documents/Wander`. Change it in Options ▸ Folder.

## The look

Warm paper `#f6f2ea`, ink `#171310`, terracotta `#9c3220`, hairline rules and
small-caps labels — an almanac page rather than an app window. Newsreader sets
anything that reads as writing; IBM Plex Sans sets anything that reads as
apparatus. The dark palette is the same hue family, inverted.

Markdown is styled where you type it — no preview pane. Headings take the
display serif, quotes go italic and indent, code takes a tinted monospace, and
the markers themselves fade to a hairline grey.

## Keys

| | |
|---|---|
| `⌘N` / `⌘⇧N` | new entry / new draft |
| `⌘1` `⌘2` `⌘3` | journal / inbox / starred |
| `⌘J` | file a draft, or return an entry to the inbox |
| `⌘D` / `⌘⇧D` | star / change date & time |
| `⌘F` | find |
| `⌘\` `⌘⇧\` `⌘⌥\` | index / stats / options columns |
| `⌘⇧F` | focus mode |
| `⌘B` `⌘I` | wrap the selection |

## Icon

`swift tools/make_icon.swift` redraws it — the wordmark's own "w" over the
masthead rule, in paper and in ink. The Mac app swaps the Dock icon to match the
appearance it is drawing in.
