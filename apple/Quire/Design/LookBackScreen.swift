//
//  LookBackScreen.swift
//  Quire
//
//  The journal seen from a distance: streaks, totals, what you wrote on this
//  day in earlier years, and the days of the week you write on.
//

#if os(iOS)

import SwiftUI

struct LookBackScreen: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q

    var open: (EntryRef) -> Void
    var search: () -> Void
    var settings: () -> Void

    @State private var selected: Int?

    /// The "on this day" entries, in the order they're drawn: what the keys walk.
    private var pastRefs: [EntryRef] {
        pastYears.flatMap { year in
            year.items.map { EntryRef(entry: $0.item, source: .archive(date: $0.date)) }
        }
    }

    private var pastYears: [OnThisDayYears.Year<Entry>] {
        OnThisDayYears.group(store.qOnThisDay(), thisYear: String(JournalStore.nowDate().prefix(4)))
    }

    var body: some View {
        let stats = store.stats()
        let refs = pastRefs
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                QMasthead(calendarEntries: { store.archiveEntries.flatMap { day in day.entries.map { EntryRef(entry: $0, source: .archive(date: day.date)) } } }, onCalendarOpen: open, onSearch: search, onSettings: settings)
                QTitle(kicker: "\(stats.days) days written", title: "Look back")
                figures(stats)
                onThisDay
                weekdays
                random
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 24)
        }
        .onChange(of: selected) { _, i in
            if let i, refs.indices.contains(i) { withAnimation { proxy.scrollTo(refs[i].entry.id, anchor: .center) } }
        }
        .qKeyList(entries: refs.map(\.entry), index: $selected, listTitle: "On this day", autoSelect: true,
                  onOpen: { entry in if let r = refs.first(where: { $0.entry.id == entry.id }) { open(r) } })
        }
    }

    private func figures(_ s: JournalStore.Stats) -> some View {
        let perDay = s.days > 0 ? s.words / s.days : 0
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                figure(s.currentStreak, "day streak", accent: true, breathe: s.currentStreak > 0)
                figure(s.bestStreak, "longest")
                figure(s.days, "days written")
            }
            HStack(alignment: .top, spacing: 0) {
                figure(s.words, "words", format: Self.short)
                figure(perDay, "words a day")
                figure(s.entries, "entries")
            }
            .padding(.top, 18)
        }
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) { QRule() }
        .qArrive()
    }

    /// A figure that counts up from nothing as the page arrives; the current
    /// streak, when there is one, breathes a few times after.
    private func figure(_ value: Int, _ label: String, accent: Bool = false, breathe: Bool = false,
                        format: @escaping (Int) -> String = { "\($0)" }) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            QCountUp(target: value, format: format)
                .font(q.display(q.isMarathon ? 32 : 38)).foregroundStyle(accent ? q.accentColor : q.inkColor)
                .minimumScaleFactor(0.6).lineLimit(1)
                .qBreathe(breathe)
            Text(q.caps(label)).tracking(q.isMarathon ? 1 : 0).font(q.isMarathon ? q.label(10) : q.ui(12)).foregroundStyle(q.mutedColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private static func short(_ n: Int) -> String {
        n >= 10_000 ? "\(n / 1000)k" : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    @ViewBuilder private var onThisDay: some View {
        let years = pastYears
        let refs = pastRefs
        if !years.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                QLabel("On this day").qArrive()
                ForEach(years) { year in
                    VStack(alignment: .leading, spacing: 8) {
                        QYearHeading(year: year.year, ago: year.ago)
                        ForEach(year.items, id: \.item.id) { dated in
                            let ref = EntryRef(entry: dated.item, source: .archive(date: dated.date))
                            let on = ref.entry.id == selected.flatMap { refs.indices.contains($0) ? refs[$0].entry.id : nil }
                            Button { open(ref) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(dated.item.qTitle.isEmpty ? "Untitled" : dated.item.qTitle)
                                        .font(q.writing(20)).foregroundStyle(q.inkColor)
                                        .multilineTextAlignment(.leading)
                                    if !dated.item.qExcerpt.isEmpty {
                                        Text(dated.item.qExcerpt).font(q.writing(16, italic: true))
                                            .foregroundStyle(q.mutedColor).lineLimit(2).multilineTextAlignment(.leading)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                                .padding(.leading, on ? 10 : 0)
                                .overlay(alignment: .leading) { if on { Rectangle().fill(q.accentColor).frame(width: 3) } }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(dated.item.id)
                            // Old pages dealt onto the desk, one after another.
                            .qFanIn(min(6, refs.firstIndex { $0.entry.id == dated.item.id } ?? 0))
                        }
                    }
                }
            }
        }
    }

    /// Entries by weekday, Monday first.
    private var weekdays: some View {
        var counts = [Int](repeating: 0, count: 7)
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        for day in store.archiveEntries {
            guard let date = QDate.date(day.date) else { continue }
            let w = (cal.component(.weekday, from: date) + 5) % 7   // Mon = 0
            counts[w] += day.entries.count
        }
        let top = max(counts.max() ?? 1, 1)
        let best = counts.firstIndex(of: top) ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            QLabel("When you write", trailing: "entries by weekday").qArrive()
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<7, id: \.self) { i in
                    Rectangle().fill(i == best ? q.accentColor : q.accentColor.opacity(0.35))
                        .frame(height: max(4, 84 * CGFloat(counts[i]) / CGFloat(top)))
                        .qGrowUp(delay: 0.15 + Double(i) * 0.04)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 84, alignment: .bottom)
            .overlay(alignment: .bottom) { Rectangle().fill(q.inkColor).frame(height: 1) }
            HStack(spacing: 10) {
                ForEach(Array("MTWTFSS".enumerated()), id: \.offset) { i, letter in
                    Text(String(letter)).frame(maxWidth: .infinity)
                        .font(q.ui(11, weight: i == best ? .semibold : .regular))
                        .foregroundStyle(i == best ? q.accentColor : q.mutedColor)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Entries by weekday: " + zip(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], counts)
            .map { "\($0) \($1)" }.joined(separator: ", "))
    }

    @ViewBuilder private var random: some View {
        if !store.archiveEntries.isEmpty {
            Button {
                if let r = store.randomEntry() { open(EntryRef(entry: r.entry, source: .archive(date: r.date))) }
            } label: {
                HStack {
                    Text("A random entry").font(q.writing(20)).foregroundStyle(q.inkColor)
                    Text("→").foregroundStyle(q.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                .overlay(alignment: .top) { QRule() }.contentShape(Rectangle())
                .qArrive()
            }
            .buttonStyle(.plain)
        }
    }
}

#endif
