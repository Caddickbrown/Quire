//
//  RootView.swift
//  Jibber
//
//  Top-level shell. A sidebar of sections (Write / Inbox / Archive) with a
//  detail pane on macOS & iPad; on iPhone the same NavigationSplitView collapses
//  to push navigation automatically.
//

import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case write = "Write"
    case inbox = "Inbox"
    case archive = "Archive"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .write:   return "square.and.pencil"
        case .inbox:   return "tray"
        case .archive: return "archivebox"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("colorScheme") private var colorSchemeRaw: String = AppColorScheme.auto.rawValue
    @State private var selection: AppSection? = .write
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
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
            .navigationTitle("Jibber")
            .toolbar { themeToolbar }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            #endif
        } detail: {
            NavigationStack {
                switch selection ?? .write {
                case .write:   WritingView()
                case .inbox:   InboxView()
                case .archive: ArchiveView()
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(store)
        }
    }

    @ToolbarContentBuilder
    private var themeToolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Appearance", selection: $colorSchemeRaw) {
                    ForEach(AppColorScheme.allCases) { scheme in
                        Label(scheme.displayName, systemImage: scheme.systemImage)
                            .tag(scheme.rawValue)
                    }
                }
            } label: {
                Image(systemName: AppColorScheme(rawValue: colorSchemeRaw)?.systemImage
                      ?? "circle.lefthalf.filled")
            }
        }
        ToolbarItem {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
        }
    }
}
