//
//  InboxScreen.swift
//  Quire
//
//  The drafts, set like the journal: by month and day, one row each. A row only
//  opens the draft; filing, editing and deleting happen inside it, where they
//  can't be hit by accident while scrolling. Nothing here changes a time.
//

#if os(iOS)

import SwiftUI

struct InboxScreen: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q
    @ObservedObject private var monitor = ExternalDisplayModel.shared

    var open: (EntryRef) -> Void
    var edit: (EntryRef) -> Void
    var retime: (EntryRef) -> Void
    var search: () -> Void
    var settings: () -> Void

    @State private var confirmFileAll = false
    @State private var selected: Int?
    @State private var deleting: Entry?

    private struct Month: Identifiable {
        let id: String   // "2026-09"
        var days: [(date: String, entries: [Entry])]
        var count: Int { days.reduce(0) { $0 + $1.entries.count } }
    }

    /// Drafts grouped by the day in their timestamp, newest first.
    private var months: [Month] {
        let byDay = Dictionary(grouping: store.inboxDrafts, by: \.date)
        var out: [Month] = []
        for date in byDay.keys.sorted(by: >) {
            let entries = (byDay[date] ?? []).sorted { $0.ts > $1.ts }
            let key = String(date.prefix(7))
            if out.last?.id == key { out[out.count - 1].days.append((date, entries)) }
            else { out.append(Month(id: key, days: [(date, entries)])) }
        }
        return out
    }

    var body: some View {
        let months = months
        let flat = months.flatMap { $0.days.flatMap(\.entries) }
        let selectedID = selected.flatMap { flat.indices.contains($0) ? flat[$0].id : nil }
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                QMasthead(onSearch: search, onSettings: settings)
                HStack(alignment: .lastTextBaseline) {
                    QTitle(kicker: kicker, title: "Inbox")
                    Spacer()
                    if let _ = store.inboxDrafts.first {
                        QLink(title: "Random") {
                            if let draft = store.inboxDrafts.randomElement() { openDraft(draft) }
                        }
                    }
                    if store.inboxDrafts.count > 1 {
                        QLink(title: "File all", emphasised: true) { confirmFileAll = true }
                    }
                }
                if store.inboxDrafts.isEmpty {
                    Text(store.indexed
                         ? "Everything is filed. Captures from the widget, the share sheet and the reminder land here first."
                         : "Loading your journal…")
                        .font(q.writing(18)).foregroundStyle(q.mutedColor).lineSpacing(5)
                }
                ForEach(months) { month in
                    VStack(alignment: .leading, spacing: 16) {
                        QLabel(QDate.monthYear(month.id + "-01"), trailing: "\(month.count)")
                            .padding(.bottom, 4).overlay(alignment: .bottom) { QRule() }
                        ForEach(month.days, id: \.date) { day in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(QDate.shortDay(day.date).uppercased()).tracking(1.4)
                                    .font(q.label(11)).foregroundStyle(q.mutedColor)
                                ForEach(day.entries) { entry in
                                    QEntryRow(entry: entry, selected: entry.id == selectedID,
                                              onOpen: { openDraft(entry) })
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 24)
        }
        .onChange(of: selectedID) { _, id in
            if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
        .qKeyList(entries: flat, index: $selected, listTitle: "Inbox", autoSelect: true,
                  onOpen: { openDraft($0) },
                  letter: { entry, key in
                      switch key {
                      case "f": store.fileDraft(entry); return true
                      case "e": edit(EntryRef(entry: entry, source: .inbox)); return true
                      case "*": store.toggleStar(entry, source: .inbox); return true
                      case "t": retime(EntryRef(entry: entry, source: .inbox)); return true
                      case "d": deleting = entry; return true
                      default: return false
                      }
                  })
        .confirmationDialog("Delete this draft?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let d = deleting { store.deleteDraft(d) }; deleting = nil }
        }
        .confirmationDialog("File all \(store.inboxDrafts.count) drafts?", isPresented: $confirmFileAll,
                            titleVisibility: .visible) {
            Button("File all") { _ = store.fileAllDrafts() }
        } message: { Text("Each goes to the day in its own timestamp.") }
        }
    }

    private func openDraft(_ entry: Entry) {
        let ref = EntryRef(entry: entry, source: .inbox)
        if monitor.isConnected { edit(ref) } else { open(ref) }
    }

    private var kicker: String {
        let n = store.inboxDrafts.count
        return n == 0 ? "Nothing waiting" : "\(n) draft\(n == 1 ? "" : "s") waiting"
    }
}

#endif
