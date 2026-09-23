//
//  ArchiveView.swift
//  Nook
//
//  Browse filed entries (jnl `browse`/`list`): days grouped by year, each row
//  showing a preview so the archive doesn't feel empty. Searchable across all
//  filed entries (jnl `search`), with Stats and a Random entry (jnl `stats`/`random`).
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import PDFKit
#endif

enum ArchiveSort: String, CaseIterable, Identifiable {
    case newest, oldest
    var id: String { rawValue }
    var label: String { self == .newest ? "Newest first" : "Oldest first" }
}

/// How an entry list is broken up: date headers, or one flat list. Shared by the
/// Inbox, Journal, split journals and Starred so they all group the same way.
enum EntryGrouping: String, CaseIterable, Identifiable {
    case date, none
    var id: String { rawValue }
    var label: String { self == .date ? "Group by date" : "No grouping" }
}

struct ArchiveView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("archiveSort") private var sortRaw: String = ArchiveSort.newest.rawValue
    @AppStorage("archiveGrouping") private var groupingRaw: String = EntryGrouping.date.rawValue

    @State private var searchText = ""
    @State private var randomHit: Hit?
    @State private var loaded: [Entry] = []
    @State private var onThisDayDays: [(date: String, entries: [Entry])] = []
    @State private var showingOnThisDay = false

    struct Hit: Identifiable { let id = UUID(); let date: String; let entry: Entry }

    private var oldestFirst: Bool { ArchiveSort(rawValue: sortRaw) == .oldest }
    private var grouping: EntryGrouping { EntryGrouping(rawValue: groupingRaw) ?? .date }

    private func openRandom() {
        if let r = store.randomEntry() { randomHit = Hit(date: r.date, entry: r.entry) }
    }

    private var filtered: [Entry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hits = q.isEmpty ? loaded : loaded.filter { $0.raw.lowercased().contains(q) }
        return hits.sorted { oldestFirst ? $0.ts < $1.ts : $0.ts > $1.ts }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !onThisDayDays.isEmpty {
                OnThisDayBanner(years: onThisDayDays.count,
                                count: onThisDayDays.reduce(0) { $0 + $1.entries.count }) {
                    showingOnThisDay = true
                }
            }
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
                    listTitle: "Journal",
                    showTime: grouping == .date,
                    fullDate: grouping == .none,   // ungrouped rows carry their own date
                    groupByDate: grouping == .date,
                    oldestFirst: oldestFirst,
                    onPullRandom: openRandom
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search entries")
        .navigationTitle("Journal")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Dice then sort — same order as the Inbox toolbar.
        .toolbar {
            Button { openRandom() } label: {
                Label("Random", systemImage: "dice")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(loaded.isEmpty)
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(ArchiveSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Grouping", selection: $groupingRaw) {
                    ForEach(EntryGrouping.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        .task(id: store.revision) {
            loaded = store.allEntriesByDay().flatMap(\.entries)
            onThisDayDays = store.onThisDay()
        }
        .sheet(item: $randomHit) { hit in
            NavigationStack {
                EntryDetailView(entry: hit.entry, source: .archive(date: hit.date))
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showingOnThisDay) {
            OnThisDaySheet(days: onThisDayDays)
                .environmentObject(store)
        }
    }
}

/// THE entry row — the one template every list uses (Inbox, Journal, Starred,
/// a day, a split journal, tag results), so an entry reads the same wherever
/// you meet it. Only the meta line's leading date/time varies by list:
/// title line, body snippet, then a caption meta line (date/time · words ·
/// media badges), tags, and the trailing thumbnail.
struct EntryPreviewRow: View {
    let entry: Entry
    /// When set, the meta line leads with the entry's full date (lists that mix
    /// days); otherwise `showTime` puts just the time there (single-day lists
    /// and the Inbox).
    var dateStyleRaw: String? = nil
    var showTime: Bool = false

    private var time: String { String(entry.ts.suffix(8).prefix(5)) }
    private var when: String? {
        if let ds = dateStyleRaw { return "\(Theme.sectionDate(entry.date, style: ds)) · \(time)" }
        if showTime { return time }
        return nil
    }

    /// The body snippet under the title. For an untitled entry the title line
    /// already shows the body's first line, so the snippet starts after it
    /// rather than repeating it.
    private var snippet: String {
        guard entry.displayTitle.isEmpty else { return entry.body }
        guard let cut = entry.body.range(of: "\n") else { return "" }
        return String(entry.body[cut.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if entry.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    Text(entry.preview.isEmpty ? "(empty)" : entry.preview)
                        .lineLimit(1)
                        .font(.body)
                }
                if !snippet.isEmpty {
                    Text(snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let when {
                        Text(when).monospacedDigit()
                        Text("·")
                    }
                    Text("\(entry.wordCount) words")
                    ForEach(entry.mediaBadges, id: \.self) { symbol in
                        Image(systemName: symbol)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                // Tags on their own line — kept even when there are none (a
                // blank of the same height), so tagged and untagged rows stand
                // the same and the list doesn't look uneven.
                Text(entry.tags.isEmpty ? " " : entry.tags.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            EntryThumbnail(entry: entry)
        }
        .padding(.vertical, 2)
    }
}

/// Reusable email-style list+detail for a set of entries (macOS); iOS pushes.
/// Same look as the Inbox: fixed-width list on the left, open entry on the right.
struct EntryTwoPane: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.accent) private var accent
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    let entries: [Entry]
    let sourceFor: (Entry) -> EntrySource
    /// What the external display calls this list while you arrow through it.
    var listTitle = "Journal"
    var showTime = false     // just HH:mm (single-day contexts)
    var fullDate = false     // date + time (flat, multi-day contexts)
    var groupByDate = false  // section the list by date (headers), entries under each
    var oldestFirst = false  // date-section order when grouping
    /// Pull down past the top to open a random entry (iOS), as in the Inbox.
    var onPullRandom: (() -> Void)? = nil
    @State private var selectedTS: String?
    @State private var openEntry: Entry?
    /// Hardware-keyboard selection (↑/↓), mirrored to the external display.
    @State private var kbIndex: Int?

    /// Stable per-row keys: the timestamp, disambiguated by occurrence for the
    /// rare same-second twins (`ts`, `ts#1`, …). Keying rows on the bare ts
    /// gave twin rows identical view identity — the list drew the first twin
    /// twice and opened the wrong one.
    /// Rebuilt only when the entries array actually changes — as a computed
    /// property this was rebuilt per `key()` call, i.e. per row render, which
    /// made a 4,000-entry list O(n²) and visibly slow.
    @State private var rowKeys: [UUID: String] = [:]

    private static func makeRowKeys(_ entries: [Entry]) -> [UUID: String] {
        var seen: [String: Int] = [:], out: [UUID: String] = [:]
        for e in entries {
            let n = seen[e.ts, default: 0]
            seen[e.ts] = n + 1
            out[e.id] = n == 0 ? e.ts : "\(e.ts)#\(n)"
        }
        return out
    }
    private func key(_ e: Entry) -> String { rowKeys[e.id] ?? e.ts }

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            list.frame(width: 320)
            Divider()
            Group {
                // Render the retained selection, so filtering it out of the list
                // (e.g. editing out a search term) doesn't kick you out mid-edit
                // — cleared only when the selection itself is cleared.
                if let e = openEntry {
                    EntryDetailView(entry: e, source: sourceFor(e),
                                    onReturnedToInbox: { openEntry = nil; selectedTS = nil })
                        .id(key(e))
                } else {
                    ContentUnavailableView("Select an entry", systemImage: "book.closed")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selectedTS) { _, sel in
            if let sel, let e = entries.first(where: { key($0) == sel }) { openEntry = e }
            else if sel == nil { openEntry = nil }
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
        // ScrollViewReader so an arrow-key selection off the bottom of the
        // screen brings its row into view rather than silently moving.
        ScrollViewReader { proxy in
            List(selection: selectionBinding) {
                if groupByDate {
                    ForEach(sections, id: \.date) { section in
                        Section(Theme.sectionDate(section.date, style: dateStyleRaw)) {
                            ForEach(section.entries) { entryRow($0) }
                        }
                    }
                } else {
                    ForEach(entries) { entryRow($0) }
                }
            }
            .onChange(of: kbIndex) { _, i in
                guard let i, entries.indices.contains(i) else { return }
                withAnimation { proxy.scrollTo(key(entries[i]), anchor: .center) }
            }
        }
        #if os(iOS)
        .refreshable { onPullRandom?() }
        .background { if onPullRandom != nil { DiceRefreshDecorator() } }
        #endif
        .entryListNavigation(entries: entries, index: $kbIndex, listTitle: listTitle) { entry in
            open(entry)
        }
        .onAppear { rowKeys = Self.makeRowKeys(entries) }
        .onChange(of: entries.map(\.id)) { _, _ in rowKeys = Self.makeRowKeys(entries) }
    }

    /// Open the keyboard-selected entry: the side pane on macOS, a push on iOS.
    private func open(_ entry: Entry) {
        #if os(macOS)
        selectedTS = key(entry)
        openEntry = entry
        #else
        nav.path.append(Route.entry(entry, sourceFor(entry)))
        #endif
    }

    private func entryRow(_ entry: Entry) -> some View {
        let keyboardSelected = kbIndex.map { entries.indices.contains($0) && entries[$0].id == entry.id } ?? false
        return rowLabel(entry)
            .tag(key(entry))
            .id(key(entry))
            .keyboardSelectedRow(keyboardSelected, accent: accent)
            .contextMenu {
                Button { store.toggleStar(entry, source: sourceFor(entry)) } label: {
                    Label(entry.isStarred ? "Unstar" : "Star",
                          systemImage: entry.isStarred ? "star.slash" : "star")
                }
                if sourceFor(entry) != .inbox {
                    Button { returnToInbox(entry) } label: {
                        Label("Return to Inbox", systemImage: "tray.and.arrow.up")
                    }
                }
                #if os(macOS)
                Button { store.revealEntry(source: sourceFor(entry)) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                #endif
                Button(role: .destructive) { delete(entry) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .destructiveAction()
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

    private func returnToInbox(_ entry: Entry) {
        #if os(macOS)
        if openEntry?.id == entry.id { openEntry = nil; selectedTS = nil }
        #endif
        store.returnToInbox(entry, source: sourceFor(entry))
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
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    let date: String

    @State private var pdfDoc: PDFExportDocument?
    @State private var makingPDF = false

    var body: some View {
        EntryTwoPane(entries: store.entries(for: date),
                     sourceFor: { _ in .archive(date: date) },
                     listTitle: Theme.sectionDate(date, style: dateStyleRaw),
                     showTime: true)
            .navigationTitle(Theme.displayDate(date, style: dateStyleRaw))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button {
                    exportPDF()
                } label: {
                    Label("Export PDF", systemImage: "doc.richtext")
                }
                .disabled(makingPDF)
                .help("Export this day as a typeset PDF")
                #if os(macOS)
                Button {
                    printDay()
                } label: {
                    Label("Print", systemImage: "printer")
                }
                .disabled(makingPDF)
                .help("Print this day")
                #endif
            }
            .fileExporter(isPresented: Binding(
                get: { pdfDoc != nil },
                set: { if !$0 { pdfDoc = nil } }
            ), document: pdfDoc, contentType: .pdf, defaultFilename: "nook-\(date).pdf") { _ in }
    }

    private func exportPDF() {
        makingPDF = true
        Task { @MainActor in
            defer { makingPDF = false }
            let data = await PDFExporter.makePDF(days: [(date, store.entries(for: date))],
                                                 store: store,
                                                 dateStyleRaw: dateStyleRaw,
                                                 fontRaw: writingFontRaw,
                                                 fontSize: CGFloat(fontSize))
            if let data { pdfDoc = PDFExportDocument(data: data) }
        }
    }

    #if os(macOS)
    /// Same render path as Export PDF, straight into the print panel.
    private func printDay() {
        makingPDF = true
        Task { @MainActor in
            defer { makingPDF = false }
            guard let data = await PDFExporter.makePDF(days: [(date, store.entries(for: date))],
                                                       store: store,
                                                       dateStyleRaw: dateStyleRaw,
                                                       fontRaw: writingFontRaw,
                                                       fontSize: CGFloat(fontSize)),
                  let doc = PDFDocument(data: data),
                  let op = doc.printOperation(for: .shared, scalingMode: .pageScaleDownToFit, autoRotate: true)
            else { return }
            op.run()
        }
    }
    #endif
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
                        #if os(macOS)
                        .contextMenu {
                            Button { store.revealEntry(source: .journal(name: j.name)) } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                        }
                        #endif
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
    // Shares the Journal's sort/grouping — a split journal is the same list,
    // just filtered to one tag.
    @AppStorage("archiveSort") private var sortRaw: String = ArchiveSort.newest.rawValue
    @AppStorage("archiveGrouping") private var groupingRaw: String = EntryGrouping.date.rawValue
    let name: String

    private var oldestFirst: Bool { ArchiveSort(rawValue: sortRaw) == .oldest }
    private var grouping: EntryGrouping { EntryGrouping(rawValue: groupingRaw) ?? .date }
    private var entries: [Entry] {
        store.entries(inJournal: name).sorted { oldestFirst ? $0.ts < $1.ts : $0.ts > $1.ts }
    }

    var body: some View {
        EntryTwoPane(entries: entries,
                     sourceFor: { _ in .journal(name: name) },
                     listTitle: name,
                     showTime: grouping == .date,
                     fullDate: grouping == .none,
                     groupByDate: grouping == .date,
                     oldestFirst: oldestFirst)
            .navigationTitle("@\(name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Menu {
                    Picker("Sort", selection: $sortRaw) {
                        ForEach(ArchiveSort.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Picker("Grouping", selection: $groupingRaw) {
                        ForEach(EntryGrouping.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
    }
}

/// Starred entries (titles ending in `*`) from across the archive, inbox and
/// split journals, opened/edited in place.
struct StarredView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("starredSort") private var sortRaw: String = ArchiveSort.newest.rawValue
    @AppStorage("starredGrouping") private var groupingRaw: String = EntryGrouping.date.rawValue
    @State private var loaded: [(entry: Entry, source: EntrySource)] = []
    @State private var randomHit: StarredHit?

    struct StarredHit: Identifiable { let id = UUID(); let entry: Entry; let source: EntrySource }

    private var oldestFirst: Bool { ArchiveSort(rawValue: sortRaw) == .oldest }
    private var grouping: EntryGrouping { EntryGrouping(rawValue: groupingRaw) ?? .date }
    private var entries: [Entry] {
        loaded.map(\.entry).sorted { oldestFirst ? $0.ts < $1.ts : $0.ts > $1.ts }
    }

    private func openRandom() {
        if let pick = loaded.randomElement() {
            randomHit = StarredHit(entry: pick.entry, source: pick.source)
        }
    }

    var body: some View {
        Group {
            if loaded.isEmpty {
                ContentUnavailableView(
                    "No starred entries",
                    systemImage: "star",
                    description: Text("Star an entry (the ✩ button adds a * to its title) and it shows up here.")
                )
            } else {
                let sources = Dictionary(loaded.map { ($0.entry.id, $0.source) },
                                         uniquingKeysWith: { a, _ in a })
                EntryTwoPane(
                    entries: entries,
                    sourceFor: { sources[$0.id] ?? .archive(date: $0.date) },
                    listTitle: "Starred",
                    showTime: grouping == .date,
                    fullDate: grouping == .none,   // ungrouped rows carry their own date
                    groupByDate: grouping == .date,
                    oldestFirst: oldestFirst,
                    onPullRandom: openRandom
                )
            }
        }
        .navigationTitle("Starred")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Dice then sort — same order as the Inbox and Journal toolbars.
        .toolbar {
            Button { openRandom() } label: {
                Label("Random", systemImage: "dice")
            }
            .disabled(loaded.isEmpty)
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(ArchiveSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Grouping", selection: $groupingRaw) {
                    ForEach(EntryGrouping.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        .sheet(item: $randomHit) { hit in
            NavigationStack {
                EntryDetailView(entry: hit.entry, source: hit.source)
            }
            .environmentObject(store)
        }
        .task(id: store.revision) {
            loaded = store.starredEntries().sorted { $0.entry.ts > $1.entry.ts }
        }
    }
}

/// Journal stats (jnl `stats`), shown as a sidebar pane. Covers the archive,
/// inbox, tags, and split journals.
struct StatsView: View {
    @EnvironmentObject private var store: JournalStore
    @AppStorage("wordGoalEnabled") private var wordGoalEnabled = false
    @AppStorage("wordGoal") private var wordGoal = 750
    @State private var stats = JournalStore.Stats()
    @State private var reviewYear: ReviewYear?
    @State private var showingTrends = false

    struct ReviewYear: Identifiable { let year: String; var id: String { year } }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        Form {
            Section("Overview") {
                LabeledContent("Inbox drafts", value: "\(stats.inboxDrafts)")
                LabeledContent("Tags", value: "\(stats.tags)")
                if stats.splitJournals > 0 {
                    LabeledContent("Split journals", value: "\(stats.splitJournals)")
                }
            }
            Section("Today") {
                LabeledContent("Words today", value: "\(stats.wordsToday)")
                if wordGoalEnabled {
                    LabeledContent("Daily goal") {
                        Text(stats.wordsToday >= max(wordGoal, 1)
                             ? "Met — \(stats.wordsToday) / \(max(wordGoal, 1))"
                             : "\(stats.wordsToday) / \(max(wordGoal, 1))")
                            .foregroundStyle(stats.wordsToday >= max(wordGoal, 1) ? .green : .secondary)
                    }
                }
            }
            Section("Archive") {
                LabeledContent("Days written", value: "\(stats.days)")
                LabeledContent("Entries", value: "\(stats.entries)")
                LabeledContent("Words", value: "\(stats.words)")
                if stats.entries > 0 {
                    LabeledContent("Avg per entry", value: "\(stats.words / stats.entries) words")
                }
            }
            Section("Sizes") {
                LabeledContent("Text", value: Self.size(stats.bytes))
                LabeledContent("Images", value: Self.size(stats.imageBytes))
                LabeledContent("Video", value: Self.size(stats.videoBytes))
                LabeledContent("Audio", value: Self.size(stats.audioBytes))
                if stats.otherMediaBytes > 0 {
                    LabeledContent("Other media", value: Self.size(stats.otherMediaBytes))
                }
                LabeledContent("Total", value: Self.size(stats.bytes + stats.mediaBytes))
            }
            Section("Sizes by location") {
                LabeledContent("Inbox", value: Self.size(stats.inboxBytes))
                LabeledContent("Archive", value: Self.size(stats.archiveBytes))
                LabeledContent("Media", value: Self.size(stats.mediaBytes))
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
            let years = store.yearsWithEntries()
            if !years.isEmpty {
                Section {
                    Button {
                        showingTrends = true
                    } label: {
                        HStack {
                            Label("Trends", systemImage: "chart.xyaxis.line")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("The year day by day, words per month, and the top tags over time.")
                }
                Section {
                    ForEach(years, id: \.self) { year in
                        Button {
                            reviewYear = ReviewYear(year: year)
                        } label: {
                            HStack {
                                Text("\(year) in review")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Year in review")
                } footer: {
                    Text("Words, streaks, top tags and the busiest day — with a shareable card.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Stats")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: store.revision) { stats = store.stats() }
        .sheet(item: $reviewYear) { item in
            YearReviewSheet(year: item.year)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingTrends) {
            TrendsView()
                .environmentObject(store)
        }
    }
}
