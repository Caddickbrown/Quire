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
}

/// What kind of media a path points at, decided by its file extension.
enum MediaKind {
    case image, video, audio
    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["mov", "mp4", "m4v"].contains(ext) { self = .video }
        else if ["m4a", "mp3", "wav", "aac", "aiff", "caf"].contains(ext) { self = .audio }
        else { self = .image }
    }
}
