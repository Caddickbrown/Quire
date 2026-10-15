// Swift value adapter for the Rust search grammar and matcher.
// Compiled with generated UniFFI bindings and the Rust XCFramework.

import Foundation

struct SearchQuery: Equatable {
    var terms: [String] = []        // lowercased plain words + quoted phrases
    var tags: [String] = []         // "@name", lowercased
    var before: String? = nil       // partial ISO date, exclusive
    var after: String? = nil        // partial ISO date, inclusive
    var has: [String] = []          // "image" | "video" | "audio" | "media"
    var starred = false

    var isEmpty: Bool {
        terms.isEmpty && tags.isEmpty && before == nil && after == nil
            && has.isEmpty && !starred
    }

    private var rawQuery: String {
        var tokens = terms.map { "\"" + $0 + "\"" } + tags.map { "tag:" + $0 } + has.map { "has:" + $0 }
        if let before { tokens.append("before:" + before) }
        if let after { tokens.append("after:" + after) }
        if starred { tokens.append("is:starred") }
        return tokens.joined(separator: " ")
    }
    static func parse(_ raw: String) -> SearchQuery {
        struct Parsed: Decodable {
            let terms: [String]; let tags: [String]; let before: String?; let after: String?; let has: [String]; let starred: Bool
        }
        let q = try! JSONDecoder().decode(Parsed.self, from: Data(searchQuery(text: raw).utf8))
        return SearchQuery(terms: q.terms, tags: q.tags, before: q.before, after: q.after, has: q.has, starred: q.starred)
    }
    func matches(_ entry: Entry) -> Bool {
        searchMatches(query: rawQuery, raw: entry.raw, file: entry.file ?? "inbox.md")
    }

    /// Whitespace-split, except quoted runs ("two words") come out whole.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" {
                if inQuotes {
                    if !current.isEmpty { tokens.append(current); current = "" }
                    inQuotes = false
                } else {
                    if !current.isEmpty { tokens.append(current); current = "" }
                    inQuotes = true
                }
            } else if ch == " " || ch == "\n" || ch == "\t", !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// "2026", "2026-03", or "2026-03-15".
    static func isPartialDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return false }
        let widths = [4, 2, 2]
        for (i, part) in parts.enumerated() {
            guard part.count == widths[i], part.allSatisfy(\.isNumber) else { return false }
        }
        return true
    }
}
