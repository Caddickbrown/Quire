//
//  Entry.swift
//  Quire
//
//  A single journal entry. Mirrors the `entry` struct in the jnl Go backend
//  (~/Code/jnl/main.go) so the on-disk format stays byte-compatible with the
//  `jnl` CLI: a `[YYYY-MM-DD HH:MM:SS] optional title` header followed by body.
//

import Foundation

struct Entry: Identifiable, Hashable {
    /// Which same-second twin this is, in file order. Entries have no id on
    /// disk and the timestamp alone isn't unique, so this is what separates
    /// two entries written in the same second. `JournalParser.parseEntries`
    /// assigns it; so does every store path that splices re-parsed entries
    /// into an existing list (see `JournalParser.withOccurrences`).
    var file: String? = nil
    var fileIndex: Int? = nil
    var occurrence: Int = 0

    /// Stable across re-parses, unlike the `UUID()` this used to be.
    ///
    /// Lists are rebuilt from the file constantly — every autosave republishes
    /// the corpus — and with a fresh id per parse nothing on screen ever
    /// compared equal to what the store now held. Every rebuild therefore
    /// re-identified every row, re-created the open editor, and in
    /// `EntryTwoPane` sent `resyncOpenEntry` walking the corpus for an entry it
    /// had only just replaced.
    var id: String { (file.map { $0 + ":" } ?? "") + (occurrence == 0 ? ts : "\(ts)#\(occurrence)") }

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

/// Which file an entry lives in — the inbox, a day in the archive, or a
/// tag-routed split journal (`<base>/<name>.md`). Every edit path routes on
/// this, so it decides which file a save rewrites.
///
/// A model type, not a view one: it lived in `EntryDetailView.swift`, which
/// kept `JournalStore` (which needs it) out of the hostless test bundle.
enum EntrySource: Hashable {
    case inbox
    case archive(date: String)
    case journal(name: String)
}
