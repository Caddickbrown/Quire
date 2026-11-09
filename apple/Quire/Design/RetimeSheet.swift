//
//  RetimeSheet.swift
//  Quire
//
//  Change when an entry happened. Tap any time in the app to get here; an
//  entry that moves to another day is filed there.
//
//  With a monitor in desk mode the keys (`t`, ^t) open `DeskDatePicker`
//  instead: a calendar drawn on the monitor and worked from the keyboard alone,
//  since the phone's graphical picker is neither on screen nor keyboard-driven
//  there. A tap on the phone still opens the sheet.
//

#if os(iOS)

import SwiftUI

struct RetimeSheet: View {
    @EnvironmentObject private var store: JournalStore
    @Environment(\.quire) private var q
    @Environment(\.dismiss) private var dismiss

    let ref: EntryRef
    var onUpdate: (EntryRef) -> Void = { _ in }
    @State private var error: String?
    @State private var date: Date

    init(ref: EntryRef, onUpdate: @escaping (EntryRef) -> Void = { _ in }) {
        self.onUpdate = onUpdate
        self.ref = ref
        _date = State(initialValue: JournalStore.date(from: ref.entry.ts) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                QLink(title: "Cancel") { dismiss() }
                Spacer()
                QLink(title: "Save", emphasised: true, action: save)
            }
            QTitle(kicker: "Change date and time", title: "When", size: 34)
            Text(ref.entry.qTitle.isEmpty ? "Untitled" : ref.entry.qTitle)
                .font(q.writing(18, italic: true)).foregroundStyle(q.mutedColor).lineLimit(2)
            DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical).labelsHidden().tint(q.accentColor)
            Text("Now \(ref.entry.ts)  →  \(JournalStore.ts(from: date))")
                .font(q.mono(12)).foregroundStyle(q.mutedColor)
            if let error { Text(error).font(q.ui(14)).foregroundStyle(q.accentColor) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26).padding(.top, 16)
        .background(q.pageColor.ignoresSafeArea())
        .preferredColorScheme(q.colorScheme)
        .environment(\.colorScheme, q.colorScheme)
        .presentationDetents([.large])
    }

    private func save() {
        if let failed = Self.retime(ref, to: date, in: store, onUpdate: onUpdate) {
            error = failed
            return
        }
        dismiss()
    }

    /// Write `ref` at `date`'s time. Nil when it landed (or nothing changed),
    /// otherwise what to tell the user.
    static func retime(_ ref: EntryRef, to date: Date, in store: JournalStore,
                       onUpdate: (EntryRef) -> Void) -> String? {
        let entry = ref.entry
        let ts = JournalStore.ts(from: date)
        guard ts != entry.ts else { return nil }
        let text = JournalStore.makeEntry(timestamp: ts, title: entry.suffix, body: entry.body).raw
        guard let result = store.saveEditorEntry(entry, source: ref.source, text: text) else {
            return store.lastWriteError ?? "The date could not be saved. Please try again."
        }
        // Not an autosave: the screens catch up now, not after typing rests.
        store.settlePendingRebuild()
        onUpdate(EntryRef(entry: result.entry, source: result.source))
        return nil
    }
}

// MARK: - On the monitor

/// The date picker of desk mode: a month on the monitor, worked from the
/// keyboard as Graft's due calendar is. ← → a day, ↑ ↓ a week, [ ] a month,
/// t today, - = the time by a quarter of an hour, digits type an exact time, ↵
/// sets, Esc cancels. The time of day is kept through every move but those. It
/// is drawn in the monitor's own look: `DeskDateOverlay` on Quire's pages,
/// `VSDatePicker` in hidden mode. A singleton, like
/// `ExternalSettingsModel`, because the monitor's window can't reach the
/// app scene's views.
@MainActor final class DeskDatePicker: ObservableObject {
    static let shared = DeskDatePicker()

    @Published private(set) var isOpen = false
    /// What ↵ would set: the day the arrows are on, at the time shown.
    @Published private(set) var date = Date()
    /// When the entry is now, marked on the calendar.
    @Published private(set) var original = Date()
    @Published private(set) var title = ""
    /// A write that failed: said on the card, which stays up.
    @Published private(set) var error: String?
    /// A time being typed, as far as it's got ("14:3"). Empty otherwise.
    @Published private(set) var typed = ""

    /// The time as it should read: what's being typed, else the time ↵ would set.
    var timeText: String { typed.isEmpty ? Self.clock.string(from: date) : typed }

    /// How the time changes, for the card.
    static let timePrompt = "- = move it 15 minutes, or type a time: 14:30"

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"; return f
    }()

    /// `date` before the first digit, for ⌫ to come back to.
    private var beforeTyping: Date?
    private var onSet: ((Date) -> String?)?
    private var onClose: (() -> Void)?
    private let routerID = UUID()

    /// The keys open this rather than the phone's sheet only while the monitor
    /// is showing things: not paused, not behind App Lock.
    var isAvailable: Bool {
        let monitor = ExternalDisplayModel.shared
        return monitor.isConnected && !monitor.isPaused && !AppLockManager.shared.showsVeil
    }

    /// ⌫, which reaches us as a key command like any other.
    private static let backspace = "\u{8}"

    /// The keys besides the arrows, ↵ and Esc.
    static let letters = ["[", "]", "-", "=", "+", ":", ".", backspace] + (0...9).map(String.init)

    /// `onSet` writes the new time and returns an error to show, or nil to close.
    /// `onClose` runs however it closes (to hand the keyboard back).
    func open(date: Date, title: String, onSet: @escaping (Date) -> String?, onClose: (() -> Void)? = nil) {
        ExternalSettingsModel.shared.close()
        self.date = date
        original = date
        self.title = title
        error = nil
        typed = ""
        beforeTyping = nil
        self.onSet = onSet
        self.onClose = onClose
        isOpen = true
        KeyCommandRouter.shared.register(routerID, QuireKeyHandlers(
            moveUp: { [weak self] in self?.move(days: -7) },
            moveDown: { [weak self] in self?.move(days: 7) },
            open: { [weak self] in self?.confirm() },
            clear: { [weak self] in self?.cancel() },
            // Every letter is the picker's while it is up, so nothing beneath
            // (delete, file, a new page) fires behind it.
            key: { [weak self] k in self?.key(k); return true },
            sideways: { [weak self] in self?.move(days: $0) },
            letters: Self.letters))
    }

    func cancel() { close() }

    private func confirm() {
        guard isOpen else { return }
        guard typed.isEmpty || TypedTime.parse(typed) != nil else {
            error = "That isn't a time. Try 14:30."
            return
        }
        if let failed = onSet?(date) { error = failed; return }
        close()
    }

    private func close() {
        guard isOpen else { return }
        isOpen = false
        KeyCommandRouter.shared.unregister(routerID)
        onSet = nil
        let done = onClose
        onClose = nil
        done?()
    }

    private func key(_ k: String) {
        if k == Self.backspace || (k.count == 1 && "0123456789:.".contains(k)) {
            typeTime(k)
            error = nil
            return
        }
        let calendar = Calendar.current
        typed = ""
        switch k {
        case "[", "]":
            date = calendar.date(byAdding: .month, value: k == "]" ? 1 : -1, to: date) ?? date
        case "t":
            // Today, at the entry's time of day.
            let time = calendar.dateComponents([.hour, .minute, .second], from: date)
            date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                                 second: time.second ?? 0, of: Date()) ?? date
        case "-":
            date = calendar.date(byAdding: .minute, value: -15, to: date) ?? date
        case "=", "+":
            date = calendar.date(byAdding: .minute, value: 15, to: date) ?? date
        case "j": move(days: 7)
        case "k": move(days: -7)
        default: break
        }
        error = nil
    }

    private func move(days: Int) {
        date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        typed = ""
        error = nil
    }

    /// The time follows the digits as they come: `1`, `14`, `143`, `1430` read as
    /// 01:00, 14:00, 01:43 and 14:30. What isn't a time leaves it alone, and ↵
    /// says so rather than setting something else.
    private func typeTime(_ k: String) {
        if k == Self.backspace {
            guard !typed.isEmpty else { return }
            typed.removeLast()
        } else {
            guard typed.count < 5, k.first?.isNumber == true || !typed.isEmpty else { return }
            if typed.isEmpty { beforeTyping = date }
            typed += k
        }
        if typed.isEmpty, let beforeTyping {
            date = beforeTyping
        } else if let time = TypedTime.parse(typed) {
            date = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: date) ?? date
        }
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

#endif
