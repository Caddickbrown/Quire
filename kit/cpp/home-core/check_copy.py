#!/usr/bin/env python3
"""Fails if this copy of home-core has been edited in place.

    python3 <copy>/check_copy.py

MANIFEST beside this file lists every file of the copy with its SHA-256 (the same format as the
kit's MANIFEST). A file that no longer matches, is missing, or isn't listed means the copy was
changed here, which isn't allowed: change home-core in app-kit (sample/kit/cpp/home-core) and copy
it again with `python3 <app-kit>/sample/kit/tools/sync_home_core.py --into <this folder>`.
"""
import hashlib
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
SKIP = {"MANIFEST", ".DS_Store"}


def problems(folder: pathlib.Path) -> list[str]:
    manifest = folder / "MANIFEST"
    if not manifest.exists():
        return [f"{folder}/MANIFEST is missing"]
    entries = {}
    for line in manifest.read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            digest, rel = line.split(None, 1)
            entries[rel] = digest
    out = []
    for rel, digest in entries.items():
        path = folder / rel
        if not path.is_file():
            out.append(f"missing: {rel}")
        elif hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            out.append(f"changed: {rel}")
    for path in sorted(folder.rglob("*")):
        rel = path.relative_to(folder).as_posix()
        if path.is_file() and path.name not in SKIP and "__pycache__" not in path.parts \
                and not path.name.startswith("._") and rel not in entries:
            out.append(f"not in MANIFEST: {rel}")
    return out


def main() -> int:
    found = problems(HERE)
    version = (HERE / "HOME_CORE_VERSION").read_text().strip() if (HERE / "HOME_CORE_VERSION").exists() else "?"
    if found:
        print(f"home-core copy at {HERE} (kit {version}) has been edited in place:")
        print("\n".join("  " + p for p in found))
        return 1
    print(f"home-core {version}: copy matches its MANIFEST")
    return 0


if __name__ == "__main__":
    sys.exit(main())
