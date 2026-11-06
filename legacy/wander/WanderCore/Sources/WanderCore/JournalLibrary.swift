//
//  JournalLibrary.swift
//  WanderCore
//
//  Every read and write Wander makes to a journal folder, with no UI framework
//  anywhere near it — Foundation only, so the same code serves the macOS app
//  and the iOS app.
//
//  The layout is jnl's, which Nook also uses:
//
//      <base>/journal/YYYY/MM/DD.md   one file per day
//      <base>/inbox.md                undated drafts
//

import Foundation

public struct JournalLibrary: Sendable {
    public let baseURL: URL

    // MARK: Locations
    //
    // Built once, not on each read: `inboxURL` was a computed property, so
    // `isUnfiled` minted a fresh URL — and then compared two of them, which
    // Foundation does by normalising both — for every entry it was asked about.
    // Over a few thousand entries that alone ran to tens of milliseconds a pass.

    public let journalDir: URL
    public let inboxURL: URL
    private let inboxPath: String

    public init(baseURL: URL) {
        self.baseURL = baseURL
        self.journalDir = baseURL.appendingPathComponent("journal", isDirectory: true)
        self.inboxURL = baseURL.appendingPathComponent("inbox.md")
        self.inboxPath = inboxURL.path
    }

    /// journal/YYYY/MM/DD.md for a "YYYY-MM-DD" date.
    public func dayFile(for date: String) -> URL? {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return nil }
        return journalDir.appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))
            .appendingPathComponent("\(parts[2]).md")
    }

    public func isUnfiled(_ entry: Entry) -> Bool { entry.sourcePath == inboxPath }

    /// Where a retimed entry would end up, for display before the move.
    public func destinationName(for entry: Entry, on day: String) -> String {
        if isUnfiled(entry) { return "inbox.md" }
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return "journal/\(parts[0])/\(parts[1])/\(parts[2]).md"
    }

    public func ensureFolders() {
        try? FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
    }

    /// Resolution order: an explicit folder, then `JNL_DIR` so an existing jnl
    /// or Nook journal opens as-is, then ~/Documents/Wander.
    public static func resolveBase(preferred: String?) -> URL {
        let fm = FileManager.default
        if let preferred, fm.fileExists(atPath: preferred) {
            return URL(fileURLWithPath: preferred, isDirectory: true)
        }
        if let jnl = ProcessInfo.processInfo.environment["JNL_DIR"],
           fm.fileExists(atPath: jnl) {
            return URL(fileURLWithPath: jnl, isDirectory: true)
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let base = fm.fileExists(atPath: documents.path)
            ? documents.appendingPathComponent("Wander", isDirectory: true)
            : home.appendingPathComponent("wander", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: Reading

    /// Every entry in the folder, newest first.
    public func load() -> [Entry] {
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
        return JournalParser.sortedByTimestamp(found).reversed()
    }

    /// Stat-only change detector: count, total size, newest mtime. Cheap enough
    /// to run on every activation, and enough to catch an edit made elsewhere.
    public func fingerprint() -> String {
        let fm = FileManager.default
        var count = 0, size = 0
        var newest = 0.0
        func stat(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return }
            count += 1
            size += values.fileSize ?? 0
            newest = max(newest, values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        stat(inboxURL)
        if let walker = fm.enumerator(at: journalDir,
                                      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let url as URL in walker where url.pathExtension == "md" { stat(url) }
        }
        return "\(count)|\(size)|\(newest)"
    }

    // MARK: Writing
    //
    // Every write reads the file it is about to replace, keeps what it isn't
    // changing, and writes the rest back. So the one thing a write may never do
    // is mistake "I couldn't read this" for "there is nothing here": that turns
    // a save of one entry into the loss of every other entry in the day.

    /// Rewrite the file that owns `entry`, replacing the entry with the same
    /// timestamp or appending it. Returns the entry with its source set.
    @discardableResult
    public func persist(_ entry: Entry, previous: Entry?) throws -> Entry {
        guard let target = entry.source ?? previous?.source ?? dayFile(for: entry.date) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let existing = try readForRewrite(target)
        let preamble = JournalParser.leadingPreamble(existing)
        var day = JournalParser.parseEntries(existing, source: target)

        var stamped = entry
        stamped.source = target
        if let index = day.firstIndex(where: { $0.ts == entry.ts }) {
            day[index] = stamped
        } else {
            day.append(stamped)
        }

        let content = JournalParser.renderEntries(preamble: preamble,
                                                  entries: JournalParser.sortedByTimestamp(day))
        try writeAtomically(content, to: target)
        return stamped
    }

    /// Take an entry out of its file, deleting the file if nothing is left.
    public func remove(_ entry: Entry) throws {
        guard let target = entry.source,
              FileManager.default.fileExists(atPath: target.path) else { return }
        let existing = try readForRewrite(target)
        let preamble = JournalParser.leadingPreamble(existing)
        let day = JournalParser.parseEntries(existing, source: target).filter { $0.ts != entry.ts }
        let content = JournalParser.renderEntries(preamble: preamble, entries: day)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FileManager.default.removeItem(at: target)
        } else {
            try writeAtomically(content, to: target)
        }
    }

    /// Move an entry to `target` under the timestamp `desired` (or the next
    /// free second after it) — the one primitive behind retiming, filing and
    /// unfiling. Returns the entry as it now stands.
    ///
    /// The destination is written before the source is touched. If the second
    /// step fails the entry is in both files rather than in neither: a
    /// duplicate can be tidied, a loss can't. Within one file it is a single
    /// rewrite, so there is no in-between at all.
    public func move(_ entry: Entry, to target: URL, stamp desired: String) throws -> Entry {
        let stamp = try freeStamp(desired, in: target, excluding: entry)
        var head = "[\(stamp)]"
        if !entry.suffix.isEmpty { head += " " + entry.suffix }
        var moved = Entry(date: String(stamp.prefix(10)), ts: stamp,
                          suffix: entry.suffix, body: entry.body,
                          raw: entry.body.isEmpty ? head : head + "\n" + entry.body,
                          source: target)

        // An entry with neither title nor body is never written — moving an
        // untouched new entry to another day must not leave a stub behind.
        if moved.suffix.isEmpty && moved.body.isEmpty {
            try remove(entry)
            moved.source = nil
            return moved
        }

        if entry.sourcePath == target.path {
            let existing = try readForRewrite(target)
            let preamble = JournalParser.leadingPreamble(existing)
            var day = JournalParser.parseEntries(existing, source: target)
            day.removeAll { $0.ts == entry.ts }
            day.append(moved)
            let content = JournalParser.renderEntries(preamble: preamble,
                                                      entries: JournalParser.sortedByTimestamp(day))
            try writeAtomically(content, to: target)
            return moved
        }

        // Read the source before writing anywhere: one that can't be rewritten
        // should refuse the move outright, not after a copy has been made.
        if let source = entry.source { _ = try readForRewrite(source) }
        let written = try persist(moved, previous: nil)
        do {
            try remove(entry)
        } catch {
            throw JournalError.leftBehind(entry.source?.lastPathComponent ?? "its old file")
        }
        return written
    }

    /// A free timestamp at or after `desired` in `target` — two entries in one
    /// file may not share a second, since the timestamp is the entry's identity.
    public func freeStamp(_ desired: String, in target: URL, excluding entry: Entry?) throws -> String {
        let content = try readForRewrite(target)
        guard !content.isEmpty else { return desired }
        var taken = Set(JournalParser.parseEntries(content).map(\.ts))
        if let entry, entry.sourcePath == target.path { taken.remove(entry.ts) }
        var stamp = desired
        var moment = Formats.stamp.date(from: stamp) ?? Date()
        while taken.contains(stamp) {
            moment = moment.addingTimeInterval(1)
            stamp = Formats.stamp.string(from: moment)
        }
        return stamp
    }

    /// The text of a file about to be rewritten. A file that isn't there yet is
    /// empty; one that can't be read, or isn't UTF-8, is an error — never "".
    /// `String(data:encoding:)` is strict, where a lossy decode would quietly
    /// turn the bad bytes into U+FFFD and write that back.
    private func readForRewrite(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw JournalError.notUTF8(url.lastPathComponent)
        }
        return text
    }

    private func writeAtomically(_ content: String, to url: URL) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".wander-\(UUID().uuidString).tmp")
        do {
            try content.write(to: tmp, atomically: false, encoding: .utf8)
            // `replaceItemAt` is for replacing: the first entry of a new day has
            // nothing to replace, so that one is a plain move into place.
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}

/// The ways a write refuses, worded for the status line — each has a
/// different remedy, so none is folded into a generic failure.
public enum JournalError: LocalizedError, Equatable, Sendable {
    /// The file on disk isn't UTF-8. Rewriting it would lose whatever part of
    /// it couldn't be read, so it is left exactly as it is.
    case notUTF8(String)
    /// A move wrote the entry to its new file but couldn't take it out of the
    /// old one.
    case leftBehind(String)

    public var errorDescription: String? {
        switch self {
        case .notUTF8:
            return "This file isn't valid UTF-8. "
                + "Open it in an editor and re-save it as UTF-8."
        case .leftBehind(let name):
            return "Moved, but the old copy couldn't be taken out of \(name) — "
                + "the entry is now in both files."
        }
    }
}

/// The three views onto one folder. Journal is what has been filed, Inbox is
/// what hasn't, Starred cuts across both.
public enum Page: String, CaseIterable, Hashable, Sendable {
    case journal, inbox, starred

    public var label: String {
        switch self {
        case .journal: return "Journal"
        case .inbox:   return "Inbox"
        case .starred: return "Starred"
        }
    }
}

/// Grouping and counting shared by every front end.
public enum JournalIndex {
    /// Entries grouped into month sections, newest month first.
    ///
    /// `list` arrives sorted by timestamp, so a month is a run rather than a
    /// bucket: the sections are slices of it. Copying entries into per-month
    /// arrays instead — and re-deriving each month's title — was most of what a
    /// rebuild of the index cost.
    public static func months(of list: [Entry]) -> [(title: String, entries: ArraySlice<Entry>)] {
        guard !list.isEmpty else { return [] }
        var runs: [(key: String, entries: ArraySlice<Entry>)] = []
        var start = list.startIndex
        var key = String(list[start].date.prefix(7))   // YYYY-MM
        for index in list.indices.dropFirst() {
            let next = String(list[index].date.prefix(7))
            guard next != key else { continue }
            runs.append((key, list[start..<index]))
            start = index
            key = next
        }
        runs.append((key, list[start...]))
        return runs.map { (monthTitle(of: $0.key), $0.entries) }
    }

    /// "September 2026" for a "YYYY-MM" key. Memoised: there are as many of
    /// these as the journal has months, and they never change.
    private static var monthTitles: [String: String] = [:]

    private static func monthTitle(of key: String) -> String {
        if let ready = monthTitles[key] { return ready }
        let title = Formats.day.date(from: key + "-01").map { Formats.month.string(from: $0) } ?? key
        monthTitles[key] = title
        return title
    }

    /// Consecutive days written, counting back from today — or from yesterday,
    /// so a streak isn't reported broken before the day's first entry.
    public static func streak(of entries: [Entry]) -> Int {
        let days = Set(entries.map(\.date))
        guard !days.isEmpty else { return 0 }
        let calendar = Calendar.current
        var cursor = Date()
        if !days.contains(Formats.day.string(from: cursor)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
            guard days.contains(Formats.day.string(from: cursor)) else { return 0 }
        }
        var count = 0
        while days.contains(Formats.day.string(from: cursor)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    public static func matches(_ entry: Entry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || entry.raw.lowercased().contains(q)
    }
}
