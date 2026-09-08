//
//  OptionsPanel.swift
//  Wander
//
//  The settings column: how the page is set, which columns are open, and where
//  the journal lives. The other right-hand column is Stats.
//

import SwiftUI
import WanderCore
import UniformTypeIdentifiers

struct OptionsPanel: View {
    @ObservedObject var store: JournalStore
    @Binding var typeSize: Double
    @Binding var leading: Double
    @Binding var focusMode: Bool
    @Binding var typewriter: Bool
    @Binding var appearance: Appearance
    @Binding var showIndex: Bool
    @Binding var showStats: Bool
    @Binding var showOptions: Bool
    @Binding var themeID: String
    @Binding var showingThemes: Bool
    @Environment(\.theme) private var theme
    @State private var choosingFolder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                setting
                columns
                folder
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(theme.panel.color)
        // iOS has no open panel; a folder comes from the document picker, and
        // arrives security-scoped — `adopt` opens the grant and bookmarks it.
        .fileImporter(isPresented: $choosingFolder,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.adopt(url)
            }
        }
    }

    private var setting: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Setting")
            FieldRow(label: "Theme") {
                ValueButton(text: Theme.named(themeID).name) { showingThemes = true }
            }
            FieldRow(label: "Type") {
                Stepper(value: String(format: "%.1f", typeSize),
                        down: { typeSize = max(13, typeSize - 0.5) },
                        up: { typeSize = min(28, typeSize + 0.5) })
            }
            // Leading is quoted the way a typesetter would: a multiple of the
            // type size, not a point value that means nothing on its own.
            FieldRow(label: "Leading") {
                Stepper(value: String(format: "%.2f", 1 + leading),
                        down: { leading = max(0.10, leading - 0.06) },
                        up: { leading = min(1.20, leading + 0.06) })
            }
            FieldRow(label: "Focus") {
                QuietButton(title: focusMode ? "On" : "Off",
                            tone: focusMode ? theme.accent : nil) { focusMode.toggle() }
            }
            FieldRow(label: "Typewriter") {
                QuietButton(title: typewriter ? "On" : "Off",
                            tone: typewriter ? theme.accent : nil) { typewriter.toggle() }
            }
            FieldRow(label: "Paper") {
                QuietButton(title: appearance.label) { appearance = appearance.next }
            }
        }
    }

    private var columns: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Columns")
            FieldRow(label: "Index") { toggle($showIndex) }
            FieldRow(label: "Stats") { toggle($showStats) }
            FieldRow(label: "Options") { toggle($showOptions) }
        }
    }

    private func toggle(_ binding: Binding<Bool>) -> some View {
        QuietButton(title: binding.wrappedValue ? "Open" : "Closed",
                    tone: binding.wrappedValue ? theme.accent : nil) {
            withAnimation(Motion.column) { binding.wrappedValue.toggle() }
        }
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Journal")
            FieldRow("Entries", "\(store.entries.count)")
            FieldRow(label: "Folder") {
                HStack(spacing: 12) {
                    #if os(macOS)
                    QuietButton(title: "Reveal") { store.revealFolder() }
                    QuietButton(title: "Change") { store.chooseFolder() }
                    #else
                    QuietButton(title: "Change") { choosingFolder = true }
                    #endif
                }
            }
            Text(store.baseURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(theme.ui(10.5))
                .foregroundStyle(theme.muted.opacity(0.85).color)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.top, 8)
        }
    }
}

/// − value + on one ruled row.
struct Stepper: View {
    let value: String
    let down: () -> Void
    let up: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            QuietButton(title: "\u{2212}", action: down)
            FieldValue(text: value)
            QuietButton(title: "+", action: up)
        }
    }
}
