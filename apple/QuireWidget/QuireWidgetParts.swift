//
//  QuireWidgetParts.swift
//  QuireWidget
//
//  What every Quire widget shares: the timeline, the day a snapshot
//  describes, and the look. The look is the app's own — QuireTheme.swift and
//  themes.json are built into the extension — picked by the theme id the app
//  writes into the snapshot, so a widget is set like the page it opens.
//

import WidgetKit
import SwiftUI

// MARK: - Timeline

struct QuireEntry: TimelineEntry {
    let date: Date
    let snap: QuireSnapshot
    /// How many times the prompt has been rerolled (App Group), when made.
    let promptOffset: Int
}

struct QuireProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuireEntry {
        QuireEntry(date: Date(), snap: .sample(on: Date()), promptOffset: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuireEntry) -> Void) {
        let now = Date()
        var snap = QuireSnapshot.load()
        // The gallery shows sample figures until the app has written a snapshot.
        if context.isPreview && snap.updatedAt == .distantPast { snap = .sample(on: now) }
        completion(QuireEntry(date: now, snap: snap, promptOffset: QuirePrompts.offset))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuireEntry>) -> Void) {
        let now = Date()
        let snap = QuireSnapshot.load()
        let offset = QuirePrompts.offset
        var entries = [QuireEntry(date: now, snap: snap, promptOffset: offset)]
        // Midnight turns the page — a new date, a new prompt, today's words
        // back to nothing — whether or not the app runs.
        if let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0),
                                                    matchingPolicy: .nextTime) {
            entries.append(QuireEntry(date: midnight, snap: snap, promptOffset: offset))
        }
        // The app reloads the timelines whenever a figure moves; this is the backstop.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1800)
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

extension QuireSnapshot {
    /// Figures for the widget gallery and placeholders.
    static func sample(on date: Date) -> QuireSnapshot {
        var s = QuireSnapshot()
        s.currentStreak = 12; s.bestStreak = 31
        s.totalDays = 214; s.totalEntries = 1284; s.totalWords = 212_400
        s.inboxDrafts = 3
        let key = dayKey(date)
        s.day = key; s.wordsToday = 145; s.wordGoal = 250
        s.filedToday = 2; s.wroteToday = true
        s.onThisDayPreview = "Lunch by the canal"
        s.onThisDayExcerpt = "Sun on the water, the heron back on its post."
        s.onThisDayYearsAgo = 3
        s.onThisDayDate = String((Int(key.prefix(4)) ?? 2026) - 3) + key.dropFirst(4)
        return s
    }
}

// MARK: - The day on show

/// A snapshot read for the day an entry shows.
struct WidgetDay {
    let entry: QuireEntry
    private var snap: QuireSnapshot { entry.snap }

    /// Whether the "today" figures are this entry's day. A snapshot from
    /// before midnight still knows the inbox and the streak, but not today.
    var isCurrent: Bool { snap.day.map { $0 == QuireSnapshot.dayKey(entry.date) } ?? true }

    var words: Int { isCurrent ? snap.wordsToday ?? 0 : 0 }
    /// 0 when the word goal is off.
    var goal: Int { max(snap.wordGoal ?? 0, 0) }
    var goalFraction: Double { goal > 0 ? min(1, Double(words) / Double(goal)) : 0 }
    var filed: Int { isCurrent ? snap.filedToday ?? 0 : 0 }
    var drafts: Int { snap.inboxDrafts }
    var entries: Int { snap.totalEntries }
    var totalWords: Int { snap.totalWords }
    var prompt: String { QuirePrompts.prompt(on: entry.date, offset: entry.promptOffset) }

    /// The streak as of this entry's day: a snapshot from yesterday keeps it
    /// only if yesterday was written; anything older has lapsed.
    var streak: Int {
        guard !isCurrent, let day = snap.day else { return snap.currentStreak }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: entry.date).map(QuireSnapshot.dayKey)
        return day == yesterday && snap.wroteToday == true ? snap.currentStreak : 0
    }
    var best: Int { max(snap.bestStreak, streak) }

    struct Memory {
        let title: String
        let excerpt: String?
        let year: String
        let yearsAgo: Int
        let url: URL?
    }

    /// The newest entry from this calendar day in an earlier year.
    var onThisDay: Memory? {
        guard isCurrent, let title = snap.onThisDayPreview?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty, let ago = snap.onThisDayYearsAgo else { return nil }
        let year = snap.onThisDayDate.map { String($0.prefix(4)) } ?? ""
        var url: URL?
        if let date = snap.onThisDayDate, let ts = snap.onThisDayTS { url = QuireSnapshot.entryURL(date: date, ts: ts) }
        return Memory(title: title, excerpt: snap.onThisDayExcerpt, year: year, yearsAgo: ago, url: url)
    }

    // Dates, set as the app sets them.
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = format
        return f
    }
    private static let longFormat = formatter("EEEE d MMMM")
    private static let shortFormat = formatter("EEE d MMM")
    var longDate: String { Self.longFormat.string(from: entry.date) }
    var shortDate: String { Self.shortFormat.string(from: entry.date) }

    /// Marathon's log number: "2026.299", and "DAY 299 / 365".
    var logNumber: String {
        let cal = Calendar.current
        return String(format: "%d.%03d", cal.component(.year, from: entry.date),
                      cal.ordinality(of: .day, in: .year, for: entry.date) ?? 1)
    }
    var dayOfYear: String {
        let cal = Calendar.current
        let day = cal.ordinality(of: .day, in: .year, for: entry.date) ?? 1
        let days = cal.range(of: .day, in: .year, for: entry.date)?.count ?? 365
        return "DAY \(day) / \(days)"
    }

    // Words, as the Today page says them.
    static func word(_ n: Int) -> String {
        let names = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return n < names.count ? names[n] : "\(n)"
    }
    var filedPhrase: String {
        filed == 0 ? "Nothing filed yet" : filed == 1 ? "One entry filed" : "\(Self.word(filed)) entries filed"
    }
    /// "Three drafts are" — nil with an empty inbox.
    var draftsPhrase: String? {
        drafts == 0 ? nil : drafts == 1 ? "One draft is" : "\(Self.word(drafts)) drafts are"
    }
    var yearsAgoPhrase: String {
        guard let ago = onThisDay?.yearsAgo else { return "" }
        return ago == 1 ? "A year ago" : "\(Self.word(ago)) years ago"
    }
    static func short(_ n: Int) -> String {
        n >= 1000 ? String(format: n >= 100_000 ? "%.0fK" : "%.1fK", Double(n) / 1000) : "\(n)"
    }
}

// MARK: - The look

/// The app's look in the environment, and the widget's page painted with it.
/// Accessories (`paintsPage: false`) take the type but leave the background
/// to the system.
struct QuireWidgetPage<Content: View>: View {
    let snap: QuireSnapshot
    var paintsPage = true
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = QuireTheme.resolve(snap.themeID ?? QuireTheme.auto, scheme: scheme)
        content
            .environment(\.quire, theme)
            .environment(\.colorScheme, paintsPage ? theme.colorScheme : scheme)
            .foregroundStyle(paintsPage ? theme.inkColor : Color.primary)
            .tint(theme.accentColor)
            // The figures are set to fit; past Large they would only clip.
            .dynamicTypeSize(...DynamicTypeSize.large)
            .containerBackground(for: .widget) { paintsPage ? theme.pageColor : Color.clear }
    }
}

/// The Quire mark at widget size.
struct WidgetMark: View {
    var color: Color
    var size: CGFloat
    var square = false
    var body: some View {
        QMark().stroke(color, style: StrokeStyle(lineWidth: max(1.2, size / 7), lineCap: square ? .square : .round))
            .frame(width: size, height: size * 70 / 62)
            .accessibilityHidden(true)
    }
}

/// A small tracked label: "MON 26 OCT", "ON THIS DAY".
struct WKicker: View {
    @Environment(\.quire) private var q
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).tracking(q.tracking(9.5))
            .font(q.label(9.5, weight: q.isMarathon ? .regular : .semibold))
            .foregroundStyle(q.mutedColor)
            .lineLimit(1)
    }
}

/// Progress as a bar: a hairline in the classic looks, a thick bar in Marathon.
struct WidgetBar: View {
    let fraction: Double
    let height: CGFloat
    let fill: Color
    let track: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle().fill(fill).frame(width: g.size.width * fraction).widgetAccentable()
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent of today's word goal")
    }
}

/// Marathon's word bar: ten cells, filled in the signal colour.
struct WidgetSegments: View {
    @Environment(\.quire) private var q
    let fraction: Double
    var body: some View {
        let filled = Int((fraction * 10).rounded(.down))
        HStack(spacing: 3) {
            ForEach(0..<10, id: \.self) { i in
                Rectangle().fill(i < filled ? q.signalColor : q.lineColor).frame(height: 10)
            }
        }
        .widgetAccentable()
        .accessibilityElement()
        .accessibilityLabel("\(filled) of 10 toward today's word goal")
    }
}

/// Marathon's begin block: ink on the page, the top-right corner cut.
struct MarathonBegin: View {
    @Environment(\.quire) private var q
    let prompt: String
    var size: CGFloat = 14
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("BEGIN A NEW ENTRY").font(q.display(size)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 6)
                Text("→").font(q.mono(size + 1, weight: .medium))
            }
            Text(prompt).font(q.ui(11.5)).opacity(0.75).lineLimit(1)
        }
        .foregroundStyle(q.pageColor)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(q.inkColor)
        .clipShape(QChamfer(cut: 15))
    }
}
