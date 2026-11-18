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
    monitor-hidden    a palette command is left off the list on the monitor (`!onMonitor`,
                      `display != .monitor` and the like) — a warning. On the monitor every
                      phone action has to be doable from ⌘K: rebuild it in the palette (a
                      pick, typed or confirm step), mark it `onPhone:` if it truly needs the
                      phone, or say where its monitor version is with a comment on the line
                      or just above: `// monitor-alt: "Browse a category…" pick`.
                      specs/PALETTE.md, "Nothing hidden on the monitor".
    text-caret        a caret typed into the text ("|" or "▏" in a Text or string) — a warning. It takes
                      a letter's advance (a whole em for "▏", from the fallback font), so there's a gap
                      beside it. Draw it: a 2-point Rectangle next to the Text. `// caret-ok` on the line
                      for one that's kerned back to no width.
    ats-arbitrary     NSAllowsArbitraryLoads in an Info.plist or project.yml — a warning. Use
                      NSAllowsLocalNetworking and exception domains for the home server.
    plist-version     a literal CFBundleShortVersionString or CFBundleVersion — a warning. Use
                      $(MARKETING_VERSION) and $(CURRENT_PROJECT_VERSION) so one bump reaches every target.
    any-certificate   a URLSession delegate that hands back URLCredential(trust:) with no check in the
                      file (no SecTrustEvaluateWithError, no pin compared) — a warning.
    apple-double      a "._" file (an exFAT or network disk's resource fork) in the tree — a warning;
                      codesign and Xcode's copy phases fail on them.

GUIDE.md's "Recurring issues" has the story behind each.

Paths to skip go in an optional kit.config.json at the repo root:
    {"exclude": ["sketches/", "docs/prototypes/"]}
"""

import argparse
import json
import pathlib
import re
import sys

ALWAYS_SKIP = {".git", "node_modules", "dist", "build", "vendor", "Vendor", ".build", "DerivedData", "kit"}
CONFIG_SUFFIXES = {".plist", ".yml", ".yaml"}
WEB_SUFFIXES = {".html", ".css", ".js", ".mjs", ".ts", ".tsx", ".jsx", ".vue", ".svelte"}

OUTSIDE_FONT = re.compile(r"fonts\.(googleapis|gstatic)\.com")
CSS_MOTION = re.compile(r"(?<![-\w])(animation|transition)\s*:(?!\s*none\b)")
CSS_REDUCED = re.compile(r"prefers-reduced-motion")
SWIFT_MOTION = re.compile(r"withAnimation\s*\(|\.animation\s*\(|\.transition\s*\(")
SWIFT_REDUCED = re.compile(r"accessibilityReduceMotion|KitMotion")
SYSTEM_SIZE = re.compile(r"\.system\(size:")
MONITOR_FLAG = r"(?:[\w.]+\.)?(?:onMonitor|isMonitor|monitorShows|onTheMonitor|monitorIsUp|showsMonitor|monitor)\b(?![.(])"
MONITOR_HIDDEN = re.compile(
    r"!\s*\(?\s*" + MONITOR_FLAG
    + r"|\b(?:onMonitor|isMonitor)\s*==\s*false"
    + r"|\b(?:display|surface|screen)\s*!=\s*\.monitor\b"
    + r"|\b(?:display|surface)\s*==\s*\.phone\b"
    + r"|\bif\s+" + MONITOR_FLAG + r"\s*\{\s*return\s*\[\s*\]"
    + r"|\b(?:onMonitor|isMonitor)\s*\?\s*\[\s*\]")
# A file that builds palette rows: it lists a CommandList or makes rows.
BUILDS_ROWS = re.compile(r":\s*CommandList\b|\bCommandRow(?:<[^>]*>)?\s*\(|\bRow(?:\.toggle)?\(")
MONITOR_ALT = re.compile(r"monitor-alt:|\bonPhone:")
TEXT_CARET = re.compile(r'"[^"\n]*▏[^"\n]*"|\b(?:Text|AttributedString)\(\s*"\|"\s*\)|\?\s*"\|"\s*:\s*""')
CARET_OK = re.compile(r"caret-ok")
ATS_ARBITRARY = re.compile(r"NSAllowsArbitraryLoads(?:</key>\s*<true\s*/>|\s*:\s*(?:true|YES|yes)\b)")
PLIST_VERSION = re.compile(r"(CFBundleShortVersionString|CFBundleVersion)"
                           r"(?:</key>\s*<string>|\s*:\s*[\"']?)\s*\d")
ANY_CERT = re.compile(r"URLCredential\(\s*trust:")
CERT_CHECKED = re.compile(r"SecTrustEvaluate|SecCertificateCopyData|SecTrustCopyCertificateChain|"
                          r"SecTrustCopyKey|pinned|[Pp]in(?:s|ned)?\b.*==")


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
        if path.name.startswith("._"):
            findings.append(("warning", str(rel), "apple-double: a resource-fork file from an exFAT or network "
                             "disk; build on APFS (an APFS disk image on the SSD) and move these to the Trash"))
            continue
        if suffix in CONFIG_SUFFIXES:
            try:
                text = path.read_text()
            except (UnicodeDecodeError, OSError):
                continue
            for m in ATS_ARBITRARY.finditer(text):
                findings.append(("warning", f"{rel}:{text.count(chr(10), 0, m.start()) + 1}",
                                 "ats-arbitrary: NSAllowsArbitraryLoads sends the token in the clear to any host; "
                                 "use NSAllowsLocalNetworking and exception domains"))
            for m in PLIST_VERSION.finditer(text):
                findings.append(("warning", f"{rel}:{text.count(chr(10), 0, m.start()) + 1}",
                                 f"plist-version: a literal {m[1]}; use $(MARKETING_VERSION) / "
                                 "$(CURRENT_PROJECT_VERSION)"))
            continue
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
        if suffix == ".swift" and path.name != "CommandPalette.swift" and BUILDS_ROWS.search(text) \
                and ("CommandRow" in text or "CommandList" in text):
            for n, line in enumerate(lines, 1):
                code = line.split("//", 1)[0]
                if not MONITOR_HIDDEN.search(code):
                    continue
                if any(MONITOR_ALT.search(l) for l in lines[max(0, n - 4):n]):
                    continue
                findings.append(("warning", f"{rel}:{n}",
                                 "monitor-hidden: a palette command hidden on the monitor; rebuild it in the palette "
                                 "(a pick, typed or confirm step), mark it onPhone:, or name the alternative with "
                                 "// monitor-alt: …"))
        if suffix == ".swift":
            if SWIFT_REDUCED.search(text):
                swift_reduced = True
            cert_checked = bool(CERT_CHECKED.search(text))
            for n, line in enumerate(lines, 1):
                if TEXT_CARET.search(line.split("//", 1)[0]) and not CARET_OK.search(line):
                    findings.append(("warning", f"{rel}:{n}",
                                     "text-caret: a caret typed into the text takes a letter's width and leaves "
                                     "a gap; draw a 2-point Rectangle beside the Text"))
                if ANY_CERT.search(line) and not cert_checked:
                    findings.append(("warning", f"{rel}:{n}",
                                     "any-certificate: URLCredential(trust:) with no check in this file accepts "
                                     "any certificate; evaluate the trust or compare the pinned certificate"))
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
