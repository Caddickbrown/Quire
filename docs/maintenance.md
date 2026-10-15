# Maintenance settings

All journal changes use Quire's Rust core; Apple coordinates storage through its Swift Vault. Apple media and backup services remain native.

| Operation | Terminal | Linux GUI | iOS / macOS |
| --- | --- | --- | --- |
| Backup / restore / schedule / retention | Yes | Yes | Yes |
| Clean up / sort inbox / file all drafts | Yes | Yes | Yes |
| Merge retired split journals | Yes | Yes | Yes |
| Clear orphan media / compress existing media | Yes | Yes | Yes |
| Review / rename tags | Yes | Yes | Yes |
| Markdown / Day One import | Yes | Yes | Yes |
| File transfer.md / merge conflict copies | Yes | Yes | Yes |
| Markdown export | Yes | Yes | Yes |
| Print / PDF export | — | System print dialog | Native export |
| Speech transcription / re-transcription | — | — | Native Apple speech |

Terminal maintenance is under Settings (`,`). Long operations run in the
background with editing suspended. Imports show a preview count before writing;
tag review confirms each variant group before merging. Back up before bulk changes.
Native Apple speech permissions and Apple PDF generation remain in Swift.

## iOS external display

Connect an iPhone or iPad to a monitor to show the current writing, reading or
browse view. External-display Settings choose a shared Quire theme and text
size, pause the display, or dim the device independently. Arrow keys move through
the focused list, Return opens, Escape returns, and Command-N starts writing.
Option-Command +/- changes monitor text size, T cycles themes, P pauses, and H
toggles shortcut hints. Locking the journal replaces all monitor content with a
neutral screen; unlocking restores the latest view unless paused.

Apple SDK builds and physical external-monitor testing require a Mac/device;
they cannot be verified on the Linux development host.
