# Changelog

All notable changes to Quire — the core, the terminal app and the Linux app —
are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

**How to update this file**

- Add a bullet under `## [Unreleased]` in the same change that ships the work.
- Buckets, in this order, omitting the empty ones: `Added` · `Changed` ·
  `Fixed` · `Removed` · `Deprecated` · `Security`.
- One line per user-visible change, present tense, what the user gets. Lead
  with the area in bold (**Terminal**, **Linux**, **Core**, **Format**, …).
- Call out anything that changes the on-disk format explicitly — the files
  are shared with jnl, Nook and hand-editing users.
- On release: rename `[Unreleased]` to `## [x.y.z] — YYYY-MM-DD`, open a fresh
  `[Unreleased]`, run `make bump V=x.y.z` (it writes the four version fields and the files that repeat them), then tag the release
  commit `vx.y.z` and push the tag (see Releases in `CLAUDE.md`).

---

## [Unreleased]

### Changed
- **Apple**: the monitor's hidden mode shows an entry's day of the week at the end of the breadcrumb bar (`inbox › 2026 › 11 › 18.md › Wednesday`), not inside the header's timestamp; the header line reads as it is on disk.

### Fixed
- **Apple**: "Compress existing media" finds a photo's links by its full path (`assets/2026/11/IMG.heic`), so the entry points at the new JPEG; a HEIC whose links weren't rewritten is never moved to recovery, so no link is left dead.
- **Apple**: ⌘K Dark or Light mode leaves a monitor in hidden (VS Code) mode in disguise, instead of showing Quire's own page with the journal on it.
- **Apple**: pinning or unpinning a search while searches.json can't be read (evicted from iCloud) changes nothing and says why, rather than writing over every other pinned search.
- **Core**: "Merge ex-split journals" leaves a file in the journal root alone unless its entries carry its tag, as the migration does: an export saved there (`journal-2026.md`) is no longer folded into the day files and deleted.
- **Core**: the iPhone Inbox shows each draft once after a fold of `inbox.md` that stopped part way, as the journal list already did.
- **Install**: `install.sh` uses python3 only when it actually runs: on a Mac without the command-line tools the `/usr/bin/python3` stub is passed over (never started, so no install offer pops up) and the settings are written without it.
- **Core**: a journal whose `journal/` (or a year or month inside `inbox/`, `journal/` or `split/`) is a link to another folder: "Clear orphan media" and media cleanup read the entries through the link, so media those entries use is no longer offered as unused or cleared; backups copy the linked folder itself rather than a link back to the live one.

### Security
- **Terminal**: `quire update` refuses a release that has no signature for the file it would install, instead of installing it on its SHA-256 alone.
- **Releases**: the release workflow fails when the signing key secret is missing, so an unsigned release is never published.
- **Terminal**: `quire update` checks a new `<tarball>.release.sig`, which signs the release tag and file name with the tarball's SHA-256, so an older signed tarball re-uploaded under a new tag is refused. Releases keep publishing the tarball's own `.sig` for clients from before this; a release without `.release.sig` is refused by this one.
- **Terminal**: `quire update` no longer renames over a `jnl` beside `quire` that isn't Quire's (the Go CLI, the bash script, anything put there by hand): it stops with nothing changed and says so.

## [1.0.0] — 2026-11-17

Quire 1.0: no longer a prototype, but a journal to keep every day. The terminal app, the Linux desktop app and the app for iPhone, iPad and Mac all read and write the same plain Markdown files, a sync landing mid-save can't overwrite an edit, a restore can't empty the journal, and updates are signed and checked. One line installs it on Linux or a Mac: `curl -fsSL https://raw.githubusercontent.com/Caddickbrown/Quire/main/install.sh | bash` (new in this release, the Mac gets the terminal app as a download too).

Also in 1.0, on iPhone, iPad and the monitor: ⌘K that does anything (every action on the open entry or the page being written, themes that preview as you pick them, settings, macros, any entry by name), a date picker that follows the screen it's on, keyboard scrolling and a hint bar that lists the keys that work, hidden mode (with the day of the week beside the date), Quire's design on the iPad, new widgets, a calendar sheet, Auto theme pairs and media in the composer. Underneath: every rewrite of a journal file is a compare-and-swap, the vault refuses paths that leave the journal, and `quire update` checks each release's signature.

### Added
- **Terminal**: `jnl update --main` (also `quire update --main`) builds the terminal app from the latest code on main with cargo, for a fix that isn't in a release yet.
- **Apple**: ⌘K, from a monitor or any hardware keyboard: type a few letters to go to Today, the Inbox, the Journal, Search, a new draft, a date or Settings, with the same fuzzy match as Pippin and MiniOffice. Jump to a date reads `14 March`, `14/3` or `2026-03-14`, or offers yesterday, a week, a month or a year ago, and says where it lands when nothing was written that day. It is drawn on the monitor (as VS Code's Command Palette in hidden mode) or over the phone, and works over the composer, which saves and closes first.
- **Apple**: the monitor's date picker shows the time with a line on how to change it, and an exact time can be typed: `1430`, `14:30` or `9`, with ⌫ taking a digit back. - and = still move it by 15 minutes, and the hint bar says so.
- **Apple**: open entries scroll with ↑↓ or j/k, on the phone and the monitor together, and Settings scrolls with them on the phone. Settings and Look back keep the selected row in view on long pages or at large text sizes.
- **Apple**: Search shows on the monitor what you're typing. ↩ goes to the results and `/` back to the query.
- **Apple**: entries open on the iPhone play their video and voice memos in place (a memo's transcript reads beneath it), instead of showing the file's path. Voice memos get a player in the theme's own colours and type: play/pause, a timeline to drag or tap to seek, elapsed and remaining time; it is sized up on the monitor.
- **Apple**: an open entry's actions (star, file or return to inbox, delete, edit) and the composer's star are icons, as the masthead's are.
- **Apple**: press and hold an entry in Today, the Inbox or the Journal to delete it (it asks first).
- **Apple**: On this day shows each entry's tags, on the phone and on the monitor.
- **Apple**: Search has a Tags button listing every tag with its count; a tag searches for itself. The Journal's tag list is gone from the top of the page.
- **Apple**: the mastheads use icons for Search and Settings, and Today and the Journal have a Media Library icon beside them (the Journal's "Media Library" link is gone).
- **Apple**: `r` (a random entry) works and is listed on the monitor in the Journal, On this day and open entries, and gives a random draft in the Inbox; another `r` replaces the open entry rather than stacking up. The monitor's key hints step down in size rather than running off the edge, and Search no longer lists keys its sheet doesn't take.
- **Apple**: words selected in the composer are shaded on the monitor too: a highlighter in the accent colour on Quire's page, VS Code's selection blue in hidden mode.
- **Apple**: the composer's footer says how many drafts are left in the inbox (or that this is the last one), for working through them one by one.
- **Apple**: with a monitor connected, ↑ and ↓ in the composer move the cursor by the monitor's lines, not the phone's, so it goes where you see it go; the phone keeps its own wrapping.
- **Apple**: a whimsy pass, in Quire's calm, bookish manner: pages arrive (titles, labels and rows settle in top to bottom within about 150 ms when a tab or entry opens), the accent rule under a title draws in like a pen stroke, filing an entry turns the page over before it closes, a just-filed entry is set down in Today's list, another prompt (`p`) rolls up into place, On this day cards are dealt onto the page, Look back's figures count up and its weekday bars grow, the current streak breathes a few times, a "Goal met" stamp lands the first time the day's word goal is reached, Today's kicker says the part of the day, and an empty page's placeholder breathes until the first word. Haptics follow one vocabulary: success on filing and the goal, a light land on saving and a new prompt, a warning when a write fails. Reduce Motion keeps everything still; nothing animates per keystroke.
- **Apple**: attach media on iPhone and iPad again. The composer has a paperclip (Photo Library, Take Photo, Record Video, Voice Note, Choose File) and accepts dropped photos, video, audio and files, as the Mac does.
- **Apple**: paste a copied image (or a copied photo, video or audio file on Mac) into any editor to attach it, as `^v` does in the terminal app.
- **Apple**: attachments land where the cursor is, as their own paragraph, not at the end of the entry.
- **Apple**: hidden mode for the monitor. Choose "VS Code (hidden)" as the monitor theme (Settings → External display, `,` on the monitor, or ⌥⌘T) and the monitor looks like VS Code on Windows 11 above a light taskbar of look-alike app icons: the entry you're writing or reading is its day file, with line numbers and a caret; a list is the Explorer, with the selected entry in a preview tab; Today is a README; settings is the Settings tab. Paused or locked, it is an empty editor. The phone is unchanged.
- **Apple**: iPad runs Quire's design. At regular width the tab words become a narrow sidebar that folds to a strip (the sidebar button or ⌃⌘S; remembered) and, where there is room (iPad landscape, an iPhone that opens out), an entry opens beside the list instead of over it; layout follows the size class, not the device.
- **Apple**: an On this day widget, a Lock Screen Today accessory (a ring of today's words against the goal, or the streak; figures; an inline line), and a Write a Line control that opens Today with its one-line field ready.
- **Apple**: the Today widget's "Another prompt" button rerolls the prompt for the app and every widget.
- **Installer**: one line installs Quire on Linux or a Mac: `curl -fsSL https://raw.githubusercontent.com/Caddickbrown/Quire/main/install.sh | bash`. On a Mac the terminal app is now downloaded from the release (Apple silicon and Intel builds, checksummed and signed like Linux's) instead of built, and `quire update` updates it the same way; the Mac's desktop app is still built from source.
- **Releases**: each release carries the terminal app for macOS, `quire-aarch64-apple-darwin.tar.gz` and `quire-x86_64-apple-darwin.tar.gz`.
- **Apple**: ⌘K does anything, not only goes places. The open or selected entry's actions come first (open, edit, star, file, return to the Inbox, change the date, delete, which asks in the menu), and the page being written has its own (file, save, date, focus, a prompt, star, voice note, attach, discard) without closing it. Themes and the monitor's looks, the VS Code disguise included, preview as you arrow through them and Esc puts the old one back; settings are toggles that say which way they go; macros, backups, saved searches, tags, split journals, Look back, the Media Library and any entry by name are all on it, with recent commands at the top. Without a keyboard, the ⌘ icon in the masthead, on an entry and while writing opens it. Built on App Kit 0.6.
- **Apple**: Today, Inbox, Journal and Look back offer a quiet calendar icon opening a themed sheet, with marked entry dates, month/year navigation and entries for the selected day; Inbox shows drafts and Journal follows its chosen journal and star filter.
- **Apple**: Auto theme picks its looks. Settings → Theme → Auto now asks which light theme to use by day and which dark one at night (Almanac and Cinema until you choose), and switches with the system's appearance. The widgets, the Live Activity and the monitor follow the same pair.
- **Apple**: Today is on screen at launch, drawn from what it showed last time while the journal is read; a new day starts empty, never with yesterday's figures.
- **Apple**: a page Quire closed on before it was saved is offered back at the next launch or unlock: save it to the Inbox, copy its text, or discard it. The save-failure banner has "Copy text".
- **Apple**: a tap anywhere below the words on the writing page puts the cursor after the last one; the text fills the page.
- **Apple**: Settings has a Macros page: Clean Up, Sort Inbox, File All Drafts, File transfer.md, Merge Conflict Copies and Merge Ex-Split Journals, each with an icon, out of Import and export.
- **Apple**: the monitor's hidden mode names the day of the week beside the date in an entry's header (`[2026-11-16 Monday 08:12:00]`, dim, like an editor's inlay hint), shows the header's real seconds in the list's preview (not `:00`), and previews long entries whole.
- **Terminal**: `^k` in the composer keeps your text as a new draft when a save is refused because the entry changed on disk.
- **Releases**: `make bump V=x.y.z` sets the version in all four fields, `Cargo.lock` and `linux/package-lock.json`, and regenerates the Xcode project.
- **Terminal**: space and PgDn read on through an entry longer than its pane in the Inbox and the Journal; PgUp goes back.
- **Apple**: the composer's failure banner has "Close and keep for later" when the journal folder can't be reached; the page is kept and offered again, and that question has a "Later".
- **Apple**: "Transcribe voice memos on this device" can be switched on an iPhone and iPad; ⌘K's rows can be tapped or clicked.
- **Tools**: `make check` tests the installer (syntax and dry runs in a scratch home) and prints `SKIPPED:` for anything it can't run; CI treats a skip as a failure and now lints and tests the desktop app. `make check-scripts` runs the part that needs no Rust.

### Changed
- **Apple**: the date picker follows the screen it's on: it matches the monitor's theme, and hidden mode has a small drop-down in VS Code's own colours instead of a card in the phone's theme.
- **Apple**: the monitor's hint bar lists the keys that work and only those: ⌘K, `t` in the Journal, `u` or `f` on an open entry, `p` on Today, and the letters that go elsewhere; an empty list no longer shows keys for rows it hasn't got. `p` now works only on Today, where the prompt is, and `j` on an open entry scrolls rather than leaving for the Journal.
- **Apple**: `/` on an open entry with a monitor attached closes the entry first, so Search shows on the monitor.
- **Linux**: the package description and the sample-journal notices no longer call Quire a prototype.
- **Releases**: a tag runs `make test`, `make check` and `make smoke` before anything is built, and publishes nothing if they fail; `.github/workflows/ci.yml` runs the same checks when asked.
- **Terminal**: the migration tests, which nothing ran, are part of `make check`.
- **Terminal**: the Inbox is set out by year, month and day like the Journal, with the same keys and `/` filter, and each draft shows where it will file to. In a narrow window, moving on to the entries now shows them instead of nothing, in both views, and `e` edits in the Journal too.
- **Terminal**: `jnl update` and `quire update` now update a copy built from source, including every Mac install, by rebuilding the latest release with cargo. Before, they only printed an install command.
- **Apple**: on the monitor, Esc always gets you home to Today: from a list or an open entry one press, from anything over the page (a question, the date picker, settings, Search, the Media Library, a sheet) it closes that first, and from the composer it saves and closes as before. A question is cancelled, never answered. The hint bar says Today. Search and the Media Library's filter take Esc too, where a typing field used to keep it.
- **Apple**: Random is a dice icon in the masthead, beside Search and Settings, on the Inbox and the Journal; the Inbox's File all button is gone (filing every draft is still in Settings → Maintenance).
- **Apple**: an entry opens with the cursor at the end of its text, ready to carry on writing.
- **Apple**: on the Mac, attaching has its own paperclip button instead of sitting in the ⋯ menu.
- **Apple**: the widgets, the Lock Screen New Draft accessory and the writing-timer Live Activity are set in Quire's design instead of Nook's: the app's theme (Marathon included), Newsreader and IBM Plex, and the mark. Small shows today's words, Medium opens on today's prompt, Large is the Today page in miniature; they turn over at midnight on their own and tint on a tinted Home Screen.
- **Apple**: the title bar keeps the Calendar beside Search on every page; the Media Library and Random buttons, which come and go, sit to its left.
- **Apple**: on the monitor, Esc from an open entry steps back to the list you came from, with your place in it kept, and the next Esc goes to Today. The hint bar says Back on an open entry.
- **Core**: Data Saver keeps each original it replaces in `.quire/media-cleanup/` for 30 days (Apple too, and for deletes from the Media Library and cleared unused media), skips animated PNGs and multi-page TIFFs, and encodes video as yuv420p. HEICs it converts are moved there instead of deleted.
- **Core**: the copy taken before a restore is named `Quire before-restore …`, is listed and restorable, and is never pruned. A backup is copied under a hidden `.partial` name and renamed when complete, so an interrupted one is never listed or restored.
- **Core**: saving keeps a file's permissions; new files follow their folder's instead of always being world-readable. Renames and removals are synced to disk.
- **Core**: text above the first header is kept as its own entry by paste and the markdown folder import; the import skips dot-folders. Impossible dates and times (`2026-02-31 25:99:00`) are refused when writing.
- **Terminal**: `^d` on an existing entry undoes this visit's changes instead of deleting the entry; only a draft started in this session is deleted.
- **Terminal**: `f`, `u`, `*` and `e` act only on an entry that is marked on screen; from another column the first press goes to the entries. Delete and date-and-time questions name the entry and act on that one, whatever is selected when you answer.
- **Terminal**: a journal opened with `--folder` keeps its backups and its last-backup time apart from your main journal's.
- **Terminal**: `quire update` writes both programs in full before replacing either, and a stalled download times out.
- **Linux**: with a PIN set, Quire locks every time it opens (the "Lock on launch" switch is gone); changing or removing the PIN asks for the current one; nothing answers a click or right-click while locked.
- **Linux**: the window can read media only from your journal folder and open only files inside it; attach, export and import take only files you chose in a dialog or dropped.
- **Linux**: Ctrl+I writes `_italic_`, as the terminal app does. The Super key no longer acts as Ctrl; Keyboard help lists Ctrl+6.
- **Apple**: with the app lock on, the On this day widget and the weekly "From your journal" note show no text from your journal; that note is withdrawn if its entry is edited or deleted.
- **Apple**: Settings asks before merging ex-split journals, deleting a template or switching the journal folder. File All Drafts, File transfer.md, the merges, imports, the unused-media check and Compress Existing Media run in the background and say they are working; a restore can't be swiped away half way.
- **Apple**: a starred page with no words no longer becomes a draft.
- **Releases**: the release pipeline refuses a tag whose CHANGELOG heading isn't `## [x.y.z] — YYYY-MM-DD`, or that leaves bullets under `[Unreleased]`. The Rust toolchain action is pinned to a commit, and `npm ci` runs in a step that never sees the signing key.
- **Install**: an AppImage is offered for removal by default only when the file carries Nook's or Wander's bundle id. `--dry-run` no longer contacts GitHub. `--uninstall` also offers to remove the source it cloned, and moves a `jnl` or `quire` only when it is Quire's.
- **Docs**: CLAUDE.md, AGENTS.md, the Linux and Apple READMEs and the plan match the code again; CI is described as it is, run when asked and on a release tag. `docs/fix-spec.md` is the review these changes come from.
- **Core**: backups leave out the recovery folder (`.quire/media-cleanup/`), so a compressed video is no longer in every backup twice. A restore's safety copy still holds everything.
- **Core**: deleting a media file on a local folder moves it to the recovery folder for 30 days instead of removing it. Data Saver's kept originals are cleared after 30 days even if Maintenance is never opened.
- **Core**: Storage sizes report the recovery folder on its own, and its copies of day files no longer count as journal text.
- **Search**: curly quotes and guillemets (“ ” „ « ») quote a phrase like `"`; quoted text is never read as an operator, so `"is:starred"` finds the words; a filter that can't be used (`before:March`) is searched as text instead of being dropped. The same in every app.
- **Terminal**: questions take `y` only. ↵ no longer answers yes, so three presses of ↵ can't restore a backup. Esc on Today no longer quits (`q` does).
- **Terminal**: a journal folder in the settings that isn't there (a drive not mounted, a folder renamed) stops Quire with a message; it no longer starts an empty journal in `~/notes`.
- **Terminal**: `--folder` with no value and unknown options are errors; `--folder=PATH` works; words after `new` or a title are never read as options. `import`, `export`, `sort`, `transfer`, `cleanup` and `random` exit with a failure when they fail.
- **Terminal**: the help overlay lists the keys that work on each screen; Search shows F1.
- **Apple**: voice memos are transcribed on the device or not at all. A recording is no longer sent to Apple's servers when the device can't recognise the language.
- **Apple**: with App Lock on, nothing of the journal is kept in Spotlight.
- **Apple**: the monitor's hint bar lists ⌥⌘ ± T P H as one hint on every page (they work while writing, in Search and in ⌘K), `?` and j/k where they act, and only Esc while a sheet opened by touch covers the page.
- **Themes**: `faint` is darker on the light themes and lighter on the dark ones, to pass WCAG AA as text on page and card in all seven themes. On Linux the off switch is visible on light themes, custom accents are adjusted per theme to stay readable, and there is one danger colour.
- **Installer**: an old `jnl` sitting where Quire's goes is moved aside only after Quire's own is downloaded, checked and run once (or built); a failed download or build leaves it where it was. You are told it will be moved, not asked.
- **Installer**: the journal backup is written as `.partial`, read back, and only then named `quire-preinstall-<stamp>.tar.gz`. A launcher entry that is only *named* Nook or Wander is offered for removal with the default no.
- **Installer**: refuses to run under `sudo` (it asks for sudo itself where needed), and Ctrl-C stops it instead of carrying on to the next step.
- **Releases**: the tag must be on `main`; the signing key is seen by one job that builds nothing; GitHub's actions are pinned to commits.

### Fixed
- **Installer**: on Debian or Ubuntu with `rpm` installed, looking for an old Quire package no longer leaves an empty `~/.rpmdb` in your home folder (a dry run made one too).
- **Backups**: pruning removes every old backup it should when several were made within the same tick of the disk's clock (a fast Linux disk); one could be kept by mistake.
- **Apple**: long lists on the monitor keep the selected row in view when the selection moves far, as a jump to a date does.
- **Apple**: a journal folder that can't be reached says so, rather than "Path leaves the journal folder", and a write no longer makes it again; a folder reported as `/private/var/…` before it exists works once it does.
- **Core**: a sync, a Shortcut or the terminal app landing mid-save can't overwrite an edit: every rewrite of a journal file is now a compare-and-swap that redoes the edit on the new text (Apple: inside one file coordination; desktop and terminal: Quire's writers take turns on a folder lock). The format is unchanged.
- **Backups**: Restore no longer empties the journal before copying the backup in. It stages and checks a copy, swaps it in, and puts everything back if a step fails. Backups and safety copies are checked against the journal, a failed one is removed, and an iCloud placeholder stops the copy instead of being backed up empty. On Apple, hidden items such as Syncthing's now stay put.
- **Apple**: markdown in a title shows as it reads: `Felt _really_ ill` sets "really" in italics in the lists (Today, Inbox, Journal, Search), on the monitor's lists and at the top of an open entry, and `**bold**` is bold. Underscores inside a word (snake_case) and the star marker are left as they are.
- **Apple**: deleting a draft from the Inbox works on the phone again. `d` and press and hold → Delete… asked for nothing: the Inbox's "Delete this draft?" never came up.
- **Apple**: confirmations work in Monitor Mode. Deleting from the Inbox, the Journal, Today or an open entry, and ^D (discard) while writing, ask on the monitor, worked from the keyboard: ↩ goes ahead, Esc cancels, and nothing else acts while it is up. The selection moves on to the next entry (or the one before). Unplugging, pausing or locking cancels it; without a monitor the phone asks as before. It is drawn as VS Code's dialog in the VS Code theme.
- **Apple**: a date changed while writing (^T or the date at the top) is saved even when the words haven't changed since the last save. It was dropped once a new page had autosaved, and closing the page lost it.
- **Apple**: changing an entry's date works in Monitor Mode. `t` (on a list or an open entry) and ^T (writing) open a calendar on the monitor, worked from the keyboard: ← → a day, ↑ ↓ a week, [ ] a month, t today, - = the time by 15 minutes, ↩ sets, Esc cancels. The time of day is kept otherwise. Tapping the date on the phone still opens the phone's picker.
- **Apple**: italics show in the editor and on the monitor: `_text_` now sets the font's italic face (TextKit 2 drew the old slant upright), and `*text*` italicises too.
- **Apple**: Esc leaves a new page from the keyboard; the title field kept Esc for itself, so a page opened on its title couldn't be closed.
- **Apple**: the monitor draws a caret in the title while the title is being written.
- **Apple**: filing or closing a page from a hardware keyboard (`^j`, Esc) no longer freezes the app until iOS kills it.
- **Apple**: hidden mode's caret behaves like VS Code's: the text no longer shifts or rewraps around it, it holds solid while you type and blinks when you stop, and it sits in the title while you type the title.
- **Apple**: the composer's control keys (`^j` file, `^s` save, `^t`, `^f`, `^p`, `^d`) work while you type; they only reached the app when no field had the cursor, and the text field read some of them as cursor moves.
- **Apple**: a new page's time is fixed at the first keystroke, so typing and deleting before the first save no longer moves it.
- **Apple**: with the word goal on but never changed, the widget compared today's words against a goal of 1 instead of 750.
- **Apple**: the Mac camera sheet fits the preview instead of cropping it and keeps it level as a Continuity Camera iPhone turns; recordings and photos are saved the same way up.
- **Apple**: ^t opens the date picker on the monitor from a new page too: the title, where a new page starts, took it as "transpose".
- **Apple**: the writing page checks after each edit that its first line still starts at the top, and lays the text out again if TextKit 2 left it a line low (the keyboard's "…" with a tag on the line below).
- **Apple**: typing on an iPad keeps up again. Each autosave no longer regroups the whole Journal list beneath the page, the editor measures its height once per change instead of twice, and the word count, caret and tag list stop redrawing the page on every keystroke.
- **Apple**: typing no longer stalls on each pause: an autosave doesn't re-read the inbox or walk the journal, the rebuild waits until the page closes, iCloud's echo of your own save no longer reloads everything, and a keystroke redraws only the body and measures one paragraph.
- **Apple**: the title and the body no longer compete for the keyboard, and markdown styling is applied in the same edit as the characters, with the paragraph laid out again after the keyboard replaces text in it (the body sitting a line low after `...` became `…`).
- **Apple**: a writing page taken down by a widget, a link or a quick action saves what was unsaved first, and stops and attaches a recording in progress. Attaching media, inserting a prompt and an arriving transcript keep the cursor and the undo history. Bold, code and italic lines are never clipped at large text sizes. A title that ends in ` *` is no longer saved as a star.
- **Apple**: on the Mac, the Stream's inline editor keeps saving after its first autosave (everything typed after the first pause was being lost), and "Return to Inbox" from an open entry works.
- **Apple**: an entry you just edited can be starred, deleted or retimed at once, without "changed on disk" and a duplicate in the Inbox. An open entry stays on the right one when two share the same second, and the keyboard selection in a list stays on its entry when a row is added above it.
- **Apple**: Today, the streak, On this day and the widgets move to the new day at midnight or when the app is reopened the next morning. "Write a line" keeps your words when the save fails, and when an iPad is rotated.
- **Apple**: text directly under a heading reads as text, in full, instead of being cut at 300 characters. A body line that looks like an entry header no longer shows its guarding backslash. Entries with photos open faster.
- **Apple**: on iPad, a notification, widget or Spotlight result for an entry on another tab opens it; another entry opened beside the list gets its own keys and stops the previous entry's audio; saving an entry opened with `e` no longer changes the one beside it; rotating keeps the Journal's filter, split journal and selection. Entry links open from a cold launch, split journals included.
- **Apple**: backups taken while you are writing no longer fail; a failed one is reported in Settings and retried later, and a backup much smaller than the last removes no older ones. Importing a large archive reads the journal once and no longer freezes, and importing the same folder twice no longer duplicates. Shares from other apps can't be lost or doubled; an entry added from Shortcuts shows up at once.
- **Apple**: in hidden mode a locked or paused monitor no longer shows what was being searched for; pausing or locking closes the monitor's Settings; the monitor stays on the page you are writing; the hint bar lists ↑↓ on Today and ⌥⌘H, and Random only when something is filed. Reduce Motion and VoiceOver labels are honoured in the places the review found missing.
- **Core**: Data Saver leaves a `.webm` or `.ogg` that holds video alone, instead of keeping only its sound.
- **Core**: HEIC conversion rewrites links through the journal's compare-and-swap and keeps a HEIC anything still mentions. Media cleanup no longer writes over a day file saved while it runs.
- **Core**: unused-media detection reads links with brackets in the name (`image(1).jpg`) and matches names whatever their case or accent form, so such a file is no longer listed as unused.
- **Core**: folding `inbox.md` and `<tag>.md` into day files picks up a draft written to them mid-fold. Pasted text, conflict copies and imported files with a byte-order mark or CRLF merge without drops or duplicates. A draft with CRLF in its body can be saved again. Filing, returning to the Inbox and retiming can be retried after a failure without leaving two copies.
- **Core**: a settings file that doesn't parse is kept as `settings.json.bad-<stamp>` instead of being replaced with defaults, settings from a newer version survive a save, and the terminal and Linux apps no longer overwrite each other's changes. Neither opens a guessed or sample journal in its place.
- **Core**: conflict copies named with letters such as `İ` merge instead of being refused or crashing. A folder that can't be listed is reported instead of giving a shorter journal. Tag rename leaves link targets and code alone. The Data Saver record is never overwritten when it can't be read and uses the same ids on every device. A backup is checked against what was copied, and older backups are kept when the newest is under half the size of the one before.
- **Terminal**: Ctrl-C no longer drops what you were writing when the save fails: the quit is cancelled and says why; a second Ctrl-C quits and keeps the text as a new draft, or prints it if even that can't be written.
- **Terminal**: Up and Down no longer stick in wrapped paragraphs; emoji made of several characters are one step for the caret and backspace; a pasted tab becomes spaces. ↵ on a column filter keeps the row the filter had selected. ↵ leaves a complete tag alone (`@run` is not turned into `@running`). The date prompt refuses dates that don't exist. Clearing all the text of a saved draft no longer leaves an empty timestamp.
- **Terminal**: opening a journal no longer counts as a change to back up; a scheduled backup waits until you have stopped writing, and failures retry at growing intervals and are shown. `quire log` with a malformed date prints usage instead of crashing. The composer says when the window is too small to write in.
- **Linux**: an entry changed on another device is never written over by an open composer: an untouched composer takes the new version, one with edits asks "Keep mine as a new draft" or "Take theirs". A failed autosave retries by itself and the pill says "Not saved"; text with a pasted `[date time]` line is kept in a recovery copy; clearing a saved draft asks whether to discard it.
- **Linux**: attaching, pasting an image, filing, deleting and importing no longer freeze the window. Coming back to the window no longer rebuilds the page, so long entries and lists keep their place. Search follows the same rules as the other apps: an unclosed quote or a half-typed `before:` no longer empties the list, and `has:media` finds a PDF.
- **Linux**: an "on change" backup still owed at close is taken first; closing during a backup asks; failures and held-back pruning are shown. Menus and dialogs keep Tab inside them and return focus. Custom accents pick readable button text. The desktop crate compiles off Linux again.
- **Install**: an old `jnl` in the folder Quire installs into is moved aside before the install instead of being overwritten, and Quire's new `jnl` is no longer sent to the Trash in its place. Nook and Wander stay installed when Quire's desktop app fails to install. The AppImage is checked before the old package goes. The pre-install backup and the log are readable only by you. A `settings.json` that can't be read is kept aside.
- **Install**: `tools/migrate_journal.py` picks up a draft written while it moves `inbox.md`, skips a file that isn't UTF-8 with a message, and with `--keep-nook` no longer hides Nook's templates.
- **Terminal**: `make smoke` runs in a scratch home on a Mac too, so it never reads or writes the real settings, and each of its 23 checks looks only at what its own action drew.
- **Terminal**, **Linux**: every figure is the main journal's, as in `quire stats` and the Apple app: Today's entry count, the streak, Look back's totals, year, tags and year list, the Marathon counters and Random no longer include split journals. Look back and `quire stats` show the split journals apart, all of them together: how many, with their entries, words and days written (a "Split journals" line under the totals in the terminal, a panel on Linux, a block in the printed stats). A draft tagged for a split journal no longer keeps the terminal's streak.
- **Terminal**, **Linux**: On this day shows the main journal only, as the Apple app does. Entries in a split journal no longer appear there (Today in both, and Look back on Linux).
- **Terminal**: `quire new Call the dentist` (and `jnl Call the dentist`) keeps the title as a draft even when nothing more is typed; before, leaving, `^s` and `^j` all saved nothing. `^p` from the title puts the prompt in the body instead of making it the title or cutting the title in two. Text on the row under the title (a paste into the title, a line joined with Backspace) is no longer drawn over by the rule.
- **Terminal**: `t` then ↵ on an untouched date prompt leaves the entry as it is, instead of rewriting its seconds as `:00` and saying it moved. In the column filter, Esc goes back to the row that was selected when `/` was pressed, the DAY column is found by what it shows (`wed`, `4`), `/` from the entries filters the days instead of opening a prompt that ignored typing, and a click on QUIRE with a filter open no longer leaves `?` dead on Today.
- **Terminal**: Today's summary line fits at 80 columns instead of losing the end of "since 2019-03". Search counts every match and says when only the newest 300 are listed. Look back draws 31 December in a leap year that starts on a Sunday. `stats` in a pipe ends the current streak's dates on its last day, not on today. One of a thing reads "1 word", "1 entry", "1 day", "1 copy".
- **Core**: a `.heif` file is a picture, like `.heic`: it is linked as one, found by `has:image`, counted as an image in the Media Library and accepted when dropped on the terminal composer. A HEIC attached with Data Saver on while no converter is installed is no longer marked as done, so "Compress existing media" converts it once a converter is there.
- **Core**: a root `.md` file with no entries in it (notes kept beside the journal) is no longer counted, or weighed, as a split journal on Look back. Media cleanup dates a file's first entry correctly when the file starts with a byte-order mark, so the media it links is organised instead of being reported as undated.
- **Linux**: two ways of leaving the composer no longer drop unsaved edits to a filed entry: ↑/↓ with the focus off the text, and the list's Random button. Both save first, as Ctrl+R and a click on a row do.
- **Linux**: an entry whose header carries a date that doesn't exist (`2026-06-31`) no longer stops the Inbox, Journal or Starred list from drawing, and an impossible month or hour no longer turns Look back's charts into `NaN`. A picture whose name has brackets (`image(1).jpg`) shows in the reader instead of a broken link and stray text.
- **Linux**: in the date and time popover, ↵ on Cancel, Now or Yesterday presses that button instead of saving. "Yesterday" on the calendar is the day before by the calendar, right in the hour around a clock change, and the year's heat map keeps 31 December where clocks change at midnight. The Journal picker goes back to the main journal when the split journal it showed has no entries left, and Look back's year picker always lists the year on show. One of a thing reads "1 word", "1 entry", "1 day".
- **Core**: a root `.md` file is only folded into `split/` when it is a split journal (one of its entries carries `@<name>`). An export saved into the journal folder, or a log of timestamped lines, is left where it is instead of being copied out as thousands of day files.
- **Core**: a year or month folder inside `inbox/`, `journal/` or `split/` that is a link to another folder is read as well as written, so a draft filed into one no longer vanishes from view. Hidden folders there (a sync tool's `.trash`) are no longer read as entries.
- **Core**: when folding `inbox.md` or a `<tag>.md` stops after copying, each entry is shown once, not twice; the same file coming back from a sync no longer adds another copy to `.quire/migration/` on every open.
- **Core**: folding `inbox.md` rewrites `./…` links so pictures still show from the day file (`tools/migrate_journal.py` does the same). Format: the folded draft's link text changes (`./assets/a.jpg` becomes `assets/a.jpg`); the original is kept in `.quire/migration/` as before.
- **Core**: pasting many entries writes each day file once, and a paste that failed partway can be pasted again without doubling what was already written.
- **Core**: a relative link to a file outside `assets/` (`./sketch.png`) still points at the same file after its entry is retimed, filed or returned to the Inbox.
- **Core**: a preamble is kept unless the whole of it is already there (`# Notes` was dropped when `# Notes 2025` had been kept).
- **Core**: pressing return after a rule (`* * *`, `- - -`) no longer starts a bullet, and only ASCII digits number a list.
- **Core**: media cleanup and clearing unused media no longer read each file into memory, so a large video needs no matching RAM. If a copy fails partway, the copies already made are taken back and a retry does not leave `name-2` files. Two files whose names differ only in case no longer land on one file on a case-insensitive disk.
- **Core**: Data Saver keeps a photo's colour profile (JPEG, PNG, TIFF), so Display P3 photos no longer come out flatter.
- **Core**: importing a markdown folder dates an undated note by the earlier of its created and modified times, and importing the same folder again after adding a file adds only that file.
- **Core**: the backup just made is never the one pruned, even when the clocks have gone back; a backup fails if a folder cannot be listed, where before it could skip files and still pass its check.
- **Core**: a Day One import that fails partway removes the media it copied for entries it did not write, and no longer follows symlinks in the export's media folders. `transfer.md` with plain paragraphs is stamped on disk before filing, so a retry does not file them twice.
- **Core**: renaming a tag no longer changes a longer accented word (`@caf` in `@café`). The Media Library's owners list agrees with its "in use" mark for links that differ in case or use `<img>`.
- **Terminal**: the tag list opens only when you type at a tag. Opening an entry that ends in `@run` no longer takes ↑ ↓ ↵ and Esc, and Esc closes the list without adding a space.
- **Terminal**: a journal file that can't be read is named on every screen until it can, not only in a five-second message.
- **Terminal**: closing the window or `kill` (SIGHUP, SIGTERM) saves what is in the composer and gives the terminal back; typing without a pause is saved at least every 5 seconds; a fault in Quire itself still saves the composer. A background job that fails no longer gives the terminal back under the running app.
- **Terminal**: `quire update --help`, or a mistyped flag, no longer performs the update. `quire help` no longer creates the folder or migrates anything.
- **Terminal**: the hint bar drops whole hints when the window is narrow, never half a word; no key acts while the window is too small to draw; Broadsheet in 256 colours has its selection background again.
- **Terminal**: ^H is Backspace, and a control chord no longer types its letter in Search, the column filter or a prompt (^W takes back a word, ^U the line). ↑ and ↓ work while a column filter is open.
- **Terminal**: after the folder changes underneath, the Inbox, Journal and Search keep the same entry selected, so `f`, `u`, `*` and `e` act on the one that was marked. Settings → Export asks before replacing a file.
- **Linux**: unsaved changes to a filed entry keep a recovery copy while you type, offered back as an edit to that entry after a crash. The recovery copy lives beside the settings file, not in the journal folder, so it survives the folder going missing; the failed-save dialog has Copy text.
- **Linux**: a row clicked after a sync changed the file opens its own entry, and a task ticked in the reader can no longer land in another entry. Ctrl+S, filing and retiming a draft wait for an autosave in flight instead of overlapping it.
- **Linux**: restore, clean up, compress, imports, File all, merges and installing an update close the composer and suspend the window until they finish; jobs that hit problems list them in a dialog that stays, with Copy.
- **Linux**: the PIN is asked for even when the first load fails. An AppImage is recognised by where the binary runs from, not by `APPIMAGE` alone.
- **Linux**: text typed in a Settings field is no longer lost when the page redraws; leaving an edited template asks first.
- **Linux**: list continuation, Tab, bold/italic/code, tag completion and attach can be undone with Ctrl+Z. A paste with text and a picture of it pastes the text; a middle click on a link opens the browser.
- **Linux**: Ctrl+1–6 work on AZERTY; templates and saved searches changed on another device reload.
- **Linux**: the reader shows heading levels, rules, fenced code and nested lists; "New entry" on a past day's page dates the draft that day; an entry edited by hand is not rewritten by opening it.
- **Linux**: printing waits for pictures; Stream and Media work in a narrow window; long lists say when they stop at 500.
- **Linux**: deleting media says where the file goes (kept 30 days) and takes "in use" from the core; Storage shows the size of recovery copies.
- **Linux**: focus ring on search fields, labels on every field, error toasts announced as alerts, the year's heat map is one tab stop with arrow keys, Delete removes a saved search and resets the timer, pictures open from the keyboard, tag merges ask first.
- **Apple**: something shared to Quire is in the Inbox as soon as the app comes forward. It used to wait for a relaunch or midnight.
- **Apple**: the reminder's "Write a line…" and Siri's Add Journal Entry no longer drop the text when the journal can't be written. The line is kept and goes into the Inbox when Quire is next opened.
- **Apple**: a journal with files iCloud hasn't downloaded asks for all of them at once, says how many are coming and opens by itself when they arrive; iCloud conflict versions are looked for and merged when the app comes forward and when a folder is opened (neither confirmed on a device yet).
- **Apple**: one file that isn't plain text no longer hides the whole journal. It is named in the banner and left out, and nothing is written into it.
- **Apple**: with App Lock on, the keyboard can no longer come back to the page being written behind the lock (not confirmed on a device yet).
- **Apple**: an entry starred on its page and then given a new date stays the page you are on. The reader's File, Return to Inbox and Delete close the page only if they happened, and say so if they didn't.
- **Apple**: converting a HEIC never replaces a JPEG of the same name. "Choose File" copies a video or audio file in rather than reading it into memory. Background video compression ends its background task when time runs out.
- **Apple**: a transcript that arrives after the page closed is no longer lost and marked done. Media links whose names hold brackets (`image(1).jpg`) show their owning entry in the Media Library.
- **Apple**: a draft another device synced into a day file this app had just written shows up at the next look, not the next full load. A custom folder whose bookmark resolves but grants no access shows the "can't reach" banner.
- **Apple**: merging tags and exporting read the journal off the main thread, and an export that can't read everything says why; a Siri add no longer walks the whole journal. A file error inside the journal folder is reported in its own words, not as "Callback interface failure".
- **Apple**: the share sheet says so when there was nothing it could save, and shared text holding a timestamp-shaped line stays one draft.
- **Apple**: Search opened by touch over an open entry shows on the monitor; `/` goes back to the query when nothing was found. The monitor's reading page no longer decodes photos at full size.
- **Apple**: Return in the middle of a styled line restyles both halves; `snake_case` is not set in italics; with a Chinese or Japanese keyboard and a monitor, ↑/↓ and Return stay with the input method.
- **Apple**: the calendar sheet's week starts where your region starts it. The date sheets scroll on a phone on its side; the keyboard returns to the text after a date sheet or an attachment picker.
- **Apple**: Marathon Day's word-goal bar, title rule and other lime marks are drawn in the accent, where they can be seen, in the app and the widgets. Look back's weekday bars are darker.
- **Apple**: the @-tag bar above the keyboard is in Quire's own type and colours, with larger targets; the reader's date and the sidebar's items are 44 points tall. VoiceOver names the entry text, speaks the date on the date button, and says that Today's summary opens the Inbox. Reduce Motion is respected in more places.
- **Apple**: the composer's prompt, and the Mac's, is the one Today and the widgets show. Year in Review and Trends no longer count conflict copies as days. The iPhone no longer applies the Mac's light/dark setting.
- **Apple**: `build-core.sh` uses rustup's toolchain when another cargo comes first on PATH.
- **Installer**: on macOS two removed files with the same name no longer overwrite each other in the Trash. On Linux without `gio`, a move that needs sudo no longer leaves a root-owned folder. A release binary that can't run here (older glibc) is caught before anything is replaced, and the message says to use `--build`.
- **Tools**: `migrate_journal.py` no longer writes over a day file that Quire or a sync changed after it planned; it plans again.
- **Docs**: the README's bundle path, its "never `rm`" claim and the `^i` key; the Mac settings path in `CLAUDE.md`.

### Security
- **Releases**: each AppImage and each terminal tarball is published with a signature (`.sig`) made with the updater's key. `quire update` checks it when the release has one (a release without one is noted and rests on SHA-256), and only downloads from GitHub over https.
- **Core**: the vault refuses absolute paths and `..`; entry paths are checked without case (`.Quire/…`, `Assets/…`) and the preamble files are not entry files. The bindings' `rewrite` accepts entry files only.
- **Linux**: the backup folder can only be set to a path chosen in a dialog.

## [0.11.0] — 2026-10-26

### Changed
- **iPhone**: the composer styles emphasis, bold, code and theme-coloured tags as you type, starts new entries in the title, moves Return to the body, and lets you change the date without leaving the editor.

### Fixed
- **iPhone**: lists select a row automatically only with an external display connected; unplugging clears the selection, while phone-only keyboard navigation still highlights the row you move to.
- **iPhone**: failed saves keep edits open with retry and recovery-copy actions; retiming carries the entry's new reference into subsequent edits, and filing, closing and save confirmations respect write failures.
- **iPhone**: external desk mode stays awake while active, opens Inbox drafts for editing, follows list navigation even when empty, tracks the actual body caret without jumping between layouts, and shows draft filing shortcuts. On this day uses the same entries as the phone.
- **iPhone**: calendars follow the chosen theme, classic mastheads include the Quire mark, selected rows leave room for the time, Marathon's final tab has no trailing divider, and tag badges use theme colours.

## [0.10.1] — 2026-10-25

### Fixed
- **Apple**: App Lock covers the iPhone app again: since the iPhone design (0.9.0) the Face ID veil was never shown there, so a locked app showed the open entry and its app-switcher snapshot. Keys do nothing while locked.
- **Apple**: Spotlight results, notification taps and widget entry links open the entry on iPhone (they reached only the iPad/Mac shell).
- **Apple**: on iPhone the composer keeps its keys (Esc, ^S, ^J…) when the list behind it gets its first entry; opening an entry without changing it no longer rewrites it on disk; leaving the reader or composer no longer blanks a list the external display had just shown; two key catchers no longer trade focus back and forth.
- **Apple**: media usage counts and entry dates hold when iOS reports the journal folder as `/private/var/…` (an attached photo was shown as unused); the vault re-checks a cached folder for having become a symlink.
- **Linux**: "Search everything" (Today, Ctrl+Shift+F) finds inbox drafts and split-journal entries again; opening an entry from the Media Library or lightbox selects it in a list that shows it; filing a draft during an Inbox search selects the next draft in the results.
- **Linux**: Marathon draws in its `themes.json` colours (a later CSS block still set the old ones, so Linux and the other shells differed).
- **Linux**: the editor's bold, italic and code keep each character's width, so the caret no longer drifts on lines with them in proportional writing fonts.
- **Linux**: pasting several lines into a title keeps the caret where it was; clearing orphan media clears exactly the files the confirmation listed (still rechecked first).
- **Linux**: the launcher entry keeps install.sh's no-FUSE wrapper when the AppImage moves, and both quote and escape the AppImage path as the desktop-entry spec requires (a path with a space broke the no-FUSE launcher).

### Changed
- **Media**: recovery copies under `.quire/media-cleanup/` are kept for 30 days, then removed the next time media cleanup or orphan clearing runs (nothing runs in the background). Clearing orphans now frees their space after that, and the folder no longer grows in every backup and sync.

## [0.10.0] — 2026-10-20

### Added
- **Linux / Apple**: a discoverable Media Library with filename search, media-type filters, sorting, date grouping, previews and links back to entries; Linux has its own tab, iPhone opens it from Journal or Settings, and Mac/iPad expose it in the sidebar.
- **Terminal**: cleanup organises older assets into `assets/YYYY/MM/` using the earliest referencing entry, updates markdown links, reports missing media, asks before clearing orphan media (default: keep; recovery copies are retained) and keeps recovery copies under `.quire/media-cleanup/`.
- **Terminal**: `quire cleanup` (also `jnl`) removes `.DS_Store` files throughout the journal folder, reporting the count and any failures.

### Changed
- **Media**: clearing orphan media from Settings or the library rechecks references and retains verified recovery copies under `.quire/media-cleanup/`.

### Fixed
- **Linux**: long editor titles wrap and grow on screen while remaining a single line in the markdown file; italic markdown stays styled while the caret is inside it.
- **Linux**: typing batches editor painting and avoids recounting the full journal on every keystroke; draft autosaves wait 1.2 seconds after typing stops, write off the UI thread and still flush when leaving or closing.
- **Linux**: the Inbox has its own search, and the Journal opens directly on its first entry instead of unexpectedly showing a whole-day overview.
- **Linux / Apple**: cleaned-up media links support angle brackets, spaces, percent escapes and optional titles; Apple library dates and entry navigation distinguish files with the same name in different folders.

## [0.9.1] — 2026-10-17

### Fixed
- **Linux**: the launcher entry is `Quire.desktop`, matching the window's app id, so the dock and pinned icon show. The installer and first run replace an old `quire.desktop`, and `quire update` finds the AppImage from either name.
- **Linux**: the window opens in your theme instead of flashing the light one first: the resolved theme is remembered and applied before the first paint, and the window itself starts dark.

## [0.9.0] — 2026-10-17

### Added
- **iPhone**: the external display is a desk mode in Quire's own design: it follows the phone's theme (or its own), in Newsreader and Plex with ruled pages. Today with the readouts and a prompt when idle, the list beside a preview of the selected entry while browsing, the page when reading or writing. It is driven from the keyboard alone: `n i j l / r` from Today, `,` for Settings on the monitor.
- **Apple (iPhone):** with a monitor attached, `,` opens Settings on the monitor instead of a sheet on the phone: ↑↓ (or j/k) move, ↵ changes the row, `,` or Esc closes. Dark mode, theme, monitor theme, text size, key hints, dimming the phone, prompts and Back up now are all there. The monitor's hint bars list `,`.
- **iPhone**: Quire's own design replaces the Nook look on iPhone: Today, a list-style Inbox, the Journal by month, a reader and composer set as a page, Look back, Search and Settings, in Newsreader and IBM Plex, ruled rather than boxed, in your theme. Times in lists are plain text; they only change inside an entry. Random entry on the Inbox and Journal; swipe from the edge to go back.
- **iPhone**: the Marathon themes are a full look, not just colours: wide heavy Archivo capitals, DM Mono readouts, numbered-style ruled tabs with an inverted current page, a signal-colour brand block, chamfered new-entry slab, dot field and hazard stripe, and a words/streak/inbox readout on Today.
- **iPhone**: Settings picks a theme from light and dark groups with swatches; the earlier settings (folder, backups, import and export, maintenance, reminders, privacy, media, split tags, external display, help) are pages in Quire's own style, and the Nook-only options that no longer apply are hidden.
- **iPhone**: the external display mirrors the composer as you type and shows an entry while you read it.
- **iPhone**: the terminal app's keys on a hardware keyboard, printed along the bottom of a connected monitor: ↑/↓ or `j`/`k` move through the Inbox, Journal and Search, Return opens, Esc lets go and then goes back to Today; in lists `f` files, `e` edits, `*` stars, `t` sets the date and time, `u` returns an entry to the inbox, `d` deletes; on Today `n` new, `i` inbox, `j` journal, `l` look back, `/` search, `r` random, `p` another prompt, `,` settings, Return writes from the prompt; while writing `^J` files the draft, `^S` saves, `^T` sets the date and time, `^F` focuses, `^P` inserts a prompt, `^D` discards, Esc is done. The first ↑/↓ from Today opens the Journal's top or bottom entry. The selection is mirrored to the monitor as a browse list with a preview. Letters never fire while you are typing.
- **Apple**: a new app icon (the gathering mark) for iOS, light and dark, and macOS; `tools/make_apple_icon.swift` regenerates it.
- **Terminal**: `quire update` updates the desktop app too: the AppImage is downloaded, checked against the release's SHA-256 and swapped in place (restart it if it's open); a .deb or .rpm gets the command for your package manager. `--terminal` or `--desktop` updates just one.

### Changed
- **Apple**: opening a journal is much faster. On a journal of 5,100 entries in a file-provider folder the full index went from 55 s to about 1.2 s and the inbox from 5 s to 0.3 s: reads no longer go through file coordination (writes still do), the folder's real path and verified directories are worked out once, and the app stops loading the whole journal twice at launch.
- **Core**: `themes.json` carries Marathon's real colours (they had drifted from the Linux CSS) and optional `signal`, `on_signal` and `flag` tokens for that family.
- **Install**: on Linux (x86_64, arm64) `install.sh` downloads the latest release instead of compiling it, checking every file against its published SHA-256: no Rust, WebKitGTK or Tauri needed, and seconds instead of minutes. The desktop app installs as the AppImage, which updates itself; an installed .deb or .rpm is offered the switch (removed only once the AppImage is in place), and `fuse3` is offered when missing. The terminal app goes to `~/.local/bin`, or replaces a source-built `~/.cargo/bin/quire`; `quire update` keeps it current. `--build` compiles from source as before, as do `--source`, `QUIRE_REF` and macOS.

### Fixed
- **Linux**: the AppImage has an icon in the dock: on first run it writes its own launcher entry and icon (when no `quire.desktop` exists), and the installer's entry sets `StartupWMClass`.
- **Linux**: the Journal opens on the Main journal, with the split journals and All journals in the picker after it.
- **Linux**: a draft in the composer has a visible Done button (Esc did this, but nothing said so), and each entry on the Journal's day page has an Edit link, so a filed entry can be edited without finding the time link first.
- **iPhone**: the keyboard shortcuts now reach the app: the key catcher sits at the root of the app and takes the keys back after a push or a sheet, instead of relying on the app delegate (which isn't in the responder chain under SwiftUI). Esc, letters and the arrows work on Today and after opening an entry.
- **iPhone**: Today and Look back no longer re-read the whole journal each time they redraw; "on this day" is read from what is already loaded, so typing in the quick-capture line stays smooth.
- **iPhone**: a large inbox no longer pushes the page sideways, and a single enormous paragraph can't break a list or the reader.

## [0.8.1] — 2026-10-16

### Fixed
- **Terminal**: `quire update` follows GitHub's download redirect itself; letting the HTTP client follow it failed with "chunk expected crlf" behind an HTTPS proxy, so 0.8.0 may not be able to update itself there (download 0.8.1 by hand once if so).

### Changed
- **Releases**: built with GitHub's Node 24 actions (the Node 20 ones are being retired), and the desktop app's build uses Node 24. Nothing in the apps changes; this release is the first chance for 0.8.0 to update itself.

## [0.8.0] — 2026-10-16

### Added
- **Releases**: pushing a `vX.Y.Z` tag builds and publishes Linux x86_64 and arm64 releases on GitHub: the terminal app as a tarball with a checksum, the desktop app as AppImage, .deb and .rpm.
- **Terminal**: `quire update` (and `jnl update`) installs the latest release over the running one after checking its SHA-256; `--check` only reports. Source builds are pointed at `install.sh`.
- **Linux**: Settings → About shows the version and how Quire was installed, checks for updates on request, and the AppImage installs a signed update and restarts.
- **Core**: Cleanup moves an entry stored in the wrong day file (say, the 14th's entries pasted into `inbox/…/20.md`) to the day file its header gives, in the same inbox, journal or split journal; one already there counts as a duplicate. Every shell's Cleanup reports how many moved.
- **Backups**: configure automatic backups (off, daily, weekly, monthly or on change) and retention in Terminal Settings; monthly means 30 days in every shell. The terminal runs backups in the background and keeps 10 copies by default.
- **Terminal**: Settings adds tag review/rename, media compression, ex-split merging, Markdown/Day One/transfer imports and conflict-copy merging through the shared Rust core. Show the version and build commit in Settings and `quire --version`.
- **Linux**: Settings adds File All Drafts and Print / Export PDF for the filed journal.
- **Apple**: Settings adds sorting, filing all drafts, transfer imports and conflict-copy merging through Rust. iOS external displays gain shared Quire themes, keyboard controls for size/theme/pause/hints, and an independent paused screen.
- **Apple**: bring Nook's native iOS/macOS SwiftUI app, widget and share
  extension into `apple/` as Quire; journal parsing, search, editing, filing,
  migration and maintenance use the shared Rust core through UniFFI and a
  coordinated Swift `Vault`. Add an XCFramework build, hostless Swift tests
  and an Apple CI workflow; Apple SDK compilation still awaits a Mac run.
- **Install**: `install.sh` for Linux and macOS asks for the terminal app,
  the desktop app, or both; finds jnl, Nook and Wander and the journal
  folders they use; backs the chosen journal up; installs what the build
  needs (Rust, WebKitGTK via apt/dnf/pacman/zypper, Tauri's CLI, optionally
  ffmpeg); builds, installs and checks Quire; points it at the journal and
  moves `inbox.md` drafts into `inbox/`; then offers to remove the old apps
  (to the Trash, never deleted; journal folders are never touched).
  `--dry-run` shows every command first; `--uninstall` removes Quire.
  With Quire already installed it offers to build nothing and only retire
  the old apps (`--tidy`), counts what's installed when choosing removal
  defaults, and says when old apps have already stopped seeing drafts.
- **Terminal**: Today's On this day rows show an entry's first tag, as the inbox rows do.
- **Terminal**: the timer pauses and resumes (`^o`), resets with `alt-o`, shows
  `paused` in the status line, rings the terminal bell when it ends (Settings ›
  Timer chime), and `^o timer` is on the Write hint bar.
- **Terminal**: Settings gains Backups (folder, back up now, restore with a
  safety copy) and Maintenance (clean up, sort inbox, file all drafts, clear
  orphan media, export all), over the same core calls as the desktop app.
- **Terminal**: menu items (hint keys, list rows, pickers) are underlined as you move over
  them; the text of an entry, in the composer or the inbox preview, is not.
- **Terminal**: a settings page (`,`) — theme (applied live), daily word goal,
  timer length, mouse and Data Saver — saved to `settings.json`, shared with
  the desktop app.
- **Core**: `quire-core`, one Rust crate every shell shares — the jnl format,
  the store, search, stats, media, maintenance — behind a `Vault` trait so
  the core never opens a file itself (the Apple shell will coordinate writes;
  Android will use the Storage Access Framework).
- **Terminal**: Quire in the terminal, installed as both `quire` and `jnl`.
  Today, Review, Browse (with the Main / split journal / all picker), Write
  (markdown styled where you type, focus, `@` autocomplete, list
  continuation, autosave), Look back (heat strip, words a month, tags, when),
  Search. Every jnl subcommand keeps its spelling and prints jnl's text when
  piped. Themes follow `themes.json`.
- **Format**: drafts live in `inbox/YYYY/MM/DD.md`, the journal's own shape.
  Retiming a draft moves it between inbox days as it moves filed entries
  between journal days; a day file that empties is deleted.
- **Format**: a legacy `inbox.md` is folded into `inbox/` on open — every
  draft verified first, the original kept under `.quire/migration/` — and
  merged again if an older app rewrites it. `tools/migrate_journal.py` does
  the same from outside the app (dry run by default).
- **Themes**: `themes.json` at the repository root, one source for every
  shell: Almanac, Broadsheet, Linen, Cinema, Night, Marathon, Marathon Day.
- **Terminal**: `quire migrate`, `quire import` (drafts from stdin).
- **Tooling**: `make smoke` drives the terminal app through every screen in a
  pseudo-terminal and checks the files it writes.
- **Terminal**: the mouse. Click hints, list rows, Browse columns, the
  journal picker, Look back's years, a modal's answers and tag suggestions;
  click in the composer to place the caret; the wheel moves through lists and
  the text. F2 turns it off (and back on) so the terminal can select text;
  the choice is kept in `settings.json` as `terminalMouse`.
- **Terminal**: images in the composer. `^v` attaches an image on the
  clipboard to `assets/` and links it; dropping photos, video or audio onto
  the window (terminals paste their paths) attaches them too. Data Saver
  applies as in the desktop app. Pasted text arrives as typed, without list
  continuation firing on every line.
- **Core**: `attach_media` / `attach_bytes` — the attach path (HEIC→JPEG,
  Data Saver, the device ledger) the desktop app had, now shared — and
  `media::encode_clipboard_image`.

### Changed
- **Format**: split journals live in `split/<tag>/YYYY/MM/DD.md`, one file
  per day, instead of one root `<tag>.md`. A `<tag>.md` written by jnl or
  Nook is folded in on open (every entry read back first; the original kept
  in `.quire/migration/`), and root `.md` files with no entries are no longer
  mistaken for split journals. `journal/` is unchanged. jnl and Nook won't
  see split entries in `split/` until taught to; `tools/migrate_journal.py`
  does the move from outside the app.
- **Terminal**: Browse's year, month and day columns are wide enough for their
  longest label and biggest count (no more `Septemb…` or a cut-off year), and
  the entries beside them no longer highlight under the pointer.
- **Terminal**: clicking QUIRE in the masthead goes back to Today (saving a
  draft first).
- **Terminal**: dates on Today (the inbox and On this day rows, "entries since"),
  the inbox list and its open draft, in Browse's day header, in Look back's
  streak dates and in search results are ISO 8601, as in the entries; the long
  dates in the mastheads stay.
- **Terminal**: the inbox is a list of drafts beside the open one (above it on
  a narrow terminal), as Browse is. Filing or deleting keeps the selection in
  place, so the next draft is up; a second click opens it. The draft dots and
  their 12-draft cap are gone.
- **Format**: the sidecar is `.quire/` (templates, saved searches, Data Saver
  ledgers). `.nook/` is read while only it exists and renamed on the first
  write; ledgers are read from both. Nook stops seeing templates and saved
  searches after the move — run one app per journal until Nook is retired.
- **Linux**: the app moves under `linux/` and runs on the core; its commands
  are thin calls on the shared store. `file_draft` now takes the draft's
  file. Opening a journal reports an inbox migration as a toast.
- **Linux**: the bundled sample journal is on the new layout.
- **Linux**: the desktop binary is `quire-desktop` (the package name), so it
  no longer shares a name with the terminal's `quire`.
- **Repository**: a Cargo workspace (`core`, `tui`, `linux/src-tauri`);
  `README.md` describes the whole, `linux/README.md` the desktop app.

### Fixed
- **Core**: ↩ in a list works on a line that still carries its `\r\n` or `\n` ending (the Apple editor passes one).
- **Apple**: the vault refuses a new file under a symlinked folder that points outside the journal (Foundation left such paths unresolved), and reminders no longer crash a process that isn't an app (hostless tests).
- **Apple**: the Xcode project no longer defines the `QuireCoreFFI` module twice (a project-wide header path duplicated the one the XCFramework provides), which broke every Apple build.
- **Terminal**: align tags and word counts in Today, Inbox and Browse, including rows with different digit counts.
- **Apple**: external monitors show a neutral screen while the journal is locked, including when an On this day preview is available.
- **Editor**: continuing an ordered list at the largest supported number
  repeats the number instead of overflowing.
- **Linux**: the running window shows Quire's icon again. Since the binary
  became `quire-desktop` its Wayland app id no longer matched `Quire.desktop`,
  so GNOME showed a generic one; the program now names itself `Quire`.
- **Linux**: text inputs in Settings (folder path, split tags, template name,
  reminder time) had no styling of their own, so dark themes showed pale text
  on the browser's white field; they now use the theme's ground, border and ink.
- **Terminal**: the selected tag suggestion uses the theme's on-accent colour,
  so it is black on Marathon's green instead of white.
- **Linux**: the welcome card says where drafts live now —
  `inbox/YYYY/MM/DD.md`, one file a day — and that an `inbox.md` from jnl
  or Nook is folded in, instead of pointing at `inbox.md`.

### Removed
- **Linux**: the presentation window branch (a second desktop window
  mirroring the composer) is parked, not merged.

## [0.6.2] — 2026-10-09
The Linux-only app, as released before the consolidation. See `linux/README.md`.
