//
//  StatsPanel.swift
//  Wander
//
//  What this entry and this journal amount to, and the few actions that belong
//  to the open entry. One of the two right-hand columns; the other is Options.
//

import SwiftUI
import WanderCore

struct StatsPanel: View {
    @ObservedObject var store: JournalStore
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                thisEntry
                filed
                journal
                actions
                note
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(theme.panel.color)
    }

    @ViewBuilder
    private var thisEntry: some View {
        if theme.statsStyle == .figures {
            VStack(alignment: .leading, spacing: 20) {
                figure("Words", "\(Counts.words(store.draftBody))", theme.ink)
                figure("Days running", "\(store.streak)", theme.accent)
                figure("This month", "\(store.entriesThisMonth)", theme.ink)
                figure("Reading", "\(Counts.readingMinutes(store.draftBody)) min", theme.ink)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "This entry")
                FieldRow("Words", "\(Counts.words(store.draftBody))")
                FieldRow("Characters", "\(Counts.characters(store.draftBody))")
                FieldRow("Paragraphs", "\(Counts.paragraphs(store.draftBody))")
                FieldRow("Reading", "\(Counts.readingMinutes(store.draftBody)) min")
            }
        }
    }

    /// A label over a display numeral — the treatment nearly every one of these
    /// looks used for its counts.
    private func figure(_ label: String, _ value: String, _ tone: Tone) -> some View {
        figureBody(label, value, tone, index: figureIndex(label))
    }

    private func figureIndex(_ label: String) -> Int {
        ["Words", "Days running", "This month", "Reading"].firstIndex(of: label) ?? 0
    }

    @ViewBuilder
    private func figureBody(_ label: String, _ value: String, _ tone: Tone, index: Int) -> some View {
        if theme.figureBlocks {
            // Each figure gets a block of its own colour, the way the loud
            // themes set them.
            let fills: [Tone] = [theme.green, theme.ink, theme.tint, theme.accent]
            let fill = fills[index % fills.count]
            // Read the fill rather than assuming: several themes set accent or
            // green to near-black, which used to print black on black.
            let onFill = fill.readable(theme.paper, theme.ink)
            VStack(alignment: .leading, spacing: 2) {
                SmallCaps(label, tone: onFill.opacity(0.75))
                Text(value)
                    .font(theme.display(34 * min(1.2, theme.displayScale)))
                    .tracking(theme.displayTracking)
                    .foregroundStyle(onFill.color)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill.color)
            .clipShape(RoundedRectangle(cornerRadius: theme.corner, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                SmallCaps(label)
                Text(value)
                    .font(theme.display(34 * min(1.2, theme.displayScale)))
                    .tracking(theme.displayTracking)
                    .foregroundStyle(tone.color)
                    .monospacedDigit()
            }
        }
    }

    private var filed: some View {
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
            FieldRow("Tags", tagSummary,
                     tint: store.selectedEntry?.tags.isEmpty == false ? theme.accent : theme.muted)
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

    @ViewBuilder
    private var journal: some View {
        if theme.statsStyle == .figures {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Journal")
                FieldRow("Entries", "\(store.entries.count)")
                FieldRow("Words", store.totalWords.formatted(.number))
            }
        } else {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Journal")
            FieldRow("Entries", "\(store.entries.count)")
            FieldRow("Words", store.totalWords.formatted(.number))
            FieldRow("This month", "\(store.entriesThisMonth)")
            FieldRow("Streak", "\(store.streak) \(store.streak == 1 ? "day" : "days")",
                     tint: store.streak > 0 ? theme.green : theme.muted)
        }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = store.selectedEntry, store.isUnfiled(entry) {
                AccentBlock(title: "File") { store.toggleFiling(entry) }
            }
            AccentBlock(title: "Copy markdown", filled: !store.selectedIsUnfiled) {
                if let entry = store.selectedEntry { store.copyMarkdown(entry) }
            }
            #if os(macOS)
            AccentBlock(title: "Reveal file", filled: false) {
                if let entry = store.selectedEntry { store.reveal(entry) } else { store.revealFolder() }
            }
            #endif
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rule(tone: theme.rule)
            Marginalia(text: Prompts.today)
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
