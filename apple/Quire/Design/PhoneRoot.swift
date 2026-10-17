//
//  PhoneRoot.swift
//  Quire
//
//  The iPhone shell: four faces (Today, Inbox, Journal, Look back) behind a
//  text tab bar, with "+" for a new entry. Entries open as pages that push over
//  the faces; the composer and the retime sheet come up over everything.
//

#if os(iOS)

import SwiftUI

struct ComposeTarget: Identifiable {
    let id = UUID()
    /// nil: a new draft. Otherwise the entry being edited, wherever it lives.
    var ref: EntryRef?
}

struct PhoneRoot: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.quire) private var q

    @State private var tab: PhoneTab = Self.startTab
    @State private var path: [EntryRef] = []
    @State private var composing: ComposeTarget?
    @State private var retiming: EntryRef?
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var rootKeyID = UUID()

    /// `QUIRE_START_TAB=inbox|journal|lookback` opens that face first (for screenshots).
    private static var startTab: PhoneTab {
        switch ProcessInfo.processInfo.environment["QUIRE_START_TAB"] {
        case "inbox": return .inbox
        case "journal": return .journal
        case "lookback": return .lookBack
        default: return .today
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                notice
                face
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                QTabBar(tab: $tab, inboxCount: store.inboxDrafts.count) {
                    composing = ComposeTarget(ref: nil)
                }
            }
            .background(q.pageColor)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: EntryRef.self) { ref in
                ReaderScreen(ref: ref, onEdit: { composing = ComposeTarget(ref: $0) },
                             onRetime: { retiming = $0 })
            }
        }
        .qKeyBlocker(active: composing != nil || retiming != nil || showSearch || showSettings)
        .fullScreenCover(item: $composing) { target in
            ComposerScreen(target: target)
        }
        .sheet(item: $retiming) { ref in
            RetimeSheet(ref: ref)
        }
        .sheet(isPresented: $showSearch) {
            SearchScreen(onOpen: { ref in
                showSearch = false
                // Let the sheet finish leaving before the page is pushed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { open(ref) }
            })
            .environmentObject(store).environmentObject(nav)
            .environment(\.quire, q)
        }
        .sheet(isPresented: $showSettings) {
            PhoneSettings()
                .environmentObject(store).environmentObject(nav)
                .environment(\.quire, q)
        }
        // The widget, the reminder and the home-screen action all ask for the
        // composer through the shared navigation model.
        .onChange(of: nav.newEntrySignal) { _, _ in composing = ComposeTarget(ref: nil) }
        // `QUIRE_OPEN=settings|search` in the launch environment opens that first (screenshots).
        // The external display scene is built by UIKit and can't reach this environment.
        .onAppear {
            ExternalDisplayModel.shared.store = store
            ExternalDisplayModel.shared.colorScheme = q.colorScheme
        }
        .onChange(of: q.id) { _, _ in ExternalDisplayModel.shared.colorScheme = q.colorScheme }
        .onAppear(perform: registerRootKeys)
        .onAppear {
            switch ProcessInfo.processInfo.environment["QUIRE_OPEN"] {
            case "settings": showSettings = true
            case "search": showSearch = true
            default: break
            }
        }
    }

    @ViewBuilder private var face: some View {
        switch tab {
        case .today:
            TodayScreen(open: open, compose: { composing = ComposeTarget(ref: nil) },
                        showInbox: { tab = .inbox }, search: { showSearch = true }, settings: { showSettings = true })
        case .inbox:
            InboxScreen(open: open, edit: { composing = ComposeTarget(ref: $0) }, retime: { retiming = $0 },
                        search: { showSearch = true }, settings: { showSettings = true })
        case .journal:
            JournalScreen(open: open, edit: { composing = ComposeTarget(ref: $0) }, retime: { retiming = $0 },
                          search: { showSearch = true }, settings: { showSettings = true })
        case .lookBack:
            LookBackScreen(open: open, search: { showSearch = true }, settings: { showSettings = true })
        }
    }

    /// A write that didn't land, or a journal folder that can't be reached:
    /// said plainly, in the accent, above everything, until it's gone.
    @ViewBuilder private var notice: some View {
        if let message = store.storageUnavailableMessage ?? store.lastWriteError {
            VStack(spacing: 0) {
                Text(message)
                    .font(q.ui(13)).foregroundStyle(q.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26).padding(.vertical, 10)
                QRule()
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func open(_ ref: EntryRef) { path.append(ref) }

    /// The terminal app's keys on Today and Look back: n new, i inbox, j journal,
    /// l look back, / search, r a random entry, p another prompt, "," settings,
    /// ↵ write from the prompt, Esc back to Today. Lists and open entries get
    /// first refusal; the first ↑/↓ from Today jumps to the Journal's top or bottom.
    private func registerRootKeys() {
        KeyCommandRouter.shared.onBack = { path.removeAll(); tab = .today }
        KeyCommandRouter.shared.register(rootKeyID, QuireKeyHandlers(
            moveUp: { jumpToJournal(up: true) },
            moveDown: { jumpToJournal(up: false) },
            open: { if tab == .today { composing = ComposeTarget(ref: nil) } },
            clear: { if tab != .today { path.removeAll(); tab = .today } },
            key: { k in
                switch k {
                case "n": composing = ComposeTarget(ref: nil)
                case "i": path.removeAll(); tab = .inbox
                case "j": path.removeAll(); tab = .journal
                case "l": path.removeAll(); tab = .lookBack
                case "/": showSearch = true
                case ",":
                    // With a monitor attached the settings open there, for the keyboard;
                    // otherwise the usual sheet.
                    let monitor = ExternalDisplayModel.shared
                    if monitor.isConnected, !monitor.isPaused, !AppLockManager.shared.showsVeil {
                        ExternalSettingsModel.shared.toggle(store: store)
                    } else { showSettings = true }
                case "p":
                    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "quirePromptOffset") + 1, forKey: "quirePromptOffset")
                case "r":
                    if let r = store.randomEntry() { open(EntryRef(entry: r.entry, source: .archive(date: r.date))) }
                default: return false
                }
                return true
            }))
    }

    /// From Today there is no list to move through, so the first arrow opens the
    /// Journal and selects its top (↓) or bottom (↑) entry: there is always
    /// something to browse.
    private func jumpToJournal(up: Bool) {
        guard tab == .today || tab == .lookBack else { return }
        path.removeAll(); tab = .journal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if up { KeyCommandRouter.shared.moveUp() } else { KeyCommandRouter.shared.moveDown() }
        }
    }
}

#endif
