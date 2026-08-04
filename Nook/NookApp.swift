//
//  NookApp.swift
//  Nook
//
//  App entry point. Registers bundled fonts, owns the single JournalStore, and
//  drives the light/dark/auto theme (persisted). Runs on iOS + macOS.
//
//  iOS additions:
//  - UIApplicationDelegateAdaptor to handle home screen quick actions
//  - onOpenURL handler for nook://write deep links from the widget
//  - Notification listener for OpenNewDraftIntent
//

import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#endif

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
        case .auto:  return nil
        case .light: return .light
        case .dark:  return .dark
        }
    }
}

// MARK: - App delegate (iOS only — quick actions + launch handling)

#if canImport(UIKit)
final class NookAppDelegate: NSObject, UIApplicationDelegate {
    /// Stashed on launch so we can handle quick actions before nav is ready.
    var pendingShortcut: UIApplicationShortcutItem?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register home screen quick actions.
        NookQuickAction.register()
        // If launched via a quick action, stash it — RootView picks it up.
        if let item = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            pendingShortcut = item
            return false   // per Apple docs: return false when handling at launch
        }
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        // App was already running; post a notification so RootView handles it.
        NotificationCenter.default.post(
            name: .nookHandleShortcut,
            object: shortcutItem
        )
        completionHandler(true)
    }
}

extension Notification.Name {
    static let nookHandleShortcut = Notification.Name("com.caddickbrown.nook.handleShortcut")
}
#endif

// MARK: - App

@main
struct NookApp: App {
    @StateObject private var store = JournalStore()
    @StateObject private var nav   = NavigationModel()
    @AppStorage("colorScheme") private var colorSchemeRaw: String = AppColorScheme.auto.rawValue
    @AppStorage("accentColor") private var accentRaw: String = AccentTheme.blue.rawValue
    @Environment(\.scenePhase) private var scenePhase

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(NookAppDelegate.self) private var delegate
    #endif

    init() { Self.registerBundledFonts() }

    var body: some Scene {
        let accent = AccentTheme.color(forRaw: accentRaw)
        return WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(nav)
                // Take the scheduled backup if one came due while we were closed.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.autoBackupIfDue() }
                }
                .tint(accent)
                .environment(\.accent, accent)
                .preferredColorScheme(
                    AppColorScheme(rawValue: colorSchemeRaw)?.resolved
                )
                // Widget / Siri deep link: nook://write
                .onOpenURL { url in
                    if url.scheme == "nook", url.host == "write" {
                        nav.requestNewEntry()
                    }
                }
                // OpenNewDraftIntent notification (when app already running)
                .onReceive(NotificationCenter.default.publisher(for: .nookOpenWrite)) { _ in
                    nav.requestNewEntry()
                }
                #if canImport(UIKit)
                // Quick action notification (app foregrounded via shortcut)
                .onReceive(NotificationCenter.default.publisher(for: .nookHandleShortcut)) { note in
                    if let item = note.object as? UIApplicationShortcutItem {
                        _ = NookQuickAction.handle(item, nav: nav)
                    }
                }
                // Pending quick action from cold launch
                .task {
                    if let item = delegate.pendingShortcut {
                        delegate.pendingShortcut = nil
                        _ = NookQuickAction.handle(item, nav: nav)
                    }
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 680)
        #endif
        .commands { AppCommands(nav: nav) }
    }

    private static func registerBundledFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts")
                ?? Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil)
        else { return }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// Menu commands + keyboard shortcuts (macOS menu bar; hardware keyboards on iPad).
struct AppCommands: Commands {
    @ObservedObject var nav: NavigationModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Entry") { nav.requestNewEntry() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(nav.focusMode ? "Exit Focus Mode" : "Focus Mode") { nav.focusMode.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandMenu("Go") {
            Button("Write")    { nav.section = .write }.keyboardShortcut("1", modifiers: .command)
            Button("Inbox")    { nav.section = .inbox }.keyboardShortcut("2", modifiers: .command)
            Button("Journal")  { nav.section = .archive }.keyboardShortcut("3", modifiers: .command)
            Button("Tags")     { nav.section = .tags }.keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Stats")    { nav.section = .stats }
            Button("Settings") { nav.section = .settings }.keyboardShortcut(",", modifiers: .command)
        }
    }
}
