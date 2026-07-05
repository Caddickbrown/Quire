//
//  JibberApp.swift
//  Jibber
//
//  App entry point. Registers bundled fonts, owns the single JournalStore, and
//  drives the light/dark/auto theme (persisted). Runs on iOS + macOS.
//

import SwiftUI
import CoreText

enum AppColorScheme: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .auto:  return "Auto"
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }
    var systemImage: String {
        switch self {
        case .auto:  return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark:  return "moon.fill"
        }
    }
    var resolved: ColorScheme? {
        switch self {
        case .auto:  return nil          // follow the system
        case .light: return .light
        case .dark:  return .dark
        }
    }
}

@main
struct JibberApp: App {
    @StateObject private var store = JournalStore()
    @AppStorage("colorScheme") private var colorSchemeRaw: String = AppColorScheme.auto.rawValue

    init() { Self.registerBundledFonts() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(
                    AppColorScheme(rawValue: colorSchemeRaw)?.resolved
                )
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 680)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(store)
                .preferredColorScheme(AppColorScheme(rawValue: colorSchemeRaw)?.resolved)
        }
        #endif
    }

    /// Register every bundled Lato face at launch so `.custom("Lato-Regular", …)`
    /// resolves on both platforms without per-font Info.plist entries.
    private static func registerBundledFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts")
                ?? Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil)
        else { return }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
