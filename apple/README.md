# Quire for iOS and macOS

The native SwiftUI shell brought over from `../nook`, renamed to Quire, with
journal storage replaced by Quire's Rust core. Minimum iOS 17 / macOS 14.
Use current Xcode with Swift 5.10 or newer (`nonisolated(unsafe)` is used by
the inherited AVFoundation implementation).

## Build on a Mac

Install full Xcode, select it with `xcode-select`, and install Rust via rustup.
From the repository root:

```sh
make apple       # Rust XCFramework, generated bindings/project, macOS + iOS Simulator
make apple-test  # hostless XCTest against the Rust core on macOS
```

Or `make -C apple open` prepares the Rust library and opens
`Quire.xcodeproj`. Select Quire and a Mac, simulator or connected iPhone.
After changing Rust, run `make -C apple core` again before building in Xcode.
The project is generated: edit `gen_pbxproj.py`, then `make -C apple project`.
Generated Swift/C bindings and compiled libraries are ignored, and recreated
by `build-core.sh`; there is no dependency on files in the Nook checkout.

`build-core.sh` builds arm64 + x86_64 macOS, arm64 iOS devices, and arm64 +
x86_64 iOS simulators. The app and hostless test bundle both link that
static XCFramework and compile the same generated UniFFI Swift bindings.
The CLI binding generator is a separate Cargo feature, excluded from device
library builds. `python3 tools/validate_apple.py` checks project wiring on Linux.
The Apple GitHub Actions workflow builds both apps and runs macOS XCTest.

For signed builds, choose your team for the app, widget and share extension.
Provision `iCloud.com.caddickbrown.quire` and `group.com.caddickbrown.quire`
on that account. These are Quire's own containers; existing Nook documents
are opened by choosing their folder in Settings. The shell retains Nook's
fonts and initial visual design; adopting Quire's shared theme system is a
separate visual pass.

## Data flow

`SwiftUI → JournalStore → CoreJournal → UniFFI → quire-core → AppleVault`.

`JournalStore` owns the security-scoped bookmark and iCloud watcher, publishes
view state, and supplies native media transcoding, backups, reminders,
Spotlight, app lock, Live Activity, widgets, share handoff and external display.
The Rust core parses entries, searches, continues lists, migrates legacy
files, saves/retimes/deletes entries, files/unfiles drafts, handles split tags,
imports prepared entries, runs cleanup, manages templates and saved searches,
and determines orphan media. There is no Swift journal parser or Swift
read-modify-write store in parallel with Rust.

`AppleVault` coordinates reads, atomic replacements, deletions and renames with
`NSFileCoordinator` within the folder access held by the store. It rejects
paths that escape the root, including symlinks. It exposes no local filesystem
path to Rust, so the Rust ffmpeg and filesystem backup paths cannot run on iOS.
Native media and backup code retain real URLs. An unavailable or downloading
file reports an error; it must not become an empty snapshot or overwrite.

Entries retain Rust's `(file, index, raw)` reference through every save. A
successful edit adopts the exact reference returned by Rust; a stale edit is
rejected. The native shell uses `inbox/YYYY/MM/DD.md`,
`journal/YYYY/MM/DD.md`, `split/<tag>/YYYY/MM/DD.md`, and `.quire/`. Old
`inbox.md`, `<tag>.md`, and `.nook/` follow the core's existing migration rules.

## Verification status

Rust bridge tests run on Linux, including callback storage, migration,
stale-index relocation, stale-raw rejection, retiming, and unreadable data.
The Swift sources, plist files and generated project can be checked here.
This port has not yet been compiled with Apple SDKs or tested on a device;
Xcode/Swift are absent on the development host. A green Apple workflow or a
successful `make apple && make apple-test` is required before treating the
native app as build-verified. iCloud, widgets, share capture, media capture
and device signing also require a signed-device check.

The imported Swift sources retain Nook's MIT notice in `LICENSE.nook`; Lato's
font license is included in `Quire/fonts/OFL.txt`.
