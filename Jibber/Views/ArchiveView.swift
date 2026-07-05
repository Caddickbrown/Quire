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
                    systemImage: "book.closed",
                    description: Text("File drafts from your inbox and they'll show up here.")
                )
            } else {
                List {
                    if searchText.isEmpty {
                        ForEach(years, id: \.self) { year in
                            Section(year) {
                                ForEach(days(in: year)) { day in
                                    NavigationLink(value: Route.day(day.date)) {
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
                                    NavigationLink(value: Route.entry(entry, .archive(date: group.date))) {
                                        EntryPreviewRow(entry: entry)
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            store.deleteFiledEntry(date: group.date, entry: entry)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search entries")
        .navigationTitle("Journal")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(ArchiveSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            Button {
                if let r = store.randomEntry() { randomHit = Hit(date: r.date, entry: r.entry) }
            } label: {
                Label("Random", systemImage: "dice")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.archiveDays.isEmpty)
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

/// A compact entry preview row (title/first line + body snippet). When
/// `dateStyleRaw` is set, the entry's date + time is shown on the trailing side.
struct EntryPreviewRow: View {
    let entry: Entry
    var dateStyleRaw: String? = nil
    var showTime: Bool = false

    private var time: String { String(entry.ts.suffix(8).prefix(5)) }
    private var trailing: String? {
        if let ds = dateStyleRaw { return "\(Theme.displayDate(entry.date, style: ds)) · \(time)" }
        if showTime { return time }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.preview.isEmpty ? "(empty)" : entry.preview)
                    .lineLimit(1)
                if let trailing {
                    Spacer()
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
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
                NavigationLink(value: Route.entry(entry, .archive(date: date))) {
                    EntryPreviewRow(entry: entry, showTime: true)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        store.deleteFiledEntry(date: date, entry: entry)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(Theme.displayDate(date, style: dateStyleRaw))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Sidebar section listing all tag-routed split journals.
struct SplitJournalsView: View {
    @EnvironmentObject private var store: JournalStore

    var body: some View {
        let journals = store.splitJournals
        Group {
            if journals.isEmpty {
                ContentUnavailableView(
                    "No split journals",
                    systemImage: "bookmark",
                    description: Text("Add tags in Settings → Split tags. Filed entries with those @tags land in their own journal here.")
                )
            } else {
                List {
                    ForEach(journals) { j in
                        NavigationLink(value: Route.journalFile(j.name)) {
                            HStack {
                                Label("@\(j.name)", systemImage: "bookmark")
                                Spacer()
                                Text("\(j.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Split Journals")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// A tag-routed split journal (<base>/<name>.md), e.g. work.md.
struct JournalFileView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    let name: String

    var body: some View {
        List {
            ForEach(store.entries(inJournal: name)) { entry in
                NavigationLink(value: Route.entry(entry, .journal(name: name))) {
                    EntryPreviewRow(entry: entry, dateStyleRaw: dateStyleRaw)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        store.deleteJournalEntry(name: name, entry: entry)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("@\(name)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Journal stats (jnl `stats`), shown as a sidebar pane. Covers the archive,
/// inbox, tags, and split journals.
struct StatsView: View {
    @EnvironmentObject private var store: JournalStore
    @State private var stats = JournalStore.Stats()

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        Form {
            Section("Overview") {
                LabeledContent("Inbox drafts", value: "\(stats.inboxDrafts)")
                LabeledContent("Inbox size", value: Self.size(stats.inboxBytes))
                LabeledContent("Tags", value: "\(stats.tags)")
                if stats.splitJournals > 0 {
                    LabeledContent("Split journals", value: "\(stats.splitJournals)")
                }
                LabeledContent("Journal size", value: Self.size(stats.bytes))
            }
            Section("Archive") {
                LabeledContent("Days written", value: "\(stats.days)")
                LabeledContent("Entries", value: "\(stats.entries)")
                LabeledContent("Words", value: "\(stats.words)")
                if stats.entries > 0 {
                    LabeledContent("Avg per entry", value: "\(stats.words / stats.entries) words")
                }
                LabeledContent("Archive size", value: Self.size(stats.archiveBytes))
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
        .task { stats = store.stats() }
    }
}
