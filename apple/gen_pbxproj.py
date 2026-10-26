#!/usr/bin/env python3
"""Generate Quire.xcodeproj/project.pbxproj for the multiplatform (iOS + macOS)
SwiftUI journaling app + its WidgetKit extension. Adapted from Pigeon's
generator; hand-editing the pbxproj is avoided — edit this file and re-run.

Two native targets are emitted:
  * Quire                  — the app (iphoneos, iphonesimulator, macosx)
  * QuireWidgetExtension   — the WidgetKit extension, embedded into the app.
Both are multiplatform so `make build` (macOS + iOS) works and Xcode can build
either platform. QuireShared.swift, QuireTheme.swift, the fonts and themes.json
are compiled/copied into both.

Usage:  python3 gen_pbxproj.py
"""

import getpass
import uuid
import os
import re
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))

# Version numbers, written once and emitted into every target's build settings
# (app, widget, share extension, test bundle) — bump MARKETING_VERSION here on
# release, per CHANGELOG.md's "How to update this file".
MARKETING_VERSION = re.search(r'^version = "([^"]+)"', (Path(HERE).parent / 'Cargo.toml').read_text(), re.M).group(1)
CURRENT_PROJECT_VERSION = '1'

# The Xcode version this project is stamped for. Xcode raises its "Update to
# recommended settings" sheet when the stamp is stale, whatever the settings
# say, so it lives in one place and is emitted into LastUpgradeCheck /
# LastSwiftUpdateCheck (pbxproj) and LastUpgradeVersion (schemes) alike.
# Encoding: major * 100 + minor * 10 — 2650 is Xcode 26.5.
XCODE_STAMP = '2650'

# Object ids are derived from their stable key rather than randomised, so a
# re-run of this generator produces a byte-identical pbxproj. `make build`
# regenerates the project first, and a random id per run turned every build
# into a several-hundred-line diff (and invalidated Xcode's per-object state).
# uuid5 over a fixed namespace is a pure function of the key.
def new_id(key):
    return uuid.uuid5(uuid.NAMESPACE_URL, 'quire:' + key).hex[:24].upper()

# (key, path relative to Quire/, containing group)
swift_files = [
    ('QuireApp',       'QuireApp.swift',              'Quire'),
    ('QuireIntents',   'QuireIntents.swift',          'Quire'),
    ('QuireShared',    'QuireShared.swift',           'Quire'),
    ('Theme',           'Theme.swift',                  'Quire'),
    ('Entry',           'Models/Entry.swift',           'Models'),
    ('JournalParser',   'Models/JournalParser.swift',   'Models'),
    ('Media',           'Models/Media.swift',           'Models'),
    ('SearchQuery',     'Models/SearchQuery.swift',     'Models'),
    ('ListContinuation','Models/ListContinuation.swift','Models'),
    ('JournalStore',    'Models/JournalStore.swift',    'Models'),
    ('CoreJournal',     'Models/CoreJournal.swift',     'Models'),
    ('AppleVault',      'Models/AppleVault.swift',      'Models'),
    ('ExternalTheme',   'Models/ExternalTheme.swift',   'Models'),
    ('QuireCore',       '../Generated/QuireCore.swift', 'Quire'),
    ('Templates',       'Models/Templates.swift',       'Models'),
    ('Importers',       'Models/Importers.swift',       'Models'),
    ('Transcription',   'Models/Transcription.swift',   'Models'),
    ('SpotlightIndexer','Models/SpotlightIndexer.swift','Models'),
    ('Reminders',       'Models/Reminders.swift',       'Models'),
    ('AppLock',         'Models/AppLock.swift',         'Models'),
    ('YearReview',      'Models/YearReview.swift',      'Models'),
    ('SavedSearches',   'Models/SavedSearches.swift',   'Models'),
    ('TimerActivity',   'Models/TimerActivity.swift',   'Models'),
    ('QuireTheme',     'Design/QuireTheme.swift',      'Design'),
    ('QuireComponents','Design/QuireComponents.swift', 'Design'),
    ('PhoneRoot',      'Design/PhoneRoot.swift',       'Design'),
    ('TodayScreen',    'Design/TodayScreen.swift',     'Design'),
    ('InboxScreen',    'Design/InboxScreen.swift',     'Design'),
    ('JournalScreen',  'Design/JournalScreen.swift',   'Design'),
    ('ReaderScreen',   'Design/ReaderScreen.swift',    'Design'),
    ('ComposerScreen', 'Design/ComposerScreen.swift',  'Design'),
    ('RetimeSheet',    'Design/RetimeSheet.swift',     'Design'),
    ('LookBackScreen', 'Design/LookBackScreen.swift',  'Design'),
    ('PhoneSettings',  'Design/PhoneSettings.swift',   'Design'),
    ('SwipeBack',      'Design/SwipeBack.swift',       'Design'),
    ('SearchScreen',   'Design/SearchScreen.swift',    'Design'),
    ('QuireKeys',      'Design/QuireKeys.swift',       'Design'),
    ('DeskViews',      'Design/DeskViews.swift',       'Design'),
    ('RootView',        'Views/RootView.swift',         'Views'),
    ('WritingView',     'Views/WritingView.swift',      'Views'),
    ('WritingTextEditor','Views/WritingTextEditor.swift','Views'),
    ('InboxView',       'Views/InboxView.swift',        'Views'),
    ('ArchiveView',     'Views/ArchiveView.swift',      'Views'),
    ('StreamView',      'Views/StreamView.swift',       'Views'),
    ('SearchView',      'Views/SearchView.swift',       'Views'),
    ('OnThisDayView',   'Views/OnThisDayView.swift',    'Views'),
    ('YearReviewView',  'Views/YearReviewView.swift',   'Views'),
    ('TrendsView',      'Views/TrendsView.swift',       'Views'),
    ('WelcomeView',     'Views/WelcomeView.swift',      'Views'),
    ('PDFExport',       'Views/PDFExport.swift',        'Views'),
    ('EntryDetailView', 'Views/EntryDetailView.swift',  'Views'),
    ('TagsView',        'Views/TagsView.swift',         'Views'),
    ('TagReviewView',   'Views/TagReviewView.swift',     'Views'),
    ('TagField',        'Views/TagField.swift',         'Views'),
    ('CalendarView',    'Views/CalendarView.swift',     'Views'),
    ('MediaPreview',    'Views/MediaPreview.swift',      'Views'),
    ('AssetsView',      'Views/AssetsView.swift',       'Views'),
    ('ExternalDisplay',  'Views/ExternalDisplayView.swift', 'Views'),
    ('ExternalSettings', 'Views/ExternalSettings.swift', 'Views'),
    ('KeyboardNav',      'Views/KeyboardNavigation.swift',   'Views'),
    ('ChangelogView',   'Views/ChangelogView.swift',    'Views'),
    ('AudioRecorder',   'Views/AudioRecorder.swift',    'Views'),
    ('VideoRecorderView','Views/VideoRecorderView.swift','Views'),
    ('SettingsView',    'Views/SettingsView.swift',     'Views'),
]

# (key, path relative to Quire/, fileType) — copied into the app Resources.
resources = [
    ('Assets', 'Assets.xcassets', 'folder.assetcatalog'),
    ('Fonts',  'fonts',           'folder'),
    ('SharedThemes', '../../themes.json', 'text.json'),
]

# Widget extension sources (own fileRefs; live in the QuireWidget/ group).
# QuireShared.swift and Design/QuireTheme.swift (shared with the app), the fonts
# and themes.json are also built into the widget, so it is set in the app's own
# look; they reuse the app's fileRefs via extra PBXBuildFile entries below.
widget_swift_files = [
    ('WQuireWidget',       'QuireWidget/QuireWidget.swift'),
    ('WQuireWidgetParts',  'QuireWidget/QuireWidgetParts.swift'),
    ('WQuireWidgetBundle', 'QuireWidget/QuireWidgetBundle.swift'),
    ('WQuireLockScreen',   'QuireWidget/QuireLockScreenWidget.swift'),
    ('WQuireControl',      'QuireWidget/QuireControlWidget.swift'),
]

# Share extension sources (own group; deliberately self-contained — it writes
# the App Group PendingShare handoff and needs no shared model code).
share_swift_files = [
    ('SShareViewController', 'QuireShare/ShareViewController.swift'),
]

# Unit-test sources. The test bundle also compiles the model files (reusing
# the app's fileRefs, like the widget does with QuireShared) so the tests run
# hostless — plain logic tests, no app launch.
test_swift_files = [
    ('TQuireTests', 'Tests/QuireTests.swift'),
    ('TStoreTests', 'Tests/JournalStoreTests.swift'),
]
# Model files compiled into the test bundle alongside the app.
#
# JournalStore is the @MainActor facade over Rust. The hostless tests compile
# it with the native Vault, adapter and generated bindings, and link the same
# Rust XCFramework as the app. `init(testingBase:)` supplies a temporary folder. Keep this list closed over its own
# dependencies; a view type leaking in is the signal it belongs in Models.
test_shared_models = ['Entry', 'JournalParser', 'Media', 'SearchQuery', 'ListContinuation',
                      'JournalStore', 'CoreJournal', 'AppleVault', 'QuireCore', 'QuireShared', 'Reminders', 'SpotlightIndexer']

# Allocate ids
IDs = {k: new_id(k) for k in [
    'project', 'mainGroup', 'quireGroup', 'modelsGroup', 'viewsGroup', 'designGroup',
    'iosGroup', 'macosGroup', 'productsGroup', 'target',
    'debugConfig', 'releaseConfig', 'projDebugConfig', 'projReleaseConfig',
    'configList', 'targetConfigList', 'sourcesBuildPhase', 'resourcesBuildPhase',
    'frameworksBuildPhase', 'product', 'iOSInfoPlist', 'macOSInfoPlist',
    # Widget extension
    'widgetGroup', 'widgetTarget', 'widgetProduct',
    'widgetSources', 'widgetFrameworks', 'widgetResources', 'embedExtensions',
    'widgetTargetConfigList', 'widgetDebugConfig', 'widgetReleaseConfig',
    'widgetDep', 'widgetProxy',
    'widgetInfoPlist', 'widgetIOSEnt', 'widgetMacEnt',
    'bf_embed_widget', 'wbf_QuireShared', 'wbf_QuireTheme', 'wbf_Fonts', 'wbf_Themes',
    # Share extension
    'shareGroup', 'shareTarget', 'shareProduct',
    'shareSources', 'shareFrameworks',
    'shareTargetConfigList', 'shareDebugConfig', 'shareReleaseConfig',
    'shareDep', 'shareProxy',
    'shareInfoPlist', 'shareIOSEnt', 'shareMacEnt',
    'bf_embed_share',
    # Unit tests
    'testsGroup', 'testsTarget', 'testsProduct',
    'testsSources', 'testsFrameworks',
    'testsTargetConfigList', 'testsDebugConfig', 'testsReleaseConfig',
    'parserChecksRef',
    # CHANGELOG.md lives at the repo root (not under Quire/), so it gets its own
    # fileRef in the project group and is copied into the app's Resources —
    # the in-app "What's New" screen renders it.
    'changelog', 'bf_changelog', 'coreFramework', 'bf_coreFramework', 'tbf_coreFramework',
]}
for name, _, _ in swift_files:
    IDs[name] = new_id(name)
    IDs['bf_' + name] = new_id('bf_' + name)
for name, _, _ in resources:
    IDs[name] = new_id(name)
    IDs['bf_' + name] = new_id('bf_' + name)
for name, _ in widget_swift_files:
    IDs[name] = new_id(name)
    IDs['bf_' + name] = new_id('bf_' + name)
for name, _ in share_swift_files:
    IDs[name] = new_id(name)
    IDs['bf_' + name] = new_id('bf_' + name)
for name, _ in test_swift_files:
    IDs[name] = new_id(name)
    IDs['bf_' + name] = new_id('bf_' + name)
for name in test_shared_models:
    IDs['tbf_' + name] = new_id('tbf_' + name)

# Truncated uuid5s are unique in practice, but a duplicate would silently
# produce a corrupt project — cheap to assert.
assert len(set(IDs.values())) == len(IDs), 'duplicate object id'

def base(path):
    return os.path.basename(path)

def pbxproj():
    L = []
    a = L.append

    a('// !$*UTF8*$!')
    a('{')
    a('\tarchiveVersion = 1;')
    a('\tclasses = {\n\t};')
    a('\tobjectVersion = 56;')
    a('\tobjects = {')
    a('')

    # ---- PBXBuildFile ----
    a('/* Begin PBXBuildFile section */')
    for name, path, _ in swift_files:
        a(f'\t\t{IDs["bf_"+name]} /* {base(path)} in Sources */ = {{isa = PBXBuildFile; fileRef = {IDs[name]} /* {base(path)} */; }};')
    for name, path, _ in resources:
        a(f'\t\t{IDs["bf_"+name]} /* {base(path)} in Resources */ = {{isa = PBXBuildFile; fileRef = {IDs[name]} /* {base(path)} */; }};')
    # Widget build files
    for name, path in widget_swift_files:
        a(f'\t\t{IDs["bf_"+name]} /* {base(path)} in Sources */ = {{isa = PBXBuildFile; fileRef = {IDs[name]} /* {base(path)} */; }};')
    a(f'\t\t{IDs["wbf_QuireShared"]} /* QuireShared.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {IDs["QuireShared"]} /* QuireShared.swift */; }};')
    a(f'\t\t{IDs["wbf_QuireTheme"]} /* QuireTheme.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {IDs["QuireTheme"]} /* QuireTheme.swift */; }};')
    a(f'\t\t{IDs["wbf_Fonts"]} /* fonts in Resources */ = {{isa = PBXBuildFile; fileRef = {IDs["Fonts"]} /* fonts */; }};')
    a(f'\t\t{IDs["wbf_Themes"]} /* themes.json in Resources */ = {{isa = PBXBuildFile; fileRef = {IDs["SharedThemes"]} /* themes.json */; }};')
    a(f'\t\t{IDs["bf_changelog"]} /* CHANGELOG.md in Resources */ = {{isa = PBXBuildFile; fileRef = {IDs["changelog"]} /* CHANGELOG.md */; }};')
    a(f'\t\t{IDs["bf_embed_widget"]} /* QuireWidgetExtension.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {IDs["widgetProduct"]} /* QuireWidgetExtension.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};')
    # Share extension build files
    for name, path in share_swift_files:
        a(f'\t\t{IDs["bf_"+name]} /* {base(path)} in Sources */ = {{isa = PBXBuildFile; fileRef = {IDs[name]} /* {base(path)} */; }};')
    a(f'\t\t{IDs["bf_embed_share"]} /* QuireShareExtension.appex in Embed Foundation Extensions */ = {{isa = PBXBuildFile; fileRef = {IDs["shareProduct"]} /* QuireShareExtension.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};')
    # Unit-test build files (test sources + the pure model files, reusing refs)
    for name, path in test_swift_files:
        a(f'\t\t{IDs["bf_"+name]} /* {base(path)} in Sources */ = {{isa = PBXBuildFile; fileRef = {IDs[name]} /* {base(path)} */; }};')
    for name in test_shared_models:
        fname = next(base(p) for k, p, g in swift_files if k == name)
        a(f'\t\t{IDs["tbf_"+name]} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {IDs[name]} /* {fname} */; }};')
    a(f'\t\t{IDs["bf_coreFramework"]} /* QuireCoreFFI.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {IDs["coreFramework"]}; }};')
    a(f'\t\t{IDs["tbf_coreFramework"]} /* QuireCoreFFI.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {IDs["coreFramework"]}; }};')
    a('/* End PBXBuildFile section */')
    a('')

    # ---- PBXContainerItemProxy ----
    a('/* Begin PBXContainerItemProxy section */')
    a(f'\t\t{IDs["widgetProxy"]} /* PBXContainerItemProxy */ = {{')
    a('\t\t\tisa = PBXContainerItemProxy;')
    a(f'\t\t\tcontainerPortal = {IDs["project"]} /* Project object */;')
    a('\t\t\tproxyType = 1;')
    a(f'\t\t\tremoteGlobalIDString = {IDs["widgetTarget"]};')
    a('\t\t\tremoteInfo = QuireWidgetExtension;')
    a('\t\t};')
    a(f'\t\t{IDs["shareProxy"]} /* PBXContainerItemProxy */ = {{')
    a('\t\t\tisa = PBXContainerItemProxy;')
    a(f'\t\t\tcontainerPortal = {IDs["project"]} /* Project object */;')
    a('\t\t\tproxyType = 1;')
    a(f'\t\t\tremoteGlobalIDString = {IDs["shareTarget"]};')
    a('\t\t\tremoteInfo = QuireShareExtension;')
    a('\t\t};')
    a('/* End PBXContainerItemProxy section */')
    a('')

    # ---- PBXCopyFilesBuildPhase (Embed App Extensions) ----
    a('/* Begin PBXCopyFilesBuildPhase section */')
    a(f'\t\t{IDs["embedExtensions"]} /* Embed Foundation Extensions */ = {{')
    a('\t\t\tisa = PBXCopyFilesBuildPhase;')
    a('\t\t\tbuildActionMask = 2147483647;')
    a('\t\t\tdstPath = "";')
    a('\t\t\tdstSubfolderSpec = 13;')
    a('\t\t\tfiles = (')
    a(f'\t\t\t\t{IDs["bf_embed_widget"]} /* QuireWidgetExtension.appex in Embed Foundation Extensions */,')
    a(f'\t\t\t\t{IDs["bf_embed_share"]} /* QuireShareExtension.appex in Embed Foundation Extensions */,')
    a('\t\t\t);')
    a('\t\t\tname = "Embed Foundation Extensions";')
    a('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    a('\t\t};')
    a('/* End PBXCopyFilesBuildPhase section */')
    a('')

    # ---- PBXFileReference ----
    a('/* Begin PBXFileReference section */')
    for name, path, _ in swift_files:
        a(f'\t\t{IDs[name]} /* {base(path)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path if name == "QuireCore" else base(path)}; sourceTree = "<group>"; }};')
    for name, path, ftype in resources:
        a(f'\t\t{IDs[name]} /* {base(path)} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {path if name == "SharedThemes" else base(path)}; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["iOSInfoPlist"]} /* iOS/Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["macOSInfoPlist"]} /* macOS/Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["product"]} /* Quire.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Quire.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    a(f'\t\t{IDs["changelog"]} /* CHANGELOG.md */ = {{isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = ../CHANGELOG.md; sourceTree = "<group>"; }};')
    # Widget file refs
    for name, path in widget_swift_files:
        a(f'\t\t{IDs[name]} /* {base(path)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {base(path)}; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["widgetInfoPlist"]} /* QuireWidget/Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["widgetIOSEnt"]} /* QuireWidget-iOS.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = "QuireWidget-iOS.entitlements"; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["widgetMacEnt"]} /* QuireWidget-macOS.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = "QuireWidget-macOS.entitlements"; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["widgetProduct"]} /* QuireWidgetExtension.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = QuireWidgetExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; }};')
    # Share extension file refs
    for name, path in share_swift_files:
        a(f'\t\t{IDs[name]} /* {base(path)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {base(path)}; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["shareInfoPlist"]} /* QuireShare/Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["shareIOSEnt"]} /* QuireShare-iOS.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = "QuireShare-iOS.entitlements"; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["shareMacEnt"]} /* QuireShare-macOS.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = "QuireShare-macOS.entitlements"; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["shareProduct"]} /* QuireShareExtension.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = QuireShareExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; }};')
    # Test file refs (ParserChecks is referenced for visibility; `make check`
    # compiles it standalone — it's in no Xcode target)
    for name, path in test_swift_files:
        a(f'\t\t{IDs[name]} /* {base(path)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {base(path)}; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["parserChecksRef"]} /* ParserChecks.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ParserChecks.swift; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["testsProduct"]} /* QuireTests.xctest */ = {{isa = PBXFileReference; explicitFileType = "wrapper.cfbundle"; includeInIndex = 0; path = QuireTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')
    a(f'\t\t{IDs["coreFramework"]} /* QuireCoreFFI.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = Frameworks/QuireCoreFFI.xcframework; sourceTree = "<group>"; }};')
    a('/* End PBXFileReference section */')
    a('')

    # ---- PBXFrameworksBuildPhase ----
    a('/* Begin PBXFrameworksBuildPhase section */')
    for fid, label in [(IDs["frameworksBuildPhase"], 'Frameworks'),
                       (IDs["widgetFrameworks"], 'Frameworks'),
                       (IDs["shareFrameworks"], 'Frameworks'),
                       (IDs["testsFrameworks"], 'Frameworks')]:
        a(f'\t\t{fid} /* {label} */ = {{')
        a('\t\t\tisa = PBXFrameworksBuildPhase;')
        a('\t\t\tbuildActionMask = 2147483647;')
        a('\t\t\tfiles = (')
        if fid in [IDs['frameworksBuildPhase'], IDs['testsFrameworks']]:
            key = 'bf_coreFramework' if fid == IDs['frameworksBuildPhase'] else 'tbf_coreFramework'
            a(f'\t\t\t\t{IDs[key]} /* QuireCoreFFI.xcframework in Frameworks */,')
        a('\t\t\t);')
        a('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
        a('\t\t};')
    a('/* End PBXFrameworksBuildPhase section */')
    a('')

    # ---- PBXGroup ----
    a('/* Begin PBXGroup section */')

    # main group
    a(f'\t\t{IDs["mainGroup"]} = {{')
    a('\t\t\tisa = PBXGroup;')
    a('\t\t\tchildren = (')
    a(f'\t\t\t\t{IDs["quireGroup"]} /* Quire */,')
    a(f'\t\t\t\t{IDs["widgetGroup"]} /* QuireWidget */,')
    a(f'\t\t\t\t{IDs["shareGroup"]} /* QuireShare */,')
    a(f'\t\t\t\t{IDs["testsGroup"]} /* Tests */,')
    a(f'\t\t\t\t{IDs["changelog"]} /* CHANGELOG.md */,')
    a(f'\t\t\t\t{IDs["coreFramework"]} /* QuireCoreFFI.xcframework */,')
    a(f'\t\t\t\t{IDs["productsGroup"]} /* Products */,')
    a('\t\t\t);')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    # products
    a(f'\t\t{IDs["productsGroup"]} /* Products */ = {{')
    a('\t\t\tisa = PBXGroup;')
    a('\t\t\tchildren = (')
    a(f'\t\t\t\t{IDs["product"]} /* Quire.app */,')
    a(f'\t\t\t\t{IDs["widgetProduct"]} /* QuireWidgetExtension.appex */,')
    a(f'\t\t\t\t{IDs["shareProduct"]} /* QuireShareExtension.appex */,')
    a(f'\t\t\t\t{IDs["testsProduct"]} /* QuireTests.xctest */,')
    a('\t\t\t);')
    a('\t\t\tname = Products;')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    # Quire source group
    top = [n for n, p, g in swift_files if g == 'Quire']
    a(f'\t\t{IDs["quireGroup"]} /* Quire */ = {{')
    a('\t\t\tisa = PBXGroup;')
    a('\t\t\tchildren = (')
    for n in top:
        a(f'\t\t\t\t{IDs[n]} /* {next(base(p) for k,p,g in swift_files if k==n)} */,')
    a(f'\t\t\t\t{IDs["modelsGroup"]} /* Models */,')
    a(f'\t\t\t\t{IDs["viewsGroup"]} /* Views */,')
    a(f'\t\t\t\t{IDs["designGroup"]} /* Design */,')
    for n, p, _ in resources:
        a(f'\t\t\t\t{IDs[n]} /* {base(p)} */,')
    a(f'\t\t\t\t{IDs["iosGroup"]} /* iOS */,')
    a(f'\t\t\t\t{IDs["macosGroup"]} /* macOS */,')
    a('\t\t\t);')
    a('\t\t\tpath = Quire;')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    # subgroups Models / Views
    for grp, gid, folder in [('Models', IDs['modelsGroup'], 'Models'),
                             ('Views', IDs['viewsGroup'], 'Views'),
                             ('Design', IDs['designGroup'], 'Design')]:
        members = [n for n, p, g in swift_files if g == grp]
        a(f'\t\t{gid} /* {grp} */ = {{')
        a('\t\t\tisa = PBXGroup;')
        a('\t\t\tchildren = (')
        for n in members:
            a(f'\t\t\t\t{IDs[n]} /* {next(base(p) for k,p,g in swift_files if k==n)} */,')
        a('\t\t\t);')
        a(f'\t\t\tpath = {folder};')
        a('\t\t\tsourceTree = "<group>";')
        a('\t\t};')

    # iOS group
    a(f'\t\t{IDs["iosGroup"]} /* iOS */ = {{')
    a('\t\t\tisa = PBXGroup;')
    a('\t\t\tchildren = (')
    a(f'\t\t\t\t{IDs["iOSInfoPlist"]} /* Info.plist */,')
    a('\t\t\t);')
    a('\t\t\tpath = iOS;')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    # macOS group
    a(f'\t\t{IDs["macosGroup"]} /* macOS */ = {{')
    a('\t\t\tisa = PBXGroup;')
    a('\t\t\tchildren = (')
    a(f'\t\t\t\t{IDs["macOSInfoPlist"]} /* Info.plist */,')
    a('\t\t\t);')
    a('\t\t\tpath = macOS;')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    # QuireWidget group
    a(f'\t\t{IDs["widgetGroup"]} /* QuireWidget */ = {{')
    a('\t\t\tisa = PBXGroup;')
    a('\t\t\tchildren = (')
    for n, p in widget_swift_files:
        a(f'\t\t\t\t{IDs[n]} /* {base(p)} */,')
    a(f'\t\t\t\t{IDs["widgetInfoPlist"]} /* Info.plist */,')
    a(f'\t\t\t\t{IDs["widgetIOSEnt"]} /* QuireWidget-iOS.entitlements */,')
    a(f'\t\t\t\t{IDs["widgetMacEnt"]} /* QuireWidget-macOS.entitlements */,')
    a('\t\t\t);')
    a('\t\t\tpath = QuireWidget;')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    # QuireShare group
    a(f'\t\t{IDs["shareGroup"]} /* QuireShare */ = {{')
    a('\t\t\tisa = PBXGroup;')
    a('\t\t\tchildren = (')
    for n, p in share_swift_files:
        a(f'\t\t\t\t{IDs[n]} /* {base(p)} */,')
    a(f'\t\t\t\t{IDs["shareInfoPlist"]} /* Info.plist */,')
    a(f'\t\t\t\t{IDs["shareIOSEnt"]} /* QuireShare-iOS.entitlements */,')
    a(f'\t\t\t\t{IDs["shareMacEnt"]} /* QuireShare-macOS.entitlements */,')
    a('\t\t\t);')
    a('\t\t\tpath = QuireShare;')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    # Tests group
    a(f'\t\t{IDs["testsGroup"]} /* Tests */ = {{')
    a('\t\t\tisa = PBXGroup;')
    a('\t\t\tchildren = (')
    for n, p in test_swift_files:
        a(f'\t\t\t\t{IDs[n]} /* {base(p)} */,')
    a(f'\t\t\t\t{IDs["parserChecksRef"]} /* ParserChecks.swift */,')
    a('\t\t\t);')
    a('\t\t\tpath = Tests;')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    a('/* End PBXGroup section */')
    a('')

    # ---- PBXNativeTarget ----
    a('/* Begin PBXNativeTarget section */')
    # App target
    a(f'\t\t{IDs["target"]} /* Quire */ = {{')
    a('\t\t\tisa = PBXNativeTarget;')
    a(f'\t\t\tbuildConfigurationList = {IDs["targetConfigList"]} /* Build configuration list for PBXNativeTarget "Quire" */;')
    a('\t\t\tbuildPhases = (')
    a(f'\t\t\t\t{IDs["sourcesBuildPhase"]} /* Sources */,')
    a(f'\t\t\t\t{IDs["frameworksBuildPhase"]} /* Frameworks */,')
    a(f'\t\t\t\t{IDs["resourcesBuildPhase"]} /* Resources */,')
    a(f'\t\t\t\t{IDs["embedExtensions"]} /* Embed Foundation Extensions */,')
    a('\t\t\t);')
    a('\t\t\tbuildRules = (\n\t\t\t);')
    a('\t\t\tdependencies = (')
    a(f'\t\t\t\t{IDs["widgetDep"]} /* PBXTargetDependency */,')
    a(f'\t\t\t\t{IDs["shareDep"]} /* PBXTargetDependency */,')
    a('\t\t\t);')
    a('\t\t\tname = Quire;')
    a('\t\t\tproductName = Quire;')
    a(f'\t\t\tproductReference = {IDs["product"]} /* Quire.app */;')
    a('\t\t\tproductType = "com.apple.product-type.application";')
    a('\t\t};')
    # Widget target
    a(f'\t\t{IDs["widgetTarget"]} /* QuireWidgetExtension */ = {{')
    a('\t\t\tisa = PBXNativeTarget;')
    a(f'\t\t\tbuildConfigurationList = {IDs["widgetTargetConfigList"]} /* Build configuration list for PBXNativeTarget "QuireWidgetExtension" */;')
    a('\t\t\tbuildPhases = (')
    a(f'\t\t\t\t{IDs["widgetSources"]} /* Sources */,')
    a(f'\t\t\t\t{IDs["widgetFrameworks"]} /* Frameworks */,')
    a(f'\t\t\t\t{IDs["widgetResources"]} /* Resources */,')
    a('\t\t\t);')
    a('\t\t\tbuildRules = (\n\t\t\t);')
    a('\t\t\tdependencies = (\n\t\t\t);')
    a('\t\t\tname = QuireWidgetExtension;')
    a('\t\t\tproductName = QuireWidgetExtension;')
    a(f'\t\t\tproductReference = {IDs["widgetProduct"]} /* QuireWidgetExtension.appex */;')
    a('\t\t\tproductType = "com.apple.product-type.app-extension";')
    a('\t\t};')
    # Share extension target
    a(f'\t\t{IDs["shareTarget"]} /* QuireShareExtension */ = {{')
    a('\t\t\tisa = PBXNativeTarget;')
    a(f'\t\t\tbuildConfigurationList = {IDs["shareTargetConfigList"]} /* Build configuration list for PBXNativeTarget "QuireShareExtension" */;')
    a('\t\t\tbuildPhases = (')
    a(f'\t\t\t\t{IDs["shareSources"]} /* Sources */,')
    a(f'\t\t\t\t{IDs["shareFrameworks"]} /* Frameworks */,')
    a('\t\t\t);')
    a('\t\t\tbuildRules = (\n\t\t\t);')
    a('\t\t\tdependencies = (\n\t\t\t);')
    a('\t\t\tname = QuireShareExtension;')
    a('\t\t\tproductName = QuireShareExtension;')
    a(f'\t\t\tproductReference = {IDs["shareProduct"]} /* QuireShareExtension.appex */;')
    a('\t\t\tproductType = "com.apple.product-type.app-extension";')
    a('\t\t};')
    # Unit-test target (hostless logic tests over the pure model files)
    a(f'\t\t{IDs["testsTarget"]} /* QuireTests */ = {{')
    a('\t\t\tisa = PBXNativeTarget;')
    a(f'\t\t\tbuildConfigurationList = {IDs["testsTargetConfigList"]} /* Build configuration list for PBXNativeTarget "QuireTests" */;')
    a('\t\t\tbuildPhases = (')
    a(f'\t\t\t\t{IDs["testsSources"]} /* Sources */,')
    a(f'\t\t\t\t{IDs["testsFrameworks"]} /* Frameworks */,')
    a('\t\t\t);')
    a('\t\t\tbuildRules = (\n\t\t\t);')
    a('\t\t\tdependencies = (\n\t\t\t);')
    a('\t\t\tname = QuireTests;')
    a('\t\t\tproductName = QuireTests;')
    a(f'\t\t\tproductReference = {IDs["testsProduct"]} /* QuireTests.xctest */;')
    a('\t\t\tproductType = "com.apple.product-type.bundle.unit-test";')
    a('\t\t};')
    a('/* End PBXNativeTarget section */')
    a('')

    # ---- PBXProject ----
    a('/* Begin PBXProject section */')
    a(f'\t\t{IDs["project"]} /* Project object */ = {{')
    a('\t\t\tisa = PBXProject;')
    a('\t\t\tattributes = {')
    a('\t\t\t\tBuildIndependentTargetsInParallel = 1;')
    a(f'\t\t\t\tLastSwiftUpdateCheck = {XCODE_STAMP};')
    a(f'\t\t\t\tLastUpgradeCheck = {XCODE_STAMP};')
    a('\t\t\t\tTargetAttributes = {')
    a(f'\t\t\t\t\t{IDs["target"]} = {{')
    a('\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;')
    a('\t\t\t\t\t};')
    a(f'\t\t\t\t\t{IDs["widgetTarget"]} = {{')
    a('\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;')
    a('\t\t\t\t\t};')
    a(f'\t\t\t\t\t{IDs["shareTarget"]} = {{')
    a('\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;')
    a('\t\t\t\t\t};')
    a(f'\t\t\t\t\t{IDs["testsTarget"]} = {{')
    a('\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;')
    a('\t\t\t\t\t};')
    a('\t\t\t\t};')
    a('\t\t\t};')
    a(f'\t\t\tbuildConfigurationList = {IDs["configList"]} /* Build configuration list for PBXProject "Quire" */;')
    a('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    a('\t\t\tdevelopmentRegion = en;')
    a('\t\t\thasScannedForEncodings = 0;')
    a('\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);')
    a(f'\t\t\tmainGroup = {IDs["mainGroup"]};')
    a(f'\t\t\tproductRefGroup = {IDs["productsGroup"]} /* Products */;')
    a('\t\t\tprojectDirPath = "";')
    a('\t\t\tprojectRoot = "";')
    a('\t\t\ttargets = (')
    a(f'\t\t\t\t{IDs["target"]} /* Quire */,')
    a(f'\t\t\t\t{IDs["widgetTarget"]} /* QuireWidgetExtension */,')
    a(f'\t\t\t\t{IDs["shareTarget"]} /* QuireShareExtension */,')
    a(f'\t\t\t\t{IDs["testsTarget"]} /* QuireTests */,')
    a('\t\t\t);')
    a('\t\t};')
    a('/* End PBXProject section */')
    a('')

    # ---- PBXResourcesBuildPhase ----
    a('/* Begin PBXResourcesBuildPhase section */')
    a(f'\t\t{IDs["resourcesBuildPhase"]} /* Resources */ = {{')
    a('\t\t\tisa = PBXResourcesBuildPhase;')
    a('\t\t\tbuildActionMask = 2147483647;')
    a('\t\t\tfiles = (')
    for name, path, _ in resources:
        a(f'\t\t\t\t{IDs["bf_"+name]} /* {base(path)} in Resources */,')
    a(f'\t\t\t\t{IDs["bf_changelog"]} /* CHANGELOG.md in Resources */,')
    a('\t\t\t);')
    a('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    a('\t\t};')
    # Widget resources: the fonts and themes.json (the looks), no asset catalog
    a(f'\t\t{IDs["widgetResources"]} /* Resources */ = {{')
    a('\t\t\tisa = PBXResourcesBuildPhase;')
    a('\t\t\tbuildActionMask = 2147483647;')
    a('\t\t\tfiles = (')
    a(f'\t\t\t\t{IDs["wbf_Fonts"]} /* fonts in Resources */,')
    a(f'\t\t\t\t{IDs["wbf_Themes"]} /* themes.json in Resources */,')
    a('\t\t\t);')
    a('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    a('\t\t};')
    a('/* End PBXResourcesBuildPhase section */')
    a('')

    # ---- PBXSourcesBuildPhase ----
    a('/* Begin PBXSourcesBuildPhase section */')
    a(f'\t\t{IDs["sourcesBuildPhase"]} /* Sources */ = {{')
    a('\t\t\tisa = PBXSourcesBuildPhase;')
    a('\t\t\tbuildActionMask = 2147483647;')
    a('\t\t\tfiles = (')
    for name, path, _ in swift_files:
        a(f'\t\t\t\t{IDs["bf_"+name]} /* {base(path)} in Sources */,')
    a('\t\t\t);')
    a('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    a('\t\t};')
    # Widget sources
    a(f'\t\t{IDs["widgetSources"]} /* Sources */ = {{')
    a('\t\t\tisa = PBXSourcesBuildPhase;')
    a('\t\t\tbuildActionMask = 2147483647;')
    a('\t\t\tfiles = (')
    for name, path in widget_swift_files:
        a(f'\t\t\t\t{IDs["bf_"+name]} /* {base(path)} in Sources */,')
    a(f'\t\t\t\t{IDs["wbf_QuireShared"]} /* QuireShared.swift in Sources */,')
    a(f'\t\t\t\t{IDs["wbf_QuireTheme"]} /* QuireTheme.swift in Sources */,')
    a('\t\t\t);')
    a('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    a('\t\t};')
    # Share extension sources
    a(f'\t\t{IDs["shareSources"]} /* Sources */ = {{')
    a('\t\t\tisa = PBXSourcesBuildPhase;')
    a('\t\t\tbuildActionMask = 2147483647;')
    a('\t\t\tfiles = (')
    for name, path in share_swift_files:
        a(f'\t\t\t\t{IDs["bf_"+name]} /* {base(path)} in Sources */,')
    a('\t\t\t);')
    a('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    a('\t\t};')
    # Test sources
    a(f'\t\t{IDs["testsSources"]} /* Sources */ = {{')
    a('\t\t\tisa = PBXSourcesBuildPhase;')
    a('\t\t\tbuildActionMask = 2147483647;')
    a('\t\t\tfiles = (')
    for name, path in test_swift_files:
        a(f'\t\t\t\t{IDs["bf_"+name]} /* {base(path)} in Sources */,')
    for name in test_shared_models:
        fname = next(base(p) for k, p, g in swift_files if k == name)
        a(f'\t\t\t\t{IDs["tbf_"+name]} /* {fname} in Sources */,')
    a('\t\t\t);')
    a('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
    a('\t\t};')
    a('/* End PBXSourcesBuildPhase section */')
    a('')

    # ---- PBXTargetDependency ----
    a('/* Begin PBXTargetDependency section */')
    a(f'\t\t{IDs["widgetDep"]} /* PBXTargetDependency */ = {{')
    a('\t\t\tisa = PBXTargetDependency;')
    a('\t\t\ttarget = ' + IDs["widgetTarget"] + ' /* QuireWidgetExtension */;')
    a(f'\t\t\ttargetProxy = {IDs["widgetProxy"]} /* PBXContainerItemProxy */;')
    a('\t\t};')
    a(f'\t\t{IDs["shareDep"]} /* PBXTargetDependency */ = {{')
    a('\t\t\tisa = PBXTargetDependency;')
    a('\t\t\ttarget = ' + IDs["shareTarget"] + ' /* QuireShareExtension */;')
    a(f'\t\t\ttargetProxy = {IDs["shareProxy"]} /* PBXContainerItemProxy */;')
    a('\t\t};')
    a('/* End PBXTargetDependency section */')
    a('')

    # ---- XCBuildConfiguration ----
    a('/* Begin XCBuildConfiguration section */')

    def project_config(cfg_id, name, debug):
        a(f'\t\t{cfg_id} /* {name} */ = {{')
        a('\t\t\tisa = XCBuildConfiguration;')
        a('\t\t\tbuildSettings = {')
        a('\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;')
        # Note the SWIFT_ in the middle: ASSETCATALOG_COMPILER_GENERATE_ASSET_
        # SYMBOL_EXTENSIONS is not a real setting, and Xcode will happily echo
        # it back from -showBuildSettings as a user-defined key while ignoring
        # it. The one Xcode's validator checks is this (default NO).
        a('\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;')
        a('\t\t\t\tCLANG_ENABLE_MODULES = YES;')
        # No search path to Generated/Headers: the XCFramework carries the
        # QuireCoreFFI headers and module map, and Xcode copies them into
        # $(BUILT_PRODUCTS_DIR)/include for the targets that link it. A second
        # path here defines the module twice ("redefinition of module").
        a('\t\t\t\tOTHER_LDFLAGS = "$(inherited) -lc++ -liconv -framework CoreFoundation -framework Security";')
        a('\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;')
        a('\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;')
        # Xcode's "recommended warnings" set. Kept here rather than accepted
        # through Xcode's *Update to recommended settings* sheet, which edits
        # the pbxproj by hand — the next `make project` would wipe it and the
        # prompt would come straight back. Most are Objective-C only and inert
        # in a pure-Swift project; they're set so the sheet stops asking.
        for setting in [
            'CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING = YES',
            'CLANG_WARN_BOOL_CONVERSION = YES',
            'CLANG_WARN_COMMA = YES',
            'CLANG_WARN_CONSTANT_CONVERSION = YES',
            'CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS = YES',
            'CLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR',
            'CLANG_WARN_EMPTY_BODY = YES',
            'CLANG_WARN_ENUM_CONVERSION = YES',
            'CLANG_WARN_INFINITE_RECURSION = YES',
            'CLANG_WARN_INT_CONVERSION = YES',
            'CLANG_WARN_NON_LITERAL_NULL_CONVERSION = YES',
            'CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES',
            'CLANG_WARN_OBJC_LITERAL_CONVERSION = YES',
            'CLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR',
            'CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = YES',
            'CLANG_WARN_RANGE_LOOP_ANALYSIS = YES',
            'CLANG_WARN_STRICT_PROTOTYPES = YES',
            'CLANG_WARN_SUSPICIOUS_MOVE = YES',
            'CLANG_WARN_UNREACHABLE_CODE = YES',
            'CLANG_WARN__DUPLICATE_METHOD_MATCH = YES',
            'GCC_WARN_64_TO_32_BIT_CONVERSION = YES',
            'GCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR',
            'GCC_WARN_UNDECLARED_SELECTOR = YES',
            'GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE',
            'GCC_WARN_UNUSED_FUNCTION = YES',
            'GCC_WARN_UNUSED_VARIABLE = YES',
        ]:
            a(f'\t\t\t\t{setting};')
        a('\t\t\t\tCOPY_PHASE_STRIP = NO;')
        a('\t\t\t\tDEAD_CODE_STRIPPING = YES;')
        # At project level so both targets inherit it — that's the "Inherit
        # Development Team from Project Settings" recommendation, and it means
        # the id is written once instead of once per target.
        a('\t\t\t\tDEVELOPMENT_TEAM = 52W73J6V95;')
        a('\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;')
        # Safe here: the project has no run-script build phases to sandbox.
        a('\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;')
        a('\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;')
        a('\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;')
        a('\t\t\t\tSTRING_CATALOG_GENERATE_SYMBOLS = YES;')
        if debug:
            a('\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;')
            a('\t\t\t\tENABLE_TESTABILITY = YES;')
            a('\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;')
            a('\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = ("DEBUG=1", "$(inherited)");')
            a('\t\t\t\tONLY_ACTIVE_ARCH = YES;')
            a('\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;')
            a('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";')
        else:
            a('\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')
            a('\t\t\t\tENABLE_NS_ASSERTIONS = NO;')
            a('\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;')
            a('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";')
        a('\t\t\t};')
        a(f'\t\t\tname = {name};')
        a('\t\t};')

    def target_config(cfg_id, name):
        a(f'\t\t{cfg_id} /* {name} */ = {{')
        a('\t\t\tisa = XCBuildConfiguration;')
        a('\t\t\tbuildSettings = {')
        a('\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
        a('\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;')
        a('\t\t\t\t"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]" = Quire/Quire-macOS.entitlements;')
        a('\t\t\t\t"CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]" = Quire/Quire-iOS.entitlements;')
        a('\t\t\t\t"CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]" = Quire/Quire-iOS.entitlements;')
        a('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
        a('\t\t\t\tDEAD_CODE_STRIPPING = YES;')
        a(f'\t\t\t\tCURRENT_PROJECT_VERSION = {CURRENT_PROJECT_VERSION};')
        a('\t\t\t\tENABLE_HARDENED_RUNTIME = YES;')
        a('\t\t\t\tENABLE_PREVIEWS = YES;')
        a('\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
        a('\t\t\t\t"INFOPLIST_FILE[sdk=iphoneos*]" = Quire/iOS/Info.plist;')
        a('\t\t\t\t"INFOPLIST_FILE[sdk=iphonesimulator*]" = Quire/iOS/Info.plist;')
        a('\t\t\t\t"INFOPLIST_FILE[sdk=macosx*]" = Quire/macOS/Info.plist;')
        a('\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = Quire;')
        # macOS requires an App Store category in Info.plist (and Finder/the
        # Store use it); GENERATE_INFOPLIST_FILE writes LSApplicationCategoryType
        # from this setting. Name verified against Xcode's CoreBuildSystem.xcspec.
        a('\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.lifestyle";')
        a('\t\t\t\tINFOPLIST_KEY_NSMicrophoneUsageDescription = "Quire records voice memos to attach to your journal entries.";')
        a('\t\t\t\tINFOPLIST_KEY_NSCameraUsageDescription = "Quire takes photos and records video to attach to your journal entries.";')
        a('\t\t\t\tINFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "Quire transcribes your voice memos on this device so their words become searchable text.";')
        a('\t\t\t\tINFOPLIST_KEY_NSFaceIDUsageDescription = "Quire uses Face ID to unlock your journal.";')
        # No INFOPLIST_KEY_UIApplicationSceneManifest_Generation: the iOS
        # Info.plist declares UIApplicationSceneManifest by hand so it can carry
        # the external-display scene (second-screen support). Letting Xcode
        # generate one too would collide with it.
        a('\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;')
        a('\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;')
        a('\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";')
        a('\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";')
        a('\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;')
        a('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "@executable_path/Frameworks";')
        a('\t\t\t\t"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = "@executable_path/../Frameworks";')
        a('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
        a(f'\t\t\t\tMARKETING_VERSION = {MARKETING_VERSION};')
        a('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.caddickbrown.quire;')
        a('\t\t\t\tREGISTER_APP_GROUPS = YES;')
        a('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
        a('\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";')
        a('\t\t\t\tSUPPORTS_MACCATALYST = NO;')
        a('\t\t\t\tSUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;')
        a('\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
        a('\t\t\t\tSWIFT_VERSION = 5.0;')
        a('\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";')
        a('\t\t\t};')
        a(f'\t\t\tname = {name};')
        a('\t\t};')

    def widget_config(cfg_id, name):
        a(f'\t\t{cfg_id} /* {name} */ = {{')
        a('\t\t\tisa = XCBuildConfiguration;')
        a('\t\t\tbuildSettings = {')
        a('\t\t\t\t"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]" = QuireWidget/QuireWidget-macOS.entitlements;')
        a('\t\t\t\t"CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]" = QuireWidget/QuireWidget-iOS.entitlements;')
        a('\t\t\t\t"CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]" = QuireWidget/QuireWidget-iOS.entitlements;')
        a('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
        a('\t\t\t\tDEAD_CODE_STRIPPING = YES;')
        a(f'\t\t\t\tCURRENT_PROJECT_VERSION = {CURRENT_PROJECT_VERSION};')
        a('\t\t\t\tENABLE_HARDENED_RUNTIME = YES;')
        a('\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
        a('\t\t\t\tINFOPLIST_FILE = QuireWidget/Info.plist;')
        a('\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = Quire;')
        a('\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";')
        a('\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;')
        a('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "@executable_path/Frameworks @executable_path/../../Frameworks";')
        a('\t\t\t\t"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = "@executable_path/../Frameworks @executable_path/../../../../Frameworks";')
        a('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
        a(f'\t\t\t\tMARKETING_VERSION = {MARKETING_VERSION};')
        a('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.caddickbrown.quire.QuireWidget;')
        a('\t\t\t\tREGISTER_APP_GROUPS = YES;')
        a('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
        a('\t\t\t\tSKIP_INSTALL = YES;')
        a('\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";')
        a('\t\t\t\tSUPPORTS_MACCATALYST = NO;')
        a('\t\t\t\tSUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;')
        a('\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
        a('\t\t\t\tSWIFT_VERSION = 5.0;')
        a('\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";')
        a('\t\t\t};')
        a(f'\t\t\tname = {name};')
        a('\t\t};')

    def share_config(cfg_id, name):
        a(f'\t\t{cfg_id} /* {name} */ = {{')
        a('\t\t\tisa = XCBuildConfiguration;')
        a('\t\t\tbuildSettings = {')
        a('\t\t\t\t"CODE_SIGN_ENTITLEMENTS[sdk=macosx*]" = QuireShare/QuireShare-macOS.entitlements;')
        a('\t\t\t\t"CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]" = QuireShare/QuireShare-iOS.entitlements;')
        a('\t\t\t\t"CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]" = QuireShare/QuireShare-iOS.entitlements;')
        a('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
        a('\t\t\t\tDEAD_CODE_STRIPPING = YES;')
        a(f'\t\t\t\tCURRENT_PROJECT_VERSION = {CURRENT_PROJECT_VERSION};')
        a('\t\t\t\tENABLE_HARDENED_RUNTIME = YES;')
        a('\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
        a('\t\t\t\tINFOPLIST_FILE = QuireShare/Info.plist;')
        a('\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = Quire;')
        a('\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";')
        a('\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;')
        a('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "@executable_path/Frameworks @executable_path/../../Frameworks";')
        a('\t\t\t\t"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = "@executable_path/../Frameworks @executable_path/../../../../Frameworks";')
        a('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
        a(f'\t\t\t\tMARKETING_VERSION = {MARKETING_VERSION};')
        a('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.caddickbrown.quire.QuireShare;')
        a('\t\t\t\tREGISTER_APP_GROUPS = YES;')
        a('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
        a('\t\t\t\tSKIP_INSTALL = YES;')
        a('\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";')
        a('\t\t\t\tSUPPORTS_MACCATALYST = NO;')
        a('\t\t\t\tSUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;')
        a('\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
        a('\t\t\t\tSWIFT_VERSION = 5.0;')
        a('\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";')
        a('\t\t\t};')
        a(f'\t\t\tname = {name};')
        a('\t\t};')

    def tests_config(cfg_id, name):
        a(f'\t\t{cfg_id} /* {name} */ = {{')
        a('\t\t\tisa = XCBuildConfiguration;')
        a('\t\t\tbuildSettings = {')
        a('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
        a(f'\t\t\t\tCURRENT_PROJECT_VERSION = {CURRENT_PROJECT_VERSION};')
        a('\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
        a('\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;')
        a('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
        a(f'\t\t\t\tMARKETING_VERSION = {MARKETING_VERSION};')
        a('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.caddickbrown.quire.QuireTests;')
        a('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
        a('\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx";')
        a('\t\t\t\tSUPPORTS_MACCATALYST = NO;')
        a('\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;')
        a('\t\t\t\tSWIFT_VERSION = 5.0;')
        a('\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";')
        a('\t\t\t};')
        a(f'\t\t\tname = {name};')
        a('\t\t};')

    project_config(IDs['projDebugConfig'], 'Debug', True)
    project_config(IDs['projReleaseConfig'], 'Release', False)
    target_config(IDs['debugConfig'], 'Debug')
    target_config(IDs['releaseConfig'], 'Release')
    widget_config(IDs['widgetDebugConfig'], 'Debug')
    widget_config(IDs['widgetReleaseConfig'], 'Release')
    share_config(IDs['shareDebugConfig'], 'Debug')
    share_config(IDs['shareReleaseConfig'], 'Release')
    tests_config(IDs['testsDebugConfig'], 'Debug')
    tests_config(IDs['testsReleaseConfig'], 'Release')
    a('/* End XCBuildConfiguration section */')
    a('')

    # ---- XCConfigurationList ----
    a('/* Begin XCConfigurationList section */')
    a(f'\t\t{IDs["configList"]} /* Build configuration list for PBXProject "Quire" */ = {{')
    a('\t\t\tisa = XCConfigurationList;')
    a('\t\t\tbuildConfigurations = (')
    a(f'\t\t\t\t{IDs["projDebugConfig"]} /* Debug */,')
    a(f'\t\t\t\t{IDs["projReleaseConfig"]} /* Release */,')
    a('\t\t\t);')
    a('\t\t\tdefaultConfigurationIsVisible = 0;')
    a('\t\t\tdefaultConfigurationName = Release;')
    a('\t\t};')
    a(f'\t\t{IDs["targetConfigList"]} /* Build configuration list for PBXNativeTarget "Quire" */ = {{')
    a('\t\t\tisa = XCConfigurationList;')
    a('\t\t\tbuildConfigurations = (')
    a(f'\t\t\t\t{IDs["debugConfig"]} /* Debug */,')
    a(f'\t\t\t\t{IDs["releaseConfig"]} /* Release */,')
    a('\t\t\t);')
    a('\t\t\tdefaultConfigurationIsVisible = 0;')
    a('\t\t\tdefaultConfigurationName = Release;')
    a('\t\t};')
    a(f'\t\t{IDs["widgetTargetConfigList"]} /* Build configuration list for PBXNativeTarget "QuireWidgetExtension" */ = {{')
    a('\t\t\tisa = XCConfigurationList;')
    a('\t\t\tbuildConfigurations = (')
    a(f'\t\t\t\t{IDs["widgetDebugConfig"]} /* Debug */,')
    a(f'\t\t\t\t{IDs["widgetReleaseConfig"]} /* Release */,')
    a('\t\t\t);')
    a('\t\t\tdefaultConfigurationIsVisible = 0;')
    a('\t\t\tdefaultConfigurationName = Release;')
    a('\t\t};')
    a(f'\t\t{IDs["shareTargetConfigList"]} /* Build configuration list for PBXNativeTarget "QuireShareExtension" */ = {{')
    a('\t\t\tisa = XCConfigurationList;')
    a('\t\t\tbuildConfigurations = (')
    a(f'\t\t\t\t{IDs["shareDebugConfig"]} /* Debug */,')
    a(f'\t\t\t\t{IDs["shareReleaseConfig"]} /* Release */,')
    a('\t\t\t);')
    a('\t\t\tdefaultConfigurationIsVisible = 0;')
    a('\t\t\tdefaultConfigurationName = Release;')
    a('\t\t};')
    a(f'\t\t{IDs["testsTargetConfigList"]} /* Build configuration list for PBXNativeTarget "QuireTests" */ = {{')
    a('\t\t\tisa = XCConfigurationList;')
    a('\t\t\tbuildConfigurations = (')
    a(f'\t\t\t\t{IDs["testsDebugConfig"]} /* Debug */,')
    a(f'\t\t\t\t{IDs["testsReleaseConfig"]} /* Release */,')
    a('\t\t\t);')
    a('\t\t\tdefaultConfigurationIsVisible = 0;')
    a('\t\t\tdefaultConfigurationName = Release;')
    a('\t\t};')
    a('/* End XCConfigurationList section */')
    a('')

    a('\t};')
    a(f'\trootObject = {IDs["project"]} /* Project object */;')
    a('}')
    return '\n'.join(L) + '\n'

# Xcode's scheme selector shows one entry per scheme, and a scheme for the
# widget extension earns its keep only while you're working on the widget: the
# Quire target already depends on it and embeds the .appex, so building/running
# "Quire" builds the widget either way. Off by default so the selector reads just
# "Quire"; flip to True (and re-run `make project`) to get the widget scheme back
# for previewing a widget on its own.
GENERATE_WIDGET_SCHEME = False

# Which widget `Run` previews when the QuireWidgetExtension scheme is selected.
# A bundle with more than one widget can't be inferred, so Xcode refuses to
# launch without _XCWidgetKind ("Please specify the widget kind in the scheme's
# Environment Variables"). Switch to 'QuireNewEntryWidget' to preview the Lock
# Screen button, or 'QuireNewDraftControl' for the Control Center control —
# or edit the variable in Xcode's scheme editor.
WIDGET_PREVIEW_KIND = 'QuireWidget'


def app_scheme():
    """Shared scheme for the app. Generated rather than left to Xcode's
    autocreation so the one scheme in the selector is deterministic and tracked
    in git — and so the widget target, whose autocreation is suppressed in the
    scheme-management plist below, has no scheme to be autocreated next to."""
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "{XCODE_STAMP}" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{IDs['target']}"
               BuildableName = "Quire.app"
               BlueprintName = "Quire"
               ReferencedContainer = "container:Quire.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{IDs['testsTarget']}"
               BuildableName = "QuireTests.xctest"
               BlueprintName = "QuireTests"
               ReferencedContainer = "container:Quire.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{IDs['testsTarget']}"
               BuildableName = "QuireTests.xctest"
               BlueprintName = "QuireTests"
               ReferencedContainer = "container:Quire.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{IDs['target']}"
            BuildableName = "Quire.app"
            BlueprintName = "Quire"
            ReferencedContainer = "container:Quire.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{IDs['target']}"
            BuildableName = "Quire.app"
            BlueprintName = "Quire"
            ReferencedContainer = "container:Quire.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''


def scheme_management():
    """Per-user scheme state (`xcuserdata/`, gitignored). Its job here is
    SuppressBuildableAutocreation: without it Xcode notices the widget target
    has no scheme and helpfully makes one, putting "QuireWidgetExtension" back in
    the selector. Keyed by target id, which this generator re-rolls on every
    run — hence writing it here, alongside the pbxproj it has to match."""
    shown = ['\t\t<key>Quire.xcscheme_^#shared#^_</key>',
             '\t\t<dict>',
             '\t\t\t<key>isShown</key>',
             '\t\t\t<true/>',
             '\t\t\t<key>orderHint</key>',
             '\t\t\t<integer>0</integer>',
             '\t\t</dict>']
    # The share extension and test bundle never earn a scheme of their own
    # (tests run through the Quire scheme's Test action); the widget's is
    # opt-in via GENERATE_WIDGET_SCHEME.
    suppress_targets = [IDs["shareTarget"], IDs["testsTarget"]]
    if GENERATE_WIDGET_SCHEME:
        shown += ['\t\t<key>QuireWidgetExtension.xcscheme_^#shared#^_</key>',
                  '\t\t<dict>',
                  '\t\t\t<key>isShown</key>',
                  '\t\t\t<true/>',
                  '\t\t\t<key>orderHint</key>',
                  '\t\t\t<integer>1</integer>',
                  '\t\t</dict>']
    else:
        suppress_targets.insert(0, IDs["widgetTarget"])
    suppressed = ['\t<key>SuppressBuildableAutocreation</key>', '\t<dict>']
    for tid in suppress_targets:
        suppressed += [f'\t\t<key>{tid}</key>',
                       '\t\t<dict>',
                       '\t\t\t<key>primary</key>',
                       '\t\t\t<true/>',
                       '\t\t</dict>']
    suppressed.append('\t</dict>')
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
             '<plist version="1.0">',
             '<dict>',
             '\t<key>SchemeUserState</key>',
             '\t<dict>'] + shown + ['\t</dict>'] + suppressed + ['</dict>', '</plist>', '']
    return '\n'.join(lines)


def widget_scheme():
    """Shared scheme for the widget extension, carrying _XCWidgetKind."""
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "{XCODE_STAMP}" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{IDs['widgetTarget']}"
               BuildableName = "QuireWidgetExtension.appex"
               BlueprintName = "QuireWidgetExtension"
               ReferencedContainer = "container:Quire.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      askForAppToLaunch = "Yes"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES"
      launchAutomaticallySubstyle = "2">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{IDs['widgetTarget']}"
            BuildableName = "QuireWidgetExtension.appex"
            BlueprintName = "QuireWidgetExtension"
            ReferencedContainer = "container:Quire.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
      <EnvironmentVariables>
         <EnvironmentVariable
            key = "_XCWidgetKind"
            value = "{WIDGET_PREVIEW_KIND}"
            isEnabled = "YES">
         </EnvironmentVariable>
      </EnvironmentVariables>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{IDs['widgetTarget']}"
            BuildableName = "QuireWidgetExtension.appex"
            BlueprintName = "QuireWidgetExtension"
            ReferencedContainer = "container:Quire.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''


if __name__ == '__main__':
    out = pbxproj()
    path = os.path.join(HERE, 'Quire.xcodeproj', 'project.pbxproj')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(out)
    print(f'Wrote {len(out)} bytes to {path}')

    schemes = os.path.join(HERE, 'Quire.xcodeproj', 'xcshareddata', 'xcschemes')
    os.makedirs(schemes, exist_ok=True)

    app_path = os.path.join(schemes, 'Quire.xcscheme')
    with open(app_path, 'w') as f:
        f.write(app_scheme())
    print(f'Wrote {app_path}')

    widget_path = os.path.join(schemes, 'QuireWidgetExtension.xcscheme')
    if GENERATE_WIDGET_SCHEME:
        with open(widget_path, 'w') as f:
            f.write(widget_scheme())
        print(f'Wrote {widget_path} (_XCWidgetKind = {WIDGET_PREVIEW_KIND})')
    elif os.path.exists(widget_path):
        os.remove(widget_path)
        print(f'Removed {widget_path} (GENERATE_WIDGET_SCHEME = False)')

    # Per-user scheme state. xcuserdata/ is gitignored, so this is rewritten
    # locally on every run rather than shared — which is what keeps its target
    # ids in step with the freshly generated pbxproj.
    userdata = os.path.join(HERE, 'Quire.xcodeproj', 'xcuserdata')
    # Only *.xcuserdatad directories count: a .DS_Store (or any other stray
    # file Finder drops in there) used to be picked as the user folder and the
    # generator then crashed writing into it.
    existing = sorted(
        d for d in os.listdir(userdata)
        if d.endswith('.xcuserdatad') and os.path.isdir(os.path.join(userdata, d))
    ) if os.path.isdir(userdata) else []
    who = existing[0] if existing else f'{getpass.getuser()}.xcuserdatad'
    mgmt_dir = os.path.join(userdata, who, 'xcschemes')
    os.makedirs(mgmt_dir, exist_ok=True)
    mgmt_path = os.path.join(mgmt_dir, 'xcschememanagement.plist')
    with open(mgmt_path, 'w') as f:
        f.write(scheme_management())
    print(f'Wrote {mgmt_path}')
