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
    public var source: URL? { didSet { indexSource() } }

    /// `source.path`, kept beside the URL. Comparing two URLs costs microseconds
    /// — enough that filing the whole journal by file, which the index does on
    /// every rebuild, was measurable; comparing the paths as strings is free.
    public private(set) var sourcePath: String?

    /// Stable across reloads: one timestamp per file. Selection survives a
    /// re-read of the folder, which a fresh UUID per parse would not. Stored
    /// rather than computed — `ForEach` asks every row for its id on each pass.
    public private(set) var id: String

    /// Counted once, at parse. The journal's total is a sum over thousands of
    /// entries and used to be recounted from the text each time it was read.
    public let wordCount: Int

    /// The timestamp as a date, parsed once. Every index row asks for it, and
    /// through `DateFormatter` a single one of these costs the best part of a
    /// tenth of a millisecond.
    public let createdDate: Date?

    public init(date: String, ts: String, suffix: String, body: String,
                raw: String, source: URL? = nil) {
        self.date = date
        self.ts = ts
        self.suffix = suffix
        self.body = body
        self.raw = raw
        self.source = source
        self.sourcePath = source?.path
        self.id = Entry.identity(of: source?.path, ts: ts)
        self.wordCount = Counts.words(body)
        self.createdDate = Formats.moment(from: ts)
    }

    private mutating func indexSource() {
        sourcePath = source?.path
        id = Entry.identity(of: sourcePath, ts: ts)
    }

    private static func identity(of path: String?, ts: String) -> String {
        "\(path ?? "-")#\(ts)"
    }

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

}

/// Word / character counting, shared by the entry model and the status line.
public enum Counts {
    /// Counted by walking the bytes rather than by `split`, which allocates an
    /// array of substrings — the difference is an order of magnitude once the
    /// caller is summing over a whole journal.
    public static func words(_ s: String) -> Int {
        var count = 0
        var inWord = false
        for byte in s.utf8 {
            if byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
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

    /// The calendar the fixed-format timestamps are read against — built once,
    /// since `Calendar.current` is resolved afresh on every access.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    /// "YYYY-MM-DD HH:MM:SS" to a `Date`, read straight off the digits.
    ///
    /// This is `stamp.date(from:)` without the formatter: the shape is fixed and
    /// ours, and `DateFormatter` spends around ninety microseconds on each one —
    /// which the index felt, having thousands of them to place.
    public static func moment(from ts: String) -> Date? {
        let digits = Array(ts.utf8)
        guard digits.count >= 19 else { return nil }
        func number(at index: Int, _ length: Int) -> Int? {
            var value = 0
            for offset in index..<(index + length) {
                let digit = digits[offset]
                guard digit >= 48, digit <= 57 else { return nil }
                value = value * 10 + Int(digit - 48)
            }
            return value
        }
        guard let year = number(at: 0, 4), let month = number(at: 5, 2),
              let day = number(at: 8, 2), let hour = number(at: 11, 2),
              let minute = number(at: 14, 2), let second = number(at: 17, 2)
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))
    }

    public static func groupNumber(_ n: Int) -> String {
        String(format: "%03d", n)
    }
}
