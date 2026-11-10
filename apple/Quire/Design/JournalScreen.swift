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
    /// A day to go to (⌘K, Jump to a date): taken and cleared.
    @Binding var jump: String?

    /// The filter, the journal chosen and the selection are the root's, so they
    /// outlast a rotation or a resized window, which builds this page afresh.
    @Binding var starredOnly: Bool
    /// A split journal being read in place of the main one, picked from the
    /// title (Dan, 9 Nov: they had no way in on the phone or iPad).
    @Binding var splitName: String?
    @Binding var selected: Int?
    @State private var deleting: Entry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The months and the flat list, kept until the journal or the filter
    /// changes. The store announces every autosave (a draft's words, the
    /// inbox), and this list redraws for each, under the composer too: regrouping
    /// every filed entry each time was the stall after each pause in typing,
    /// worst on an iPad, where the list stays on screen beside the sidebar.
    @State private var grouped = Grouped()

    /// See `grouped`. Every change to `archiveEntries` comes with a new
    /// `revision` (or, when the folder goes, a new count).
    private final class Grouped {
        private var key: (Int, Int, Bool, String)?
        private var months: [Month] = []
        private var flat: [Entry] = []
        func lists(for key: (Int, Int, Bool, String), build: () -> ([Month], [Entry])) -> ([Month], [Entry]) {
            if let k = self.key, k == key { return (months, flat) }
            (months, flat) = build()
            self.key = key
            return (months, flat)
        }
    }

    private struct Month: Identifiable {
        let id: String   // "2026-09"
        var days: [(date: String, entries: [Entry])]
        var count: Int { days.reduce(0) { $0 + $1.entries.count } }
    }

    /// Where an entry in this list lives: the main journal, or the split one.
    private func source(_ entry: Entry) -> EntrySource {
        if let splitName { return .journal(name: splitName) }
        return .archive(date: entry.date)
    }

    /// The chosen split journal's entries as days, newest day first.
    private func splitDays(_ name: String) -> [(date: String, entries: [Entry])] {
        let entries = store.splitEntriesCache[name] ?? []
        return Dictionary(grouping: entries, by: \.date)
            .map { (date: $0.key, entries: $0.value.sorted { $0.ts < $1.ts }) }
            .sorted { $0.date > $1.date }
    }

    /// Days, newest first, narrowed by the star filter.
    private var days: [(date: String, entries: [Entry])] {
        var days = splitName.map(splitDays) ?? store.archiveEntries
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
        let (months, flat) = grouped.lists(for: (store.revision, store.archiveEntries.count, starredOnly, splitName ?? "")) {
            let months = self.months
            return (months, months.flatMap { $0.days.flatMap { $0.entries.reversed() } })
        }
        let selectedID = selected.flatMap { flat.indices.contains($0) ? flat[$0].id : nil }
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                QMasthead(onRandom: store.archiveEntries.isEmpty ? nil : {
                              if let r = store.randomEntry() { open(EntryRef(entry: r.entry, source: .archive(date: r.date))) }
                          },
                          onMedia: media, onSearch: search, onSettings: settings)
                // The count from the months already grouped: counting the days again
                // regrouped a split journal on every autosave.
                title(count: months.reduce(0) { $0 + $1.count })
                filters
                if months.isEmpty {
                    Text(!store.indexed ? (store.foldingLegacy ? "Moving your journal into day files…" : "Loading your journal…")
                         : starredOnly ? "Nothing matches."
                         : splitName != nil ? "Nothing in this journal yet."
                         : "Nothing is filed yet. File a draft from the inbox and it lands here.")
                        .font(q.writing(18)).foregroundStyle(q.mutedColor)
                }
                ForEach(months) { month in
                    VStack(alignment: .leading, spacing: 16) {
                        QLabel(QDate.monthYear(month.id + "-01"), trailing: "\(month.count)")
                            .padding(.bottom, 4).overlay(alignment: .bottom) { QRule() }
                        ForEach(month.days, id: \.date) { day in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(QDate.fullDay(day.date).uppercased()).tracking(1.4)
                                    .font(q.label(11)).foregroundStyle(q.mutedColor)
                                ForEach(day.entries.reversed()) { entry in
                                    let ref = EntryRef(entry: entry, source: source(entry))
                                    QEntryRow(entry: entry, selected: entry.id == selectedID, onOpen: { open(ref) },
                                              onDelete: { delete(entry) })
                                }
                            }
                        }
                    }
                    .id(month.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 24)
        }
        .onChange(of: selectedID) { _, id in
            if let id { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(id, anchor: .center) } }
        }
        // A split journal that is gone (its tag removed, merged back, another
        // folder chosen) leaves nothing to read: back to the main journal.
        .onChange(of: store.splitJournals) { _, _ in dropMissingSplit() }
        .onAppear(perform: dropMissingSplit)
        // `task`, not `onChange`: the list may only be appearing as the day arrives,
        // and a list that appears drops its selection first.
        .task(id: jump) {
            guard let day = jump else { return }
            // Cleared last: clearing it changes the id, which cancels this.
            defer { jump = nil }
            starredOnly = false
            splitName = nil
            await Task.yield()
            let all = self.months.flatMap { $0.days.flatMap { $0.entries.reversed() } }
            guard let i = all.firstIndex(where: { $0.date == day }) else { return }
            selected = i
            // A far row isn't built yet: the month brings it in, then the row is found.
            proxy.scrollTo(String(day.prefix(7)), anchor: .top)
            try? await Task.sleep(for: .milliseconds(120))
            proxy.scrollTo(all[i].id, anchor: .center)
        }
        .qKeyList(entries: flat, index: $selected, listTitle: "Journal", autoSelect: true,
                  onOpen: { open(EntryRef(entry: $0, source: source($0))) },
                  letter: { entry, key in
                      let source = source(entry)
                      switch key {
                      case "e": edit(EntryRef(entry: entry, source: source)); return true
                      case "*": store.toggleStar(entry, source: source); return true
                      case "u": _ = store.returnToInbox(entry, source: source); return true
                      case "t": retime(EntryRef(entry: entry, source: source)); return true
                      case "d": askDelete(entry); return true
                      default: return false
                      }
                  })
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deleting { delete(d) }
                deleting = nil
            }
        }
        .qKeyBlocker(active: deleting != nil, onEscape: { deleting = nil })
        }
    }

    /// The title, which picks the journal when there are split ones.
    @ViewBuilder private func title(count: Int) -> some View {
        let heading = QTitle(kicker: "\(count) filed", title: splitName ?? "Journal")
        if store.splitJournals.isEmpty && splitName == nil {
            heading
        } else {
            Menu {
                Picker("Journal", selection: $splitName) {
                    Text("Journal").tag(String?.none)
                    ForEach(store.splitJournals) { journal in
                        Text("\(journal.name) · \(journal.count)").tag(String?.some(journal.name))
                    }
                }
            } label: {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    heading
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(q.mutedColor)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Choose a journal")
            .onChange(of: splitName) { _, _ in selected = nil }
        }
    }

    private func dropMissingSplit() {
        guard store.indexed, let name = splitName,
              !store.splitJournals.contains(where: { $0.name == name }),
              store.splitEntriesCache[name] == nil else { return }
        splitName = nil
        selected = nil
    }

    @discardableResult
    private func delete(_ entry: Entry) -> Bool {
        if let splitName { return store.deleteJournalEntry(name: splitName, entry: entry) }
        return store.deleteFiledEntry(date: entry.date, entry: entry)
    }

    /// On the monitor in desk mode, where the keyboard can answer; the phone's
    /// dialog otherwise. The list keeps its place, so the selection lands on the
    /// next entry (or the one before, if this was the last).
    private func askDelete(_ entry: Entry) {
        let asked = DeskConfirm.shared.ask(.init(kicker: "Journal", question: "Delete this entry?",
                                                 detail: DeskConfirm.describe(entry), when: DeskConfirm.when(entry),
                                                 action: "Delete")) {
            delete(entry) ? nil : (store.lastWriteError ?? "The entry could not be deleted.")
        }
        if !asked { deleting = entry }
    }

    private var filters: some View {
        HStack(spacing: 18) {
            filterLink("All", on: !starredOnly) { starredOnly = false }
            filterLink("Starred", on: starredOnly) { starredOnly.toggle() }
            Spacer()
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
