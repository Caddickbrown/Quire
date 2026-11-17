# Words

Tone belongs to each app. These shapes don't.

## Errors

Say what failed, then what it means for the person's data, then what they can do.

| Good | Avoid |
|---|---|
| Couldn't reach the server. Nothing was added. **Retry** | Error 503 |
| Couldn't save the photo. The note is saved without it. **Try again** | Something went wrong |
| The server didn't accept the token. **Open settings** | Unauthorized |

Never leave someone guessing whether their work was kept.

## Empty states

One sentence on what the place is for, then the one action that fills it.

> Nothing here yet. Notes you capture land here first. **New note**

## Relative dates

Implemented once in `kit/js/relative-date.js` and once in
`kit/swift/RelativeDate.swift`. Both pass `kit/vectors/relative-date.json`.

| Age | Reads |
|---|---|
| Under a minute (either way) | just now |
| Under an hour | 5 min ago |
| Earlier today, or later today | 14:02 |
| Yesterday | Yesterday 14:02 |
| 2–6 days ago | Tue |
| Older, this year | 12 Oct |
| Older, another year | 12 Oct 2025 |

Days are calendar days in the reader's time zone. The words are fixed English,
24-hour time, day before month.

## Timestamps

Anything stored or sent between client and server is UTC, written
`YYYY-MM-DDTHH:MM:SSZ`. Formatting for people happens at the edge, with the
helpers above.

## Server connection

An app that talks to a self-hosted server has one settings block, in this order:

1. **Server**: the address, editable.
2. **Token**: masked, editable.
3. **Test connection**: a secondary button; the result appears inline.
4. The status line.
5. **Sync now**: the primary button.

The status line comes from `SyncStatus` (Swift) or `statusLine` (JS), both
tested against `kit/vectors/sync-status.json`:

| State | Line | Colour role |
|---|---|---|
| Connected | Connected · Last synced 2 min ago | `done` |
| Syncing | Syncing… | `inkSecondary` |
| Unreachable | Couldn't reach the server. Your changes are safe on this device. | `late` |
| Unauthorised | The server didn't accept the token. | `late` |
| Never connected | Not connected | `inkSecondary` |

Outside this block, a server is named only in one line when it has stopped.
