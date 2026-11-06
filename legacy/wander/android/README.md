# wander (Android)

A fourth native build of Wander, in Kotlin and Jetpack Compose, over the same
journal folder as the other three.

```
app/src/main/java/com/caddickbrown/wander/
  core/      the port of WanderCore — model, parser, every format decision
  data/      the folder: SAF tree access, the library, the remembered grant
  store/     JournalStore, the observable layer the UI watches
  editor/    the writing surface: EditText, and markdown drawn as spans
  ui/        themes, type, the page, the index, the sheets, the fold
app/src/main/assets/
  themes.json    copied from ../Resources — the same table all four builds read
  fonts/         the same faces, plus a manifest of family, weight and slant
```

## The three decisions worth knowing about

**The folder is chosen, never assumed.** Android has no `~/Documents` a program
may read, so the first thing the app does is ask, through the system folder
picker, and it keeps the grant across launches with a persisted URI permission.
What comes back is a real folder in the user's storage — point it at one
Syncthing or a Dropbox client already watches and the same files open on the
Mac, on iOS and in the `jnl` CLI, byte for byte. The alternative, an app-private
directory, would have been far less work and would have made the Android build
an island.

The cost is in `data/SafTree.kt`: the framework addresses files by opaque
document id, so a path like `journal/2026/09/08.md` has to be walked to be
resolved. Resolutions are cached and directories are read in a single cursor
with every column at once — `DocumentFile`, which queries once per attribute, is
unusable over a journal of any size. The one guarantee that could not be carried
across is the atomic replace the other builds get from a rename: SAF has no
swap, so a write truncates in place, holding the previous bytes to put back if
it fails.

**The editor is a platform text view.** `editor/ProseEditor.kt` is an `EditText`,
and `editor/MarkdownStyler.kt` is the port of `MarkdownStyle.swift` — the same
line-bound rules, applied as Android spans. It only ever adds and removes spans,
never a character, so the IME's composing region is never pulled out from under
it. That is the whole reason this build is native rather than a web view in a
shell: autocorrect, composition, the selection handles, the magnifier and
dictation all work because the text is the platform's.

**The themes are not re-described.** `assets/themes.json` is a copy of
`Resources/themes.json`, parsed at launch by `ui/Theme.kt`. A theme is defined in
one place and looks the same in four.

## Two screens

`ui/Fold.kt` reads the hinge through Jetpack WindowManager, and `Shell` in
`ui/RootScreen.kt` lays out accordingly:

| | |
|---|---|
| Phone | the page is the root, the index arrives as a sheet |
| Surface Duo, unfolded foldable, tablet | the index sits beside the page, split at the hinge |
| Tabletop / book posture | the page in the raised half, the index in the flat half |

Nothing is drawn across the hinge: the gap is left as a margin, because a seam
through a sentence is worse than a wasted strip. Where there is no hinge but the
window is wide, the index simply takes a column — which is the layout the macOS
build has always had.

## Building

Needs JDK 17+ and an Android SDK with platform 35.

```
cd android
./gradlew :app:assembleDebug     # or open this folder in Android Studio
./gradlew :app:testDebugUnitTest # the format tests
```

The Gradle wrapper jar is not checked in; `gradle wrapper` or Android Studio
will fetch it on first use.

## Keeping the format honest

`app/src/test/java/.../ParserTest.kt` is about bytes, not behaviour: the
preamble surviving a rewrite, the star being a standalone token rather than any
trailing asterisk, en-dash dates normalising, entries sorting stably. The format
is the contract between five programs, and anything that changes what lands on
disk should fail there first.
