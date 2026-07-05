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

    @State private var title = ""
    @State private var date = Date()
    @State private var text = ""
    @State private var activeTS: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var toast: String?
    @FocusState private var bodyFocused: Bool

    private var size: CGFloat { CGFloat(fontSize) }
    private var font: Font { Theme.font(writingFontRaw, size: size) }
    // The text view's built-in left inset differs by platform; match it so the
    // placeholder's left edge lands exactly on the caret.
    private var placeholderLeading: CGFloat {
        #if os(macOS)
        return 0
        #else
        return 5
        #endif
    }
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
                DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    #if os(macOS)
                    .datePickerStyle(.field)
                    #else
                    .datePickerStyle(.compact)
                    #endif
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            TextEditor(text: $text)
                .font(font)
                .foregroundStyle(Theme.bodyText(colorScheme))
                .lineSpacing(Theme.lineSpacing(for: size))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .focused($bodyFocused)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Begin writing")
                            .font(font)
                            .foregroundStyle(Theme.placeholder(colorScheme))
                            .padding(.leading, placeholderLeading)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
        }
        .frame(maxWidth: 1520)
        .frame(maxWidth: .infinity)
        .navigationTitle("Write")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup {
                fontSizeButton
                Button {
                    saveNow()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasText)
                Button {
                    newEntry()
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
                .disabled(!hasText)
                Menu {
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
        .onAppear { bodyFocused = true }
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

    private var fontSizeButton: some View {
        Button("\(Int(fontSize))px") {
            let sizes = Theme.fontSizes
            if let i = sizes.firstIndex(of: size) {
                fontSize = Double(sizes[(i + 1) % sizes.count])
            } else {
                fontSize = Double(Theme.defaultFontSize)
            }
        }
        .monospacedDigit()
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
