# Motion

How much an app moves is its own choice. That it stops when asked is not.

- Every animation honours the system's Reduce Motion setting, on every platform
  the app ships. The change still happens; it just doesn't move.
- **Swift:** animate through `KitMotion.perform { }` and `.kitAnimation(_:value:)`
  (`kit/swift/Motion.swift`), or read `@Environment(\.accessibilityReduceMotion)`
  directly.
- **Web:** any stylesheet that animates is paired with a block like this:

  ```css
  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      animation-duration: 0.01ms !important;
      animation-iteration-count: 1 !important;
      transition-duration: 0.01ms !important;
      scroll-behavior: auto !important;
    }
  }
  ```

- An app with a lot of personality in its motion may offer its own setting
  (Full, Subtle, Off). The system setting still wins: Reduce Motion means Off.

`kit/tools/kit_check.py` fails when CSS animates with no `prefers-reduced-motion`
block, or when Swift animates and nothing reads `accessibilityReduceMotion`.
