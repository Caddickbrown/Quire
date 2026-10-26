//
//  QuireComponents.swift
//  Quire
//
//  The parts every phone screen is made of: masthead, text tab bar, entry row,
//  rendered markdown. No boxes — type, hairlines and margins.
//

import SwiftUI

// MARK: - Dates and excerpts

enum QDate {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = format
        return f
    }
    private static let long = formatter("EEEE d MMMM")
    private static let short = formatter("EEE d MMM")
    private static let full = formatter("EEE d MMM yyyy")
    private static let month = formatter("MMMM yyyy")

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    /// A jnl timestamp, or a bare "YYYY-MM-DD" (read as noon, clear of any DST edge).
    static func date(_ iso: String) -> Date? { parser.date(from: iso.count == 10 ? iso + " 12:00:00" : iso) }
    static func longDay(_ d: Date = Date()) -> String { long.string(from: d) }
    static func shortDay(_ iso: String) -> String { date(iso).map { short.string(from: $0) } ?? iso }
    static func fullDay(_ iso: String) -> String { date(iso).map { full.string(from: $0) } ?? iso }
    static func monthYear(_ iso: String) -> String { date(iso).map { month.string(from: $0) } ?? iso }
    /// "08:12" from a jnl timestamp.
    static func time(_ ts: String) -> String { String(ts.dropFirst(11).prefix(5)) }
}

extension String {
    /// At most `limit` characters, ending in an ellipsis if cut. A single enormous
    /// paragraph (an import, a pasted page) can't be wrapped by SwiftUI's Text,
    /// which then measures it as one very wide line and shoves the whole screen
    /// sideways, so anything shown as a preview is clamped first.
    func qClamped(_ limit: Int) -> String {
        count <= limit ? self : String(prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Splits long text into pieces of at most `limit` characters, at spaces
    /// where it can, so each piece is a paragraph Text can lay out.
    func qChunks(_ limit: Int) -> [String] {
        guard count > limit else { return [self] }
        var out: [String] = []
        var rest = Substring(self)
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(of: " ").map { window.distance(from: window.startIndex, to: $0) } ?? limit
            let n = max(cut, 1)
            out.append(String(rest.prefix(n)))
            rest = rest.dropFirst(n).drop { $0 == " " }
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }
}

extension Entry {
    /// The line used as a title: the header title, else the first body line.
    var qTitle: String { preview.trimmingCharacters(in: .whitespaces).qClamped(200) }
    var qHasTitle: Bool { !displayTitle.isEmpty }
    /// The next line of body worth showing under the title.
    var qExcerpt: String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("![") }
        if !qHasTitle, !lines.isEmpty { lines.removeFirst() }
        return (lines.first ?? "").qClamped(300)
    }
}

/// An entry together with where it lives, so every edit can route.
struct EntryRef: Hashable, Identifiable {
    let entry: Entry
    let source: EntrySource
    var id: String { entry.id }
}

// MARK: - Masthead

/// "Quire" in italic, with Search and Settings as plain words. In Marathon the
/// mark sits in a signal block, and the actions are cells ruled off from it.
struct QMasthead: View {
    @Environment(\.quire) private var q
    var onSearch: () -> Void
    var onSettings: () -> Void

    var body: some View {
        if q.isMarathon {
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    QMark().stroke(q.onSignalColor, style: StrokeStyle(lineWidth: 7, lineCap: .square))
                        .frame(width: 19, height: 21)
                    Text("QUIRE").font(q.display(17)).tracking(0.4)
                }
                .padding(.horizontal, 16).frame(height: 48)
                .background(q.signalColor, ignoresSafeAreaEdges: []).foregroundStyle(q.onSignalColor)
                .accessibilityElement(children: .combine).accessibilityLabel("Quire")
                Spacer(minLength: 0)
                cell("Search", onSearch)
                cell("Settings", onSettings)
            }
            .overlay(alignment: .bottom) { QRule() }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                HStack(spacing: 8) {
                    QMark().stroke(q.inkColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 16, height: 18).accessibilityHidden(true)
                    Text("Quire").font(q.writing(22, italic: true)).foregroundStyle(q.inkColor)
                }
                Spacer()
                QLink(title: "Search", action: onSearch)
                QLink(title: "Settings", action: onSettings)
            }
            .foregroundStyle(q.mutedColor)
        }
    }

    private func cell(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title.uppercased()).tracking(1.3).font(q.label(11, weight: .medium)).foregroundStyle(q.inkColor)
                .padding(.horizontal, 14).frame(height: 48).contentShape(Rectangle())
                .overlay(alignment: .leading) { Rectangle().fill(q.lineColor).frame(width: 1) }
        }
        .buttonStyle(.plain)
    }
}

/// A screen title: the small-caps kicker over a large word. Marathon: mono
/// readout over wide, heavy capitals.
struct QTitle: View {
    @Environment(\.quire) private var q
    let kicker: String
    let title: String
    var size: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kicker.uppercased()).tracking(q.tracking(11))
                .font(q.label(11, weight: q.isMarathon ? .regular : .semibold)).foregroundStyle(q.mutedColor)
            if q.isMarathon {
                Text(title.uppercased()).font(q.display(size * 0.92)).tracking(-size * 0.02)
                    .foregroundStyle(q.inkColor).minimumScaleFactor(0.5).lineLimit(1)
            } else {
                Text(title).font(q.display(size)).foregroundStyle(q.inkColor)
                    .minimumScaleFactor(0.7).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Tab bar

enum PhoneTab: Hashable { case today, inbox, journal, lookBack }

/// Words, not icons. The page you are on is accent and heavier; only the inbox
/// carries a count, because only the inbox is a queue. Marathon: ruled square
/// cells in tracked caps, the current one inverted, "+" as a signal block.
struct QTabBar: View {
    @Environment(\.quire) private var q
    @Binding var tab: PhoneTab
    let inboxCount: Int
    var onNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            QRule()
            if q.isMarathon { marathon } else { classic }
        }
        .background(q.pageColor)
    }

    // MARK: Classic

    private var classic: some View {
        HStack {
            item("Today", .today)
            Spacer(minLength: 0)
            inbox
            Spacer(minLength: 0)
            Button(action: onNew) {
                Text("+").font(q.writing(30)).foregroundStyle(q.accentColor)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("New entry")
            Spacer(minLength: 0)
            item("Journal", .journal)
            Spacer(minLength: 0)
            item("Look back", .lookBack)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }

    private func item(_ title: String, _ target: PhoneTab) -> some View {
        Button { tab = target } label: {
            Text(title)
                .font(q.ui(13, weight: tab == target ? .semibold : .regular))
                .foregroundStyle(tab == target ? q.accentColor : q.inkColor)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == target ? .isSelected : [])
    }

    private var inbox: some View {
        Button { tab = .inbox } label: {
            HStack(spacing: 4) {
                Text("Inbox")
                if inboxCount > 0 { Text("\(inboxCount)").foregroundStyle(q.accentColor).fontWeight(.semibold) }
            }
            .font(q.ui(13, weight: tab == .inbox ? .semibold : .regular))
            .foregroundStyle(tab == .inbox ? q.accentColor : q.inkColor)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == .inbox ? .isSelected : [])
    }

    // MARK: Marathon

    private var marathon: some View {
        HStack(spacing: 0) {
            cell("Today", .today)
            cell("Inbox", .inbox, badge: inboxCount)
            Button(action: onNew) {
                Text("+").font(q.mono(22, weight: .medium)).foregroundStyle(q.onSignalColor)
                    .frame(width: 52, height: 52).background(q.signalColor, ignoresSafeAreaEdges: [])
            }
            .buttonStyle(.plain).accessibilityLabel("New entry")
            cell("Journal", .journal)
            cell("Look back", .lookBack)
        }
        .frame(height: 52)
    }

    private func cell(_ title: String, _ target: PhoneTab, badge: Int = 0) -> some View {
        let on = tab == target
        return Button { tab = target } label: {
            HStack(spacing: 5) {
                Text(title.uppercased()).tracking(0.9)
                if badge > 0 {
                    Text(badge > 99 ? "99+" : String(format: "%02d", badge)).font(q.label(9.5, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(q.signalColor).foregroundStyle(q.onSignalColor)
                }
            }
            .font(q.label(10.5, weight: .medium))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(on ? q.pageColor : q.inkColor)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(on ? q.inkColor : Color.clear, ignoresSafeAreaEdges: [])
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) { if target != .lookBack { Rectangle().fill(q.lineColor).frame(width: 1) } }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Entry row

/// Mono time, serif title, one muted line. The time is only text here: changing
/// an entry's time is a deliberate act inside the entry, never a tap in a list.
struct QEntryRow: View {
    @Environment(\.quire) private var q
    let entry: Entry
    var showTime = true
    /// The row the keyboard is on.
    var selected = false
    var onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if showTime {
                // Set on its side, reading upwards, so the title gets the width.
                Text(QDate.time(entry.ts))
                    .font(q.mono(12)).foregroundStyle(q.mutedColor)
                    .fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 14, height: 40)
                    .padding(.top, 2)
                    .accessibilityLabel("Time \(QDate.time(entry.ts))")
            }
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.qTitle.isEmpty ? "Untitled" : entry.qTitle)
                            .font(q.writing(19, weight: q.isMarathon ? .medium : .regular, italic: entry.qTitle.isEmpty))
                            .foregroundStyle(entry.qTitle.isEmpty ? q.mutedColor : q.inkColor)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        if entry.isStarred { Text("★").font(q.ui(13)).foregroundStyle(q.accentColor) }
                    }
                    if !entry.qExcerpt.isEmpty {
                        Text(entry.qExcerpt).font(q.ui(13)).foregroundStyle(q.mutedColor)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.vertical, 4)
        .background(selected ? q.accentSoftColor : Color.clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(q.accentColor).frame(width: 3) }
        }
        .id(entry.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - On this day

extension JournalStore {
    /// Filed entries from today's calendar day in earlier years, newest year
    /// first, read from the parsed archive already in memory. (`onThisDay()`
    /// re-reads and re-decodes the whole journal once per matching year, which
    /// is far too heavy to call while a screen is being drawn.)
    func qOnThisDay() -> [(date: String, entries: [Entry])] {
        let today = JournalStore.nowDate()
        let monthDay = String(today.suffix(5)), year = String(today.prefix(4))
        return archiveEntries.filter { $0.date.hasSuffix(monthDay) && String($0.date.prefix(4)) < year }
    }
}

// MARK: - Markdown

/// Inline markdown, with @tags in the accent.
enum QMarkdown {
    static func inline(_ text: String, accent: Color) -> AttributedString {
        var out = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let plain = String(out.characters)
        if let regex = try? NSRegularExpression(pattern: "(?<![\\w@])@[\\w][\\w-]*") {
            for match in regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let r = Range(match.range, in: plain),
                      let lower = AttributedString.Index(r.lowerBound, within: out),
                      let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
                out[lower..<upper].foregroundColor = accent
            }
        }
        return out
    }
}
