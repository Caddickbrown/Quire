//
//  ComposerScreen.swift
//  Quire
//
//  The page you write on. Nothing but the date, a title, the rule and the
//  text; saving happens as you type (a new page is a draft in the inbox) and
//  "File" sends it to its day. Focus quiets everything that isn't the text.
//  The paperclip, a drop or a pasted image attaches media where the caret is.
//

#if os(iOS)

import SwiftUI
import PhotosUI

struct ComposerScreen: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage(PromptDeck.enabledKey) private var promptsOn = false

    let target: ComposeTarget
    var onUpdate: (EntryRef) -> Void = { _ in }
    var onRemove: () -> Void = {}

    @State private var title = ""
    @State private var text = ""
    @State private var starred = false
    /// The entry being edited, kept current as saves land.
    @State private var current: Entry?
    /// A new page's draft timestamp: fixed on the first save, then the key it keeps.
    @State private var startedAt: String?
    @State private var focusMode = false
    @State private var loaded = false
    /// What an existing entry opened with: unchanged, it isn't written back, so
    /// opening an entry never re-normalises it on disk.
    @State private var opened: (title: String, text: String, starred: Bool)?
    @State private var pending: Task<Void, Never>?
    private enum Field: Hashable { case title, body }
    @FocusState private var focus: Field?
    @State private var caret: Int?
    @State private var savedSource: EntrySource?
    @State private var saveError: String?
    @State private var saveGeneration = 0
    @State private var recoverCopy = false
    @State private var routerID = UUID()
    @State private var showStamp = false
    /// A date and time chosen (^t) before the first save of a new page.
    @State private var pendingTS: String?
    @State private var confirmDiscard = false
    @State private var savedFlash = false
    /// Where the caret last was in the body: a picker sheet takes focus away,
    /// and what it brings back still lands there.
    @State private var lastCaret: Int?
    @State private var showingPhotoPicker = false
    @State private var showingFilePicker = false
    @State private var showingPhotoCapture = false
    @State private var showingVideoRecorder = false
    @State private var photoItem: PhotosPickerItem?
    @StateObject private var recorder = AudioRecorder()
    /// A brief word in the footer (a refused drop).
    @State private var notice: String?

    /// Today's prompt, when Settings → Writing prompts is on.
    private static var prompt: String {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return PromptDeck.prompts[day % PromptDeck.prompts.count]
    }

    private var editing: EntryRef? { target.ref }
    private var source: EntrySource { savedSource ?? editing?.source ?? .inbox }
    private var isDraft: Bool { source == .inbox }
    private var words: Int { text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count }
    private var quiet: Double { focusMode && focus == .body ? 0.25 : 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let saveError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(saveError).font(q.ui(14)).foregroundStyle(q.accentColor)
                    HStack {
                        Button("Retry save") { _ = saveNow() }
                        Button("Save a copy to Inbox") { recoverCopy = true }
                    }.font(q.ui(14))
                }.padding(.horizontal, 20).padding(.vertical, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(themeLabel) · \(QDate.longDay(stampDate))".uppercased()).tracking(1.6)
                        .font(q.ui(11)).foregroundStyle(q.mutedColor).opacity(quiet)
                    TextField("", text: $title, prompt: Text("Title").foregroundColor(q.faintColor))
                        .focused($focus, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focus = .body }
                        .font(q.isMarathon ? q.display(30) : q.writing(32, weight: .medium)).foregroundStyle(q.inkColor)
                        .textCase(q.isMarathon ? .uppercase : nil)
                        .opacity(quiet)
                    QTitleRule().opacity(quiet)
                    editor
                }
                .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            footer
        }
        .background(q.pageColor.ignoresSafeArea())
        .onAppear { load(); registerKeys() }
        .onChange(of: title) { _, _ in scheduleSave(); mirror() }
        .onChange(of: text) { _, _ in scheduleSave(); mirror() }
        .onDisappear {
            pending?.cancel()
            ExternalDisplayModel.shared.releasePage(owner: routerID)
            KeyCommandRouter.shared.unregister(routerID)
        }
        .interactiveDismissDisabled()
        .onChange(of: caret) { _, _ in mirror() }
        .onChange(of: starred) { _, _ in scheduleSave(); mirror() }
        .alert("Save a recovery copy?", isPresented: $recoverCopy) {
            Button("Save copy") { saveRecoveryCopy() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your edits will be saved as a new Inbox draft. The original entry will be kept.")
        }
        .sheet(isPresented: $showStamp) {
            StampSheet(initial: stampDate) { applyStamp($0) }.environment(\.quire, q)
        }
        .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveNow() } }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $photoItem,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                defer { photoItem = nil }
                if let rel = await Attach.photo(item, into: store) { link(rel) }
            }
        }
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: Attach.types,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first,
               let rel = Attach.file(url, into: store) { link(rel) }
        }
        .sheet(isPresented: $showingPhotoCapture) {
            PhotoCaptureView { url in if let rel = store.importAsset(from: url) { link(rel) } }
        }
        .sheet(isPresented: $showingVideoRecorder) {
            VideoRecorderView { url in if let rel = store.importAsset(from: url) { link(rel) } }
        }
        .onDrop(of: [.image, .movie, .audio, .fileURL], isTargeted: nil) { providers in
            Attach.drop(providers, into: store, link: link,
                        refused: { say("Only images, video and audio attach") })
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            QLink(title: "Close") { close() }
            Spacer()
            Button { showStamp = true } label: {
                Text("[\(stampText)]").font(q.mono(12)).foregroundStyle(q.mutedColor).underline(pattern: .dot)
                    .frame(minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel("Change date and time")
            Spacer()
            QLink(title: starred ? "★" : "☆") { starred.toggle() }
                .accessibilityLabel(starred ? "Starred" : "Star")
                .frame(minWidth: 44)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(editing == nil ? (promptsOn ? Self.prompt : "Begin writing") : "").font(q.writing(fontSize + 2, italic: true))
                    .foregroundStyle(q.faintColor).padding(.top, 8).allowsHitTesting(false)
            }
            WritingTextEditor(text: $text, fontRaw: q.editorFontName,
                              size: fontSize + 2, textColor: q.inkColor, lineSpacing: 8,
                              accent: q.accentColor, sizeToFit: true,
                              tagSuggestions: store.tagCounts.map { String($0.tag.dropFirst()) },
                              onCaretChange: { caret = $0; if let c = $0 { lastCaret = c } },
                              onPasteMedia: { if let rel = Attach.pasted($0, into: store) { link(rel) } },
                              focused: Binding(get: { focus == .body }, set: { if $0 { focus = .body } else if focus == .body { focus = nil } }))
                .focused($focus, equals: .body)
                .frame(minHeight: 360, alignment: .top)

        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            QRule()
            HStack(spacing: 14) {
                if recorder.isRecording {
                    Button(action: toggleRecord) {
                        HStack(spacing: 8) {
                            Circle().fill(q.accentColor).frame(width: 8, height: 8)
                            Text("\(recorder.elapsedString) · Stop").font(q.mono(12)).foregroundStyle(q.accentColor)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Stop recording, \(recorder.elapsedString)")
                } else {
                    Text(notice ?? "\(words) words · \(savedFlash ? "saved" : isDraft ? "draft" : "filed")")
                        .font(q.mono(12)).foregroundStyle(q.mutedColor).opacity(quiet)
                }
                Spacer()
                AttachMenu(photoLibrary: { showingPhotoPicker = true },
                           file: { showingFilePicker = true },
                           photo: { showingPhotoCapture = true },
                           video: { showingVideoRecorder = true },
                           voice: recorder.isRecording ? nil : { toggleRecord() }) {
                    Image(systemName: "paperclip").font(.system(size: 17))
                        .foregroundStyle(q.inkColor)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .opacity(quiet)
                Button { focusMode.toggle() } label: {
                    Text("Focus").font(q.ui(14, weight: focusMode ? .semibold : .regular))
                        .foregroundStyle(focusMode ? q.accentColor : q.inkColor)
                        .underline(focusMode, color: q.accentColor)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(focusMode ? .isSelected : [])
                Button(action: finish) {
                    Text(q.caps(isDraft ? "File" : "Done"))
                        .font(q.isMarathon ? q.label(12, weight: .medium) : q.ui(14, weight: .semibold)).foregroundStyle(q.onSignalColor)
                        .padding(.horizontal, 18).frame(minHeight: 44).background(q.signalColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 4)
        }
        .background(q.pageColor)
    }

    // MARK: Attachments

    /// Put an attachment's link in the body where the caret was.
    private func link(_ rel: String) {
        text = JournalStore.linking(rel, into: text, at: lastCaret)
    }

    private func say(_ message: String) {
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { notice = nil }
    }

    private func toggleRecord() {
        if recorder.isRecording {
            if let data = recorder.stop(), let rel = store.saveAsset(data, ext: "m4a") {
                link(rel)
                autoTranscribeIfEnabled(rel)
            }
        } else {
            Task { await recorder.start() }
        }
    }

    /// A recording still running when the page closes would die with its
    /// `@StateObject` — Close and File stop it and attach the memo first.
    private func finishRecordingIfNeeded() {
        guard recorder.isRecording else { return }
        if let data = recorder.stop(), let rel = store.saveAsset(data, ext: "m4a") { link(rel) }
    }

    /// Settings → auto-transcribe: the words land beneath the memo's link.
    private func autoTranscribeIfEnabled(_ rel: String) {
        guard UserDefaults.standard.bool(forKey: JournalStore.autoTranscribeKey),
              let url = store.assetURL(forRelative: rel) else { return }
        Task { @MainActor in
            guard let transcript = try? await Transcriber.transcribe(url: url) else { return }
            text = Transcriber.insert(transcript: transcript, after: rel, in: text)
            store.markTranscribed(assetID: ((rel as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
    }

    // MARK: Time

    private var stampText: String { pendingTS ?? current?.ts ?? startedAt ?? JournalStore.nowTS() }
    private var stampDate: Date { JournalStore.date(from: stampText) ?? Date() }
    private var themeLabel: String { q.name }

    // MARK: Loading and saving

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let ref = editing {
            current = ref.entry
            title = ref.entry.displayTitle
            text = ref.entry.body
            starred = ref.entry.isStarred
            opened = (title, text, starred)
        }
        // The page opens ready to type into.
        DispatchQueue.main.async { if editing == nil { focus = .title } }
        mirror()
        // The edits above would otherwise schedule a save of unchanged text.
        pending?.cancel()
    }

    private var headerTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard starred else { return t }
        return t.isEmpty ? "*" : t + " *"
    }

    /// Republish the page to a connected monitor as you type.
    private func mirror() {
        guard loaded else { return }
        let content: ExternalDisplayContent = editing == nil
            ? .composing(title: title, date: stampDate, text: text, caret: caret)
            : .editing(title: title, date: stampDate, text: text, caret: caret, isStarred: starred, isDraft: isDraft)
        ExternalDisplayModel.shared.present(content, owner: routerID)
    }

    private func scheduleSave() {
        guard loaded else { return }
        savedFlash = false
        pending?.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        pending = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled, generation == saveGeneration { saveNow() }
        }
    }

    @discardableResult
    private func saveNow(timestamp: String? = nil) -> Bool {
        pending?.cancel()
        saveGeneration += 1
        let body = text.trimmingCharacters(in: .newlines)
        let stamp = timestamp ?? pendingTS ?? current?.ts ?? startedAt ?? JournalStore.nowTS()
        let raw = JournalStore.makeEntry(timestamp: stamp, title: headerTitle, body: body).raw
        if let current {
            if raw == current.raw { saveError = nil; return true }
            // Opened and untouched: never re-normalise it on disk.
            if let o = opened, o.title == title, o.text == text, o.starred == starred { saveError = nil; return true }
            guard let result = store.saveEditorEntry(current, source: source, text: raw) else {
                reportFailure(); return false
            }
            self.current = result.entry
            savedSource = result.source
            // What's on disk now is the baseline an unchanged page compares to.
            opened = (title, text, starred)
            onUpdate(EntryRef(entry: result.entry, source: result.source))
        } else if !headerTitle.isEmpty || !body.isEmpty {
            guard let entry = store.createEditorDraft(timestamp: stamp, title: headerTitle, body: body) else {
                reportFailure(); return false
            }
            current = entry
            savedSource = .inbox
            startedAt = entry.ts
        }
        saveError = nil
        if current != nil { pendingTS = nil }
        mirror()
        return true
    }

    private func reportFailure() {
        savedFlash = false
        saveError = (store.lastWriteError ?? "The entry could not be saved.") + " Your edits are still open here. Retry, or save a copy to Inbox."
    }

    private func close() {
        finishRecordingIfNeeded()
        if saveNow() { dismiss() }
    }

    private func saveRecoveryCopy() {
        pending?.cancel()
        saveGeneration += 1
        guard let entry = store.createEditorDraft(timestamp: stampText, title: headerTitle, body: text) else {
            reportFailure(); return
        }
        current = entry
        savedSource = .inbox
        startedAt = entry.ts
        onUpdate(EntryRef(entry: entry, source: .inbox))
        pendingTS = nil
        saveError = nil
        mirror()
    }

    // MARK: The terminal app's keys while writing

    /// ^j file to its day · ^s save now (it autosaves) · ^t date and time ·
    /// ^f focus · ^p insert a prompt · ^d discard the draft · Esc back (saved).
    private func registerKeys() {
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: {}, moveDown: {}, open: {},
            clear: { close() },
            key: { _ in false },
            wantsChords: true,
            chord: { k in
                switch k {
                case "j": if isDraft { finish(); return true }; return false
                case "s": if saveNow() { flashSaved() }; return true
                case "t": showStamp = true; return true
                case "f": focusMode.toggle(); return true
                case "p": insertPrompt(); return true
                case "d": if isDraft { confirmDiscard = true; return true }; return false
                default: return false
                }
            }))
    }

    private func flashSaved() {
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { savedFlash = false }
    }

    private func insertPrompt() {
        let prompt = PromptDeck.prompts.randomElement() ?? "Begin writing"
        text += (text.isEmpty ? "" : "\n\n") + prompt + "\n"
    }

    private func discard() {
        if recorder.isRecording { _ = recorder.stop() }
        pending?.cancel()
        saveGeneration += 1
        if let cur = current {
            guard store.deleteEditorDraft(cur) else { reportFailure(); return }
        }
        onRemove()
        dismiss()
    }

    /// Retiming adopts the returned reference and leaves the editor open.
    private func applyStamp(_ date: Date) {
        let ts = JournalStore.ts(from: date)
        pendingTS = ts
        _ = saveNow(timestamp: ts)
        mirror()
    }

    /// File the draft, or just close a filed entry.
    private func finish() {
        finishRecordingIfNeeded()
        guard saveNow() else { return }
        if isDraft, let current {
            guard store.fileDraft(current) != nil else { reportFailure(); return }
            onRemove()
        }
        dismiss()
    }
}

/// ^t: the date and time of the page.
private struct StampSheet: View {
    @Environment(\.quire) private var q
    @Environment(\.dismiss) private var dismiss
    @State var initial: Date
    let onSave: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                QLink(title: "Cancel") { dismiss() }
                Spacer()
                QLink(title: "Set", emphasised: true) { onSave(initial); dismiss() }
            }
            QTitle(kicker: "Date and time", title: "When", size: 34)
            DatePicker("", selection: $initial, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical).labelsHidden().tint(q.accentColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26).padding(.top, 16)
        .background(q.pageColor.ignoresSafeArea())
        .preferredColorScheme(q.colorScheme)
        .environment(\.colorScheme, q.colorScheme)
        .presentationDetents([.large])
    }
}

#endif
