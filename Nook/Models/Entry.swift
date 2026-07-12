//
//  Entry.swift
//  Nook
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

    /// Starred entries carry a trailing `*` on their title (the header suffix),
    /// so the flag lives in the plain-markdown file and round-trips through the
    /// jnl CLI. Toggling is add/remove of that marker (see `JournalStore.toggleStar`).
    var isStarred: Bool { suffix.hasSuffix("*") }

    /// The title with any trailing star marker (and surrounding spaces) removed.
    var displayTitle: String {
        guard isStarred else { return suffix }
        return String(suffix.dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// A short one-line preview for list rows: the title (sans star) if present,
    /// else the first non-empty body line.
    var preview: String {
        let t = displayTitle
        if !t.isEmpty { return t }
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

    /// SF Symbol names for the kinds of media this entry links — image (photo),
    /// audio (mic), video (film) — plus a paperclip for any other attachment.
    /// Deduped and ordered; empty when the entry has no media.
    var mediaBadges: [String] {
        let paths = JournalStore.mediaPaths(in: raw)
        guard !paths.isEmpty else { return [] }
        var image = false, audio = false, video = false, other = false
        for p in paths {
            switch (p as NSString).pathExtension.lowercased() {
            case "mov", "mp4", "m4v":
                video = true
            case "m4a", "mp3", "wav", "aac", "aiff", "caf":
                audio = true
            case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp":
                image = true
            default:
                other = true
            }
        }
        var out: [String] = []
        if image { out.append("photo") }
        if audio { out.append("mic") }
        if video { out.append("film") }
        if other { out.append("paperclip") }
        return out
    }
}
