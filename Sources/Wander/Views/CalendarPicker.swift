//
//  CalendarPicker.swift
//  Wander
//
//  A month grid drawn in the app's own vocabulary rather than the system's:
//  small-caps weekday heads over a hairline, tabular numerals, one solid accent
//  block for the chosen day, and a dot under every day that already has an
//  entry — the almanac page, not a control.
//

import SwiftUI
import WanderCore

struct CalendarPicker: View {
    @Binding var moment: Date
    /// "YYYY-MM-DD" days that already hold entries.
    let marked: Set<String>
    @Environment(\.theme) private var theme
    @State private var visibleMonth: Date

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    init(moment: Binding<Date>, marked: Set<String>) {
        _moment = moment
        self.marked = marked
        _visibleMonth = State(initialValue: moment.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            weekdays
            Rule(tone: theme.ink)
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(gridDays, id: \.self) { day in
                    DayCell(day: day,
                            inMonth: calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month),
                            selected: calendar.isDate(day, inSameDayAs: moment),
                            today: calendar.isDateInToday(day),
                            marked: marked.contains(Formats.day.string(from: day))) {
                        select(day)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Formats.month.string(from: visibleMonth))
                .font(Face.serif(17))
                .foregroundStyle(theme.ink.color)
            Spacer()
            QuietButton(title: "Today") { jump(to: Date()) }
            QuietButton(title: "\u{2039}") { shiftMonth(-1) }
            QuietButton(title: "\u{203A}") { shiftMonth(1) }
        }
        .padding(.bottom, 10)
    }

    private var weekdays: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            // Keyed by position, not by the symbol: "S" and "T" each appear
            // twice in a week, and identical ids collapse the duplicates.
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                SmallCaps(symbol)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 6)
    }

    /// Mo Tu We Th Fr Sa Su, rotated to the locale's first weekday. Two letters
    /// rather than one, so Tuesday and Thursday can be told apart.
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols.map { String($0.prefix(2)) }
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Six weeks, so the grid never changes height as months are paged.
    private var gridDays: [Date] {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month],
                                                                           from: visibleMonth))
        else { return [] }
        let weekday = calendar.component(.weekday, from: monthStart)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -lead, to: monthStart) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        withAnimation(.easeOut(duration: 0.12)) { visibleMonth = next }
    }

    private func jump(to date: Date) {
        visibleMonth = date
        select(date)
    }

    /// Keep the time; move the day.
    private func select(_ day: Date) {
        let time = calendar.dateComponents([.hour, .minute, .second], from: moment)
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = time.hour
        parts.minute = time.minute
        parts.second = time.second
        guard let combined = calendar.date(from: parts) else { return }
        moment = combined
        if !calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month) {
            visibleMonth = day
        }
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let selected: Bool
    let today: Bool
    let marked: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(Calendar.current.component(.day, from: day))")
                    .font(Face.sans(12.5, weight: selected || today ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(numberTone.color)
                Circle()
                    .fill(marked ? dotTone.color : Color.clear)
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var numberTone: Tone {
        if selected { return theme.paper }
        if !inMonth { return theme.muted.opacity(0.45) }
        if today { return theme.accent }
        return theme.ink
    }

    private var dotTone: Tone {
        if selected { return theme.paper.opacity(0.7) }
        return inMonth ? theme.accent.opacity(0.65) : theme.muted.opacity(0.4)
    }

    @ViewBuilder private var background: some View {
        if selected {
            Rectangle().fill(theme.accent.color)
        } else if hovering {
            Rectangle().fill(theme.rule.opacity(0.5).color)
        } else {
            Color.clear
        }
    }
}

/// HH:mm, typed or nudged — the system's time field brings its own furniture.
struct TimeField: View {
    @Binding var moment: Date
    @Environment(\.theme) private var theme
    @State private var text: String = ""
    @FocusState private var editing: Bool

    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 10) {
            QuietButton(title: "\u{2212}") { nudge(-5) }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(Face.sans(13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.ink.color)
                .frame(width: 44)
                .tint(theme.accent.color)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { _, focused in if !focused { commit() } }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(editing ? theme.accent.color : Color.clear)
                        .frame(height: 1)
                        .offset(y: 3)
                }
            QuietButton(title: "+") { nudge(5) }
        }
        .onAppear { text = Formats.clock.string(from: moment) }
        .onChange(of: moment) { _, new in
            if !editing { text = Formats.clock.string(from: new) }
        }
    }

    private func nudge(_ minutes: Int) {
        guard let moved = calendar.date(byAdding: .minute, value: minutes, to: moment) else { return }
        moment = moved
        text = Formats.clock.string(from: moved)
    }

    /// Accepts "9", "930", "9:30", "09:30"; anything else snaps back.
    private func commit() {
        let digits = text.filter(\.isNumber)
        var hour: Int?
        var minute = 0
        switch digits.count {
        case 1, 2: hour = Int(digits)
        case 3: hour = Int(digits.prefix(1)); minute = Int(digits.suffix(2)) ?? 0
        case 4: hour = Int(digits.prefix(2)); minute = Int(digits.suffix(2)) ?? 0
        default: hour = nil
        }
        if let hour, (0...23).contains(hour), (0...59).contains(minute) {
            var parts = calendar.dateComponents([.year, .month, .day], from: moment)
            parts.hour = hour
            parts.minute = minute
            parts.second = 0
            if let combined = calendar.date(from: parts) { moment = combined }
        }
        text = Formats.clock.string(from: moment)
    }
}
