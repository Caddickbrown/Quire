//
//  ComposerScreen.swift
//  Quire
//
//  The page you write on. Nothing but the date, a title, the rule and the
//  text; saving happens as you type (a new page is a draft in the inbox) and
//  "File" sends it to its day. Focus quiets everything that isn't the text.
//

#if os(iOS)

import SwiftUI

struct ComposerScreen: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage(PromptDeck.enabledKey) private var promptsOn = false

    let target: ComposeTarget

    @State private var title = ""
    @State private var text = ""
    @State private var starred = false
    /// The entry being edited, kept current as saves land.
    @State private var current: Entry?
    /// A new page's draft timestamp: fixed on the first save, then the key it keeps.
    @State private var startedAt: String?
    @State private var focusMode = false
    @State private var loaded = false
    @State private var pending: Task<Void, Never>?
    @FocusState private var bodyFocused: Bool
    @State private var routerID = UUID()
    @State private var showStamp = false
    /// A date and time chosen (^t) before the first save of a new page.
    @State private var pendingTS: String?
    @State private var confirmDiscard = false
    @State private var savedFlash = false

    /// Today's prompt, when Settings → Writing prompts is on.
    private static var prompt: String {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return PromptDeck.prompts[day % PromptDeck.prompts.count]
    }

    private var editing: EntryRef? { target.ref }
    private var isDraft: Bool { editing == nil || editing?.source == .inbox }
    private var words: Int { text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count }
    private var quiet: Double { focusMode && bodyFocused ? 0.25 : 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(themeLabel) · \(QDate.longDay(stampDate))".uppercased()).tracking(1.6)
                        .font(q.ui(11)).foregroundStyle(q.mutedColor).opacity(quiet)
                    TextField("", text: $title, prompt: Text("Title").foregroundColor(q.faintColor), axis: .vertical)
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
            ExternalDisplayModel.shared.present(.idle)
            KeyCommandRouter.shared.unregister(routerID)
        }
        .sheet(isPresented: $showStamp) {
            StampSheet(initial: stampDate) { applyStamp($0) }.environment(\.quire, q)
        }
        .confirmationDialog("Discard this draft?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard() }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveNow() } }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            QLink(title: "Close") { saveNow(); dismiss() }
            Spacer()
            Text("[\(stampText)]").font(q.mono(12)).foregroundStyle(q.mutedColor)
            Spacer()
            QLink(title: starred ? "★" : "☆") { starred.toggle(); scheduleSave() }
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
            TextEditor(text: $text)
                .font(q.writing(fontSize + 2)).foregroundStyle(q.inkColor).tint(q.accentColor)
                .lineSpacing(8)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .focused($bodyFocused)
                .frame(minHeight: 360, alignment: .top)
                .padding(.horizontal, -5)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            QRule()
            HStack(spacing: 14) {
                Text("\(words) words · \(savedFlash ? "saved" : isDraft ? "draft" : "filed")")
                    .font(q.mono(12)).foregroundStyle(q.mutedColor).opacity(quiet)
                Spacer()
                Button { focusMode.toggle() } label: {
                    Text("Focus").font(q.ui(14, weight: focusMode ? .semibold : .regular))
                        .foregroundStyle(focusMode ? q.accentColor : q.inkColor)
                        .underline(focusMode, color: q.accentColor)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityAddTraits(focusMode ? .isSelected : [])
                Button(action: finish) {
                    Text(q.caps(editing == nil ? "File to today" : isDraft ? "File" : "Done"))
                        .font(q.isMarathon ? q.label(12, weight: .medium) : q.ui(14, weight: .semibold)).foregroundStyle(q.onSignalColor)
                        .padding(.horizontal, 18).frame(minHeight: 44).background(q.signalColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 4)
        }
        .background(q.pageColor)
    }

    // MARK: Time

    private var stampText: String { current?.ts ?? startedAt ?? pendingTS ?? JournalStore.nowTS() }
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
        }
        // The page opens ready to type into.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { if editing == nil { bodyFocused = true } }
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
        ExternalDisplayModel.shared.present(editing == nil
            ? .composing(title: title, date: stampDate, text: text, caret: nil)
            : .editing(title: title, date: stampDate, text: text, caret: nil, isStarred: starred))
    }

    private func scheduleSave() {
        guard loaded else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        pending?.cancel()
        let title = headerTitle
        let body = text.trimmingCharacters(in: .newlines)
        if let ref = editing, let cur = current {
            let newText = JournalStore.makeEntry(timestamp: cur.ts, title: title, body: body).raw
            guard newText != cur.raw else { return }
            let fallback = JournalStore.makeEntry(timestamp: cur.ts, title: title, body: body)
            switch ref.source {
            case .inbox:
                if store.updateDraft(cur, newText: newText) { current = store.writtenEntry(fallback: fallback) }
            case .archive(let d):
                if store.updateFiledEntry(date: d, original: cur, newText: newText) != nil {
                    current = store.writtenEntry(fallback: fallback)
                }
            case .journal(let n):
                if store.updateJournalEntry(name: n, original: cur, newText: newText) {
                    current = store.writtenEntry(fallback: fallback)
                }
            }
        } else {
            let stamp = startedAt ?? pendingTS ?? JournalStore.nowTS()
            if let used = store.upsertDraft(previous: startedAt, timestamp: stamp, title: title, body: body) {
                startedAt = used
            } else {
                startedAt = nil
            }
        }
    }

    // MARK: The terminal app's keys while writing

    /// ^j file to its day · ^s save now (it autosaves) · ^t date and time ·
    /// ^f focus · ^p insert a prompt · ^d discard the draft · Esc back (saved).
    private func registerKeys() {
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: {}, moveDown: {}, open: {},
            clear: { saveNow(); dismiss() },
            key: { _ in false },
            wantsChords: true,
            chord: { k in
                switch k {
                case "j": if isDraft { finish(); return true }; return false
                case "s": saveNow(); flashSaved(); return true
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
        pending?.cancel()
        if let cur = current { store.deleteDraft(cur) }
        else if let ts = startedAt { store.removeDraft(timestamp: ts) }
        dismiss()
    }

    /// A chosen date and time. A new page keeps it for its first save, or moves
    /// its draft; an entry that already exists is rewritten under it and the page
    /// closes, since it now lives under another time.
    private func applyStamp(_ date: Date) {
        let ts = JournalStore.ts(from: date)
        let body = text.trimmingCharacters(in: .newlines)
        if let ref = editing, let cur = current {
            let rewritten = JournalStore.makeEntry(timestamp: ts, title: headerTitle, body: body).raw
            switch ref.source {
            case .inbox: store.updateDraft(cur, newText: rewritten)
            case .archive(let d): store.updateFiledEntry(date: d, original: cur, newText: rewritten)
            case .journal(let n): _ = store.updateJournalEntry(name: n, original: cur, newText: rewritten)
            }
            dismiss()
        } else {
            pendingTS = ts
            if startedAt != nil {
                startedAt = store.upsertDraft(previous: startedAt, timestamp: ts, title: headerTitle, body: body) ?? startedAt
            }
        }
    }

    /// File the draft, or just close a filed entry.
    private func finish() {
        saveNow()
        if isDraft {
            let ts = current?.ts ?? startedAt
            if let draft = store.inboxDrafts.first(where: { $0.ts == ts }) { store.fileDraft(draft) }
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
        .presentationDetents([.large])
    }
}

#endif
