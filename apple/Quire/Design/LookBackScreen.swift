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

    var body: some View {
        let stats = store.stats()
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                QMasthead(onSearch: search, onSettings: settings)
                QTitle(kicker: "\(stats.days) days written", title: "Look back")
                figures(stats)
                onThisDay
                weekdays
                random
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 24)
        }
    }

    private func figures(_ s: JournalStore.Stats) -> some View {
        let perDay = s.days > 0 ? s.words / s.days : 0
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                figure("\(s.currentStreak)", "day streak", accent: true)
                figure("\(s.bestStreak)", "longest")
                figure("\(s.days)", "days written")
            }
            HStack(alignment: .top, spacing: 0) {
                figure(Self.short(s.words), "words")
                figure("\(perDay)", "words a day")
                figure("\(s.entries)", "entries")
            }
            .padding(.top, 18)
        }
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) { QRule() }
    }

    private func figure(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(q.display(q.isMarathon ? 32 : 38)).foregroundStyle(accent ? q.accentColor : q.inkColor)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(q.caps(label)).tracking(q.isMarathon ? 1 : 0).font(q.isMarathon ? q.label(10) : q.ui(12)).foregroundStyle(q.mutedColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private static func short(_ n: Int) -> String {
        n >= 10_000 ? "\(n / 1000)k" : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    @ViewBuilder private var onThisDay: some View {
        let past = store.qOnThisDay()
        if !past.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                QLabel("On this day")
                ForEach(past, id: \.date) { day in
                    ForEach(day.entries.prefix(2)) { entry in
                        let ref = EntryRef(entry: entry, source: .archive(date: day.date))
                        Button { open(ref) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(day.date.prefix(4))).font(q.mono(12)).foregroundStyle(q.accentColor)
                                Text(entry.qTitle.isEmpty ? "Untitled" : entry.qTitle)
                                    .font(q.writing(20)).foregroundStyle(q.inkColor)
                                    .multilineTextAlignment(.leading)
                                if !entry.qExcerpt.isEmpty {
                                    Text(entry.qExcerpt).font(q.writing(16, italic: true))
                                        .foregroundStyle(q.mutedColor).lineLimit(2).multilineTextAlignment(.leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
            QLabel("When you write", trailing: "entries by weekday")
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0..<7, id: \.self) { i in
                    Rectangle().fill(i == best ? q.accentColor : q.accentColor.opacity(0.35))
                        .frame(height: max(4, 84 * CGFloat(counts[i]) / CGFloat(top)))
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
            }
            .buttonStyle(.plain)
        }
    }
}

#endif
