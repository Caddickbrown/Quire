//
//  CalendarView.swift
//  Jibber
//
//  A month calendar for browsing the journal by date. Days that have filed
//  entries are highlighted; tapping one opens that day.
//

import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var store: JournalStore
    @State private var month: Date = CalendarView.startOfMonth(Date())

    private let cal = Calendar.current
    private static let ymd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private var entryDays: [String: Int] {
        Dictionary(uniqueKeysWithValues: store.archiveDays.map { ($0.date, $0.count) })
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            weekdayLabels
            grid
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: 620, alignment: .top)
        .frame(maxWidth: .infinity)
        .navigationTitle("Calendar")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            Button { month = Self.startOfMonth(Date()) } label: {
                Label("Today", systemImage: "calendar.circle")
            }
        }
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            Spacer()
            Text(Self.monthTitle(month)).font(.title3.weight(.semibold))
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
        }
    }

    private var weekdayLabels: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { s in
                Text(s).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                if let date = cell {
                    dayCell(date)
                } else {
                    Color.clear.frame(height: 40)
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let key = Self.ymd.string(from: date)
        let count = entryDays[key]
        let isToday = cal.isDateInToday(date)

        if let count, count > 0 {
            NavigationLink(value: Route.day(key)) {
                cellContent(date, filled: true, isToday: isToday, count: count)
            }
            .buttonStyle(.plain)
        } else {
            cellContent(date, filled: false, isToday: isToday, count: nil)
        }
    }

    private func cellContent(_ date: Date, filled: Bool, isToday: Bool, count: Int?) -> some View {
        VStack(spacing: 2) {
            Text("\(cal.component(.day, from: date))")
                .font(.callout)
                .foregroundStyle(filled ? .primary : .secondary)
            Circle()
                .fill(filled ? Color.accentColor : Color.clear)
                .frame(width: 5, height: 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(filled ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isToday ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }

    // MARK: Date helpers

    private func shift(_ months: Int) {
        if let d = cal.date(byAdding: .month, value: months, to: month) {
            month = Self.startOfMonth(d)
        }
    }

    private var cells: [Date?] {
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let first = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: first) else { return [] }
        let firstWeekday = cal.component(.weekday, from: first)
        let leading = (firstWeekday - cal.firstWeekday + 7) % 7
        var out: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            out.append(cal.date(byAdding: .day, value: day - 1, to: first))
        }
        return out
    }

    private var orderedWeekdaySymbols: [String] {
        let syms = cal.veryShortWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(syms[start...] + syms[..<start])
    }

    private static func startOfMonth(_ d: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    private static func monthTitle(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: d)
    }
}
