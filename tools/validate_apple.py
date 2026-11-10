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
for _, rel, _ in generator["resources"]:
    assert (APPLE / "Quire" / rel).exists(), f"missing app resource: {rel}"
for _, rel in generator["widget_swift_files"] + generator["share_swift_files"] + generator["test_swift_files"]:
    assert (APPLE / rel).is_file(), f"missing target source: {rel}"
for _, rel in generator["uitest_swift_files"]:
    assert (APPLE / rel).is_file(), f"missing UI test source: {rel}"
ids = generator["IDs"]
ui_target = re.search(rf'{ids["uitestsTarget"]} /\* QuireUITests \*/ = \{{(.*?)\n\t\t\}};', project, re.S).group(1)
assert 'productType = "com.apple.product-type.bundle.ui-testing";' in ui_target and ids["uitestsDep"] in ui_target
assert f'TestTargetID = {ids["target"]};' in project, "UI tests do not name the app as their target"
ui_sources = re.search(rf'{ids["uitestsSources"]} /\* Sources \*/ = \{{(.*?)\n\t\t\}};', project, re.S).group(1)
assert ids["bf_UEditorUITests"] in ui_sources and "tbf_" not in ui_sources
for config in ["uitestsDebugConfig", "uitestsReleaseConfig"]:
    settings = re.search(rf'{ids[config]} /\* \w+ \*/ = \{{(.*?)\n\t\t\}};', project, re.S).group(1)
    assert 'SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";' in settings, "UI tests are iOS only"
    assert "TEST_TARGET_NAME = Quire;" in settings
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
app_scheme = ET.parse(APPLE / "Quire.xcodeproj/xcshareddata/xcschemes/Quire.xcscheme")
assert ids["uitestsTarget"] not in ET.tostring(app_scheme.getroot(), encoding="unicode"), "the Quire scheme must stay hostless"
ui_scheme_path = APPLE / "Quire.xcodeproj/xcshareddata/xcschemes/QuireUITests.xcscheme"
assert ui_scheme_path.read_text() == generator["uitests_scheme"](), "regenerate the Xcode project"
ui_scheme = ET.parse(ui_scheme_path).getroot()
assert [r.get("BlueprintIdentifier") for r in ui_scheme.iter("BuildableReference") if r.get("BlueprintName") == "QuireUITests"]
assert "path = ../CHANGELOG.md;" in project
assert f"MARKETING_VERSION = {generator['MARKETING_VERSION']};" in project
print("Apple project checks passed: app, widget, share extension, hostless tests, UI tests, Rust linkage, plists and scheme.")
