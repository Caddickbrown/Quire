//
//  CommandMenu.swift
//  Quire
//
//  ⌘K, or ⌘ in the masthead without a keyboard. What it lists is
//  `Models/QuireCommands.swift`, built from a plain `QuireCommandState`; the
//  keys, recents, steps and previews are App Kit's
//  (`kit/swift/CommandPalette.swift`). This file makes the state from what's on
//  screen, does what each command says (with `PhoneRoot.runCommand`), and draws
//  the panel in Quire's design. With the monitor showing things it is drawn
//  there (in VS Code's own dress in hidden mode, `DeskCode.swift`); otherwise
//  over the phone or iPad.
//

#if os(iOS)

import Combine
import SwiftUI
import UIKit

// MARK: - What's selected, and the page being written

/// The entry the menu acts on: a page that's open, or else a list's selected row.
@MainActor final class CommandFocus {
    static let shared = CommandFocus()
    private init() {}

    struct Target {
        let ref: EntryRef
        let isPage: Bool
    }

    private var targets: [(id: UUID, target: Target)] = []

    /// A page or a list says what it has selected (nil: nothing, or it's gone).
    func set(_ owner: UUID, _ target: Target?) {
        targets.removeAll { $0.id == owner }
        if let target { targets.append((owner, target)) }
        QuireCommandMenu.refreshSoon()
    }

    var current: Target? { targets.last(where: { $0.target.isPage })?.target ?? targets.last?.target }

    func target(_ id: String) -> Target? { targets.last { $0.target.ref.id == id }?.target }
}

/// The page being written, for the menu: what it is, and a way to ask it to do things without closing it.
@MainActor final class ComposerCommands {
    static let shared = ComposerCommands()
    private init() {}

    private(set) var state: QuireCommandState.Composer?
    private var owner: UUID?
    private var run: ((QuireComposerAction) -> Void)?

    func attach(_ owner: UUID, _ state: QuireCommandState.Composer, run: @escaping (QuireComposerAction) -> Void) {
        self.owner = owner
        self.state = state
        self.run = run
        QuireCommandMenu.refreshSoon()
    }

    func update(_ owner: UUID, _ state: QuireCommandState.Composer) {
        guard owner == self.owner, state != self.state else { return }
        self.state = state
        QuireCommandMenu.refreshSoon()
    }

    func detach(_ owner: UUID) {
        guard owner == self.owner else { return }
        self.owner = nil; state = nil; run = nil
        QuireCommandMenu.refreshSoon()
    }

    func perform(_ action: QuireComposerAction) { run?(action) }
}

// MARK: - The menu

@MainActor enum QuireCommandMenu {
    /// Set by `PhoneRoot`, which owns the faces, the pages and the sheets: what's on screen, as the list wants it.
    static var screen: () -> QuireCommandState? = { nil }
    /// What a chosen command does.
    static var run: (QuireCommand) -> Void = { _ in }
    /// Leaves the sheet or the page being written, the way Esc does, before a command that goes elsewhere.
    static var leave: () -> Void = {}
    /// What's in Search's box (`SearchScreen`), for Pin a search….
    static var searchQuery = ""

    static let host: CommandHost<QuireCommandList> = {
        let host = CommandHost<QuireCommandList>()
        host.list = { screen().map { QuireCommandList(state: $0) } }
        host.monitorShows = { DeskDatePicker.shared.isAvailable }
        // Not behind App Lock, and not over a question or the date picker, which are answered first.
        host.blocked = {
            AppLockManager.shared.showsVeil || DeskConfirm.shared.isOpen || DeskDatePicker.shared.isOpen
                || ExternalDisplayModel.shared.store == nil
        }
        host.recents = CommandRecents(key: "quire.commands.recents")
        host.perform = { run($0) }
        // A theme tried while the highlight passes: the setting, and nothing that follows from it.
        host.preview = { action in
            if case .pref(let key, let value) = action { write(key, value) }
        }
        host.onHighlight = { row in
            if let row, case .run(let action) = row.step { lit = action } else { lit = nil }
        }
        // A command that is done where it's chosen (one for the page being written, a setting) is done there, and
        // the page or sheet stays; anything else leaves it first, as Esc would.
        host.leaveSheet = {
            if let action = lit, action.staysOverSheets { run(action) } else { leave() }
        }
        host.overlay = { AnyView(CommandMenuOverlay()) }
        return host
    }()

    /// The row lit last: the one chosen, when the host asks for the sheet to go.
    private static var lit: QuireCommand?
    private static var watching: [AnyCancellable] = []
    private static let routerID = UUID()

    /// Once, at launch.
    static func install() {
        _ = host
        watching = [
            // Nothing beneath acts while the menu is up, even for a key that reaches the app delegate.
            host.$menu.map { $0 != nil }.removeDuplicates().sink { open in
                if open {
                    if let store = ExternalDisplayModel.shared.store { loadExtras(store: store) }
                    KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
                        moveUp: {}, moveDown: {}, open: {}, clear: { host.close() }, key: { _ in true }))
                } else {
                    KeyCommandRouter.shared.unregister(routerID)
                }
            },
            // Whatever changes while it's open (a preview, a star, the monitor going), the list follows.
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main).sink { _ in refreshSoon() },
            ExternalDisplayModel.shared.objectWillChange.receive(on: DispatchQueue.main).sink { _ in refreshSoon() },
        ]
    }

    private static var refreshPending = false

    /// Soon, and once for a burst of changes (an autosave announces several).
    static func refreshSoon() {
        guard host.menu != nil, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            refreshPending = false
            host.refresh()
        }
    }

    // MARK: Settings

    static func write(_ key: String, _ value: QuirePref) {
        let d = UserDefaults.standard
        switch value {
        case .bool(let v): d.set(v, forKey: key)
        case .int(let v): d.set(v, forKey: key)
        case .double(let v): d.set(v, forKey: key)
        case .string(let v): d.set(v, forKey: key)
        }
    }

    /// A setting, and whatever Settings does when it changes.
    static func set(_ key: String, _ value: QuirePref, store: JournalStore) {
        write(key, value)
        switch key {
        case QuirePrefKey.reminder:
            if case .bool(true) = value {
                Task { @MainActor in
                    if await ReminderScheduler.requestPermission() { refreshReminder(store) }
                    else { write(key, .bool(false)) }
                }
            } else { refreshReminder(store) }
        case QuirePrefKey.weekly:
            if case .bool(true) = value {
                Task { @MainActor in
                    if await ReminderScheduler.requestPermission() { ResurfacingScheduler.settingsChanged(store: store) }
                    else { write(key, .bool(false)) }
                }
            } else { ResurfacingScheduler.settingsChanged(store: store) }
        case QuirePrefKey.weeklyDay, QuirePrefKey.weeklyHour:
            ResurfacingScheduler.settingsChanged(store: store)
        case QuirePrefKey.appLock:
            AppLockManager.shared.preferenceChanged()
        case QuirePrefKey.spotlight:
            SpotlightIndexer.scheduleReindex(source: { store.spotlightSource() })
        case QuirePrefKey.dimPhone, QuirePrefKey.dimLevel:
            ExternalDisplayModel.shared.autoDimPreferenceChanged()
        default:
            break
        }
    }

    static func setReminderTime(hour: Int, minute: Int, store: JournalStore) {
        UserDefaults.standard.set(hour, forKey: ReminderScheduler.hourKey)
        UserDefaults.standard.set(minute, forKey: ReminderScheduler.minuteKey)
        refreshReminder(store)
    }

    private static func refreshReminder(_ store: JournalStore) {
        let s = store.stats()
        ReminderScheduler.refresh(hasEntryToday: s.hasEntryToday, streak: s.currentStreak)
    }

    /// Dark or light, as the monitor's settings list does it: the look Auto uses for that, and the monitor follows.
    /// A monitor in its hidden (VS Code) look stays hidden: following the phone
    /// would put Quire's own page, journal text and all, on the screen.
    static func setDark(_ dark: Bool) {
        UserDefaults.standard.set(QuireTheme.autoID(dark: dark), forKey: QuireTheme.storageKey)
        UserDefaults.standard.set(MonitorThemeRule.afterDarkOrLight(UserDefaults.standard.string(forKey: ExternalTheme.key)),
                                  forKey: ExternalTheme.key)
    }

    // MARK: Macros

    /// Settings → Macros, run from the menu. What happened, in words.
    static func runMacro(_ macro: QuireMacro, store: JournalStore) async -> String {
        func n(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? "1 \(one)" : "\(count) \(many)" }
        switch macro {
        case .cleanUp:
            let r = store.cleanup()
            return "Cleaned up: moved \(r.moved), formatted \(r.formatted), reordered \(r.reordered), removed \(r.deduped) duplicate(s), extracted \(r.extracted) to split journals."
        case .sortInbox:
            store.sortInbox()
            return "The Inbox is in date order."
        case .fileAll:
            return "Filed \(n(await store.fileAllDraftsAsync(), "draft", "drafts"))."
        case .transfer:
            return "Filed \(n(await store.fileTransferAsync(), "entry", "entries")) from transfer.md."
        case .conflicts:
            return "Merged \(n(await store.mergeConflictCopiesAsync(), "entry", "entries")) from conflict copies."
        case .mergeExSplit:
            let r = await store.mergeExSplitJournalsAsync()
            return "Merged \(n(r.entries, "entry", "entries")) from \(n(r.journals, "journal", "journals"))."
        case .compressMedia:
            let r = await store.compressExistingMedia()
            let total = r.images + r.videos + r.audios
            var said = total == 0 ? "No new media to compress."
                : "Compressed \(r.images) photo(s), \(r.videos) video(s), \(r.audios) audio — saved \(ByteCountFormatter.string(fromByteCount: Int64(r.bytesSaved), countStyle: .file))."
            if r.converted > 0 { said = "Converted \(r.converted) HEIC photo(s) to JPEG. " + said }
            if r.failed > 0 { said += " \(r.failed) couldn't be compressed just now, and will be tried again." }
            return said
        case .transcribeAll:
            let r = await store.transcribeAllMemos()
            return r.done == 0 && r.failed == 0 ? "No untranscribed voice notes."
                : "Transcribed \(n(r.done, "voice note", "voice notes"))\(r.failed > 0 ? "; \(r.failed) failed" : "")."
        case .clearOrphans:
            let count = await store.orphanAssetsAsync().count
            guard count > 0 else { return "No orphan media: every file is in use." }
            let cleared = await store.deleteOrphanAssetsAsync()
            return "Cleared \(n(cleared, "unused file", "unused files")). Copies are kept in .quire/media-cleanup/ for 30 days."
        }
    }

    // MARK: What takes a moment to read: media, backups, templates, tag review

    /// Set by `PhoneRoot` while it asks about a page Quire closed on: that page, in words.
    static var recovery: String?

    private struct Extras {
        var revision = -1
        var media: [QuireCommandState.Media] = []
        var backups: [QuireCommandState.Backup] = []
        var templates: [String] = []
        var tagGroups: [QuireCommandState.TagGroup] = []
    }
    private static var extras = Extras()
    private static var loadingExtras = false

    /// Read off the main thread as the menu opens, and once per change to the journal; the list follows when they land.
    static func loadExtras(store: JournalStore, force: Bool = false) {
        guard !loadingExtras, force || extras.revision != store.revision else { return }
        loadingExtras = true
        let revision = store.revision
        Task { @MainActor in
            defer { loadingExtras = false }
            var next = Extras()
            next.revision = revision
            let base = store.baseURL
            next.media = await store.allAssetsAsync().map { item in
                let kind: String
                switch MediaKind(path: item.name) { case .image: kind = "image"; case .video: kind = "video"; case .audio: kind = "audio" }
                let path = base.map { JournalStore.relativePath(of: item.url, under: $0) } ?? item.name
                return .init(path: path, name: item.name, kind: kind, date: item.date, size: item.size)
            }
            if store.backupFolderName != nil {
                next.backups = await store.listBackups().map { .init(name: $0.name, date: $0.date, isSafetyCopy: $0.isSafetyCopy) }
            }
            next.templates = store.templateNames()
            next.tagGroups = await store.similarTagGroupsAsync().map { g in
                .init(tags: g.variants.map(\.tag), counts: g.variants.map(\.count), caseOnly: g.caseOnly)
            }
            extras = next
            refreshSoon()
        }
    }

    /// The voice notes and videos an entry links, by path from the journal's root.
    static func playable(_ entry: Entry) -> [String] {
        MediaLinks.paths(in: entry.raw).compactMap { MediaLinks.resolved($0, file: entry.file ?? "inbox.md") }
            .filter { MediaKind(path: $0) != .image }
    }

    // MARK: The state, from the app

    /// Saved searches are read from the journal folder: once per change to it, not at every key.
    private static var searchCache: (revision: Int, searches: [QuireCommandState.Search])?

    /// Everything that isn't about the screen: settings, looks, the journal's days, tags, searches, the monitor.
    static func appState(store: JournalStore) -> QuireCommandState {
        var s = QuireCommandState()
        let d = UserDefaults.standard
        func flag(_ key: String, _ value: Bool = false) -> Bool { d.object(forKey: key) as? Bool ?? value }
        var counts: [String: Int] = [:]
        var entries: [QuireCommandState.Item] = []
        func item(_ e: Entry, draft: Bool = false, journal: String? = nil) -> QuireCommandState.Item {
            .init(id: e.id, title: e.qHasTitle ? e.displayTitle : e.qTitle, when: "\(QDate.shortDay(e.date)), \(QDate.time(e.ts))",
                  isDraft: draft, isStarred: e.isStarred, journal: journal)
        }
        for e in store.inboxDrafts.reversed() { entries.append(item(e, draft: true)) }
        for day in store.archiveEntries {
            counts[day.date, default: 0] += day.entries.count
            for e in day.entries.reversed() { entries.append(item(e)) }
        }
        for (name, list) in store.splitEntriesCache.sorted(by: { $0.key < $1.key }) {
            for e in list.reversed() { entries.append(item(e, journal: name)) }
        }
        s.entries = entries
        s.counts = counts
        s.drafts = store.inboxDrafts.count
        s.splits = store.splitJournals.map(\.name)
        s.tags = store.tagCounts.map(\.tag)
        if searchCache?.revision != store.revision {
            searchCache = (store.revision, store.savedSearches().map { .init(name: $0.name, query: $0.query) })
        }
        s.searches = searchCache?.searches ?? []
        s.themes = QuireTheme.all.map { .init(id: $0.id, name: $0.name, dark: $0.dark) }

        var set = QuireCommandState.Settings()
        set.theme = d.string(forKey: QuireTheme.storageKey) ?? QuireTheme.auto
        set.autoLight = QuireTheme.sharedDefaults.string(forKey: QuireTheme.autoLightKey) ?? QuireTheme.defaultAutoLight
        set.autoDark = QuireTheme.sharedDefaults.string(forKey: QuireTheme.autoDarkKey) ?? QuireTheme.defaultAutoDark
        set.dark = set.theme == QuireTheme.auto ? ExternalDisplayModel.shared.colorScheme == .dark
            : QuireTheme.all.first { $0.id == set.theme }?.dark ?? false
        set.prompts = flag(PromptDeck.enabledKey)
        set.goalOn = flag(QuirePrefKey.goalOn)
        set.goal = d.object(forKey: QuirePrefKey.goal) as? Int ?? 750
        set.fontSize = d.object(forKey: QuirePrefKey.fontSize) as? Double ?? Double(Theme.defaultFontSize)
        set.typewriter = flag(QuirePrefKey.typewriter)
        set.focusParagraph = flag(QuirePrefKey.focusParagraph)
        set.autoTranscribe = flag(JournalStore.autoTranscribeKey)
        set.reminder = flag(ReminderScheduler.enabledKey)
        set.reminderHour = d.object(forKey: ReminderScheduler.hourKey) as? Int ?? ReminderScheduler.defaultHour
        set.reminderMinute = d.object(forKey: ReminderScheduler.minuteKey) as? Int ?? 0
        set.weekly = flag(ResurfacingScheduler.enabledKey)
        set.weeklyDay = d.object(forKey: ResurfacingScheduler.weekdayKey) as? Int ?? ResurfacingScheduler.defaultWeekday
        set.weeklyHour = d.object(forKey: ResurfacingScheduler.hourKey) as? Int ?? ResurfacingScheduler.defaultHour
        set.appLock = flag(AppLockManager.enabledKey)
        set.appLockGrace = d.object(forKey: AppLockManager.graceKey) as? Double ?? 0
        set.canLock = AppLockManager.canAuthenticate()
        set.spotlight = flag(SpotlightIndexer.enabledKey)
        set.dataSaver = flag(QuirePrefKey.dataSaver)
        set.splitTags = d.string(forKey: QuirePrefKey.splitTags) ?? ""
        set.backupInterval = d.string(forKey: JournalStore.backupIntervalKey) ?? BackupInterval.off.rawValue
        set.backupKeep = d.object(forKey: JournalStore.backupKeepKey) as? Int ?? 10
        set.mediaSort = d.string(forKey: QuirePrefKey.mediaSort) ?? AssetSort.newest.rawValue
        set.mediaGroup = d.string(forKey: QuirePrefKey.mediaGroup) ?? AssetGrouping.none.rawValue
        s.settings = set
        if set.prompts { s.prompt = QuirePrompts.prompt(offset: QuirePrompts.offset) }

        let monitor = ExternalDisplayModel.shared
        if monitor.isConnected {
            s.monitor = .init(paused: monitor.isPaused,
                              theme: d.string(forKey: ExternalTheme.key) ?? ExternalTheme.followPhone,
                              themes: ExternalTheme.all.map { .init(id: $0.id, name: $0.name, dark: $0.dark) },
                              textSize: d.string(forKey: ExternalTextSize.key) ?? ExternalTextSize.regular.rawValue,
                              hints: flag(ShortcutHints.key, true),
                              dim: flag(ExternalDisplayModel.autoDimKey),
                              dimLevel: d.object(forKey: ExternalDisplayModel.dimLevelKey) as? Double ?? ExternalDisplayModel.dimFloor)
        }
        s.monitorShows = DeskDatePicker.shared.isAvailable
        s.backupFolderSet = store.backupFolderName != nil
        s.backupRunning = store.backupRunning
        s.lastBackup = store.lastBackupAt.map { "Last " + $0.formatted(date: .abbreviated, time: .shortened) }
        s.composer = ComposerCommands.shared.state
        if extras.revision != store.revision { loadExtras(store: store) }
        s.media = extras.media
        s.backups = extras.backups
        s.templates = extras.templates
        s.tagGroups = extras.tagGroups
        s.recovery = recovery
        s.playing = MediaPlayback.shared.current
        if let target = CommandFocus.shared.current {
            var selected = item(target.ref.entry, draft: target.ref.source == .inbox)
            selected.isOpen = target.isPage
            // Played where the monitor shows the page; the phone's own players are under a finger.
            if target.isPage, s.monitorShows { selected.media = playable(target.ref.entry) }
            if case .journal(let name) = target.ref.source { selected.journal = name }
            s.selected = selected
        }
        return s
    }
}

// MARK: - The screen

/// The menu's own window: the panel over the dimmed page, unless the monitor has it. Tapping outside closes it.
private struct CommandMenuOverlay: View {
    @ObservedObject private var host = QuireCommandMenu.host
    @AppStorage(QuireTheme.storageKey) private var themeID = QuireTheme.auto
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let q = QuireTheme.resolve(themeID, scheme: scheme)
        ZStack(alignment: .top) {
            Color.black.opacity(host.onMonitor ? 0.001 : 0.18).ignoresSafeArea()
                .onTapGesture { host.close() }
                .accessibilityLabel("Close the menu")
                .accessibilityAddTraits(.isButton)
            if let menu = host.menu {
                if host.onMonitor {
                    VStack {
                        Spacer()
                        Text("The menu is on the monitor. Tap to close it.")
                            .font(q.ui(14)).foregroundStyle(q.mutedColor)
                            .padding(12).background(q.pageColor)
                            .overlay(Rectangle().strokeBorder(q.lineColor, lineWidth: 1))
                            .padding(16)
                    }
                    .allowsHitTesting(false)
                } else {
                    CommandMenuPanel(menu: menu, showsKeys: !host.byTouch, touch: host.byTouch)
                        .padding(.horizontal, 16).padding(.top, 24)
                }
            }
        }
        .environment(\.quire, q)
    }
}

/// The menu in Quire's design, the same on the phone and the monitor: `z` scales it.
struct CommandMenuPanel: View {
    @Environment(\.quire) private var q
    let menu: CommandPalette<QuireCommandList>
    var z: CGFloat = 1
    /// The monitor has its hint bar for this.
    var showsKeys = false
    /// Opened by touch: rows take taps, and there's a back and a close button.
    var touch = false

    private var rowHeight: CGFloat { 54 * z }
    private var host: CommandHost<QuireCommandList> { QuireCommandMenu.host }

    var body: some View {
        VStack(spacing: 0) {
            field
            Rectangle().fill(q.lineColor).frame(height: 1)
            if menu.rows.isEmpty {
                Text(menu.nothing).font(q.writing(17 * z, italic: true)).foregroundStyle(q.mutedColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18 * z).padding(.vertical, 16 * z)
            } else {
                list
            }
            if showsKeys {
                Rectangle().fill(q.lineColor).frame(height: 1)
                keys
            }
        }
        .frame(maxWidth: 600 * z)
        .background(q.pageColor)
        .overlay(Rectangle().strokeBorder(q.lineColor, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 18 * z, y: 6 * z)
    }

    private var field: some View {
        HStack(spacing: 10 * z) {
            if touch && menu.depth > 0 {
                Button { host.back() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17 * z, weight: .medium))
                        .foregroundStyle(q.accentColor).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("Back")
            } else {
                Image(systemName: menu.isAsking ? "character.cursor.ibeam" : "magnifyingglass")
                    .font(.system(size: 15 * z, weight: .light)).foregroundStyle(q.mutedColor)
            }
            if let opener = menu.opener {
                Text(opener.title).font(q.ui(15 * z, weight: .semibold)).foregroundStyle(q.accentColor)
                    .lineLimit(1).fixedSize()
            }
            HStack(spacing: 1 * z) {
                if !menu.query.isEmpty {
                    Text(menu.query).font(q.writing(20 * z)).foregroundStyle(q.inkColor).lineLimit(1).truncationMode(.head)
                }
                Caret(font: q.writing(20 * z), color: q.accentColor, width: max(2, 2 * z))
                if menu.query.isEmpty {
                    Text(menu.prompt).font(q.writing(20 * z, italic: true)).foregroundStyle(q.faintColor).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if touch {
                Button { host.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 15 * z, weight: .medium))
                        .foregroundStyle(q.mutedColor).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 18 * z).frame(minHeight: 52 * z)
        .accessibilityElement(children: .contain)
    }

    /// No cap on the rows: it scrolls, and the lit row stays in view.
    private var list: some View {
        let headings = menu.sections.filter { $0.title != nil }.count
        let shown = CGFloat(min(menu.rows.count, CommandPaletteLimit.rows)) * rowHeight + CGFloat(headings) * 30 * z
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(menu.sections) { section in
                        if let title = section.title {
                            Text(q.caps(title)).font(q.label(11 * z)).foregroundStyle(q.mutedColor).lineLimit(1)
                                .padding(.horizontal, 18 * z).padding(.bottom, 4 * z)
                                .frame(height: 30 * z, alignment: .bottomLeading)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.rows) { row in
                            CommandMenuRow(row: row, lit: row.id == menu.selected, z: z).frame(height: rowHeight).id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture { host.choose(row.id) }
                                .onHover { inside in if inside { host.highlight(row.id) } }
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
            }
            .frame(maxHeight: shown)
            .onAppear { if let id = menu.selected { proxy.scrollTo(id) } }
            .onChange(of: menu.selected) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private var keys: some View {
        HStack(spacing: 14 * z) {
            ForEach(menu.hints) { hint in
                HStack(spacing: 4 * z) {
                    Text(hint.key).font(q.mono(11 * z, weight: .medium)).foregroundStyle(q.accentColor)
                    Text(q.caps(hint.label)).font(q.label(11 * z)).foregroundStyle(q.mutedColor)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18 * z).padding(.vertical, 8 * z)
    }
}

private struct CommandMenuRow: View {
    @Environment(\.quire) private var q
    let row: CommandRow<QuireCommand>
    let lit: Bool
    let z: CGFloat

    /// Destructive rows are red, as Delete is on the entry's page.
    private var ink: Color { row.destructive ? .red : q.inkColor }

    var body: some View {
        HStack(spacing: 12 * z) {
            Image(systemName: row.symbol).font(.system(size: 16 * z, weight: .light))
                .foregroundStyle(row.destructive ? .red : lit ? q.accentColor : q.mutedColor).frame(width: 22 * z)
            VStack(alignment: .leading, spacing: 1 * z) {
                Text(row.title).font(q.writing(19 * z)).foregroundStyle(ink).lineLimit(1)
                if let detail = row.detail {
                    Text(detail).font(q.ui(12 * z)).foregroundStyle(q.mutedColor).lineLimit(1)
                }
            }
            Spacer(minLength: 8 * z)
            if let state = row.state {
                Text(state).font(q.ui(13 * z)).foregroundStyle(row.isOn == true ? q.accentColor : q.mutedColor)
            }
            if row.isCurrent {
                Image(systemName: "checkmark").font(.system(size: 14 * z, weight: .semibold)).foregroundStyle(q.accentColor)
                    .accessibilityLabel("Current")
            }
            if row.leads {
                Image(systemName: "chevron.right").font(.system(size: 12 * z)).foregroundStyle(q.mutedColor)
            }
        }
        .padding(.horizontal, 18 * z)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(lit ? q.accentSoftColor : Color.clear)
        .overlay(alignment: .leading) { if lit { Rectangle().fill(q.accentColor).frame(width: max(3, 3 * z)) } }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.state ?? "")
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

/// ⌘ in the masthead, the reader's bar and the composer: the way in without a keyboard.
struct CommandMenuButton: View {
    @Environment(\.quire) private var q
    var size: CGFloat = 18

    var body: some View {
        Button { QuireCommandMenu.host.present() } label: {
            Image(systemName: "command").font(.system(size: size, weight: .regular)).foregroundStyle(q.inkColor)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Commands")
        .accessibilityHint("Everything Quire can do, to search and choose")
    }
}

#endif
