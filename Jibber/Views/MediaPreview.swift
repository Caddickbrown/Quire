//
//  MediaPreview.swift
//  Jibber
//
//  Renders an entry's body with inline images. Images are stored as Obsidian-
//  style markdown links (![](assets/…)); this splits the text on those links and
//  draws the referenced image files inline.
//

import SwiftUI

enum MDSegment {
    case text(String)
    case image(String)   // relative asset path or URL
}

/// Split body text into text runs and image links.
func parseMediaSegments(_ s: String) -> [MDSegment] {
    let regex = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)
    let ns = s as NSString
    var segments: [MDSegment] = []
    var cursor = 0
    for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        if m.range.location > cursor {
            segments.append(.text(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
        }
        segments.append(.image(ns.substring(with: m.range(at: 1))))
        cursor = m.range.location + m.range.length
    }
    if cursor < ns.length {
        segments.append(.text(ns.substring(from: cursor)))
    }
    return segments
}

struct MediaPreview: View {
    @EnvironmentObject private var store: JournalStore
    let text: String
    let font: Font
    let textColor: Color

    private var segments: [MDSegment] { parseMediaSegments(text) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .text(let t):
                        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            Text(trimmed)
                                .font(font)
                                .foregroundStyle(textColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    case .image(let path):
                        imageView(path)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func imageView(_ path: String) -> some View {
        if let image = loadImage(path) {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Label(path, systemImage: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func loadImage(_ path: String) -> Image? {
        let url: URL?
        if path.hasPrefix("http") {
            url = URL(string: path)   // remote not loaded synchronously; falls through to placeholder
            return nil
        } else {
            url = store.assetURL(forRelative: path)
        }
        guard let url else { return nil }
        #if os(macOS)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #endif
    }
}
