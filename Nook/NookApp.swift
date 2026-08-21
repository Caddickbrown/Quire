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
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
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
/// A `UIResponder` (not merely `NSObject`) so it joins the responder chain: the
/// hardware-keyboard commands below are declared here precisely because the app
/// delegate sits at the *end* of that chain, which means they fire for keys
/// nothing else wanted — and a focused text field, being earlier in the chain,
/// keeps its arrows and `?` to itself.
final class NookAppDelegate: UIResponder, UIApplicationDelegate {
    /// Stashed on launch so we can handle quick actions before nav is ready.
    var pendingShortcut: UIApplicationShortcutItem?

    // MARK: Hardware keyboard

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let arrows = [
            UIKeyCommand(input: UIKeyCommand.inputUpArrow,   modifierFlags: [], action: #selector(nookMoveUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nookMoveDown)),
        ]
        // Arrows would otherwise be eaten by a scroll view's own key handling.
        // Deliberately not applied to Return or "?", which have no competing
        // system behaviour and are better left to ordinary chain order.
        for command in arrows { command.wantsPriorityOverSystemBehavior = true }
        return arrows + [
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(nookOpenSelection)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(nookClearSelection)),
            UIKeyCommand(input: "?", modifierFlags: [], action: #selector(nookToggleHints)),
        ]
    }

    @objc private func nookMoveUp()   { KeyCommandRouter.shared.moveUp() }
    @objc private func nookMoveDown() { KeyCommandRouter.shared.moveDown() }
    @objc private func nookOpenSelection()  { KeyCommandRouter.shared.open() }
    @objc private func nookClearSelection() { KeyCommandRouter.shared.clear() }
    @objc private func nookToggleHints()    { ShortcutHints.toggle() }

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
    @ObservedObject private var router = NotificationRouter.shared
    @AppStorage("colorScheme") private var colorSchemeRaw: String = AppColorScheme.auto.rawValue
    @AppStorage("accentColor") private var accentRaw: String = AccentTheme.blue.rawValue
    @Environment(\.scenePhase) private var scenePhase

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(NookAppDelegate.self) private var delegate
    #endif

    init() {
        Self.registerBundledFonts()
        // Before any notification can arrive: the delegate handles the
        // reminder's inline "Write a line…" action and resurfacing taps.
        NotificationResponder.shared.install()
    }

    var body: some Scene {
        let accent = AccentTheme.color(forRaw: accentRaw)
        return WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(nav)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Relock check first, so entry text isn't up while the
                        // Face ID sheet decides.
                        AppLockManager.shared.didBecomeActive()
                        // Pick up edits made while we were away — another device,
                        // the jnl CLI, a Siri quick-add — and take the scheduled
                        // backup if one came due while we were closed.
                        store.reloadIfChanged()
                        store.autoBackupIfDue()
                        // Plan the next weekly resurfacing note if none is pending.
                        Task { await ResurfacingScheduler.ensureScheduled(store: store) }
                    case .background:
                        AppLockManager.shared.didEnterBackground()
                    default:
                        break
                    }
                }
                #if os(macOS)
                // scenePhase stays .active across app switches on macOS, so
                // returning from the jnl CLI or Finder never refreshed — this
                // notification is what actually fires there.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    store.reloadIfChanged()
                    store.autoBackupIfDue()
                }
                #endif
                .tint(accent)
                .environment(\.accent, accent)
                .preferredColorScheme(
                    AppColorScheme(rawValue: colorSchemeRaw)?.resolved
                )
                // Deep links: nook://write (composer), nook://timer (start a
                // session), nook://entry?date=…&ts=… (open one entry — the
                // widget's On This Day line and notifications land here).
                .onOpenURL { url in
                    guard url.scheme == "nook" else { return }
                    switch url.host {
                    case "write":
                        nav.requestNewEntry()
                    case "timer":
                        if !nav.timerRunning {
                            if nav.timerRemaining <= 0 {
                                let minutes = UserDefaults.standard.integer(forKey: "timerMinutes")
                                nav.timerRemaining = max(minutes, 1) * 60
                            }
                            nav.timerRunning = true
                        }
                    case "entry":
                        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                        openEntry(date: items?.first(where: { $0.name == "date" })?.value,
                                  ts: items?.first(where: { $0.name == "ts" })?.value)
                    default:
                        break
                    }
                }
                // Notification taps: the daily reminder opens the composer, the
                // weekly resurfacing note opens the entry it teased. These come
                // through NotificationRouter rather than a NotificationCenter
                // post so a tap that launched the app cold isn't missed.
                .onReceive(router.$pending.compactMap { $0 }) { action in
                    // Async so clearing doesn't publish inside a view update.
                    DispatchQueue.main.async { router.pending = nil }
                    switch action {
                    case .write:
                        nav.requestNewEntry()
                    case .entry(let date, let ts):
                        openEntry(date: date, ts: ts)
                    }
                }
                // A draft was added outside the UI (notification quick-write).
                .onReceive(NotificationCenter.default.publisher(for: .nookJournalChangedExternally)) { _ in
                    store.reloadIfChanged()
                }
                // OpenNewDraftIntent notification (when app already running)
                .onReceive(NotificationCenter.default.publisher(for: .nookOpenWrite)) { _ in
                    nav.requestNewEntry()
                }
                #if canImport(CoreSpotlight)
                // A tapped Spotlight result (Settings → Privacy → Spotlight).
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          let (entry, source) = SpotlightIndexer.resolve(identifier: id, store: store)
                    else { return }
                    nav.open(entry, source: source)
                }
                #endif
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

    /// Resolve an entry reference (from a deep link or notification) and open
    /// it: dated → its day file, otherwise the inbox.
    private func openEntry(date: String?, ts: String?) {
        guard let ts, !ts.isEmpty else { return }
        if let date, !date.isEmpty,
           let entry = store.entries(for: date).first(where: { $0.ts == ts }) {
            nav.open(entry, source: .archive(date: date))
            return
        }
        if let draft = store.inboxDrafts.first(where: { $0.ts == ts }) {
            nav.open(draft, source: .inbox)
        }
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
        // ⌘B/⌘I wrap the selection in **/_ in whichever editor is focused —
        // the editors listen for these (WritingTextEditor.Coordinator).
        CommandGroup(replacing: .textFormatting) {
            Button("Bold") { NotificationCenter.default.post(name: .nookFormatBold, object: nil) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { NotificationCenter.default.post(name: .nookFormatItalic, object: nil) }
                .keyboardShortcut("i", modifiers: .command)
        }
        CommandMenu("Go") {
            Button("Write")    { nav.section = .write }.keyboardShortcut("1", modifiers: .command)
            Button("Inbox")    { nav.section = .inbox }.keyboardShortcut("2", modifiers: .command)
            Button("Journal")  { nav.section = .archive }.keyboardShortcut("3", modifiers: .command)
            Button("Tags")     { nav.section = .tags }.keyboardShortcut("4", modifiers: .command)
            Button("Search")   { nav.section = .search }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Stats")    { nav.section = .stats }
            Button("Settings") { nav.section = .settings }.keyboardShortcut(",", modifiers: .command)
        }
    }
}
