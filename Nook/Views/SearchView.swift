//
//  SearchView.swift
//  Nook
//
//  Global search (⌘⇧F): one query over the whole corpus — inbox, archive, and
//  split journals — with the SearchQuery operator grammar (tag:, before:,
//  after:, has:, is:starred, "phrases"). Results reuse the shared entry list,
//  so a hit opens and edits in place like anywhere else.
//

import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @State private var queryText = ""
    @State private var results: [(entry: Entry, source: EntrySource)] = []
    @State private var searched = false
    @State private var savedSearches: [SavedSearch] = []
    @State private var namingPin = false
    @State private var pinName = ""

    var body: some View {
        Group {
            if results.isEmpty {
                if !searched && !savedSearches.isEmpty {
                    // Idle with pins: the saved searches double as a start page.
                    List(savedSearches) { saved in
                        Button {
                            queryText = saved.query
                        } label: {
                            HStack {
                                Label(saved.name, systemImage: "magnifyingglass.circle")
                                Spacer()
                                Text(saved.query)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeSavedSearch(named: saved.name)
                            } label: {
                                Label("Remove Pin", systemImage: "pin.slash")
                            }
                            .destructiveAction()
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(searched ? "No matches" : "Search everything",
                              systemImage: "magnifyingglass")
                    } description: {
                        Text(searched
                             ? "Nothing matches that query."
                             : "Searches the inbox, journal and split journals together.\nOperators: tag:work · before:2026-03 · after:2025 · has:image · is:starred · \"exact phrase\"\nPin a query with the pin button to keep it in the sidebar.")
                    }
                }
            } else {
                let sources = Dictionary(results.map { ($0.entry.id, $0.source) },
                                         uniquingKeysWith: { a, _ in a })
                EntryTwoPane(
                    entries: results.map(\.entry),
                    sourceFor: { sources[$0.id] ?? .archive(date: $0.date) },
                    listTitle: "Search",
                    fullDate: true
                )
            }
        }
        .searchable(text: $queryText, prompt: "tag:work before:2026-03 \"phrase\"")
        .navigationTitle("Search")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            Button {
                pinName = suggestedPinName
                namingPin = true
            } label: {
                Label("Pin Search", systemImage: "pin")
            }
            .disabled(SearchQuery.parse(queryText).isEmpty)
            .help("Keep this query in the sidebar")
        }
        .alert("Pin this search", isPresented: $namingPin) {
            TextField("Name", text: $pinName)
            Button("Pin") {
                let name = pinName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { store.addSavedSearch(name: name, query: queryText) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Shows up under Saved Searches in the sidebar.")
        }
        // Adopt a query handed over by a sidebar pin (or a deep link).
        .onAppear { adoptPendingQuery() }
        .onChange(of: nav.pendingSearchQuery) { _, _ in adoptPendingQuery() }
        .task(id: "\(queryText)#\(store.revision)") {
            savedSearches = store.savedSearches()
            // Debounce a beat so typing doesn't rescan per keystroke.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            run()
        }
    }

    private func adoptPendingQuery() {
        if let pending = nav.pendingSearchQuery {
            queryText = pending
            nav.pendingSearchQuery = nil
        }
    }

    /// A readable default name for the pin: the query itself, tidied.
    private var suggestedPinName: String {
        let q = queryText.trimmingCharacters(in: .whitespaces)
        return q.count <= 30 ? q : String(q.prefix(30))
    }

    private func run() {
        let query = SearchQuery.parse(queryText)
        guard !query.isEmpty else { results = []; searched = false; return }
        var hits: [(entry: Entry, source: EntrySource)] = []
        for e in store.inboxDrafts where query.matches(e) { hits.append((e, .inbox)) }
        for day in store.allEntriesByDay() {
            for e in day.entries where query.matches(e) { hits.append((e, .archive(date: day.date))) }
        }
        for j in store.splitJournals {
            for e in store.entries(inJournal: j.name) where query.matches(e) {
                hits.append((e, .journal(name: j.name)))
            }
        }
        results = hits.sorted { $0.entry.ts > $1.entry.ts }
        searched = true
    }
}
