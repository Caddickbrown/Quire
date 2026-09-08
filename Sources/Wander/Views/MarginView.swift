//
//  MarginView.swift
//  Wander
//
//  The right-hand column: what this session amounts to, what the journal
//  amounts to, the few settings worth reaching for, and a note in the margin.
//

import SwiftUI

struct MarginView: View {
    @ObservedObject var store: JournalStore
    @Binding var typeSize: Double
    @Binding var focusMode: Bool
    @Binding var typewriter: Bool
    @Binding var appearance: Appearance
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                session
                entry
                journal
                settings
                actions
                note
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(theme.panel.color)
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "This entry")
            FieldRow("Words", "\(Counts.words(store.draftBody))")
            FieldRow("Characters", "\(Counts.characters(store.draftBody))")
            FieldRow("Paragraphs", "\(Counts.paragraphs(store.draftBody))")
            FieldRow("Reading", "\(Counts.readingMinutes(store.draftBody)) min")
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Filed")
            FieldRow("Number", store.selectedNumber.map { "No. \(Formats.groupNumber($0))" } ?? "—")
            FieldRow(label: "Written") {
                if let entry = store.selectedEntry, let date = entry.createdDate {
                    ValueButton(text: Formats.shortDay.string(from: date)
                                + " · " + Formats.clock.string(from: date)) {
                        store.reschedulingEntry = entry
                    }
                } else {
                    FieldValue(text: "—")
                }
            }
            FieldRow("Tags", tagSummary, tint: store.selectedEntry?.tags.isEmpty == false
                     ? theme.accent : theme.muted)
            FieldRow(label: "Status") {
                if let entry = store.selectedEntry {
                    ValueButton(text: store.isUnfiled(entry) ? "In the inbox" : "Filed") {
                        store.toggleFiling(entry)
                    }
                    .help(store.isUnfiled(entry)
                          ? "File this draft into journal/\(entry.date)"
                          : "Return this entry to inbox.md")
                } else {
                    FieldValue(text: "—")
                }
            }
            FieldRow("File", store.selectedEntry?.source?.lastPathComponent ?? "unsaved")
        }
    }

    private var journal: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Journal")
            FieldRow("Entries", "\(store.entries.count)")
            FieldRow("Words", store.totalWords.formatted(.number))
            FieldRow("This month", "\(store.entriesThisMonth)")
            FieldRow("Streak", "\(store.streak) \(store.streak == 1 ? "day" : "days")",
                     tint: store.streak > 0 ? theme.green : theme.muted)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Setting")
            SettingsRows(typeSize: $typeSize,
                         focusMode: $focusMode,
                         typewriter: $typewriter,
                         appearance: $appearance)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = store.selectedEntry, store.isUnfiled(entry) {
                AccentBlock(title: "File") { store.toggleFiling(entry) }
            }
            AccentBlock(title: "Copy markdown", filled: store.selectedIsUnfiled ? false : true) {
                if let entry = store.selectedEntry { store.copyMarkdown(entry) }
            }
            AccentBlock(title: "Reveal file", filled: false) {
                if let entry = store.selectedEntry { store.reveal(entry) } else { store.revealFolder() }
            }
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rule(tone: theme.rule)
            Marginalia(text: Prompts.today)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SmallCaps("Folder")
                Spacer()
                QuietButton(title: "Change") { store.chooseFolder() }
            }
            Text(store.baseURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Face.sans(10.5))
                .foregroundStyle(theme.muted.opacity(0.85).color)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var tagSummary: String {
        let tags = store.selectedEntry?.tags ?? []
        guard !tags.isEmpty else { return "—" }
        return tags.prefix(3).joined(separator: " ")
    }
}

/// A different line each day, in the voice of an editor's note rather than a
/// prompt card. Deterministic on the date so it doesn't shuffle mid-session.
enum Prompts {
    static let all = [
        "Write the sentence you would rather not. It is usually the one carrying the entry.",
        "Detail before conclusion: what was on the table, what the light was doing, who spoke first.",
        "A journal is not a defence. Nobody is going to cross-examine the draft.",
        "If the day resists summary, put down three things in the order they happened and stop.",
        "The dull entries are the ones worth having in five years. Keep them.",
        "Name the thing you are avoiding, then leave it. Naming is enough for today.",
        "Write it as you would tell it to one person, and not as you would post it.",
        "What changed today that you would not have predicted on Monday?",
        "End mid-thought if you must. Tomorrow's entry can pick up the sentence.",
        "Tag it @later and let the future reader do the sorting.",
        "One page is a good day's work. Half a page still counts.",
        "Describe the room. The feeling tends to follow the furniture."
    ]

    static var today: String {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return all[day % all.count]
    }
}
