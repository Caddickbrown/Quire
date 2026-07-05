//
//  WritingView.swift
//  Jibber
//
//  The distraction-free composer (freewrite's heart). You write, then send the
//  text to the inbox as a new draft. Font size cycles like freewrite; the
//  macOS-only key monitors (backspace-lock, scroll-to-set-timer) are intentionally
//  left out of this foundation pass.
//

import SwiftUI

struct WritingView: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var text = ""
    @AppStorage("fontSize") private var fontSize: Double = Double(Theme.defaultFontSize)
    @State private var placeholder = Theme.placeholderPrompts.first ?? "Begin writing"
    @State private var justSaved = false
    @FocusState private var editorFocused: Bool

    private var size: CGFloat { CGFloat(fontSize) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.custom(Theme.writingFont, size: size))
                .foregroundStyle(Theme.bodyText(colorScheme))
                .lineSpacing(Theme.lineSpacing(for: size))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .focused($editorFocused)

            if text.isEmpty {
                // Align the placeholder's left edge with the caret (the editor's
                // text region starts at its own 8pt inset).
                Text(placeholder)
                    .font(.custom(Theme.writingFont, size: size))
                    .foregroundStyle(Theme.placeholder(colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .padding()
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .navigationTitle("Write")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup {
                fontSizeButton
                Button {
                    saveDraft()
                } label: {
                    Label("Save to Inbox", systemImage: "tray.and.arrow.down")
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            placeholder = Theme.placeholderPrompts.randomElement() ?? placeholder
            editorFocused = true
        }
        .overlay(alignment: .bottom) {
            if justSaved {
                Text("Saved to inbox")
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

    private func saveDraft() {
        store.addDraft(title: "", body: text)
        text = ""
        placeholder = Theme.placeholderPrompts.randomElement() ?? placeholder
        editorFocused = true
        withAnimation { justSaved = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { justSaved = false }
        }
    }
}
