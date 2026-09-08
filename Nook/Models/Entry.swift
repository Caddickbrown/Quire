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
    ///
    /// The marker is a standalone token — either the whole title or preceded by
    /// a space. A bare `hasSuffix("*")` also matched a markdown-bold title like
    /// `**Important**`, which then showed as starred and lost one `*` per
    /// un-star.
    var isStarred: Bool { suffix == "*" || suffix.hasSuffix(" *") }

    /// The title with any trailing star marker (and surrounding spaces) removed.
    var displayTitle: String {
        guard isStarred else { return suffix }
        return String(suffix.dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// The same rule as `isStarred` / `displayTitle`, for editors that hold the
    /// title as text rather than a parsed entry. Four views each carried their
    /// own `hasSuffix("*")`, so the model's fix left them mangling `**bold**`.
    static func hasStarMarker(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "*" || t.hasSuffix(" *")
    }
    /// The title with the marker (and the space before it) removed.
    static func strippingStarMarker(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasStarMarker(t) else { return t }
        return String(t.dropLast()).trimmingCharacters(in: .whitespaces)
    }
    /// The title with the marker added, or removed if it was there.
    static func togglingStarMarker(_ title: String) -> String {
        let base = strippingStarMarker(title)
        if hasStarMarker(title) { return base }
        return base.isEmpty ? "*" : base + " *"
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

    /// Relative path of the first image this entry links, if any — the list rows
    /// draw it as a thumbnail.
    var firstImagePath: String? {
        MediaLinks.paths(in: raw).first { MediaKind(path: $0) == .image }
    }

    /// SF Symbol names for the kinds of media this entry links — image (photo),
    /// audio (mic), video (film) — plus a paperclip for any other attachment.
    /// Deduped and ordered; empty when the entry has no media.
    var mediaBadges: [String] {
        let paths = MediaLinks.paths(in: raw)
        guard !paths.isEmpty else { return [] }
        var image = false, audio = false, video = false, other = false
        for p in paths {
            // One list, shared with `MediaKind` — they had drifted, so a `.webm`
            // recording counted as one kind here and another there.
            let ext = (p as NSString).pathExtension.lowercased()
            if MediaKind.videoExtensions.contains(ext) { video = true }
            else if MediaKind.audioExtensions.contains(ext) { audio = true }
            else if MediaKind.imageExtensions.contains(ext) { image = true }
            else { other = true }
        }
        var out: [String] = []
        if image { out.append("photo") }
        if audio { out.append("mic") }
        if video { out.append("film") }
        if other { out.append("paperclip") }
        return out
    }
}
