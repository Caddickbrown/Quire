//
//  DeskViews.swift
//  Quire
//
//  The monitor, in Quire's own design. A plugged-in display is a desk mode: it
//  follows the phone's theme, sets everything in the same type and rules, and is
//  driven from the keyboard alone: Today when nothing is open, the list and a
//  preview while browsing, the page itself when reading or writing, a
//  settings list on `,`, and a calendar over the page while a date is changed. Sizes come from `ExternalDisplayMetrics`, so a desk
//  monitor and a TV across the room both read.
//

#if os(iOS)

import SwiftUI

// MARK: - The window shown on the monitor

struct ExternalDisplayRoot: View {
    @ObservedObject private var model = ExternalDisplayModel.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @ObservedObject private var settings = ExternalSettingsModel.shared
    @ObservedObject private var datePicker = DeskDatePicker.shared
    @ObservedObject private var confirm = DeskConfirm.shared
    @AppStorage(QuireTheme.storageKey) private var themeID = QuireTheme.auto
    @AppStorage(ExternalTheme.key) private var monitorTheme = ExternalTheme.followPhone
    @AppStorage(ExternalTextSize.key) private var textSizeRaw = ExternalTextSize.regular.rawValue

    var body: some View {
        if monitorTheme == ExternalTheme.vsCode {
            DeskCode(store: model.store, hints: hints,
                     scale: (ExternalTextSize(rawValue: textSizeRaw) ?? .regular).scale)
                // The calendar in the phone's theme over the editor's window.
                .overlay {
                    let q = QuireTheme.resolve(themeID, scheme: model.colorScheme)
                    GeometryReader { geo in
                        DeskDateOverlay(metrics: ExternalDisplayMetrics(size: geo.size,
                            scale: (ExternalTextSize(rawValue: textSizeRaw) ?? .regular).scale))
                    }
                    .environment(\.quire, q).foregroundStyle(q.inkColor)
                }
        } else {
            desk
        }
    }

    @ViewBuilder private var desk: some View {
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
                            .overlay { DeskDateOverlay(metrics: metrics) }
                            .overlay { DeskConfirmOverlay(metrics: metrics) }
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
            case .composing(let title, let date, let text, let caret, let inTitle):
                DeskEntry(title: title, date: date, text: text, isStarred: false, live: true, caret: caret,
                          inTitle: inTitle, metrics: metrics)
            case .editing(let title, let date, let text, let caret, let isStarred, _, let inTitle):
                DeskEntry(title: title, date: date, text: text, isStarred: isStarred, live: true, caret: caret,
                          inTitle: inTitle, metrics: metrics)
            case .reading(let title, let date, let text, let isStarred):
                DeskEntry(title: title, date: date, text: text, isStarred: isStarred, live: false, caret: nil, metrics: metrics)
            }
        }
    }

    /// Which keys are live right now. Shown on the monitor because the phone is
    /// dimmed; the same keys as the terminal app.
    private var hints: [ShortcutHint] {
        // A question on the monitor takes every key but these two.
        if let question = confirm.request {
            return [.init(key: "↩", label: question.action), .init(key: "⎋", label: "Cancel")]
        }
        if datePicker.isOpen {
            return [.init(key: "←→", label: "Day"), .init(key: "↑↓", label: "Week"), .init(key: "[ ]", label: "Month"),
                    .init(key: "t", label: "Today"), .init(key: "- =", label: "Time"), .init(key: "↩", label: "Set"),
                    .init(key: "⎋", label: "Cancel")]
        }
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
            let random = ShortcutHint(key: "r", label: "Random")
            switch listTitle {
            case "Inbox":
                // A random draft, as the Inbox's own Random does.
                return base + [random, .init(key: "f", label: "File"), .init(key: "e", label: "Edit"), .init(key: "*", label: "Star"),
                               .init(key: "t", label: "Time"), .init(key: "d", label: "Delete"), .init(key: ",", label: "Settings")]
            case "Journal":
                return base + [random, .init(key: "e", label: "Edit"), .init(key: "u", label: "Inbox"), .init(key: "*", label: "Star"),
                               .init(key: "d", label: "Delete"), .init(key: ",", label: "Settings")]
            case "Search":
                // The search sheet keeps the app's letters away (they type).
                return base
            default:
                return base + [random, .init(key: "n", label: "New"), .init(key: ",", label: "Settings")]
            }
        case .composing:
            // No `?` or `,` here: with the editor focused they type.
            return [.init(key: "^J", label: "File"), .init(key: "^S", label: "Save"), .init(key: "^T", label: "Date"),
                    .init(key: "^F", label: "Focus"), .init(key: "^P", label: "Prompt"), .init(key: "^D", label: "Discard"), .init(key: "⎋", label: "Done")]
        case .editing(_, _, _, _, _, let isDraft, _):
            return (isDraft ? [.init(key: "^J", label: "File")] : []) +
                [.init(key: "^S", label: "Save"), .init(key: "^T", label: "Date"), .init(key: "^F", label: "Focus"),
                 .init(key: "^P", label: "Prompt")] +
                (isDraft ? [.init(key: "^D", label: "Discard")] : []) + [.init(key: "⎋", label: "Back")]
        case .reading:
            return [.init(key: "e", label: "Edit"), .init(key: "r", label: "Random"), .init(key: "*", label: "Star"),
                    .init(key: "t", label: "Time"), .init(key: "d", label: "Delete"), .init(key: "⎋", label: "Back"),
                    .init(key: ",", label: "Settings")] + common
        }
    }
}

// MARK: - Confirmations

/// A question the keyboard answers on the monitor: "Delete this draft?" over the
/// page, ↵ to go ahead, Esc to cancel. The phone's confirmation dialogs sit on the
/// dimmed phone in desk mode, where the hardware keyboard can't answer them, so
/// while the monitor is available (`isAvailable`, as the date picker) every
/// confirmation asks here instead; without one the phone's dialogs are untouched.
/// While it is up it takes every key, so nothing beneath acts behind it.
/// Unplugging, pausing or locking cancels it. A singleton, like `DeskDatePicker`,
/// because the monitor's window can't reach the app scene's views.
@MainActor final class DeskConfirm: ObservableObject {
    static let shared = DeskConfirm()

    struct Request: Equatable {
        /// The page it was asked from ("Inbox"), over the question.
        var kicker: String
        var question: String
        /// What it is about: the entry's title or first line.
        var detail: String = ""
        /// When that entry is, beside the kicker.
        var when: String = ""
        /// What happens, when the question doesn't say.
        var note: String = ""
        /// ↵'s word: "Delete", "Discard".
        var action: String
    }

    @Published private(set) var request: Request?
    /// A write that failed: said on the panel, which stays up.
    @Published private(set) var error: String?
    var isOpen: Bool { request != nil }

    private var onConfirm: (() -> String?)?
    private var onClose: (() -> Void)?
    private var owner: UUID?
    private let routerID = UUID()

    /// The monitor is showing things: connected, not paused, not behind App Lock.
    var isAvailable: Bool { DeskDatePicker.shared.isAvailable }

    /// Ask on the monitor if it is available, and say whether it did: false
    /// leaves the caller to ask on the phone as before. `onConfirm` does the
    /// thing and returns an error to show, or nil to close; `onClose` runs
    /// however it closes. `owner` lets a page cancel only its own question.
    @discardableResult
    func ask(_ request: Request, owner: UUID? = nil, onConfirm: @escaping () -> String?,
             onClose: (() -> Void)? = nil) -> Bool {
        guard isAvailable else { return false }
        open(request, owner: owner, onConfirm: onConfirm, onClose: onClose)
        return true
    }

    func open(_ request: Request, owner: UUID? = nil, onConfirm: @escaping () -> String?,
              onClose: (() -> Void)? = nil) {
        DeskDatePicker.shared.cancel()
        ExternalSettingsModel.shared.close()
        close()
        self.request = request
        error = nil
        self.owner = owner
        self.onConfirm = onConfirm
        self.onClose = onClose
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: {}, moveDown: {},
            open: { [weak self] in self?.confirm() },
            clear: { [weak self] in self?.cancel() },
            // Every letter is the panel's while it is up: a second `d`, `f` or
            // `n` beneath it never fires.
            key: { _ in true }))
    }

    func cancel() { close() }

    /// Cancel only if `owner` asked it (a page going away).
    func cancel(owner: UUID) { if self.owner == owner { close() } }

    private func confirm() {
        guard isOpen, let run = onConfirm else { return }
        if let failed = run() { error = failed; return }
        close()
    }

    private func close() {
        guard isOpen else { return }
        request = nil
        error = nil
        owner = nil
        KeyCommandRouter.shared.unregister(routerID)
        onConfirm = nil
        let done = onClose
        onClose = nil
        done?()
    }

    /// An entry as the panel names it: its title, else its first line.
    static func describe(_ entry: Entry) -> String {
        entry.qTitle.isEmpty ? "Untitled" : entry.qTitle
    }

    static func when(_ entry: Entry) -> String {
        "\(QDate.shortDay(entry.date)) · \(QDate.time(entry.ts))"
    }
}

/// `DeskConfirm`'s question over the page, in Quire's design: the question, the
/// entry it is about, and the two keys that answer it.
private struct DeskConfirmOverlay: View {
    let metrics: ExternalDisplayMetrics
    @ObservedObject private var confirm = DeskConfirm.shared
    @ObservedObject private var model = ExternalDisplayModel.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @Environment(\.quire) private var q

    var body: some View {
        if let request = confirm.request, !model.isPaused, !appLock.showsVeil {
            ZStack {
                q.pageColor.opacity(0.82)
                card(request)
            }
            .transition(.opacity)
        }
    }

    private func card(_ r: DeskConfirm.Request) -> some View {
        VStack(alignment: .leading, spacing: metrics.gap * 0.7) {
            DeskHeader(kicker: r.kicker, title: r.question, trailing: r.when, metrics: metrics)
            if !r.detail.isEmpty {
                Text(r.detail).font(q.writing(metrics.text * 0.9, italic: true)).foregroundStyle(q.inkColor)
                    .lineLimit(2)
            }
            if !r.note.isEmpty {
                Text(r.note).font(q.ui(metrics.caption)).foregroundStyle(q.mutedColor).lineLimit(2)
            }
            if let error = confirm.error {
                Text(error).font(q.ui(metrics.caption)).foregroundStyle(q.accentColor).lineLimit(3)
            }
            Rectangle().fill(q.lineColor).frame(height: 1)
            HStack(spacing: metrics.gap) {
                key("↩", r.action, emphasised: true)
                key("⎋", "Cancel", emphasised: false)
                Spacer(minLength: 0)
            }
        }
        .padding(metrics.padding * 0.6)
        .frame(width: min(metrics.text * 20, 900))
        .background(q.pageColor)
        .overlay(Rectangle().strokeBorder(q.lineColor, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: metrics.gap, y: metrics.gap * 0.3)
    }

    private func key(_ glyph: String, _ label: String, emphasised: Bool) -> some View {
        HStack(spacing: metrics.caption * 0.5) {
            Text(glyph).font(q.mono(metrics.caption, weight: .medium))
            Text(q.caps(label)).font(q.ui(metrics.text * 0.7, weight: emphasised ? .semibold : .regular))
        }
        .foregroundStyle(emphasised ? q.onSignalColor : q.inkColor)
        .padding(.horizontal, metrics.caption * 0.9).padding(.vertical, metrics.caption * 0.45)
        .background(emphasised ? q.signalColor : Color.clear)
        .overlay(Rectangle().strokeBorder(emphasised ? Color.clear : q.lineColor, lineWidth: 1))
    }
}

// MARK: - Pieces

/// The date picker of desk mode (`DeskDatePicker`), over whatever page is up:
/// a month on the day ↵ would set, today ringed, the entry's day dotted, and
/// the time beneath. Drawn only here; the phone shows nothing of it.
private struct DeskDateOverlay: View {
    let metrics: ExternalDisplayMetrics
    @ObservedObject private var picker = DeskDatePicker.shared
    @ObservedObject private var model = ExternalDisplayModel.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @Environment(\.quire) private var q

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = format; return f
    }
    private static let day = formatter("EEEE d MMMM yyyy")
    private static let month = formatter("MMMM yyyy")
    private static let time = formatter("HH:mm")

    var body: some View {
        if picker.isOpen, !model.isPaused, !appLock.showsVeil {
            ZStack {
                q.pageColor.opacity(0.82)
                card
            }
            .transition(.opacity)
        }
    }

    private var card: some View {
        let calendar = Calendar.current
        let chosen = picker.date
        let days = Self.grid(for: chosen, calendar: calendar)
        let month = calendar.component(.month, from: chosen)
        let cell = metrics.text * 1.9
        return VStack(alignment: .leading, spacing: metrics.gap * 0.7) {
            DeskHeader(kicker: "Change date and time", title: "When", metrics: metrics)
            Text(picker.title.isEmpty ? "Untitled" : picker.title)
                .font(q.writing(metrics.text * 0.8, italic: true)).foregroundStyle(q.mutedColor).lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text(q.caps(Self.month.string(from: chosen))).font(q.display(metrics.text * 1.05))
                Spacer(minLength: metrics.caption)
                Text(Self.time.string(from: chosen)).font(q.mono(metrics.text * 1.05, weight: .medium))
                    .foregroundStyle(q.accentColor)
            }
            VStack(spacing: metrics.caption * 0.2) {
                HStack(spacing: 0) {
                    ForEach(Array(Self.weekdayInitials(calendar).enumerated()), id: \.offset) { _, initial in
                        Text(initial).frame(width: cell)
                    }
                }
                .font(q.label(metrics.caption, weight: .medium)).foregroundStyle(q.mutedColor)
                ForEach(0..<6, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(days[(week * 7)..<(week * 7 + 7)], id: \.self) { date in
                            dayCell(date, size: cell,
                                    selected: calendar.isDate(date, inSameDayAs: chosen),
                                    isToday: calendar.isDateInToday(date),
                                    isOriginal: calendar.isDate(date, inSameDayAs: picker.original),
                                    inMonth: calendar.component(.month, from: date) == month)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(q.lineColor).frame(height: 1)
            Text(Self.day.string(from: chosen) + " · " + Self.time.string(from: chosen))
                .font(q.writing(metrics.text * 0.8))
            Text("Now \(JournalStore.ts(from: picker.original))  →  \(JournalStore.ts(from: chosen))")
                .font(q.mono(metrics.caption)).foregroundStyle(q.mutedColor).lineLimit(1).minimumScaleFactor(0.7)
            if let error = picker.error {
                Text(error).font(q.ui(metrics.caption)).foregroundStyle(q.accentColor).lineLimit(2)
            }
        }
        .padding(metrics.padding * 0.6)
        .frame(width: cell * 7 + metrics.padding * 1.2)
        .background(q.pageColor)
        .overlay(Rectangle().strokeBorder(q.lineColor, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: metrics.gap, y: metrics.gap * 0.3)
    }

    private func dayCell(_ date: Date, size: CGFloat, selected: Bool, isToday: Bool,
                         isOriginal: Bool, inMonth: Bool) -> some View {
        ZStack {
            if selected {
                Circle().fill(q.accentColor)
            } else if isToday {
                Circle().strokeBorder(q.accentColor, lineWidth: max(2, metrics.caption * 0.12))
            }
            Text("\(Calendar.current.component(.day, from: date))")
                .font(q.mono(metrics.text * 0.75, weight: selected || isToday ? .medium : .regular))
                .foregroundStyle(selected ? q.onAccentColor : inMonth ? q.inkColor : q.faintColor)
            if isOriginal && !selected {
                Circle().fill(q.accentColor).frame(width: size * 0.12, height: size * 0.12).offset(y: size * 0.3)
            }
        }
        .frame(width: size * 0.9, height: size * 0.9)
        .frame(width: size, height: size)
    }

    /// Six weeks from the start of the week the month starts in.
    static func grid(for date: Date, calendar: Calendar) -> [Date] {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let lead = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        // Noon, so a daylight-saving change never lands a cell on the wrong day.
        let first = calendar.date(byAdding: .day, value: -lead, to: start).flatMap {
            calendar.date(bySettingHour: 12, minute: 0, second: 0, of: $0)
        } ?? start
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: first) ?? first }
    }

    static func weekdayInitials(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }
}

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
                // Every key must show: a long list at a large size steps down
                // rather than running off the edge.
                ViewThatFits(in: .horizontal) {
                    row(size: metrics.caption, gap: 1.7)
                    row(size: metrics.caption * 0.85, gap: 1.1)
                    row(size: metrics.caption * 0.72, gap: 0.8)
                }
                .padding(.horizontal, metrics.padding)
                .padding(.vertical, metrics.caption * 0.9)
            }
        }
    }
}

extension DeskHintBar {
    fileprivate func row(size: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: size * gap) {
            ForEach(hints) { hint in
                HStack(spacing: size * 0.45) {
                    Text(hint.key).font(q.mono(size, weight: .medium)).foregroundStyle(q.accentColor)
                    Text(q.caps(hint.label)).font(q.label(size * 0.9)).tracking(q.isMarathon ? 1.2 : 0)
                        .foregroundStyle(q.mutedColor)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
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
                        if !entry.tags.isEmpty {
                            Text(entry.qTagLine).font(q.mono(metrics.caption)).foregroundStyle(q.accentColor).lineLimit(1)
                        }
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
    /// The phone's cursor is in the title field: the caret is drawn there.
    var inTitle = false
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
            if live && inTitle {
                titleBeingWritten
            } else {
                DeskHeader(kicker: Self.stamp.string(from: date) + (starred ? "  ★" : ""),
                           title: displayTitle.isEmpty ? "" : displayTitle, metrics: metrics)
            }
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

    /// The header while the title is being typed: the title as it stands (or
    /// the field's "Title" placeholder) with a blinking caret after it, as the
    /// body has its own.
    private var titleBeingWritten: some View {
        VStack(alignment: .leading, spacing: metrics.caption * 0.6) {
            Text(q.caps(Self.stamp.string(from: date) + (starred ? "  ★" : "")))
                .font(q.label(metrics.caption, weight: .medium))
                .tracking(metrics.caption * 0.16).foregroundStyle(q.mutedColor).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 0.55)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
                if displayTitle.isEmpty {
                    // Before the placeholder, where the phone's cursor sits.
                    HStack(spacing: metrics.caption * 0.3) {
                        Rectangle().fill(q.accentColor)
                            .frame(width: max(2, metrics.title * 0.08), height: metrics.title * 1.25)
                            .opacity(on ? 1 : 0)
                        Text("Title").font(q.display(metrics.title * 1.25)).foregroundStyle(q.faintColor)
                    }
                } else {
                    // After the words, wrapping with them.
                    (Text(q.caps(displayTitle)).foregroundColor(q.inkColor)
                        + Text("|").foregroundColor(q.accentColor.opacity(on ? 1 : 0)))
                        .font(q.display(metrics.title * 1.25))
                }
            }
            .lineLimit(2).minimumScaleFactor(0.6)
            Rectangle().fill(q.accentColor).frame(width: metrics.text * 2.4, height: max(2, q.ruleH))
                .padding(.top, metrics.caption * 0.3)
        }
    }

    @ViewBuilder private var bodyText: some View {
        if live {
            WritingTextEditor(text: .constant(text), fontRaw: q.editorFontName,
                              size: metrics.text, textColor: q.inkColor,
                              lineSpacing: metrics.text * 0.3, accent: q.accentColor,
                              mirror: true, mirrorCaret: inTitle ? nil : caret)
        } else {
            MediaPreview(text: text, font: q.writing(metrics.text), textColor: q.inkColor, contentPadding: 0,
                         mediaScale: max(1, metrics.text / 20))
        }
    }

}

#endif
