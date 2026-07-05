#!/usr/bin/env python3
"""Generate Jibber.xcodeproj/project.pbxproj for the multiplatform (iOS + macOS)
SwiftUI journaling app. Adapted from Pigeon's generator; hand-editing the pbxproj
is avoided — edit this file and re-run instead.

Usage:  python3 gen_pbxproj.py
"""

import uuid
import os

HERE = os.path.dirname(os.path.abspath(__file__))

def new_id():
    return uuid.uuid4().hex[:24].upper()

# (key, path relative to Jibber/, containing group)
swift_files = [
    ('JibberApp',       'JibberApp.swift',              'Jibber'),
    ('Theme',           'Theme.swift',                  'Jibber'),
    ('Entry',           'Models/Entry.swift',           'Models'),
    ('JournalParser',   'Models/JournalParser.swift',   'Models'),
    ('JournalStore',    'Models/JournalStore.swift',    'Models'),
    ('RootView',        'Views/RootView.swift',         'Views'),
    ('WritingView',     'Views/WritingView.swift',      'Views'),
    ('InboxView',       'Views/InboxView.swift',        'Views'),
    ('ArchiveView',     'Views/ArchiveView.swift',      'Views'),
    ('EntryDetailView', 'Views/EntryDetailView.swift',  'Views'),
    ('TagsView',        'Views/TagsView.swift',         'Views'),
    ('SettingsView',    'Views/SettingsView.swift',     'Views'),
]

# (key, path relative to Jibber/, fileType) — copied into Resources.
resources = [
    ('Assets', 'Assets.xcassets', 'folder.assetcatalog'),
    ('Fonts',  'fonts',           'folder'),
]

# Allocate ids
IDs = {k: new_id() for k in [
    'project', 'mainGroup', 'jibberGroup', 'modelsGroup', 'viewsGroup',
    'iosGroup', 'macosGroup', 'productsGroup', 'target',
    'debugConfig', 'releaseConfig', 'projDebugConfig', 'projReleaseConfig',
    'configList', 'targetConfigList', 'sourcesBuildPhase', 'resourcesBuildPhase',
    'frameworksBuildPhase', 'product', 'iOSInfoPlist', 'macOSInfoPlist',
]}
for name, _, _ in swift_files:
    IDs[name] = new_id()
    IDs['bf_' + name] = new_id()
for name, _, _ in resources:
    IDs[name] = new_id()
    IDs['bf_' + name] = new_id()

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
    a('/* End PBXBuildFile section */')
    a('')

    # ---- PBXFileReference ----
    a('/* Begin PBXFileReference section */')
    for name, path, _ in swift_files:
        a(f'\t\t{IDs[name]} /* {base(path)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {base(path)}; sourceTree = "<group>"; }};')
    for name, path, ftype in resources:
        a(f'\t\t{IDs[name]} /* {base(path)} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {base(path)}; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["iOSInfoPlist"]} /* iOS/Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["macOSInfoPlist"]} /* macOS/Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    a(f'\t\t{IDs["product"]} /* Jibber.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Jibber.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    a('/* End PBXFileReference section */')
    a('')

    # ---- PBXFrameworksBuildPhase ----
    a('/* Begin PBXFrameworksBuildPhase section */')
    a(f'\t\t{IDs["frameworksBuildPhase"]} /* Frameworks */ = {{')
    a('\t\t\tisa = PBXFrameworksBuildPhase;')
    a('\t\t\tbuildActionMask = 2147483647;')
    a('\t\t\tfiles = (\n\t\t\t);')
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
    a(f'\t\t\t\t{IDs["jibberGroup"]} /* Jibber */,')
    a(f'\t\t\t\t{IDs["productsGroup"]} /* Products */,')
    a('\t\t\t);')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    # products
    a(f'\t\t{IDs["productsGroup"]} /* Products */ = {{')
    a('\t\t\tisa = PBXGroup;')
    a('\t\t\tchildren = (')
    a(f'\t\t\t\t{IDs["product"]} /* Jibber.app */,')
    a('\t\t\t);')
    a('\t\t\tname = Products;')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    # Jibber source group
    top = [n for n, p, g in swift_files if g == 'Jibber']
    a(f'\t\t{IDs["jibberGroup"]} /* Jibber */ = {{')
    a('\t\t\tisa = PBXGroup;')
    a('\t\t\tchildren = (')
    for n in top:
        a(f'\t\t\t\t{IDs[n]} /* {next(base(p) for k,p,g in swift_files if k==n)} */,')
    a(f'\t\t\t\t{IDs["modelsGroup"]} /* Models */,')
    a(f'\t\t\t\t{IDs["viewsGroup"]} /* Views */,')
    for n, p, _ in resources:
        a(f'\t\t\t\t{IDs[n]} /* {base(p)} */,')
    a(f'\t\t\t\t{IDs["iosGroup"]} /* iOS */,')
    a(f'\t\t\t\t{IDs["macosGroup"]} /* macOS */,')
    a('\t\t\t);')
    a('\t\t\tpath = Jibber;')
    a('\t\t\tsourceTree = "<group>";')
    a('\t\t};')

    # subgroups Models / Views
    for grp, gid, folder in [('Models', IDs['modelsGroup'], 'Models'),
                             ('Views', IDs['viewsGroup'], 'Views')]:
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

    a('/* End PBXGroup section */')
    a('')

    # ---- PBXNativeTarget ----
    a('/* Begin PBXNativeTarget section */')
    a(f'\t\t{IDs["target"]} /* Jibber */ = {{')
    a('\t\t\tisa = PBXNativeTarget;')
    a(f'\t\t\tbuildConfigurationList = {IDs["targetConfigList"]} /* Build configuration list for PBXNativeTarget "Jibber" */;')
    a('\t\t\tbuildPhases = (')
    a(f'\t\t\t\t{IDs["sourcesBuildPhase"]} /* Sources */,')
    a(f'\t\t\t\t{IDs["frameworksBuildPhase"]} /* Frameworks */,')
    a(f'\t\t\t\t{IDs["resourcesBuildPhase"]} /* Resources */,')
    a('\t\t\t);')
    a('\t\t\tbuildRules = (\n\t\t\t);')
    a('\t\t\tdependencies = (\n\t\t\t);')
    a('\t\t\tname = Jibber;')
    a('\t\t\tproductName = Jibber;')
    a(f'\t\t\tproductReference = {IDs["product"]} /* Jibber.app */;')
    a('\t\t\tproductType = "com.apple.product-type.application";')
    a('\t\t};')
    a('/* End PBXNativeTarget section */')
    a('')

    # ---- PBXProject ----
    a('/* Begin PBXProject section */')
    a(f'\t\t{IDs["project"]} /* Project object */ = {{')
    a('\t\t\tisa = PBXProject;')
    a('\t\t\tattributes = {')
    a('\t\t\t\tBuildIndependentTargetsInParallel = 1;')
    a('\t\t\t\tLastSwiftUpdateCheck = 1600;')
    a('\t\t\t\tLastUpgradeCheck = 1600;')
    a('\t\t\t\tTargetAttributes = {')
    a(f'\t\t\t\t\t{IDs["target"]} = {{')
    a('\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;')
    a('\t\t\t\t\t};')
    a('\t\t\t\t};')
    a('\t\t\t};')
    a(f'\t\t\tbuildConfigurationList = {IDs["configList"]} /* Build configuration list for PBXProject "Jibber" */;')
    a('\t\t\tcompatibilityVersion = "Xcode 14.0";')
    a('\t\t\tdevelopmentRegion = en;')
    a('\t\t\thasScannedForEncodings = 0;')
    a('\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);')
    a(f'\t\t\tmainGroup = {IDs["mainGroup"]};')
    a(f'\t\t\tproductRefGroup = {IDs["productsGroup"]} /* Products */;')
    a('\t\t\tprojectDirPath = "";')
    a('\t\t\tprojectRoot = "";')
    a('\t\t\ttargets = (')
    a(f'\t\t\t\t{IDs["target"]} /* Jibber */,')
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
    a('/* End PBXSourcesBuildPhase section */')
    a('')

    # ---- XCBuildConfiguration ----
    a('/* Begin XCBuildConfiguration section */')

    def project_config(cfg_id, name, debug):
        a(f'\t\t{cfg_id} /* {name} */ = {{')
        a('\t\t\tisa = XCBuildConfiguration;')
        a('\t\t\tbuildSettings = {')
        a('\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;')
        a('\t\t\t\tCLANG_ENABLE_MODULES = YES;')
        a('\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;')
        a('\t\t\t\tCLANG_ENABLE_OBJC_WEAK = YES;')
        a('\t\t\t\tCOPY_PHASE_STRIP = NO;')
        a('\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;')
        a('\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;')
        a('\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;')
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
        a('\t\t\t\tCODE_SIGN_ENTITLEMENTS = Jibber/Jibber.entitlements;')
        a('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
        a('\t\t\t\tCURRENT_PROJECT_VERSION = 1;')
        a('\t\t\t\tDEVELOPMENT_TEAM = 52W73J6V95;')
        a('\t\t\t\tENABLE_HARDENED_RUNTIME = YES;')
        a('\t\t\t\tENABLE_PREVIEWS = YES;')
        a('\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
        a('\t\t\t\t"INFOPLIST_FILE[sdk=iphoneos*]" = Jibber/iOS/Info.plist;')
        a('\t\t\t\t"INFOPLIST_FILE[sdk=iphonesimulator*]" = Jibber/iOS/Info.plist;')
        a('\t\t\t\t"INFOPLIST_FILE[sdk=macosx*]" = Jibber/macOS/Info.plist;')
        a('\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = Jibber;')
        a('\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;')
        a('\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;')
        a('\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;')
        a('\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";')
        a('\t\t\t\tINFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";')
        a('\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;')
        a('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = "@executable_path/Frameworks";')
        a('\t\t\t\t"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = "@executable_path/../Frameworks";')
        a('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
        a('\t\t\t\tMARKETING_VERSION = 1.0;')
        a('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.caddickbrown.jibber;')
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

    project_config(IDs['projDebugConfig'], 'Debug', True)
    project_config(IDs['projReleaseConfig'], 'Release', False)
    target_config(IDs['debugConfig'], 'Debug')
    target_config(IDs['releaseConfig'], 'Release')
    a('/* End XCBuildConfiguration section */')
    a('')

    # ---- XCConfigurationList ----
    a('/* Begin XCConfigurationList section */')
    a(f'\t\t{IDs["configList"]} /* Build configuration list for PBXProject "Jibber" */ = {{')
    a('\t\t\tisa = XCConfigurationList;')
    a('\t\t\tbuildConfigurations = (')
    a(f'\t\t\t\t{IDs["projDebugConfig"]} /* Debug */,')
    a(f'\t\t\t\t{IDs["projReleaseConfig"]} /* Release */,')
    a('\t\t\t);')
    a('\t\t\tdefaultConfigurationIsVisible = 0;')
    a('\t\t\tdefaultConfigurationName = Release;')
    a('\t\t};')
    a(f'\t\t{IDs["targetConfigList"]} /* Build configuration list for PBXNativeTarget "Jibber" */ = {{')
    a('\t\t\tisa = XCConfigurationList;')
    a('\t\t\tbuildConfigurations = (')
    a(f'\t\t\t\t{IDs["debugConfig"]} /* Debug */,')
    a(f'\t\t\t\t{IDs["releaseConfig"]} /* Release */,')
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

if __name__ == '__main__':
    out = pbxproj()
    path = os.path.join(HERE, 'Jibber.xcodeproj', 'project.pbxproj')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(out)
    print(f'Wrote {len(out)} bytes to {path}')
