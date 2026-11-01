//
//  JournalScreen.swift
//  Quire
//
//  Everything that has been filed, by month and day. Starred narrows the list;
//  tags are browsed from Search, where each one is a query.
//

#if os(iOS)

import SwiftUI

struct JournalScreen: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q

    var open: (EntryRef) -> Void
    var edit: (EntryRef) -> Void
    var retime: (EntryRef) -> Void
    var search: () -> Void
    var settings: () -> Void
    var media: () -> Void

    @State private var starredOnly = false
    @State private var selected: Int?
    @State private var deleting: Entry?

    private struct Month: Identifiable {
        let id: String   // "2026-09"
        var days: [(date: String, entries: [Entry])]
        var count: Int { days.reduce(0) { $0 + $1.entries.count } }
    }

    /// Days, newest first, narrowed by the star filter.
    private var days: [(date: String, entries: [Entry])] {
        var days = store.archiveEntries
        if starredOnly {
            days = days.compactMap { day in
                let kept = day.entries.filter(\.isStarred)
                return kept.isEmpty ? nil : (day.date, kept)
            }
        }
        return days
    }

    private var months: [Month] {
        var out: [Month] = []
        for day in days {
            let key = String(day.date.prefix(7))
            if out.last?.id == key { out[out.count - 1].days.append(day) }
            else { out.append(Month(id: key, days: [day])) }
        }
        return out
    }

    var body: some View {
        let months = months
        let flat = months.flatMap { $0.days.flatMap { $0.entries.reversed() } }
        let selectedID = selected.flatMap { flat.indices.contains($0) ? flat[$0].id : nil }
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                QMasthead(onMedia: media, onSearch: search, onSettings: settings)
                QTitle(kicker: "\(store.archiveEntries.reduce(0) { $0 + $1.entries.count }) filed", title: "Journal")
                filters
                if months.isEmpty {
                    Text(!store.indexed ? "Loading your journal…"
                         : starredOnly ? "Nothing matches."
                         : "Nothing is filed yet. File a draft from the inbox and it lands here.")
                        .font(q.writing(18)).foregroundStyle(q.mutedColor)
                }
                ForEach(months) { month in
                    VStack(alignment: .leading, spacing: 16) {
                        QLabel(QDate.monthYear(month.id + "-01"), trailing: "\(month.count)")
                            .padding(.bottom, 4).overlay(alignment: .bottom) { QRule() }
                        ForEach(month.days, id: \.date) { day in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(QDate.shortDay(day.date).uppercased()).tracking(1.4)
                                    .font(q.label(11)).foregroundStyle(q.mutedColor)
                                ForEach(day.entries.reversed()) { entry in
                                    let ref = EntryRef(entry: entry, source: .archive(date: day.date))
                                    QEntryRow(entry: entry, selected: entry.id == selectedID, onOpen: { open(ref) },
                                              onDelete: { deleting = entry })
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
        .qKeyList(entries: flat, index: $selected, listTitle: "Journal", autoSelect: true,
                  onOpen: { open(EntryRef(entry: $0, source: .archive(date: $0.date))) },
                  letter: { entry, key in
                      let source = EntrySource.archive(date: entry.date)
                      switch key {
                      case "e": edit(EntryRef(entry: entry, source: source)); return true
                      case "*": store.toggleStar(entry, source: source); return true
                      case "u": _ = store.returnToInbox(entry, source: source); return true
                      case "t": retime(EntryRef(entry: entry, source: source)); return true
                      case "d": deleting = entry; return true
                      default: return false
                      }
                  })
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deleting { _ = store.deleteFiledEntry(date: d.date, entry: d) }
                deleting = nil
            }
        }
        }
    }

    private var filters: some View {
        HStack(spacing: 18) {
            filterLink("All", on: !starredOnly) { starredOnly = false }
            filterLink("Starred", on: starredOnly) { starredOnly.toggle() }
            Spacer()
            filterLink("Random", on: false) {
                if let r = store.randomEntry() { open(EntryRef(entry: r.entry, source: .archive(date: r.date))) }
            }
        }
    }

    private func filterLink(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(q.caps(title))
                .tracking(q.isMarathon ? 1.2 : 0)
                .font(q.isMarathon ? q.label(12, weight: on ? .medium : .regular) : q.ui(14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? q.accentColor : q.inkColor)
                .underline(on, color: q.accentColor)
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif
