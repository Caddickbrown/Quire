//
//  WritingView.swift
//  Jibber
//
//  The composer. A title field + date/time picker sit above the body; everything
//  autosaves continuously into one inbox draft in the jnl format
//  ([timestamp] title / body). Paste multi-entry text and "Import" splits it into
//  separate drafts.
//

import SwiftUI

struct WritingView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @AppStorage("writingFont") private var writingFontRaw: String = WritingFont.lato.rawValue
    @AppStorage("timerMinutes") private var timerMinutes: Int = 15

    @State private var timerRemaining = 15 * 60
    @State private var timerRunning = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var title = ""
    @State private var date = Date()
    @State private var text = ""
    @State private var activeTS: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var toast: String?
    @FocusState private var bodyFocused: Bool

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
                              lineSpacing: Theme.lineSpacing(for: size))
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
                timerMenu
                Button {
                    saveNow()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasText)
                .help("Save to inbox (⌘S)")
                Button {
                    newEntry()
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
                .disabled(!hasText)
                .help("Start a new entry")
                Menu {
                    Button {
                        promoteFirstLine()
                    } label: {
                        Label("Promote first line to title", systemImage: "arrow.up.to.line")
                    }
                    .disabled(!hasFirstBodyLine)
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
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: date) { _, _ in scheduleSave() }
        .onChange(of: nav.newEntrySignal) { _, _ in newEntry() }
        .onChange(of: timerMinutes) { _, m in if !timerRunning { timerRemaining = m * 60 } }
        .onReceive(ticker) { _ in
            guard timerRunning else { return }
            if timerRemaining > 0 { timerRemaining -= 1 } else { timerRunning = false }
        }
        .onAppear {
            if !timerRunning { timerRemaining = timerMinutes * 60 }
            bodyFocused = true
        }
        .onDisappear { flush() }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
    }

    private var timerString: String {
        String(format: "%d:%02d", timerRemaining / 60, timerRemaining % 60)
    }

    private var timerMenu: some View {
        Menu {
            Button(timerRunning ? "Pause" : "Start") { timerRunning.toggle() }
            Button("Reset") { timerRunning = false; timerRemaining = timerMinutes * 60 }
            Divider()
            Picker("Duration", selection: $timerMinutes) {
                ForEach([5, 10, 15, 20, 25, 30], id: \.self) { Text("\($0) min").tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(timerString, systemImage: "timer")
                .monospacedDigit()
        }
        .help("Writing timer")
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

    private func commit() {
        guard hasText else {
            if let ts = activeTS { store.removeDraft(timestamp: ts); activeTS = nil }
            return
        }
        let ts = JournalStore.ts(from: date)
        store.upsertDraft(previous: activeTS, timestamp: ts, title: title, body: text)
        activeTS = ts
    }

    private func flush() {
        saveTask?.cancel()
        commit()
    }

    /// Explicit save (⌘S): commit immediately and confirm.
    private func saveNow() {
        flush()
        showToast("Saved to inbox")
    }

    private func newEntry() {
        flush()
        reset()
        bodyFocused = true
    }

    private func importEntries() {
        // Drop the single working draft, then split the pasted text into drafts.
        if let ts = activeTS { store.removeDraft(timestamp: ts); activeTS = nil }
        let n = store.importDrafts(from: text)
        reset()
        showToast(n == 1 ? "Imported 1 entry" : "Imported \(n) entries")
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
