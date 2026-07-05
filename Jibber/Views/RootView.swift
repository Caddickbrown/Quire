//
//  RootView.swift
//  Jibber
//
//  Top-level shell. A sidebar of sections (Write / Inbox / Archive / Tags) with
//  Settings pinned to the bottom, and a detail pane on macOS & iPad; on iPhone
//  the same NavigationSplitView collapses to push navigation automatically.
//

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case write = "Write"
    case inbox = "Inbox"
    case archive = "Journal"
    case splitJournals = "Split Journals"
    case tags = "Tags"
    case stats = "Stats"
    case settings = "Settings"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .write:         return "square.and.pencil"
        case .inbox:         return "tray"
        case .archive:       return "book.closed"
        case .splitJournals: return "bookmark"
        case .tags:          return "number"
        case .stats:         return "chart.bar"
        case .settings:      return "gearshape"
        }
    }

    /// The journal sections shown in the main sidebar list (Settings sits apart).
    static let primary: [AppSection] = [.write, .inbox, .archive, .splitJournals, .tags]
}

/// Shared navigation state so keyboard-shortcut commands (defined at the App
/// scene level) can drive the sidebar selection and trigger a new entry.
@MainActor final class NavigationModel: ObservableObject {
    @Published var section: AppSection? = .write
    @Published var newEntrySignal = 0
    func requestNewEntry() { section = .write; newEntrySignal += 1 }
}

struct RootView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel

    var body: some View {
        NavigationSplitView {
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
            NavigationStack {
                switch nav.section ?? .write {
                case .write:         WritingView()
                case .inbox:         InboxView()
                case .archive:       ArchiveView()
                case .splitJournals: SplitJournalsView()
                case .tags:          TagsView()
                case .stats:         StatsView()
                case .settings:      SettingsView()
                }
            }
        }
    }

    /// Floating Stats + Settings icons, bottom-left of the sidebar.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            iconButton(.stats)
            iconButton(.settings)
        }
        .padding(.trailing, 8)
        .padding(.bottom, 10)
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
