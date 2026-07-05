//
//  JournalStore.swift
//  Jibber
//
//  The app's data layer. Owns the on-disk journal (iCloud ubiquity container
//  when available, local Documents otherwise) and exposes the inbox + archive
//  to SwiftUI. Filing / sorting / atomic writes are ported from ~/Code/jnl/main.go.
//
//  Storage layout (identical to jnl, so the `jnl` CLI can point JNL_DIR here):
//      <base>/inbox.md                     — unsorted drafts
//      <base>/journal/YYYY/MM/DD.md         — filed entries, one file per day
//

import Foundation
import Combine
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class JournalStore: ObservableObject {

    // MARK: Published state
    @Published private(set) var inboxDrafts: [Entry] = []
    /// Filed days with a lightweight summary, newest first.
    @Published private(set) var archiveDays: [ArchiveDay] = []

    struct ArchiveDay: Identifiable, Hashable {
        let date: String     // "YYYY-MM-DD"
        let count: Int
        let preview: String
        var id: String { date }
        var year: String { String(date.prefix(4)) }
    }
    /// Where data actually lives once resolved; nil while still resolving.
    @Published private(set) var baseURL: URL?
    /// Where journal data currently lives.
    @Published private(set) var storageMode: StorageMode = .local

    enum StorageMode: Equatable {
        case custom, iCloud, local
        var label: String {
            switch self {
            case .custom: return "Custom folder"
            case .iCloud: return "iCloud Drive"
            case .local:  return "On this device"
            }
        }
    }

    // MARK: Config
    /// Tags routed to their own `<base>/<tag>.md` file (jnl JNL_SPLIT_TAGS).
    /// Read live from the "splitTags" preference (space/comma separated).
    var splitTags: [String] {
        let raw = UserDefaults.standard.string(forKey: "splitTags") ?? ""
        return raw.split(whereSeparator: { $0 == " " || $0 == "," })
            .map { let s = String($0); return s.hasPrefix("@") ? s : "@" + s }
    }

    private let fm = FileManager.default

    // Passing nil to the ubiquity API uses the app's first/default container.
    private let ubiquityContainerID: String? = nil
    private let bookmarkKey = "customFolderBookmark"
    /// Retained so we can release security-scoped access when the folder changes.
    private var securityScopedURL: URL?

    init() {
        resolveBaseAndReload()
    }

    // MARK: Base directory resolution (custom folder → iCloud → local)

    struct Resolved { let url: URL; let mode: StorageMode; let scoped: Bool }

    private func resolveBaseAndReload() {
        // Both the bookmark resolve and forUbiquityContainerIdentifier can block,
        // so do them off the main actor.
        let containerID = ubiquityContainerID
        let bookmark = UserDefaults.standard.data(forKey: bookmarkKey)
        Task { [weak self] in
            let resolved = await Task.detached(priority: .userInitiated) {
                Self.resolveBase(bookmark: bookmark, containerID: containerID)
            }.value
            self?.applyResolved(resolved)
        }
    }

    private func applyResolved(_ resolved: Resolved) {
        if let old = securityScopedURL {
            old.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
        if resolved.scoped, resolved.url.startAccessingSecurityScopedResource() {
            securityScopedURL = resolved.url
        }
        baseURL = resolved.url
        storageMode = resolved.mode
        try? fm.createDirectory(at: resolved.url.appendingPathComponent("journal"),
                                withIntermediateDirectories: true)
        reload()
    }

    /// Resolution order: a user-chosen custom folder (security-scoped bookmark),
    /// else the iCloud ubiquity container's Documents folder, else a local
    /// Documents/Jibber folder. The chosen folder is the journal base directly —
    /// same layout as jnl's `JNL_DIR`, so pointing it at an existing jnl notes
    /// folder just works.
    private nonisolated static func resolveBase(bookmark: Data?, containerID: String?) -> Resolved {
        let fm = FileManager.default
        if let data = bookmark, let url = FolderAccess.resolve(data) {
            return Resolved(url: url, mode: .custom, scoped: true)
        }
        if let container = fm.url(forUbiquityContainerIdentifier: containerID) {
            let docs = container.appendingPathComponent("Documents", isDirectory: true)
            try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
            return Resolved(url: docs, mode: .iCloud, scoped: false)
        }
        let local = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jibber", isDirectory: true)
        try? fm.createDirectory(at: local, withIntermediateDirectories: true)
        return Resolved(url: local, mode: .local, scoped: false)
    }

    /// Human-readable location for display (e.g. "…/Notes" or an iCloud path).
    var storagePath: String { baseURL?.path ?? "Resolving…" }

    // MARK: Choosing the journal folder

    /// Point Jibber at a user-selected folder (from a file importer). It becomes
    /// the journal base and is remembered across launches via a bookmark.
    func setCustomFolder(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = FolderAccess.makeBookmark(url) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        resolveBaseAndReload()
    }

    /// Forget the custom folder and fall back to iCloud / local.
    func useDefaultFolder() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        resolveBaseAndReload()
    }

    // MARK: Paths
    private var inboxURL: URL? { baseURL?.appendingPathComponent("inbox.md") }
    private var journalDirURL: URL? { baseURL?.appendingPathComponent("journal", isDirectory: true) }

    /// journal/YYYY/MM/DD.md for a "YYYY-MM-DD" date.
    private func journalFileURL(for date: String) -> URL? {
        let parts = date.split(separator: "-")
        guard parts.count == 3, let dir = journalDirURL else { return nil }
        return dir.appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))
            .appendingPathComponent("\(parts[2]).md")
    }

    // MARK: Loading

    func reload() {
        loadInbox()
        loadArchive()
    }

    private func loadInbox() {
        guard let inboxURL, let content = try? String(contentsOf: inboxURL, encoding: .utf8) else {
            inboxDrafts = []
            return
        }
        inboxDrafts = JournalParser.parseEntries(content)
    }

    /// Build the archive index once per reload: each day's entry count + a short
    /// preview, newest day first (so the Archive list needs no per-render file reads).
    private func loadArchive() {
        let files = allJournalFiles().sorted { fileToDate($0) > fileToDate($1) }
        archiveDays = files.map { url in
            let entries = JournalParser.parseEntries(readString(url))
            return ArchiveDay(date: fileToDate(url),
                              count: entries.count,
                              preview: entries.first?.preview ?? "")
        }
    }

    /// All journal day-file URLs (recursive walk of journal/).
    private func allJournalFiles() -> [URL] {
        guard let dir = journalDirURL,
              let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var files: [URL] = []
        for case let url as URL in en where url.pathExtension == "md" {
            files.append(url)
        }
        return files
    }

    /// journal/2026/05/10.md → "2026-05-10".
    private func fileToDate(_ url: URL) -> String {
        let day = url.deletingPathExtension().lastPathComponent
        let month = url.deletingLastPathComponent().lastPathComponent
        let year = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return "\(year)-\(month)-\(day)"
    }

    /// Entries filed on a given day, chronological.
    func entries(for date: String) -> [Entry] {
        guard let url = journalFileURL(for: date),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return JournalParser.parseEntries(content)
    }

    // MARK: Tags (jnl cmdTags / cmdTag)

    /// All `@tags` across the archive + inbox with usage counts, sorted by count
    /// (desc) then name. Mirrors jnl `tags`.
    func tagCounts() -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for url in allJournalFiles() {
            for t in JournalParser.splitTags(readString(url)) { counts[t, default: 0] += 1 }
        }
        if let inboxURL { for t in JournalParser.splitTags(readString(inboxURL)) { counts[t, default: 0] += 1 } }
        return counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    /// Filed entries containing a tag, newest day first. Mirrors jnl `tag <name>`.
    func entries(taggedWith name: String) -> [(date: String, entry: Entry)] {
        let tag = name.hasPrefix("@") ? name : "@" + name
        var result: [(String, Entry)] = []
        for url in allJournalFiles().sorted(by: { fileToDate($0) > fileToDate($1) }) {
            let date = fileToDate(url)
            for e in JournalParser.parseEntries(readString(url)) where e.raw.contains(tag) {
                result.append((date, e))
            }
        }
        return result
    }

    private func readString(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: Split journals (JNL_SPLIT_TAGS files: <base>/<tag>.md)

    struct SplitJournal: Identifiable, Hashable {
        let name: String
        let count: Int
        var id: String { name }
    }

    private let reservedFiles: Set<String> = ["inbox.md", "transfer.md", "export.md", "jibber-export.md"]

    /// Top-level `<base>/<name>.md` files (i.e. tag-routed split journals), each
    /// with its entry count. The date journal (journal/) and reserved files are excluded.
    func splitJournals() -> [SplitJournal] {
        guard let base = baseURL,
              let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        else { return [] }
        return items
            .filter { $0.pathExtension == "md" && !reservedFiles.contains($0.lastPathComponent) }
            .map { SplitJournal(name: $0.deletingPathExtension().lastPathComponent,
                                count: JournalParser.parseEntries(readString($0)).count) }
            .filter { $0.count > 0 }
            .sorted { $0.name < $1.name }
    }

    private func splitJournalURL(_ name: String) -> URL? {
        baseURL?.appendingPathComponent("\(name).md")
    }

    func entries(inJournal name: String) -> [Entry] {
        guard let url = splitJournalURL(name) else { return [] }
        return JournalParser.parseEntries(readString(url))
    }

    func updateJournalEntry(name: String, original: Entry, newText: String) {
        guard let url = splitJournalURL(name) else { return }
        let content = readString(url)
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        guard let idx = entries.firstIndex(where: { $0.raw == original.raw }) else { return }
        entries.replaceSubrange(idx...idx, with: JournalParser.parseEntries(newText))
        try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))
        loadArchive()
    }

    func deleteJournalEntry(name: String, entry: Entry) {
        guard let url = splitJournalURL(name) else { return }
        let content = readString(url)
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        entries.removeAll { $0.raw == entry.raw }
        try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))
        loadArchive()
    }

    // MARK: Composer autosave (jnl cmdNew)

    /// Build an Entry from title + timestamp + body in the jnl header format:
    /// title lands on the header line (`[ts] title`), body on the lines below.
    static func makeEntry(timestamp: String, title: String, body: String) -> Entry {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = JournalParser.trimRightNewlines(body)
        let raw: String
        if !t.isEmpty && !b.isEmpty { raw = "[\(timestamp)] \(t)\n\(b)" }
        else if !t.isEmpty         { raw = "[\(timestamp)] \(t)" }
        else                       { raw = "[\(timestamp)]\n\(b)" }
        return Entry(date: String(timestamp.prefix(10)), ts: timestamp, suffix: t,
                     body: b.trimmingCharacters(in: .whitespacesAndNewlines), raw: raw)
    }

    /// Create or update the composer's working draft. `previous` is the last
    /// timestamp this draft was saved under (so changing the date picker moves the
    /// same draft rather than orphaning it). Empty title+body removes the draft.
    func upsertDraft(previous: String?, timestamp: String, title: String, body: String) {
        guard let inboxURL else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = JournalParser.trimRightNewlines(body).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty && b.isEmpty {
            if let previous { removeDraft(timestamp: previous) }
            return
        }
        let content = (try? String(contentsOf: inboxURL, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        if let previous, previous != timestamp { drafts.removeAll { $0.ts == previous } }
        let entry = Self.makeEntry(timestamp: timestamp, title: title, body: body)
        if let idx = drafts.firstIndex(where: { $0.ts == timestamp }) {
            drafts[idx] = entry
        } else {
            drafts.append(entry)
        }
        try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))
        loadInbox()
    }

    func removeDraft(timestamp: String) {
        guard let inboxURL else { return }
        let content = (try? String(contentsOf: inboxURL, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        let before = drafts.count
        drafts.removeAll { $0.ts == timestamp }
        guard drafts.count != before else { return }
        try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))
        loadInbox()
    }

    /// Import pasted text as separate inbox drafts (jnl `transfer` parsing): if it
    /// contains `[timestamp]` headers each becomes its own draft; otherwise each
    /// blank-line-separated paragraph becomes a draft stamped with the current time.
    /// Returns how many drafts were added.
    @discardableResult
    func importDrafts(from text: String) -> Int {
        guard let inboxURL else { return 0 }
        let imported = parseImport(text)
        guard !imported.isEmpty else { return 0 }
        let content = (try? String(contentsOf: inboxURL, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        drafts.append(contentsOf: imported)
        try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))
        loadInbox()
        return imported.count
    }

    // MARK: Headless add (App Intents)

    /// Append a draft to the inbox from outside the UI (Shortcuts/Siri/Spotlight).
    /// Resolves the journal folder exactly as the app does. Returns false if both
    /// title and body are empty.
    static func quickAddDraft(title: String, body: String) throws -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(t.isEmpty && b.isEmpty) else { return false }

        let resolved = resolveBase(bookmark: UserDefaults.standard.data(forKey: "customFolderBookmark"),
                                   containerID: nil)
        let base = resolved.url
        let started = resolved.scoped && base.startAccessingSecurityScopedResource()
        defer { if started { base.stopAccessingSecurityScopedResource() } }

        let inbox = base.appendingPathComponent("inbox.md")
        let entry = makeEntry(timestamp: nowTS(), title: t, body: b)
        var out = JournalParser.trimRightNewlines(entry.raw) + "\n"
        let existing = (try? String(contentsOf: inbox, encoding: .utf8)) ?? ""
        if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out = JournalParser.trimRightNewlines(existing) + "\n\n" + out
        }
        try atomicWrite(inbox, out)
        return true
    }

    /// Number of drafts currently in the inbox (headless — for App Intents).
    static func inboxDraftCount() -> Int {
        let resolved = resolveBase(bookmark: UserDefaults.standard.data(forKey: "customFolderBookmark"),
                                   containerID: nil)
        let base = resolved.url
        let started = resolved.scoped && base.startAccessingSecurityScopedResource()
        defer { if started { base.stopAccessingSecurityScopedResource() } }
        let inbox = base.appendingPathComponent("inbox.md")
        let content = (try? String(contentsOf: inbox, encoding: .utf8)) ?? ""
        return JournalParser.parseEntries(content).count
    }

    /// Atomic write usable off the main actor (temp-file + rename).
    nonisolated static func atomicWrite(_ url: URL, _ content: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".jibber-\(UUID().uuidString).tmp")
        try Data(content.utf8).write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        try fm.moveItem(at: tmp, to: url)
    }

    private func parseImport(_ text: String) -> [Entry] {
        let parsed = JournalParser.parseEntries(text)
        if !parsed.isEmpty { return parsed }
        // No [timestamp] headers → there's nothing to split; treat the whole
        // thing (paragraphs and all) as a single draft.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [Self.makeEntry(timestamp: Self.nowTS(), title: "", body: trimmed)]
    }

    // MARK: Review actions (jnl cmdReview)

    /// File a draft into its day's journal file (or a split-tag file), then
    /// remove it from the inbox. Returns the label it was filed under.
    @discardableResult
    func fileDraft(_ entry: Entry) -> String? {
        guard let label = try? fileEntry(entry) else { return nil }
        removeFromInbox(entry)
        loadInbox()
        loadArchive()
        return label
    }

    func deleteDraft(_ entry: Entry) {
        removeFromInbox(entry)
        loadInbox()
    }

    /// Replace a draft's text (from the editor) and persist the inbox.
    func updateDraft(_ entry: Entry, newText: String) {
        guard let inboxURL else { return }
        let content = (try? String(contentsOf: inboxURL, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        guard let idx = drafts.firstIndex(where: { $0.id == entry.id })
                ?? drafts.firstIndex(where: { $0.raw == entry.raw }) else { return }
        // Re-parse the edited text; it may yield 0..n entries.
        let parsed = JournalParser.parseEntries(newText)
        drafts.replaceSubrange(idx...idx, with: parsed)
        try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))
        loadInbox()
    }

    /// Sort the inbox into date order in place (jnl cmdSort).
    func sortInbox() {
        guard let inboxURL else { return }
        let content = (try? String(contentsOf: inboxURL, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        let entries = JournalParser.parseEntries(content)
        guard entries.count >= 2 else { return }
        let sorted = JournalParser.sortedByTimestamp(entries)
        try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: sorted))
        loadInbox()
    }

    // MARK: Filed-entry editing (archive)

    /// Replace a filed entry within its day file. Matches the original entry by
    /// its raw text. Re-parses `newText` (0..n entries) in its place. Removes the
    /// day file if it ends up empty.
    func updateFiledEntry(date: String, original: Entry, newText: String) {
        guard let url = journalFileURL(for: date) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        guard let idx = entries.firstIndex(where: { $0.raw == original.raw }) else { return }
        entries.replaceSubrange(idx...idx, with: JournalParser.parseEntries(newText))
        try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))
        loadArchive()
    }

    /// Delete a filed entry from its day file (removes the file if now empty).
    func deleteFiledEntry(date: String, entry: Entry) {
        guard let url = journalFileURL(for: date) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        entries.removeAll { $0.raw == entry.raw }
        try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))
        loadArchive()
    }

    // MARK: Filing internals (jnl fileDraft / splitTagTarget)

    /// Append one entry to its destination file. Throws on empty entry / IO error.
    private func fileEntry(_ e: Entry) throws -> String {
        if e.body.isEmpty && e.suffix.isEmpty {
            throw JournalError.nothingToFile
        }
        let dest: URL
        let label: String
        if let (tag, url) = splitTagTarget(e.raw) {
            dest = url; label = tag
        } else {
            let date = e.date.isEmpty ? Self.nowDate() : e.date
            guard let url = journalFileURL(for: date) else { throw JournalError.badPath }
            dest = url; label = date
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var out = ""
        if let existing = try? String(contentsOf: dest, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out = existing
            if !out.hasSuffix("\n\n") {
                out += out.hasSuffix("\n") ? "\n" : "\n\n"
            }
        }
        if !e.suffix.isEmpty && !e.body.isEmpty {
            out += "[\(e.ts)] \(e.suffix)\n\(e.body)\n"
        } else if !e.suffix.isEmpty {
            out += "[\(e.ts)] \(e.suffix)\n"
        } else {
            out += "[\(e.ts)]\n\(e.body)\n"
        }
        try writeFile(dest, out)
        return label
    }

    /// If the entry's text contains a configured split tag, return (tag, file).
    private func splitTagTarget(_ raw: String) -> (tag: String, url: URL)? {
        guard let base = baseURL, !splitTags.isEmpty else { return nil }
        let present = Set(JournalParser.splitTags(raw))
        for t in splitTags {
            let tag = t.hasPrefix("@") ? t : "@" + t
            if present.contains(tag) {
                let name = String(tag.dropFirst())
                return (tag, base.appendingPathComponent("\(name).md"))
            }
        }
        return nil
    }

    private func removeFromInbox(_ entry: Entry) {
        guard let inboxURL else { return }
        let content = (try? String(contentsOf: inboxURL, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        if let idx = drafts.firstIndex(where: { $0.id == entry.id })
            ?? drafts.firstIndex(where: { $0.raw == entry.raw }) {
            drafts.remove(at: idx)
        }
        try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))
    }

    // MARK: Search (jnl cmdSearch)

    /// Filed entries whose text contains `query` (case-insensitive), newest first.
    func search(_ query: String) -> [(date: String, entry: Entry)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var result: [(String, Entry)] = []
        for url in allJournalFiles().sorted(by: { fileToDate($0) > fileToDate($1) }) {
            let date = fileToDate(url)
            for e in JournalParser.parseEntries(readString(url)) where e.raw.lowercased().contains(q) {
                result.append((date, e))
            }
        }
        return result
    }

    // MARK: Bulk filing (jnl transfer)

    /// File every inbox draft into the archive. Returns how many were filed.
    @discardableResult
    func fileAllDrafts() -> Int {
        var filed = 0
        for draft in inboxDrafts where (try? fileEntry(draft)) != nil { filed += 1 }
        // Clear the inbox (all filed).
        if let inboxURL { try? writeFile(inboxURL, "") }
        reload()
        return filed
    }

    // MARK: Random (jnl cmdRandom)

    func randomEntry() -> (date: String, entry: Entry)? {
        var all: [(String, Entry)] = []
        for url in allJournalFiles() {
            let date = fileToDate(url)
            for e in JournalParser.parseEntries(readString(url)) { all.append((date, e)) }
        }
        return all.randomElement()
    }

    // MARK: Export (jnl cmdExport)

    /// All filed entries combined into one markdown string, oldest day first.
    func exportMarkdown() -> String {
        let files = allJournalFiles().sorted { fileToDate($0) < fileToDate($1) }
        let parts = files.map { JournalParser.trimRightNewlines(readString($0)) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "" : parts.joined(separator: "\n\n") + "\n"
    }

    // MARK: Cleanup (jnl cmdCleanup)

    struct CleanupResult { var formatted = 0; var reordered = 0 }

    /// Standardise punctuation (… and straight quotes) and reorder each day's
    /// entries by timestamp. Returns how many files changed.
    @discardableResult
    func cleanup() -> CleanupResult {
        var res = CleanupResult()
        for url in allJournalFiles() {
            let orig = readString(url)
            let fixed = orig
                .replacingOccurrences(of: "...", with: "\u{2026}")
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .replacingOccurrences(of: "\u{201C}", with: "\"")
                .replacingOccurrences(of: "\u{201D}", with: "\"")
            if fixed != orig { res.formatted += 1 }

            let preamble = JournalParser.leadingPreamble(fixed)
            let entries = JournalParser.parseEntries(fixed)
            let sorted = JournalParser.sortedByTimestamp(entries)
            if entries.map(\.ts) != sorted.map(\.ts) { res.reordered += 1 }
            let rebuilt = JournalParser.renderEntries(preamble: preamble, entries: sorted)
            if rebuilt != orig { try? writeFile(url, rebuilt) }
        }
        loadArchive()
        return res
    }

    // MARK: Stats (jnl cmdStats)

    struct Stats {
        var days = 0, entries = 0, words = 0
        var currentStreak = 0, bestStreak = 0
        var longestDay = "", longestDayWords = 0
        var bytes = 0
        var inboxDrafts = 0, tags = 0, splitJournals = 0
    }

    /// Total size on disk of all markdown journal files (date journals, split
    /// journals, and the inbox) under the base folder.
    func journalBytes() -> Int {
        guard let base = baseURL,
              let en = fm.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        for case let url as URL in en where url.pathExtension == "md" {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    func stats() -> Stats {
        var s = Stats()
        var dates: [Date] = []
        for url in allJournalFiles() {
            let content = readString(url)
            let es = JournalParser.parseEntries(content)
            let w = content.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
            s.days += 1; s.entries += es.count; s.words += w
            if w > s.longestDayWords { s.longestDayWords = w; s.longestDay = fileToDate(url) }
            if let d = Self.dateFormatter.date(from: fileToDate(url)) { dates.append(d) }
        }
        dates.sort()
        // best streak
        var run = 0
        for (i, d) in dates.enumerated() {
            if i > 0, let prev = Calendar.current.date(byAdding: .day, value: 1, to: dates[i-1]),
               Calendar.current.isDate(prev, inSameDayAs: d) { run += 1 } else { run = 1 }
            s.bestStreak = max(s.bestStreak, run)
        }
        // current streak (back from today)
        let today = Calendar.current.startOfDay(for: Date())
        var cur = 0
        for i in stride(from: dates.count - 1, through: 0, by: -1) {
            let expected = Calendar.current.date(byAdding: .day, value: -cur, to: today)!
            if Calendar.current.isDate(dates[i], inSameDayAs: expected) { cur += 1 } else { break }
        }
        s.currentStreak = cur
        s.bytes = journalBytes()
        s.inboxDrafts = inboxDrafts.count
        s.tags = tagCounts().count
        s.splitJournals = splitJournals().count
        return s
    }

    #if os(macOS)
    /// Reveal the journal folder in Finder (jnl open).
    func revealInFinder() {
        if let baseURL { NSWorkspace.shared.activateFileViewerSelecting([baseURL]) }
    }
    #endif

    // MARK: Atomic write (jnl writeFile)

    /// Write via temp-file + rename so an interrupted write never truncates the
    /// user's only copy of their notes. An empty string removes the file.
    private func writeFile(_ url: URL, _ content: String) throws {
        if content.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".jibber-\(UUID().uuidString).tmp")
        try content.data(using: .utf8)!.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        try fm.moveItem(at: tmp, to: url)
    }

    // MARK: Time helpers

    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    static func nowTS() -> String { tsFormatter.string(from: Date()) }
    static func nowDate() -> String { dateFormatter.string(from: Date()) }
    /// Convert a Date (from the composer's date picker) to a jnl timestamp.
    static func ts(from date: Date) -> String { tsFormatter.string(from: date) }
    /// Parse a jnl timestamp back into a Date (for the composer's date picker).
    static func date(from ts: String) -> Date? { tsFormatter.date(from: ts) }

    enum JournalError: Error { case nothingToFile, badPath }
}

// MARK: - Security-scoped folder bookmarks (cross-platform)

/// Persists access to a user-chosen folder across launches. Under the sandbox a
/// picked folder is only reachable via a security-scoped bookmark.
enum FolderAccess {
    static func makeBookmark(_ url: URL) -> Data? {
        #if os(macOS)
        return try? url.bookmarkData(options: .withSecurityScope,
                                     includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try? url.bookmarkData(options: [],
                                     includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    static func resolve(_ data: Data) -> URL? {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        return try? URL(resolvingBookmarkData: data, options: options,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
