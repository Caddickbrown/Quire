//
//  Media.swift
//  Nook
//
//  Pure helpers for the media links in an entry's markdown — extracting the
//  `![](assets/…)` paths and classifying them by kind. Kept free of Foundation
//  UI / file-system dependencies (like JournalParser) so `Entry` can use them
//  and `make check` can compile the model layer on its own.
//

import Foundation

/// Relative asset paths referenced by markdown media links in some content.
enum MediaLinks {
    private static let regex = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)

    static func paths(in content: String) -> [String] {
        let ns = content as NSString
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
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
    /// `content` with every link to `assets/<from>` pointed at `assets/<to>`
    /// instead, or nil when it has none — so a caller rewrites only the files
    /// that actually change.
    static func renaming(_ content: String, from: String, to: String) -> String? {
        let old = "(assets/\(from))"
        guard content.contains(old) else { return nil }
        return content.replacingOccurrences(of: old, with: "(assets/\(to))")
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
