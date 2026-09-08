//
//  JournalStore.swift
//  Wander
//
//  Reads and writes a jnl-format journal folder — the same layout Nook and the
//  `jnl` CLI use, so all three can share one folder:
//
//      <base>/journal/YYYY/MM/DD.md   one file per day, entries appended
//      <base>/inbox.md                unfiled drafts (read, never written here)
//
//  This is a deliberately small store: parse on load, rewrite one day file per
//  save. Nook's own store does the heavy lifting (sync, media, importers);
//  Wander only needs the writing surface.
//

import Foundation
import AppKit

/// The three views onto the same folder. Journal is what has been filed,
/// Inbox is what hasn't, Starred cuts across both.
enum Page: String, CaseIterable, Hashable {
    case journal, inbox, starred

    var label: String {
        switch self {
        case .journal:  return "Journal"
        case .inbox:    return "Inbox"
        case .starred:  return "Starred"
        }
    }
}

@MainActor
final class JournalStore: ObservableObject {

    enum SaveState: Equatable {
        case idle
        case editing
        case saved(Date)
        case failed(String)
    }

    @Published private(set) var entries: [Entry] = []      // newest first
    @Published var selection: Entry.ID?
    @Published var query: String = ""
    @Published private(set) var page: Page = .journal
    @Published private(set) var saveState: SaveState = .idle
    @Published private(set) var baseURL: URL

    /// The live text of the selected entry. The editor binds straight to these;
    /// they are folded back into `entries` (and the file) on the debounced save.
    @Published var draftTitle: String = ""
    @Published var draftBody: String = ""

    /// Bumped to ask the sidebar to take keyboard focus (⌘F).
    @Published var searchFocusRequest: Int = 0

    /// The entry a delete has been asked for; the window confirms before it goes.
    @Published var deletionCandidate: Entry?

    /// The entry whose date and time are being changed, if the sheet is open.
    @Published var reschedulingEntry: Entry?

    private var draftEntry: Entry?
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var lastFingerprint = ""

    private static let folderKey = "journalFolderPath"

    // MARK: Lifecycle

    init() {
        baseURL = Self.resolveBase()
        try? FileManager.default.createDirectory(
            at: baseURL.appendingPathComponent("journal", isDirectory: true),
            withIntermediateDirectories: true)
        reload()
        select(firstVisibleID)
    }

    /// The first entry on the page being shown — what to fall back to whenever
    /// a selection is lost, so the editor never holds an entry the index isn't
    /// listing.
    private var firstVisibleID: Entry.ID? {
        sections.flatMap(\.entries).first?.id
    }

    /// A remembered folder if the user picked one, else ~/Documents/Wander.
    /// Point it at a Nook or jnl folder and the entries are simply there.
    private static func resolveBase() -> URL {
        if let path = UserDefaults.standard.string(forKey: folderKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Wander", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Paths

    private var journalDir: URL { baseURL.appendingPathComponent("journal", isDirectory: true) }
    private var inboxURL: URL { baseURL.appendingPathComponent("inbox.md") }

    /// journal/YYYY/MM/DD.md for a "YYYY-MM-DD" date.
    private func dayFile(for date: String) -> URL? {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return nil }
        return journalDir.appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))
            .appendingPathComponent("\(parts[2]).md")
    }

    // MARK: Loading

    func reload() {
        let fm = FileManager.default
        var found: [Entry] = []

        if let content = try? String(contentsOf: inboxURL, encoding: .utf8) {
            found += JournalParser.parseEntries(content, source: inboxURL)
        }
        if let walker = fm.enumerator(at: journalDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "md" {
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                found += JournalParser.parseEntries(content, source: url)
            }
        }

        entries = JournalParser.sortedByTimestamp(found).reversed()
        lastFingerprint = Self.fingerprint(base: baseURL)

        // An unsaved new entry lives only in memory until it has text; keep it.
        if let draft = draftEntry, draft.source == nil, !entries.contains(where: { $0.id == draft.id }) {
            entries.insert(draft, at: 0)
        }
        if let selection, !entries.contains(where: { $0.id == selection }) {
            select(firstVisibleID)
        }
    }

    /// Cheap stat-only change detector, so a jnl or Nook edit made while Wander
    /// was in the background shows up on activation without a blind re-read.
    func reloadIfChanged() {
        guard !dirty else { return }
        let current = Self.fingerprint(base: baseURL)
        guard current != lastFingerprint else { return }
        let keep = selection
        reload()
        if let keep, entries.contains(where: { $0.id == keep }) { select(keep) }
    }

    nonisolated static func fingerprint(base: URL) -> String {
        let fm = FileManager.default
        var count = 0, size = 0
        var newest = 0.0
        func stat(_ url: URL) {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return }
            count += 1
            size += v.fileSize ?? 0
            newest = max(newest, v.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        stat(base.appendingPathComponent("inbox.md"))
        if let walker = fm.enumerator(at: base.appendingPathComponent("journal", isDirectory: true),
                                      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let url as URL in walker where url.pathExtension == "md" { stat(url) }
        }
        return "\(count)|\(size)|\(newest)"
    }

    // MARK: Selection and drafts

    func select(_ id: Entry.ID?) {
        guard id != selection || draftEntry == nil else { return }
        flush()
        selection = id
        let entry = entries.first { $0.id == id }
        draftEntry = entry
        draftTitle = entry?.displayTitle ?? ""
        draftBody = entry?.body ?? ""
        dirty = false
        saveState = .idle
    }

    var selectedEntry: Entry? { entries.first { $0.id == selection } }

    /// Switch page, keeping the open entry if it belongs there and taking the
    /// first of the new page if it doesn't.
    func show(_ page: Page) {
        guard page != self.page else { return }
        self.page = page
        let visible = sections.flatMap(\.entries)
        if let selection, visible.contains(where: { $0.id == selection }) { return }
        select(visible.first?.id)
    }

    /// Called by the editor on every keystroke; the write itself is debounced.
    /// The draft is compared against the entry rather than trusted, because
    /// loading a different entry also changes the bound text — an edit is only
    /// an edit when the text actually differs from what is filed.
    func edited() {
        guard let base = draftEntry else { return }
        guard draftTitle != base.displayTitle || draftBody != base.body else {
            saveTask?.cancel()
            dirty = false
            if saveState == .editing { saveState = .idle }
            return
        }
        dirty = true
        saveState = .editing
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Fold the draft back into the entry and rewrite its day file.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard dirty, let base = draftEntry else { return }
        dirty = false

        let revised = base.revised(title: draftTitle, body: draftBody)
        let isEmpty = revised.suffix.isEmpty && revised.body.isEmpty

        // Trailing whitespace alone can't cost a file rewrite.
        if revised.raw == base.raw, base.source != nil {
            saveState = .saved(Date())
            return
        }

        do {
            if isEmpty {
                // Never leave an empty stub on disk. If it was written earlier
                // (title typed, then deleted), take it back out of the file.
                if base.source != nil { try remove(base) }
                var carried = revised
                carried.source = nil
                replaceInMemory(base, with: carried)
                saveState = .idle
            } else {
                let written = try persist(revised, previous: base)
                replaceInMemory(base, with: written)
                saveState = .saved(Date())
            }
            lastFingerprint = Self.fingerprint(base: baseURL)
        } catch {
            dirty = true
            saveState = .failed(error.localizedDescription)
        }
    }

    private func replaceInMemory(_ old: Entry, with new: Entry) {
        if let i = entries.firstIndex(where: { $0.id == old.id }) {
            entries[i] = new
        } else {
            entries.insert(new, at: 0)
        }
        draftEntry = new
        if selection == old.id { selection = new.id }
    }

    // MARK: Writing

    /// Rewrite the day file that owns `entry`, replacing the entry with the
    /// same timestamp (or appending it). Returns the entry with its source set.
    @discardableResult
    private func persist(_ entry: Entry, previous: Entry?) throws -> Entry {
        guard let target = entry.source ?? previous?.source ?? dayFile(for: entry.date) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(existing)
        var day = JournalParser.parseEntries(existing, source: target)

        var stamped = entry
        stamped.source = target
        if let i = day.firstIndex(where: { $0.ts == entry.ts }) {
            day[i] = stamped
        } else {
            day.append(stamped)
        }

        let content = JournalParser.renderEntries(
            preamble: preamble, entries: JournalParser.sortedByTimestamp(day))
        try writeAtomically(content, to: target)
        return stamped
    }

    /// Take an entry out of its file, deleting the file if nothing is left.
    private func remove(_ entry: Entry) throws {
        guard let target = entry.source,
              let existing = try? String(contentsOf: target, encoding: .utf8) else { return }
        let preamble = JournalParser.leadingPreamble(existing)
        let day = JournalParser.parseEntries(existing, source: target)
            .filter { $0.ts != entry.ts }

        let content = JournalParser.renderEntries(preamble: preamble, entries: day)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: target)
        } else {
            try writeAtomically(content, to: target)
        }
    }

    private func writeAtomically(_ content: String, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".wander-\(UUID().uuidString).tmp")
        try content.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: Commands

    func newEntry() {
        flush()
        if page == .inbox { page = .journal }
        let entry = Entry.blank()
        entries.insert(entry, at: 0)
        selection = entry.id
        draftEntry = entry
        draftTitle = ""
        draftBody = ""
        dirty = false
        saveState = .idle
    }

    /// A draft: same as a new entry, but destined for inbox.md rather than a
    /// day file, so unfinished writing doesn't land in the dated record.
    func newDraft() {
        flush()
        page = .inbox
        var entry = Entry.blank()
        entry.source = inboxURL
        entries.insert(entry, at: 0)
        selection = entry.id
        draftEntry = entry
        draftTitle = ""
        draftBody = ""
        dirty = false
        saveState = .idle
    }

    func delete(_ entry: Entry) {
        saveTask?.cancel()
        dirty = false
        try? remove(entry)
        entries.removeAll { $0.id == entry.id }
        if selection == entry.id {
            draftEntry = nil
            select(firstVisibleID)
        }
        lastFingerprint = Self.fingerprint(base: baseURL)
    }

    func toggleStar(_ entry: Entry) {
        let flipped = entry.revised(title: entry.displayTitle,
                                    body: entry.body,
                                    starred: !entry.isStarred)
        guard flipped.suffix.isEmpty == false || flipped.body.isEmpty == false else { return }
        if let written = try? persist(flipped, previous: entry) {
            replaceInMemory(entry, with: written)
            if selection == written.id { draftEntry = written }
            saveState = .saved(Date())
        }
    }

    /// Move an entry to `target`, taking the timestamp `desired` — the one
    /// primitive behind retiming, filing and unfiling. A second already used in
    /// the target file is stepped past rather than overwritten.
    @discardableResult
    private func move(_ current: Entry, to target: URL, stamp desired: String) -> Bool {
        var stamp = desired
        if let content = try? String(contentsOf: target, encoding: .utf8) {
            var taken = Set(JournalParser.parseEntries(content).map(\.ts))
            if target == current.source { taken.remove(current.ts) }
            var moment = Formats.stamp.date(from: stamp) ?? Date()
            while taken.contains(stamp) {
                moment = moment.addingTimeInterval(1)
                stamp = Formats.stamp.string(from: moment)
            }
        }

        var head = "[\(stamp)]"
        if !current.suffix.isEmpty { head += " " + current.suffix }
        let moved = Entry(date: String(stamp.prefix(10)), ts: stamp,
                          suffix: current.suffix, body: current.body,
                          raw: current.body.isEmpty ? head : head + "\n" + current.body,
                          source: target)

        do {
            try remove(current)
            let written = try persist(moved, previous: nil)
            entries.removeAll { $0.id == current.id }
            entries.append(written)
            entries = JournalParser.sortedByTimestamp(entries).reversed()
            selection = written.id
            draftEntry = written
            draftTitle = written.displayTitle
            draftBody = written.body
            dirty = false
            saveState = .saved(Date())
            lastFingerprint = Self.fingerprint(base: baseURL)
            return true
        } catch {
            saveState = .failed(error.localizedDescription)
            return false
        }
    }

    /// Change an entry's timestamp. For a filed entry the date is the filename,
    /// so this moves it between day files. A draft stays in inbox.md, which
    /// isn't dated — retiming there must not quietly file it.
    func reschedule(_ entry: Entry, to date: Date) {
        flush()
        let current = entries.first { $0.id == entry.id } ?? entry
        let stamp = Formats.stamp.string(from: date)
        guard stamp != current.ts else { return }
        let day = String(stamp.prefix(10))
        guard let target = isUnfiled(current) ? inboxURL : dayFile(for: day) else { return }
        move(current, to: target, stamp: stamp)
    }

    /// Draft ▸ journal: inbox.md into journal/YYYY/MM/DD.md, by its own date.
    func file(_ entry: Entry) {
        flush()
        let current = entries.first { $0.id == entry.id } ?? entry
        guard isUnfiled(current) || current.source == nil else { return }
        guard let target = dayFile(for: current.date) else { return }
        move(current, to: target, stamp: current.ts)
    }

    /// Journal ▸ draft: back to inbox.md, to be worked on and filed again.
    func unfile(_ entry: Entry) {
        flush()
        let current = entries.first { $0.id == entry.id } ?? entry
        guard !isUnfiled(current) else { return }
        move(current, to: inboxURL, stamp: current.ts)
    }

    /// Toggle whichever way the entry currently sits, and follow it to the
    /// page it now lives on so the open entry doesn't vanish from the index.
    func toggleFiling(_ entry: Entry) {
        let wasUnfiled = isUnfiled(entry)
        wasUnfiled ? file(entry) : unfile(entry)
        if page == .journal && !wasUnfiled { page = .inbox }
        else if page == .inbox && wasUnfiled { page = .journal }
    }

    /// Where a retimed entry would end up — shown in the sheet before the move.
    func destinationName(for entry: Entry, at date: Date) -> String {
        if entry.source == inboxURL { return "inbox.md" }
        let day = Formats.day.string(from: date)
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return "journal/\(parts[0])/\(parts[1])/\(parts[2]).md"
    }

    /// True when the entry sits in inbox.md rather than a dated day file.
    func isUnfiled(_ entry: Entry) -> Bool { entry.source == inboxURL }

    var selectedIsUnfiled: Bool { selectedEntry.map(isUnfiled) ?? false }

    func toggleStarOnSelection() {
        flush()
        guard let entry = selectedEntry else { return }
        toggleStar(entry)
    }

    // MARK: Folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a journal folder — a Nook or jnl folder works as-is."
        panel.directoryURL = baseURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        flush()
        UserDefaults.standard.set(url.path, forKey: Self.folderKey)
        baseURL = url
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent("journal", isDirectory: true),
            withIntermediateDirectories: true)
        draftEntry = nil
        selection = nil
        reload()
        select(firstVisibleID)
    }


    func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([baseURL])
    }

    func reveal(_ entry: Entry) {
        flush()
        guard let url = (entries.first { $0.id == entry.id } ?? entry).source else {
            return revealFolder()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copy an entry's markdown — header line included, so it can be pasted
    /// straight into another jnl file.
    func copyMarkdown(_ entry: Entry) {
        flush()
        let current = entries.first { $0.id == entry.id } ?? entry
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current.raw, forType: .string)
    }

    /// Move the selection through the filtered list: -1 newer, +1 older.
    func step(_ delta: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        guard let current = list.firstIndex(where: { $0.id == selection }) else {
            return select(list.first?.id)
        }
        let next = min(max(current + delta, 0), list.count - 1)
        select(list[next].id)
    }

    // MARK: Derived

    var filtered: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.raw.lowercased().contains(q)
        }
    }

    /// Sidebar sections for the current page. The journal and the starred cut
    /// are set by month; the inbox is one undated run, because inbox.md is.
    var sections: [(title: String, entries: [Entry], inbox: Bool)] {
        switch page {
        case .journal:
            return months(of: filtered.filter { !isUnfiled($0) }).map { ($0.title, $0.entries, false) }
        case .inbox:
            let drafts = filtered.filter(isUnfiled)
            return drafts.isEmpty ? [] : [("Inbox", drafts, true)]
        case .starred:
            return months(of: filtered.filter(\.isStarred)).map { ($0.title, $0.entries, false) }
        }
    }

    /// Entries grouped into month sections, newest month first.
    func months(of list: [Entry]) -> [(title: String, entries: [Entry])] {
        var order: [String] = []
        var buckets: [String: [Entry]] = [:]
        for entry in list {
            let key = String(entry.date.prefix(7))   // YYYY-MM
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map { key in
            let title = Formats.day.date(from: key + "-01").map { Formats.month.string(from: $0) } ?? key
            return (title, buckets[key] ?? [])
        }
    }

    /// Badge counts for the masthead's page switches.
    func count(of page: Page) -> Int {
        switch page {
        case .journal:  return entries.filter { !isUnfiled($0) }.count
        case .inbox:    return entries.filter(isUnfiled).count
        case .starred:  return entries.filter(\.isStarred).count
        }
    }

    /// Days that already hold at least one entry — the calendar dots them.
    var datesWithEntries: Set<String> { Set(entries.map(\.date)) }

    var totalWords: Int { entries.reduce(0) { $0 + $1.wordCount } }

    var entriesThisMonth: Int {
        let prefix = String(Formats.day.string(from: Date()).prefix(7))
        return entries.filter { $0.date.hasPrefix(prefix) }.count
    }

    /// Consecutive days written, counting back from today (or yesterday, so a
    /// streak isn't reported broken before the day's first entry).
    var streak: Int {
        let days = Set(entries.map(\.date))
        guard !days.isEmpty else { return 0 }
        let cal = Calendar.current
        var cursor = Date()
        if !days.contains(Formats.day.string(from: cursor)) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
            guard days.contains(Formats.day.string(from: cursor)) else { return 0 }
        }
        var count = 0
        while days.contains(Formats.day.string(from: cursor)) {
            count += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Position of the selected entry in the whole journal, oldest = 1 — the
    /// masthead's "No. 014".
    var selectedNumber: Int? {
        guard let selection, let i = entries.firstIndex(where: { $0.id == selection }) else { return nil }
        return entries.count - i
    }
}
