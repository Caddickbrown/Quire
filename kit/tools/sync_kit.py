#!/usr/bin/env python3
"""Copy the kit into an app, and check that an app's copy hasn't drifted.

    python3 kit/tools/sync_kit.py --manifest           # in the kit's home: refresh kit/MANIFEST
    python3 kit/tools/sync_kit.py --into ../other-app  # copy this kit into another repo's kit/
    python3 kit/tools/sync_kit.py --check              # verify ./kit against its MANIFEST

kit/MANIFEST lists every shipped file with its SHA-256. It travels with the
copy, so --check needs nothing but the app's own repo: a file that no longer
matches its hash was edited in place, which the kit's rules forbid. Fix it in
the kit, then sync again.

kit/tests/ stays in the kit's home and is never copied.
"""

import argparse
import hashlib
import pathlib
import shutil
import sys

KIT = pathlib.Path(__file__).resolve().parent.parent
NOT_SHIPPED = {"tests", "__pycache__"}


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def shipped(kit: pathlib.Path) -> list[pathlib.Path]:
    out = []
    for path in sorted(kit.rglob("*")):
        rel = path.relative_to(kit)
        if path.is_file() and rel.as_posix() != "MANIFEST" and not NOT_SHIPPED.intersection(rel.parts):
            out.append(rel)
    return out


def read_manifest(kit: pathlib.Path) -> dict[str, str]:
    entries = {}
    for line in (kit / "MANIFEST").read_text().splitlines():
        if line.strip():
            digest, rel = line.split(None, 1)
            entries[rel] = digest
    return entries


def write_manifest(kit: pathlib.Path) -> None:
    lines = [f"{sha256(kit / rel)}  {rel.as_posix()}" for rel in shipped(kit)]
    (kit / "MANIFEST").write_text("\n".join(lines) + "\n")
    print(f"wrote {kit / 'MANIFEST'} ({len(lines)} files)")


def drift(kit: pathlib.Path) -> list[str]:
    if not (kit / "MANIFEST").exists():
        return [f"{kit}/MANIFEST is missing"]
    entries = read_manifest(kit)
    problems = []
    for rel, digest in entries.items():
        path = kit / rel
        if not path.exists():
            problems.append(f"missing: kit/{rel}")
        elif sha256(path) != digest:
            problems.append(f"changed: kit/{rel}")
    for rel in shipped(kit):
        if rel.as_posix() not in entries:
            problems.append(f"not in MANIFEST: kit/{rel.as_posix()}")
    return problems


def copy_into(target_repo: pathlib.Path, force: bool) -> int:
    source_problems = drift(KIT)
    if source_problems:
        print("this kit's MANIFEST is out of date; run --manifest first:")
        print("\n".join("  " + p for p in source_problems))
        return 1
    target = target_repo.resolve() / "kit"
    if target == KIT:
        print("refusing to copy the kit onto itself")
        return 1
    if (target / "MANIFEST").exists() and not force:
        local = drift(target)
        if local:
            print(f"{target} has local edits; move them into the kit, or pass --force to overwrite:")
            print("\n".join("  " + p for p in local))
            return 1
    if target.exists():
        shutil.rmtree(target)
    for rel in [*shipped(KIT), pathlib.Path("MANIFEST")]:
        dest = target / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(KIT / rel, dest)
    version = (KIT / "VERSION").read_text().strip()
    print(f"copied kit {version} into {target}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--manifest", action="store_true")
    mode.add_argument("--into", metavar="REPO")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--kit", default="kit", help="the kit folder to check (default ./kit)")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)

    if args.manifest:
        write_manifest(KIT)
        return 0
    if args.into:
        return copy_into(pathlib.Path(args.into), args.force)

    kit = pathlib.Path(args.kit).resolve()
    problems = drift(kit)
    if not problems:
        print(f"kit {(kit / 'VERSION').read_text().strip()} matches its MANIFEST")
        return 0
    home = (kit / "tests").exists()
    print("\n".join(problems))
    print("run sync_kit.py --manifest after changing the kit" if home
          else "kit/ was edited in this repo; make the change in the kit and sync again")
    return 1


if __name__ == "__main__":
    sys.exit(main())
