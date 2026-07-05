//
//  ArchiveView.swift
//  Jibber
//
//  Browse filed entries (jnl `browse`/`list`): days grouped by year, each row
//  showing a preview so the archive doesn't feel empty. Searchable across all
//  filed entries (jnl `search`), with Stats and a Random entry (jnl `stats`/`random`).
//

import SwiftUI

enum ArchiveSort: String, CaseIterable, Identifiable {
    case newest, oldest
    var id: String { rawValue }
    var label: String { self == .newest ? "Newest first" : "Oldest first" }
}

struct ArchiveView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    @AppStorage("archiveSort") private var sortRaw: String = ArchiveSort.newest.rawValue

    @State private var searchText = ""
    @State private var showingStats = false
    @State private var randomHit: Hit?

    struct Hit: Identifiable { let id = UUID(); let date: String; let entry: Entry }

    private var oldestFirst: Bool { ArchiveSort(rawValue: sortRaw) == .oldest }

    private var years: [String] {
        var seen = Set<String>(), out: [String] = []
        for d in store.archiveDays where !seen.contains(d.year) { seen.insert(d.year); out.append(d.year) }
        return oldestFirst ? out.reversed() : out
    }

    private func days(in year: String) -> [JournalStore.ArchiveDay] {
        let d = store.archiveDays.filter { $0.year == year }
        return oldestFirst ? d.reversed() : d
    }

    private var searchGroups: [(date: String, entries: [Entry])] {
        var order: [String] = [], map: [String: [Entry]] = [:]
        for hit in store.search(searchText) {
            if map[hit.date] == nil { order.append(hit.date) }
            map[hit.date, default: []].append(hit.entry)
        }
        let groups = order.map { ($0, map[$0] ?? []) }
        return oldestFirst ? groups.reversed() : groups
    }

    var body: some View {
        Group {
            if store.archiveDays.isEmpty {
                ContentUnavailableView(
                    "No entries yet",
                    systemImage: "archivebox",
                    description: Text("File drafts from your inbox and they'll show up here.")
                )
            } else {
                List {
                    if searchText.isEmpty {
                        ForEach(years, id: \.self) { year in
                            Section(year) {
                                ForEach(days(in: year)) { day in
                                    NavigationLink {
                                        DayView(date: day.date)
                                    } label: {
                                        dayRow(day)
                                    }
                                }
                            }
                        }
                    } else if searchGroups.isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    } else {
                        ForEach(searchGroups, id: \.date) { group in
                            Section(Theme.displayDate(group.date, style: dateStyleRaw)) {
                                ForEach(group.entries) { entry in
                                    NavigationLink {
                                        EntryDetailView(entry: entry, source: .archive(date: group.date))
                                    } label: {
                                        EntryPreviewRow(entry: entry)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search entries")
        .navigationTitle("Archive")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(ArchiveSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            Button {
                if let r = store.randomEntry() { randomHit = Hit(date: r.date, entry: r.entry) }
            } label: {
                Label("Random", systemImage: "dice")
            }
            .disabled(store.archiveDays.isEmpty)
            Button {
                showingStats = true
            } label: {
                Label("Stats", systemImage: "chart.bar")
            }
        }
        .sheet(isPresented: $showingStats) {
            StatsView(stats: store.stats()).environmentObject(store)
        }
        .sheet(item: $randomHit) { hit in
            NavigationStack {
                EntryDetailView(entry: hit.entry, source: .archive(date: hit.date))
            }
            .environmentObject(store)
        }
    }

    private func dayRow(_ day: JournalStore.ArchiveDay) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Theme.displayDate(day.date, style: dateStyleRaw)).fontWeight(.medium)
                Spacer()
                Text("\(day.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !day.preview.isEmpty {
                Text(day.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A compact entry preview row (title/first line + body snippet).
struct EntryPreviewRow: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.preview.isEmpty ? "(empty)" : entry.preview)
                .lineLimit(1)
            if !entry.body.isEmpty {
                Text(entry.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One day's filed entries.
struct DayView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    let date: String

    var body: some View {
        List {
            ForEach(store.entries(for: date)) { entry in
                NavigationLink {
                    EntryDetailView(entry: entry, source: .archive(date: date))
                } label: {
                    EntryPreviewRow(entry: entry)
                }
            }
        }
        .navigationTitle(Theme.displayDate(date, style: dateStyleRaw))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Writing stats (jnl `stats`).
struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    let stats: JournalStore.Stats

    var body: some View {
        NavigationStack {
            Form {
                Section("Totals") {
                    LabeledContent("Days written", value: "\(stats.days)")
                    LabeledContent("Entries", value: "\(stats.entries)")
                    LabeledContent("Words", value: "\(stats.words)")
                    if stats.entries > 0 {
                        LabeledContent("Avg per entry", value: "\(stats.words / stats.entries) words")
                    }
                }
                Section("Streaks") {
                    LabeledContent("Current", value: "\(stats.currentStreak) day\(stats.currentStreak == 1 ? "" : "s")")
                    LabeledContent("Best", value: "\(stats.bestStreak) day\(stats.bestStreak == 1 ? "" : "s")")
                }
                if !stats.longestDay.isEmpty {
                    Section("Highlights") {
                        LabeledContent("Longest day", value: "\(stats.longestDay) · \(stats.longestDayWords) words")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Stats")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
