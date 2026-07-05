//
//  MediaPreview.swift
//  Jibber
//
//  Renders an entry's body with inline images. Images are stored as Obsidian-
//  style markdown links (![](assets/…)); this splits the text on those links and
//  draws the referenced image files inline.
//

import SwiftUI
import AVKit

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
            VStack(alignment: .leading, spacing: 20) {
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
                        mediaView(path)
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func mediaView(_ path: String) -> some View {
        let url = store.assetURL(forRelative: path)
        switch MediaKind(path: path) {
        case .video:
            if let url {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else { missing(path) }
        case .audio:
            if let url { AudioPlayerView(url: url) } else { missing(path) }
        case .image:
            if let image = loadImage(url) {
                image.resizable().scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else { missing(path) }
        }
    }

    private func missing(_ path: String) -> some View {
        Label(path, systemImage: "questionmark.square.dashed")
            .font(.caption).foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadImage(_ url: URL?) -> Image? {
        guard let url else { return nil }
        #if os(macOS)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #endif
    }
}

enum MediaKind {
    case image, video, audio
    init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["mov", "mp4", "m4v"].contains(ext) { self = .video }
        else if ["m4a", "mp3", "wav", "aac", "aiff", "caf"].contains(ext) { self = .audio }
        else { self = .image }
    }
}

/// A compact inline audio player (play/pause + filename).
struct AudioPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var playing = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if playing { player?.pause() } else { player?.play() }
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            Label(url.lastPathComponent, systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { if player == nil { player = AVPlayer(url: url) } }
    }
}
