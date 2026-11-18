//
//  Media.swift
//  Quire
//
//  Pure helpers for the media links in an entry's markdown — extracting the
//  `![](assets/…)` paths and classifying them by kind. Kept free of Foundation
//  UI / file-system dependencies (like JournalParser) so `Entry` can use them
//  and `make check` can compile the model layer on its own.
//

import Foundation

/// Relative asset paths referenced by markdown media links in some content.
enum MediaLinks {
    /// A bare target may hold balanced brackets, as CommonMark allows and the
    /// core's `LINK_TARGET_RE` reads them: `assets/2026/09/image(1).jpg` is one
    /// target, where this used to stop at the first `)` and find `image(1`.
    private static let regex = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*(?:<([^>\n]*)>|((?:[^\s()]|\([^\s()]*\))+))(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?(?:\s*\)|[ \t]*(?=\r?\n|$))"#)

    static func paths(in content: String) -> [String] {
        let ns = content as NSString
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            .map { match in
                let range = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
                return destination(ns.substring(with: range))
            }
    }

    /// Local URL syntax is stripped before decoding so an escaped # stays a
    /// filename character, rather than being mistaken for an anchor.
    static func destination(_ target: String) -> String {
        let path = target.split(whereSeparator: { $0 == "#" || $0 == "?" }).first.map(String.init) ?? target
        return path.removingPercentEncoding ?? path
    }

    /// Root-relative asset identity, independent of duplicate basenames.
    static func resolved(_ path: String, file: String) -> String? {
        guard !path.hasPrefix("/"), !path.contains(":") else { return nil }
        var parts = path.hasPrefix("assets/") ? [] : file.split(separator: "/").dropLast().map(String.init)
        for part in path.split(separator: "/") {
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else if part != "." { parts.append(String(part)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// `content` with every media link replaced by a space — what an entry
    /// says apart from its attachments, for an identity that has to survive a
    /// link being rewritten to a fresh asset path (the importers' re-run
    /// check). Uses the one compiled regex above; an inline
    /// `replacingOccurrences(…, options: .regularExpression)` compiles a new
    /// one per call.
    static func strippingLinks(_ content: String) -> String {
        regex.stringByReplacingMatches(
            in: content, range: NSRange(location: 0, length: (content as NSString).length),
            withTemplate: " ")
    }
}

extension MediaLinks {
    /// `content`, the entry file at `file` (root-relative), with every media
    /// link to the root-relative asset `from` ("assets/2026/11/IMG.heic")
    /// pointed at `to` instead ("assets/2026/11/IMG.jpg", the same folder), or
    /// nil when it has none — so a caller rewrites only the files that
    /// actually change. A link is matched by the asset it resolves to, so the
    /// dated folders count, and so do links written relative to the entry.
    static func renaming(_ content: String, file: String, from: String, to: String) -> String? {
        let ns = content as NSString
        let fromName = (from as NSString).lastPathComponent
        let toName = (to as NSString).lastPathComponent
        let fromStem = (fromName as NSString).deletingPathExtension
        let toStem = (toName as NSString).deletingPathExtension
        let toExt = (toName as NSString).pathExtension
        var edits: [(NSRange, String)] = []
        for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let angled = match.range(at: 1).location != NSNotFound
            let range = angled ? match.range(at: 1) : match.range(at: 2)
            let raw = ns.substring(with: range)
            guard resolved(destination(raw), file: file) == from else { continue }
            // The path, and any #anchor or ?query after it, kept as written.
            let cut = raw.firstIndex(where: { $0 == "#" || $0 == "?" }) ?? raw.endIndex
            let path = String(raw[..<cut]), tail = String(raw[cut...])
            let slash = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
            let dir = String(path[..<slash]), last = String(path[slash...])
            let lastStem = (last as NSString).deletingPathExtension
            // "IMG%200001.heic" → "IMG%200001-1.jpg": the name keeps its own
            // escaping, and only what the new name adds is appended.
            let newLast: String
            if (lastStem.removingPercentEncoding ?? lastStem) == fromStem, toStem.hasPrefix(fromStem) {
                newLast = lastStem + toStem.dropFirst(fromStem.count) + "." + toExt
            } else {
                newLast = angled ? toName : (toName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? toName)
            }
            edits.append((range, dir + newLast + tail))
        }
        guard !edits.isEmpty else { return nil }
        let out = NSMutableString(string: content)
        for (range, text) in edits.reversed() { out.replaceCharacters(in: range, with: text) }
        return out as String
    }
}

/// What kind of media a path points at, decided by its file extension.
///
/// The `webm`/`weba`/`mkv`/`ogg`/`oga`/`opus`/`flac` entries are here because
/// the Linux port records straight into them and writes the links into the same
/// shared folder — without them a Linux voice memo showed up here as a photo.
/// Keep in step with `Entry.mediaBadges` and the Rust `parser::media_kind`.
/// (Not to be confused with `JournalStore`'s Data Saver extension sets, which
/// are deliberately narrower — those are AVFoundation *transcode* targets.)
enum MediaKind {
    case image, video, audio
    static let videoExtensions = ["mov", "mp4", "m4v", "webm", "mkv"]
    static let audioExtensions = ["m4a", "mp3", "wav", "aac", "aiff", "caf",
                                  "ogg", "oga", "opus", "flac", "weba"]
    static let imageExtensions = ["png", "jpg", "jpeg", "gif", "heic", "heif",
                                  "webp", "tiff", "tif", "bmp", "svg"]
    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) { self = .video }
        else if Self.audioExtensions.contains(ext) { self = .audio }
        else { self = .image }
    }
}
