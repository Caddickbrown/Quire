//
//  AssetsView.swift
//  Nook
//
//  Browse everything in the journal's assets/ folder (images, video, audio).
//  Right-click to reveal the file (macOS) or delete it.
//

import SwiftUI

struct AssetsView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @State private var assets: [JournalStore.AssetItem] = []

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 14)]

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
                        ForEach(assets) { item in
                            cell(item)
                                .contextMenu {
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
            Button { reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
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

    private func cell(_ item: JournalStore.AssetItem) -> some View {
        VStack(spacing: 6) {
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

            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
    }

    private func thumbnail(_ url: URL) -> Image? {
        #if os(macOS)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #endif
    }
}
