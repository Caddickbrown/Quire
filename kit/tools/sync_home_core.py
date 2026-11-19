#!/usr/bin/env python3
"""Copy home-core (kit/cpp/home-core) into a firmware, and check a firmware's copy.

    python3 kit/tools/sync_home_core.py --into ../Pala/src/home/core
    python3 kit/tools/sync_home_core.py --check ../Pala/src/home/core

The copy gets home-core's files, the kit's vectors/ota.json, HOME_CORE_VERSION (the kit's version; not VERSION, which would shadow
the C++ <version> header on a case-insensitive disk) and a
MANIFEST of SHA-256 hashes. check_copy.py, which travels with the copy, checks it with nothing but
the firmware's own repo. --into refuses to overwrite a copy with local edits unless --force.
"""
import argparse
import hashlib
import importlib.util
import pathlib
import shutil
import sys

KIT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = KIT / "cpp" / "home-core"
EXTRA = {"vectors/ota.json": KIT / "vectors" / "ota.json",
         "tools/sign_firmware.py": KIT / "tools" / "sign_firmware.py",
         "tools/make_signing_keys.sh": KIT / "tools" / "make_signing_keys.sh"}


def source_files() -> dict[str, pathlib.Path]:
    files = {p.relative_to(SOURCE).as_posix(): p for p in sorted(SOURCE.rglob("*"))
             if p.is_file() and "__pycache__" not in p.parts and p.name != ".DS_Store" and not p.name.startswith("._")}
    files.update(EXTRA)
    return files


def checker():
    spec = importlib.util.spec_from_file_location("check_copy", SOURCE / "check_copy.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def copy_into(dest: pathlib.Path, force: bool) -> int:
    dest = dest.resolve()
    if dest == SOURCE or SOURCE in dest.parents:
        print("refusing to copy home-core into itself")
        return 1
    if (dest / "MANIFEST").exists() and not force:
        local = checker().problems(dest)
        if local:
            print(f"{dest} has local edits; move them into the kit, or pass --force:")
            print("\n".join("  " + p for p in local))
            return 1
    old = dest / "MANIFEST"
    if old.exists():   # remove what the last copy put there; anything else stays, and --check will name it
        for line in old.read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                (dest / line.split(None, 1)[1]).unlink(missing_ok=True)
    version = (KIT / "VERSION").read_text().strip()
    lines = [f"# home-core from app-kit kit {version}. Don't edit: change it in app-kit and copy again."]
    files = source_files()
    files["HOME_CORE_VERSION"] = KIT / "VERSION"
    for rel, src in sorted(files.items()):
        out = dest / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, out)
        lines.append(f"{hashlib.sha256(out.read_bytes()).hexdigest()}  {rel}")
    (dest / "MANIFEST").write_text("\n".join(lines) + "\n")
    print(f"copied home-core {version} into {dest} ({len(files)} files)")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--into", metavar="DIR")
    mode.add_argument("--check", metavar="DIR")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)
    if args.into:
        return copy_into(pathlib.Path(args.into), args.force)
    found = checker().problems(pathlib.Path(args.check).resolve())
    if found:
        print("\n".join(found))
        return 1
    print("home-core copy matches its MANIFEST")
    return 0


if __name__ == "__main__":
    sys.exit(main())
