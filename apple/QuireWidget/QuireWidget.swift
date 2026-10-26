//
//  QuireWidget.swift
//  QuireWidget
//
//  The Home Screen widgets, set like the Today page they open:
//
//  Today (QuireWidget)
//    Small  — the date, today's words against the goal, streak and drafts.
//    Medium — "Begin a new entry", today's prompt (with a button for another),
//             and the day's figures ruled off below.
//    Large  — the Today page in miniature: the sentence about the day, a way
//             to begin, and what you wrote on this day in an earlier year.
//  On this day (QuireOnThisDayWidget) — Small: that entry, tap to read it.
//
//  Each has a classic face (Almanac, Broadsheet, Linen, Cinema, Night) and a
//  Marathon one. Figures come from the QuireSnapshot the app writes to the App
//  Group after every reload; the widget never opens the journal.
//

import WidgetKit
import SwiftUI
import AppIntents
#if canImport(ActivityKit)
import ActivityKit
#endif

private enum Links {
    static let write = URL(string: "quire://write")!
    static let today = URL(string: "quire://today")!
    static let inbox = URL(string: "quire://inbox")!
}

// MARK: - Another prompt

/// The medium and large widgets' "Another prompt": rerolls the prompt for the
/// app and every widget (the offset lives in the App Group).
struct NextPromptIntent: AppIntent {
    static var title: LocalizedStringResource = "Another Prompt"
    static var description = IntentDescription("Shows the next writing prompt in Quire and its widgets.")
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        QuirePrompts.next()
        return .result()
    }
}

// MARK: - Small · Today

private struct TodaySmall: View {
    let day: WidgetDay
    @Environment(\.quire) private var q

    var body: some View {
        Group { if q.isMarathon { marathon } else { classic } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(Links.today)
    }

    private var classic: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                WidgetMark(color: q.mutedColor, size: 10)
                WKicker(day.shortDate)
            }
            Text("Today").font(q.display(30)).lineLimit(1).padding(.top, 10)
            Rectangle().fill(q.accentColor).frame(width: 28, height: q.ruleH)
                .padding(.top, 6).widgetAccentable()
            Spacer(minLength: 6)
            Group {
                if day.goal > 0 {
                    Text("\(day.words)").foregroundColor(q.accentColor) + Text(" of \(day.goal) words")
                } else {
                    Text("\(day.words)").foregroundColor(q.accentColor) + Text(day.words == 1 ? " word today" : " words today")
                }
            }
            .font(q.writing(15)).lineLimit(1).minimumScaleFactor(0.8)
            if day.goal > 0 {
                WidgetBar(fraction: day.goalFraction, height: q.ruleH, fill: q.accentColor, track: q.lineColor)
                    .padding(.top, 6)
            }
            footer.padding(.top, 9)
        }
    }

    private var footer: some View {
        let streak = day.streak == 1 ? "1 day" : "\(day.streak) days"
        let drafts = day.drafts == 1 ? "1 draft" : "\(day.drafts) drafts"
        return Group {
            if day.drafts > 0 {
                Text(streak + " · ") + Text(drafts).foregroundColor(q.accentColor)
            } else {
                Text(streak + " running")
            }
        }
        .font(q.ui(11)).foregroundStyle(q.mutedColor).lineLimit(1)
    }

    private var marathon: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("■").foregroundStyle(q.signalColor)
                Text(day.goal > 0 ? "WORDS / GOAL" : "WORDS TODAY").tracking(1.4)
            }
            .font(q.label(10)).foregroundStyle(q.mutedColor)
            Text(String(format: "%03d", day.words)).font(q.display(40)).foregroundStyle(q.accentColor)
                .lineLimit(1).minimumScaleFactor(0.5).padding(.top, 10)
            Text(day.goal > 0 ? "OF \(day.goal) TODAY" : "\(day.logNumber)").tracking(1.2)
                .font(q.label(10)).foregroundStyle(q.mutedColor).padding(.top, 4)
            Spacer(minLength: 6)
            if day.goal > 0 { WidgetSegments(fraction: day.goalFraction) }
            HStack(spacing: 10) {
                Text(String(format: "%03d", day.streak)).foregroundColor(q.inkColor) + Text(" STREAK")
                if day.drafts > 0 {
                    Text(String(format: "%02d", day.drafts)).foregroundColor(q.flagColor) + Text(" UNFILED")
                }
            }
            .tracking(1.1).font(q.label(9.5)).foregroundStyle(q.mutedColor).lineLimit(1)
            .minimumScaleFactor(0.8).padding(.top, 8)
        }
    }
}

// MARK: - Medium · Begin

private struct BeginMedium: View {
    let day: WidgetDay
    @Environment(\.quire) private var q

    var body: some View {
        Group { if q.isMarathon { marathon } else { classic } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(Links.write)
    }

    private var classic: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                WKicker(day.longDate)
                Spacer(minLength: 8)
                another
            }
            (Text("Begin a new entry ") + Text("→").foregroundColor(q.accentColor))
                .font(q.writing(22)).lineLimit(1).minimumScaleFactor(0.8)
            Text(day.prompt).font(q.writing(14.5, italic: true)).foregroundStyle(q.mutedColor)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            QRule()
            HStack(spacing: 0) {
                cell(words, day.goal > 0 ? "Words" : "Words today", leading: false)
                cell(Text("\(day.streak)"), "Day streak", leading: true)
                Link(destination: Links.inbox) {
                    cell(Text("\(day.drafts)").foregroundColor(day.drafts > 0 ? q.accentColor : q.inkColor),
                         "Drafts", leading: true)
                }
            }
            .padding(.top, 4)
        }
    }

    private var words: Text {
        day.goal > 0
            ? Text("\(day.words)").foregroundColor(q.accentColor) + Text("/\(day.goal)").foregroundColor(q.mutedColor)
            : Text("\(day.words)").foregroundColor(q.accentColor)
    }

    private var another: some View {
        Button(intent: NextPromptIntent()) {
            Text(q.caps("Another prompt ↻")).tracking(q.isMarathon ? 1.2 : 0)
                .font(q.isMarathon ? q.label(10) : q.ui(11, weight: .medium))
                .foregroundStyle(q.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Another prompt")
    }

    private func cell(_ value: Text, _ label: String, leading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            value.font(q.mono(13, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label.uppercased()).tracking(1).font(q.label(9)).foregroundStyle(q.mutedColor).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, leading ? 10 : 0)
        .overlay(alignment: .leading) {
            if leading { Rectangle().fill(q.lineColor).frame(width: 1) }
        }
        .accessibilityElement(children: .combine)
    }

    private var marathon: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("LOG \(day.logNumber)").tracking(1.4).font(q.label(10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(q.signalColor).foregroundStyle(q.onSignalColor)
                Text(day.dayOfYear).tracking(1.4).font(q.label(10)).foregroundStyle(q.mutedColor)
                    .lineLimit(1)
                Spacer(minLength: 4)
                another
            }
            MarathonBegin(prompt: day.prompt, size: 15)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                Text("\(day.words)").foregroundColor(q.accentColor)
                    + Text(day.goal > 0 ? "/\(day.goal) WORDS" : " WORDS")
                Text("\(day.streak)").foregroundColor(q.inkColor) + Text(" STREAK")
                Link(destination: Links.inbox) {
                    Text(String(format: "%02d", day.drafts)).foregroundColor(q.flagColor) + Text(" UNFILED")
                }
            }
            .tracking(1.2).font(q.label(10)).foregroundStyle(q.mutedColor).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Large · Today page

private struct TodayLarge: View {
    let day: WidgetDay
    @Environment(\.quire) private var q

    var body: some View {
        Group { if q.isMarathon { marathon } else { classic } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(Links.today)
    }

    private var classic: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 7) {
                    WidgetMark(color: q.inkColor, size: 14)
                    Text("Quire").font(q.writing(17, italic: true))
                }
                Spacer()
                Text(day.shortDate).font(q.mono(11)).foregroundStyle(q.mutedColor)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Today").font(q.display(34)).lineLimit(1)
                Rectangle().fill(q.accentColor).frame(width: 40, height: q.ruleH).widgetAccentable()
            }
            summary
            Link(destination: Links.write) {
                VStack(alignment: .leading, spacing: 2) {
                    (Text("Begin a new entry ") + Text("→").foregroundColor(q.accentColor))
                        .font(q.writing(19)).lineLimit(1)
                    Text(day.prompt).font(q.writing(13, italic: true)).foregroundStyle(q.mutedColor).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .overlay(alignment: .top) { QRule() }
                .overlay(alignment: .bottom) { QRule() }
            }
            if let memory = day.onThisDay {
                VStack(alignment: .leading, spacing: 6) {
                    WKicker("On this day")
                    memoryLink(memory) {
                        HStack(alignment: .top, spacing: 10) {
                            Text(memory.year).font(q.mono(10.5)).foregroundStyle(q.accentColor)
                                .fixedSize().rotationEffect(.degrees(-90)).frame(width: 12, height: 30)
                            Text(memory.title).font(q.writing(15)).lineLimit(2)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text(day.streak == 0 ? "Best streak \(day.best) days" : "\(day.streak) days running · best \(day.best)")
                .font(q.ui(11)).foregroundStyle(q.mutedColor)
        }
    }

    // "Two entries filed, 145 of 250 words so far. Three drafts are waiting."
    private var summary: some View {
        let words: Text = day.goal > 0
            ? Text(", ") + Text("\(day.words) of \(day.goal)").foregroundColor(q.accentColor) + Text(" words so far.")
            : Text(day.words > 0 ? ", \(day.words) words so far." : ".")
        let drafts: Text = day.draftsPhrase.map {
            Text(" ") + Text($0).foregroundColor(q.accentColor) + Text(" waiting.")
        } ?? Text("")
        return (Text(day.filedPhrase) + words + drafts)
            .font(q.writing(15)).lineSpacing(3).lineLimit(3)
    }

    @ViewBuilder
    private func memoryLink<Content: View>(_ memory: WidgetDay.Memory, @ViewBuilder _ label: () -> Content) -> some View {
        if let url = memory.url { Link(destination: url) { label() } } else { label() }
    }

    private var marathon: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    WidgetMark(color: q.onSignalColor, size: 11, square: true)
                    Text("QUIRE").font(q.display(12))
                }
                .padding(.horizontal, 12).frame(maxHeight: .infinity)
                .background(q.signalColor).foregroundStyle(q.onSignalColor)
                Spacer(minLength: 0)
                Text("LOG \(day.logNumber)").tracking(1.4).font(q.label(10)).foregroundStyle(q.mutedColor)
                    .padding(.horizontal, 12).frame(maxHeight: .infinity)
                    .overlay(alignment: .leading) { Rectangle().fill(q.lineColor).frame(width: 1) }
            }
            .frame(height: 30)
            .overlay(alignment: .bottom) { QRule() }

            Text("\(day.shortDate.uppercased()) · \(day.dayOfYear)").tracking(1.4)
                .font(q.label(10)).foregroundStyle(q.mutedColor).lineLimit(1).padding(.top, 12)
            Text("TODAY").font(q.display(38)).lineLimit(1).minimumScaleFactor(0.6).padding(.top, 2)

            HStack(alignment: .top, spacing: 0) {
                readout("Words" + (day.goal > 0 ? " / goal" : ""), leading: false) {
                    (Text(String(format: "%03d", day.words)).foregroundColor(q.accentColor)
                        + Text(day.goal > 0 ? "/\(day.goal)" : "").foregroundColor(q.mutedColor))
                        .font(q.display(18)).lineLimit(1).minimumScaleFactor(0.5)
                    if day.goal > 0 {
                        WidgetBar(fraction: day.goalFraction, height: 4, fill: q.signalColor, track: q.lineColor)
                    }
                }
                readout("Streak", leading: true) {
                    Text("\(day.streak)").font(q.display(18)).lineLimit(1)
                    Text(day.streak > 0 && day.streak >= day.best ? "▲ RECORD" : "BEST \(day.best)")
                        .tracking(1).font(q.label(9))
                        .foregroundStyle(day.streak > 0 && day.streak >= day.best ? q.accentColor : q.mutedColor)
                }
                Link(destination: Links.inbox) {
                    readout("Inbox", leading: true) {
                        Text(String(format: "%02d", day.drafts)).font(q.display(18))
                            .foregroundStyle(day.drafts > 0 ? q.flagColor : q.inkColor)
                        Text("UNFILED").tracking(1).font(q.label(9)).foregroundStyle(q.mutedColor)
                    }
                }
            }
            .overlay(alignment: .top) { QRule() }
            .overlay(alignment: .bottom) { QRule() }
            .padding(.top, 10)

            Link(destination: Links.write) { MarathonBegin(prompt: day.prompt) }
                .padding(.top, 12)

            Spacer(minLength: 8)
            QHazard(color: q.signalColor).opacity(0.9)
            HStack {
                Text("~/JOURNAL")
                Spacer()
                Text("\(day.entries) ENTRIES · \(WidgetDay.short(day.totalWords)) WORDS")
            }
            .tracking(1.2).font(q.label(9)).foregroundStyle(q.mutedColor).lineLimit(1).padding(.top, 6)
        }
    }

    private func readout<Content: View>(_ label: String, leading: Bool,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).tracking(1.2).font(q.label(9)).foregroundStyle(q.mutedColor).lineLimit(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9).padding(.leading, leading ? 10 : 0).padding(.trailing, 6)
        .overlay(alignment: .leading) { if leading { Rectangle().fill(q.lineColor).frame(width: 1) } }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Small · On this day

private struct OnThisDaySmall: View {
    let day: WidgetDay
    @Environment(\.quire) private var q

    var body: some View {
        Group {
            if let memory = day.onThisDay {
                if q.isMarathon { marathon(memory) } else { classic(memory) }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(day.onThisDay?.url ?? Links.today)
    }

    private func classic(_ memory: WidgetDay.Memory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WKicker("On this day")
            HStack(alignment: .top, spacing: 10) {
                Text(memory.year).font(q.mono(11)).foregroundStyle(q.accentColor)
                    .fixedSize().rotationEffect(.degrees(-90)).frame(width: 12, height: 32)
                    .widgetAccentable()
                Text(memory.title).font(q.writing(19)).lineLimit(3).minimumScaleFactor(0.8)
            }
            .padding(.top, 12)
            if let excerpt = memory.excerpt {
                Text(excerpt).font(q.writing(12.5, italic: true)).foregroundStyle(q.mutedColor)
                    .lineLimit(2).padding(.top, 6)
            }
            Spacer(minLength: 4)
            Text(day.yearsAgoPhrase).font(q.ui(11)).foregroundStyle(q.mutedColor)
        }
    }

    private func marathon(_ memory: WidgetDay.Memory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("■").foregroundStyle(q.signalColor)
                Text("ON THIS DAY").tracking(1.4)
            }
            .font(q.label(10)).foregroundStyle(q.mutedColor)
            Text(memory.year).tracking(1.4).font(q.label(10, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(q.signalColor).foregroundStyle(q.onSignalColor)
                .padding(.top, 10)
            Text(memory.title.uppercased()).font(q.display(16)).lineLimit(3).minimumScaleFactor(0.7)
                .padding(.top, 8)
            Spacer(minLength: 4)
            Text(memory.yearsAgo == 1 ? "1 YEAR AGO" : "\(memory.yearsAgo) YEARS AGO").tracking(1.2).font(q.label(10)).foregroundStyle(q.mutedColor)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            WKicker("On this day")
            Spacer(minLength: 0)
            Text("Nothing from this day in an earlier year — yet.")
                .font(q.writing(15, italic: true)).foregroundStyle(q.mutedColor)
        }
    }
}

// MARK: - Widget definitions

struct QuireWidget: Widget {
    // The kind is kept from the first widget, so placed widgets carry over.
    let kind = "QuireWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuireProvider()) { entry in
            QuireWidgetPage(snap: entry.snap) { QuireWidgetEntryView(entry: entry) }
        }
        .configurationDisplayName("Today")
        .description("Today's page: your words, a prompt, and a way to begin.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct QuireWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuireEntry

    var body: some View {
        let day = WidgetDay(entry: entry)
        switch family {
        case .systemSmall:  TodaySmall(day: day)
        case .systemLarge:  TodayLarge(day: day)
        default:            BeginMedium(day: day)
        }
    }
}

struct QuireOnThisDayWidget: Widget {
    let kind = "QuireOnThisDayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuireProvider()) { entry in
            QuireWidgetPage(snap: entry.snap) { OnThisDaySmall(day: WidgetDay(entry: entry)) }
        }
        .configurationDisplayName("On This Day")
        .description("What you wrote on this day in an earlier year.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Writing-timer Live Activity (iOS)

#if os(iOS)
/// The Lock Screen / Dynamic Island countdown for a writing session, in the
/// app's look. The system counts down to `endDate` itself; nothing here ticks.
struct QuireTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuireTimerAttributes.self) { context in
            TimerLockScreen(context: context)
        } dynamicIsland: { context in
            let q = Self.islandTheme(context.attributes.themeID)
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        WidgetMark(color: q.accentColor, size: 13, square: q.isMarathon)
                        Text(q.caps("Writing")).font(q.writing(17, italic: !q.isMarathon))
                            .foregroundStyle(q.inkColor)
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...state.endDate, countsDown: true)
                        .font(q.mono(22, weight: .medium)).monospacedDigit()
                        .foregroundStyle(q.accentColor)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(Self.wordsLine(state, marathon: q.isMarathon))
                        .font(q.isMarathon ? q.label(11) : q.ui(12))
                        .foregroundStyle(q.mutedColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                }
            } compactLeading: {
                WidgetMark(color: q.accentColor, size: 12, square: q.isMarathon)
            } compactTrailing: {
                Text(timerInterval: Date()...state.endDate, countsDown: true)
                    .font(q.mono(14, weight: .medium)).monospacedDigit()
                    .foregroundStyle(q.accentColor)
                    .frame(maxWidth: 46)
            } minimal: {
                WidgetMark(color: q.accentColor, size: 12, square: q.isMarathon)
            }
        }
    }

    /// The Island is always black: a dark look as it is, a light one as its
    /// dark partner (Cinema, or Marathon for Marathon Day).
    static func islandTheme(_ id: String?) -> QuireTheme {
        let theme = QuireTheme.resolve(id ?? QuireTheme.auto, scheme: .dark)
        if theme.dark { return theme }
        let partner = theme.isMarathon ? "marathon" : "cinema"
        return QuireTheme.all.first { $0.id == partner } ?? theme
    }

    static func wordsLine(_ state: QuireTimerAttributes.ContentState, marathon: Bool) -> String {
        let line: String
        if state.wordGoal > 0 {
            line = state.wordsToday >= state.wordGoal
                ? "Goal met — \(state.wordsToday) words today"
                : "\(state.wordsToday) of \(state.wordGoal) words today"
        } else {
            line = "\(state.wordsToday) words today"
        }
        return marathon ? line.uppercased() : line
    }
}

/// The Lock Screen banner: the page colour, the words so far, the time left.
private struct TimerLockScreen: View {
    let context: ActivityViewContext<QuireTimerAttributes>
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let q = QuireTheme.resolve(context.attributes.themeID ?? QuireTheme.auto, scheme: scheme)
        let state = context.state
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        WidgetMark(color: q.mutedColor, size: 10, square: q.isMarathon)
                        Text("WRITING SESSION").tracking(q.tracking(9.5))
                            .font(q.label(9.5, weight: q.isMarathon ? .regular : .semibold))
                    }
                    .foregroundStyle(q.mutedColor)
                    if state.wordGoal > 0 {
                        (Text("\(state.wordsToday)").foregroundColor(q.accentColor)
                            + Text(" of \(state.wordGoal) words"))
                            .font(q.writing(18))
                    } else {
                        (Text("\(state.wordsToday)").foregroundColor(q.accentColor) + Text(" words today"))
                            .font(q.writing(18))
                    }
                }
                Spacer()
                Text(timerInterval: Date()...state.endDate, countsDown: true)
                    .font(q.isMarathon ? q.display(28) : q.mono(30, weight: .medium)).monospacedDigit()
                    .foregroundStyle(q.accentColor)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
            }
            if state.wordGoal > 0 {
                WidgetBar(fraction: min(1, Double(state.wordsToday) / Double(state.wordGoal)),
                          height: q.isMarathon ? 4 : q.ruleH,
                          fill: q.isMarathon ? q.signalColor : q.accentColor, track: q.lineColor)
            }
        }
        .foregroundStyle(q.inkColor)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .activityBackgroundTint(q.pageColor)
        .activitySystemActionForegroundColor(q.accentColor)
        .environment(\.quire, q)
    }
}
#endif
