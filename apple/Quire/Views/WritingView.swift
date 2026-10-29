//
//  WritingView.swift
//  Quire
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
    @Environment(\.scenePhase) private var scenePhase
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
    /// Set once the user touches the DatePicker; the automatic first-keystroke
    /// stamp then leaves the date alone. Stamps are recognised by value so
    /// `onChange(of: date)` can tell the two apart.
    @State private var datePinned = false
    @State private var lastAutoStamp: Date?
    @State private var text = ""
    /// The body editor's caret (UTF-16 offset), nil while the body isn't
    /// focused — forwarded to the external display so its caret tracks ours.
    @State private var caret: Int?
    /// Where the caret last was, so an attachment made after the editor gave
    /// up focus (a picker sheet, a toolbar menu) still lands there.
    @State private var lastCaret: Int?
    @State private var activeTS: String?
    /// How many `[timestamp]` headers the working text carries. Non-zero means
    /// a paste that would split into several drafts: the format has no escape
    /// for a header line, so nothing is written until Import or Keep as one.
    @State private var embeddedEntries = 0
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
    private func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasText: Bool { !(isBlank(title) && isBlank(text)) }

    /// `jnl new` stamps an entry when you start writing it, not when the app
    /// launched. On macOS the Write section lives for the whole app lifetime,
    /// so a `Date()` fixed at view creation stamped the next morning's first
    /// entry with yesterday's time — and filed it to yesterday. Re-stamp while
    /// the composer is still untouched; once there is text (or a draft on
    /// disk) the date belongs to the user and the DatePicker owns it.
    private func stampIfUntouched(_ wasBlank: Bool) {
        guard activeTS == nil, wasBlank, !datePinned else { return }
        autoStamp()
    }
    private func autoStamp() {
        let now = Date()
        lastAutoStamp = now
        date = now
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

            if embeddedEntries > 0 {
                pasteBanner
                Divider()
            }

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
                        // Not `nil`: at regular width the sidebar is already on
                        // screen and the detail pane falls back to the composer,
                        // so clearing the section left Done doing nothing
                        // visible. Land on the Inbox instead — where the draft
                        // it just saved is waiting.
                        nav.section = .inbox
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Save to inbox & open it")
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
                AttachMenu(photoLibrary: { showingPhotoPicker = true },
                           file: { showingImagePicker = true },
                           photo: { showingPhotoCapture = true },
                           video: { showingVideoRecorder = true })
                Menu {
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
                        refused: { showToast("Only images, video and audio can be attached") })
        }
        .sheet(isPresented: $showingVideoRecorder) {
            VideoRecorderView { url in attachCaptured(url) }
        }
        .sheet(isPresented: $showingPhotoCapture) {
            PhotoCaptureView { url in attachCaptured(url) }
        }
        .onChange(of: title) { old, _ in
            stampIfUntouched(isBlank(old) && isBlank(text))
            scheduleSave()
        }
        .onChange(of: text) { old, _ in
            stampIfUntouched(isBlank(title) && isBlank(old))
            scheduleSave()
        }
        // Returning to an untouched composer the next day re-stamps it too.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { stampIfUntouched(!hasText) }
        }
        .onChange(of: date) { _, new in
            if new != lastAutoStamp { datePinned = true }
            scheduleSave()
        }
        .onChange(of: nav.newEntrySignal) { _, _ in newEntry() }
        // Put the live text on a connected external display (iOS second screen).
        .externalDisplay(.composing(title: title, date: date, text: text, caret: caret))
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

    /// Shown when the working text holds `[timestamp]` headers of its own. One
    /// draft is one entry on disk, so text like this has to become several
    /// drafts (Import) or stop being headers (Keep as one, which escapes them);
    /// until then the composer saves nothing rather than writing a body that
    /// would parse back as extra entries.
    private var pasteBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(embeddedEntries == 1
                 ? "This looks like a pasted entry — nothing is saved until you choose."
                 : "This looks like \(embeddedEntries) entries — nothing is saved until you choose.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Import") { importEntries() }
            Button("Keep as one") { keepAsOne() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Escape the embedded header lines (markdown's `\[`) so the text stays one
    /// draft — visibly, in the composer, so what saves is what you can see.
    private func keepAsOne() {
        text = JournalStore.escapingEmbeddedHeaders(text, skippingFirstLine: false)
        embeddedEntries = 0
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

    /// `body` overrides the live text for the one caller that has just rewritten
    /// it (`flush`) — a `@State` write isn't readable back reliably in the same
    /// call, and the save must use the text that's about to be shown.
    private func commit(reindex: Bool = false, body: String? = nil) {
        let working = body ?? text
        let empty = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && working.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !empty else {
            if let ts = activeTS { store.removeDraft(timestamp: ts); activeTS = nil }
            embeddedEntries = 0
            return
        }
        // A paste holding its own `[timestamp]` headers would come back out of
        // the inbox as several drafts, and every later autosave would add more.
        // Leave it undecided (the banner asks) and write nothing.
        embeddedEntries = JournalStore.embeddedEntryCount(in: working)
        guard embeddedEntries == 0 else { return }
        let ts = JournalStore.ts(from: date)
        // Adopt the timestamp the store actually used — a colliding second is
        // nudged forward rather than overwriting an unrelated draft.
        activeTS = store.upsertDraft(previous: activeTS, timestamp: ts,
                                     title: title, body: working, reindex: reindex)
    }

    private func flush() {
        saveTask?.cancel()
        // Leaving with an undecided paste keeps it as one draft rather than
        // dropping it — escaped, so what lands on disk is what reopens.
        let safe = JournalStore.escapingEmbeddedHeaders(text, skippingFirstLine: false)
        if safe != text { text = safe }
        commit(reindex: true, body: safe)
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
        saveTask?.cancel()
        // Clear everything this working text has already put in the inbox — the
        // draft under `activeTS`, plus any entries an earlier build's autosave
        // split out of the pasted body — or the import would stack on top of them.
        // Anything typed above the first pasted header is the user's own note,
        // not part of the import — `parseEntries` drops it as preamble — so it
        // stays in the composer (with the title) as the working draft.
        let preamble = JournalParser.leadingPreamble(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let ts = activeTS { store.removeDraft(timestamp: ts); activeTS = nil }
        store.removeDrafts(matching: JournalParser.parseEntries(text))
        let n = store.importDrafts(from: text)
        if preamble.isEmpty && isBlank(title) {
            reset()
        } else {
            text = preamble
            embeddedEntries = 0
        }
        showToast(n == 1 ? "Imported 1 entry" : "Imported \(n) entries")
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

    private func reset() {
        activeTS = nil
        embeddedEntries = 0
        title = ""
        text = ""
        datePinned = false
        autoStamp()
    }

    private func showToast(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { toast = nil }
        }
    }
}
