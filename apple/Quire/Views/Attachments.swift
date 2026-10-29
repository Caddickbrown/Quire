//
//  Attachments.swift
//  Quire
//
//  Getting media into an entry, shared by every writing surface — the iPhone
//  composer, the iPad/Mac composer and the entry editor — so a photo picked,
//  dropped, pasted or captured lands the same way wherever you write: copied
//  into assets/YYYY/MM/ and linked as `![](assets/…)` in the body.
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a paste brought with it, when it was media rather than text.
enum PastedMedia {
    case data(Data, ext: String)
    case file(URL)
}

@MainActor
enum Attach {
    /// The types a body link can show; anything else would sit behind a
    /// link that renders nothing.
    static let types: [UTType] = [.image, .movie, .audio]

    static func isMedia(_ type: UTType) -> Bool {
        types.contains { type.conforms(to: $0) }
    }

    /// A file's own content type when the file system knows one, its
    /// extension otherwise.
    static func isMediaFile(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        return type.map(isMedia) ?? false
    }

    /// Copy a picked or dropped file in; returns its relative path.
    static func file(_ url: URL, into store: JournalStore) -> String? {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        return store.saveAsset(data, ext: ext)
    }

    static func pasted(_ media: PastedMedia, into store: JournalStore) -> String? {
        switch media {
        case .data(let data, let ext): return store.saveAsset(data, ext: ext)
        case .file(let url): return file(url, into: store)
        }
    }

    /// A Photos pick. Videos come across as a file (`PickedMovie`) so they
    /// never sit in memory whole; images still come as data (they're
    /// downsampled on save anyway).
    static func photo(_ item: PhotosPickerItem, into store: JournalStore) async -> String? {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
           let movie = try? await item.loadTransferable(type: PickedMovie.self) {
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return store.importAsset(from: movie.url)
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        return store.saveAsset(data, ext: ext)
    }

    /// Dropped items: file URLs (macOS/Files) or raw image/movie/audio data (a
    /// photo dragged out of the iOS Photos app has no file URL). `link` gets
    /// each attachment as it lands; `refused` hears about a non-media file.
    static func drop(_ providers: [NSItemProvider], into store: JournalStore,
                     link: @escaping @MainActor (String) -> Void,
                     refused: @escaping @MainActor () -> Void) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        guard isMediaFile(url) else { refused(); return }
                        if let rel = file(url, into: store) { link(rel) }
                    }
                }
            } else if let id = provider.registeredTypeIdentifiers.first(where: { UTType($0).map(isMedia) ?? false }),
                      let type = UTType(id) {
                handled = true
                if type.conforms(to: .movie) {
                    // A dropped video lands as a temp file, not a Data buffer.
                    provider.loadFileRepresentation(forTypeIdentifier: id) { url, _ in
                        guard let url else { return }
                        // The provider deletes its file when this returns; copy first.
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent("\(UUID().uuidString).\(type.preferredFilenameExtension ?? "mov")")
                        try? FileManager.default.copyItem(at: url, to: dest)
                        Task { @MainActor in
                            if let rel = store.importAsset(from: dest) { link(rel) }
                            try? FileManager.default.removeItem(at: dest)
                        }
                    }
                } else {
                    provider.loadDataRepresentation(forTypeIdentifier: id) { data, _ in
                        guard let data else { return }
                        let ext = type.preferredFilenameExtension ?? "dat"
                        Task { @MainActor in if let rel = store.saveAsset(data, ext: ext) { link(rel) } }
                    }
                }
            }
        }
        return handled
    }

    /// Media on the clipboard, if a paste should attach rather than type.
    /// Copied files come first (Finder), then image data; anything carrying
    /// text pastes as text.
    static func pasteboardMedia() -> PastedMedia? {
        #if os(macOS)
        let pb = NSPasteboard.general
        // A copied file also carries its Finder icon as an image: a file that
        // isn't media pastes as its name, never as that icon.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.first(where: isMediaFile).map { .file($0) }
        }
        // Text copied from a rich editor can carry a picture of itself.
        if pb.string(forType: .string) != nil { return nil }
        if let data = pb.data(forType: .png) { return .data(data, ext: "png") }
        if let tiff = pb.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return .data(png, ext: "png")
        }
        return nil
        #else
        let pb = UIPasteboard.general
        // Text copied from a rich editor can carry a picture of itself.
        guard pb.hasImages, !pb.hasStrings else { return nil }
        for type in [UTType.heic, .jpeg, .png, .gif] {
            if let data = pb.data(forPasteboardType: type.identifier) {
                return .data(data, ext: type.preferredFilenameExtension ?? "png")
            }
        }
        if let data = pb.image?.pngData() { return .data(data, ext: "png") }
        return nil
        #endif
    }
}

/// The paperclip: every way to attach, in one visible place. `voice` adds a
/// voice note for screens without a mic button of their own.
struct AttachMenu<Icon: View>: View {
    var photoLibrary: () -> Void
    var file: () -> Void
    var photo: () -> Void
    var video: () -> Void
    var voice: (() -> Void)? = nil
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Menu {
            #if os(iOS)
            Button(action: photoLibrary) { Label("Photo Library", systemImage: "photo") }
            #endif
            Button(action: photo) { Label("Take Photo", systemImage: "camera") }
            Button(action: video) { Label("Record Video", systemImage: "video") }
            if let voice {
                Button(action: voice) { Label("Voice Note", systemImage: "mic") }
            }
            Button(action: file) { Label("Choose File", systemImage: "folder") }
        } label: {
            icon()
        }
        .help("Attach a photo, video, audio or file")
        .accessibilityLabel("Attach")
    }
}

extension AttachMenu where Icon == Image {
    init(photoLibrary: @escaping () -> Void, file: @escaping () -> Void,
         photo: @escaping () -> Void, video: @escaping () -> Void) {
        self.init(photoLibrary: photoLibrary, file: file, photo: photo, video: video,
                  icon: { Image(systemName: "paperclip") })
    }
}
