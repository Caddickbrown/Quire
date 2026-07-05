//
//  InboxView.swift
//  Jibber
//
//  The inbox: unfiled drafts. On macOS it's an email-style two-pane (list +
//  selected draft); on iOS the list pushes to the editor. Each draft can be
//  Filed, Edited, or Deleted. Search / sort / File All live in the toolbar.
//

import SwiftUI

enum InboxSort: String, CaseIterable, Identifiable {
    case newest, oldest, longest, shortest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest:   return "Newest first"
        case .oldest:   return "Oldest first"
        case .longest:  return "Longest first"
        case .shortest: return "Shortest first"
        }
    }
}

struct InboxView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    @AppStorage("inboxSort") private var sortRaw: String = InboxSort.newest.rawValue
    @State private var searchText = ""
    @State private var randomDraft: Entry?
    @State private var selectedTS: String?

    private var drafts: [Entry] {
        var d = store.inboxDrafts
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty { d = d.filter { $0.raw.lowercased().contains(q) } }
        switch InboxSort(rawValue: sortRaw) ?? .newest {
        case .newest:   d.sort { $0.ts > $1.ts }
        case .oldest:   d.sort { $0.ts < $1.ts }
        case .longest:  d.sort { $0.wordCount > $1.wordCount }
        case .shortest: d.sort { $0.wordCount < $1.wordCount }
        }
        return d
    }

    var body: some View {
        content
            .searchable(text: $searchText, prompt: "Search drafts")
            .navigationTitle("Inbox")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarItems }
            .sheet(item: $randomDraft) { draft in
                NavigationStack { EntryDetailView(entry: draft, source: .inbox) }
                    .environmentObject(store)
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.inboxDrafts.isEmpty {
            ContentUnavailableView(
                "Inbox is empty",
                systemImage: "tray",
                description: Text("Drafts you write appear here until you file them.")
            )
        } else {
            #if os(macOS)
            HSplitView {
                draftList
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
                Group {
                    if let ts = selectedTS, let draft = drafts.first(where: { $0.ts == ts }) {
                        EntryDetailView(entry: draft, source: .inbox).id(ts)
                    } else {
                        ContentUnavailableView("Select a draft", systemImage: "tray")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #else
            draftList
            #endif
        }
    }

    private var draftList: some View {
        List(selection: selectionBinding) {
            ForEach(drafts) { draft in
                row(for: draft)
                    .tag(draft.ts)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { store.fileDraft(draft) } label: { Label("File", systemImage: "archivebox") }
                            .tint(.green)
                        Button(role: .destructive) { store.deleteDraft(draft) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button { store.fileDraft(draft) } label: { Label("Archive", systemImage: "archivebox") }
                        Button(role: .destructive) { store.deleteDraft(draft) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        }
    }

    /// On macOS the list drives the side pane; on iOS rows push via NavigationLink.
    @ViewBuilder
    private func row(for draft: Entry) -> some View {
        #if os(macOS)
        DraftRow(draft: draft, dateStyleRaw: dateStyleRaw)
        #else
        NavigationLink(value: Route.entry(draft, .inbox)) {
            DraftRow(draft: draft, dateStyleRaw: dateStyleRaw)
        }
        #endif
    }

    private var selectionBinding: Binding<String?> {
        #if os(macOS)
        return $selectedTS
        #else
        return .constant(nil)
        #endif
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(InboxSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            Button {
                randomDraft = store.inboxDrafts.randomElement()
            } label: {
                Label("Random", systemImage: "dice")
            }
            .disabled(store.inboxDrafts.isEmpty)
            Menu {
                Button { store.fileAllDrafts() } label: { Label("File All", systemImage: "archivebox") }
                    .disabled(store.inboxDrafts.isEmpty)
                Button { store.sortInbox() } label: { Label("Sort file by date", systemImage: "calendar") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

private struct DraftRow: View {
    let draft: Entry
    let dateStyleRaw: String

    private var time: String { String(draft.ts.suffix(8).prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(draft.preview.isEmpty ? "(empty)" : draft.preview)
                .lineLimit(1)
                .font(.body)
            HStack(spacing: 8) {
                Text(Theme.displayDate(draft.date, style: dateStyleRaw))
                Text("·")
                Text(time)
                Text("·")
                Text("\(draft.wordCount) words")
                if !draft.tags.isEmpty {
                    Text("·")
                    Text(draft.tags.joined(separator: " ")).foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
