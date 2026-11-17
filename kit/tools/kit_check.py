#!/usr/bin/env python3
"""Check an app's source against the kit's rules that a palette check can't see.

    python3 kit/tools/kit_check.py               # check the current repo; exit 1 on errors
    python3 kit/tools/kit_check.py --root ../app
    python3 kit/tools/kit_check.py --report      # print everything, always exit 0

Rules (kit/specs/ explains each):

    outside-font      a web file loads fonts from Google's font hosts
    reduced-motion    CSS animates but no stylesheet has a prefers-reduced-motion block,
                      or Swift animates but nothing reads accessibilityReduceMotion
    system-size       .system(size:) does not follow the reader's text size — a warning,
                      since a fixed size is sometimes right (a canvas, a wall display).
                      `.custom(name, size:)` is fine: it scales with body text, and
                      relativeTo: ties it to a closer style.

Paths to skip go in an optional kit.config.json at the repo root:
    {"exclude": ["sketches/", "docs/prototypes/"]}
"""

import argparse
import json
import pathlib
import re
import sys

ALWAYS_SKIP = {".git", "node_modules", "dist", "build", "vendor", "Vendor", ".build", "DerivedData", "kit"}
WEB_SUFFIXES = {".html", ".css", ".js", ".mjs", ".ts", ".tsx", ".jsx", ".vue", ".svelte"}

OUTSIDE_FONT = re.compile(r"fonts\.(googleapis|gstatic)\.com")
CSS_MOTION = re.compile(r"(?<![-\w])(animation|transition)\s*:(?!\s*none\b)")
CSS_REDUCED = re.compile(r"prefers-reduced-motion")
SWIFT_MOTION = re.compile(r"withAnimation\s*\(|\.animation\s*\(|\.transition\s*\(")
SWIFT_REDUCED = re.compile(r"accessibilityReduceMotion|KitMotion")
SYSTEM_SIZE = re.compile(r"\.system\(size:")


def files(root: pathlib.Path, exclude: list[str]):
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root)
        if ALWAYS_SKIP.intersection(rel.parts[:-1]):
            continue
        if any(rel.as_posix().startswith(e) for e in exclude):
            continue
        yield path, rel


def check(root: pathlib.Path) -> list[tuple[str, str, str]]:
    """Return (level, location, message) findings, level being 'error' or 'warning'."""
    config_path = root / "kit.config.json"
    exclude = json.loads(config_path.read_text()).get("exclude", []) if config_path.exists() else []
    findings = []
    css_motion, css_reduced = [], False
    swift_motion, swift_reduced = [], False

    for path, rel in files(root, exclude):
        suffix = path.suffix
        if suffix not in WEB_SUFFIXES and suffix != ".swift":
            continue
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        lines = text.splitlines()

        if suffix in WEB_SUFFIXES:
            for n, line in enumerate(lines, 1):
                if OUTSIDE_FONT.search(line):
                    findings.append(("error", f"{rel}:{n}", "outside-font: load fonts from the app's own files"))
        if suffix == ".css":
            if CSS_REDUCED.search(text):
                css_reduced = True
            for n, line in enumerate(lines, 1):
                if CSS_MOTION.search(line):
                    css_motion.append(f"{rel}:{n}")
        if suffix == ".swift":
            if SWIFT_REDUCED.search(text):
                swift_reduced = True
            for n, line in enumerate(lines, 1):
                if SWIFT_MOTION.search(line):
                    swift_motion.append(f"{rel}:{n}")
                if SYSTEM_SIZE.search(line):
                    findings.append(("warning", f"{rel}:{n}",
                                     "system-size: a fixed system size does not follow the reader's text size"))

    if css_motion and not css_reduced:
        findings.append(("error", css_motion[0],
                         f"reduced-motion: {len(css_motion)} CSS animation(s) and no prefers-reduced-motion block"))
    if swift_motion and not swift_reduced:
        findings.append(("error", swift_motion[0],
                         f"reduced-motion: {len(swift_motion)} Swift animation(s) and nothing reads "
                         "accessibilityReduceMotion"))
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--report", action="store_true", help="never fail; for a first look at an existing app")
    args = parser.parse_args(argv)

    findings = check(pathlib.Path(args.root).resolve())
    for level, where, message in sorted(findings, key=lambda f: (f[0] != "error", f[1])):
        print(f"{level:7}  {where}  {message}")
    errors = sum(1 for f in findings if f[0] == "error")
    warnings = len(findings) - errors
    print(f"{errors} error(s), {warnings} warning(s)")
    return 0 if args.report or errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
