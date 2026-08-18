//
//  AssetsView.swift
//  Nook
//
//  Browse everything in the journal's assets/ folder (images, video, audio).
//  Tap to view an asset full size; right-click to reveal the file (macOS),
//  jump to the entry using it, or delete it.
//

import SwiftUI
import AVKit

enum AssetSort: String, CaseIterable, Identifiable {
    case newest, oldest, largest, kind, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest:  return "Newest first"
        case .oldest:  return "Oldest first"
        case .largest: return "Largest first"
        case .kind:    return "By kind"
        case .name:    return "By name"
        }
    }
}

/// How the gallery is broken up: one continuous grid, or date headers at day,
/// month, or year granularity (by the date of the entry using the file).
enum AssetGrouping: String, CaseIterable, Identifiable {
    case none, day, month, year
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:  return "No grouping"
        case .day:   return "By day"
        case .month: return "By month"
        case .year:  return "By year"
        }
    }

    /// Sortable section key, so section order is just the keys sorted.
    var keyFormat: String {
        switch self {
        case .none, .day: return "yyyy-MM-dd"
        case .month:      return "yyyy-MM"
        case .year:       return "yyyy"
        }
    }
}

struct AssetsView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @AppStorage("assetSort") private var sortRaw = AssetSort.newest.rawValue
    @AppStorage("assetGrouping") private var groupingRaw = AssetGrouping.none.rawValue
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    @State private var assets: [JournalStore.AssetItem] = []
    @State private var viewing: JournalStore.AssetItem?
    @State private var usagePicker: UsagePicker?

    /// Shown when an asset is used by several entries, so you can pick one.
    struct UsagePicker: Identifiable {
        let id = UUID()
        let uses: [(entry: Entry, source: EntrySource)]
    }

    // Tight square tiles with hairline gaps — a photo gallery, not a file list.
    // The maximum keeps tiles from ballooning into a handful of huge squares on
    // a wide window; they stay thumbnail-sized and the grid just gets more columns.
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 2)]

    /// Kind order for the "By kind" sort: images, then video, then audio.
    private static func kindRank(_ name: String) -> Int {
        switch MediaKind(path: name) {
        case .image: return 0
        case .video: return 1
        case .audio: return 2
        }
    }

    /// Dates come from the entry that links each file (see `AssetItem.date`),
    /// falling back to the file's own date for media no entry references.
    private var sorted: [JournalStore.AssetItem] {
        switch AssetSort(rawValue: sortRaw) ?? .newest {
        case .newest:  return assets.sorted { $0.date > $1.date }
        case .oldest:  return assets.sorted { $0.date < $1.date }
        case .largest: return assets.sorted { $0.size > $1.size }
        case .name:    return assets.sorted { $0.name < $1.name }
        case .kind:
            return assets.sorted {
                let (a, b) = (Self.kindRank($0.name), Self.kindRank($1.name))
                return a == b ? $0.date > $1.date : a < b
            }
        }
    }

    private var grouping: AssetGrouping { AssetGrouping(rawValue: groupingRaw) ?? .none }

    struct AssetSection: Identifiable {
        let id: String
        let title: String
        let items: [JournalStore.AssetItem]
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// The sorted assets cut into date sections. Sections run newest-first
    /// unless the sort is oldest-first; the items inside keep the chosen sort.
    private var sections: [AssetSection] {
        let items = sorted
        guard grouping != .none else { return [AssetSection(id: "all", title: "", items: items)] }

        let key = Self.formatter(grouping.keyFormat)
        var order: [String] = [], map: [String: [JournalStore.AssetItem]] = [:]
        for item in items {
            let k = key.string(from: item.date)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(item)
        }
        let ascending = AssetSort(rawValue: sortRaw) == .oldest
        order.sort { ascending ? $0 < $1 : $0 > $1 }
        return order.map { AssetSection(id: $0, title: title(for: $0), items: map[$0] ?? []) }
    }

    /// Section keys are machine-sortable; headers are the readable form.
    private func title(for key: String) -> String {
        switch grouping {
        case .none:  return key
        case .day:   return Theme.sectionDate(key, style: dateStyleRaw)
        case .month:
            guard let d = Self.formatter("yyyy-MM").date(from: key) else { return key }
            return Self.formatter("MMMM yyyy").string(from: d)
        case .year:  return key
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(.bar)
    }

    private func tile(_ item: JournalStore.AssetItem) -> some View {
        Button { viewing = item } label: { cell(item) }
            .buttonStyle(.plain)
            .contextMenu {
                Button { viewing = item } label: {
                    Label("View", systemImage: "eye")
                }
                goToMenu(item)
                #if os(macOS)
                Button {
                    store.revealAsset(item.url)
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                }
                #endif
                Button(role: .destructive) {
                    store.deleteAsset(item.url)
                    reload()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .destructiveAction()
            }
    }

    var body: some View {
        Group {
            if assets.isEmpty {
                ContentUnavailableView(
                    "No media yet",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Images, video, and audio you attach to entries live here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns,
                              spacing: 2,
                              pinnedViews: grouping == .none ? [] : [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.items) { tile($0) }
                            } header: {
                                if grouping != .none { header(section.title) }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .navigationTitle("Assets")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(AssetSort.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Grouping", selection: $groupingRaw) {
                    ForEach(AssetGrouping.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .sheet(item: $viewing) { item in
            AssetViewer(item: item)
        }
        .confirmationDialog("Go to Entry",
                            isPresented: Binding(get: { usagePicker != nil },
                                                 set: { if !$0 { usagePicker = nil } }),
                            presenting: usagePicker) { picker in
            ForEach(Array(picker.uses.enumerated()), id: \.offset) { _, use in
                Button(label(for: use)) { nav.open(use.entry, source: use.source) }
            }
        } message: { picker in
            Text("Used by \(picker.uses.count) entries.")
        }
        .task { reload() }
    }

    private func reload() {
        Task { assets = await store.allAssetsAsync() }
    }

    /// "Go to entry". Finding an asset's usages means reading every journal
    /// file, so it happens when this is *pressed* — building it into the menu up
    /// front scanned the whole journal once per visible cell, which made opening
    /// Assets crawl.
    private func goToMenu(_ item: JournalStore.AssetItem) -> some View {
        Button {
            let uses = store.usages(ofAsset: item.name)
            if uses.count == 1 {
                nav.open(uses[0].entry, source: uses[0].source)
            } else if uses.count > 1 {
                usagePicker = UsagePicker(uses: uses)
            }
        } label: {
            Label("Go to Entry", systemImage: "arrow.turn.up.right")
        }
    }

    private func label(for use: (entry: Entry, source: EntrySource)) -> String {
        let where_: String
        switch use.source {
        case .inbox:            where_ = "Inbox"
        case .archive(let d):   where_ = d
        case .journal(let n):   where_ = "@\(n)"
        }
        let preview = use.entry.preview.isEmpty ? use.entry.ts : use.entry.preview
        return "\(where_) · \(preview)"
    }

    /// Thumbnail only — the uuid filenames carry no meaning, so the gallery
    /// stays a clean grid of pictures.
    private func cell(_ item: JournalStore.AssetItem) -> some View {
        AssetThumbnailCell(url: item.url)
    }
}

/// A grid cell's picture: a still for images, a poster frame for video (marked
/// with a play badge so it still reads as a video), a glyph for audio. Video
/// frames have to be decoded, so it loads asynchronously and shows the glyph
/// until the frame arrives.
private struct AssetThumbnailCell: View {
    let url: URL
    @State private var image: Image?

    private var kind: MediaKind { MediaKind(path: url.lastPathComponent) }

    var body: some View {
        // The square is established first and the picture fills into it. Letting
        // a `scaledToFill` image sit loose in the stack lets the image's own size
        // drive the cell, which is what made the grid ragged.
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: glyph).font(.title).foregroundStyle(.secondary)
                }
            }
            .overlay {
                if kind == .video, image != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 3)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: url) { image = await RowThumbnail.thumbnail(for: url) }
    }

    private var glyph: String {
        switch kind {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        }
    }
}

/// One asset, full size. Images open fitted to the screen and zoom like the
/// Photos app; video and audio play.
struct AssetViewer: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.dismiss) private var dismiss
    let item: JournalStore.AssetItem

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        return "\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(size)"
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(subtitle)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem {
                        Menu {
                            ForEach(Array(store.usages(ofAsset: item.name).enumerated()), id: \.offset) { _, use in
                                Button(use.entry.preview.isEmpty ? use.entry.ts : use.entry.preview) {
                                    dismiss()
                                    nav.open(use.entry, source: use.source)
                                }
                            }
                            #if os(macOS)
                            Button {
                                store.revealAsset(item.url)
                            } label: {
                                Label("Reveal in Finder", systemImage: "magnifyingglass")
                            }
                            #endif
                        } label: {
                            Label("Options", systemImage: "ellipsis.circle")
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch MediaKind(path: item.name) {
        case .image:
            if let img = platformImage {
                ZoomableImage(image: img)
            } else {
                ContentUnavailableView("Can't open this image", systemImage: "photo")
            }
        case .video:
            VideoPlayer(player: AVPlayer(url: item.url))
        case .audio:
            AudioPlayerView(url: item.url).padding()
        }
    }

    #if os(macOS)
    private var platformImage: NSImage? { NSImage(contentsOf: item.url) }
    #else
    private var platformImage: UIImage? { UIImage(contentsOfFile: item.url.path) }
    #endif
}

#if os(iOS)
/// A scroll-view-backed image: opens fitted, pinch to zoom, drag to pan,
/// double-tap to zoom in and back out, rubber-banding at the edges — the Photos
/// app behaviour. SwiftUI's own gestures don't reproduce it convincingly.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = LayoutReportingScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)

        context.coordinator.scrollView = scroll
        context.coordinator.imageView = imageView
        scroll.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.fitIfBoundsChanged()
        }

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Reports every layout pass, so the image can be re-fitted after a rotation
    /// or a resize (a scroll view has no delegate callback for that).
    final class LayoutReportingScrollView: UIScrollView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        private var lastSize: CGSize = .zero

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

        /// Refit only when the viewport actually changed, so a re-render can't
        /// throw away the zoom the reader set.
        func fitIfBoundsChanged() {
            guard let scroll = scrollView, let imageView else { return }
            let size = scroll.bounds.size
            guard size != lastSize, size.width > 0, size.height > 0 else { return }
            lastSize = size
            scroll.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size
            centre()
        }

        /// Keep the image in the middle while it's smaller than the viewport.
        private func centre() {
            guard let scroll = scrollView, let imageView else { return }
            let x = max(0, (scroll.bounds.width - imageView.frame.width) / 2)
            let y = max(0, (scroll.bounds.height - imageView.frame.height) / 2)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                // Zoom to a third of the viewport around the tapped point.
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2,
                                       y: point.y - size.height / 2,
                                       width: size.width,
                                       height: size.height),
                            animated: true)
            }
        }
    }
}
#else
/// macOS: an NSScrollView gives native magnification (pinch / ⌘-scroll) and
/// scrolling around a zoomed image.
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 6
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = scroll.contentView.bounds
        imageView.autoresizingMask = [.width, .height]
        scroll.documentView = imageView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? NSImageView)?.image = image
    }
}
#endif
