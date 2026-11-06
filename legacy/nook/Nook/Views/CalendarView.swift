//
//  CalendarView.swift
//  Nook
//
//  The sidebar's compact month calendar (plus its month/year picker popover).
//  Days with filed entries are shaded and open that day; grey days hold
//  unfiled drafts and open the Inbox.
//

import SwiftUI

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
    @State private var showingPicker = false

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
    private var starredDays: Set<String> { Set(store.archiveDays.filter(\.hasStarred).map(\.date)) }
    /// Days with unfiled drafts — shaded grey, distinct from filed days.
    private var inboxOnlyDays: Set<String> { store.inboxDays.subtracting(days) }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 2) {
                Button { showingPicker = true } label: {
                    Text(Self.title(month)).font(.caption.weight(.semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    MonthYearPicker(month: $month)
                        .padding()
                        #if os(iOS)
                        .presentationCompactAdaptation(.popover)
                        #endif
                }
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
        let inboxOnly = inboxOnlyDays.contains(key)
        let inMonth = cal.isDate(date, equalTo: month, toGranularity: .month)
        let isToday = cal.isDateInToday(date)
        Button {
            if has { nav.openDay(key) }
            // A grey day only has unfiled drafts — the Inbox is where they live.
            else if inboxOnly { nav.section = .inbox }
        } label: {
            Text("\(cal.component(.day, from: date))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(inMonth ? (has || inboxOnly ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                         : AnyShapeStyle(.quaternary))
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(dayFill(filed: has, inbox: inboxOnly, inMonth: inMonth),
                           in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isToday ? accent : .clear, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if starredDays.contains(key) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(.yellow)
                            .padding(1)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!has && !inboxOnly)
        .accessibilityLabel(a11yLabel(key: key, filed: has, inbox: inboxOnly))
    }

    private func a11yLabel(key: String, filed: Bool, inbox: Bool) -> String {
        if filed { return "Open \(key)" }
        if inbox { return "\(key), unfiled drafts — open Inbox" }
        return key
    }

    /// Accent for days you've filed, grey for days that still have drafts waiting.
    private func dayFill(filed: Bool, inbox: Bool, inMonth: Bool) -> Color {
        let opacity = inMonth ? 0.18 : 0.08
        if filed { return accent.opacity(opacity) }
        if inbox { return Color.secondary.opacity(opacity) }
        return .clear
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

/// Month + year picker shown in a popover when the calendar's title is tapped,
/// so you can spin straight to a month instead of stepping one at a time. Two
/// wheels on iOS (the system date-picker idiom); two pop-up menus on macOS.
struct MonthYearPicker: View {
    @Binding var month: Date
    private let cal = Calendar.current
    private static let years = Array(1970...2100)

    private var monthIndex: Int { cal.component(.month, from: month) }   // 1…12
    private var year: Int { cal.component(.year, from: month) }

    private var monthBinding: Binding<Int> {
        Binding(get: { monthIndex }, set: { set(month: $0, year: year) })
    }
    private var yearBinding: Binding<Int> {
        Binding(get: { year }, set: { set(month: monthIndex, year: $0) })
    }

    var body: some View {
        VStack(spacing: 12) {
            wheels
            // No "Done": the wheels apply as you spin them and the popover
            // closes on a tap outside.
            HStack {
                Button("This Month") { set(startOf: Date()) }
                Spacer()
            }
            .font(.callout)
        }
        #if os(iOS)
        .frame(width: 300)
        #else
        .frame(width: 260)
        #endif
    }

    @ViewBuilder
    private var wheels: some View {
        #if os(iOS)
        HStack(spacing: 0) {
            Picker("Month", selection: monthBinding) {
                ForEach(1...12, id: \.self) { Text(cal.monthSymbols[$0 - 1]).tag($0) }
            }
            .pickerStyle(.wheel)
            Picker("Year", selection: yearBinding) {
                ForEach(Self.years, id: \.self) { Text(String($0)).tag($0) }
            }
            .pickerStyle(.wheel)
        }
        .labelsHidden()
        .frame(height: 170)
        #else
        HStack(spacing: 8) {
            Picker("Month", selection: monthBinding) {
                ForEach(1...12, id: \.self) { Text(cal.monthSymbols[$0 - 1]).tag($0) }
            }
            Picker("Year", selection: yearBinding) {
                ForEach(Self.years, id: \.self) { Text(String($0)).tag($0) }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        #endif
    }

    private func set(month m: Int, year y: Int) {
        var c = DateComponents(); c.year = y; c.month = m; c.day = 1
        if let d = cal.date(from: c) { month = d }
    }
    private func set(startOf date: Date) {
        month = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }
}
