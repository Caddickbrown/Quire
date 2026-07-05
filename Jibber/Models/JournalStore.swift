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
    /// Bumped on every reload so views can cheaply observe "data changed".
    @Published private(set) var revision = 0
    @Published private(set) var archiveDays: [ArchiveDay] = []

    struct ArchiveDay: Identifiable, Hashable {
        let date: String     // "YYYY-MM-DD"
        let count: Int
        let preview: String
        var hasPhoto = false
        var hasVideo = false
        var hasAudio = false
        var id: String { date }
        var year: String { String(date.prefix(4)) }
    }

    struct SplitJournal: Identifiable, Hashable {
        let name: String
        let count: Int
        var id: String { name }
    }

    /// All `@tags` (archive + inbox) with counts, cached — built off-main on reload.
    @Published private(set) var tagCounts: [(tag: String, count: Int)] = []
    /// Tag-routed split journals, cached — built off-main on reload.
    @Published private(set) var splitJournals: [SplitJournal] = []
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

    // MARK: Backup

    private let backupBookmarkKey = "backupFolderBookmark"
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private func resolveBackupURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: backupBookmarkKey) else { return nil }
        return FolderAccess.resolve(data)
    }

    /// Display name of the chosen backup folder, or nil if none.
    var backupFolderName: String? { resolveBackupURL()?.lastPathComponent }
    /// Full path of the chosen backup folder, or nil if none.
    var backupFolderPath: String? { resolveBackupURL()?.path }

    func setBackupFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if let data = FolderAccess.makeBookmark(url) {
            UserDefaults.standard.set(data, forKey: backupBookmarkKey)
        }
    }

    /// Copy the whole journal folder into a timestamped subfolder of the backup
    /// location. Returns a user-facing result message.
    func backupNow() -> (ok: Bool, message: String) {
        guard let base = baseURL else { return (false, "No journal folder to back up.") }
        guard let backupBase = resolveBackupURL() else {
            return (false, "Choose a backup folder first.")
        }
        let ok = backupBase.startAccessingSecurityScopedResource()
        defer { if ok { backupBase.stopAccessingSecurityScopedResource() } }
        let name = "Jibber-Backup-\(Self.stampFormatter.string(from: Date()))"
        let dest = backupBase.appendingPathComponent(name)
        do {
            try fm.copyItem(at: base, to: dest)
            return (true, "Backed up to \(name).")
        } catch {
            return (false, "Backup failed: \(error.localizedDescription)")
        }
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
        revision &+= 1
        loadInbox()
        rebuildIndex()
    }

    private func loadInbox() {
        guard let inboxURL, let content = try? String(contentsOf: inboxURL, encoding: .utf8) else {
            inboxDrafts = []
            return
        }
        inboxDrafts = JournalParser.parseEntries(content)
    }

    struct BuiltIndex {
        var days: [ArchiveDay] = []
        var tags: [(tag: String, count: Int)] = []
        var splits: [SplitJournal] = []
    }

    /// Rebuild the archive/tags/split-journal index off the main thread and
    /// publish the results, so no view body ever does directory-wide file reads.
    private func rebuildIndex() {
        guard let base = baseURL else {
            archiveDays = []; tagCounts = []; splitJournals = []
            return
        }
        let inboxTags = inboxDrafts.flatMap { $0.tags }
        Task.detached(priority: .userInitiated) {
            let idx = Self.buildIndex(base: base)
            await MainActor.run {
                self.archiveDays = idx.days
                var map = Dictionary(uniqueKeysWithValues: idx.tags.map { ($0.tag, $0.count) })
                for t in inboxTags { map[t, default: 0] += 1 }
                self.tagCounts = map.map { (tag: $0.key, count: $0.value) }
                    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
                self.splitJournals = idx.splits
            }
        }
    }

    nonisolated private static let reservedFiles: Set<String> = ["inbox.md", "transfer.md", "export.md", "jibber-export.md"]

    nonisolated static func buildIndex(base: URL) -> BuiltIndex {
        let fm = FileManager.default
        var idx = BuiltIndex()

        // Date journals under journal/.
        var urls: [URL] = []
        let journalDir = base.appendingPathComponent("journal", isDirectory: true)
        if let en = fm.enumerator(at: journalDir, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.pathExtension == "md" { urls.append(u) }
        }
        urls.sort { staticFileToDate($0) > staticFileToDate($1) }
        var tagMap: [String: Int] = [:]
        for u in urls {
            let content = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            let entries = JournalParser.parseEntries(content)
            var day = ArchiveDay(date: staticFileToDate(u),
                                 count: entries.count,
                                 preview: entries.first?.preview ?? "")
            for path in mediaPaths(in: content) {
                switch MediaKind(path: path) {
                case .image: day.hasPhoto = true
                case .video: day.hasVideo = true
                case .audio: day.hasAudio = true
                }
            }
            idx.days.append(day)
            for t in JournalParser.splitTags(content) { tagMap[t, default: 0] += 1 }
        }

        // Split-tag journals (top-level <base>/<name>.md).
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for u in items where u.pathExtension == "md" && !reservedFiles.contains(u.lastPathComponent) {
                let entries = JournalParser.parseEntries((try? String(contentsOf: u, encoding: .utf8)) ?? "")
                if !entries.isEmpty {
                    idx.splits.append(SplitJournal(name: u.deletingPathExtension().lastPathComponent,
                                                   count: entries.count))
                }
            }
            idx.splits.sort { $0.name < $1.name }
        }

        idx.tags = tagMap.map { (tag: $0.key, count: $0.value) }
        return idx
    }

    nonisolated private static let mediaLinkRegex = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)

    /// Extract the paths from markdown media links in some content.
    nonisolated static func mediaPaths(in content: String) -> [String] {
        let ns = content as NSString
        return mediaLinkRegex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    nonisolated static func staticFileToDate(_ url: URL) -> String {
        let day = url.deletingPathExtension().lastPathComponent
        let month = url.deletingLastPathComponent().lastPathComponent
        let year = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        return "\(year)-\(month)-\(day)"
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

    /// All filed entries grouped by day, newest day first (each day chronological).
    func allEntriesByDay() -> [(date: String, entries: [Entry])] {
        allJournalFiles()
            .sorted { fileToDate($0) > fileToDate($1) }
            .map { (fileToDate($0), JournalParser.parseEntries(readString($0))) }
            .filter { !$0.1.isEmpty }
            .map { (date: $0.0, entries: $0.1) }
    }

    /// Entries filed on a given day, chronological.
    func entries(for date: String) -> [Entry] {
        guard let url = journalFileURL(for: date),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return JournalParser.parseEntries(content)
    }

    // MARK: Tags (jnl cmdTags / cmdTag)

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

    // MARK: Tag review (find near-duplicate tags, merge/rename)

    struct TagGroup: Identifiable, Sendable {
        let variants: [Variant]
        let caseOnly: Bool     // true = identical apart from case; false = 1-char apart
        /// Stable key so an "ignore" choice sticks regardless of ordering.
        var id: String { variants.map(\.tag).sorted().joined(separator: "|") }

        struct Variant: Sendable { let tag: String; let count: Int }
    }

    private let ignoredTagGroupsKey = "ignoredTagGroups"

    func ignoreTagGroup(_ group: TagGroup) {
        var ignored = UserDefaults.standard.stringArray(forKey: ignoredTagGroupsKey) ?? []
        if !ignored.contains(group.id) { ignored.append(group.id) }
        UserDefaults.standard.set(ignored, forKey: ignoredTagGroupsKey)
    }

    /// Compute the tag groups off the main thread (levenshtein clustering can be
    /// O(n²) over the tag set). Snapshot the inputs on the main actor first.
    func similarTagGroupsAsync() async -> [TagGroup] {
        let counts = tagCounts.map { TagGroup.Variant(tag: $0.tag, count: $0.count) }
        let ignored = Set(UserDefaults.standard.stringArray(forKey: ignoredTagGroupsKey) ?? [])
        return await Task.detached { Self.computeTagGroups(counts, ignored: ignored) }.value
    }

    /// Two tiers of possibly-duplicate tags: case-only variants (@tags/@Tags),
    /// then one-character-apart lookalikes (journaling/journalling — but also
    /// false friends like food/mood, which the user can ignore). Case-only first.
    nonisolated static func computeTagGroups(_ counts: [TagGroup.Variant], ignored: Set<String>) -> [TagGroup] {
        var order: [String] = [], buckets: [String: [TagGroup.Variant]] = [:]
        for item in counts {
            let key = item.tag.dropFirst().lowercased()
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }

        var groups: [TagGroup] = []
        // Tier 1: keys that cover more than one actual tag → only case differs.
        for key in order where (buckets[key]?.count ?? 0) > 1 {
            let variants = (buckets[key] ?? []).sorted { $0.count > $1.count }
            let g = TagGroup(variants: variants, caseOnly: true)
            if !ignored.contains(g.id) { groups.append(g) }
        }
        // Tier 2: distinct keys within one edit of each other.
        var used = Set<String>()
        for i in order.indices where !used.contains(order[i]) {
            var cluster = [order[i]]
            for j in order.indices where j > i && !used.contains(order[j]) {
                if min(order[i].count, order[j].count) >= 4,
                   levenshtein(order[i], order[j]) == 1 {
                    cluster.append(order[j])
                }
            }
            guard cluster.count > 1 else { continue }
            cluster.forEach { used.insert($0) }
            let variants = cluster.flatMap { buckets[$0] ?? [] }.sorted { $0.count > $1.count }
            let g = TagGroup(variants: variants, caseOnly: false)
            if !ignored.contains(g.id) { groups.append(g) }
        }
        return groups
    }

    nonisolated private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        var d = Array(0...b.count)
        for i in 1...a.count {
            var prev = d[0]; d[0] = i
            for j in 1...b.count {
                let temp = d[j]
                d[j] = a[i-1] == b[j-1] ? prev : min(prev, d[j], d[j-1]) + 1
                prev = temp
            }
        }
        return d[b.count]
    }

    /// Apply several tag renames in one pass over each file, reloading once.
    func mergeTags(_ merges: [(from: String, to: String)]) {
        let rules: [(NSRegularExpression, String)] = merges.compactMap { m in
            let oldName = m.from.hasPrefix("@") ? String(m.from.dropFirst()) : m.from
            let newTok = m.to.hasPrefix("@") ? m.to : "@" + m.to
            guard let re = try? NSRegularExpression(
                pattern: "@" + NSRegularExpression.escapedPattern(for: oldName) + "(?![A-Za-z0-9_-])"
            ) else { return nil }
            return (re, NSRegularExpression.escapedTemplate(for: newTok))
        }
        guard !rules.isEmpty else { return }
        func fix(_ url: URL?) {
            guard let url else { return }
            var s = readString(url)
            let orig = s
            for (re, tpl) in rules {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tpl)
            }
            if s != orig { try? writeFile(url, s) }
        }
        fix(inboxURL)
        for url in allJournalFiles() { fix(url) }
        for sj in splitJournals { fix(splitJournalURL(sj.name)) }
        reload()
    }

    /// Rename all occurrences of one @tag to another across inbox, journal, and
    /// split-journal files. Whole-token match, so @tag doesn't touch @tags.
    @discardableResult
    func renameTag(from old: String, to new: String) -> Int {
        let oldName = old.hasPrefix("@") ? String(old.dropFirst()) : old
        let newTok = new.hasPrefix("@") ? new : "@" + new
        guard let regex = try? NSRegularExpression(
            pattern: "@" + NSRegularExpression.escapedPattern(for: oldName) + "(?![A-Za-z0-9_-])"
        ) else { return 0 }
        let template = NSRegularExpression.escapedTemplate(for: newTok)

        var changed = 0
        func fix(_ url: URL?) {
            guard let url else { return }
            let s = readString(url)
            let r = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
            if r != s { try? writeFile(url, r); changed += 1 }
        }
        fix(inboxURL)
        for url in allJournalFiles() { fix(url) }
        for sj in splitJournals { fix(splitJournalURL(sj.name)) }
        reload()
        return changed
    }

    // MARK: Split journals (JNL_SPLIT_TAGS files: <base>/<tag>.md)

    private func splitJournalURL(_ name: String) -> URL? {
        baseURL?.appendingPathComponent("\(name).md")
    }

    func entries(inJournal name: String) -> [Entry] {
        guard let url = splitJournalURL(name) else { return [] }
        return JournalParser.parseEntries(readString(url))
    }

    func updateJournalEntry(name: String, original: Entry, newText: String, reindex: Bool = true) {
        guard let url = splitJournalURL(name) else { return }
        let content = readString(url)
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        guard let idx = entries.firstIndex(where: { $0.ts == original.ts }) ?? entries.firstIndex(where: { $0.raw == original.raw }) else { return }
        entries.replaceSubrange(idx...idx, with: JournalParser.parseEntries(newText))
        try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))
        if reindex { rebuildIndex() }
    }

    func deleteJournalEntry(name: String, entry: Entry) {
        guard let url = splitJournalURL(name) else { return }
        let content = readString(url)
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        entries.removeAll { $0.ts == entry.ts || $0.raw == entry.raw }
        try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))
        rebuildIndex()
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
    func upsertDraft(previous: String?, timestamp: String, title: String, body: String, reindex: Bool = true) {
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
        if reindex { loadInbox() }
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

    // MARK: Media assets (Obsidian-style: <base>/assets/<file>, markdown links)

    private var assetsDirURL: URL? { baseURL?.appendingPathComponent("assets", isDirectory: true) }

    /// Absolute URL for a relative asset path like "assets/foo.png".
    func assetURL(forRelative path: String) -> URL? {
        baseURL?.appendingPathComponent(path)
    }

    struct AssetItem: Identifiable, Hashable {
        let url: URL
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    /// All files in the assets folder (for the Assets browser).
    func allAssets() -> [AssetItem] {
        guard let dir = assetsDirURL,
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return items
            .filter { !$0.hasDirectoryPath }
            .map { AssetItem(url: $0) }
            .sorted { $0.name < $1.name }
    }

    func deleteAsset(_ url: URL) { try? fm.removeItem(at: url) }

    /// Total size on disk of everything in the assets folder.
    func assetsBytes() -> Int {
        guard let dir = assetsDirURL,
              let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        for case let url as URL in en where !url.hasDirectoryPath {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Asset files that no entry references any more (safe to delete).
    func orphanAssets() -> [URL] {
        let all = allAssets().map(\.url)
        guard !all.isEmpty else { return [] }
        var texts: [String] = []
        if let inboxURL { texts.append(readString(inboxURL)) }
        for url in allJournalFiles() { texts.append(readString(url)) }
        for sj in splitJournals { if let u = splitJournalURL(sj.name) { texts.append(readString(u)) } }
        let corpus = texts.joined(separator: "\n")
        return all.filter { !corpus.contains("assets/\($0.lastPathComponent)") }
    }

    @discardableResult
    func deleteOrphanAssets() -> Int {
        let orphans = orphanAssets()
        for url in orphans { deleteAsset(url) }
        if !orphans.isEmpty { rebuildIndex() }
        return orphans.count
    }

    /// Entries that reference an asset by file name (for "go to file").
    func usages(ofAsset fileName: String) -> [(entry: Entry, source: EntrySource)] {
        let needle = "assets/\(fileName)"
        var result: [(Entry, EntrySource)] = []
        for e in inboxDrafts where e.raw.contains(needle) { result.append((e, .inbox)) }
        for url in allJournalFiles() {
            let date = fileToDate(url)
            for e in JournalParser.parseEntries(readString(url)) where e.raw.contains(needle) {
                result.append((e, .archive(date: date)))
            }
        }
        for sj in splitJournals {
            for e in entries(inJournal: sj.name) where e.raw.contains(needle) {
                result.append((e, .journal(name: sj.name)))
            }
        }
        return result
    }

    #if os(macOS)
    func revealAsset(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    #endif

    /// Copy an existing file (e.g. a recorded video) into assets/ and return the
    /// relative path. Better than loading large media into memory.
    func importAsset(from url: URL) -> String? {
        guard let dir = assetsDirURL else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do { try fm.copyItem(at: url, to: dest); return "assets/\(dest.lastPathComponent)" }
        catch { return nil }
    }

    /// Save image data into the journal's assets folder and return the relative
    /// markdown-friendly path ("assets/<uuid>.<ext>"), or nil on failure.
    func saveAsset(_ data: Data, ext: String) -> String? {
        guard let dir = assetsDirURL else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(ext.lowercased())"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            return "assets/\(name)"
        } catch {
            return nil
        }
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
        rebuildIndex()
        return label
    }

    func deleteDraft(_ entry: Entry) {
        removeFromInbox(entry)
        loadInbox()
    }

    /// Replace a draft's text (from the editor) and persist the inbox.
    func updateDraft(_ entry: Entry, newText: String, reindex: Bool = true) {
        guard let inboxURL else { return }
        let content = (try? String(contentsOf: inboxURL, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var drafts = JournalParser.parseEntries(content)
        guard let idx = drafts.firstIndex(where: { $0.ts == entry.ts })
                ?? drafts.firstIndex(where: { $0.raw == entry.raw }) else { return }
        // Re-parse the edited text; it may yield 0..n entries.
        let parsed = JournalParser.parseEntries(newText)
        drafts.replaceSubrange(idx...idx, with: parsed)
        try? writeFile(inboxURL, JournalParser.renderEntries(preamble: preamble, entries: drafts))
        if reindex { loadInbox() }
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
    func updateFiledEntry(date: String, original: Entry, newText: String, reindex: Bool = true) {
        guard let url = journalFileURL(for: date) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        guard let idx = entries.firstIndex(where: { $0.ts == original.ts }) ?? entries.firstIndex(where: { $0.raw == original.raw }) else { return }
        entries.replaceSubrange(idx...idx, with: JournalParser.parseEntries(newText))
        try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))
        if reindex { rebuildIndex() }
    }

    /// Delete a filed entry from its day file (removes the file if now empty).
    func deleteFiledEntry(date: String, entry: Entry) {
        guard let url = journalFileURL(for: date) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let preamble = JournalParser.leadingPreamble(content)
        var entries = JournalParser.parseEntries(content)
        entries.removeAll { $0.ts == entry.ts || $0.raw == entry.raw }
        try? writeFile(url, JournalParser.renderEntries(preamble: preamble, entries: entries))
        rebuildIndex()
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
        if let idx = drafts.firstIndex(where: { $0.ts == entry.ts })
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

    struct CleanupResult { var formatted = 0; var reordered = 0; var deduped = 0 }

    /// Remove exact-duplicate entries (identical raw text), keeping the first.
    private func dedupe(_ entries: [Entry]) -> [Entry] {
        var seen = Set<String>(), out: [Entry] = []
        for e in entries where seen.insert(e.raw).inserted { out.append(e) }
        return out
    }

    /// Standardise punctuation (… and straight quotes), reorder each day's entries
    /// by timestamp, and drop exact-duplicate entries. Returns what changed.
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
            let deduped = dedupe(sorted)
            res.deduped += (sorted.count - deduped.count)
            let rebuilt = JournalParser.renderEntries(preamble: preamble, entries: deduped)
            if rebuilt != orig { try? writeFile(url, rebuilt) }
        }
        // Inbox: reorder by timestamp and drop exact duplicates too.
        if let inboxURL {
            let content = readString(inboxURL)
            let preamble = JournalParser.leadingPreamble(content)
            let entries = JournalParser.parseEntries(content)
            let sorted = JournalParser.sortedByTimestamp(entries)
            if entries.map(\.ts) != sorted.map(\.ts) { res.reordered += 1 }
            let deduped = dedupe(sorted)
            res.deduped += (sorted.count - deduped.count)
            let rebuilt = JournalParser.renderEntries(preamble: preamble, entries: deduped)
            if rebuilt != content {
                try? writeFile(inboxURL, rebuilt)
            }
        }
        reload()
        return res
    }

    // MARK: Stats (jnl cmdStats)

    struct Stats {
        var days = 0, entries = 0, words = 0
        var currentStreak = 0, bestStreak = 0
        var longestDay = "", longestDayWords = 0
        var bytes = 0
        var inboxBytes = 0, archiveBytes = 0
        var mediaBytes = 0
        var inboxDrafts = 0, tags = 0, splitJournals = 0
    }

    private func fileBytes(_ url: URL?) -> Int {
        guard let url else { return 0 }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Non-journal markdown files that live in the folder but aren't journal data
    /// (jnl's transfer scratch file and export outputs). Excluded from size totals.
    private let nonJournalFiles: Set<String> = ["transfer.md", "export.md", "jibber-export.md"]

    /// Total size on disk of all markdown journal files (date journals, split
    /// journals, and the inbox) under the base folder. Skips transfer/export files.
    func journalBytes() -> Int {
        guard let base = baseURL,
              let en = fm.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        for case let url as URL in en
        where url.pathExtension == "md" && !nonJournalFiles.contains(url.lastPathComponent) {
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
        s.inboxBytes = fileBytes(inboxURL)
        s.archiveBytes = max(0, s.bytes - s.inboxBytes)
        s.mediaBytes = assetsBytes()
        s.inboxDrafts = inboxDrafts.count
        s.tags = tagCounts.count
        s.splitJournals = splitJournals.count
        return s
    }

    #if os(macOS)
    /// Reveal the journal folder in Finder (jnl open).
    func revealInFinder() {
        if let baseURL { NSWorkspace.shared.activateFileViewerSelecting([baseURL]) }
    }

    func revealBackupFolder() {
        guard let url = resolveBackupURL() else { return }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
