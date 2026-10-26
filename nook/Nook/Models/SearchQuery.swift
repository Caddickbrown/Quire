//
//  SearchQuery.swift
//  Nook
//
//  The global search's query grammar — pure string parsing and entry matching,
//  kept free of UI/file-system dependencies (like JournalParser) so it compiles
//  into `make check` and stays portable to the Linux port.
//
//  Grammar:
//      plain terms          case-insensitive substring match on title + body
//                           (not the timestamp header — see `matches`)
//      "exact phrase"       quoted phrases match as one substring
//      tag:name             entry carries @name (leading @ optional)
//      before:2026-03       entry date strictly before the (partial) ISO date
//      after:2026-03        entry date on/after the (partial) ISO date
//      has:image            entry links media of that kind (image|video|audio|media)
//      is:starred           entry is starred
//
//  Every clause must match (AND). An empty query matches nothing.
//

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

    /// Split the raw input into tokens (quoted phrases stay together), then
    /// peel off the operator tokens; whatever is left is a plain term.
    static func parse(_ raw: String) -> SearchQuery {
        var q = SearchQuery()
        for token in tokenize(raw) {
            let lower = token.lowercased()
            if lower.hasPrefix("tag:") {
                let name = String(token.dropFirst(4)).lowercased()
                guard !name.isEmpty else { continue }
                q.tags.append(name.hasPrefix("@") ? name : "@" + name)
            } else if lower.hasPrefix("before:") {
                let d = String(token.dropFirst(7))
                if isPartialDate(d) { q.before = d }
            } else if lower.hasPrefix("after:") {
                let d = String(token.dropFirst(6))
                if isPartialDate(d) { q.after = d }
            } else if lower.hasPrefix("has:") {
                let kind = String(lower.dropFirst(4))
                if ["image", "video", "audio", "media"].contains(kind) { q.has.append(kind) }
            } else if lower == "is:starred" {
                q.starred = true
            } else if !lower.isEmpty {
                q.terms.append(lower)
            }
        }
        return q
    }

    func matches(_ entry: Entry) -> Bool {
        guard !isEmpty else { return false }
        // Plain terms search what the writer wrote — the title and the body —
        // and deliberately not `raw`, whose timestamp header made searching
        // "2025" return every entry written that year. Dates have their own
        // `before:`/`after:` operators. Tags still come from `raw`, since a
        // `@tag` in the title counts.
        if !terms.isEmpty {
            let text = (entry.suffix + "\n" + entry.body).lowercased()
            for term in terms where !text.contains(term) { return false }
        }
        if !tags.isEmpty {
            let present = Set(entry.tags.map { $0.lowercased() })
            for tag in tags where !present.contains(tag) { return false }
        }
        if let before, !(entry.date < before) { return false }
        if let after, !(entry.date > after || entry.date.hasPrefix(after)) { return false }
        if starred && !entry.isStarred { return false }
        if !has.isEmpty {
            let paths = MediaLinks.paths(in: entry.raw)
            for want in has {
                let ok: Bool
                switch want {
                case "media": ok = !paths.isEmpty
                case "image": ok = paths.contains { MediaKind(path: $0) == .image }
                case "video": ok = paths.contains { MediaKind(path: $0) == .video }
                case "audio": ok = paths.contains { MediaKind(path: $0) == .audio }
                default:      ok = true
                }
                if !ok { return false }
            }
        }
        return true
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
