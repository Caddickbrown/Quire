# The command palette

`swift/CommandPalette.swift`: the ⌘K menu's rules, keys and host. The app supplies the commands and draws the panel in its own design; the kit has no visual components. The rules it serves are in App Kit's `docs/MONITOR.md`: every action is a command, the selected item comes first, follow-up steps stay in the palette, toggles say which way they go, Delete is red with Undo, it works on the monitor, with a keyboard and without one.

The reference app is the Sample App: `ios/Sample/Commands/SampleCommands.swift` (the list) and `ios/Sample/Commands/CommandMenu.swift` (what each command does, and the panel).

## The pieces

| Type | What |
|---|---|
| `CommandList` | The app's menu as a value: `rows(stage:typing:)`, `prompt(stage:)`, `nothing(stage:)`. Built from what's on screen now. |
| `CommandRow<Action>` | One command. `step` is `.run(action)`, `.pick(CommandPick)`, `.ask(CommandAsk)` or the older `.open(stage)`. `keepsSheet: true` runs it over an open sheet. |
| `CommandPick` | A follow-up choice inside the palette: "Theme…" then the theme. Its choices are rows, so they can preview, be red, or lead on to another step. |
| `CommandAsk` | A typed answer inside the palette: "Rename…", "Snooze until…". `make` turns the typing into an action, or nil while it isn't usable; `then` leads on to another step instead; `skip` lets it be left empty (0.9). |
| `CommandMulti`, `CommandOption`, `CommandTicks` | Ticks inside the palette: "Labels…", "Tags…", "Show only…". Space ticks, Return is Done; `adds` lets a new name be typed in (0.9). |
| `CommandConfirm` | A question inside the palette before something that can't be undone: "Delete 3 items?", Return to confirm (0.9). |
| `CommandForm`, `CommandAnswers` | Several answers one after another: "New duty…" then title, due, person. Builds the chained steps (0.9). |
| `CommandSetting`, `CommandSettings` | A list of settings (toggle, choice, number, text) turned into commands: "Setting: Dark mode — turn off" (0.9). |
| `CommandNoticeBoard`, `CommandNotice` | The notices showing now, as a value: results, Undo, failures, "Finish on the phone"; the latest Undo for ⌘Z (0.9). |
| `CommandNotices` | iOS: the app's one board (`.shared`), with timing, ⌘Z, and the phone hand-off (0.9). |
| `CommandNoticeStack`, `CommandNoticeCard` | iOS: the notices drawn, for the monitor's scene (and the phone's). A default card in system materials, or the app's own (0.9). |
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

## Monitor Mode: every phone action from ⌘K (0.9)

Dan, 18 Nov: in Monitor Mode every phone action must be doable from ⌘K. The audit (`~/claude-dd/reviews/monitor-mode-audit-18nov.md`) found most gaps came from the same few missing pieces: a typed edit, a multi pick, a confirm, a notice on the monitor, and system sheets. 0.9 has each. None of them changes how the panel looks or the keys you already know; a panel that draws `isCurrent` ticks, red `destructive` rows and `leads` chevrons draws all of them with no changes.

### How an app adds a typed, pick, multi or confirm command

```swift
// Typed, prefilled: "Rename project…" shows the current name. Return commits, Esc backs out.
Row("project.rename", "Rename project…", symbol: "pencil", step: .ask(CommandAsk(
    prompt: "A new name", initial: project.name, title: { "Rename to “\($0)”" },
    make: { $0.isEmpty || $0 == project.name ? nil : .renameProject(project.id, $0) })),
    context: "“\(project.name)”")

// Pick one, current ticked: "Sort by…". Typing at the top finds "Sort by: Due date" too.
Row("sort", "Sort by…", symbol: "arrow.up.arrow.down", step: .pick(CommandPick(prompt: "Sort by?",
    choices: sorts.map { Row($0.id, $0.title, symbol: "arrow.up.arrow.down", step: .run(.sort($0.id)),
                             isCurrent: $0.id == sort) })))

// Pick several, current ticked: "Labels…". Space ticks, Return is Done, a new name can be added.
Row("issue.labels", "Labels…", symbol: "tag", step: .multi(CommandMulti(prompt: "Which labels?",
    options: labels.map { CommandOption($0.id, $0.name) }, ticked: issue.labelIDs,
    adds: { "New label “\($0)”" },
    make: { ticks in ticks.ids == issue.labelIDs && ticks.added.isEmpty ? nil
                     : .setLabels(issue.id, ticks.ids, new: ticks.added) })),
    context: "“\(issue.title)”")

// Confirm in the palette, not a phone alert: Return confirms, Esc backs out.
Row("items.delete", "Delete \(n) items…", symbol: "trash", step: .confirm(CommandConfirm(
    prompt: "Delete \(n) items?", title: "Delete \(n) items", detail: "This can't be undone.",
    action: .delete(ids))), destructive: true)

// Several answers in a row: "New duty…" then title, due, repeat, person.
Row("duty.new", "New duty…", symbol: "plus", step: CommandForm(fields: [
    .text("title", "Title", prompt: "What needs doing?"),
    .choice("due", "Due", prompt: "When?", options: dueDays, skip: "No due date"),
    .choice("repeat", "Repeat", prompt: "How often?", options: repeats, current: "never"),
    .multi("who", "People", prompt: "Who?", options: people, ticked: [me]),
], finish: { a in .newDuty(title: a.text("title"), due: a.choice("due"), repeats: a.choice("repeat"),
                           people: a.choices("who")) }).step)

// Needs the phone's own screen (Photos, Files, share, print, Face ID): the monitor says what to do there.
Row("attach", "Attach photos…", symbol: "photo", step: .run(.attachPhotos),
    onPhone: "Choose the photos on the phone.")
```

Then in the app's `perform`, post the result where the monitor shows it: `CommandNotices.shared.undoable("Deleted 3 items.") { app.undo() }`, `.say("Renamed.")`, `.fail("Couldn't save. The server didn't answer.")`. And put `CommandNoticeStack(z: scale)` at the bottom of the monitor scene.

### Typed step (`.ask`)

- `initial` is in the box when it opens: the name being changed. The typed row ("Rename to “Plot”") is lit and Return commits it; `make` returning nil (empty, or unchanged) shows no row, so Return does nothing.
- Editing: letters add at the end, ⌫ takes one, **⌥⌫** a word, **⌘⌫** empties the box (to type afresh over the prefilled name; it never backs out), **⌘V** types what's on the clipboard. ⌫ with the box empty backs out a step; Esc backs out with nothing done.
- On the phone controller (opened by touch, or from the ⋯ menu with the monitor up) the phone's own keyboard types into it and its Go key is Return. The panel shows the answer on the monitor as it's typed.
- `then:` instead of `make:` leads on to another step with what's typed (a pick, another question, a confirm), for commands with several answers; the row it makes has a chevron. `skip: "No note"` adds a row while the box is empty that goes on with "".
- Suggestions (`suggestions:`) follow the typed row, narrowed by the typing: "Tomorrow", "Next week" under "Snooze until…".

### Pick several (`.multi`)

- Opens with what's on now ticked (`ticked:`, drawn as `isCurrent`), the first option lit, and a **Done** row first ("Done: Bug, UI"; `done:` words it differently).
- **Space** ticks or unticks the lit option. **Return** (or ⌘↩, or tapping Done) finishes with what's ticked, wherever the highlight is. A tap on an option ticks it. Esc backs out with nothing changed.
- Typing narrows the options (by title and synonyms) and lights the best. Fuzzy matching ignores spaces, so Space is free to tick; on the Done row or a "New …" row it types a space.
- `adds:` offers a row for a name typed that isn't there ("New label “urgent”"); Return or a tap on it adds it, ticked (Space there types a space, for names with two words). Done hands over `CommandTicks(ids:added:)`: ticked option ids in the options' order, then the new names.
- `make` returning nil (nothing changed, or nothing usable) makes Done back out instead. `then:` leads on to another step.
- `menu.isTicking` and `menu.ticked` are there for the panel; the hints say "Space Tick" and "↩ Done".

### Confirm (`.confirm`)

- The box shows the question (`prompt`), then two rows: the answer (red unless `destructive: false`, lit) and Cancel. **Return confirms**, Esc or Cancel backs out, typing does nothing. `menu.isConfirming` is true while it's open.
- It counts as asking first: `CommandSafety.unguarded` passes it, and it's never in Recents. Mark the row that opens it `destructive: true` so it's drawn red at the top.
- Use it for anything the app asked about in an alert before (delete, finish, discard, send to many): an alert on the phone can't be seen or answered from the monitor.

### Forms (`CommandForm`)

- A field is `.text(id, label, prompt:, initial:, skip:, valid:)`, `.choice(id, label, prompt:, options:, current:, skip:)` or `.multi(id, label, prompt:, options:, ticked:, adds:)`. `form.step` goes on the row; `finish` gets `CommandAnswers` (`text(id)`, `choice(id)`, `choices(id)`, `added(id)`) and returns the action.
- Each field is its own step. Esc goes back one field with its answer still there to change; ⌘K closes the lot. `menu.trail` is every row that opened a step ("New duty…", "Title: “Mow”"), for a breadcrumb in the box.

### Settings (`CommandSettings`)

```swift
out += CommandSettings.rows([
    .toggle("dark", "Dark mode", symbol: "moon", isOn: s.dark, set: { .setDark($0) }),
    .choice("theme", "Theme", symbol: "paintpalette", options: themes, current: s.theme, previews: true,
            set: { .setTheme($0) }),
    .number("size", "Text size", symbol: "textformat.size", value: s.size, range: 12...24, step: 2, unit: "pt",
            set: { .setSize($0) }),
    .text("server", "Server address", symbol: "server.rack", value: s.server, set: { .setServer($0) }),
])
```

- A toggle is "Setting: Dark mode — turn off" with state "On" (either wording finds it). A choice is "Setting: Theme…", a pick with the current ticked and, with `previews: true`, a live preview that Esc puts back; typing finds "Setting: Theme: Sepia" at the top. A number is a typed step prefilled with the value, with Smaller and Larger, refusing what's out of range. Text is a typed step prefilled, with "Clear it" once emptied (`clearable:`).
- Ids are `setting.<id>`; `prefix: ""` drops the "Setting:" word. This replaces a "Settings" row that opened a phone-only screen: list each setting instead, as Narrowcast does.

### Notices on the monitor (`CommandNotices`)

- `CommandNotices.shared.say(_)`, `.undoable(_, undo:)`, `.fail(_)`, `.phone(_)` post a notice; each goes after its time (3.2 s, 6 s, 8 s, 90 s), three at most, oldest first. VoiceOver reads each as it comes.
- **⌘Z** runs the latest Undo while it shows: `CommandResponders.install()` adds it to the window, the end of the responder chain, so a text field's own undo and an app's own ⌘Z still come first. An app with its own ⌘Z calls `CommandNotices.shared.undoLatest()` from it (it returns false when there's nothing, so the app can fall back to its own undo).
- `CommandNotices.shared.undoRow(.undoLatest)` gives an "Undo: Deleted 3 items" row (detail ⌘Z) for the app's list while there's one to undo.
- Draw them: `CommandNoticeStack(z: scale)` at the bottom of the monitor scene, above the hint bar; `CommandNoticeStack(z: scale) { MyToast(notice: $0) }` in the app's own design. The board is a plain value (`CommandNoticeBoard`), so tests pass the clock in.

### Finish on the phone (`onPhone:`)

- For what only the phone can show: Photos or Files pickers, the share sheet, print, Face ID, a camera. Set `onPhone: "Choose the photos on the phone."` on the row (or on the row that opens its step). Chosen with the menu on the monitor, the host runs the action as usual (the app opens the sheet on the phone) and posts a "Finish on the phone" notice with those words. It goes once a sheet has come up on the phone and gone again, after 90 s, or when the app calls `CommandNotices.shared.finishedOnPhone()` (do that after Face ID, which isn't a sheet). `menu.phoneNote` says what it will be.
- Where the app has its own list to choose from (recent files, its own media), a `.pick` is better still: no phone needed.

### Nothing hidden on the monitor

The rule: no command is left off the list on the monitor (`if !state.onMonitor { … }`, `display != .monitor`) unless the monitor has another way to do it. Rebuild the step in the palette instead (typed, pick, multi, confirm), or mark the row `onPhone:` if it truly needs the phone. `kit_check.py` warns with `file:line` on such a filter in a file that builds rows (rule `monitor-hidden`). Where the monitor's version is another row, say so on the line or within the three lines above, and the warning goes:

```swift
// monitor-alt: "Browse a category…" pick, in monitorRows()
if !state.onMonitor { out.append(openCategoriesScreen) }
```

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

- The box: `menu.query`, then a caret, then `menu.prompt` while the query is empty. Draw the caret as a shape beside the `Text` (a 2-point `Rectangle` a line high, the Sample's `Caret`), never as `"|"` or `"▏"` in the string: a typed caret takes a letter's width and leaves a gap beside it on the monitor. `kit_check` warns `text-caret` (0.9.1). The typed text doesn't animate.
- `menu.sections`: draw each `title` as a small heading when it isn't nil. `menu.rows` is the same rows flat.
- A row: `symbol`, `title` (red when `destructive`), `detail`, `state` for toggles, a tick for `isCurrent`, a chevron when `leads`.
- The box: `menu.opener?.title` before the query when a step is open ("Theme…"), `menu.query`, and `menu.prompt` when it's empty.
- The list: a `ScrollView` inside a `ScrollViewReader`, at most `CommandPaletteLimit.rows` rows high, scrolling to `menu.selected` when it changes.
- Keys: `menu.hints` lists exactly the keys that work now.

## Moving from 0.8

Nothing to change: 0.9 only adds. Old lists, steps and keys behave as before.

- **New `Step` cases**: `.multi`, `.confirm`, `.tick` and `.back`. An exhaustive `switch row.step` in an app needs them (none of the apps had one on 18 Nov; `row.leads` covers drawing).
- **New `CommandKey` cases**: `.clear`, `.deleteWord`, `.done`, `.paste`, for ⌘⌫, ⌥⌫, ⌘↩ and ⌘V, which the palette already held.
- **`CommandRow(… onPhone:)`** is a new last parameter, defaulted.
- **One file still.** Everything is in `swift/CommandPalette.swift`, so a sync needs no project change.
- **Draw the new states** if the panel wants to: `menu.trail` for a breadcrumb, `menu.isTicking` / `menu.isConfirming` for the box's icon. Ticks, red and chevrons already come through `isCurrent`, `destructive` and `leads`.
- Then, app by app, close the audit's gaps: replace phone-only sheets and alerts behind commands with `.ask`, `.pick`, `.multi`, `.confirm` and `CommandForm`; settings with `CommandSettings.rows`; toasts with `CommandNotices` and a `CommandNoticeStack` on the monitor; system sheets with `onPhone:`; and clear `kit_check.py`'s `monitor-hidden` warnings.

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
