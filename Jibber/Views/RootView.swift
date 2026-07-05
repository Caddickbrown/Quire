//
//  RootView.swift
//  Jibber
//
//  Top-level shell. A sidebar of sections (Write / Inbox / Archive / Tags) with
//  Settings pinned to the bottom, and a detail pane on macOS & iPad; on iPhone
//  the same NavigationSplitView collapses to push navigation automatically.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
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
    func jibberRoutes() -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case write = "Write"
    case inbox = "Inbox"
    case archive = "Journal"
    case calendar = "Calendar"
    case splitJournals = "Split Journals"
    case tags = "Tags"
    case assets = "Assets"
    case stats = "Stats"
    case settings = "Settings"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .write:         return "square.and.pencil"
        case .inbox:         return "tray"
        case .archive:       return "book.closed"
        case .calendar:      return "calendar"
        case .splitJournals: return "bookmark"
        case .tags:          return "number"
        case .assets:        return "photo.on.rectangle"
        case .stats:         return "chart.bar"
        case .settings:      return "gearshape"
        }
    }

    /// The journal sections shown in the main sidebar list (Settings sits apart).
    static let primary: [AppSection] = [.write, .inbox, .archive, .calendar, .splitJournals, .tags, .assets]
}

/// Shared navigation state so keyboard-shortcut commands (defined at the App
/// scene level) can drive the sidebar selection and trigger a new entry.
@MainActor final class NavigationModel: ObservableObject {
    @Published var section: AppSection? = .write
    @Published var path = NavigationPath()
    @Published var newEntrySignal = 0
    @Published var focusMode = false
    @Published var timerRemaining = 15 * 60
    @Published var timerRunning = false
    var backMonitorInstalled = false
    func requestNewEntry() { section = .write; path = NavigationPath(); newEntrySignal += 1 }
    /// Pop one level (mouse Back button / ⌘[).
    func goBack() { if !path.isEmpty { path.removeLast() } }

    /// Programmatically open an entry: switch section, then push it (after the
    /// section-change path reset has run).
    func open(_ entry: Entry, source: EntrySource) {
        switch source {
        case .inbox:   section = .inbox
        case .archive: section = .archive
        case .journal: section = .splitJournals
        }
        Task { @MainActor in path.append(Route.entry(entry, source)) }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { nav.focusMode ? .detailOnly : .all },
            set: { nav.focusMode = ($0 == .detailOnly) }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            List(AppSection.primary, selection: $nav.section) { section in
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
            .navigationTitle("jibber")
            .overlay(alignment: .bottomTrailing) { bottomBar }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            #endif
        } detail: {
            NavigationStack(path: $nav.path) {
                detailRoot
                    .jibberRoutes()
            }
        }
        .onChange(of: nav.section) { _, _ in nav.path = NavigationPath() }
        .onReceive(ticker) { _ in
            guard nav.timerRunning else { return }
            if nav.timerRemaining > 0 { nav.timerRemaining -= 1 } else { nav.timerRunning = false }
        }
        #if os(macOS)
        .onAppear(perform: installBackButtonMonitor)
        #endif
    }

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @ViewBuilder
    private var detailRoot: some View {
        switch nav.section ?? .write {
        case .write:         WritingView()
        case .inbox:         InboxView()
        case .archive:       ArchiveView()
        case .calendar:      CalendarView()
        case .splitJournals: SplitJournalsView()
        case .tags:          TagsView()
        case .assets:        AssetsView()
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

    /// Floating timer + Stats + Settings icons, bottom-right of the sidebar.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            timerControl
            iconButton(.stats)
            iconButton(.settings)
        }
        .padding(.trailing, 8)
        .padding(.bottom, 10)
    }

    @AppStorage("timerMinutes") private var timerMinutes: Int = 15

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
                    .foregroundStyle(nav.timerRemaining == 0 ? Color.red : Color.accentColor)
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
    }

    private func iconButton(_ section: AppSection) -> some View {
        Button {
            nav.section = section
        } label: {
            Image(systemName: section.systemImage)
                .font(.title3)
                .foregroundStyle(nav.section == section ? Color.accentColor : Color.secondary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.rawValue)
    }
}
