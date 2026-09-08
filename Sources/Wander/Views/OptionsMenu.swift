//
//  OptionsMenu.swift
//  Wander
//
//  The same settings rows in two places: down the margin when that column is
//  open, and in a masthead popover when it isn't — so nothing becomes
//  unreachable by closing a column.
//

import SwiftUI

/// Type size, focus, typewriter, paper. Ruled rows, like everything else.
struct SettingsRows: View {
    @Binding var typeSize: Double
    @Binding var focusMode: Bool
    @Binding var typewriter: Bool
    @Binding var appearance: Appearance
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FieldRow(label: "Type") {
                HStack(spacing: 10) {
                    QuietButton(title: "\u{2212}") { typeSize = max(13, typeSize - 0.5) }
                    FieldValue(text: String(format: "%.1f", typeSize))
                    QuietButton(title: "+") { typeSize = min(28, typeSize + 0.5) }
                }
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
}

/// Masthead popover: the settings, the two columns, and where the journal lives.
struct OptionsPopover: View {
    @ObservedObject var store: JournalStore
    @Binding var typeSize: Double
    @Binding var focusMode: Bool
    @Binding var typewriter: Bool
    @Binding var appearance: Appearance
    @Binding var showIndex: Bool
    @Binding var showMargin: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Setting")
                SettingsRows(typeSize: $typeSize,
                             focusMode: $focusMode,
                             typewriter: $typewriter,
                             appearance: $appearance)
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Columns")
                FieldRow(label: "Index") {
                    QuietButton(title: showIndex ? "Open" : "Closed",
                                tone: showIndex ? theme.accent : nil) {
                        withAnimation(.easeOut(duration: 0.16)) { showIndex.toggle() }
                    }
                }
                FieldRow(label: "Margin") {
                    QuietButton(title: showMargin ? "Open" : "Closed",
                                tone: showMargin ? theme.accent : nil) {
                        withAnimation(.easeOut(duration: 0.16)) { showMargin.toggle() }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Journal")
                FieldRow("Entries", "\(store.entries.count)")
                FieldRow("Words", store.totalWords.formatted(.number))
                FieldRow(label: "Folder") {
                    HStack(spacing: 12) {
                        QuietButton(title: "Reveal") { store.revealFolder() }
                        QuietButton(title: "Change") { store.chooseFolder() }
                    }
                }
                Text(store.baseURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(Face.sans(10.5))
                    .foregroundStyle(theme.muted.opacity(0.85).color)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(width: 280)
        .background(theme.panel.color)
    }
}
