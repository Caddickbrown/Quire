# Tokens

Every app keeps its colours in one `design/tokens.json` and generates its
platform palettes from it with `kit/tools/build_tokens.py`. The values are the
app's own. What is shared is the shape of the file, the roles every app must
define, and the contrast each must reach.

## Shape

```json
{
  "name": "Palette name",
  "color": {
    "bg": { "light": "#F4F6F8", "dark": "#0D1512", "use": "The one ground every screen sits on" }
  },
  "font":   { "family": "Inter", "fallback": "system-ui, -apple-system, sans-serif" },
  "space":  { "s": 8, "m": 12 },
  "radius": { "control": 12 },
  "line":   { "row": 1 },
  "build": {
    "css": "web/static/palette.generated.css",
    "swift": "ios/App/AppPalette.generated.swift",
    "swiftPalette": "AppPalette",
    "swiftMeasure": "AppMeasure",
    "checks": { "pairs": [["chromeInk", "chrome", 4.5]] }
  }
}
```

Every colour has a `light`, a `dark` and a one-line `use`. `font`, `space`,
`radius` and `line` are optional. Under `build`, either output may be left out.

## Required roles

| Role | Holds | Must reach |
|---|---|---|
| `bg` | The ground every screen sits on | — |
| `raised` | Sheets, dialogs, a selected item's panel | — |
| `ink` | Anything you read | 4.5:1 on `bg` and `raised` |
| `inkSecondary` | Labels, metadata, times | 4.5:1 on `bg` and `raised` |
| `rule` | Section lines | — |
| `hairline` | Lines between rows | — |
| `accent` | Primary action, links, focus | 3:1 on `bg` |
| `onAccent` | Text on an accent fill | 4.5:1 on `accent` |
| `late` | Overdue, failed, offline | 4.5:1 on `bg` |
| `done` | Completed, positive change | 3:1 on `bg` |

Every ratio is checked in light and dark.

- `rule` and `hairline` are dividers and carry no ratio. If a line is the only
  visible edge of an input field, give that border its own role and add a 3:1
  pair for it under `build.checks.pairs`.
- Add any extra roles the app needs. Add a pair for any extra role that carries
  text (text on a chip, text on a tinted selection).
- A light-only app sets `dark` equal to `light` and says so in `design/README.md`.
- A required role the app doesn't use yet (no "overdue" state, say) copies `ink`
  and says so in its `use` line, rather than inventing a colour.
- A pair the app can't change, such as a platform system colour, can be waived
  under `build.checks.waive` with a reason:
  `{"pair": ["inkSecondary", "bg"], "reason": "the platform's own secondary label"}`.
  Waived pairs are still printed on every check.

## Recording before generating

An app can adopt `tokens.json` before its screens use the generated palette:
leave out `css` and `swift` under `build` and the file is checked but nothing is
generated. Wire the outputs in when the screens move over. A generated Swift
palette imports UIKit, so keep it out of a macOS target's sources until the
generator emits an AppKit variant.

## Rules

- Screens use the generated names, never a hex literal.
- Generated files are never edited by hand; their header says so.
- `build_tokens.py --check` runs in CI. It fails on a missing role, a malformed
  value, a stale generated file or a missed ratio.
