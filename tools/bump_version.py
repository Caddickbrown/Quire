#!/usr/bin/env python3
"""Set Quire's version everywhere it is written by hand: `make bump V=x.y.z`.

The four version fields release.yml checks against the tag:

    Cargo.toml                        [workspace.package] version
    linux/src-tauri/Cargo.toml        [package] version
    linux/src-tauri/tauri.conf.json   "version"
    linux/package.json                "version"

and the two lock files that repeat them:

    Cargo.lock                the workspace's own packages
    linux/package-lock.json   the root "version", and packages[""]

Each file is edited as text, one field at a time, so nothing else in it moves;
every edit is then read back, and nothing is written unless all of them are
right. `make bump` goes on to regenerate the Xcode project, which takes its
version from Cargo.toml (apple/gen_pbxproj.py).

It does not touch CHANGELOG.md, commit, or tag: see "Releases" in CLAUDE.md.

    python3 -I tools/bump_version.py 0.12.0
    python3 -I tools/bump_version.py 0.12.0 --root /path/to/a/checkout
"""
import argparse
import json
import re
import sys
from pathlib import Path


class Stop(Exception):
    pass


def sub_once(text, pattern, version, what, flags=re.M):
    """Replace group 2 of the first match of `pattern` with the version."""
    m = re.search(pattern, text, flags)
    if not m:
        raise Stop("no version found in " + what)
    return text[:m.start(2)] + version + text[m.end(2):]


def toml_section_version(text, section, version, what):
    """`version = "…"` inside [section], and nowhere else."""
    m = re.search(r"(?ms)^\[%s\]\n(.*?)(?=^\[|\Z)" % re.escape(section), text)
    if not m:
        raise Stop("no [%s] in %s" % (section, what))
    body = sub_once(m.group(1), r'^(version = ")([^"]*)(")', version, "[%s] of %s" % (section, what))
    return text[:m.start(1)] + body + text[m.end(1):]


def toml_names(root, members):
    names = []
    for member in members:
        text = (root / member / "Cargo.toml").read_text(encoding="utf-8")
        m = re.search(r'(?ms)^\[package\]\n.*?^name = "([^"]+)"', text)
        if not m:
            raise Stop("no package name in %s/Cargo.toml" % member)
        names.append(m.group(1))
    return names


def bump(root, version):
    """Return {path: new text} for every file that changes."""
    out = {}

    cargo = root / "Cargo.toml"
    text = cargo.read_text(encoding="utf-8")
    new = toml_section_version(text, "workspace.package", version, "Cargo.toml")
    out[cargo] = new
    members = re.search(r"(?ms)^members = \[(.*?)\]", text)
    if not members:
        raise Stop("no workspace members in Cargo.toml")
    names = toml_names(root, re.findall(r'"([^"]+)"', members.group(1)))

    desk = root / "linux/src-tauri/Cargo.toml"
    out[desk] = toml_section_version(desk.read_text(encoding="utf-8"), "package", version, "linux/src-tauri/Cargo.toml")

    for rel in ("linux/src-tauri/tauri.conf.json", "linux/package.json"):
        p = root / rel
        new = sub_once(p.read_text(encoding="utf-8"), r'^(  "version": ")([^"]*)(")', version, rel)
        if json.loads(new)["version"] != version:
            raise Stop("%s: the top-level version did not take" % rel)
        out[p] = new

    # The workspace's own packages in Cargo.lock: they have no `source` line.
    lock = root / "Cargo.lock"
    text = lock.read_text(encoding="utf-8")
    for name in names:
        pattern = r'(\[\[package\]\]\nname = "%s"\nversion = ")([^"]*)("\n(?!source = ))' % re.escape(name)
        if len(re.findall(pattern, text)) != 1:
            raise Stop("Cargo.lock: expected one local package named " + name)
        text = sub_once(text, pattern, version, "Cargo.lock", flags=0)
    out[lock] = text

    plock = root / "linux/package-lock.json"
    text = plock.read_text(encoding="utf-8")
    text = sub_once(text, r'^(  "version": ")([^"]*)(")', version, "linux/package-lock.json")
    text = sub_once(text, r'(?s)("packages": \{\n    "": \{\n.*?^      "version": ")([^"]*)(")', version,
                    'packages[""] of linux/package-lock.json', flags=re.M | re.S)
    data = json.loads(text)
    if data["version"] != version or data["packages"][""]["version"] != version:
        raise Stop("linux/package-lock.json: the version did not take in both places")
    out[plock] = text
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("version", help="x.y.z")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent), help="the checkout (default: this one)")
    a = ap.parse_args(argv)
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", a.version):
        print("the version is MAJOR.MINOR.PATCH, e.g. 0.12.0 (no leading v)", file=sys.stderr)
        return 2
    root = Path(a.root)
    try:
        changes = bump(root, a.version)
    except (Stop, OSError, ValueError, KeyError) as e:
        print("nothing was changed: %s" % e, file=sys.stderr)
        return 1
    for path, text in changes.items():
        rel = path.relative_to(root)
        if path.read_text(encoding="utf-8") == text:
            print("  %-34s already %s" % (rel, a.version))
        else:
            path.write_text(text, encoding="utf-8")
            print("  %-34s → %s" % (rel, a.version))
    return 0


if __name__ == "__main__":
    sys.exit(main())
