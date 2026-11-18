# Keys

Apps with a keyboard layer share one map, so the same fingers work everywhere.
The machine-readable copy is `keymap.json`.

- An app declares which actions it supports and leaves the rest unbound.
- It never gives a shared key a different meaning.
- Unassigned letters (`u` among them) are free for app-specific actions.
- Single-letter keys act only on the list in front of you, and never while
  text is being typed or a sheet is up.
- On a desktop, section and global keys carry ⌘ (Ctrl elsewhere).

| Key | Action | Notes |
|---|---|---|
| ↑ ↓ / j k | Move through the list | |
| ↵ | Open | |
| esc | Back, close, cancel | ⌘. too, on iOS: `kit/swift/FieldEscape.swift` |
| 1–9 | Jump to section | ⌘ on desktop |
| [ ] | Previous / next group | Whatever the app groups by: a status, a folder, a list |
| x | Done | |
| a | Archive | |
| b | Snooze | |
| p | Priority | |
| n | New | ⌘N on desktop |
| / | Search | ⌘K on desktop |
| r | Refresh | |
| ⌘Z | Undo | The platform standard; every app supports it |
| ? | Show all keys | |
| ⌥⌘ = / ⌥⌘ − | External display text size | |
| ⌥⌘P | Pause external display | |

In a form: tab moves to the next field, ↵ saves, esc cancels.

## In the ⌘K palette

`specs/PALETTE.md` has the whole model; these are the keys inside it.

| Key | Action | Notes |
|---|---|---|
| ⌘K | Open, or close from anywhere | |
| ↑ ↓ ⇥ ⇧⇥ | Move | Page Up/Down, Home/End, ⌘↑ ⌘↓ too |
| ↵ | Go; in a typed step, commit; in a confirm, confirm | |
| esc | Back one step; at the top, close | ⌘. too |
| ⌫ | A letter; with the box empty, back one step | |
| ⌥⌫ | A word | 0.9 |
| ⌘⌫ | Empty the box (type afresh over a prefilled name) | 0.9 |
| ⌘V | Paste into the box | 0.9 |
| Space | In a multi pick: tick or untick the lit option | 0.9 |
| ↵ or ⌘↩ | In a multi pick: Done, with what's ticked | 0.9 |
| ⌘Z | Undo what the latest Undo notice offers, while it shows | 0.9; an app's own ⌘Z comes first |
