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
