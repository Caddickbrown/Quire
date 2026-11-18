# kit

The shared parts underneath an app's own design: helpers, wording, an
accessibility floor and the checks that enforce them. It deliberately contains
no visual components and no colour values: each app keeps its own look.

The kit is copied into each app (`kit/` at the repo root) rather than
installed as a package, so it needs no registry credentials in CI and works for
servers in any language. `kit/MANIFEST` records a hash of every file, and
`sync_kit.py --check` fails if a copy has been edited in place.

## What's here

| Path | What |
|---|---|
| `specs/TOKENS.md` | The `design/tokens.json` shape, required colour roles and contrast floor |
| `specs/WORDS.md` | Errors, empty states, relative dates, timestamps, the server connection block |
| `specs/MOTION.md` | Reduce Motion on every platform |
| `specs/KEYS.md`, `specs/keymap.json` | The shared keyboard map |
| `specs/PALETTE.md` | The command palette: commands, steps, previews, recents, the host, and the move from 0.5 |
| `tools/build_tokens.py` | Generates CSS and Swift palettes from `design/tokens.json`; `--check` for CI |
| `tools/kit_check.py` | Outside font hosts, missing Reduce Motion handling; warns on text sizes that don't scale |
| `tools/sync_kit.py` | Copies the kit into an app; `--check` for drift; `--manifest` after changing the kit |
| `swift/` | `Color(hex:)`, `Color(light:dark:)`, `Contrast`, `Font.scaled`, `KitMotion`, `RelativeDate`, `SyncStatus`, `CommandPalette` (the ⌘K menu's rules, keys, steps, previews and recents, and its host; the app draws the panel; see `specs/PALETTE.md`), `KitFieldEscape` (Esc and ⌘. on every field and the window; the app says what a press does) |
| `js/` | `relativeDate`, `statusLine` (ES modules, no dependencies) |
| `python/home_pairing.py` | The pairing rules every home server shares (`docs/DEVICES.md` section 1): codes, tidying, keys and their hashes, scopes, limits, firmware versions and what an update's signature covers. Standard library only |
| `rust/home-pairing/` | The same rules as a Rust crate (`sha2` only; callers pass random bytes in). Add it as a path dependency |
| `vectors/` | Shared test cases the Swift and JS halves must both pass; `pairing.json` and `ota.json` for the Python and Rust pairing halves (and any firmware) |
| `ci/kit.yml` | The standard GitHub Actions workflow running the three checks |
| `tests/` | The kit's own tests; never copied into an app |

## Adopting it in an app

1. Copy it in: `python3 path/to/kit/tools/sync_kit.py --into .`
2. Write `design/tokens.json` (see `specs/TOKENS.md`) and run
   `python3 kit/tools/build_tokens.py` until `--check` passes.
3. Add `kit/swift/` files to the app target as you need them, deleting the
   app's own versions of the same helpers.
4. Run `python3 kit/tools/kit_check.py --report` for a first look, then fix
   what it finds.
5. In CI: copy `kit/ci/kit.yml` to `.github/workflows/kit.yml`. It runs

   ```sh
   python3 kit/tools/sync_kit.py --check
   python3 kit/tools/build_tokens.py --check
   python3 kit/tools/kit_check.py
   ```

Paths the checker should skip (design prototypes, vendored code) go in
`kit.config.json` at the repo root: `{"exclude": ["sketches/"]}`.

## Changing the kit

Change it here, never in an app's copy. Then:

```sh
python3 -m unittest discover -s kit/tests      # tools, and the Swift palette rules
node --test kit/tests/vectors.test.mjs          # JS against the shared vectors
cargo test -p home-pairing                      # Rust pairing against the same vectors
python3 kit/tools/sync_kit.py --manifest        # refresh the hashes
```

Bump `VERSION` when an app would need to know, and sync it out.

## Not yet in the kit

- **Swift tests against `vectors/`.** The Swift halves mirror the JS line for
  line but haven't been run here; an XCTest that loads the vectors belongs in
  the first app that adopts them.
- **External display scene.** One shared scene for iPhone-to-monitor, with the
  app supplying the view.
- **Icon generator.** One `make_icons.py` with a per-app geometry file and a
  `--check`.
