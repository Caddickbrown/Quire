//
//  RescheduleSheet.swift
//  Wander
//
//  Changing an entry's date and time. The timestamp is both the entry's
//  identity and its filename, so this moves the entry between day files —
//  the sheet says so plainly before it does it.
//

import SwiftUI
import WanderCore

struct RescheduleSheet: View {
    let entry: Entry
    @ObservedObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var moment: Date

    init(entry: Entry, store: JournalStore) {
        self.entry = entry
        self.store = store
        _moment = State(initialValue: entry.createdDate ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Date & time")
                    .font(theme.display(22))
                    .foregroundStyle(theme.ink.color)
                Spacer()
                SmallCaps(entry.preview.isEmpty ? "Untitled" : entry.preview)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            .padding(.bottom, 10)

            Rule(weight: 2, tone: theme.ink)

            CalendarPicker(moment: $moment, marked: store.datesWithEntries)
                .padding(.top, 14)
                .padding(.bottom, 12)

            FieldRow(label: "Time") { TimeField(moment: $moment) }

            FieldRow(store.isUnfiled(entry) ? "Stays in" : "Moves to",
                     store.destinationName(for: entry, at: moment))

            Marginalia(text: store.isUnfiled(entry)
                       ? "This one is still in the inbox, which isn't dated — retiming it "
                         + "rewrites it in place rather than filing it under a day."
                       : "The date is the filename. Changing it rewrites both day files, so "
                         + "jnl and Nook see the entry under its new date.")
                .padding(.top, 14)

            HStack(spacing: 10) {
                AccentBlock(title: "Keep", filled: false) { dismiss() }
                AccentBlock(title: "Move entry") {
                    store.reschedule(entry, to: moment)
                    dismiss()
                }
            }
            .padding(.top, 18)
        }
        .padding(24)
        .frame(width: 380)
        .background(theme.paper.color)
    }
}
