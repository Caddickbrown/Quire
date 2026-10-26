//
//  JournalParser.swift
//  Wander
//
//  Pure parsing/rendering of the jnl markdown format, ported from
//  ~/Code/nook/Nook/Models/JournalParser.swift (itself a port of the Go `jnl`
//  CLI) so Wander's files round-trip byte-identically with jnl and Nook:
//  a `[YYYY-MM-DD HH:MM:SS] optional title` header line followed by the body.
//
//  No UI or file-system dependencies.
//

import Foundation

public enum JournalParser {

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

    public static func isHeaderLine(_ line: String) -> Bool { matchHeader(line) != nil }

    /// File text as the parser reads it: a leading byte-order mark dropped and
    /// CRLF line endings turned to LF. Splitting on "\n" alone left a "\r" on
    /// every line of a file written on Windows, and the rewrite then joined
    /// those lines back with bare "\n" — half one ending, half the other, and
    /// every entry changed on disk by a save that changed nothing. Wander
    /// writes LF; a CRLF file becomes LF the first time it is saved.
    public static func normalised(_ content: String) -> String {
        var text = content
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        // Checked by byte: in Swift "\r\n" is one Character, so asking the
        // String whether it contains "\r" would say no.
        guard text.utf8.contains(0x0D) else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Split file content into entries. Content before the first header is
    /// dropped here — `leadingPreamble` preserves it across a rewrite.
    public static func parseEntries(_ content: String, source: URL? = nil) -> [Entry] {
        var entries: [Entry] = []
        var cur: [String] = []
        var curTS = "", curDate = "", curSuffix = ""

        func flush() {
            guard !curTS.isEmpty else { return }
            let body = cur.dropFirst().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(Entry(
                date: curDate, ts: curTS, suffix: curSuffix,
                body: body, raw: cur.joined(separator: "\n"), source: source
            ))
        }

        for line in normalised(content).components(separatedBy: "\n") {
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

    /// Content before the first header (or "" if only blank/absent). Rewrites
    /// must preserve this or a hand-written file header would be lost.
    public static func leadingPreamble(_ content: String) -> String {
        var pre: [String] = []
        for line in normalised(content).components(separatedBy: "\n") {
            if matchHeader(line) != nil { break }
            pre.append(line)
        }
        let text = trimRightNewlines(pre.joined(separator: "\n"))
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }

    /// Copy ordered by timestamp, oldest first. Stable; input untouched.
    /// ts is fixed-width, so a lexicographic compare is chronological.
    public static func sortedByTimestamp(_ entries: [Entry]) -> [Entry] {
        let indexed = Array(entries.enumerated())
        return indexed.sorted { a, b in
            if a.element.ts != b.element.ts { return a.element.ts < b.element.ts }
            return a.offset < b.offset   // stable: preserve input order on ties
        }.map { $0.element }
    }

    /// Rebuild file content from a preamble + entries, preserving the preamble
    /// and each entry's raw text. Returns "" when there is nothing.
    public static func renderEntries(preamble: String, entries: [Entry]) -> String {
        var parts: [String] = []
        if !preamble.isEmpty { parts.append(trimRightNewlines(preamble)) }
        for e in entries { parts.append(trimRightNewlines(e.raw)) }
        if parts.isEmpty { return "" }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// All `@tag` tokens in `s`, in order of appearance.
    public static func splitTags(_ s: String) -> [String] {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return tagRegex.matches(in: s, range: range).compactMap {
            Range($0.range, in: s).map { String(s[$0]) }
        }
    }

    /// Trim only trailing "\n" (Go's strings.TrimRight(s, "\n")). Walked by
    /// scalar, not by Character: a trailing "\r\n" is a single Character that
    /// isn't equal to "\n", so it was never trimmed.
    public static func trimRightNewlines(_ s: String) -> String {
        var scalars = s.unicodeScalars[...]
        while scalars.last == "\n" { scalars.removeLast() }
        return String(scalars)
    }
}
