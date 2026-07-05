//
//  TagsView.swift
//  Jibber
//
//  Tag explorer (jnl `tags` / `tag <name>`): every @tag with a usage count,
//  drilling into the entries that use it.
//

import SwiftUI

struct TagsView: View {
    @EnvironmentObject private var store: JournalStore
    @State private var searchText = ""

    var body: some View {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tags = q.isEmpty
            ? store.tagCounts()
            : store.tagCounts().filter { $0.tag.lowercased().contains(q) }
        Group {
            if tags.isEmpty {
                ContentUnavailableView(
                    "No tags yet",
                    systemImage: "number",
                    description: Text("Write @tags in your entries and they'll show up here.")
                )
            } else {
                List {
                    ForEach(tags, id: \.tag) { item in
                        NavigationLink {
                            TagDetailView(tag: item.tag)
                        } label: {
                            HStack {
                                Text(item.tag).foregroundStyle(.tint)
                                Spacer()
                                Text("\(item.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search tags")
        .navigationTitle("Tags")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Filed entries carrying one tag, newest first.
struct TagDetailView: View {
    @EnvironmentObject private var store: JournalStore
    let tag: String

    var body: some View {
        let hits = store.entries(taggedWith: tag)
        List {
            ForEach(hits, id: \.entry.id) { hit in
                NavigationLink {
                    EntryDetailView(entry: hit.entry, source: .archive(date: hit.date))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(hit.entry.preview.isEmpty ? "(empty)" : hit.entry.preview)
                                .lineLimit(1)
                            Spacer()
                            Text(hit.date)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if !hit.entry.body.isEmpty {
                            Text(hit.entry.body)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(tag)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
