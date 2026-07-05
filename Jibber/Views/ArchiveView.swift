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
    @AppStorage("archiveSort") private var sortRaw: String = ArchiveSort.newest.rawValue

    @State private var searchText = ""
    @State private var randomHit: Hit?
    @State private var loaded: [Entry] = []

    struct Hit: Identifiable { let id = UUID(); let date: String; let entry: Entry }

    private var oldestFirst: Bool { ArchiveSort(rawValue: sortRaw) == .oldest }

    private var filtered: [Entry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return q.isEmpty ? loaded : loaded.filter { $0.raw.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if loaded.isEmpty {
                ContentUnavailableView(
                    "No entries yet",
                    systemImage: "book.closed",
                    description: Text("File drafts from your inbox and they'll show up here.")
                )
            } else {
                EntryTwoPane(
                    entries: filtered,
                    sourceFor: { .archive(date: $0.date) },
                    showTime: true,
                    groupByDate: true,
                    oldestFirst: oldestFirst
                )
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
            .disabled(loaded.isEmpty)
        }
        .task(id: store.revision) { loaded = store.allEntriesByDay().flatMap(\.entries) }
        .sheet(item: $randomHit) { hit in
            NavigationStack {
                EntryDetailView(entry: hit.entry, source: .archive(date: hit.date))
            }
            .environmentObject(store)
        }
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

/// Reusable email-style list+detail for a set of entries (macOS); iOS pushes.
/// Same look as the Inbox: fixed-width list on the left, open entry on the right.
struct EntryTwoPane: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    let entries: [Entry]
    let sourceFor: (Entry) -> EntrySource
    var showTime = false     // just HH:mm (single-day contexts)
    var fullDate = false     // date + time (flat, multi-day contexts)
    var groupByDate = false  // section the list by date (headers), entries under each
    var oldestFirst = false  // date-section order when grouping
    @State private var selectedTS: String?

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            list.frame(width: 320)
            Divider()
            Group {
                if let ts = selectedTS, let e = entries.first(where: { $0.ts == ts }) {
                    EntryDetailView(entry: e, source: sourceFor(e)).id(ts)
                } else {
                    ContentUnavailableView("Select an entry", systemImage: "book.closed")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        list
        #endif
    }

    /// Entries grouped by their date, section order by newest/oldest.
    private var sections: [(date: String, entries: [Entry])] {
        let sorted = entries.sorted { oldestFirst ? $0.ts < $1.ts : $0.ts > $1.ts }
        var order: [String] = [], map: [String: [Entry]] = [:]
        for e in sorted {
            if map[e.date] == nil { order.append(e.date) }
            map[e.date, default: []].append(e)
        }
        return order.map { (date: $0, entries: map[$0] ?? []) }
    }

    @ViewBuilder
    private var list: some View {
        List(selection: selectionBinding) {
            if groupByDate {
                ForEach(sections, id: \.date) { section in
                    Section(Theme.displayDate(section.date, style: dateStyleRaw)) {
                        ForEach(section.entries) { entryRow($0) }
                    }
                }
            } else {
                ForEach(entries) { entryRow($0) }
            }
        }
    }

    private func entryRow(_ entry: Entry) -> some View {
        rowLabel(entry)
            .tag(entry.ts)
            .contextMenu {
                Button(role: .destructive) { delete(entry) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private func rowLabel(_ entry: Entry) -> some View {
        let isInbox: Bool = { if case .inbox = sourceFor(entry) { return true }; return false }()
        let row = HStack(spacing: 8) {
            EntryPreviewRow(entry: entry,
                            dateStyleRaw: fullDate ? dateStyleRaw : nil,
                            showTime: !fullDate && showTime)
            if isInbox {
                Text("Inbox")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        row
        #else
        NavigationLink(value: Route.entry(entry, sourceFor(entry))) { row }
        #endif
    }

    private var selectionBinding: Binding<String?> {
        #if os(macOS)
        $selectedTS
        #else
        .constant(nil)
        #endif
    }

    private func delete(_ entry: Entry) {
        switch sourceFor(entry) {
        case .inbox:            store.deleteDraft(entry)
        case .archive(let d):   store.deleteFiledEntry(date: d, entry: entry)
        case .journal(let n):   store.deleteJournalEntry(name: n, entry: entry)
        }
    }
}

/// One day's filed entries.
struct DayView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    let date: String

    var body: some View {
        EntryTwoPane(entries: store.entries(for: date),
                     sourceFor: { _ in .archive(date: date) },
                     showTime: true)
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
        EntryTwoPane(entries: store.entries(inJournal: name),
                     sourceFor: { _ in .journal(name: name) },
                     showTime: true,
                     groupByDate: true)
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
