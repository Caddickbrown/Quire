//
//  WritingView.swift
//  Nook
//
//  The composer. A title field + date/time picker sit above the body; everything
//  autosaves continuously into one inbox draft in the jnl format
//  ([timestamp] title / body). Paste multi-entry text and "Import" splits it into
//  separate drafts.
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct WritingView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accent) private var accent

    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("highlightTags") private var highlightTags = true

    @State private var title = ""
    @State private var date = Date()
    @State private var text = ""
    @State private var activeTS: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var showingImagePicker = false
    @State private var showingVideoRecorder = false
    @State private var showingPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @StateObject private var recorder = AudioRecorder()
    @FocusState private var bodyFocused: Bool
    @FocusState private var titleFocused: Bool

    private var size: CGFloat { CGFloat(fontSize) }
    private var font: Font { Theme.font(writingFontRaw, size: size) }
    private var hasText: Bool {
        !(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Title", text: $title)
                    .font(font.weight(.semibold))
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { bodyFocused = true }
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        #if os(macOS)
                        .datePickerStyle(.field)
                        #else
                        .datePickerStyle(.compact)
                        #endif
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            WritingTextEditor(text: $text,
                              fontRaw: writingFontRaw,
                              size: size,
                              textColor: Theme.bodyText(colorScheme),
                              lineSpacing: Theme.lineSpacing(for: size),
                              highlightTags: highlightTags,
                              accent: accent)
                .focused($bodyFocused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Begin writing")
                            .font(font)
                            .foregroundStyle(Theme.placeholder(colorScheme))
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
        .frame(maxWidth: 1520)
        .frame(maxWidth: .infinity)
        .navigationTitle("Write")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup {
                Button {
                    newEntry()
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasText)
                .help("Save to inbox & start a new entry (⌘S)")
                Button {
                    toggleRecord()
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic")
                        .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
                }
                .help(recorder.isRecording ? "Stop recording" : "Record audio")
                Menu {
                    #if os(iOS)
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Photo Library", systemImage: "photo")
                    }
                    Button {
                        showingImagePicker = true
                    } label: {
                        Label("Choose File", systemImage: "folder")
                    }
                    #else
                    Button {
                        showingImagePicker = true
                    } label: {
                        Label("Attach Media", systemImage: "paperclip")
                    }
                    #endif
                    Button {
                        showingVideoRecorder = true
                    } label: {
                        Label("Record Video", systemImage: "video")
                    }
                    Button {
                        promoteFirstLine()
                    } label: {
                        Label("Promote first line to title", systemImage: "arrow.up.to.line")
                    }
                    .disabled(!hasFirstBodyLine)
                    Divider()
                    Button(role: .destructive) {
                        discard()
                    } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .destructiveAction()
                    .disabled(!hasText && activeTS == nil)
                    Button {
                        importEntries()
                    } label: {
                        Label("Import as separate entries", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fileImporter(isPresented: $showingImagePicker,
                      allowedContentTypes: [.image, .movie, .audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { attachImage(url) }
        }
        #if os(iOS)
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) { _, item in
            if let item { loadPhoto(item) }
        }
        #endif
        .onDrop(of: [.image, .movie, .audio, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $showingVideoRecorder) {
            VideoRecorderView { url in
                if let rel = store.importAsset(from: url) {
                    let md = "![](\(rel))"
                    text = text.isEmpty ? md : text + "\n\n" + md
                }
            }
        }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: date) { _, _ in scheduleSave() }
        .onChange(of: nav.newEntrySignal) { _, _ in newEntry() }
        .onAppear { focusStart() }
        .onDisappear { flush() }
        .overlay(alignment: .bottom) {
            if recorder.isRecording {
                RecordingBanner(elapsed: recorder.elapsedString) { toggleRecord() }
            } else if let toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
    }

    private func toggleRecord() {
        if recorder.isRecording {
            if let data = recorder.stop(), let rel = store.saveAsset(data, ext: "m4a") {
                let md = "![](\(rel))"
                text = text.isEmpty ? md : text + "\n\n" + md
            }
        } else {
            Task { await recorder.start() }
        }
    }

    private var hasFirstBodyLine: Bool {
        text.split(separator: "\n", omittingEmptySubsequences: true).first != nil
    }

    /// Move the first non-empty body line into the title field.
    private func promoteFirstLine() {
        var lines = text.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return }
        title = lines[idx].trimmingCharacters(in: .whitespaces)
        lines.remove(at: idx)
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Autosave

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit(reindex: Bool = false) {
        guard hasText else {
            if let ts = activeTS { store.removeDraft(timestamp: ts); activeTS = nil }
            return
        }
        let ts = JournalStore.ts(from: date)
        store.upsertDraft(previous: activeTS, timestamp: ts, title: title, body: text, reindex: reindex)
        activeTS = ts
    }

    private func flush() {
        saveTask?.cancel()
        commit(reindex: true)
    }

    /// Where the cursor lands when the composer opens or resets. On iOS people
    /// tend to title-then-write, so start in the title; on macOS keep the body
    /// focused so you can type immediately.
    private func focusStart() {
        #if os(iOS)
        titleFocused = true
        #else
        bodyFocused = true
        #endif
    }

    private func newEntry() {
        let saved = hasText
        flush()
        reset()
        focusStart()
        if saved { showToast("Saved to inbox") }
    }

    /// Delete the current draft (autosaved to the inbox) without keeping it.
    private func discard() {
        saveTask?.cancel()
        if let ts = activeTS { store.removeDraft(timestamp: ts); activeTS = nil }
        reset()
        focusStart()
        showToast("Discarded")
    }

    private func importEntries() {
        // Drop the single working draft, then split the pasted text into drafts.
        if let ts = activeTS { store.removeDraft(timestamp: ts); activeTS = nil }
        let n = store.importDrafts(from: text)
        reset()
        showToast(n == 1 ? "Imported 1 entry" : "Imported \(n) entries")
    }

    private func attachImage(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        insertMedia(data, ext: ext)
    }

    private func insertMedia(_ data: Data, ext: String) {
        guard let rel = store.saveAsset(data, ext: ext) else { return }
        let md = "![](\(rel))"
        text = text.isEmpty ? md : text + "\n\n" + md
    }

    /// Load a picked photo/video and attach it (iOS Photos library).
    private func loadPhoto(_ item: PhotosPickerItem) {
        Task { @MainActor in
            defer { photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            insertMedia(data, ext: ext)
        }
    }

    /// Handle dropped items: file URLs (macOS/Files) or raw image/movie/audio
    /// data (a photo dragged out of the iOS Photos app has no file URL).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in attachImage(url) }
                }
            } else if let id = provider.registeredTypeIdentifiers.first(where: { isMedia($0) }),
                      let type = UTType(id) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: id) { data, _ in
                    guard let data else { return }
                    let ext = type.preferredFilenameExtension ?? "dat"
                    Task { @MainActor in insertMedia(data, ext: ext) }
                }
            }
        }
        return handled
    }

    private func isMedia(_ id: String) -> Bool {
        guard let t = UTType(id) else { return false }
        return t.conforms(to: .image) || t.conforms(to: .movie) || t.conforms(to: .audio)
    }

    private func reset() {
        activeTS = nil
        title = ""
        text = ""
        date = Date()
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { toast = nil }
        }
    }
}
