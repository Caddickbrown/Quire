#!/usr/bin/env python3
"""Check Apple project wiring on any host. This does not replace xcodebuild."""
from pathlib import Path
import plistlib
import re
import runpy
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
APPLE = ROOT / "apple"
generator = runpy.run_path(str(APPLE / "gen_pbxproj.py"))
project = generator["pbxproj"]()
assert project == generator["pbxproj"](), "project generation is not deterministic"
assert project == (APPLE / "Quire.xcodeproj/project.pbxproj").read_text(), "regenerate the Xcode project"

for key, rel, group in generator["swift_files"]:
    path = APPLE / "Quire" / rel
    if key == "QuireCore":
        assert rel == "../Generated/QuireCore.swift"
        continue  # emitted by build-core.sh, before Xcode starts
    assert path.is_file(), f"missing app source: {path}"
for _, rel in generator["widget_swift_files"] + generator["share_swift_files"] + generator["test_swift_files"]:
    assert (APPLE / rel).is_file(), f"missing target source: {rel}"
ids = generator["IDs"]
for phase in ["sourcesBuildPhase", "testsSources"]:
    section = re.search(rf'{ids[phase]} /\* Sources \*/ = \{{(.*?)\n\t\t\}};', project, re.S).group(1)
    prefix = "bf_" if phase == "sourcesBuildPhase" else "tbf_"
    for source in ["JournalStore", "CoreJournal", "AppleVault", "QuireCore", "JournalParser"]:
        assert ids[prefix + source] in section, f"{phase} missing {source}"
for phase, build_file in [("frameworksBuildPhase", "bf_coreFramework"), ("testsFrameworks", "tbf_coreFramework")]:
    section = re.search(rf'{ids[phase]} /\* Frameworks \*/ = \{{(.*?)\n\t\t\}};', project, re.S).group(1)
    assert ids[build_file] in section, f"{phase} does not link the Rust library"

for path in APPLE.rglob("*.plist"):
    plistlib.loads(path.read_bytes())
for path in APPLE.rglob("*.entitlements"):
    contents = plistlib.loads(path.read_bytes())
    assert contents.get("com.apple.security.application-groups") == ["group.com.caddickbrown.quire"], path
    assert "nook" not in path.read_text().lower(), path
ET.parse(APPLE / "Quire.xcodeproj/xcshareddata/xcschemes/Quire.xcscheme")
assert "path = ../CHANGELOG.md;" in project
assert f"MARKETING_VERSION = {generator['MARKETING_VERSION']};" in project
print("Apple project checks passed: app, widget, share extension, hostless tests, Rust linkage, plists and scheme.")
