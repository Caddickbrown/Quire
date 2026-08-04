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

struct AssetsView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @AppStorage("assetSort") private var sortRaw = AssetSort.newest.rawValue
    @State private var assets: [JournalStore.AssetItem] = []
    @State private var viewing: JournalStore.AssetItem?

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 14)]

    /// Kind order for the "By kind" sort: images, then video, then audio.
    private static func kindRank(_ name: String) -> Int {
        switch MediaKind(path: name) {
        case .image: return 0
        case .video: return 1
        case .audio: return 2
        }
    }

    private var sorted: [JournalStore.AssetItem] {
        switch AssetSort(rawValue: sortRaw) ?? .newest {
        case .newest:  return assets.sorted { $0.modified > $1.modified }
        case .oldest:  return assets.sorted { $0.modified < $1.modified }
        case .largest: return assets.sorted { $0.size > $1.size }
        case .name:    return assets.sorted { $0.name < $1.name }
        case .kind:
            return assets.sorted {
                let (a, b) = (Self.kindRank($0.name), Self.kindRank($1.name))
                return a == b ? $0.modified > $1.modified : a < b
            }
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
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(sorted) { item in
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
                                }
                        }
                    }
                    .padding()
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
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .sheet(item: $viewing) { item in
            AssetViewer(item: item)
        }
        .task { reload() }
    }

    private func reload() { assets = store.allAssets() }

    /// "Go to entry" — direct if one usage, a submenu to pick if several.
    @ViewBuilder
    private func goToMenu(_ item: JournalStore.AssetItem) -> some View {
        let uses = store.usages(ofAsset: item.name)
        if uses.count == 1 {
            Button {
                nav.open(uses[0].entry, source: uses[0].source)
            } label: {
                Label("Go to Entry", systemImage: "arrow.turn.up.right")
            }
        } else if uses.count > 1 {
            Menu {
                ForEach(Array(uses.enumerated()), id: \.offset) { _, use in
                    Button(label(for: use)) {
                        nav.open(use.entry, source: use.source)
                    }
                }
            } label: {
                Label("Go to Entry (\(uses.count))", systemImage: "arrow.turn.up.right")
            }
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
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            switch MediaKind(path: item.name) {
            case .image:
                if let img = thumbnail(item.url) {
                    img.resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            case .video:
                Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
            case .audio:
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func thumbnail(_ url: URL) -> Image? {
        #if os(macOS)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #endif
    }
}

/// One asset, full size. Images pinch/scroll to zoom; video and audio play.
struct AssetViewer: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.dismiss) private var dismiss
    let item: JournalStore.AssetItem

    @State private var zoom: CGFloat = 1

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        return "\(item.modified.formatted(date: .abbreviated, time: .shortened)) · \(size)"
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
            if let img = fullImage {
                ScrollView([.horizontal, .vertical]) {
                    img.resizable().scaledToFit()
                        .scaleEffect(zoom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .gesture(MagnificationGesture()
                    .onChanged { zoom = max(1, min(6, $0)) }
                    .onEnded { _ in if zoom < 1.05 { zoom = 1 } })
            } else {
                ContentUnavailableView("Can't open this image", systemImage: "photo")
            }
        case .video:
            VideoPlayer(player: AVPlayer(url: item.url))
        case .audio:
            AudioPlayerView(url: item.url).padding()
        }
    }

    private var fullImage: Image? {
        #if os(macOS)
        return NSImage(contentsOf: item.url).map { Image(nsImage: $0) }
        #else
        return UIImage(contentsOfFile: item.url.path).map { Image(uiImage: $0) }
        #endif
    }
}
