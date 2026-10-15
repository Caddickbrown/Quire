// Swift adapter for Quire Rust parsing, rendering, tags and punctuation.
// Compiled with generated UniFFI bindings and the Rust XCFramework.

import Foundation

enum JournalParser {

    private struct Parsed: Decodable {
        let date: String; let ts: String; let suffix: String; let body: String; let raw: String
        var entry: Entry { Entry(date: date, ts: ts, suffix: suffix, body: body, raw: raw) }
    }
    static func isHeaderLine(_ line: String) -> Bool { headerLine(line: line) }
    static func parseEntries(_ content: String) -> [Entry] {
        // Serialization of these plain values cannot fail at the Rust boundary.
        let parsed = try! JSONDecoder().decode([Parsed].self, from: Data(parseText(text: content).utf8))
        return withOccurrences(parsed.map(\.entry))
    }

    /// Number each entry among its same-second twins, in order, so `Entry.id`
    /// is unique within a file and stable across re-parses. Store paths that
    /// splice freshly parsed entries into an existing list must re-run this, or
    /// two entries sharing a second would both claim occurrence 0.
    static func withOccurrences(_ entries: [Entry]) -> [Entry] {
        var seen: [String: Int] = [:]
        return entries.map { e in
            var e = e
            let n = seen[e.ts, default: 0]
            seen[e.ts] = n + 1
            e.occurrence = n
            return e
        }
    }

    /// Content before the first header (or "" if only blank/absent). Rewrite
    /// paths (sort, file, cleanup) must preserve this or it would be lost.
    static func leadingPreamble(_ content: String) -> String {
        preamble(text: content)
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
        renderText(pre: preamble, raws: entries.map(\.raw))
    }

    /// All `@tag` tokens in `s`, in order of appearance.
    static func splitTags(_ s: String) -> [String] {
        tagsIn(text: s)
    }

    /// Trim only trailing "\n" characters (equivalent to Go strings.TrimRight(s, "\n")).
    static func trimRightNewlines(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex, s[s.index(before: end)] == "\n" {
            end = s.index(before: end)
        }
        return String(s[s.startIndex..<end])
    }

    /// jnl cmdCleanup's punctuation pass (… and straight quotes), applied only
    /// outside `![alt](path)` media links — a filename or URL containing "..."
    /// must never be rewritten into an ellipsis and the link broken.
    static func normalizePunctuation(_ s: String) -> String {
        punctuation(text: s)
    }

}
