//
//  MediaPreview.swift
//  Nook
//
//  Renders an entry's body with inline images. Images are stored as Obsidian-
//  style markdown links (![](assets/…)); this splits the text on those links and
//  draws the referenced image files inline.
//

import SwiftUI
import AVKit
import ImageIO
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum MDSegment {
    case text(String)
    case image(path: String, caption: String)   // relative asset path/URL + alt-text caption
}

/// Split body text into text runs and image links. The image link's alt text
/// (`![caption](path)`) is carried through as the caption — the same convention
/// Obsidian's "Image Captions" plugin uses, so it round-trips as plain markdown.
func parseMediaSegments(_ s: String) -> [MDSegment] {
    let regex = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
    let ns = s as NSString
    var segments: [MDSegment] = []
    var cursor = 0
    for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        if m.range.location > cursor {
            segments.append(.text(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
        }
        let caption = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        segments.append(.image(path: ns.substring(with: m.range(at: 2)), caption: caption))
        cursor = m.range.location + m.range.length
    }
    if cursor < ns.length {
        segments.append(.text(ns.substring(from: cursor)))
    }
    return segments
}

/// Same `@tag` shape the parser and the editor use.
private let previewTagRegex = try! NSRegularExpression(pattern: #"@[a-zA-Z][a-zA-Z0-9_-]*"#)

struct MediaPreview: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.accent) private var accent
    @AppStorage("highlightTags") private var highlightTags = true
    let text: String
    let font: Font
    let textColor: Color
    /// When provided, captions become editable: tapping one (or "Add caption")
    /// rewrites the image's alt text and hands the whole updated body back here.
    var onUpdateText: ((String) -> Void)? = nil

    @State private var editingIndex: Int?
    @State private var draftCaption = ""

    private var segments: [MDSegment] { parseMediaSegments(text) }
    private var editorPresented: Binding<Bool> {
        Binding(get: { editingIndex != nil }, set: { if !$0 { editingIndex = nil } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                    switch seg {
                    case .text(let t):
                        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            Text(markdown(trimmed))
                                .font(font)
                                .foregroundStyle(textColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    case .image(let path, let caption):
                        mediaView(path, caption: caption, index: index)
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Caption", isPresented: editorPresented) {
            TextField("Caption", text: $draftCaption)
            Button("Save") { commitCaption() }
            Button("Cancel", role: .cancel) { editingIndex = nil }
        } message: {
            Text("Shown beneath the image. Stored as the image's alt text.")
        }
    }

    private func commitCaption() {
        guard let index = editingIndex else { return }
        var segs = segments
        guard index < segs.count, case .image(let path, _) = segs[index] else { editingIndex = nil; return }
        // Keep the alt text link-safe: no newlines or closing brackets.
        let clean = draftCaption
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces)
        segs[index] = .image(path: path, caption: clean)
        onUpdateText?(reconstruct(segs))
        editingIndex = nil
    }

    /// Render segments back to markdown — text runs verbatim, images as
    /// `![caption](path)` — so only the edited caption changes.
    private func reconstruct(_ segs: [MDSegment]) -> String {
        segs.map { seg in
            switch seg {
            case .text(let t): return t
            case .image(let path, let caption):
                return caption.isEmpty ? "![](\(path))" : "![\(caption)](\(path))"
            }
        }.joined()
    }

    /// Render inline markdown (bold/italic/links/code), preserving line breaks,
    /// then tint any `@tags` the same way the editor does.
    private func markdown(_ s: String) -> AttributedString {
        var out = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(s)
        if highlightTags { tintTags(in: &out) }
        return out
    }

    /// Colour every `@tag` in the rendered text. Offsets are converted through
    /// Character distances so multi-byte text (emoji) doesn't shift the ranges.
    private func tintTags(in attributed: inout AttributedString) {
        let plain = String(attributed.characters)
        let full = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        for match in previewTagRegex.matches(in: plain, range: full) {
            guard let r = Range(match.range, in: plain) else { continue }
            let lower = plain.distance(from: plain.startIndex, to: r.lowerBound)
            let upper = plain.distance(from: plain.startIndex, to: r.upperBound)
            let start = attributed.index(attributed.startIndex, offsetByCharacters: lower)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: upper)
            attributed[start..<end].foregroundColor = accent
        }
    }

    /// The media itself plus its caption (the image link's alt text), drawn as a
    /// centred figcaption beneath it — Obsidian-style. Tappable to edit when the
    /// view is editable.
    @ViewBuilder
    private func mediaView(_ path: String, caption: String, index: Int) -> some View {
        VStack(spacing: 6) {
            mediaContent(path)
            captionView(caption: caption, index: index)
        }
    }

    @ViewBuilder
    private func captionView(caption: String, index: Int) -> some View {
        if onUpdateText != nil {
            Button {
                draftCaption = caption
                editingIndex = index
            } label: {
                if caption.isEmpty {
                    Label("Add caption", systemImage: "text.below.photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
        } else if !caption.isEmpty {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func mediaContent(_ path: String) -> some View {
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
                    .frame(maxWidth: .infinity, alignment: .center)
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

/// Small square thumbnails for list rows. Decoded at thumbnail size via ImageIO
/// (a full-resolution photo never lands in memory) and cached by path, so
/// scrolling a long inbox stays cheap.
enum RowThumbnail {
    final class Box {
        let image: Image
        init(_ image: Image) { self.image = image }
    }
    private static let cache = NSCache<NSString, Box>()

    /// Synchronous still for an image file — cheap enough for a list row.
    static func load(_ url: URL, side: Int = 96) -> Image? {
        let key = cacheKey(url, side)
        if let hit = cache.object(forKey: key) { return hit.image }
        guard let image = decode(url, side: side) else { return nil }
        cache.setObject(Box(image), forKey: key)
        return image
    }

    /// A thumbnail for any asset: a downsampled still for images, a poster frame
    /// for video (generating one needs to decode, so this is async), nil for
    /// audio — there's no frame to show.
    static func thumbnail(for url: URL, side: Int = 200) async -> Image? {
        let key = cacheKey(url, side)
        if let hit = cache.object(forKey: key) { return hit.image }
        let image: Image?
        switch MediaKind(path: url.lastPathComponent) {
        case .image: image = decode(url, side: side)
        case .video: image = await posterFrame(url, side: side)
        case .audio: image = nil
        }
        if let image { cache.setObject(Box(image), forKey: key) }
        return image
    }

    private static func cacheKey(_ url: URL, _ side: Int) -> NSString {
        "\(url.path)#\(side)" as NSString
    }

    private static func decode(_ url: URL, side: Int) -> Image? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return platformImage(cg)
    }

    private static func posterFrame(_ url: URL, side: Int) async -> Image? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true          // respect the recorded rotation
        generator.maximumSize = CGSize(width: side * 2, height: side * 2)
        // A moment in rather than frame zero, which is often black.
        let time = CMTime(seconds: 0.3, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return platformImage(cg)
    }

    private static func platformImage(_ cg: CGImage) -> Image {
        #if canImport(AppKit)
        return Image(nsImage: NSImage(cgImage: cg, size: .zero))
        #else
        return Image(uiImage: UIImage(cgImage: cg))
        #endif
    }
}

/// The leading thumbnail on an entry row — drawn only when the entry links an
/// image, so text-only rows keep their current shape.
struct EntryThumbnail: View {
    @EnvironmentObject private var store: JournalStore
    let entry: Entry
    var side: CGFloat = 56

    var body: some View {
        if let path = entry.firstImagePath,
           let url = store.assetURL(forRelative: path),
           let image = RowThumbnail.load(url) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
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
