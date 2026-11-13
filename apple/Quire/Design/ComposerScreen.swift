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
    /// The body's words live in an object the page doesn't watch: only the
    /// small view around the editor (`ComposerBody`) is redrawn as you type,
    /// not the whole page with its header, title field and footer.
    @State private var draft = ComposerText()
    private var text: String {
        get { draft.text }
        nonmutating set { draft.text = newValue }
    }
    /// For edits that don't come from the keyboard (a link, a prompt, a
    /// transcript): they go into the editor as ranged edits.
    @State private var editorProxy = WritingEditorProxy()
    @State private var starred = false
    /// The entry being edited, kept current as saves land.
    @State private var current: Entry?
    /// A new page's draft timestamp: fixed at the first keystroke (as `jnl new`
    /// stamps when you start writing), then the key it keeps.
    @State private var startedAt: String?
    @State private var focusMode = false
    @State private var loaded = false
    /// What an existing entry opened with: unchanged, it isn't written back, so
    /// opening an entry never re-normalises it on disk.
    @State private var opened: (title: String, text: String, starred: Bool)?
    private enum Field: Hashable { case title, body }
    /// Where the keyboard is, as UIKit last reported it, and where it is asked
    /// to go. Plain state, not `@FocusState`: the two fields are UIKit views
    /// and report their own first responder, and a second arbiter beside them
    /// is how the keyboard came to be fought over. Each field acts on a change
    /// of this, once (see `WritingTextEditor.Coordinator.request`).
    @State private var focus: Field?
    /// The page's visible size, and how far down it the body starts, so the
    /// text view can reach the footer (a tap below the words is then a tap in
    /// the text).
    @State private var page: CGSize = .zero
    @State private var editorTop: CGFloat = 0
    /// What changes on every keystroke but isn't drawn here: kept out of
    /// SwiftUI state, so writing it never asks for another pass over the page.
    @State private var scratch = Scratch()
    /// The footer's count, brought up to date a moment after typing pauses
    /// rather than recounted from the whole text on every keystroke.
    @State private var words = 0
    /// The known tags for the @ bar, rebuilt when the store's tags change
    /// rather than on every keystroke's pass over the page.
    @State private var tagNames: [String] = []
    @State private var savedSource: EntrySource?
    @State private var saveError: String?
    @State private var recoverCopy = false
    @State private var routerID = UUID()
    @State private var showStamp = false
    @ObservedObject private var datePicker = DeskDatePicker.shared
    @ObservedObject private var deskConfirm = DeskConfirm.shared
    /// A date and time chosen (^t) before the first save of a new page.
    @State private var pendingTS: String?
    @State private var confirmDiscard = false
    @State private var savedFlash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Filing turns the page over, away from you, before it closes.
    @State private var turning = false
    /// Felt moments: filed (success), saved (land), a write that failed (warning).
    @State private var filedBeat = 0
    @State private var savedBeat = 0
    @State private var failedBeat = 0
    @State private var showingPhotoPicker = false
    @State private var showingFilePicker = false
    @State private var showingPhotoCapture = false
    @State private var showingVideoRecorder = false
    @State private var photoItem: PhotosPickerItem?
    @StateObject private var recorder = AudioRecorder()
    /// A brief word in the footer (a refused drop).
    @State private var notice: String?
    @State private var leaving = false

    /// Today's prompt, when Settings → Writing prompts is on.
    private static var prompt: String {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return PromptDeck.prompts[day % PromptDeck.prompts.count]
    }

    private var editing: EntryRef? { target.ref }
    private var source: EntrySource { savedSource ?? editing?.source ?? .inbox }
    private var isDraft: Bool { source == .inbox }
    private static func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }
    /// The other drafts still waiting, for working through the inbox one by one.
    private var draftsLeft: Int { store.inboxDrafts.filter { $0.id != current?.id }.count }
    private var draftsNote: String {
        if draftsLeft > 0 { return " · \(draftsLeft) \(draftsLeft == 1 ? "draft" : "drafts") left" }
        return isDraft && current != nil ? " · last draft" : ""
    }
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
                        Button("Copy text") { copyText() }
                    }.font(q.ui(14))
                }.padding(.horizontal, 20).padding(.vertical, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(themeLabel) · \(QDate.longDay(stampDate))".uppercased()).tracking(1.6)
                        .font(q.ui(11)).foregroundStyle(q.mutedColor).opacity(quiet)
                    QEscapingField(text: $title, placeholder: "Title", font: titleFont, color: UIColor(q.inkColor),
                                       placeholderColor: UIColor(q.faintColor), tint: UIColor(q.accentColor),
                                       focused: Binding(get: { focus == .title },
                                                        set: { if $0 { focus = .title } else if focus == .title { focus = nil } }),
                                       identifier: "composer.title",
                                       onSubmit: { focus = .body })
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(quiet)
                    QTitleRule().qDrawIn().opacity(quiet)
                    editor
                }
                .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, Self.bottomPadding)
                .coordinateSpace(.named(Self.pageSpace))
            }
            // The tallest the page has been at this width: the keyboard coming
            // and going doesn't resize the body under your hands.
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if abs(size.width - page.width) > 0.5 { page = size }
                else if size.height > page.height + 0.5 { page.height = size.height }
            }
            .scrollDismissesKeyboard(.interactively)
            footer
        }
        .background(q.pageColor.ignoresSafeArea())
        .rotation3DEffect(.degrees(turning ? -80 : 0), axis: (x: 0, y: 1, z: 0),
                          anchor: .leading, perspective: 0.45)
        .opacity(turning ? 0 : 1)
        .qHaptic(.success, trigger: filedBeat)
        .qHaptic(.land, trigger: savedBeat)
        .qHaptic(.warning, trigger: failedBeat)
        .background(chordKeys)
        // The monitor's date picker or question takes the keys while it is up: the
        // text is let go, and this catcher holds first responder in its place.
        .background {
            if datePicker.isOpen || deskConfirm.isOpen {
                KeyCommandCatcher().frame(width: 0, height: 0).allowsHitTesting(false)
            }
        }
        .onAppear { scratch.closing = false; ComposerRecovery.live.insert(scratch.recoveryID); load(); registerKeys() }
        .onChange(of: title) { _, _ in stampOnFirstKeystroke(); scheduleSave(); mirror() }
        .onReceive(store.$tagCounts) { counts in tagNames = counts.map { String($0.tag.dropFirst()) } }
        .onDisappear {
            // However the page came to be taken down (a widget or a link
            // opening another, not only Close), what's unsaved is saved first.
            // After Close this finds nothing to write; after a discard or a
            // filing it is skipped; an empty page still makes no draft.
            scratch.closing = true
            if loaded, !scratch.settled {
                finishRecordingIfNeeded()
                saveNow()
            }
            scratch.pending?.cancel()
            ComposerRecovery.live.remove(scratch.recoveryID)
            store.settlePendingRebuild()
            scratch.countTask?.cancel()
            DeskDatePicker.shared.cancel()
            DeskConfirm.shared.cancel(owner: routerID)
            ExternalDisplayModel.shared.releasePage(owner: routerID)
            KeyCommandRouter.shared.unregister(routerID)
        }
        .interactiveDismissDisabled()
        .onChange(of: focus) { _, _ in mirror() }
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

    /// The title's face: Newsreader Medium, or Marathon's wide display Archivo.
    private var titleFont: UIFont {
        if q.isMarathon { return QuireFont.uiArchivo(30, weight: 800, width: 125) }
        let base = UIFont(name: "NewsreaderRoman-Medium", size: 32) ?? .systemFont(ofSize: 32, weight: .medium)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            QLink(title: "Close") { close() }.accessibilityIdentifier("composer.close")
            Spacer()
            Button { showStamp = true } label: {
                Text("[\(stampText)]").font(q.mono(12)).foregroundStyle(q.mutedColor).underline(pattern: .dot)
                    .frame(minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel("Change date and time")
            Spacer()
            Button { starred.toggle() } label: {
                Image(systemName: starred ? "star.fill" : "star").font(.system(size: 18))
                    .foregroundStyle(starred ? q.accentColor : q.mutedColor)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(starred ? "Starred" : "Star")
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    /// The chords again for the title field, which is a SwiftUI field and so
    /// can't declare them itself; the body's text view declares its own.
    private var chordKeys: some View {
        ZStack {
            ForEach(KeyCommandRouter.chords, id: \.self) { k in
                Button(k) { KeyCommandRouter.shared.chord(k) }
                    .keyboardShortcut(KeyEquivalent(Character(k)), modifiers: .control)
            }
            CommandMenuShortcut()
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    private static let pageSpace = "composer.page"
    private static let bottomPadding: CGFloat = 24

    /// From where the body starts to the foot of the page.
    private var bodyMinHeight: CGFloat {
        max(240, page.height - editorTop - Self.bottomPadding)
    }

    private var editor: some View {
        ComposerBody(draft: draft,
                     placeholder: editing == nil ? (promptsOn ? Self.prompt : "Begin writing") : "",
                     size: fontSize + 2, tagNames: tagNames, minHeight: bodyMinHeight, proxy: editorProxy,
                     focused: Binding(get: { focus == .body },
                                      set: { if $0 { focus = .body } else if focus == .body { focus = nil } }),
                     onEdit: { stampOnFirstKeystroke(); scheduleSave(); mirror(); scheduleCount() },
                     onCaretChange: caretMoved,
                     onPasteMedia: { if let rel = Attach.pasted($0, into: store) { link(rel) } })
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.pageSpace)).minY.rounded() }
                action: { editorTop = $0 }
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
                    Text(notice ?? "\(words) words · \(savedFlash ? "saved" : isDraft ? "draft" : "filed")\(draftsNote)")
                        .font(q.mono(12)).foregroundStyle(q.mutedColor).opacity(quiet)
                        .lineLimit(1).minimumScaleFactor(0.8)
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
                .buttonStyle(.plain).accessibilityIdentifier("composer.file")
            }
            .padding(.horizontal, 20).padding(.vertical, 4)
        }
        .background(q.pageColor)
    }

    // MARK: Attachments

    /// Put an attachment's link in the body where the caret was, and the
    /// caret after it.
    private func link(_ rel: String) {
        edit(to: JournalStore.linking(rel, into: text, at: scratch.lastCaret), moveCaret: true)
    }

    /// Change the body to `new` from outside the keyboard. Only what differs
    /// goes into the editor, as one undoable edit, so the caret, the undo
    /// stack and the words around it stay as they were. Assigning the whole
    /// text is kept for when there is no live editor (the page is closing).
    private func edit(to new: String, moveCaret: Bool) {
        let old = text
        guard new != old else { return }
        let a = old as NSString, b = new as NSString
        let shortest = min(a.length, b.length)
        var prefix = 0
        while prefix < shortest, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        // Never between the two halves of one character.
        if prefix > 0, UTF16.isLeadSurrogate(a.character(at: prefix - 1)) { prefix -= 1 }
        var suffix = 0
        while suffix < shortest - prefix,
              a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a.character(at: a.length - suffix)) { suffix -= 1 }
        let range = NSRange(location: prefix, length: a.length - prefix - suffix)
        let replacement = b.substring(with: NSRange(location: prefix, length: b.length - prefix - suffix))
        if !scratch.closing, editorProxy.replace(range, with: replacement, in: a.length, moveCaret: moveCaret) { return }
        text = new
    }

    /// The failure banner's last resort: the words on the clipboard.
    private func copyText() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        UIPasteboard.general.string = t.isEmpty ? text : t + "\n\n" + text
        say("Copied")
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
            // Beneath its link, wherever the caret has got to since.
            edit(to: Transcriber.insert(transcript: transcript, after: rel, in: text), moveCaret: false)
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
            // As typed: a line the core guards with a backslash opens without it,
            // and `makeEntry` puts it back on save, so an unchanged page still
            // composes to `current.raw`.
            text = ref.entry.shownBody
            starred = ref.entry.isStarred
            opened = (title, text, starred)
        }
        words = Self.count(text)
        // The page opens ready to type into.
        // A new page starts on its title; an entry opens ready to carry on,
        // with the cursor at the end of its text.
        DispatchQueue.main.async { focus = editing == nil ? .title : .body }
        mirror()
        // The edits above would otherwise schedule a save of unchanged text.
        scratch.pending?.cancel()
    }

    private var headerTitle: String { Self.headerTitle(title, starred: starred) }

    /// The header's title as it is written. A trailing ` *` is the star
    /// (`journal::has_star`, `Entry.hasStarMarker`), so a title that only
    /// happens to end in one would be saved as a starred entry and come back
    /// two characters short. Starred, the real marker goes after it and it
    /// reads back whole; unstarred, the asterisk is closed up to the word
    /// before it, where it is not a marker, and a title of just `*` is no title.
    static func headerTitle(_ title: String, starred: Bool) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if starred { return t.isEmpty ? "*" : t + " *" }
        guard Entry.hasStarMarker(t) else { return t }
        let before = String(t.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return before.isEmpty ? "" : before + "*"
    }

    /// Republish the page to a connected monitor as you type. A keystroke
    /// reaches here from the text and from the caret; the same page twice is
    /// sent once.
    private func mirror() {
        guard loaded else { return }
        let caret = scratch.caret
        let content: ExternalDisplayContent = editing == nil
            ? .composing(title: title, date: stampDate, text: text, caret: caret, inTitle: focus == .title)
            : .editing(title: title, date: stampDate, text: text, caret: caret, isStarred: starred, isDraft: isDraft,
                       inTitle: focus == .title)
        guard content != scratch.mirrored else { return }
        scratch.mirrored = content
        ExternalDisplayModel.shared.present(content, owner: routerID)
    }

    /// The body's caret moved. Only the monitor shows it, so it is kept off
    /// the page's state, and the monitor hears on the next turn: the editor
    /// can report it while SwiftUI is still updating the page.
    private func caretMoved(_ new: Int?) {
        if let new { scratch.lastCaret = new }
        guard new != scratch.caret else { return }
        scratch.caret = new
        DispatchQueue.main.async { mirror() }
    }

    /// The footer's word count, a quarter of a second after the last keystroke.
    private func scheduleCount() {
        scratch.countTask?.cancel()
        scratch.countTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let n = Self.count(text)
            if n != words { words = n }
        }
    }

    /// Until now the header showed the time of each redraw, so typing and
    /// deleting a letter before the first save moved it on every keystroke.
    private func stampOnFirstKeystroke() {
        guard loaded, editing == nil, current == nil, startedAt == nil,
              !title.isEmpty || !text.isEmpty else { return }
        startedAt = JournalStore.nowTS()
    }

    private func scheduleSave() {
        guard loaded else { return }
        // Only when it is showing: this runs on every keystroke, and the
        // footer has no need to hear about each one.
        if savedFlash { savedFlash = false }
        scratch.pending?.cancel()
        scratch.saveGeneration += 1
        let generation = scratch.saveGeneration
        scratch.pending = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled, generation == scratch.saveGeneration { saveNow() }
        }
    }

    @discardableResult
    private func saveNow(timestamp: String? = nil) -> Bool {
        scratch.pending?.cancel()
        scratch.saveGeneration += 1
        let body = text.trimmingCharacters(in: .newlines)
        let stamp = timestamp ?? pendingTS ?? current?.ts ?? startedAt ?? JournalStore.nowTS()
        let raw = JournalStore.makeEntry(timestamp: stamp, title: headerTitle, body: body).raw
        if let current {
            if raw == current.raw { settleSaved(); return true }
            // Opened and untouched: never re-normalise it on disk. A new date
            // (^t, the stamp) is a change too: without the check it was dropped
            // whenever the words hadn't moved since the last save.
            if let o = opened, o.title == title, o.text == text, o.starred == starred, stamp == current.ts {
                settleSaved(); return true
            }
            keepForRecovery(stamp: stamp, composed: raw)
            guard let result = store.saveEditorEntry(current, source: source, text: raw) else {
                reportFailure(); return false
            }
            self.current = result.entry
            savedSource = result.source
            // What's on disk now is the baseline an unchanged page compares to.
            opened = (title, text, starred)
            onUpdate(EntryRef(entry: result.entry, source: result.source))
        } else if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !body.isEmpty {
            // Words, not just a star: a starred page with nothing on it is not a draft.
            keepForRecovery(stamp: stamp, composed: raw)
            guard let entry = store.createEditorDraft(timestamp: stamp, title: headerTitle, body: body) else {
                reportFailure(); return false
            }
            current = entry
            savedSource = .inbox
            startedAt = entry.ts
        }
        settleSaved()
        if current != nil { pendingTS = nil }
        mirror()
        return true
    }

    /// The journal holds what's on the page: no error, and nothing to recover.
    private func settleSaved() {
        if saveError != nil { saveError = nil }
        dropRecovery()
    }

    /// Before each write to the journal, the page goes to a small file in the
    /// app's own container. If the write fails and the app is then killed, the
    /// words are there at the next launch (`ComposerRecovery.pending()`).
    private func keepForRecovery(stamp: String, composed: String) {
        let sourceName: String
        switch source {
        case .inbox: sourceName = "inbox"
        case .archive(let date): sourceName = "archive:\(date)"
        case .journal(let name): sourceName = "journal:\(name)"
        }
        let record = ComposerRecovery(id: scratch.recoveryID, savedAt: Date(), title: title, text: text,
                                      starred: starred, stamp: stamp, composed: composed,
                                      file: current?.file, index: current?.fileIndex, raw: current?.raw,
                                      source: current == nil ? nil : sourceName)
        if record.write() { scratch.recoveryKept = true }
    }

    private func dropRecovery() {
        guard scratch.recoveryKept else { return }
        scratch.recoveryKept = false
        ComposerRecovery.remove(scratch.recoveryID)
    }

    private func reportFailure() {
        savedFlash = false
        failedBeat += 1
        saveError = (store.lastWriteError ?? "The entry could not be saved.") + " Your edits are still open here. Retry, or save a copy to Inbox."
    }

    private func close() {
        finishRecordingIfNeeded()
        if saveNow() { leave() }
    }

    private func saveRecoveryCopy() {
        scratch.pending?.cancel()
        scratch.saveGeneration += 1
        keepForRecovery(stamp: stampText,
                        composed: JournalStore.makeEntry(timestamp: stampText, title: headerTitle, body: text).raw)
        guard let entry = store.createEditorDraft(timestamp: stampText, title: headerTitle, body: text) else {
            reportFailure(); return
        }
        current = entry
        savedSource = .inbox
        startedAt = entry.ts
        onUpdate(EntryRef(entry: entry, source: .inbox))
        pendingTS = nil
        // The copy is the page now: it is what an unchanged page compares to.
        opened = (title, text, starred)
        settleSaved()
        mirror()
    }

    // MARK: The terminal app's keys while writing

    /// ^j file to its day · ^s save now (it autosaves) · ^t date and time ·
    /// ^f focus · ^p insert a prompt · ^d discard the draft · Esc back (saved),
    /// or out of whatever the page has open first.
    private func registerKeys() {
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: {}, moveDown: {}, open: {},
            clear: { if !closeOverlay() { close() } },
            key: { _ in false },
            wantsChords: true,
            chord: { k in
                switch k {
                case "j": if isDraft { finish(); return true }; return false
                case "s": if saveNow() { flashSaved() }; return true
                case "t": changeDate(); return true
                case "f": focusMode.toggle(); return true
                case "p": insertPrompt(); return true
                case "d": if isDraft { askDiscard(); return true }; return false
                default: return false
                }
            }))
    }

    /// Esc with something up over the page closes that, and the page stays. A
    /// question is cancelled, never answered. The camera has its own Cancel, and a
    /// recording mustn't go on one key: Esc waits for it.
    private func closeOverlay() -> Bool {
        if showingPhotoCapture || showingVideoRecorder { return true }
        guard showStamp || confirmDiscard || recoverCopy || showingPhotoPicker || showingFilePicker else { return false }
        showStamp = false; confirmDiscard = false; recoverCopy = false
        showingPhotoPicker = false; showingFilePicker = false
        return true
    }

    private func flashSaved() {
        savedFlash = true
        savedBeat += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { savedFlash = false }
    }

    private func insertPrompt() {
        let prompt = PromptDeck.prompts.randomElement() ?? "Begin writing"
        // At the end of the page, as an edit of its own: ⌘Z takes it back.
        edit(to: text + (text.isEmpty ? "" : "\n\n") + prompt + "\n", moveCaret: true)
    }

    private func discard() {
        if recorder.isRecording { _ = recorder.stop() }
        scratch.pending?.cancel()
        scratch.saveGeneration += 1
        if let cur = current {
            guard store.deleteEditorDraft(cur) else { reportFailure(); return }
        }
        // Discarded on purpose: no last save as the page goes, nothing to recover.
        scratch.settled = true
        dropRecovery()
        onRemove()
        leave()
    }

    /// ^d: on the monitor in desk mode, where the keyboard can answer it; the
    /// phone's dialog otherwise. The text is let go while it is up, as for ^t.
    private func askDiscard() {
        guard DeskConfirm.shared.isAvailable else { confirmDiscard = true; return }
        let was = focus
        let firstLine = text.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? firstLine : title
        // On the next turn, not inside the key's own handling (see `leave`).
        DispatchQueue.main.async {
            focus = nil
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            DeskConfirm.shared.open(.init(kicker: "Writing", question: "Discard this draft?",
                                          detail: name.isEmpty ? "Untitled" : String(name.prefix(200)),
                                          when: "\(QDate.shortDay(String(stampText.prefix(10)))) · \(QDate.time(stampText))",
                                          action: "Discard"),
                                    owner: routerID,
                                    onConfirm: {
                                        discard()
                                        return leaving ? nil : (saveError ?? "The draft could not be discarded.")
                                    },
                                    onClose: { DispatchQueue.main.async { if !leaving { focus = was ?? .body } } })
        }
    }

    /// ^t: on the monitor in desk mode, where the keyboard can work it; the
    /// phone's sheet otherwise (and always from a tap on the date).
    private func changeDate() {
        guard DeskDatePicker.shared.isAvailable else { showStamp = true; return }
        let was = focus
        // On the next turn, not inside the key's own handling (see `leave`).
        DispatchQueue.main.async {
            focus = nil
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            DeskDatePicker.shared.open(date: stampDate, title: title,
                                       onSet: { applyStamp($0); return nil },
                                       onClose: { DispatchQueue.main.async { if !leaving { focus = was ?? .body } } })
        }
    }

    /// Retiming adopts the returned reference and leaves the editor open.
    private func applyStamp(_ date: Date) {
        let ts = JournalStore.ts(from: date)
        pendingTS = ts
        _ = saveNow(timestamp: ts)
        mirror()
    }

    /// Close the page. The cursor is let go first and the page closes on the
    /// next turn of the run loop: closing it with a hardware key still being
    /// handled (^j, Esc) set SwiftUI dropping the text view's focus against
    /// UIKit and the key catcher taking it back, each swap rebuilding the
    /// keyboard's input views, until the watchdog killed the app.
    private func leave() {
        // Esc can arrive from more than one place; the page closes once.
        guard !leaving else { return }
        leaving = true
        focus = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        DispatchQueue.main.async { dismiss() }
    }

    /// File the draft, or just close a filed entry.
    private func finish() {
        finishRecordingIfNeeded()
        guard saveNow() else { return }
        if isDraft, let current {
            guard store.fileDraft(current) != nil else { reportFailure(); return }
            // Filed: the reference this page holds is the draft that was.
            scratch.settled = true
            onRemove()
            filedBeat += 1
            // The page turns over to its day before it closes.
            if !reduceMotion {
                focus = nil
                withAnimation(QMotion.move) { turning = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { leave() }
                return
            }
        }
        leave()
    }
}

/// The composer's per-keystroke bookkeeping (see `ComposerScreen.scratch`).
private final class Scratch {
    var caret: Int?
    /// Where the caret last was in the body: a picker sheet takes focus away,
    /// and what it brings back still lands there.
    var lastCaret: Int?
    var countTask: Task<Void, Never>?
    /// The page last sent to the monitor.
    var mirrored: ExternalDisplayContent?
    /// The autosave waiting out its pause, and which one it is.
    var pending: Task<Void, Never>?
    var saveGeneration = 0
    /// Discarded or filed: the page has nothing left to save as it goes.
    var settled = false
    /// The page is being taken down: edits go to the text, not the editor.
    var closing = false
    /// This page's recovery file, and whether one is on disk.
    let recoveryID = UUID()
    var recoveryKept = false
}

/// The body's words, outside the page's own state (see `ComposerScreen.draft`).
final class ComposerText: ObservableObject {
    @Published var text = ""
}

/// The body: the placeholder and the editor. The only view that is redrawn on
/// a keystroke.
private struct ComposerBody: View {
    @Environment(\.quire) private var q
    @ObservedObject var draft: ComposerText
    let placeholder: String
    let size: Double
    let tagNames: [String]
    let minHeight: CGFloat
    let proxy: WritingEditorProxy
    let focused: Binding<Bool>
    let onEdit: () -> Void
    let onCaretChange: (Int?) -> Void
    let onPasteMedia: (PastedMedia) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if draft.text.isEmpty {
                Text(placeholder).font(q.writing(size, italic: true))
                    .foregroundStyle(q.faintColor).padding(.top, 8).allowsHitTesting(false)
                    .qHover()
            }
            // The text view is as tall as the page (`minHeight`), so a tap
            // anywhere below the words lands in it and UIKit places the caret.
            WritingTextEditor(text: $draft.text, fontRaw: q.editorFontName,
                              size: size, textColor: q.inkColor, lineSpacing: 8,
                              accent: q.accentColor, sizeToFit: true,
                              tagSuggestions: tagNames,
                              onCaretChange: onCaretChange,
                              onPasteMedia: onPasteMedia,
                              focused: focused, minHeight: minHeight, proxy: proxy,
                              identifier: "composer.body")
        }
        .onChange(of: draft.text) { _, _ in onEdit() }
    }
}

/// What the composer was about to write, kept in the app's own container
/// (Application Support, not the journal folder and not the App Group) from
/// just before each write until the write succeeds or the page is discarded.
/// One small file per open page. A file found at launch means a write never
/// landed, or the app died in the moment between keeping and writing: check
/// `composed` against the journal before offering it.
struct ComposerRecovery: Codable, Equatable, Identifiable {
    var id: UUID
    var savedAt: Date
    var title: String
    /// The body as it stood in the editor.
    var text: String
    var starred: Bool
    /// `YYYY-MM-DD HH:MM:SS`.
    var stamp: String
    /// The whole entry as it was about to be written, header line included.
    var composed: String
    /// The entry being edited: its file, index and raw text, and `inbox`,
    /// `archive:<date>` or `journal:<name>`. All nil for a page never saved.
    var file: String?
    var index: Int?
    var raw: String?
    var source: String?

    /// Pages open now: theirs are not "pending", they are in hand.
    static var live: Set<UUID> = []

    /// The oldest page whose words never reached the journal, if any.
    static func pending() -> ComposerRecovery? { all().first }

    /// Every such page, oldest first.
    static func all() -> [ComposerRecovery] {
        guard let dir = directory(create: false),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ComposerRecovery.self, from: Data(contentsOf: $0)) }
            .filter { !live.contains($0.id) }
            .sorted { $0.savedAt < $1.savedAt }
    }

    /// Forget the one `pending()` returns: it was restored, or declined.
    static func clear() { if let record = pending() { remove(record.id) } }

    static func remove(_ id: UUID) {
        guard let dir = directory(create: false) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id.uuidString + ".json"))
    }

    /// Atomically: the file is whole or it is the one before.
    func write() -> Bool {
        guard let dir = Self.directory(create: true), let data = try? JSONEncoder().encode(self) else { return false }
        do {
            try data.write(to: dir.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
            return true
        } catch { return false }
    }

    private static func directory(create: Bool) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("ComposerRecovery", isDirectory: true)
        if create { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }
}

/// A one-line field in UIKit so it can claim Esc: a SwiftUI TextField's
/// UITextField keeps Esc for itself, so from a new page (which opens on its
/// title) Esc never reached the composer and the page couldn't be left from
/// the keyboard, and Search, which opens on its field, was the same. Focus
/// follows the host's own, as the body's editor does: `focused` is the one
/// channel, so don't add SwiftUI's `.focused()` beside it.
struct QEscapingField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var placeholderFont: UIFont? = nil
    let font: UIFont
    let color: UIColor
    let placeholderColor: UIColor
    let tint: UIColor
    var focused: Binding<Bool>
    var returnKey: UIReturnKeyType = .next
    /// Off for a search: what's typed is a query, not prose.
    var plain = false
    /// For UI tests to find the field by; nothing reads it otherwise.
    var identifier: String? = nil
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EscapingTextField {
        let field = EscapingTextField()
        field.delegate = context.coordinator
        field.returnKeyType = returnKey
        if plain {
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        field.borderStyle = .none
        field.accessibilityIdentifier = identifier
        field.adjustsFontForContentSizeCategory = false
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        context.coordinator.field = field
        field.onWindow = { [weak coordinator = context.coordinator] in coordinator?.attached() }
        return field
    }

    func updateUIView(_ field: EscapingTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.field = field
        // Each only when it differs: this runs whenever the page around the
        // field is redrawn, and a setter on a text field is not free.
        if (field.text ?? "") != text { field.text = text }
        if field.font != font { field.font = font }
        if field.textColor != color { field.textColor = color }
        if field.tintColor != tint { field.tintColor = tint }
        let shown = Coordinator.Placeholder(text: placeholder, font: placeholderFont ?? font, color: placeholderColor)
        if coordinator.placeholder != shown {
            coordinator.placeholder = shown
            field.attributedPlaceholder = NSAttributedString(string: placeholder,
                attributes: [.font: shown.font, .foregroundColor: placeholderColor])
        }
        // Never first responder from in here (see `Coordinator.request`).
        coordinator.request(focus: focused.wrappedValue, on: field)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        struct Placeholder: Equatable {
            let text: String
            let font: UIFont
            let color: UIColor
        }

        var parent: QEscapingField
        weak var field: EscapingTextField?
        var placeholder: Placeholder?
        /// The focus last asked for or last reported by UIKit; a request is
        /// acted on only when it differs. The same rule as the body's editor.
        private var lastFocus: Bool?
        /// Asked for before the field had a window; kept for when it does.
        private var focusOwed = false

        init(_ parent: QEscapingField) { self.parent = parent }

        /// On the next turn, after SwiftUI's update, and only for a change:
        /// asking on every update set two fields taking the keyboard from each
        /// other.
        func request(focus want: Bool, on field: EscapingTextField) {
            guard want != lastFocus else { return }
            lastFocus = want
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, self.lastFocus == want else { return }
                self.applyFocus(field)
            }
        }

        private func applyFocus(_ field: EscapingTextField) {
            guard let want = lastFocus else { return }
            guard field.window != nil else { focusOwed = true; return }
            focusOwed = false
            if want, !field.isFirstResponder {
                // Refused: forget the request, so the next change of anything asks again.
                if !field.becomeFirstResponder() { lastFocus = nil }
            } else if !want, field.isFirstResponder {
                field.resignFirstResponder()
            }
        }

        /// The field joined a window with a request still owed.
        func attached() {
            guard focusOwed else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusOwed, let field = self.field else { return }
                self.applyFocus(field)
            }
        }

        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) {
            // UIKit's word on it, recorded before the binding echoes it back.
            lastFocus = true
            focusOwed = false
            if !parent.focused.wrappedValue { parent.focused.wrappedValue = true }
        }
        func textFieldDidEndEditing(_ field: UITextField) {
            lastFocus = false
            focusOwed = false
            if parent.focused.wrappedValue { parent.focused.wrappedValue = false }
        }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { parent.onSubmit(); return false }
    }
}

/// Declares Esc and ⌘. ahead of the text system and hands them to the router,
/// and the composer's control chords too: a new page starts in this field, and
/// without them the field's own text system took ^t (transpose) and the date
/// picker never opened on the monitor.
final class EscapingTextField: UITextField {
    /// Told when the field joins a window: a focus request made before it was
    /// on screen is acted on then.
    var onWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onWindow?() }
    }

    override var keyCommands: [UIKeyCommand]? {
        let esc = EscapeChord.declared(composing: markedTextRange != nil).map { $0.keyCommand(action: #selector(quireEscape)) }
        let own = (super.keyCommands ?? []) + esc + [CommandKeys.toggle]
        guard KeyCommandRouter.shared.wantsChords else { return own }
        return own + KeyCommandRouter.chords.map {
            let c = UIKeyCommand(input: $0, modifierFlags: .control, action: #selector(quireChord(_:)))
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }

    @objc private func quireEscape() { KeyCommandRouter.shared.clear() }
    @objc private func quireChord(_ command: UIKeyCommand) {
        if let input = command.input { KeyCommandRouter.shared.chord(input) }
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
