//
//  Entry.swift
//  Wander
//
//  A single journal entry, in the jnl / Nook on-disk shape: a
//  `[YYYY-MM-DD HH:MM:SS] optional title` header line followed by the body.
//  Adapted from ~/Code/nook/Nook/Models/Entry.swift; the media helpers are
//  left out — Wander is a writing surface, not an attachment browser.
//

import Foundation

public struct Entry: Identifiable, Hashable, Sendable {
    public let date: String     // "YYYY-MM-DD"
    public let ts: String       // "YYYY-MM-DD HH:MM:SS"
    public let suffix: String   // text after the timestamp on the header line (the "title")
    public let body: String     // lines after the header, trimmed of leading/trailing blanks
    public let raw: String      // full original text including the normalised header line
    /// File the entry was parsed from — the rewrite target, and half of `id`.
    public var source: URL?

    public init(date: String, ts: String, suffix: String, body: String,
                raw: String, source: URL? = nil) {
        self.date = date
        self.ts = ts
        self.suffix = suffix
        self.body = body
        self.raw = raw
        self.source = source
    }

    /// Stable across reloads: one timestamp per file. Selection survives a
    /// re-read of the folder, which a fresh UUID per parse would not.
    public var id: String { "\(source?.path ?? "-")#\(ts)" }

    /// The normalised header line, e.g. "[2026-05-10 08:00:00] A title".
    public var header: String { suffix.isEmpty ? "[\(ts)]" : "[\(ts)] \(suffix)" }

    /// Starred entries carry a trailing `*` on their title, so the flag lives
    /// in the plain markdown and round-trips through the jnl CLI. The marker is
    /// a standalone token — a bare `hasSuffix("*")` would also match a bold
    /// title like `**Important**` and lose one `*` per un-star.
    public var isStarred: Bool { suffix == "*" || suffix.hasSuffix(" *") }

    /// The title with any trailing star marker (and its space) removed.
    public var displayTitle: String {
        guard isStarred else { return suffix }
        return String(suffix.dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// One line for list rows: the title if there is one, else the first
    /// non-empty body line with its markdown markers stripped.
    public var preview: String {
        let t = displayTitle
        if !t.isEmpty { return t }
        let first = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return first.trimmingCharacters(in: CharacterSet(charactersIn: "#>-*_ `"))
    }

    /// `@tag` tokens found anywhere in the raw text, in order of first
    /// appearance and deduplicated — writing `@admin` three times in an entry
    /// still files it under one tag, and lists one.
    public var tags: [String] {
        var seen = Set<String>()
        return JournalParser.splitTags(raw).filter { seen.insert($0.lowercased()).inserted }
    }

    public var wordCount: Int { Counts.words(body) }

    /// Rebuild from edited parts, keeping the timestamp (and so the file) fixed.
    public func revised(title: String, body: String, starred: Bool? = nil) -> Entry {
        let star = starred ?? isStarred
        var suffix = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if star { suffix = suffix.isEmpty ? "*" : suffix + " *" }
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var head = "[\(ts)]"
        if !suffix.isEmpty { head += " " + suffix }
        let raw = cleanBody.isEmpty ? head : head + "\n" + cleanBody
        return Entry(date: date, ts: ts, suffix: suffix, body: cleanBody,
                     raw: raw, source: source)
    }

    /// A blank entry stamped now, not yet written to disk.
    public static func blank(at now: Date = Date()) -> Entry {
        let ts = Formats.stamp.string(from: now)
        let date = String(ts.prefix(10))
        return Entry(date: date, ts: ts, suffix: "", body: "",
                     raw: "[\(ts)]", source: nil)
    }

    public var createdDate: Date? { Formats.stamp.date(from: ts) }
}

/// Word / character counting, shared by the entry model and the status line.
public enum Counts {
    public static func words(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    public static func characters(_ s: String) -> Int { s.count }

    /// Reading time in whole minutes, at the conventional 220 wpm, floored at 1
    /// for anything non-empty.
    public static func readingMinutes(_ s: String) -> Int {
        let w = words(s)
        return w == 0 ? 0 : max(1, Int((Double(w) / 220.0).rounded()))
    }

    public static func paragraphs(_ s: String) -> Int {
        s.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }
}

/// Date formatters used across the app. Fixed-locale where the string is a
/// file format (`stamp`), user-locale where it is read by a person.
public enum Formats {
    public static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "Tuesday, 8 September 2026"
    public static let longDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f
    }()

    /// "8 Sep"
    public static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    /// "September 2026" — the sidebar's month rules.
    public static let month: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    public static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    public static func groupNumber(_ n: Int) -> String {
        String(format: "%03d", n)
    }
}
