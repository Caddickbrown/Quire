//
//  InboxView.swift
//  Nook
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

enum SwipeAction: String, CaseIterable, Identifiable {
    case file, delete, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .file:   return "File"
        case .delete: return "Delete"
        case .none:   return "None"
        }
    }
}

struct InboxView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    @AppStorage("inboxSort") private var sortRaw: String = InboxSort.newest.rawValue
    @AppStorage("inboxSwipeLeft") private var swipeLeftRaw = SwipeAction.file.rawValue
    @AppStorage("inboxSwipeRight") private var swipeRightRaw = SwipeAction.delete.rawValue
    @State private var searchText = ""
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
    }

    private func selectRandom() {
        guard let draft = store.inboxDrafts.randomElement() else { return }
        #if os(macOS)
        selectedTS = draft.ts
        #else
        nav.path.append(Route.entry(draft, .inbox))
        #endif
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
            HStack(spacing: 0) {
                draftList
                    .frame(width: 320)
                Divider()
                Group {
                    // Look the draft up in the full inbox (not the search-filtered
                    // list) so editing out the search term doesn't kick you out.
                    if let ts = selectedTS, let draft = store.inboxDrafts.first(where: { $0.ts == ts }) {
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

    /// Drafts grouped into date sections (order follows the current sort).
    private var draftSections: [(date: String, entries: [Entry])] {
        var order: [String] = [], map: [String: [Entry]] = [:]
        for d in drafts {
            if map[d.date] == nil { order.append(d.date) }
            map[d.date, default: []].append(d)
        }
        switch InboxSort(rawValue: sortRaw) ?? .newest {
        case .longest, .shortest: order.sort { $0 > $1 }   // dates newest-first
        default: break                                     // already in ts order
        }
        return order.map { (date: $0, entries: map[$0] ?? []) }
    }

    private var draftList: some View {
        List(selection: selectionBinding) {
            ForEach(draftSections, id: \.date) { section in
                Section(Theme.displayDate(section.date, style: dateStyleRaw)) {
                    ForEach(section.entries) { draft in
                        row(for: draft)
                            .tag(draft.ts)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                swipeButton(SwipeAction(rawValue: swipeRightRaw) ?? .delete, draft)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                swipeButton(SwipeAction(rawValue: swipeLeftRaw) ?? .file, draft)
                            }
                            .contextMenu {
                                Button { store.fileDraft(draft) } label: { Label("Archive", systemImage: "archivebox") }
                                Button(role: .destructive) { store.deleteDraft(draft) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func swipeButton(_ action: SwipeAction, _ draft: Entry) -> some View {
        switch action {
        case .file:
            Button { store.fileDraft(draft) } label: { Label("File", systemImage: "archivebox") }
                .tint(.green)
        case .delete:
            Button(role: .destructive) { store.deleteDraft(draft) } label: { Label("Delete", systemImage: "trash") }
        case .none:
            EmptyView()
        }
    }

    /// On macOS the list drives the side pane; on iOS rows push via NavigationLink.
    @ViewBuilder
    private func row(for draft: Entry) -> some View {
        #if os(macOS)
        DraftRow(draft: draft)
        #else
        NavigationLink(value: Route.entry(draft, .inbox)) {
            DraftRow(draft: draft)
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
            Button {
                selectRandom()
            } label: {
                Label("Random", systemImage: "dice")
            }
            .disabled(store.inboxDrafts.isEmpty)
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(InboxSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Button { store.fileAllDrafts() } label: { Label("File All", systemImage: "archivebox") }
                    .disabled(store.inboxDrafts.isEmpty)
                Button { store.sortInbox() } label: { Label("Sort file by date", systemImage: "calendar") }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
        }
    }
}

private struct DraftRow: View {
    let draft: Entry

    private var time: String { String(draft.ts.suffix(8).prefix(5)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(draft.preview.isEmpty ? "(empty)" : draft.preview)
                .lineLimit(1)
                .font(.body)
            HStack(spacing: 8) {
                Text(time)
                Text("·")
                Text("\(draft.wordCount) words")
                ForEach(draft.mediaBadges, id: \.self) { symbol in
                    Image(systemName: symbol)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !draft.tags.isEmpty {
                Text(draft.tags.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
