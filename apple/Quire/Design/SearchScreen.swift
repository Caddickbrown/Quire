//
//  SearchScreen.swift
//  Quire
//
//  One query over the inbox, the journal and the split journals, with the shared
//  search grammar (tag:, before:, after:, has:, is:starred, "phrases"). Saved
//  searches are the start page. Results read like the journal: by day, one row
//  each, opening on the entry's page.
//

#if os(iOS)

import SwiftUI

struct SearchScreen: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.quire) private var q
    @Environment(\.dismiss) private var dismiss

    var onOpen: (EntryRef) -> Void

    @State private var query = ""
    @State private var results: [EntryRef] = []
    @State private var searched = false
    @State private var saved: [SavedSearch] = []
    @State private var naming = false
    @State private var pinName = ""
    @FocusState private var focused: Bool
    @State private var selected: Int?

    /// More than this is a reason to narrow the query, not to scroll.
    private let shown = 200

    private var shownResults: [EntryRef] { Array(results.prefix(shown)) }
    private var selectedID: String? {
        selected.flatMap { shownResults.indices.contains($0) ? shownResults[$0].id : nil }
    }

    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    QTitle(kicker: "Everything", title: "Search", size: 40)
                    field
                    if results.isEmpty { idle } else { list }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(q.pageColor.ignoresSafeArea())
        .onChange(of: selectedID) { _, id in
            if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
        .qKeyList(entries: shownResults.map(\.entry), index: $selected, listTitle: "Search", autoSelect: true,
                  onOpen: { entry in if let ref = shownResults.first(where: { $0.entry.id == entry.id }) { onOpen(ref) } })
        .onChange(of: query) { _, _ in selected = nil }
        .onAppear {
            focused = true
            if let pending = nav.pendingSearchQuery { query = pending; nav.pendingSearchQuery = nil }
        }
        .alert("Pin this search", isPresented: $naming) {
            TextField("Name", text: $pinName)
            Button("Pin") {
                let name = pinName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { store.addSavedSearch(name: name, query: query); saved = store.savedSearches() }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("It stays here, on the search page, until you remove it.") }
        .task(id: "\(query)#\(store.revision)") {
            saved = store.savedSearches()
            // A beat, so typing doesn't rescan on every keystroke.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await run()
        }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            QLink(title: "Close") { dismiss() }
            Spacer()
            if !SearchQuery.parse(query).isEmpty {
                QLink(title: "Pin", emphasised: true) {
                    pinName = query.count <= 30 ? query : String(query.prefix(30))
                    naming = true
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 8)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("", text: $query,
                          prompt: Text("title, text or @tag").font(q.writing(20, italic: true)).foregroundColor(q.faintColor))
                    .font(q.writing(20)).foregroundStyle(q.inkColor)
                    .focused($focused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search)
                    .frame(minHeight: 44)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Text("Clear").font(q.ui(13)).foregroundStyle(q.mutedColor)
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .bottom) { QRule() }
            Text("tag:work · before:2026-03 · after:2025 · has:image · is:starred · \"a phrase\"")
                .font(q.mono(11)).foregroundStyle(q.mutedColor).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var idle: some View {
        if searched {
            Text("Nothing matches that.").font(q.writing(18)).foregroundStyle(q.mutedColor)
        } else if !saved.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                QLabel("Saved searches")
                ForEach(saved) { search in
                    Button { query = search.query } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(search.name).font(q.writing(19)).foregroundStyle(q.inkColor)
                            Text(search.query).font(q.mono(12)).foregroundStyle(q.mutedColor).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            store.removeSavedSearch(named: search.name); saved = store.savedSearches()
                        }
                    }
                }
            }
        }
    }

    private struct Day: Identifiable { let id: String; var entries: [EntryRef] }

    private var days: [Day] {
        var out: [Day] = []
        for ref in results.prefix(shown) {
            if out.last?.id == ref.entry.date { out[out.count - 1].entries.append(ref) }
            else { out.append(Day(id: ref.entry.date, entries: [ref])) }
        }
        return out
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 16) {
            QLabel("Results", trailing: results.count > shown ? "\(shown) of \(results.count)" : "\(results.count)")
                .padding(.bottom, 4).overlay(alignment: .bottom) { QRule() }
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 10) {
                    Text(QDate.shortDay(day.id).uppercased() + " " + String(day.id.prefix(4))).tracking(1.4)
                        .font(q.label(11)).foregroundStyle(q.mutedColor)
                    ForEach(day.entries) { ref in
                        QEntryRow(entry: ref.entry, selected: ref.id == selectedID, onOpen: { onOpen(ref) })
                    }
                }
            }
            if results.count > shown {
                Text("Narrow the query to see the rest.").font(q.ui(13)).foregroundStyle(q.mutedColor)
            }
        }
    }

    // MARK: Searching

    /// The scan runs off the main thread: each entry is one call into the core.
    private func run() async {
        let text = query
        let inbox = store.inboxDrafts
        let days = store.archiveEntries
        let splits = store.splitEntriesCache
        let hits: [EntryRef] = await Task.detached(priority: .userInitiated) {
            let parsed = SearchQuery.parse(text)
            guard !parsed.isEmpty else { return [] }
            var out: [EntryRef] = []
            for e in inbox where parsed.matches(e) { out.append(EntryRef(entry: e, source: .inbox)) }
            for day in days {
                for e in day.entries where parsed.matches(e) { out.append(EntryRef(entry: e, source: .archive(date: day.date))) }
            }
            for (name, entries) in splits {
                for e in entries where parsed.matches(e) { out.append(EntryRef(entry: e, source: .journal(name: name))) }
            }
            return out.sorted { $0.entry.ts > $1.entry.ts }
        }.value
        guard !Task.isCancelled else { return }
        results = hits
        searched = !SearchQuery.parse(text).isEmpty
    }
}

#endif
