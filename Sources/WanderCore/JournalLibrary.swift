//
//  JournalLibrary.swift
//  WanderCore
//
//  Every read and write Wander makes to a journal folder, with no UI framework
//  anywhere near it — Foundation only, so the same code serves the macOS app,
//  the iOS app and the Linux terminal build.
//
//  The layout is jnl's, which Nook also uses:
//
//      <base>/journal/YYYY/MM/DD.md   one file per day
//      <base>/inbox.md                undated drafts
//

import Foundation

public struct JournalLibrary: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    // MARK: Locations

    public var journalDir: URL { baseURL.appendingPathComponent("journal", isDirectory: true) }
    public var inboxURL: URL { baseURL.appendingPathComponent("inbox.md") }

    /// journal/YYYY/MM/DD.md for a "YYYY-MM-DD" date.
    public func dayFile(for date: String) -> URL? {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return nil }
        return journalDir.appendingPathComponent(String(parts[0]))
            .appendingPathComponent(String(parts[1]))
            .appendingPathComponent("\(parts[2]).md")
    }

    public func isUnfiled(_ entry: Entry) -> Bool { entry.source == inboxURL }

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

    /// Rewrite the file that owns `entry`, replacing the entry with the same
    /// timestamp or appending it. Returns the entry with its source set.
    @discardableResult
    public func persist(_ entry: Entry, previous: Entry?) throws -> Entry {
        guard let target = entry.source ?? previous?.source ?? dayFile(for: entry.date) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
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
              let existing = try? String(contentsOf: target, encoding: .utf8) else { return }
        let preamble = JournalParser.leadingPreamble(existing)
        let day = JournalParser.parseEntries(existing, source: target).filter { $0.ts != entry.ts }
        let content = JournalParser.renderEntries(preamble: preamble, entries: day)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: target)
        } else {
            try writeAtomically(content, to: target)
        }
    }

    /// A free timestamp at or after `desired` in `target` — two entries in one
    /// file may not share a second, since the timestamp is the entry's identity.
    public func freeStamp(_ desired: String, in target: URL, excluding entry: Entry?) -> String {
        guard let content = try? String(contentsOf: target, encoding: .utf8) else { return desired }
        var taken = Set(JournalParser.parseEntries(content).map(\.ts))
        if let entry, entry.source == target { taken.remove(entry.ts) }
        var stamp = desired
        var moment = Formats.stamp.date(from: stamp) ?? Date()
        while taken.contains(stamp) {
            moment = moment.addingTimeInterval(1)
            stamp = Formats.stamp.string(from: moment)
        }
        return stamp
    }

    private func writeAtomically(_ content: String, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".wander-\(UUID().uuidString).tmp")
        try content.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
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
    public static func months(of list: [Entry]) -> [(title: String, entries: [Entry])] {
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
