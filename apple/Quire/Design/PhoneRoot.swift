//
//  PhoneRoot.swift
//  Quire
//
//  The iPhone and iPad shell: four faces (Today, Inbox, Journal, Look back)
//  behind a text tab bar, with "+" for a new entry. Entries open as pages that
//  push over the faces; the composer and the retime sheet come up over
//  everything. At regular width the tab bar becomes a sidebar and, with room,
//  the page opens beside the list.
//

#if os(iOS)

import SwiftUI

struct ComposeTarget: Identifiable {
    let id = UUID()
    /// nil: a new draft. Otherwise the entry being edited, wherever it lives.
    var ref: EntryRef?
}

struct PhoneRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.quire) private var q
    @ObservedObject private var appLock = AppLockManager.shared

    @State private var tab: PhoneTab = Self.startTab
    @State private var path: [EntryRef] = []
    @State private var composing: ComposeTarget?
    @State private var retiming: EntryRef?
    @State private var showMedia = false
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var rootKeyID = UUID()
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The page sits beside the list rather than over it.
    @State private var splitActive = false

    /// The content column (window less the sidebar) needs this much before the
    /// page goes beside the list: iPad landscape and an opened-out iPhone do,
    /// iPad portrait doesn't.
    private static let splitMinWidth: CGFloat = 700
    private static let listWidth: CGFloat = 360

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
        shell
        .background(KeyCommandCatcher().frame(width: 0, height: 0).allowsHitTesting(false))
        .qKeyBlocker(active: composing != nil || retiming != nil || showSearch || showSettings || showMedia)
        .fullScreenCover(item: $composing, onDismiss: { restoreMonitorPage() }) { target in
            ComposerScreen(target: target, onUpdate: { updated in
                if target.ref != nil, !path.isEmpty { path[path.count - 1] = updated }
            }, onRemove: {
                if target.ref != nil, !path.isEmpty { path.removeLast() }
            })
        }
        .sheet(item: $retiming) { ref in
            RetimeSheet(ref: ref, onUpdate: { replaceReference(ref, with: $0) })
                .environment(\.quire, q)
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
        .sheet(isPresented: $showMedia) {
            NavigationStack {
                AssetsView(onOpenEntry: { entry, source in
                    showMedia = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        open(EntryRef(entry: entry, source: source))
                    }
                }, onClose: { showMedia = false })
                .toolbar(.hidden, for: .navigationBar)
            }
            .environmentObject(store).environmentObject(nav)
            .environment(\.quire, q)
            .tint(q.accentColor)
            .preferredColorScheme(q.colorScheme)
        }
        .sheet(isPresented: $showSettings) {
            PhoneSettings(openMedia: {
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showMedia = true }
            })
                .environmentObject(store).environmentObject(nav)
                .environment(\.quire, q)
        }
        // The widget, the reminder and the home-screen action all ask for the
        // composer through the shared navigation model.
        .onChange(of: nav.newEntrySignal) { _, _ in composing = ComposeTarget(ref: nil) }
        // Spotlight, notifications and the widget open entries through the shared
        // model; this shell has its own stack, so it takes the request from there.
        .onChange(of: nav.openRequest) { _, _ in takeOpenRequest() }
        .onAppear(perform: takeOpenRequest)
        // The widgets' Today and Inbox links, and the "Write a line" control.
        .onChange(of: nav.phoneRequest) { _, _ in takePhoneRequest() }
        .onAppear(perform: takePhoneRequest)
        // App Lock: the veil is a window of its own (AppLockVeilWindow), above any
        // sheet or the composer, so nothing stays readable while locked.
        .onAppear { AppLockVeilWindow.shared.setVisible(appLock.showsVeil) }
        .onChange(of: appLock.showsVeil) { _, show in AppLockVeilWindow.shared.setVisible(show) }
        // `QUIRE_OPEN=settings|search` in the launch environment opens that first (screenshots).
        // The external display scene is built by UIKit and can't reach this environment.
        .onAppear {
            ExternalDisplayModel.shared.store = store
            ExternalDisplayModel.shared.colorScheme = q.colorScheme
        }
        .onChange(of: scenePhase) { _, _ in ExternalDisplayModel.shared.updateIdleTimer() }
        .onChange(of: q.id) { _, _ in ExternalDisplayModel.shared.colorScheme = q.colorScheme }
        .onAppear(perform: registerRootKeys)
        .onAppear {
            switch ProcessInfo.processInfo.environment["QUIRE_OPEN"] {
            case "settings": showSettings = true
            case "search": showSearch = true
            case "media": showMedia = true
            default: break
            }
        }
    }

    /// Compact width: the phone shell. Regular width (iPad, an opened-out
    /// iPhone): the tab words become a sidebar, and where there is room the
    /// page opens beside the list instead of over it.
    @ViewBuilder private var shell: some View {
        if sizeClass == .regular {
            HStack(spacing: 0) {
                QSideBar(tab: $tab, inboxCount: store.inboxDrafts.count) {
                    composing = ComposeTarget(ref: nil)
                }
                verticalRule
                VStack(spacing: 0) {
                    notice
                    GeometryReader { geo in
                        let split = geo.size.width >= Self.splitMinWidth
                        Group {
                            if split { splitContent } else { stack(withChrome: false) }
                        }
                        .onAppear { splitActive = split }
                        .onChange(of: split) { _, now in
                            splitActive = now
                            // Only one page shows beside the list.
                            if now, path.count > 1 { path = Array(path.suffix(1)) }
                        }
                    }
                }
            }
            .background(q.pageColor)
            // The sidebar stays in reach while a page is open; choosing another
            // face closes the page, as the phone's tab bar never shows over one.
            .onChange(of: tab) { _, _ in path.removeAll() }
        } else {
            stack(withChrome: true)
        }
    }

    /// The list with pages pushed over it; on the phone it carries the notice
    /// and the tab bar, beside the sidebar it doesn't.
    private func stack(withChrome: Bool) -> some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if withChrome { notice }
                face
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if withChrome {
                    QTabBar(tab: $tab, inboxCount: store.inboxDrafts.count) {
                        composing = ComposeTarget(ref: nil)
                    }
                }
            }
            .background(q.pageColor)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: EntryRef.self) { ref in
                ReaderScreen(ref: ref, onEdit: { composing = ComposeTarget(ref: $0) },
                             onRetime: { retiming = $0 })
            }
        }
    }

    /// The face at list width, the open entry beside it.
    private var splitContent: some View {
        HStack(spacing: 0) {
            face
                .frame(width: Self.listWidth)
                .frame(maxHeight: .infinity)
            verticalRule
            Group {
                if let ref = path.last {
                    ReaderScreen(ref: ref, onEdit: { composing = ComposeTarget(ref: $0) },
                                 onRetime: { retiming = $0 }, onClose: { path.removeAll() })
                } else {
                    emptyPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(q.pageColor)
    }

    private var emptyPage: some View {
        VStack(spacing: 8) {
            Text(q.caps("Nothing open"))
                .font(q.isMarathon ? q.display(20) : q.writing(24, italic: true))
                .foregroundStyle(q.mutedColor)
            Text("Choose an entry, or begin a new one.")
                .font(q.ui(13)).foregroundStyle(q.mutedColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(q.pageColor)
    }

    private var verticalRule: some View {
        Rectangle().fill(q.lineColor).frame(width: 1).accessibilityHidden(true)
    }

    @ViewBuilder private var face: some View {
        switch tab {
        case .today:
            TodayScreen(open: open, compose: { composing = ComposeTarget(ref: nil) },
                        showInbox: { tab = .inbox }, search: { showSearch = true }, settings: { showSettings = true })
                .onAppear { ExternalDisplayModel.shared.present(.idle) }
        case .inbox:
            InboxScreen(open: open, edit: { composing = ComposeTarget(ref: $0) }, retime: { retiming = $0 },
                        search: { showSearch = true }, settings: { showSettings = true })
        case .journal:
            JournalScreen(open: open, edit: { composing = ComposeTarget(ref: $0) }, retime: { retiming = $0 },
                          search: { showSearch = true }, settings: { showSettings = true }, media: { showMedia = true })
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

    /// `.capture` is left for TodayScreen, which focuses its field and clears
    /// it; with the composer up, the request is dropped rather than closing it.
    private func takePhoneRequest() {
        guard let request = nav.phoneRequest else { return }
        if composing != nil { nav.phoneRequest = nil; return }
        path.removeAll()
        switch request {
        case .today: tab = .today; nav.phoneRequest = nil
        case .inbox: tab = .inbox; nav.phoneRequest = nil
        case .capture: tab = .today
        }
    }

    private func restoreMonitorPage() {
        if let ref = path.last {
            ExternalDisplayModel.shared.present(.reading(title: ref.entry.displayTitle,
                date: QDate.date(ref.entry.ts) ?? Date(), text: ref.entry.body, isStarred: ref.entry.isStarred))
        } else if tab == .today { ExternalDisplayModel.shared.present(.idle) }
    }

    private func replaceReference(_ old: EntryRef, with updated: EntryRef) {
        path = path.map { $0 == old ? updated : $0 }
    }

    /// Beside the list, opening replaces the page; on the phone it pushes.
    private func open(_ ref: EntryRef) {
        if splitActive { path = [ref] } else { path.append(ref) }
    }

    /// Open what Spotlight, a notification or the widget asked for: close whatever
    /// is presented, go to the entry's face, and push it.
    private func takeOpenRequest() {
        guard let request = nav.openRequest else { return }
        nav.openRequest = nil
        let presented = composing != nil || retiming != nil || showSearch || showSettings || showMedia
        composing = nil; retiming = nil; showSearch = false; showSettings = false; showMedia = false
        let ref = EntryRef(entry: request.entry, source: request.source)
        let push = {
            if case .inbox = request.source { tab = .inbox } else { tab = .journal }
            path = [ref]
        }
        // Let a sheet or the composer finish leaving before the page is pushed.
        if presented { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: push) } else { push() }
    }

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
                    QuirePrompts.next()
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
