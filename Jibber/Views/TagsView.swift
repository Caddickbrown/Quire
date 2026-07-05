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
    @State private var randomTag: RandomTag?

    struct RandomTag: Identifiable { let id = UUID(); let tag: String }

    var body: some View {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tags = q.isEmpty
            ? store.tagCounts
            : store.tagCounts.filter { $0.tag.lowercased().contains(q) }
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
                            NavigationLink(value: Route.tag(item.tag)) {
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
        .toolbar {
            Button {
                if let t = store.tagCounts.randomElement() {
                    randomTag = RandomTag(tag: t.tag)
                }
            } label: {
                Label("Random", systemImage: "dice")
            }
            .disabled(tags.isEmpty)
        }
        .sheet(item: $randomTag) { r in
            NavigationStack {
                TagDetailView(tag: r.tag).jibberRoutes()
            }
            .environmentObject(store)
        }
    }

    /// A palette so the tag cloud isn't a sea of one colour. Each tag gets a
    /// stable colour from its name; frequency sets how strong the fill is.
    static let palette: [Color] = [
        .blue, .teal, .green, .orange, .pink, .purple, .red, .indigo, .mint, .cyan, .brown,
    ]

    static func color(for tag: String) -> Color {
        let hash = tag.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[hash % palette.count]
    }

    /// A tag bubble: name + count, coloured per tag and filled by frequency.
    private func bubble(_ item: (tag: String, count: Int), maxCount: Int) -> some View {
        let color = Self.color(for: item.tag)
        let intensity = 0.16 + 0.34 * (Double(item.count) / Double(maxCount))
        return HStack(spacing: 6) {
            Text(item.tag)
                .fontWeight(.medium)
                .foregroundStyle(color)
            Text("\(item.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(color.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(color.opacity(0.18), in: Capsule())
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(color.opacity(intensity), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
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
                NavigationLink(value: Route.entry(hit.entry, .archive(date: hit.date))) {
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
