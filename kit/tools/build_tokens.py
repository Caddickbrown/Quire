#!/usr/bin/env python3
"""Build an app's palettes from its design/tokens.json, and check them.

    python3 kit/tools/build_tokens.py            # write the generated files
    python3 kit/tools/build_tokens.py --check    # exit 1 if stale, incomplete or low-contrast
    python3 kit/tools/build_tokens.py --tokens path/to/tokens.json

One source, two outputs, so the phone and the web can never disagree about a
colour. Where the outputs go is the app's choice, set in the tokens file:

    "build": {
      "css": "web/static/palette.generated.css",
      "swift": "ios/App/AppPalette.generated.swift",
      "swiftPalette": "AppPalette",
      "swiftMeasure": "AppMeasure",
      "checks": {
        "pairs": [["chromeInk", "chrome", 4.5]],
        "waive": [{"pair": ["inkSecondary", "bg"], "reason": "the platform's own grey"}]
      }
    }

Either output may be left out; with neither, the file is checked but nothing
is generated (an app recording its palette before it wires screens to it). The colour values are the app's own; what is
shared is the set of roles every app must define and the contrast each must
reach. See kit/specs/TOKENS.md.
"""

import argparse
import json
import pathlib
import re
import sys

REQUIRED_ROLES = [
    "bg", "raised", "ink", "inkSecondary", "rule", "hairline",
    "accent", "onAccent", "late", "done",
]

# (foreground, background, minimum ratio), checked in light and dark.
# `rule` and `hairline` are dividers, which WCAG does not hold to a ratio; an
# app that uses a line as the only edge of a field adds that pair itself.
DEFAULT_PAIRS = [
    ("ink", "bg", 4.5), ("ink", "raised", 4.5),
    ("inkSecondary", "bg", 4.5), ("inkSecondary", "raised", 4.5),
    ("accent", "bg", 3.0), ("onAccent", "accent", 4.5),
    ("late", "bg", 4.5), ("done", "bg", 3.0),
]

HEX = re.compile(r"^#[0-9A-Fa-f]{6}$")


def kebab(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "-", name).lower()


def luminance(hex_value: str) -> float:
    channels = [int(hex_value[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(a: str, b: str) -> float:
    hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def validate(t: dict) -> list[str]:
    """Problems with the file's shape: missing roles, malformed values."""
    colors = t.get("color", {})
    problems = [f"missing required role: {r}" for r in REQUIRED_ROLES if r not in colors]
    for key, v in colors.items():
        for mode in ("light", "dark"):
            if not HEX.match(str(v.get(mode, ""))):
                problems.append(f"{key}.{mode} is not a #RRGGBB colour: {v.get(mode)!r}")
        if not v.get("use"):
            problems.append(f"{key} has no `use` line")
    return problems


def contrast_failures(t: dict) -> tuple[list[str], list[str]]:
    """(failures, waived): pairs short of their ratio, split by whether the app
    has waived them with a reason under build.checks.waive."""
    colors = t.get("color", {})
    checks = t.get("build", {}).get("checks", {})
    extra = [tuple(p) for p in checks.get("pairs", [])]
    waivers = {tuple(w["pair"]): w["reason"] for w in checks.get("waive", [])}
    failures, waived = [], []
    for fg, bg, minimum in DEFAULT_PAIRS + extra:
        if fg not in colors or bg not in colors:
            continue  # reported by validate() when the role is required
        for mode in ("light", "dark"):
            ratio = contrast(colors[fg][mode], colors[bg][mode])
            if ratio < minimum:
                line = f"{mode}: {fg} on {bg} is {ratio:.2f}:1, needs {minimum}:1"
                if (fg, bg) in waivers:
                    waived.append(f"{line} (waived: {waivers[(fg, bg)]})")
                else:
                    failures.append(line)
    return failures, waived


def header(tokens_rel: str) -> str:
    return f"Generated from {tokens_rel} by kit/tools/build_tokens.py. Do not edit by hand."


def build_css(t: dict, head: str) -> str:
    colors = t["color"]
    light = "\n".join(f"  --{kebab(k)}: {v['light']};" for k, v in colors.items())
    dark = "\n".join(f"  --{kebab(k)}: {v['dark']};" for k, v in colors.items())
    extras = []
    if "font" in t:
        extras.append(f'  --font: "{t["font"]["family"]}", {t["font"]["fallback"]};')
    extras += [f"  --space-{k}: {v}px;" for k, v in t.get("space", {}).items()]
    extras += [f"  --radius-{k}: {v}px;" for k, v in t.get("radius", {}).items()]
    extras += [f"  --line-{kebab(k)}: {v}px;" for k, v in t.get("line", {}).items()]
    return (
        f"/* {head} */\n\n"
        f":root {{\n{light}\n" + "\n".join(extras) + "\n}\n\n"
        f"@media (prefers-color-scheme: dark) {{\n  :root:not([data-theme=\"light\"]) {{\n"
        + "\n".join("  " + line for line in dark.splitlines())
        + "\n  }\n}\n\n"
        f":root[data-theme=\"dark\"] {{\n{dark}\n}}\n"
    )


def hex_literal(value: str) -> str:
    return "0x" + value.lstrip("#").upper()


def build_swift(t: dict, head: str, palette: str, measure: str) -> str:
    lines = [f"// {head}", "", "import SwiftUI", "import UIKit", "",
             f"/// The {t.get('name', palette)} palette. Each colour resolves light or dark at draw time.",
             f"struct {palette} {{"]
    for key, v in t["color"].items():
        lines.append(f"    /// {v['use']}.")
        lines.append(f"    let {key} = {palette}.pair({hex_literal(v['light'])}, {hex_literal(v['dark'])})")
    lines += ["", f"    static let shared = {palette}()", "",
              "    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {",
              "        Color(UIColor { trait in",
              "            let rgb = trait.userInterfaceStyle == .dark ? dark : light",
              "            return UIColor(red: CGFloat((rgb >> 16) & 0xff) / 255,",
              "                           green: CGFloat((rgb >> 8) & 0xff) / 255,",
              "                           blue: CGFloat(rgb & 0xff) / 255, alpha: 1)",
              "        })",
              "    }",
              "}", ""]
    measures = []
    for k, v in t.get("space", {}).items():
        measures.append(f"    static let space{k.upper()}: CGFloat = {v}")
    for k, v in t.get("radius", {}).items():
        measures.append(f"    static let radius{k[0].upper() + k[1:]}: CGFloat = {v}")
    for k, v in t.get("line", {}).items():
        measures.append(f"    static let line{k[0].upper() + k[1:]}: CGFloat = {v}")
    if measures:
        lines += ["/// Spacing, radius and line widths from the same file.", f"enum {measure} {{"]
        lines += measures + ["}", ""]
    return "\n".join(lines)


def outputs(tokens_path: pathlib.Path, t: dict) -> dict[pathlib.Path, str]:
    root = tokens_path.resolve().parent.parent  # <root>/design/tokens.json
    build = t.get("build", {})
    head = header(tokens_path.resolve().relative_to(root).as_posix())
    out = {}
    if "css" in build:
        out[root / build["css"]] = build_css(t, head)
    if "swift" in build:
        out[root / build["swift"]] = build_swift(
            t, head, build.get("swiftPalette", "AppPalette"), build.get("swiftMeasure", "AppMeasure"))
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tokens", default="design/tokens.json")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)

    tokens_path = pathlib.Path(args.tokens)
    t = json.loads(tokens_path.read_text())
    root = tokens_path.resolve().parent.parent

    problems = validate(t)
    if problems:
        for p in problems:
            print(f"tokens: {p}")
        return 1
    failures, waived = contrast_failures(t)
    for f in failures:
        print(f"contrast: {f}")
    for w in waived:
        print(f"contrast: {w}")

    files = outputs(tokens_path, t)
    if not files:
        print("tokens: checked; no outputs configured, so nothing generated")
        return 1 if failures else 0
    if args.check:
        stale = [p for p, text in files.items() if not p.exists() or p.read_text() != text]
        for p in stale:
            print(f"out of date: {p.relative_to(root)}")
        return 1 if stale or failures else 0
    for path, text in files.items():
        path.write_text(text)
        print(f"wrote {path.relative_to(root)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
