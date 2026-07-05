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

@MainActor
final class JournalStore: ObservableObject {

    // MARK: Published state
    @Published private(set) var inboxDrafts: [Entry] = []
    /// Filed days, newest first (e.g. "2026-05-10").
    @Published private(set) var archiveDates: [String] = []
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
    /// Empty for now — no config UI yet (deferred).
    var splitTags: [String] = []

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
        loadArchiveDates()
    }

    private func loadInbox() {
        guard let inboxURL, let content = try? String(contentsOf: inboxURL, encoding: .utf8) else {
            inboxDrafts = []
            return
        }
        inboxDrafts = JournalParser.parseEntries(content)
    }

    private func loadArchiveDates() {
        archiveDates = allJournalFiles().map(fileToDate).sorted(by: >)
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

    // MARK: Draft creation (jnl cmdNew)

    /// Append a new draft to the inbox. `title` becomes the header suffix; empty
    /// title is fine. No-op if both title and body are blank.
    func addDraft(title: String, body: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(trimmedTitle.isEmpty && trimmedBody.isEmpty), let inboxURL else { return }

        var header = "[\(Self.nowTS())]"
        if !trimmedTitle.isEmpty { header += " " + trimmedTitle }
        let raw = JournalParser.trimRightNewlines(header + "\n" + trimmedBody)
        var normalised = raw + "\n"

        let existing = (try? String(contentsOf: inboxURL, encoding: .utf8)) ?? ""
        if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalised = JournalParser.trimRightNewlines(existing) + "\n\n" + normalised
        }
        try? writeFile(inboxURL, normalised)
        loadInbox()
    }

    // MARK: Review actions (jnl cmdReview)

    /// File a draft into its day's journal file (or a split-tag file), then
    /// remove it from the inbox. Returns the label it was filed under.
    @discardableResult
    func fileDraft(_ entry: Entry) -> String? {
        guard let label = try? fileEntry(entry) else { return nil }
        removeFromInbox(entry)
        loadInbox()
        loadArchiveDates()
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
        loadArchiveDates()
    }

    /// Delete a filed entry from its day file (removes the file if now empty).
    func deleteFiledEntry(date: String, entry: Entry) {
        guard let url = journalFileURL(for: date) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        entries.removeAll { $0.raw == entry.raw }
        try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))
        loadArchiveDates()
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
