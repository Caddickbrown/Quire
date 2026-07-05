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
        let maxCount = max(tags.map(\.count).max() ?? 1, 1)
        Group {
            if tags.isEmpty {
                ContentUnavailableView(
                    "No tags yet",
                    systemImage: "number",
                    description: Text("Write @tags in your entries and they'll show up here.")
                )
            } else {
                ScrollView {
                    FlowLayout(spacing: 8) {
                        ForEach(tags, id: \.tag) { item in
                            NavigationLink {
                                TagDetailView(tag: item.tag)
                            } label: {
                                bubble(item, maxCount: maxCount)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search tags")
        .navigationTitle("Tags")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// A tag bubble: name + count, tinted more strongly the more it's used.
    private func bubble(_ item: (tag: String, count: Int), maxCount: Int) -> some View {
        let intensity = 0.12 + 0.35 * (Double(item.count) / Double(maxCount))
        return HStack(spacing: 6) {
            Text(item.tag)
                .fontWeight(.medium)
                .foregroundStyle(.tint)
            Text("\(item.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.18), in: Capsule())
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(intensity), in: Capsule())
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
                    tagRow(hit)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        store.deleteFiledEntry(date: hit.date, entry: hit.entry)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(tag)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func tagRow(_ hit: (date: String, entry: Entry)) -> some View {
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
