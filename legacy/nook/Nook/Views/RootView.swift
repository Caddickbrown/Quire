//
//  RootView.swift
//  Nook
//
//  Top-level shell. A sidebar of sections (Write / Inbox / Archive / Starred /
//  Stream / Tags) with
//  Settings pinned to the bottom, and a detail pane on macOS & iPad; on iPhone
//  the same NavigationSplitView collapses to push navigation automatically.
//

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// A pushable detail destination, so navigation is programmatic (enables the
/// mouse Back button and ⌘[ to pop the stack).
enum Route: Hashable {
    case entry(Entry, EntrySource)
    case day(String)
    case tag(String)
    case journalFile(String)
}

struct RouteDestination: View {
    let route: Route
    var body: some View {
        switch route {
        case .entry(let e, let s): EntryDetailView(entry: e, source: s)
        case .day(let d):          DayView(date: d)
        case .tag(let t):          TagDetailView(tag: t)
        case .journalFile(let n):  JournalFileView(name: n)
        }
    }
}

extension View {
    /// Register the shared pushable destinations on a NavigationStack.
    func nookRoutes() -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case write = "Write"
    case inbox = "Inbox"
    case archive = "Journal"
    case starred = "Starred"
    case stream = "Stream"
    case splitJournals = "Split Journals"
    case tags = "Tags"
    case assets = "Assets"
    case search = "Search"
    case stats = "Stats"
    case settings = "Settings"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .write:         return "square.and.pencil"
        case .inbox:         return "tray"
        case .archive:       return "book.closed"
        case .starred:       return "star"
        case .stream:        return "scroll"
        case .splitJournals: return "bookmark"
        case .tags:          return "number"
        case .assets:        return "photo.on.rectangle"
        case .search:        return "magnifyingglass"
        case .stats:         return "chart.bar"
        case .settings:      return "gearshape"
        }
    }

    /// The journal sections shown in the main sidebar list (Settings sits apart).
    static let primary: [AppSection] = [.write, .inbox, .archive, .starred, .stream, .splitJournals, .tags, .assets, .search]
}

/// The writing timer's length, in one place: the sidebar reads it through
/// `@AppStorage` (which supplies the default itself) and the `nook://timer`
/// deep link reads the raw defaults, where an untouched key would otherwise
/// come back as 0 and start a one-minute session.
enum WritingTimer {
    static let minutesKey = "timerMinutes"
    static let defaultMinutes = 15
}

/// Shared navigation state so keyboard-shortcut commands (defined at the App
/// scene level) can drive the sidebar selection and trigger a new entry.
@MainActor final class NavigationModel: ObservableObject {
    // iPhone collapses the split view, so a non-nil section would push straight
    // into that page on launch; start with no selection so the menu shows first.
    // Switching section always drops back to that section's root. The reset
    // lives here rather than in a view `onChange` so that a programmatic
    // `open` can set the section and push in one synchronous step — an
    // `onChange` reset could otherwise land after the push and wipe it.
    #if os(iOS)
    @Published var section: AppSection? = nil { didSet { resetPathOnSectionChange(oldValue) } }
    #else
    @Published var section: AppSection? = .write { didSet { resetPathOnSectionChange(oldValue) } }
    #endif

    private func resetPathOnSectionChange(_ oldValue: AppSection?) {
        if section != oldValue { path = NavigationPath() }
    }
    @Published var path = NavigationPath()
    @Published var newEntrySignal = 0
    @Published var focusMode = false
    /// A query for SearchView to adopt on its next appearance — how the
    /// sidebar's saved-search pins (and deep links) open a pre-filled search.
    @Published var pendingSearchQuery: String?
    @Published var timerRemaining = WritingTimer.defaultMinutes * 60
    @Published var timerRunning = false
    var backMonitorInstalled = false
    func requestNewEntry() { section = .write; path = NavigationPath(); newEntrySignal += 1 }
    /// Pop one level (mouse Back button / ⌘[).
    func goBack() { if !path.isEmpty { path.removeLast() } }

    /// Programmatically open an entry: switch section, then push it. Both
    /// steps are synchronous, so the entry is always what ends up on screen.
    func open(_ entry: Entry, source: EntrySource) {
        switch source {
        case .inbox:   section = .inbox
        case .archive: section = .archive
        case .journal: section = .splitJournals
        }
        // Explicit, because `section` may already be the right one, in which
        // case its `didSet` doesn't fire and a stack could still be pushed.
        path = NavigationPath()
        path.append(Route.entry(entry, source))
    }

    func openDay(_ date: String) {
        section = .archive
        path = NavigationPath()
        path.append(Route.day(date))
    }

    /// Open the Search section pre-filled with a query.
    func openSearch(query: String) {
        pendingSearchQuery = query
        section = .search
    }
}

struct RootView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @ObservedObject private var appLock = AppLockManager.shared
    @Environment(\.accent) private var accent
    @State private var savedSearches: [SavedSearch] = []
    @AppStorage("welcomeShown") private var welcomeShown = false
    @State private var showingWelcome = false
    /// The banner's "Locate Folder…" picker (Settings has the same one).
    @State private var showingFolderPicker = false
    // Resolved appearance (after the app's own preferredColorScheme, so Auto
    // reads as the system's choice) — mirrored to the external display.
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    // Sidebar calendar is collapsible on iOS: in landscape it can otherwise swamp
    // the whole sidebar. Toggled from the footer; the choice is remembered.
    @AppStorage("sidebarCalendarExpanded") private var calendarExpanded = true
    #endif

    /// Sidebar rows. On iPhone, Write is a top-right compose button instead of a
    /// browsable row, so it's dropped from the list there.
    private var sidebarSections: [AppSection] {
        #if os(iOS)
        AppSection.primary.filter { $0 != .write }
        #else
        AppSection.primary
        #endif
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { nav.focusMode ? .detailOnly : .all },
            set: { nav.focusMode = ($0 == .detailOnly) }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            List(selection: $nav.section) {
                ForEach(sidebarSections) { section in
                    NavigationLink(value: section) {
                        Label {
                            HStack {
                                Text(section.rawValue)
                                if section == .inbox, !store.inboxDrafts.isEmpty {
                                    Spacer()
                                    Text("\(store.inboxDrafts.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: section.systemImage)
                        }
                    }
                }
                // Pinned queries from the Search screen — smart folders.
                if !savedSearches.isEmpty {
                    Section("Saved Searches") {
                        ForEach(savedSearches) { saved in
                            Button {
                                nav.openSearch(query: saved.query)
                            } label: {
                                Label(saved.name, systemImage: "magnifyingglass.circle")
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.removeSavedSearch(named: saved.name)
                                } label: {
                                    Label("Remove Pin", systemImage: "pin.slash")
                                }
                                .destructiveAction()
                            }
                        }
                    }
                }
            }
            .task(id: store.revision) { savedSearches = store.savedSearches() }
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            #if os(iOS)
            // No wordmark in the sidebar bar — the sections speak for themselves
            // and the title only crowded them. macOS still names the window.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // On iPhone, Write lives as a compose button top-right rather than a
            // sidebar row — it's the one-tap action, not a place you browse to.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { nav.section = .write } label: {
                        Image(systemName: AppSection.write.systemImage)
                    }
                    .help("Write")
                    .accessibilityLabel("New entry")
                }
            }
            #else
            .navigationTitle("nook")
            #endif
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            #endif
        } detail: {
            NavigationStack(path: $nav.path) {
                detailRoot
                    .nookRoutes()
            }
            // Rendered @tags anywhere in the detail pane push their tag page.
            .environment(\.nookOpenTag) { nav.path.append(Route.tag($0)) }
        }
        // Hand the store to the external-display scene, which is built by a
        // UIKit scene delegate and so can't reach this environment itself.
        // The colour scheme goes the same way: an external scene has its own
        // trait collection and won't follow the device's appearance on its own.
        .onAppear {
            ExternalDisplayModel.shared.store = store
            ExternalDisplayModel.shared.colorScheme = colorScheme
            AppLockVeilWindow.shared.setVisible(appLock.showsVeil)
            registerRootKeys()
        }
        .onChange(of: colorScheme) { _, new in
            ExternalDisplayModel.shared.colorScheme = new
        }
        .onReceive(ticker) { _ in
            guard nav.timerRunning else { return }
            if nav.timerRemaining > 0 {
                nav.timerRemaining -= 1
                if nav.timerRemaining == 0 {
                    nav.timerRunning = false
                    timerFinished()
                }
            } else {
                nav.timerRunning = false
            }
        }
        // In focus mode the sidebar (and its timer) is hidden — a running
        // countdown keeps a quiet pill in the corner so the session doesn't
        // end invisibly.
        .overlay(alignment: .bottomTrailing) {
            if nav.focusMode && nav.timerRunning {
                Text(String(format: "%d:%02d", nav.timerRemaining / 60, nav.timerRemaining % 60))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .padding(14)
                    .accessibilityLabel("Writing timer, \(nav.timerRemaining / 60) minutes left")
            }
        }
        // Above everything, and it stays: while the chosen folder is missing
        // nothing the user writes is being saved anywhere.
        .safeAreaInset(edge: .top, spacing: 0) { storageBanner }
        // Transient, at the bottom: a write that didn't reach disk.
        .overlay(alignment: .bottom) { writeErrorToast }
        .animation(.easeInOut(duration: 0.2), value: store.lastWriteError)
        #if os(iOS)
        // The Lock Screen / Dynamic Island countdown lives and dies with the
        // sidebar timer.
        .onChange(of: nav.timerRunning) { _, running in
            if running {
                TimerActivityController.start(
                    remaining: nav.timerRemaining,
                    wordsToday: store.stats().wordsToday,
                    wordGoal: wordGoalEnabled ? max(wordGoal, 1) : 0)
            } else {
                TimerActivityController.end()
            }
        }
        #endif
        // The veil goes in a window of its own (see AppLockVeilWindow) rather
        // than only an overlay, so a presented sheet can't stay readable on
        // top of the lock.
        .onChange(of: appLock.showsVeil) { _, show in
            AppLockVeilWindow.shared.setVisible(show)
        }
        #if os(macOS)
        // Kept as the base cover on macOS: it is up from the first frame,
        // before there is a window to hang the veil window off.
        .overlay {
            if appLock.showsVeil { AppLockVeil() }
        }
        #endif
        // First run only: one welcome screen, then never again.
        .sheet(isPresented: $showingWelcome, onDismiss: { welcomeShown = true }) {
            WelcomeView()
                .environmentObject(store)
                .environmentObject(nav)
        }
        .onAppear { if !welcomeShown { showingWelcome = true } }
        #if os(macOS)
        .onAppear(perform: installBackButtonMonitor)
        #endif
    }

    /// The journal folder the app was pointed at can't be reached — an
    /// unmounted volume, a folder that moved or went away. Nook blocks writes
    /// rather than quietly starting a second journal in iCloud, so say so and
    /// offer both ways out.
    @ViewBuilder
    private var storageBanner: some View {
        if let message = store.storageUnavailableMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 10) {
                    Button("Locate Folder…") { showingFolderPicker = true }
                    Button("Use Default") { store.useDefaultFolder() }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .fileImporter(isPresented: $showingFolderPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.setCustomFolder(url)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// A read or write that didn't happen. Tap to dismiss, and it clears itself
    /// after a few seconds — the point is that an edit which never reached disk
    /// is never mistaken for a saved one.
    @ViewBuilder
    private var writeErrorToast: some View {
        if let message = store.lastWriteError {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(radius: 8, y: 2)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { store.lastWriteError = nil }
                .task(id: message) {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard !Task.isCancelled else { return }
                    store.lastWriteError = nil
                }
        }
    }

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The session ended — say so. The timer used to just stop, which in a
    /// hidden sidebar (or mid-flow) meant nobody noticed.
    private func timerFinished() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #else
        NSSound(named: "Glass")?.play()
        #endif
    }

    /// Bottom of the key-command stack: what ↑/↓ do when no list is on screen.
    /// The external display's idle screen offers "↑↓ Browse", and from the
    /// section menu there is nothing to browse yet — so the first press opens
    /// the Journal, whose list then registers over this and takes the next one.
    private func registerRootKeys() {
        let intoJournal = { if nav.section == nil { nav.section = .archive } }
        KeyCommandRouter.shared.register(Self.rootKeyID, NookKeyHandlers(
            moveUp:   intoJournal,
            moveDown: intoJournal,
            open:     {},
            clear:    { nav.section = nil }
        ))
    }

    private static let rootKeyID = UUID()

    @ViewBuilder
    private var detailRoot: some View {
        switch nav.section ?? .write {
        case .write:         WritingView()
        case .inbox:         InboxView()
        case .archive:       ArchiveView()
        case .starred:       StarredView()
        case .stream:        StreamView()
        case .splitJournals: SplitJournalsView()
        case .tags:          TagsView()
        case .assets:        AssetsView()
        case .search:        SearchView()
        case .stats:         StatsView()
        case .settings:      SettingsView()
        }
    }

    #if os(macOS)
    /// Route the mouse "Back"/"Forward" side buttons to stack navigation.
    private func installBackButtonMonitor() {
        guard !nav.backMonitorInstalled else { return }
        nav.backMonitorInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            switch event.buttonNumber {
            case 3: nav.goBack(); return nil   // Back
            default: return event
            }
        }
    }
    #endif

    /// Sidebar footer: mini calendar + timer/Stats/Settings row.
    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            if showsMiniCalendar {
                MiniCalendarView()
                Divider()
            }
            HStack(spacing: footerSpacing) {
                #if os(iOS)
                calendarToggle
                #endif
                Spacer()
                if wordGoalEnabled { wordGoalControl }
                timerControl
                iconButton(.stats)
                iconButton(.settings)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    @AppStorage(WritingTimer.minutesKey) private var timerMinutes: Int = WritingTimer.defaultMinutes
    @AppStorage("wordGoalEnabled") private var wordGoalEnabled = false
    @AppStorage("wordGoal") private var wordGoal = 750

    /// Today's progress toward the daily word goal — a quiet ring next to the
    /// timer, filled from the same cached stats pass the widget uses. Tapping
    /// it opens Stats. Hidden entirely when the goal is off.
    private var wordGoalControl: some View {
        let goal = max(wordGoal, 1)
        let words = store.stats().wordsToday
        let progress = min(Double(words) / Double(goal), 1)
        return Button {
            nav.section = .stats
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(progress >= 1 ? Color.green : accent,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if progress >= 1 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 18, height: 18)
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(words) of \(goal) words today")
        .accessibilityLabel("Word goal")
        .accessibilityValue("\(words) of \(goal) words today")
    }

    private var timerControl: some View {
        Menu {
            Button(nav.timerRunning ? "Pause" : "Start") { nav.timerRunning.toggle() }
            Button("Reset") { nav.timerRunning = false; nav.timerRemaining = timerMinutes * 60 }
            Divider()
            Picker("Duration", selection: $timerMinutes) {
                ForEach([5, 10, 15, 20, 25, 30], id: \.self) { Text("\($0) min").tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            if nav.timerRunning {
                Text(String(format: "%d:%02d", nav.timerRemaining / 60, nav.timerRemaining % 60))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(nav.timerRemaining == 0 ? Color.red : accent)
            } else {
                Image(systemName: "timer")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onChange(of: timerMinutes) { _, m in if !nav.timerRunning { nav.timerRemaining = m * 60 } }
        .help("Writing timer")
        .accessibilityLabel("Writing timer")
        .accessibilityValue(nav.timerRunning
                            ? String(format: "%d minutes %d seconds left", nav.timerRemaining / 60, nav.timerRemaining % 60)
                            : "not running")
    }

    private var showsMiniCalendar: Bool {
        #if os(iOS)
        return calendarExpanded
        #else
        return true
        #endif
    }

    #if os(iOS)
    /// Footer toggle to show/hide the (tall) sidebar calendar. Always reachable at
    /// the bottom even when the calendar is expanded, so it's never stuck open.
    private var calendarToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { calendarExpanded.toggle() }
        } label: {
            Image(systemName: calendarExpanded ? "calendar.badge.minus" : "calendar")
                .font(.title3)
                .foregroundStyle(calendarExpanded ? accent : Color.secondary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(calendarExpanded ? "Hide calendar" : "Show calendar")
        .accessibilityLabel(calendarExpanded ? "Hide calendar" : "Show calendar")
    }
    #endif

    private var footerSpacing: CGFloat {
        #if os(iOS)
        return 16
        #else
        return 4
        #endif
    }

    private func iconButton(_ section: AppSection) -> some View {
        Button {
            nav.section = section
        } label: {
            Image(systemName: section.systemImage)
                .font(.title3)
                .foregroundStyle(nav.section == section ? accent : Color.secondary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.rawValue)
        .accessibilityLabel(section.rawValue)
    }
}

/// Full-screen veil shown while the app lock is engaged — and while the app is
/// merely on its way out of the foreground, so entry text never reaches the
/// app-switcher snapshot. Auto-attempts Face ID / Touch ID once actually
/// locked; the button retries after a cancel. Covered-but-unlocked shows the
/// cover alone: there is nothing to authenticate for yet.
struct AppLockVeil: View {
    @ObservedObject private var appLock = AppLockManager.shared

    var body: some View {
        ZStack {
            Rectangle().fill(.thickMaterial).ignoresSafeArea()
            if appLock.isLocked {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Nook is locked")
                        .font(.headline)
                    Button("Unlock") { appLock.unlock() }
                        .buttonStyle(.borderedProminent)
                        .disabled(appLock.unlocking)
                }
            }
        }
        .onAppear { appLock.unlock() }
        // The veil is often already up (covering the switcher snapshot) when
        // the lock itself engages, so appearing isn't the only cue to prompt.
        .onChange(of: appLock.isLocked) { _, locked in
            if locked { appLock.unlock() }
        }
    }
}

/// Presents `AppLockVeil` in a window of its own, above everything.
///
/// It used to be only a `.overlay` on the root view, which put it *under*
/// anything presented as a sheet — Settings, a Year in Review card, an import
/// preview — so locking the app left that sheet's contents legible. A window
/// of its own sits over sheets on both platforms.
@MainActor
final class AppLockVeilWindow {
    static let shared = AppLockVeilWindow()

    func setVisible(_ visible: Bool) {
        if visible { show() } else { hide() }
    }

    #if os(iOS)
    private var windows: [UIWindow] = []

    /// One veil per application scene. On iPad a second Nook window (Split
    /// View, Stage Manager) is a scene of its own, and a veil on whichever
    /// scene `connectedScenes` yielded first left the other fully readable.
    /// Every RootView's `onAppear` calls back in, so a window opened while
    /// locked is covered too.
    private func show() {
        windows.removeAll { $0.windowScene == nil }
        let covered = Set(windows.compactMap { $0.windowScene.map(ObjectIdentifier.init) })
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication && !covered.contains(ObjectIdentifier($0)) }
        guard !scenes.isEmpty else { return }
        for scene in scenes {
            let host = UIHostingController(rootView: AppLockVeil())
            // Opaque under the veil's material: in a window of its own the
            // material has no backdrop of the app's to thicken.
            host.view.backgroundColor = .systemBackground
            let veil = UIWindow(windowScene: scene)
            veil.rootViewController = host
            veil.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            veil.isHidden = false
            windows.append(veil)
        }
        // Put the keyboard away with the text it belongs to.
        _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
    }

    private func hide() {
        windows.forEach { $0.isHidden = true }
        windows.removeAll()
    }
    #endif

    #if os(macOS)
    /// Borderless windows refuse key status, which would leave the veil's own
    /// Unlock button unreachable on top of everything else.
    private final class VeilWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private var veils: [NSWindow] = []
    private var resizeObservers: [NSObjectProtocol] = []

    /// One veil per journal window (⌘N opens more than one), each a child of
    /// its host so it covers a sheet that is already up. Called again from
    /// every RootView's `onAppear`, so a window opened while locked is covered.
    private func show() {
        let veiled = Set(veils.compactMap { $0.parent.map(ObjectIdentifier.init) })
        let hosts = NSApp.windows.filter {
            $0.isVisible && $0.canBecomeMain && !veiled.contains(ObjectIdentifier($0))
        }
        for host in hosts {
            let veil = VeilWindow(contentRect: host.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            veil.contentView = NSHostingView(rootView: AppLockVeil())
            veil.backgroundColor = .windowBackgroundColor
            veil.isReleasedWhenClosed = false
            host.addChildWindow(veil, ordered: .above)
            veil.setFrame(host.frame, display: true)
            // Only the key window's veil takes key status; the rest just cover.
            if host.isKeyWindow || veils.isEmpty { veil.makeKeyAndOrderFront(nil) }
            else { veil.orderFront(nil) }
            veils.append(veil)
            // A child window follows a move on its own, but not a resize.
            resizeObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: host, queue: .main) { _ in
                    Task { @MainActor in AppLockVeilWindow.shared.followHosts() }
                })
        }
    }

    private func hide() {
        resizeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        resizeObservers.removeAll()
        for veil in veils {
            veil.parent?.removeChildWindow(veil)
            veil.orderOut(nil)
        }
        veils.removeAll()
        // A veil was key; hand focus back rather than leaving the app with
        // no key window at all.
        Self.hostWindow?.makeKeyAndOrderFront(nil)
    }

    private func followHosts() {
        for veil in veils {
            if let host = veil.parent { veil.setFrame(host.frame, display: true) }
        }
    }

    private static var hostWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.isKeyWindow }
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }
    #endif
}
