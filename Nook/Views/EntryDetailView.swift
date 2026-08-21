//
//  EntryDetailView.swift
//  Nook
//
//  Edit a single entry — an inbox draft, a filed archive entry, or a split-journal
//  entry. Same title + date-picker + body layout as the composer, autosaving
//  continuously. Edit / Preview modes; controls are inline (not in the window
//  toolbar) so they don't shift the layout when shown in a split pane.
//

import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
#if canImport(AppKit)
import AppKit
import PDFKit
#elseif canImport(UIKit)
import UIKit
#endif

enum EntrySource: Hashable {
    case inbox
    case archive(date: String)
    case journal(name: String)   // a tag-routed split journal (<base>/<name>.md)
}

struct EntryDetailView: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accent) private var accent
    @Environment(\.dismiss) private var dismiss

    let entry: Entry
    let source: EntrySource

    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("dateStyle") private var dateStyleRaw: String = DateStyle.weekday.rawValue
    @AppStorage("highlightTags") private var highlightTags = true
    @AppStorage("typewriterScroll") private var typewriterScroll = false
    @AppStorage("focusParagraph") private var focusParagraph = false

    @State private var transcribing = false
    @State private var transcribeError: String?

    @State private var title: String
    @State private var date: Date
    @State private var text: String
    @State private var baselineRaw: String
    @State private var mode: EntryViewMode = .edit
    @State private var showingImagePicker = false
    @State private var showingVideoRecorder = false
    @State private var showingPhotoCapture = false
    @State private var showingPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var saveTask: Task<Void, Never>?
    @State private var pendingReindex = false
    @StateObject private var recorder = AudioRecorder()
    @FocusState private var bodyFocused: Bool

    enum EntryViewMode: String, CaseIterable, Identifiable {
        case edit = "Edit", preview = "Preview"
        var id: String { rawValue }
    }

    init(entry: Entry, source: EntrySource) {
        self.entry = entry
        self.source = source
        _title = State(initialValue: entry.suffix)
        _date = State(initialValue: JournalStore.date(from: entry.ts) ?? Date())
        _text = State(initialValue: entry.body)
        _baselineRaw = State(initialValue: entry.raw)
        // Drafts open ready to edit; filed/journal entries open in Preview.
        let startMode: EntryViewMode = { if case .inbox = source { return .edit }; return .preview }()
        _mode = State(initialValue: startMode)
    }

    private var size: CGFloat { CGFloat(fontSize) }
    private var font: Font { Theme.font(writingFontRaw, size: size) }
    private var currentEntry: Entry {
        JournalStore.makeEntry(timestamp: JournalStore.ts(from: date), title: title, body: text)
    }
    private var composedRaw: String { currentEntry.raw }
    private var isDirty: Bool { composedRaw != baselineRaw }

    /// Star state is a trailing `*` on the title; toggling edits `title` so the
    /// change flows through the normal autosave (and Preview) path.
    private var isStarred: Bool { title.trimmingCharacters(in: .whitespaces).hasSuffix("*") }
    private func toggleStar() {
        let base = title.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("*") {
            title = String(base.dropLast()).trimmingCharacters(in: .whitespaces)
        } else {
            title = base.isEmpty ? "*" : base + " *"
        }
    }
    /// Title as shown in Preview: the star marker stripped (it's drawn as an icon).
    private var previewTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix("*") else { return t }
        return String(t.dropLast()).trimmingCharacters(in: .whitespaces)
    }
    private var saveHelp: String {
        if case .inbox = source { return "Save draft (keep in Inbox)" }
        return "Save"
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            controlBar
            Divider()
            #endif

            if mode == .preview {
                VStack(alignment: .leading, spacing: 0) {
                    if !previewTitle.isEmpty || isStarred {
                        HStack(spacing: 6) {
                            if isStarred {
                                Image(systemName: "star.fill").foregroundStyle(.yellow)
                            }
                            Text(previewTitle).font(font.weight(.bold))
                            Spacer()
                            Text(Theme.displayDate(String(JournalStore.ts(from: date).prefix(10)), style: dateStyleRaw))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        // 16 to match the editor's gutter, so toggling
                        // Edit/Preview doesn't shift the text sideways.
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                    }
                    MediaPreview(text: text, font: font, textColor: Theme.bodyText(colorScheme)) { text = $0 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editArea
            }
        }
        .overlay(alignment: .bottom) {
            if recorder.isRecording {
                RecordingBanner(elapsed: recorder.elapsedString) { toggleRecord() }
            }
        }
        .frame(maxWidth: 1520)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
        .fileImporter(isPresented: $showingImagePicker,
                      allowedContentTypes: [.image, .movie, .audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { attachFile(url) }
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
        #if os(iOS)
        // In the navigation bar rather than a row of their own: an entry used to
        // pay for two rows of chrome (an all-but-empty nav bar plus this) before
        // any text showed up.
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                modeButton
                actionButtons
            }
        }
        #endif
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: date) { _, _ in scheduleSave() }
        // Present the entry on a connected external display (iOS second screen).
        .externalDisplay(.reading(title: title, date: date, text: text, isStarred: isStarred))
        .onDisappear { finishRecordingIfNeeded(); flush() }
        .alert("Transcription", isPresented: Binding(
            get: { transcribeError != nil },
            set: { if !$0 { transcribeError = nil } }
        )) {
            Button("OK") { }
        } message: {
            Text(transcribeError ?? "")
        }
    }

    /// Transcribe every attached voice memo and slot each transcript in
    /// beneath its audio link (same flow as the composer's).
    private func transcribeAudio() {
        let paths = Transcriber.audioPaths(in: text)
        guard !paths.isEmpty, !transcribing else { return }
        transcribing = true
        Task { @MainActor in
            defer { transcribing = false }
            var updated = text
            var lastError: String?
            for path in paths {
                guard let url = store.assetURL(forRelative: path) else { continue }
                do {
                    let transcript = try await Transcriber.transcribe(url: url)
                    updated = Transcriber.insert(transcript: transcript, after: path, in: updated)
                } catch {
                    lastError = error.localizedDescription
                }
            }
            text = updated
            if let lastError { transcribeError = lastError }
        }
    }

    // MARK: Controls
    //
    // macOS keeps them inline — a detail pane must not reshuffle the window
    // toolbar when the selection changes. iOS hoists them into the nav bar.

    private var controlBar: some View {
        HStack(spacing: 18) {
            modeButton
            Spacer()
            actionButtons
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var modeButton: some View {
        Button {
            mode = (mode == .edit) ? .preview : .edit
        } label: {
            Image(systemName: mode == .edit ? "eye" : "pencil")
        }
        .help(mode == .edit ? "Preview" : "Edit")
        .accessibilityLabel(mode == .edit ? "Preview" : "Edit")
    }

    @ViewBuilder
    private var actionButtons: some View {
        #if os(macOS)
        Button {
            toggleStar()
        } label: {
            Image(systemName: isStarred ? "star.fill" : "star")
                .foregroundStyle(isStarred ? Color.yellow : Color.primary)
        }
        .help(isStarred ? "Unstar" : "Star")
        .accessibilityLabel(isStarred ? "Unstar" : "Star")
        #endif

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
            Button { toggleStar() } label: {
                Label(isStarred ? "Unstar" : "Star",
                      systemImage: isStarred ? "star.slash" : "star")
            }
            Divider()
            Button { showingPhotoPicker = true } label: { Label("Photo Library", systemImage: "photo") }
            Button { showingImagePicker = true } label: { Label("Choose File", systemImage: "folder") }
            #else
            Button { showingImagePicker = true } label: { Label("Attach Media", systemImage: "paperclip") }
            #endif
            Button { showingPhotoCapture = true } label: { Label("Take Photo", systemImage: "camera") }
            Button { showingVideoRecorder = true } label: { Label("Record Video", systemImage: "video") }
            Button { copyText() } label: { Label("Copy text", systemImage: "doc.on.doc") }
            #if os(macOS)
            Button { printEntry() } label: { Label("Print…", systemImage: "printer") }
            #endif
            Button { promoteFirstLine() } label: { Label("Promote first line to title", systemImage: "arrow.up.to.line") }
                .disabled(!hasFirstBodyLine)
            Button { transcribeAudio() } label: {
                Label(transcribing ? "Transcribing…" : "Transcribe Voice Memos",
                      systemImage: "text.quote")
            }
            .disabled(transcribing || Transcriber.audioPaths(in: text).isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .fixedSize()
        .accessibilityLabel("More actions")

        Button {
            flush()
            #if os(iOS)
            dismiss()
            #endif
        } label: {
            Label("Save", systemImage: "checkmark").labelStyle(.iconOnly)
        }
        .help(saveHelp)

        if case .inbox = source {
            Button {
                flush()
                store.fileDraft(currentEntry)
                #if os(iOS)
                dismiss()
                #endif
            } label: {
                Label("File", systemImage: "archivebox").labelStyle(.iconOnly)
            }
            .help("File into the archive")
        }
        Button(role: .destructive) {
            delete()
            #if os(iOS)
            dismiss()
            #endif
        } label: {
            Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
        }
        .destructiveAction()
        .help("Delete")
    }

    private var editArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Title", text: $title)
                    .font(font.weight(.semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { bodyFocused = true }
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        #if os(macOS)
                        .datePickerStyle(.field)
                        #else
                        .datePickerStyle(.compact)
                        #endif
                }
            }
            // Same rhythm as the composer's header — the two screens are the
            // same layout and shouldn't sit a couple of points apart.
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
                        Text("Begin writing")
                            .font(font)
                            .foregroundStyle(Theme.placeholder(colorScheme))
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Autosave

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    /// `reindex: false` (the debounced path) writes the file without rebuilding
    /// the whole index — so typing doesn't trigger a folder-wide re-render. The
    /// final flush reindexes so lists refresh once you leave.
    private func commit(reindex: Bool = false) {
        guard isDirty else { return }
        switch source {
        case .inbox:            store.updateDraft(entry, newText: composedRaw, reindex: reindex)
        case .archive(let d):   store.updateFiledEntry(date: d, original: entry, newText: composedRaw, reindex: reindex)
        case .journal(let n):   store.updateJournalEntry(name: n, original: entry, newText: composedRaw, reindex: reindex)
        }
        baselineRaw = composedRaw
        pendingReindex = !reindex
    }

    /// Persist everything and make the store reload, so leaving the entry always
    /// refreshes the lists — even if the last write was a deferred (unindexed) one.
    private func flush() {
        saveTask?.cancel()
        if isDirty {
            commit(reindex: true)
        } else if pendingReindex {
            store.reload()
        }
        pendingReindex = false
    }

    // MARK: Media / helpers

    private var hasFirstBodyLine: Bool {
        text.split(separator: "\n", omittingEmptySubsequences: true).first != nil
    }

    private func promoteFirstLine() {
        var lines = text.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        title = lines[idx].trimmingCharacters(in: .whitespaces)
        lines.remove(at: idx)
        text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attachFile(_ url: URL) {
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
    /// come across as a file (`PickedMovie`) so they never sit in memory whole.
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
                    Task { @MainActor in attachFile(url) }
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

    #if os(macOS)
    /// ⌘P by another door: typeset this entry through the PDF renderer and
    /// hand it to the system print panel.
    private func printEntry() {
        Task { @MainActor in
            let day = String(JournalStore.ts(from: date).prefix(10))
            guard let data = await PDFExporter.makePDF(days: [(day, [currentEntry])],
                                                       store: store,
                                                       dateStyleRaw: dateStyleRaw,
                                                       fontRaw: writingFontRaw,
                                                       fontSize: CGFloat(fontSize)),
                  let doc = PDFDocument(data: data),
                  let op = doc.printOperation(for: .shared, scalingMode: .pageScaleDownToFit, autoRotate: true)
            else { return }
            op.run()
        }
    }
    #endif

    /// Copy the entry's title + body to the clipboard.
    private func copyText() {
        let combined = [title.trimmingCharacters(in: .whitespacesAndNewlines), text]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = combined
        #endif
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
                appendLink(rel)
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

    private func delete() {
        switch source {
        case .inbox:            store.deleteDraft(entry)
        case .archive(let d):   store.deleteFiledEntry(date: d, entry: entry)
        case .journal(let n):   store.deleteJournalEntry(name: n, entry: entry)
        }
    }
}
