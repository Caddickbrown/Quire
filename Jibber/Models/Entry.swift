//
//  Entry.swift
//  Jibber
//
//  A single journal entry. Mirrors the `entry` struct in the jnl Go backend
//  (~/Code/jnl/main.go) so the on-disk format stays byte-compatible with the
//  `jnl` CLI: a `[YYYY-MM-DD HH:MM:SS] optional title` header followed by body.
//

import Foundation

struct Entry: Identifiable, Hashable {
    /// In-memory identity only — entries have no persistent id on disk. Lists
    /// are always rebuilt from the parsed file, so a fresh UUID per parse is fine.
    let id = UUID()

    let date: String    // "YYYY-MM-DD"
    let ts: String      // "YYYY-MM-DD HH:MM:SS"
    let suffix: String  // text after the timestamp on the header line (the "title")
    let body: String    // lines after the header, trimmed of leading/trailing blanks
    let raw: String     // full original text including the (normalised) header line

    /// The normalised header line, e.g. "[2026-05-10 08:00:00] A title".
    var header: String {
        suffix.isEmpty ? "[\(ts)]" : "[\(ts)] \(suffix)"
    }

    /// A short one-line preview for list rows: the title if present, else the
    /// first non-empty body line.
    var preview: String {
        if !suffix.isEmpty { return suffix }
        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return firstLine
    }

    /// `@tag` tokens found anywhere in the raw text, in order of appearance.
    var tags: [String] { JournalParser.splitTags(raw) }

    var wordCount: Int {
        body.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
}
