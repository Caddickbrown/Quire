//
//  CalendarView.swift
//  Nook
//
//  A month calendar for browsing the journal by date. Days that have filed
//  entries are highlighted; tapping one opens that day.
//

import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.accent) private var accent
    @State private var month: Date = CalendarView.startOfMonth(Date())

    private let cal = Calendar.current
    private static let ymd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private var daysByDate: [String: JournalStore.ArchiveDay] {
        Dictionary(uniqueKeysWithValues: store.archiveDays.map { ($0.date, $0) })
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
        let day = daysByDate[key]
        let isToday = cal.isDateInToday(date)

        if let day {
            NavigationLink(value: Route.day(key)) {
                cellContent(date, day: day, isToday: isToday)
            }
            .buttonStyle(.plain)
        } else {
            cellContent(date, day: nil, isToday: isToday)
        }
    }

    private func cellContent(_ date: Date, day: JournalStore.ArchiveDay?, isToday: Bool) -> some View {
        let filled = day != nil
        return VStack(spacing: 3) {
            Text("\(cal.component(.day, from: date))")
                .font(.callout)
                .foregroundStyle(filled ? .primary : .secondary)
            HStack(spacing: 3) {
                if let day {
                    if day.hasPhoto { dot(.blue) }
                    if day.hasVideo { dot(.purple) }
                    if day.hasAudio { dot(.green) }
                    if !day.hasPhoto && !day.hasVideo && !day.hasAudio { dot(accent) }
                } else {
                    Circle().fill(.clear).frame(width: 5, height: 5)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(filled ? accent.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isToday ? accent : Color.clear, lineWidth: 1.5)
        )
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 5, height: 5)
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

/// A compact month calendar for the sidebar. Fixed 6-week height so the layout
/// never shifts; weekday header, swipe to change month, optional week numbers,
/// configurable first day of week. Tapping a day opens it.
struct MiniCalendarView: View {
    @EnvironmentObject private var store: JournalStore
    @EnvironmentObject private var nav: NavigationModel
    @Environment(\.accent) private var accent
    @AppStorage("firstWeekday") private var firstWeekday = 1        // 1=Sun … 7=Sat
    @AppStorage("showWeekNumbers") private var showWeekNumbers = false
    @State private var month = MiniCalendarView.startOfMonth(Date())

    private static let ymd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private var cal: Calendar {
        var c = Calendar.current
        c.firstWeekday = min(max(firstWeekday, 1), 7)
        return c
    }
    private var days: Set<String> { Set(store.archiveDays.map(\.date)) }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 2) {
                Text(Self.title(month)).font(.caption.weight(.semibold))
                Spacer()
                calButton("chevron.left") { shift(-1) }
                calButton("smallcircle.filled.circle") { month = Self.startOfMonth(Date()) }
                    .help("Today")
                calButton("chevron.right") { shift(1) }
            }
            weekdayHeader
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 2) {
                    if showWeekNumbers {
                        weekNumber(row)
                        Divider().frame(height: 18)
                    }
                    ForEach(0..<7, id: \.self) { col in
                        dayCell(grid[row * 7 + col])
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 24).onEnded { v in
            if v.translation.width > 40 { shift(-1) }
            else if v.translation.width < -40 { shift(1) }
        })
    }

    private var weekdayHeader: some View {
        HStack(spacing: 2) {
            if showWeekNumbers {
                Text("").frame(width: 18)
                Divider().frame(height: 12)
            }
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                Text(s).font(.system(size: 9)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func weekNumber(_ row: Int) -> some View {
        Text("\(cal.component(.weekOfYear, from: grid[row * 7]))")
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 18)
    }

    @ViewBuilder
    private func dayCell(_ date: Date) -> some View {
        let key = Self.ymd.string(from: date)
        let has = days.contains(key)
        let inMonth = cal.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = cal.isDateInToday(date)
        Button {
            if has { nav.openDay(key) }
        } label: {
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(inMonth ? (has ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                         : AnyShapeStyle(.quaternary))
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(has ? accent.opacity(inMonth ? 0.18 : 0.08) : Color.clear,
                           in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isToday ? accent : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!has)
    }

    private func calButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shift(_ m: Int) {
        if let d = cal.date(byAdding: .month, value: m, to: month) {
            withAnimation(.easeInOut(duration: 0.15)) { month = Self.startOfMonth(d) }
        }
    }

    private var weekdaySymbols: [String] {
        let syms = cal.veryShortWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(syms[start...] + syms[..<start])
    }

    /// 42 consecutive dates (6 weeks) filling the grid, including adjacent months.
    private var grid: [Date] {
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let first = cal.date(from: comps) else { return [] }
        let leading = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -leading, to: first) else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private static func startOfMonth(_ d: Date) -> Date {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }
    private static func title(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f.string(from: d)
    }
}
