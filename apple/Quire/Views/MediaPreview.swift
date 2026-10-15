//
//  MediaPreview.swift
//  Quire
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

/// The rendered body itself, laid out top-to-bottom with no scroll view of its
/// own — so it can sit inside one (`MediaPreview`) or inside somebody else's
/// scroll, as the Stream does for every entry on the page.
/// How a rendered `@tag` opens its tag page. Optional: the external display
/// renders the same body with no navigation to push into, so nil means the
/// tint stays but taps do nothing.
private struct OpenTagKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}
extension EnvironmentValues {
    var quireOpenTag: ((String) -> Void)? {
        get { self[OpenTagKey.self] }
        set { self[OpenTagKey.self] = newValue }
    }
}

struct MediaBody: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quireOpenTag) private var openTag
    @Environment(\.accent) private var accent
    @AppStorage("highlightTags") private var highlightTags = true
    let text: String
    let font: Font
    let textColor: Color
    /// Inset around the rendered body. Defaults to the app's writing gutter, so
    /// Preview lines up with the composer and the entry editor instead of
    /// shifting the text sideways when you toggle modes. The external display
    /// passes 0 — it supplies its own, much larger margin, and a second inset
    /// would indent a read entry further than a composed one on that screen.
    var contentPadding: CGFloat = 16
    /// When provided, captions become editable: tapping one (or "Add caption")
    /// rewrites the image's alt text and hands the whole updated body back here.
    var onUpdateText: ((String) -> Void)? = nil
    /// Selectable prose is the right default for reading one entry. Lists of
    /// them turn it off: on macOS a right-click inside selectable text raises
    /// the system's own Copy menu instead of the row's context menu.
    var selectableText = true
    /// Cap on how tall an inline image draws.
    var maxImageHeight: CGFloat = 520
    /// When set, images are decoded through the downsampling thumbnail cache at
    /// this pixel size rather than loaded at full resolution — what the Stream
    /// uses so scrolling the whole corpus doesn't decode every photo in full.
    var thumbnailSide: Int? = nil

    @State private var editingIndex: Int?
    @State private var draftCaption = ""

    private var segments: [MDSegment] { parseMediaSegments(text) }
    private var editorPresented: Binding<Bool> {
        Binding(get: { editingIndex != nil }, set: { if !$0 { editingIndex = nil } })
    }

    /// Segments paired with how many checkbox lines precede each one, so a
    /// tapped checkbox can be located in the *full* body text.
    private var indexedSegments: [(index: Int, seg: MDSegment, checkboxStart: Int)] {
        var out: [(Int, MDSegment, Int)] = []
        var count = 0
        for (i, seg) in segments.enumerated() {
            out.append((i, seg, count))
            if case .text(let t) = seg { count += Self.bodyBlocks(t).filter(\.isCheckbox).count }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(indexedSegments, id: \.index) { index, seg, checkboxStart in
                switch seg {
                case .text(let t):
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        textRun(t, checkboxStart: checkboxStart)
                    }
                case .image(let path, let caption):
                    mediaView(path, caption: caption, index: index)
                        .padding(.vertical, 4)
                }
            }
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A tapped @tag opens its tag page; every other link stays a link.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "quire-tag", let host = url.host, !host.isEmpty else {
                return .systemAction
            }
            openTag?(host)
            return .handled
        })
        .alert("Caption", isPresented: editorPresented) {
            TextField("Caption", text: $draftCaption)
            Button("Save") { commitCaption() }
            Button("Cancel", role: .cancel) { editingIndex = nil }
        } message: {
            Text("Shown beneath the image. Stored as the image's alt text.")
        }
    }

    // MARK: Checkboxes (- [ ] task lines render as tappable boxes)

    /// A text run broken into prose paragraphs and checkbox lines.
    enum BodyBlock {
        case prose(String)
        case checkbox(done: Bool, label: String)
        var isCheckbox: Bool { if case .checkbox = self { return true }; return false }
    }

    private static let checkboxLineRegex = try! NSRegularExpression(
        pattern: #"^(\s*[-*+] \[)( |x|X)(\] )(.*)$"#)

    /// Split a text run by line, grouping consecutive non-checkbox lines back
    /// into prose blocks. Order matches the order of checkbox lines on disk.
    static func bodyBlocks(_ t: String) -> [BodyBlock] {
        var blocks: [BodyBlock] = []
        var prose: [String] = []
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.prose(joined)) }
            prose = []
        }
        for line in t.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let m = checkboxLineRegex.firstMatch(in: line, range: range),
               let mark = Range(m.range(at: 2), in: line),
               let label = Range(m.range(at: 4), in: line) {
                flushProse()
                blocks.append(.checkbox(done: line[mark] != " ", label: String(line[label])))
            } else {
                prose.append(line)
            }
        }
        flushProse()
        return blocks
    }

    /// Flip the `globalIndex`-th checkbox line of the whole body and hand the
    /// updated text back. The count walks the same per-line regex the renderer
    /// used, so the tapped box and the flipped line always agree.
    private func toggleCheckbox(globalIndex: Int) {
        guard let onUpdateText else { return }
        var count = 0
        var lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard let m = Self.checkboxLineRegex.firstMatch(in: line, range: range) else { continue }
            if count == globalIndex {
                guard let head = Range(m.range(at: 1), in: line),
                      let mark = Range(m.range(at: 2), in: line),
                      let tail = Range(m.range(at: 3), in: line),
                      let label = Range(m.range(at: 4), in: line) else { return }
                let flipped = line[mark] == " " ? "x" : " "
                lines[i] = line[head] + flipped + line[tail] + line[label]
                onUpdateText(lines.joined(separator: "\n"))
                return
            }
            count += 1
        }
    }

    @ViewBuilder
    private func textRun(_ t: String, checkboxStart: Int) -> some View {
        let blocks = Self.bodyBlocks(t)
        if !blocks.contains(where: \.isCheckbox) {
            plainRun(t.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            let indexed: [(offset: Int, block: BodyBlock, checkboxIndex: Int)] = {
                var out: [(Int, BodyBlock, Int)] = []
                var n = checkboxStart
                for (i, block) in blocks.enumerated() {
                    out.append((i, block, n))
                    if block.isCheckbox { n += 1 }
                }
                return out
            }()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(indexed, id: \.offset) { _, block, checkboxIndex in
                    switch block {
                    case .prose(let p):
                        plainRun(p)
                    case .checkbox(let done, let label):
                        checkboxRow(done: done, label: label, globalIndex: checkboxIndex)
                    }
                }
            }
        }
    }

    private func checkboxRow(done: Bool, label: String, globalIndex: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                toggleCheckbox(globalIndex: globalIndex)
            } label: {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(font)
                    .foregroundStyle(done ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .disabled(onUpdateText == nil)
            Text(markdown(label))
                .font(font)
                .strikethrough(done, color: .secondary)
                .foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(textColor))
        }
    }

    @ViewBuilder
    private func plainRun(_ t: String) -> some View {
        let run = Text(markdown(t))
            .font(font)
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity, alignment: .leading)
        if selectableText { run.textSelection(.enabled) } else { run }
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

    /// Colour every `@tag` in the rendered text — and link it, so a rendered
    /// tag is a way into its tag page, not just paint. Offsets are converted
    /// through Character distances so multi-byte text (emoji) doesn't shift
    /// the ranges.
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
            attributed[start..<end].underlineStyle = nil
            let name = String(plain[r].dropFirst())   // strip the @
            attributed[start..<end].link = URL(string: "quire-tag://\(name)")
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
            let text = Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
            if selectableText { text.textSelection(.enabled) } else { text }
        }
    }

    @ViewBuilder
    private func mediaContent(_ path: String) -> some View {
        let url = store.assetURL(forRelative: path)
        switch MediaKind(path: path) {
        case .video:
            if let url {
                VideoView(url: url)
                    .frame(height: min(300, maxImageHeight))
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else { missing(path) }
        case .audio:
            if let url { AudioPlayerView(url: url) } else { missing(path) }
        case .image:
            if let image = inlineImage(url) {
                image.resizable().scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(maxHeight: maxImageHeight)
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

    /// Full-resolution by default; downsampled through `RowThumbnail` when the
    /// caller asked for thumbnails.
    private func inlineImage(_ url: URL?) -> Image? {
        guard let url else { return nil }
        if let thumbnailSide { return RowThumbnail.load(url, side: thumbnailSide) ?? loadImage(url) }
        return loadImage(url)
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

/// Render an entry's body — markdown text with its media inline — in a scroll
/// view of its own. The entry editor's Preview mode and the external display
/// use this; the Stream renders `MediaBody` directly inside its own scroll.
struct MediaPreview: View {
    let text: String
    let font: Font
    let textColor: Color
    var contentPadding: CGFloat = 16
    var onUpdateText: ((String) -> Void)? = nil

    var body: some View {
        ScrollView {
            MediaBody(text: text,
                      font: font,
                      textColor: textColor,
                      contentPadding: contentPadding,
                      onUpdateText: onUpdateText)
        }
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

    /// The cached thumbnail only — nil rather than decoding.
    static func cached(_ url: URL, side: Int = 96) -> Image? {
        cache.object(forKey: cacheKey(url, side))?.image
    }

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

/// The trailing thumbnail on an entry row — drawn only when the entry links an
/// image, so text-only rows keep their current shape.
///
/// The square bleeds into the row's own insets: negative padding shrinks what
/// it reports to the layout, so the picture draws `bleed` points taller than
/// the space it takes up and sits closer to the row's edges without the row
/// growing or the text moving. A modest bleed, so a sliver of margin survives;
/// it stays well under the list's vertical cell inset, so nothing is clipped.
struct EntryThumbnail: View {
    @EnvironmentObject private var store: JournalStore
    let entry: Entry
    var side: CGFloat = 84
    var bleed: CGFloat = 24

    @State private var image: Image?

    var body: some View {
        // Async decode (cache hit stays instant): the synchronous ImageIO call
        // in `body` cost a stutter per fresh row on first scroll-past.
        if let path = entry.firstImagePath, let url = store.assetURL(forRelative: path) {
            Group {
                if let image {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(.vertical, -bleed)
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .task(id: url) {
                if let hit = RowThumbnail.cached(url, side: 200) { image = hit; return }
                image = await Task.detached(priority: .userInitiated) {
                    RowThumbnail.load(url, side: 200)
                }.value
            }
        }
    }
}

/// An inline video player that owns one `AVPlayer` for the view's lifetime.
/// Handing `VideoPlayer` a freshly-built `AVPlayer(url:)` from inside `body`
/// made a new one on every re-evaluation, which restarted playback (and left
/// the old players behind); `AudioPlayerView` below already does it this way.
/// Sizing and clipping are left to the caller.
struct VideoView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
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
