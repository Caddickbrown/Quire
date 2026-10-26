//
//  DeskViews.swift
//  Quire
//
//  The monitor, in Quire's own design. A plugged-in display is a desk mode: it
//  follows the phone's theme, sets everything in the same type and rules, and is
//  driven from the keyboard alone: Today when nothing is open, the list and a
//  preview while browsing, the page itself when reading or writing, and a
//  settings list on `,`. Sizes come from `ExternalDisplayMetrics`, so a desk
//  monitor and a TV across the room both read.
//

#if os(iOS)

import SwiftUI

// MARK: - The window shown on the monitor

struct ExternalDisplayRoot: View {
    @ObservedObject private var model = ExternalDisplayModel.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @ObservedObject private var settings = ExternalSettingsModel.shared
    @AppStorage(QuireTheme.storageKey) private var themeID = QuireTheme.auto
    @AppStorage(ExternalTheme.key) private var monitorTheme = ExternalTheme.followPhone
    @AppStorage(ExternalTextSize.key) private var textSizeRaw = ExternalTextSize.regular.rawValue

    var body: some View {
        // The phone's theme unless the monitor was given its own.
        let id = monitorTheme == ExternalTheme.followPhone ? themeID : monitorTheme
        let q = QuireTheme.resolve(id, scheme: model.colorScheme)
        GeometryReader { geo in
            let metrics = ExternalDisplayMetrics(size: geo.size, scale: (ExternalTextSize(rawValue: textSizeRaw) ?? .regular).scale)
            ZStack {
                q.pageColor.ignoresSafeArea()
                if model.isPaused || appLock.showsVeil {
                    DeskNotice(title: appLock.showsVeil ? "Journal locked" : "Display paused",
                               line: appLock.showsVeil ? "Unlock Quire on your phone to continue." : "⌥⌘P to resume",
                               metrics: metrics)
                } else if let store = model.store {
                    VStack(spacing: 0) {
                        page(metrics: metrics).frame(maxWidth: .infinity, maxHeight: .infinity)
                        DeskHintBar(hints: hints, metrics: metrics)
                    }
                    .environmentObject(store)
                } else {
                    DeskNotice(title: "Quire", line: "Loading your journal…", metrics: metrics)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .environment(\.quire, q)
        .tint(q.accentColor)
        .foregroundStyle(q.inkColor)
        .environment(\.colorScheme, q.colorScheme)
        .preferredColorScheme(q.colorScheme)
    }

    @ViewBuilder private func page(metrics: ExternalDisplayMetrics) -> some View {
        if settings.isOpen {
            ExternalSettingsView(metrics: metrics)
        } else {
            switch model.content {
            case .idle:
                DeskToday(metrics: metrics)
            case .browsing(let listTitle, let rows, let selected, let offset, let total):
                DeskBrowse(listTitle: listTitle, rows: rows, selected: selected, offset: offset, total: total ?? rows.count, metrics: metrics)
            case .composing(let title, let date, let text, let caret):
                DeskEntry(title: title, date: date, text: text, isStarred: false, live: true, caret: caret, metrics: metrics)
            case .editing(let title, let date, let text, let caret, let isStarred, _):
                DeskEntry(title: title, date: date, text: text, isStarred: isStarred, live: true, caret: caret, metrics: metrics)
            case .reading(let title, let date, let text, let isStarred):
                DeskEntry(title: title, date: date, text: text, isStarred: isStarred, live: false, caret: nil, metrics: metrics)
            }
        }
    }

    /// Which keys are live right now. Shown on the monitor because the phone is
    /// dimmed; the same keys as the terminal app.
    private var hints: [ShortcutHint] {
        if settings.isOpen {
            return [.init(key: "↑↓", label: "Move"), .init(key: "↩", label: "Change"), .init(key: ",", label: "Close"), .init(key: "⎋", label: "Close")]
        }
        let common: [ShortcutHint] = [.init(key: "⌥⌘±", label: "Size"), .init(key: "⌥⌘T", label: "Theme"), .init(key: "⌥⌘P", label: "Pause")]
        switch model.content {
        case .idle:
            return [.init(key: "n", label: "New"), .init(key: "i", label: "Inbox"), .init(key: "j", label: "Journal"),
                    .init(key: "l", label: "Look back"), .init(key: "/", label: "Search"), .init(key: "r", label: "Random"),
                    .init(key: ",", label: "Settings"), .init(key: "?", label: "Hints")]
        case .browsing(let listTitle, _, _, _, _):
            let base: [ShortcutHint] = [.init(key: "↑↓", label: "Move"), .init(key: "↩", label: "Open"), .init(key: "⎋", label: "Back")]
            switch listTitle {
            case "Inbox":
                return base + [.init(key: "f", label: "File"), .init(key: "e", label: "Edit"), .init(key: "*", label: "Star"),
                               .init(key: "t", label: "Time"), .init(key: "d", label: "Delete"), .init(key: ",", label: "Settings")]
            case "Journal":
                return base + [.init(key: "e", label: "Edit"), .init(key: "u", label: "Inbox"), .init(key: "*", label: "Star"),
                               .init(key: "d", label: "Delete"), .init(key: ",", label: "Settings")]
            default:
                return base + [.init(key: "n", label: "New"), .init(key: ",", label: "Settings")]
            }
        case .composing:
            // No `?` or `,` here: with the editor focused they type.
            return [.init(key: "^J", label: "File"), .init(key: "^S", label: "Save"), .init(key: "^T", label: "Date"),
                    .init(key: "^F", label: "Focus"), .init(key: "^P", label: "Prompt"), .init(key: "^D", label: "Discard"), .init(key: "⎋", label: "Done")]
        case .editing(_, _, _, _, _, let isDraft):
            return (isDraft ? [.init(key: "^J", label: "File")] : []) +
                [.init(key: "^S", label: "Save"), .init(key: "^T", label: "Date"), .init(key: "^F", label: "Focus"),
                 .init(key: "^P", label: "Prompt")] +
                (isDraft ? [.init(key: "^D", label: "Discard")] : []) + [.init(key: "⎋", label: "Back")]
        case .reading:
            return [.init(key: "e", label: "Edit"), .init(key: "*", label: "Star"), .init(key: "t", label: "Time"),
                    .init(key: "d", label: "Delete"), .init(key: "⎋", label: "Back"), .init(key: ",", label: "Settings")] + common
        }
    }
}

// MARK: - Pieces

/// The keys along the bottom, over a hairline. Hidden with `?`.
private struct DeskHintBar: View {
    let hints: [ShortcutHint]
    let metrics: ExternalDisplayMetrics
    @Environment(\.quire) private var q
    @AppStorage(ShortcutHints.key) private var showHints = true

    var body: some View {
        if showHints && !hints.isEmpty {
            VStack(spacing: 0) {
                Rectangle().fill(q.lineColor).frame(height: 1)
                HStack(spacing: metrics.caption * 1.7) {
                    ForEach(hints) { hint in
                        HStack(spacing: metrics.caption * 0.45) {
                            Text(hint.key).font(q.mono(metrics.caption, weight: .medium)).foregroundStyle(q.accentColor)
                            Text(q.caps(hint.label)).font(q.label(metrics.caption * 0.9)).tracking(q.isMarathon ? 1.2 : 0)
                                .foregroundStyle(q.mutedColor)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .padding(.horizontal, metrics.padding)
                .padding(.vertical, metrics.caption * 0.9)
            }
        }
    }
}

private struct DeskNotice: View {
    let title: String
    let line: String
    let metrics: ExternalDisplayMetrics
    @Environment(\.quire) private var q

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap * 0.5) {
            Spacer()
            Text(q.caps(title)).font(q.display(metrics.title * 1.4)).foregroundStyle(q.inkColor)
            Rectangle().fill(q.accentColor).frame(width: metrics.text * 3, height: max(2, q.ruleH))
            Text(line).font(q.writing(metrics.text * 0.8, italic: true)).foregroundStyle(q.mutedColor)
            Spacer()
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The eyebrow, the title and the short accent rule every desk page starts with.
struct DeskHeader: View {
    let kicker: String
    let title: String
    var trailing: String = ""
    let metrics: ExternalDisplayMetrics
    @Environment(\.quire) private var q

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.caption * 0.6) {
            HStack(alignment: .firstTextBaseline) {
                Text(q.caps(kicker)).font(q.label(metrics.caption, weight: .medium))
                    .tracking(metrics.caption * 0.16).foregroundStyle(q.mutedColor)
                Spacer(minLength: metrics.caption)
                if !trailing.isEmpty {
                    Text(trailing).font(q.mono(metrics.caption)).foregroundStyle(q.mutedColor)
                }
            }
            .lineLimit(1)
            if !title.isEmpty {
                Text(q.caps(title)).font(q.display(metrics.title * 1.25)).foregroundStyle(q.inkColor)
                    .lineLimit(2).minimumScaleFactor(0.6)
            }
            Rectangle().fill(q.accentColor).frame(width: metrics.text * 2.4, height: max(2, q.ruleH))
                .padding(.top, metrics.caption * 0.3)
        }
    }
}

// MARK: - Today (idle)

private struct DeskToday: View {
    let metrics: ExternalDisplayMetrics
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q
    @AppStorage(QuirePrompts.offsetKey, store: QuirePrompts.defaults) private var promptOffset = 0

    private var prompt: String { QuirePrompts.prompt(offset: promptOffset) }

    private var readouts: [(value: String, label: String, accent: Bool)] {
        let s = store.stats()
        return [("\(s.currentStreak)", "day streak", true),
                ("\(s.entries)", "entries", false),
                ("\(Self.short(s.words))", "words", false),
                ("\(store.inboxDrafts.count)", store.inboxDrafts.count == 1 ? "draft waiting" : "drafts waiting", store.inboxDrafts.count > 0)]
    }

    private static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fm", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)k" }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap) {
            HStack(alignment: .firstTextBaseline) {
                Text("Quire").font(q.writing(metrics.text * 0.95, italic: true))
                Spacer()
            }
            DeskHeader(kicker: QDate.longDay(), title: "Today", metrics: metrics)
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(readouts.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: metrics.caption * 0.4) {
                        Text(r.value).font(q.display(metrics.title * 1.15))
                            .foregroundStyle(r.accent ? q.accentColor : q.inkColor)
                        Text(q.caps(r.label)).font(q.label(metrics.caption)).tracking(metrics.caption * 0.12)
                            .foregroundStyle(q.mutedColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: metrics.caption * 0.6) {
                Rectangle().fill(q.lineColor).frame(height: 1)
                HStack(alignment: .firstTextBaseline, spacing: metrics.caption) {
                    Text("Begin a new entry").font(q.writing(metrics.text * 1.1))
                    Text("n").font(q.mono(metrics.caption, weight: .medium)).foregroundStyle(q.accentColor)
                }
                Text(prompt).font(q.writing(metrics.text * 0.8, italic: true)).foregroundStyle(q.mutedColor)
                    .lineLimit(2)
                Rectangle().fill(q.lineColor).frame(height: 1)
            }
            if let past = store.qOnThisDay().first {
                VStack(alignment: .leading, spacing: metrics.caption * 0.4) {
                    Text(q.caps("On this day · " + String(past.date.prefix(4))))
                        .font(q.label(metrics.caption, weight: .medium)).foregroundStyle(q.mutedColor)
                    ForEach(past.entries.prefix(2)) { entry in
                        Text(entry.qTitle.isEmpty ? "Untitled" : entry.qTitle)
                            .font(q.writing(metrics.text * 0.85)).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

    }
}

// MARK: - Browsing

/// The list as arrowed through on the keyboard, with the selected entry beside it.
private struct DeskBrowse: View {
    let listTitle: String
    let rows: [ExternalRow]
    let selected: Int
    let offset: Int
    let total: Int
    let metrics: ExternalDisplayMetrics
    @Environment(\.quire) private var q

    private var current: ExternalRow? { rows.indices.contains(selected) ? rows[selected] : nil }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 1000
            HStack(alignment: .top, spacing: metrics.padding) {
                list.frame(width: wide ? geo.size.width * 0.46 : geo.size.width - metrics.padding * 2)
                if wide, let row = current { preview(row) }
            }
            .padding(metrics.padding)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: metrics.caption) {
            DeskHeader(kicker: rows.isEmpty ? "No entries" : "\(offset + selected + 1) of \(total)", title: listTitle, metrics: metrics)
            if rows.isEmpty { Text("No entries here yet.").font(q.writing(metrics.text)).foregroundStyle(q.mutedColor) }
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if i == 0 || rows[i - 1].date.prefix(7) != row.date.prefix(7) {
                                Text(q.caps(QDate.monthYear(row.date))).font(q.label(metrics.caption, weight: .medium))
                                    .tracking(metrics.caption * 0.16).foregroundStyle(q.mutedColor)
                                    .padding(.top, i == 0 ? 0 : metrics.gap * 0.6).padding(.bottom, metrics.caption * 0.4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .overlay(alignment: .bottom) { Rectangle().fill(q.lineColor).frame(height: 1) }
                            }
                            rowView(row, on: i == selected).id(row.id)
                        }
                    }
                }
                .onChange(of: selected) { _, i in
                    if rows.indices.contains(i) { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(rows[i].id, anchor: .center) } }
                }
                .onAppear { if rows.indices.contains(selected) { proxy.scrollTo(rows[selected].id, anchor: .center) } }
            }
        }
    }

    private func rowView(_ row: ExternalRow, on: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.caption) {
            Text(QDate.shortDay(row.date).uppercased()).font(q.label(metrics.caption * 0.85)).tracking(metrics.caption * 0.1)
                .foregroundStyle(on ? q.accentColor : q.mutedColor)
                .frame(width: metrics.text * 4.6, alignment: .leading)
            Text(row.title.isEmpty ? "Untitled" : row.title)
                .font(q.writing(metrics.text * 0.78, italic: row.title.isEmpty))
                .foregroundStyle(row.title.isEmpty ? q.mutedColor : q.inkColor).lineLimit(1)
            Spacer(minLength: 0)
            if row.starred { Text("★").font(q.ui(metrics.caption)).foregroundStyle(q.accentColor) }
        }
        .padding(.vertical, metrics.caption * 0.55).padding(.horizontal, metrics.caption * 0.6)
        .background(on ? q.accentSoftColor : Color.clear)
        .overlay(alignment: .leading) { if on { Rectangle().fill(q.accentColor).frame(width: max(3, metrics.caption * 0.2)) } }
    }

    private func preview(_ row: ExternalRow) -> some View {
        VStack(alignment: .leading, spacing: metrics.caption) {
            Text(q.caps(QDate.fullDay(row.date) + (row.time.isEmpty ? "" : " · " + row.time)))
                .font(q.label(metrics.caption, weight: .medium)).tracking(metrics.caption * 0.16).foregroundStyle(q.mutedColor)
            Text(row.title.isEmpty ? "Untitled" : row.title).font(q.display(metrics.title * 0.9)).lineLimit(3)
            Rectangle().fill(q.accentColor).frame(width: metrics.text * 2, height: max(2, q.ruleH))
            Text(row.body).font(q.writing(metrics.text * 0.8)).foregroundStyle(q.inkColor.opacity(0.9))
                .lineSpacing(metrics.text * 0.25).lineLimit(14)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.leading, metrics.padding * 0.5)
        .overlay(alignment: .leading) { Rectangle().fill(q.lineColor).frame(width: 1) }
    }
}

// MARK: - An entry (reading and writing share one page)

private struct DeskEntry: View {
    let title: String
    let date: Date
    let text: String
    let isStarred: Bool
    /// Writing: the body is the editor's live text with a caret. Reading: the
    /// rendered entry, media inline.
    let live: Bool
    let caret: Int?
    let metrics: ExternalDisplayMetrics
    @Environment(\.quire) private var q

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMMM yyyy · HH:mm"; return f
    }()

    private var displayTitle: String { Entry.strippingStarMarker(title) }
    private var starred: Bool { isStarred || Entry.hasStarMarker(title) }
    private var tags: [String] { JournalParser.splitTags(title + "\n" + text) }
    private var words: Int { text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.gap) {
            DeskHeader(kicker: Self.stamp.string(from: date) + (starred ? "  ★" : ""),
                       title: displayTitle.isEmpty ? "" : displayTitle, metrics: metrics)
            bodyText.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(alignment: .firstTextBaseline) {
                Text(tags.joined(separator: "  ")).foregroundStyle(q.accentColor).lineLimit(1)
                Spacer(minLength: metrics.caption)
                Text(words == 1 ? "1 word" : "\(words) words").foregroundStyle(q.mutedColor)
            }
            .font(q.mono(metrics.caption))
        }
        .padding(metrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var bodyText: some View {
        if live {
            WritingTextEditor(text: .constant(text), fontRaw: q.editorFontName,
                              size: metrics.text, textColor: q.inkColor,
                              lineSpacing: metrics.text * 0.3, accent: q.accentColor,
                              mirror: true, mirrorCaret: caret)
        } else {
            MediaPreview(text: text, font: q.writing(metrics.text), textColor: q.inkColor, contentPadding: 0)
        }
    }

}

#endif
