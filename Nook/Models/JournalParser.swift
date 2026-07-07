//
//  JournalParser.swift
//  Nook
//
//  Pure, platform-independent parsing/rendering of the jnl markdown format.
//  Ported faithfully from ~/Code/jnl/main.go (parseEntries, leadingPreamble,
//  sortedByTimestamp, renderEntries, splitTags) so files round-trip identically
//  to the Go `jnl` CLI. No Foundation UI / file-system dependencies — unit-testable.
//

import Foundation

enum JournalParser {

    // Header: [YYYY-MM-DD HH:MM:SS] optional trailing text.
    // Accepts ASCII hyphen or en-dash in the date (jnl normalises to hyphen).
    private static let headerRegex = try! NSRegularExpression(
        pattern: #"^\[(\d{4}[-–]\d{2}[-–]\d{2}) (\d{2}:\d{2}:\d{2})\](.*)"#
    )

    private static let tagRegex = try! NSRegularExpression(
        pattern: #"@[a-zA-Z][a-zA-Z0-9_-]*"#
    )

    /// Match the header line, returning (date, time, trailingSuffix) or nil.
    private static func matchHeader(_ line: String) -> (date: String, time: String, suffix: String)? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let m = headerRegex.firstMatch(in: line, range: range),
              let dr = Range(m.range(at: 1), in: line),
              let tr = Range(m.range(at: 2), in: line),
              let sr = Range(m.range(at: 3), in: line) else { return nil }
        return (String(line[dr]), String(line[tr]), String(line[sr]))
    }

    /// Split file content into entries. Content before the first header is
    /// silently dropped (see `leadingPreamble` to preserve it on rewrite).
    static func parseEntries(_ content: String) -> [Entry] {
        var entries: [Entry] = []
        var cur: [String] = []
        var curTS = "", curDate = "", curSuffix = ""

        func flush() {
            guard !curTS.isEmpty else { return }
            let body = cur.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(Entry(
                date: curDate, ts: curTS, suffix: curSuffix,
                body: body, raw: cur.joined(separator: "\n")
            ))
        }

        for line in content.components(separatedBy: "\n") {
            if let h = matchHeader(line) {
                flush()
                curDate = h.date.replacingOccurrences(of: "–", with: "-")
                curTS = curDate + " " + h.time
                curSuffix = h.suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                // Normalise the header to ASCII hyphens so raw round-trips cleanly.
                var normHeader = "[\(curTS)]"
                if !curSuffix.isEmpty { normHeader += " " + curSuffix }
                cur = [normHeader]
            } else if !curTS.isEmpty {
                cur.append(line)
            }
        }
        flush()
        return entries
    }

    /// Content before the first header (or "" if only blank/absent). Rewrite
    /// paths (sort, file, cleanup) must preserve this or it would be lost.
    static func leadingPreamble(_ content: String) -> String {
        var pre: [String] = []
        for line in content.components(separatedBy: "\n") {
            if matchHeader(line) != nil { break }
            pre.append(line)
        }
        let text = trimRightNewlines(pre.joined(separator: "\n"))
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }

    /// Copy ordered by timestamp, oldest first. Stable; input untouched.
    /// ts is fixed-width so a lexicographic compare is chronological.
    static func sortedByTimestamp(_ entries: [Entry]) -> [Entry] {
        let indexed = Array(entries.enumerated())
        let sorted = indexed.sorted { a, b in
            if a.element.ts != b.element.ts { return a.element.ts < b.element.ts }
            return a.offset < b.offset   // stable: preserve input order on ties
        }
        return sorted.map { $0.element }
    }

    /// Rebuild file content from a preamble + entries, preserving the preamble
    /// and each entry's original raw text. Returns "" when there is nothing.
    static func renderEntries(preamble: String, entries: [Entry]) -> String {
        var parts: [String] = []
        if !preamble.isEmpty { parts.append(trimRightNewlines(preamble)) }
        for e in entries { parts.append(trimRightNewlines(e.raw)) }
        if parts.isEmpty { return "" }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// All `@tag` tokens in `s`, in order of appearance.
    static func splitTags(_ s: String) -> [String] {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return tagRegex.matches(in: s, range: range).compactMap {
            Range($0.range, in: s).map { String(s[$0]) }
        }
    }

    /// Trim only trailing "\n" characters (equivalent to Go strings.TrimRight(s, "\n")).
    static func trimRightNewlines(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex, s[s.index(before: end)] == "\n" {
            end = s.index(before: end)
        }
        return String(s[s.startIndex..<end])
    }
}
