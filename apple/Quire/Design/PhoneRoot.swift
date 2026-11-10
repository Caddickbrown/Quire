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
    /// ⌘K, Jump to a date: the day for the Journal to go to.
    @State private var journalJump: String?
    /// What waits for the composer to close through its own save: a choice
    /// from ⌘K, a new page asked for from outside (widget, reminder, quick
    /// action, quire://write), or an entry to open (Spotlight, a notification).
    /// The composer is never taken down from here: its last words, a recording
    /// in progress and a save that is failing are all its own to deal with.
    private enum AfterComposer { case command(CommandAction), open(NavigationModel.OpenRequest) }
    @State private var afterComposer: AfterComposer?
    /// The composer's entry as its saves move it (a new date, a recovery copy):
    /// the open page follows it only while it is that entry's page.
    @State private var composerRef: EntryRef?
    /// A page the composer was about to write when Quire last closed, and the
    /// journal doesn't hold (`ComposerRecovery`): asked about once it is safe to.
    @State private var recovery: ComposerRecovery?
    @State private var recoveryNote: String?
    /// The faces' own state, kept here: the face is built in a different place
    /// for the phone, the sidebar and the sidebar with a page beside it, so a
    /// rotation or a resized window would otherwise start each one afresh.
    @State private var journalStarred = false
    @State private var journalSplit: String?
    @State private var journalSelected: Int?
    @State private var inboxSelected: Int?
    @State private var lookBackSelected: Int?
    /// Today's "Write a line", not yet saved.
    @State private var todayLine = ""
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The page sits beside the list rather than over it.
    @State private var splitActive = false
    /// The sidebar folded to a strip; remembered across launches.
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false

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
        shellAsking
        .background(KeyCommandCatcher().frame(width: 0, height: 0).allowsHitTesting(false))
        .background(CommandMenuShortcut())
        .qKeyBlocker(active: composing != nil || retiming != nil || showSearch || showSettings || showMedia,
                     onEscape: { closeSheet() })
        .fullScreenCover(item: $composing, onDismiss: {
            restoreMonitorPage()
            // A page taken down with a save that never landed is offered at once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { checkRecovery() }
            if let next = afterComposer {
                afterComposer = nil
                switch next {
                case .command(let action): runCommand(action)
                case .open(let request): show(request)
                }
            }
        }) { target in
            // The open page follows a save, and closes on a file or a discard,
            // only when it is the page of the entry being edited: `e` on a list
            // row edits an entry that is not the one open beside the list.
            ComposerScreen(target: target, onUpdate: { updated in
                let was = composerRef ?? target.ref
                composerRef = updated
                if target.ref != nil, let was, let last = path.last, last.id == was.id {
                    path[path.count - 1] = updated
                }
            }, onRemove: {
                if target.ref != nil, let was = composerRef ?? target.ref, let last = path.last, last.id == was.id {
                    path.removeLast()
                }
            })
            // The composer paints its own page; clear behind it, so a page
            // turning over as it is filed shows the day it lands on.
            .presentationBackground(.clear)
        }
        .sheet(item: $retiming) { ref in
            RetimeSheet(ref: ref, onUpdate: { replaceReference(ref, with: $0) })
                .environment(\.quire, q)
        }
        .sheet(isPresented: $showSearch, onDismiss: { restoreMonitorPage() }) {
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
        // With a page already being written, that page closes first, through its
        // own save, as it does for ⌘K: never by being replaced.
        .onChange(of: nav.newEntrySignal) { _, _ in runCommand(.newDraft) }
        .onChange(of: composing?.id) { _, _ in composerRef = nil }
        // Spotlight, notifications and the widget open entries through the shared
        // model; this shell has its own stack, so it takes the request from there.
        .onChange(of: nav.openRequest) { _, _ in takeOpenRequest() }
        .onAppear(perform: takeOpenRequest)
        // An entry link that arrived before the journal was read (a cold launch
        // from a widget or a notification) waits for the index, then opens.
        .onChange(of: nav.pendingLink) { _, _ in nav.resolvePendingLink(in: store) }
        .onChange(of: store.indexed) { _, _ in nav.resolvePendingLink(in: store) }
        .onAppear { nav.resolvePendingLink(in: store) }
        // Back at compact width nothing sits beside the list, so opening pushes.
        .onChange(of: sizeClass) { _, now in if now != .regular { splitActive = false } }
        // The widgets' Today and Inbox links, and the "Write a line" control.
        .onChange(of: nav.phoneRequest) { _, _ in takePhoneRequest() }
        .onAppear(perform: takePhoneRequest)
        // App Lock: the veil is a window of its own (AppLockVeilWindow), above any
        // sheet or the composer, so nothing stays readable while locked.
        .onAppear { AppLockVeilWindow.shared.setVisible(appLock.showsVeil) }
        .onChange(of: appLock.showsVeil) { _, show in
            AppLockVeilWindow.shared.setVisible(show)
            // Unlocked: a page that never reached the journal can be asked about.
            if !show { checkRecovery() }
            // Something asked the composer to close while the lock was up, when no
            // key reaches it: asked again now.
            if !show, composing != nil, afterComposer != nil { askComposerToClose() }
        }
        // `QUIRE_OPEN=settings|search|media|write|entry` in the launch environment opens that first (screenshots).
        // The external display scene is built by UIKit and can't reach this environment.
        .onAppear {
            ExternalDisplayModel.shared.store = store
            ExternalDisplayModel.shared.colorScheme = q.colorScheme
        }
        .onChange(of: scenePhase) { _, _ in ExternalDisplayModel.shared.updateIdleTimer() }
        .onChange(of: q.id) { _, _ in ExternalDisplayModel.shared.colorScheme = q.colorScheme }
        .onAppear(perform: registerRootKeys)
        .onAppear { CommandHost.shared.perform = runCommand }
        .onAppear {
            switch ProcessInfo.processInfo.environment["QUIRE_OPEN"] {
            case "settings": showSettings = true
            case "search": showSearch = true
            case "media": showMedia = true
            case "write": composing = ComposeTarget(ref: nil)
            case "entry":
                // The newest filed entry, once the journal has loaded.
                Task { @MainActor in
                    for _ in 0..<20 {
                        if let day = store.archiveEntries.first, let e = day.entries.last {
                            open(EntryRef(entry: e, source: .archive(date: day.date))); return
                        }
                        try? await Task.sleep(for: .seconds(0.5))
                    }
                }
            default: break
            }
        }
        // `QUIRE_DESK=idle|entry|browse|date|confirm|live` draws the monitor over the app, as if one
        // were plugged in (screenshots; simulators have no second screen to hand).
        // Drawn at 1920×1080 and scaled to fit, as a monitor would show it.
        .overlay {
            if Self.deskPreview != nil {
                GeometryReader { geo in
                    let k = min(geo.size.width / 1920, geo.size.height / 1080)
                    ExternalDisplayRoot().frame(width: 1920, height: 1080).scaleEffect(k)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .background(Color.black).ignoresSafeArea()
            }
        }
        .task { if let mode = Self.deskPreview { await previewDesk(mode) } }
    }

    /// The shell, and the question about a page that never reached the journal.
    private var shellAsking: some View {
        shell
        // A page Quire closed on before it was saved: once there is a journal to
        // compare it with and to save it to, and never over the lock.
        .onAppear(perform: checkRecovery)
        .onChange(of: store.indexed) { _, _ in checkRecovery() }
        .onChange(of: store.baseURL) { _, _ in checkRecovery() }
        .alert("Quire closed before this page was saved.",
               isPresented: Binding(get: { recovery != nil && !appLock.showsVeil },
                                    set: { if !$0 { recovery = nil } }),
               presenting: recovery) { record in
            Button("Save to Inbox") { saveRecovered(record) }
            Button("Copy text") { copyRecovered(record) }
            Button("Discard", role: .destructive) { ComposerRecovery.remove(record.id); checkRecoverySoon() }
        } message: { record in
            Text(recoveryNote ?? Self.recoveryDescription(record))
        }
    }

    private static var deskPreview: String? { ProcessInfo.processInfo.environment["QUIRE_DESK"] }

    private func previewDesk(_ mode: String) async {
        let model = ExternalDisplayModel.shared
        model.previewConnected()
        var entries: [Entry] = []
        for _ in 0..<20 where entries.isEmpty {
            try? await Task.sleep(for: .seconds(0.5))
            entries = store.allEntriesByDay().flatMap(\.entries)
        }
        let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        switch mode {
        case "entry":
            guard let e = entries.first(where: { $0.body.count > 400 }) ?? entries.first else { return }
            model.present(.editing(title: e.suffix, date: stamp.date(from: e.ts) ?? .now, text: e.shownBody,
                                   caret: Int(ProcessInfo.processInfo.environment["QUIRE_DESK_CARET"] ?? "") ?? e.shownBody.utf16.count,
                                   isStarred: e.isStarred), owner: UUID())
            // "location,length": shade a selection as the composer would.
            let sel = (ProcessInfo.processInfo.environment["QUIRE_DESK_SELECT"] ?? "").split(separator: ",").compactMap { Int($0) }
            if sel.count == 2 { model.selection = NSRange(location: sel[0], length: sel[1]) }
        case "browse":
            model.present(.browsing(listTitle: "Journal", rows: ExternalRow.rows(from: entries), selected: 3), owner: UUID())
        case "date":
            // The date picker over an entry; nothing is written. `QUIRE_DESK_KEYS`
            // presses keys first: < > ← →, ^ v ↑ ↓, anything else as typed.
            let e = entries.first
            let when = e.flatMap { stamp.date(from: $0.ts) } ?? .now
            if let e {
                model.present(.reading(title: e.displayTitle, date: when, text: e.shownBody, isStarred: e.isStarred), owner: UUID())
            }
            DeskDatePicker.shared.open(date: when, title: e?.qTitle ?? "") { _ in nil }
        case "confirm":
            // The question over an entry; ↵ writes nothing here.
            guard let e = entries.first else { return }
            model.present(.reading(title: e.displayTitle, date: stamp.date(from: e.ts) ?? .now, text: e.shownBody,
                                   isStarred: e.isStarred), owner: UUID())
            DeskConfirm.shared.open(.init(kicker: "Journal", question: "Delete this entry?",
                                          detail: DeskConfirm.describe(e), when: DeskConfirm.when(e),
                                          action: "Delete")) { nil }
        default:
            // `live`: the app's own pages publish, and the keys below drive them
            // (`QUIRE_START_TAB=inbox QUIRE_DESK=live QUIRE_DESK_KEYS=d↩` really
            // deletes the first draft).
            try? await Task.sleep(for: .seconds(1))
        }
        // `QUIRE_DESK_KEYS` presses keys: < > ← →, ^ v ↑ ↓, ↩ Return, ⎋ Esc,
        // … waits three seconds (for a sheet to settle), anything else as typed,
        // a beat apart.
        let router = KeyCommandRouter.shared
        for k in ProcessInfo.processInfo.environment["QUIRE_DESK_KEYS"] ?? "" {
            switch k {
            case "<": router.sideways(-1)
            case ">": router.sideways(1)
            case "^": router.moveUp()
            case "v": router.moveDown()
            case "↩": router.open()
            case "⎋": router.clear()
            case "…": try? await Task.sleep(for: .seconds(3))
            default: router.key(String(k))
            }
            try? await Task.sleep(for: .seconds(0.4))
        }
    }

    /// Compact width: the phone shell. Regular width (iPad, an opened-out
    /// iPhone): the tab words become a sidebar, which folds to a strip, and
    /// where there is room the page opens beside the list instead of over it.
    @ViewBuilder private var shell: some View {
        if sizeClass == .regular {
            HStack(spacing: 0) {
                if sidebarCollapsed {
                    QSideRail(onNew: { composing = ComposeTarget(ref: nil) },
                              onExpand: { withAnimation(foldAnimation) { sidebarCollapsed = false } },
                              onMedia: { showMedia = true }, onSearch: { showSearch = true },
                              onSettings: { showSettings = true })
                } else {
                    QSideBar(tab: tabChoice, inboxCount: store.inboxDrafts.count,
                             onNew: { composing = ComposeTarget(ref: nil) },
                             onCollapse: { withAnimation(foldAnimation) { sidebarCollapsed = true } },
                             onMedia: { showMedia = true }, onSearch: { showSearch = true },
                             onSettings: { showSettings = true })
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
                .environment(\.qBesideSidebar, true)
            }
            .background(q.pageColor)
        } else {
            stack(withChrome: true)
        }
    }

    /// The sidebar stays in reach while a page is open; choosing another face
    /// closes the page, as the phone's tab bar never shows over one. Done where
    /// the face is chosen, not by watching `tab`: an entry link sets the face and
    /// the page together, and a watcher then closed the page it had just opened.
    private func select(_ new: PhoneTab) {
        if new != tab { path.removeAll() }
        tab = new
    }

    private var tabChoice: Binding<PhoneTab> { Binding(get: { tab }, set: { select($0) }) }

    /// The sidebar folding to its strip and back; at once with Reduce Motion on.
    private var foldAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.2) }

    /// The list with pages pushed over it; on the phone it carries the notice
    /// and the tab bar, beside the sidebar it doesn't.
    private func stack(withChrome: Bool) -> some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if withChrome { notice }
                face
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .qArrivalRoot(key: tab)
                if withChrome {
                    QTabBar(tab: tabChoice, inboxCount: store.inboxDrafts.count) {
                        composing = ComposeTarget(ref: nil)
                    }
                }
            }
            .background(q.pageColor)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: EntryRef.self) { ref in
                ReaderScreen(ref: ref, onEdit: { composing = ComposeTarget(ref: $0) },
                             onRetime: { retiming = $0 }, onRetimeKey: retimeFromKeys)
                    .qArrivalRoot(key: ref.id)
            }
        }
    }

    /// The face at list width, the open entry beside it.
    private var splitContent: some View {
        HStack(spacing: 0) {
            face
                .frame(width: Self.listWidth)
                .frame(maxHeight: .infinity)
                .qArrivalRoot(key: tab)
            verticalRule
            Group {
                if let ref = path.last {
                    ReaderScreen(ref: ref, onEdit: { composing = ComposeTarget(ref: $0) },
                                 onRetime: { retiming = $0 }, onRetimeKey: retimeFromKeys,
                                 onClose: { path.removeAll(); ExternalDisplayModel.shared.relist() })
                        .qArrivalRoot(key: ref.id)
                        // One reader per entry: its keys, its question and what
                        // is playing belong to the entry it opened with, so
                        // another entry gets another reader, not this one re-aimed.
                        .id(ref.id)
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
                        showInbox: { select(.inbox) }, search: { showSearch = true }, settings: { showSettings = true },
                        media: { showMedia = true }, line: $todayLine)
                .onAppear { ExternalDisplayModel.shared.present(.idle) }
        case .inbox:
            InboxScreen(open: open, edit: { composing = ComposeTarget(ref: $0) }, retime: retimeFromKeys,
                        search: { showSearch = true }, settings: { showSettings = true },
                        selected: $inboxSelected)
        case .journal:
            JournalScreen(open: open, edit: { composing = ComposeTarget(ref: $0) }, retime: retimeFromKeys,
                          search: { showSearch = true }, settings: { showSettings = true }, media: { showMedia = true },
                          jump: $journalJump, starredOnly: $journalStarred, splitName: $journalSplit,
                          selected: $journalSelected)
        case .lookBack:
            LookBackScreen(open: open, search: { showSearch = true }, settings: { showSettings = true },
                           selected: $lookBackSelected)
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

    // MARK: A page that never reached the journal

    /// Look for pages the composer kept just before a write that Quire didn't
    /// live to see land. One the journal already holds, word for word, did
    /// land: its file goes, silently. The first that didn't is asked about,
    /// once; nothing is ever written without the answer. Waits for a journal
    /// that has been read (there is nothing to compare with before), and for
    /// the lock, a sheet or the composer to be out of the way.
    private func checkRecovery() {
        guard recovery == nil, store.baseURL != nil, store.indexed, !appLock.showsVeil,
              composing == nil, retiming == nil, !showSearch, !showSettings, !showMedia else { return }
        for record in ComposerRecovery.all() {
            if journalHolds(record) { ComposerRecovery.remove(record.id); continue }
            recoveryNote = nil
            recovery = record
            return
        }
    }

    /// After an answer, once its alert has gone: the next one, if there is one.
    private func checkRecoverySoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { checkRecovery() }
    }

    /// Whether the entry as it was about to be written is in the journal: among
    /// the drafts, on the day it was stamped for, or where the entry it edited
    /// lives. `composed` and an entry's `raw` are both the core's own text
    /// (guards and all), so this compares like with like; an entry read from
    /// its file also carries the blank line after it, which is taken off.
    private func journalHolds(_ record: ComposerRecovery) -> Bool {
        let wanted = JournalParser.trimRightNewlines(record.composed)
        func holds(_ entries: [Entry]) -> Bool {
            entries.contains { JournalParser.trimRightNewlines($0.raw) == wanted }
        }
        if holds(store.inboxDrafts) { return true }
        var days = [String(record.stamp.prefix(10))]
        if let source = record.source {
            if source.hasPrefix("archive:") { days.append(String(source.dropFirst("archive:".count))) }
            if source.hasPrefix("journal:"), holds(store.entries(inJournal: String(source.dropFirst("journal:".count)))) {
                return true
            }
        }
        // From the index, not a fresh read of the journal on the main thread.
        return days.contains { day in holds(store.archiveEntries.first { $0.date == day }?.entries ?? []) }
    }

    /// "9 Nov, 14:02 · the title or the first words", so the page can be told.
    private static func recoveryDescription(_ record: ComposerRecovery) -> String {
        let firstLine = record.text.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (title.isEmpty ? firstLine : title).qClamped(80)
        let when = "\(QDate.shortDay(String(record.stamp.prefix(10)))), \(QDate.time(record.stamp))"
        return name.isEmpty ? when : "\(when) · \(name)"
    }

    /// A new, distinct Inbox draft through the composer's own create path. The
    /// kept file goes only when the draft is in the journal; if the write
    /// fails it stays, the notice says why, and it is offered again next time.
    private func saveRecovered(_ record: ComposerRecovery) {
        // Still there: a second window may have answered for it already.
        guard ComposerRecovery.all().contains(where: { $0.id == record.id }) else { return }
        let title = ComposerScreen.headerTitle(record.title, starred: record.starred)
        guard store.createEditorDraft(timestamp: record.stamp, title: title, body: record.text) != nil else { return }
        ComposerRecovery.remove(record.id)
        checkRecoverySoon()
    }

    /// The words on the clipboard; the file stays and the question comes back,
    /// since a clipboard is no place to leave the only copy.
    private func copyRecovered(_ record: ComposerRecovery) {
        let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        UIPasteboard.general.string = title.isEmpty ? record.text : title + "\n\n" + record.text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard recovery == nil, !appLock.showsVeil, composing == nil,
                  ComposerRecovery.all().contains(where: { $0.id == record.id }) else { return }
            recoveryNote = "Copied. " + Self.recoveryDescription(record)
            recovery = record
        }
    }

    private func restoreMonitorPage() {
        if let ref = path.last {
            ExternalDisplayModel.shared.present(.reading(title: ref.entry.displayTitle,
                date: QDate.date(ref.entry.ts) ?? Date(), text: ref.entry.shownBody, isStarred: ref.entry.isStarred,
                isDraft: ref.source == .inbox))
        } else if tab == .today { ExternalDisplayModel.shared.present(.idle) }
        else { ExternalDisplayModel.shared.relist() }
    }

    /// `t` on a list or an open entry. With the monitor in desk mode the date is
    /// changed there, from the keyboard (the phone's sheet is out of sight and its
    /// graphical picker takes no keys); otherwise the sheet, as a tap opens.
    private func retimeFromKeys(_ ref: EntryRef) {
        let picker = DeskDatePicker.shared
        guard picker.isAvailable else { retiming = ref; return }
        picker.open(date: JournalStore.date(from: ref.entry.ts) ?? Date(), title: ref.entry.qTitle) { date in
            RetimeSheet.retime(ref, to: date, in: store) { replaceReference(ref, with: $0) }
        }
    }

    private func replaceReference(_ old: EntryRef, with updated: EntryRef) {
        path = path.map { $0 == old ? updated : $0 }
    }

    /// Beside the list, opening replaces the page; on the phone it pushes.
    private func open(_ ref: EntryRef) {
        if splitActive { path = [ref] } else { path.append(ref) }
    }

    /// Open what Spotlight, a notification or the widget asked for: close whatever
    /// is presented, go to the entry's face, and push it. The composer closes
    /// itself first, through its own save; if that save fails the page being
    /// written stays and the request is dropped.
    private func takeOpenRequest() {
        guard let request = nav.openRequest else { return }
        nav.openRequest = nil
        if composing != nil { closeComposer(then: .open(request)); return }
        show(request)
    }

    private func show(_ request: NavigationModel.OpenRequest) {
        let presented = retiming != nil || showSearch || showSettings || showMedia
        retiming = nil; showSearch = false; showSettings = false; showMedia = false
        let ref = EntryRef(entry: request.entry, source: request.source)
        let push = {
            // A split journal is read from the Journal's title, so its entry
            // opens with that journal chosen behind it.
            switch request.source {
            case .inbox: tab = .inbox
            case .archive: tab = .journal
            case .journal(let name): tab = .journal; journalSplit = name
            }
            path = [ref]
        }
        // Let a sheet finish leaving before the page is pushed.
        if presented { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: push) } else { push() }
    }

    /// Ask the composer to close, as Esc does: it saves, and leaves only if the
    /// save landed. `next` is done once it has gone (the cover's `onDismiss`).
    private func closeComposer(then next: AfterComposer) {
        afterComposer = next
        // Behind App Lock no key reaches the composer; it is asked when the lock lifts.
        guard !appLock.showsVeil else { return }
        askComposerToClose()
    }

    private func askComposerToClose() {
        KeyCommandRouter.shared.clear()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            // Still open: the save failed, or something over the page took the
            // Esc. The page stays and what was asked is dropped.
            if composing != nil, !appLock.showsVeil { afterComposer = nil }
        }
    }

    /// What ⌘K chose. Over the composer it closes the composer first, through its
    /// own save, and carries on from there; if that save fails the page stays and
    /// the choice is dropped. Sheets are closed before anything is shown.
    private func runCommand(_ action: CommandAction) {
        if composing != nil { closeComposer(then: .command(action)); return }
        let keepsSearch = action == .search && showSearch
        let keepsSettings = action == .settings && showSettings
        let wasUp = retiming != nil || showMedia || (showSearch && !keepsSearch) || (showSettings && !keepsSettings)
        retiming = nil; showMedia = false
        if !keepsSearch { showSearch = false }
        if !keepsSettings { showSettings = false }
        if action != .settings { ExternalSettingsModel.shared.close() }
        let go = {
            switch action {
            case .today: path.removeAll(); tab = .today
            case .inbox: path.removeAll(); tab = .inbox
            case .journal: path.removeAll(); tab = .journal
            case .search: if !keepsSearch { openSearch() }
            case .newDraft: composing = ComposeTarget(ref: nil)
            case .settings: if !keepsSettings { openSettings() }
            case .jump(let day): path.removeAll(); tab = .journal; journalJump = day
            }
        }
        // Let a sheet finish leaving first.
        if wasUp { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: go) } else { go() }
    }

    /// With the monitor showing things the results go there, and an open entry
    /// holds its page, so the entry closes first.
    private func openSearch() {
        if DeskDatePicker.shared.isAvailable { path.removeAll() }
        showSearch = true
    }

    /// With a monitor attached the settings open there, for the keyboard;
    /// otherwise the usual sheet.
    private func openSettings() {
        if DeskDatePicker.shared.isAvailable {
            let model = ExternalSettingsModel.shared
            if !model.isOpen { model.open(store: store) }
        } else { showSettings = true }
    }

    /// The terminal app's keys on Today and Look back: n new, i inbox, j journal,
    /// l look back, / search, r a random entry, p another prompt, "," settings,
    /// ↵ write from the prompt, Esc back to Today. Lists and open entries get
    /// first refusal; the first ↑/↓ from Today jumps to the Journal's top or bottom.
    private func registerRootKeys() {
        KeyCommandRouter.shared.onBack = { if !closeSheet() { path.removeAll(); tab = .today } }
        KeyCommandRouter.shared.register(rootKeyID, QuireKeyHandlers(
            moveUp: { jumpToJournal(up: true) },
            moveDown: { jumpToJournal(up: false) },
            open: { if tab == .today || idleOnMonitor { composing = ComposeTarget(ref: nil) } },
            clear: { if tab != .today { path.removeAll(); tab = .today } },
            key: { k in
                switch k {
                case "n": composing = ComposeTarget(ref: nil)
                case "i": path.removeAll(); tab = .inbox
                case "j": path.removeAll(); tab = .journal
                case "l": path.removeAll(); tab = .lookBack
                case "/": openSearch()
                case ",": openSettings()
                case "p":
                    // The prompt is on Today, and on the monitor's Today page.
                    guard (tab == .today && path.isEmpty) || idleOnMonitor else { return false }
                    QuirePrompts.next()
                case "r":
                    // Another random entry takes the open page's place rather than
                    // stacking up, so Esc on the phone still goes straight back to the list.
                    if let r = store.randomEntry() {
                        let ref = EntryRef(entry: r.entry, source: .archive(date: r.date))
                        if !path.isEmpty, !splitActive { path[path.count - 1] = ref } else { open(ref) }
                    }
                default: return false
                }
                return true
            }))
    }

    /// Look back with nothing on this day leaves the monitor on its Today page,
    /// whose "begin a new entry" and prompt then answer to ↵ and `p` as its
    /// hint bar says.
    private var idleOnMonitor: Bool {
        let monitor = ExternalDisplayModel.shared
        return tab == .lookBack && path.isEmpty && monitor.isConnected && !monitor.isPaused && monitor.content == .idle
    }

    /// Esc over a sheet closes it and goes no further, whatever is beneath. Not the
    /// composer: it closes itself, through its own save.
    @discardableResult private func closeSheet() -> Bool {
        if retiming != nil { retiming = nil }
        else if showSearch { showSearch = false }
        else if showMedia { showMedia = false }
        else if showSettings { showSettings = false }
        else { return false }
        return true
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
