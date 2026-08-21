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
import CoreTransferable

/// A picked video delivered as a file, never as in-memory `Data` — a Photos
/// clip can be gigabytes, and `loadTransferable(type: Data.self)` buffers all
/// of it before a byte reaches disk. Shared by the composer and the entry
/// editor.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            // The received file dies when this closure returns; copy it out.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(received.file.pathExtension)")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}

struct WritingView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accent) private var accent
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("highlightTags") private var highlightTags = true
    @AppStorage("typewriterScroll") private var typewriterScroll = false
    @AppStorage("focusParagraph") private var focusParagraph = false
    @AppStorage(PromptDeck.enabledKey) private var promptsOn = false

    @State private var promptOffset = 0
    @State private var transcribing = false
    @State private var title = ""
    @State private var date = Date()
    @State private var text = ""
    @State private var activeTS: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var toast: String?
    @State private var showingImagePicker = false
    @State private var showingVideoRecorder = false
    @State private var showingPhotoCapture = false
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
                              accent: accent,
                              typewriter: typewriterScroll,
                              focusParagraph: focusParagraph,
                              tagSuggestions: store.tagCounts.map { String($0.tag.dropFirst()) })
                .focused($bodyFocused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(promptsOn ? PromptDeck.prompt(offset: promptOffset) : "Begin writing")
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
            #if os(iOS)
            // The composer is reached by setting the section, not by pushing,
            // so at regular width it gets no system back button — without this
            // there is no way out of it. Saves on the way, like every other exit
            // from here. Compact width is excluded: there the split view is
            // collapsed, so setting the section *is* a push and UIKit already
            // supplies a back chevron — adding ours put two side by side.
            if sizeClass != .compact {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        flush()
                        nav.section = nil
                    } label: {
                        Label("Done", systemImage: "chevron.left")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Save to inbox & back to the menu")
                }
            }
            #endif
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
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record audio")
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
                        showingPhotoCapture = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
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
                    Menu {
                        let names = store.templateNames()
                        if names.isEmpty {
                            Text("No templates — add one in Settings")
                        } else {
                            ForEach(names, id: \.self) { name in
                                Button(name) { insertTemplate(name) }
                            }
                        }
                    } label: {
                        Label("Insert Template", systemImage: "doc.on.doc.fill")
                    }
                    if promptsOn {
                        Button {
                            promptOffset += 1
                        } label: {
                            Label("New Prompt", systemImage: "dice")
                        }
                    }
                    Button {
                        transcribeAudio()
                    } label: {
                        Label(transcribing ? "Transcribing…" : "Transcribe Voice Memos",
                              systemImage: "text.quote")
                    }
                    .disabled(transcribing || Transcriber.audioPaths(in: text).isEmpty)
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
                .accessibilityLabel("More actions")
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
            VideoRecorderView { url in attachCaptured(url) }
        }
        .sheet(isPresented: $showingPhotoCapture) {
            PhotoCaptureView { url in attachCaptured(url) }
        }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: date) { _, _ in scheduleSave() }
        .onChange(of: nav.newEntrySignal) { _, _ in newEntry() }
        // Put the live text on a connected external display (iOS second screen).
        .externalDisplay(.composing(title: title, date: date, text: text))
        .onAppear { focusStart() }
        .onDisappear { finishRecordingIfNeeded(); flush() }
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

    /// A recording still running when the view goes away would die with its
    /// `@StateObject` — stop it and attach the memo instead of losing it.
    private func finishRecordingIfNeeded() {
        guard recorder.isRecording else { return }
        if let data = recorder.stop(), let rel = store.saveAsset(data, ext: "m4a") {
            appendLink(rel)
            autoTranscribeIfEnabled(rel)
        }
    }

    private func toggleRecord() {
        if recorder.isRecording {
            if let data = recorder.stop(), let rel = store.saveAsset(data, ext: "m4a") {
                let md = "![](\(rel))"
                text = text.isEmpty ? md : text + "\n\n" + md
                autoTranscribeIfEnabled(rel)
            }
        } else {
            Task { await recorder.start() }
        }
    }

    /// Settings → Writing → auto-transcribe: a just-recorded memo transcribes
    /// itself, the words landing beneath the link when recognition finishes.
    private func autoTranscribeIfEnabled(_ rel: String) {
        guard UserDefaults.standard.bool(forKey: JournalStore.autoTranscribeKey),
              let url = store.assetURL(forRelative: rel) else { return }
        Task { @MainActor in
            guard let transcript = try? await Transcriber.transcribe(url: url) else { return }
            text = Transcriber.insert(transcript: transcript, after: rel, in: text)
            store.markTranscribed(assetID: ((rel as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
    }

    private var hasFirstBodyLine: Bool {
        text.split(separator: "\n", omittingEmptySubsequences: true).first != nil
    }

    /// Append a template's body ({{date}}/{{time}}/{{weekday}} filled in).
    private func insertTemplate(_ name: String) {
        guard let body = store.templateBody(named: name) else { return }
        text = text.isEmpty ? body : text + "\n\n" + body
        bodyFocused = true
    }

    /// Transcribe every attached voice memo and slot each transcript in
    /// beneath its audio link.
    private func transcribeAudio() {
        let paths = Transcriber.audioPaths(in: text)
        guard !paths.isEmpty, !transcribing else { return }
        transcribing = true
        Task { @MainActor in
            defer { transcribing = false }
            var updated = text
            var done = 0
            var lastError: String?
            for path in paths {
                guard let url = store.assetURL(forRelative: path) else { continue }
                do {
                    let transcript = try await Transcriber.transcribe(url: url)
                    updated = Transcriber.insert(transcript: transcript, after: path, in: updated)
                    done += 1
                } catch {
                    lastError = error.localizedDescription
                }
            }
            text = updated
            if done > 0 {
                showToast(done == 1 ? "Transcribed 1 memo" : "Transcribed \(done) memos")
            } else if let lastError {
                showToast(lastError)
            }
        }
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
        // Adopt the timestamp the store actually used — a colliding second is
        // nudged forward rather than overwriting an unrelated draft.
        activeTS = store.upsertDraft(previous: activeTS, timestamp: ts,
                                     title: title, body: text, reindex: reindex) ?? ts
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
        appendLink(rel)
    }

    /// Attach a file the camera just wrote (photo or video).
    private func attachCaptured(_ url: URL) {
        if let rel = store.importAsset(from: url) { appendLink(rel) }
    }

    private func appendLink(_ rel: String) {
        let md = "![](\(rel))"
        text = text.isEmpty ? md : text + "\n\n" + md
    }

    /// Load a picked photo/video and attach it (iOS Photos library). Videos
    /// come across as a file so they never sit in memory whole; images still
    /// come as data (they're downsampled on save anyway).
    private func loadPhoto(_ item: PhotosPickerItem) {
        Task { @MainActor in
            defer { photoItem = nil }
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }),
               let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                if let rel = store.importAsset(from: movie.url) { appendLink(rel) }
                try? FileManager.default.removeItem(at: movie.url)
                return
            }
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
                if type.conforms(to: .movie) {
                    // A dropped video lands as a temp file, not a Data buffer.
                    provider.loadFileRepresentation(forTypeIdentifier: id) { url, _ in
                        guard let url else { return }
                        // The provider deletes its file when this returns; copy first.
                        let dest = FileManager.default.temporaryDirectory
                            .appendingPathComponent("\(UUID().uuidString).\(type.preferredFilenameExtension ?? "mov")")
                        try? FileManager.default.copyItem(at: url, to: dest)
                        Task { @MainActor in
                            if let rel = store.importAsset(from: dest) { appendLink(rel) }
                            try? FileManager.default.removeItem(at: dest)
                        }
                    }
                } else {
                    provider.loadDataRepresentation(forTypeIdentifier: id) { data, _ in
                        guard let data else { return }
                        let ext = type.preferredFilenameExtension ?? "dat"
                        Task { @MainActor in insertMedia(data, ext: ext) }
                    }
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
