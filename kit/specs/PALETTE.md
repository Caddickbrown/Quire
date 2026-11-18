# The command palette

`swift/CommandPalette.swift`: the ⌘K menu's rules, keys and host. The app supplies the commands and draws the panel in its own design; the kit has no visual components. The rules it serves are in App Kit's `docs/MONITOR.md`: every action is a command, the selected item comes first, follow-up steps stay in the palette, toggles say which way they go, Delete is red with Undo, it works on the monitor, with a keyboard and without one.

The reference app is the Sample App: `ios/Sample/Commands/SampleCommands.swift` (the list) and `ios/Sample/Commands/CommandMenu.swift` (what each command does, and the panel).

## The pieces

| Type | What |
|---|---|
| `CommandList` | The app's menu as a value: `rows(stage:typing:)`, `prompt(stage:)`, `nothing(stage:)`. Built from what's on screen now. |
| `CommandRow<Action>` | One command. `step` is `.run(action)`, `.pick(CommandPick)`, `.ask(CommandAsk)` or the older `.open(stage)`. `keepsSheet: true` runs it over an open sheet. |
| `CommandPick` | A follow-up choice inside the palette: "Theme…" then the theme. Its choices are rows, so they can preview, be red, or lead on to another step. |
| `CommandAsk` | A typed answer inside the palette: "Rename…", "Snooze until…". `make` turns the typing into an action, or nil while it isn't usable. |
| `CommandPalette` | The state: query, sections, rows, the lit row, the steps open, previews. Plain Foundation, so tests build it on a Mac. |
| `CommandRecents` | The commands chosen lately, newest first, kept in the app's UserDefaults and capped. |
| `CommandHost` | iOS: the palette's own window above sheets, its keys, the on-screen keyboard when opened by touch, previews and the sheet gate. |
| `CommandMenuItem` | iOS: "Commands", for the ⋯ menu. |
| `CommandMenuShortcut` | iOS: ⌘K for a screen with nothing focused, and the name iPad lists when ⌘ is held. |
| `CommandSafety` | For an app's tests: `unguarded` (destroys with no question and no Undo) and `unmarked` (sounds destructive, isn't red). Both look inside picks and questions. |

## A row

```swift
CommandRow("item.delete", "Delete", symbol: "trash", step: .run(.delete(id)),
           synonyms: ["remove", "bin"],     // found by these too
           destructive: true,               // drawn red
           undoable: true,                  // the app offers Undo, so it needn't ask
           context: "“Buy milk”")           // acts on the selected item: listed first, under its name
```

- **Synonyms.** Typing matches `search` (the title by default) and each synonym. Words can come in any order and be spread across the title and synonyms: "sepia theme" finds "Theme: Sepia", "vertical" finds Shorts. Accents and case don't matter.
- **Punctuation between words.** `:` `;` `,` `›` `‹` `»` `«` `·` `•` `—` `–` `|` `→` count as spaces, in the typing and in titles and synonyms (`CommandMatch.separators`), so "theme: sepia" and "Status: Review" find the rows titled that way. A full stop, a hyphen, a slash and `…` are still matched as typed: `…` marks a step, so "tag…" is the step "Tag…" rather than any row with "tag" in it.
- **Over a sheet.** Chosen while a sheet is up, a row first leaves the sheet the way Esc does and runs once it has gone. A row that belongs to the sheet (a composer's Send, Attach, Save draft; an editor's actions) says `keepsSheet: true`, and runs at once with the sheet left open. On a pick or a question it covers the choices and the typed answer; on `CommandRow.toggle` it's a parameter too. The palette says so as `menu.keepsSheet` (and `menu.chosen`) after a `.run`, and `CommandGate.step(sheetUp:waited:keepsSheet:)` is the rule. List such rows only while their sheet is up, since the action needs it.
- **Toggles.** `CommandRow.toggle(id, isOn:, turnOn:, turnOff:, states:, symbol:, action:)` makes a row whose title says what choosing it does ("Pause monitor" while showing, "Resume monitor" while paused), with `isOn` and `state` ("Paused") for drawing. Either title finds it.
- **Destructive.** `destructive: true` is drawn red, and needs `confirms` or `undoable`. Destructive rows never go into Recents, so ⌘K then Return can't delete.
- **Context.** Rows with `context` set act on the selected item. With nothing typed they come right after Recents, under that name; typing ranks them a little higher.
- **Preview.** `preview: .theme("sepia")` is done while the row is lit; `revert` (or the pick's `revert`) puts back what was there. The revert is read once, at the first preview, so a list rebuilt mid-preview can't make the previewed theme the one put back. Each pick (or step, for its spread choices) is its own kind: arrowing from "Theme: Sepia" to "Monitor theme: Sepia" puts the app theme back before the monitor previews (0.7.1). Opening the palette never previews: the first key does.

## Steps

```swift
let themes = ["bone", "forest", "ink"].map {
    CommandRow($0, $0.capitalized, symbol: "paintpalette", step: .run(.theme($0)),
               preview: .theme($0), isCurrent: $0 == theme)
}
CommandRow("theme", "Theme…", symbol: "paintpalette",
           step: .pick(CommandPick(prompt: "Which theme?", choices: themes, revert: .theme(theme))))

CommandRow("item.rename", "Rename…", symbol: "character.cursor.ibeam",
           step: .ask(CommandAsk(prompt: "A new name", initial: title, title: { "Rename to “\($0)”" },
                                 make: { $0.isEmpty || $0 == title ? nil : .rename(id, $0) })))
```

- In a pick, the `isCurrent` choice is lit first and should be drawn with a tick.
- Esc backs out one step and puts back any preview; at the top it closes. ⌘K closes from anywhere. ⌫ with the box empty backs out too. Steps nest: a pick's choice can be another pick or a question (Sample's "Move to project…" › "New project…").
- Typing at the top also finds each pick's choices as commands of their own, titled "Theme: Sepia". `searchable: false` on a pick keeps its choices out (Sample does this for projects).
- The older `.open(stage)` still works as before, Esc closing the whole menu from it. Prefer `.pick` for anything new.

## The list with nothing typed

Recent commands first (up to `CommandPaletteLimit.recents`, that are on the list now), then the selected item's commands, then the rest under "Commands". There's no cap: the panel shows `CommandPaletteLimit.rows` (10) and scrolls, and the lit row has to stay in view. ↑↓ wrap round the whole list; Page Up and Down move ten; Home, End, ⌘↑ and ⌘↓ go to the ends.

## The host, on iOS

```swift
let host = CommandHost<MyList>()
host.list = { MyList(state: .current) }        // built the way the tests build it
host.monitorShows = { monitor.isConnected && !monitor.isPaused }
host.perform = { run($0) }                     // what a chosen command does
host.preview = { apply($0) }                   // optional: previews and reverts, without side effects like clearing a selection
host.onHighlight = { row in … }                // optional: the highlight moved
host.onCancel = { … }                          // optional: closed without choosing, after any preview was put back
host.recents = CommandRecents(key: "myapp.commands.recents")   // the default key is fine for one menu per app
host.leaveSheet = { … }                        // close the sheet on top the way Esc does
host.overlay = { AnyView(MyOverlay()) }
CommandResponders.install()
```

- **Without a keyboard:** put `CommandMenuItem()` in the ⋯ menu (or call `CommandRoute.presentMenu()` / `host.present()`). The on-screen keyboard comes up, and `host.byTouch` tells the panel to take taps: rows call `host.choose(row.id)`, and it shows a back button (`host.back()`) once `menu.depth > 0`, and a close button (`host.close()`). On iPad with a trackpad, `.onHover` on a row can call `host.highlight(row.id)` to preview.
- **On the monitor:** when `monitorShows()` is true as it opens, `host.onMonitor` is set and the app draws the panel on the monitor; the phone takes the keys, or shows its keyboard if opened by touch.
- **Refresh** when what's on screen changes (`host.refresh()`), so toggles and the selected item stay right while it's open.

## Drawing the panel

- `menu.sections`: draw each `title` as a small heading when it isn't nil. `menu.rows` is the same rows flat.
- A row: `symbol`, `title` (red when `destructive`), `detail`, `state` for toggles, a tick for `isCurrent`, a chevron when `leads`.
- The box: `menu.opener?.title` before the query when a step is open ("Theme…"), `menu.query`, and `menu.prompt` when it's empty.
- The list: a `ScrollView` inside a `ScrollViewReader`, at most `CommandPaletteLimit.rows` rows high, scrolling to `menu.selected` when it changes.
- Keys: `menu.hints` lists exactly the keys that work now.

## Moving from 0.6.0

Nothing to change: 0.6.1 and 0.6.2 add to 0.6.0. 0.6.2 only puts `…` back to being matched as typed (0.6.1 treated it as a space, so "tag…" could light a row other than "Tag…").

1. **Colons and the like match.** "theme: dark" finds "Theme: Dark" (it found nothing before). A test that typed a colon to show nothing matches should type letters that aren't there instead.
2. **`keepsSheet`.** If the app closed a sheet before running a row by hand, or kept a sheet's actions off the menu because the host would close the sheet, mark those rows `keepsSheet: true` and take the workaround out: the host now runs them over the sheet, and gives the keyboard back to the field that had it. Rows that leave the sheet are unchanged, and `host.leaveSheet` is still what closes it for them.

## Moving from 0.5

Everything 0.5 had still compiles and behaves the same, except as below.

1. **The 10-row cap is gone.** `menu.rows` can be longer than ten. If the panel sizes itself as `rowHeight * rows.count`, cap it: `rowHeight * CGFloat(min(menu.rows.count, CommandPaletteLimit.rows))`, and keep the `ScrollViewReader` scrolling to `menu.selected`. Tests that checked the list stops at ten should check it scrolls instead. `CommandPaletteLimit.rows` is still 10, now meaning "shown before it scrolls".
2. **Recents are on by default in the host** (`host.recents`). The blank list then starts with "Recent" and, if any row has `context`, the item's name: draw `menu.sections` headings. Set `host.recents = nil` to keep the old list. A bare `CommandPalette(list)` in tests has no recents unless given one.
3. **Matching ignores word order** and matches synonyms. Rankings for single words are unchanged.
4. **New keys:** Page Up, Page Down, Home, End, ⌘↑ and ⌘↓ move in the list, and ⌘. is Esc. They were already held from the page behind.
5. **`CommandSafety.unguarded`** now passes `undoable` rows, flags rows marked `destructive` that neither confirm nor undo, and looks inside picks.

Then, for the rules in `docs/MONITOR.md`:

- Add `CommandMenuItem()` to the ⋯ menu on every screen that has one.
- Mark Delete and the like `destructive: true, undoable: true` (or `confirms: true`) and draw `destructive` rows red. Add `check(CommandSafety.unmarked(rows).isEmpty, …)` to the tests.
- Give the selected item's rows `context:`. Build the list from a plain state value, and test the list the app builds, not one built by hand.
- Turn settings with choices into picks with `preview` and `revert`; turn toggles into `CommandRow.toggle`.
- Replace sheets and choosers that follow a command with `.pick` and `.ask`.
- Add synonyms where people would type a different word.
