# Nook

A native **iOS + macOS** journaling app built with SwiftUI. Write freely into a
distraction-free composer; drafts collect in an **inbox**, then you **file** them
into a date-organised **archive**. Everything is plain markdown in an **iCloud
Documents** container, so it syncs across your devices and stays readable by hand.

Nook grew out of [freewrite](https://www.freewrite.io/) (the writing feel) and
the [`jnl`](../jnl) CLI (the inbox → archive model). Its on-disk format is
byte-compatible with `jnl` — point `JNL_DIR` at Nook's folder and use both.

## Build

```sh
make project     # generate Nook.xcodeproj from gen_pbxproj.py
make build       # xcodebuild for macOS + iOS Simulator (unsigned)
make check       # verify the parser matches jnl semantics
open Nook.xcodeproj
```

The Xcode project is **generated** — never hand-edit `project.pbxproj`; edit
`gen_pbxproj.py` and run `make project`.

## iCloud

Data lives in the app's iCloud ubiquity container (`Documents/`), falling back to
local `~/Documents/Nook` when iCloud is unavailable. To ship a signed build,
enable **iCloud → iCloud Documents** on the target in Xcode and select the
`iCloud.com.caddickbrown.nook` container.

## Layout

```
inbox.md                 unfiled drafts
journal/YYYY/MM/DD.md     filed entries, one file per day
```

Each entry: `[YYYY-MM-DD HH:MM:SS] optional title` + body, with `@tags`.

See [CLAUDE.md](CLAUDE.md) for the full architecture and
[CHANGELOG.md](CHANGELOG.md) for what has changed.
