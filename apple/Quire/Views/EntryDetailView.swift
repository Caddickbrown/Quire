//
//  EntryDetailView.swift
//  Quire
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
    @State private var dropError: String?

    @State private var title: String
    @State private var date: Date
    @State private var text: String
    /// The body editor's caret, for the external display (see WritingView).
    @State private var caret: Int?
    /// Where the caret last was, so an attachment made after the editor gave
    /// up focus (a picker sheet, a toolbar menu) still lands there.
    @State private var lastCaret: Int?
    @State private var baselineRaw: String
    /// What this editor last wrote, and where. The store looks an entry up by
    /// its text, so the lookup key has to follow every save — passing the
    /// immutable `entry` it was opened with meant the first date change orphaned
    /// the editor and every later autosave (and Delete, and File) silently
    /// no-oped. `currentSource` moves too: re-dating a filed entry moves it into
    /// another day's file.
    @State private var current: Entry
    @State private var currentSource: EntrySource
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

    /// Called after "Return to Inbox" moves the entry out from under this view.
    /// Sheets and pushes just dismiss; a macOS side pane has nothing to dismiss,
    /// so its host clears the selection through this instead of leaving a view
    /// onto a vanished entry.
    var onReturnedToInbox: (() -> Void)?

    init(entry: Entry, source: EntrySource, onReturnedToInbox: (() -> Void)? = nil) {
        self.entry = entry
        self.source = source
        self.onReturnedToInbox = onReturnedToInbox
        let opened = JournalStore.date(from: entry.ts) ?? Date()
        _title = State(initialValue: entry.suffix)
        _date = State(initialValue: opened)
        _text = State(initialValue: entry.body)
        // Baseline from what this editor *would* compose, not from the file's
        // raw text: a non-canonical entry (extra blank lines, a hand-edited
        // header) used to read as dirty and be rewritten the moment it opened.
        _baselineRaw = State(initialValue: JournalStore.makeEntry(
            timestamp: JournalStore.ts(from: opened), title: entry.suffix, body: entry.body).raw)
        _current = State(initialValue: entry)
        _currentSource = State(initialValue: source)
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
    private var isStarred: Bool { Entry.hasStarMarker(title) }
    private func toggleStar() { title = Entry.togglingStarMarker(title) }
    /// Title as shown in Preview: the star marker stripped (it's drawn as an icon).
    private var previewTitle: String { Entry.strippingStarMarker(title) }
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
            if case .success(let urls) = result, let url = urls.first,
               let rel = Attach.file(url, into: store) { appendLink(rel) }
        }
        #if os(iOS)
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) { _, item in
            if let item { loadPhoto(item) }
        }
        #endif
        .onDrop(of: [.image, .movie, .audio, .fileURL], isTargeted: nil) { providers in
            Attach.drop(providers, into: store, link: appendLink,
                        refused: { dropError = "Only images, video and audio can be attached to an entry." })
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
        // The same editor can be handed a re-read entry while it sits open —
        // starring it from the inbox row, say. With nothing typed since the last
        // save, adopt it; the fields held the pre-star text and the next
        // keystroke wrote the star straight back off.
        .onChange(of: entry) { _, e in adopt(e) }
        // Present the entry on a connected external display (iOS second
        // screen): Edit mirrors the editor, caret and all; Preview renders it.
        .externalDisplay(mode == .edit
            ? .editing(title: title, date: date, text: text, caret: caret, isStarred: isStarred)
            : .reading(title: title, date: date, text: text, isStarred: isStarred))
        .onDisappear { finishRecordingIfNeeded(); flush() }
        .alert("Transcription", isPresented: Binding(
            get: { transcribeError != nil },
            set: { if !$0 { transcribeError = nil } }
        )) {
            Button("OK") { }
        } message: {
            Text(transcribeError ?? "")
        }
        .alert("Can't attach that", isPresented: Binding(
            get: { dropError != nil },
            set: { if !$0 { dropError = nil } }
        )) {
            Button("OK") { }
        } message: {
            Text(dropError ?? "")
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

        AttachMenu(photoLibrary: { showingPhotoPicker = true },
                   file: { showingImagePicker = true },
                   photo: { showingPhotoCapture = true },
                   video: { showingVideoRecorder = true })

        Menu {
            #if os(iOS)
            Button { toggleStar() } label: {
                Label(isStarred ? "Unstar" : "Star",
                      systemImage: isStarred ? "star.slash" : "star")
            }
            #endif
            if source != .inbox {
                Button { returnToInbox() } label: {
                    Label("Return to Inbox", systemImage: "tray.and.arrow.up")
                }
                #if os(macOS)
                Divider()
                #endif
            }
            #if os(iOS)
            Divider()
            #endif
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

        if case .inbox = currentSource {
            Button {
                flush()
                // `current` is what the flush actually wrote — filing the
                // composed text instead left the original behind in the inbox
                // once the date had been changed.
                store.fileDraft(current)
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
                              tagSuggestions: store.tagCounts.map { String($0.tag.dropFirst()) },
                              onCaretChange: { caret = $0; if let c = $0 { lastCaret = c } },
                              onPasteMedia: { if let rel = Attach.pasted($0, into: store) { appendLink(rel) } })
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
        let composed = composedRaw
        let saved: Bool
        switch currentSource {
        case .inbox:
            saved = store.updateDraft(current, newText: composed, reindex: reindex)
        case .archive(let d):
            // A re-dated entry lands in another day's file; follow it there.
            if let moved = store.updateFiledEntry(date: d, original: current,
                                                  newText: composed, reindex: reindex) {
                currentSource = moved
                saved = true
            } else {
                saved = false
            }
        case .journal(let n):
            saved = store.updateJournalEntry(name: n, original: current, newText: composed, reindex: reindex)
        }
        // Only a write that happened moves the baseline — otherwise the editor
        // would go clean with nothing on disk and never retry.
        guard saved else { return }
        current = store.writtenEntry(fallback: current)
        baselineRaw = composed
        pendingReindex = !reindex
    }

    /// Take on an entry re-read from disk, unless there are unsaved edits (in
    /// which case what's typed wins and the next commit will write it).
    private func adopt(_ e: Entry) {
        guard !isDirty else { return }
        let opened = JournalStore.date(from: e.ts) ?? date
        let incoming = JournalStore.makeEntry(timestamp: JournalStore.ts(from: opened),
                                              title: e.suffix, body: e.body).raw
        // Same text, freshly parsed (the usual case after our own save): keep
        // the lookup key current and leave the fields — and the cursor — alone.
        guard incoming != baselineRaw else { current = e; return }
        title = e.suffix
        text = e.body
        date = opened
        current = e
        baselineRaw = incoming
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

    /// Attach a file the camera just wrote (photo or video).
    private func attachCaptured(_ url: URL) {
        if let rel = store.importAsset(from: url) { appendLink(rel) }
    }

    private func appendLink(_ rel: String) {
        text = JournalStore.linking(rel, into: text, at: lastCaret)
    }

    /// Attach a photo or video picked from the iOS Photos library.
    private func loadPhoto(_ item: PhotosPickerItem) {
        Task { @MainActor in
            defer { photoItem = nil }
            if let rel = await Attach.photo(item, into: store) { appendLink(rel) }
        }
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

    /// Save first so the move carries any edit still in the autosave debounce,
    /// then hand the entry back to the inbox and leave.
    private func returnToInbox() {
        flush()
        guard store.returnToInbox(currentEntry, source: source) else { return }
        // A sheet or push closes itself; a side pane (no presentation to
        // dismiss — dismiss() there would pop the enclosing stack) asks its host.
        if let onReturnedToInbox { onReturnedToInbox() } else { dismiss() }
    }

    private func delete() {
        // `current`, not `entry`: after a date change the opened text is no
        // longer what's on disk, and deleting by it removed nothing.
        saveTask?.cancel()
        switch currentSource {
        case .inbox:            store.deleteDraft(current)
        case .archive(let d):   store.deleteFiledEntry(date: d, entry: current)
        case .journal(let n):   store.deleteJournalEntry(name: n, entry: current)
        }
    }
}
