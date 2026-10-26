//
//  RetimeSheet.swift
//  Quire
//
//  Change when an entry happened. Tap any time in the app to get here; an
//  entry that moves to another day is filed there.
//

#if os(iOS)

import SwiftUI

struct RetimeSheet: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q
    @Environment(\.dismiss) private var dismiss

    let ref: EntryRef
    var onUpdate: (EntryRef) -> Void = { _ in }
    @State private var error: String?
    @State private var date: Date

    init(ref: EntryRef, onUpdate: @escaping (EntryRef) -> Void = { _ in }) {
        self.onUpdate = onUpdate
        self.ref = ref
        _date = State(initialValue: JournalStore.date(from: ref.entry.ts) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                QLink(title: "Cancel") { dismiss() }
                Spacer()
                QLink(title: "Save", emphasised: true, action: save)
            }
            QTitle(kicker: "Change date and time", title: "When", size: 34)
            Text(ref.entry.qTitle.isEmpty ? "Untitled" : ref.entry.qTitle)
                .font(q.writing(18, italic: true)).foregroundStyle(q.mutedColor).lineLimit(2)
            DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical).labelsHidden().tint(q.accentColor)
            Text("Now \(ref.entry.ts)  →  \(JournalStore.ts(from: date))")
                .font(q.mono(12)).foregroundStyle(q.mutedColor)
            if let error { Text(error).font(q.ui(14)).foregroundStyle(q.accentColor) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26).padding(.top, 16)
        .background(q.pageColor.ignoresSafeArea())
        .preferredColorScheme(q.colorScheme)
        .environment(\.colorScheme, q.colorScheme)
        .presentationDetents([.large])
    }

    private func save() {
        let entry = ref.entry
        let ts = JournalStore.ts(from: date)
        if ts != entry.ts {
            let text = JournalStore.makeEntry(timestamp: ts, title: entry.suffix, body: entry.body).raw
            guard let result = store.saveEditorEntry(entry, source: ref.source, text: text) else {
                error = store.lastWriteError ?? "The date could not be saved. Please try again."
                return
            }
            onUpdate(EntryRef(entry: result.entry, source: result.source))
        }
        dismiss()
    }
}

#endif
