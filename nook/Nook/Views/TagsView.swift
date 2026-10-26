//
//  TagsView.swift
//  Nook
//
//  Tag explorer (jnl `tags` / `tag <name>`): a horizontal rail of coloured tag
//  chips across the top; picking one shows its entries in the shared two-pane
//  (list + open entry on macOS, push on iOS). Tap another chip to switch tags.
//

import SwiftUI

struct TagsView: View {
    @EnvironmentObject private var store: JournalStore
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var taggedEntries: [Entry] = []
    @State private var taggedSources: [String: EntrySource] = [:]

    private var tags: [(tag: String, count: Int)] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.isEmpty ? store.tagCounts : store.tagCounts.filter { $0.tag.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if store.tagCounts.isEmpty {
                ContentUnavailableView(
                    "No tags yet",
                    systemImage: "number",
                    description: Text("Write @tags in your entries and they'll show up here.")
                )
            } else {
                VStack(spacing: 0) {
                    rail
                    Divider()
                    entriesPane
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search tags")
        .navigationTitle("Tags")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            Button {
                selectedTag = tags.randomElement()?.tag
            } label: {
                Label("Random", systemImage: "dice")
            }
            .disabled(tags.isEmpty)
        }
        .onAppear { if selectedTag == nil { selectedTag = store.tagCounts.first?.tag } }
        // Load once per (tag, revision) — reading inside `body` re-read the
        // whole journal on every render, i.e. on every search keystroke.
        .task(id: TagLoadKey(tag: selectedTag, revision: store.revision)) { loadTagged() }
    }

    private struct TagLoadKey: Equatable { let tag: String?; let revision: Int }

    private func loadTagged() {
        guard let tag = selectedTag else {
            taggedEntries = []; taggedSources = [:]
            return
        }
        let inboxHits = store.inboxDrafts.filter { $0.tags.contains(tag) }
        let journalHits = store.entries(taggedWith: tag)
        // Two pools in one list, so the ids are renumbered across the merge —
        // a draft and a filed entry sharing a second are both `ts` until then,
        // and would share a source (see `mergedEntrySources`).
        let pairs = inboxHits.map { (entry: $0, source: EntrySource.inbox) }
            + journalHits.map { (entry: $0.entry, source: EntrySource.archive(date: $0.date)) }
        let merged = mergedEntrySources(pairs)
        taggedEntries = merged.entries
        taggedSources = Dictionary(zip(merged.entries.map(\.id), pairs.map(\.source)),
                                   uniquingKeysWith: { a, _ in a })
    }

    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.tag) { item in
                    Button {
                        selectedTag = item.tag
                    } label: {
                        chip(item, selected: item.tag == selectedTag)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var entriesPane: some View {
        if let tag = selectedTag {
            EntryTwoPane(
                entries: taggedEntries,
                sourceFor: { taggedSources[$0.id] ?? .archive(date: $0.date) },
                fullDate: true
            )
            .id(tag)
        } else {
            ContentUnavailableView("Select a tag", systemImage: "number")
        }
    }

    private func chip(_ item: (tag: String, count: Int), selected: Bool) -> some View {
        let color = Self.color(for: item.tag)
        return HStack(spacing: 6) {
            Text(item.tag)
                .fontWeight(.medium)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(color))
            Text("\(item.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(selected ? color : color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(selected ? 0 : 0.35), lineWidth: 1))
    }

    /// A palette so the tags aren't a sea of one colour; each tag maps to a stable colour.
    static let palette: [Color] = [
        .blue, .teal, .green, .orange, .pink, .purple, .red, .indigo, .mint, .cyan, .brown,
    ]

    static func color(for tag: String) -> Color {
        let hash = tag.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[hash % palette.count]
    }
}

/// Still reachable via Route.tag; a plain list of a tag's entries.
struct TagDetailView: View {
    @EnvironmentObject private var store: JournalStore
    let tag: String

    var body: some View {
        let hits = store.entries(taggedWith: tag)
        let dateByTS = Dictionary(hits.map { ($0.entry.ts, $0.date) }, uniquingKeysWith: { a, _ in a })
        EntryTwoPane(
            entries: hits.map(\.entry),
            sourceFor: { .archive(date: dateByTS[$0.ts] ?? "") },
            fullDate: true
        )
        .navigationTitle(tag)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
