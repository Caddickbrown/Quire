//
//  CommandPalette.swift
//  Quire
//
//  ⌘K, from a hardware keyboard: type a few letters and go somewhere. The same
//  behaviour and the same match as Pippin's and MiniOffice's menus, with Quire's
//  own short list. It is kept apart from anything on screen, so the rules can be
//  tested without an app: `Design/CommandMenu.swift` is the glue and the drawing.
//
//  Two rules matter. Esc always closes it, in one press, from anywhere in it. And
//  it only goes places: nothing on the list writes to the journal.
//

import Foundation

/// One key prompt: the glyph and what it does.
struct ShortcutHint: Identifiable, Equatable {
    let key: String
    let label: String
    var id: String { key + label }
}

/// The letters of `query` in order within `text`, as MiniOffice's palette matches them.
enum CommandMatch {
    /// Runs and word starts score higher, long titles a little lower. Nil when the letters aren't all there.
    static func score(_ query: String, _ text: String) -> Int? {
        let t = Array(text.lowercased())
        var score = 0, at = 0, run = 0
        for ch in query.lowercased() where ch != " " {
            var found = false
            while at < t.count {
                let here = at
                at += 1
                if t[here] == ch {
                    run += 1
                    score += 1 + run * 2 + (here == 0 || t[here - 1] == " " ? 6 : 0)
                    found = true
                    break
                }
                run = 0
            }
            if !found { return nil }
        }
        return score - t.count / 8
    }

    /// What matches, best first; equal scores keep the order they came in.
    static func rank<Item>(_ items: [Item], _ query: String, by text: (Item) -> String) -> [Item] {
        let scored = items.enumerated().compactMap { i, item in score(query, text(item)).map { (item, $0, i) } }
        return scored.sorted { ($0.1, $1.2) > ($1.1, $0.2) }.map(\.0)
    }
}

/// Everything the menu can make happen.
enum CommandAction: Equatable {
    case today, inbox, journal, search, newDraft, settings
    /// The Journal, on this day ("2026-03-14").
    case jump(String)
}

/// What the app has just now, for the menu to list.
struct CommandSources: Equatable {
    /// The days with something filed, oldest first ("2026-03-14"), with how many.
    var days: [String] = []
    var counts: [String: Int] = [:]
    var today = Date()

    init(counts: [String: Int] = [:], today: Date = Date()) {
        self.counts = counts
        self.days = counts.keys.sorted()
        self.today = today
    }

    /// The filed day closest to `day`, the later one if two are as close.
    func nearest(to day: String) -> String? {
        guard !days.isEmpty else { return nil }
        let after = days.firstIndex { $0 >= day }
        guard let after else { return days.last }
        guard after > 0, days[after] != day else { return days[after] }
        let earlier = days[after - 1], later = days[after]
        guard let target = CommandDates.date(day), let a = CommandDates.date(earlier), let b = CommandDates.date(later) else { return later }
        return target.timeIntervalSince(a) < b.timeIntervalSince(target) ? earlier : later
    }
}

/// One line of the menu.
struct CommandRow: Equatable, Identifiable {
    enum Step: Equatable {
        case run(CommandAction)
        /// A shorter list to choose from, in the same menu.
        case open(CommandPalette.Stage)
    }

    var id: String
    var title: String
    var detail: String?
    var symbol: String
    var step: Step
    /// What typing is matched against, when it isn't just the title.
    var search: String

    init(_ id: String, _ title: String, detail: String? = nil, symbol: String, step: Step, search: String? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.symbol = symbol; self.step = step
        self.search = search ?? title
    }
}

struct CommandPalette: Equatable {
    enum Stage: Equatable { case top, date }

    enum Key: CaseIterable { case esc, enter, up, down, tab, backTab, toggle }

    enum Outcome: Equatable {
        case stay, close
        /// Closed, with this to do.
        case run(CommandAction)
    }

    private(set) var stage = Stage.top
    private(set) var query = ""
    private(set) var rows: [CommandRow] = []
    /// The row the keys are on, by id, so the highlight follows the row and not a position.
    private(set) var selected: String?
    private let sources: CommandSources

    init(_ sources: CommandSources) {
        self.sources = sources
        list()
    }

    var lit: CommandRow? { rows.first { $0.id == selected } }

    /// The grey words in the box.
    var prompt: String {
        switch stage {
        case .top: "Where to?"
        case .date: "A date: 14 March, 14/3, 2026-03-14"
        }
    }

    /// Said in place of the list when nothing matches.
    var nothing: String {
        switch stage {
        case .top: "Nothing here by that name."
        case .date: "That isn't a date. Try 14 March."
        }
    }

    // MARK: typing

    mutating func type(_ text: String) {
        let clean = text.filter { !$0.isNewline && !($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) }
        guard !clean.isEmpty else { return }
        query = String((query + clean).prefix(60))
        list()
    }

    /// One letter back. With none left, back out of a shorter list.
    mutating func backspace() {
        if query.isEmpty {
            guard stage != .top else { return }
            stage = .top
        } else {
            query.removeLast()
        }
        list()
    }

    // MARK: keys

    mutating func press(_ key: Key) -> Outcome {
        switch key {
        case .esc, .toggle: return .close
        case .up, .backTab: move(-1)
        case .down, .tab: move(1)
        case .enter:
            guard let row = lit else { return .stay }
            switch row.step {
            case .run(let action): return .run(action)
            case .open(let next):
                stage = next
                query = ""
                list()
            }
        }
        return .stay
    }

    /// Down the list as it's drawn, wrapping round. With nothing lit, the first row.
    private mutating func move(_ by: Int) {
        guard !rows.isEmpty else { return }
        guard let i = rows.firstIndex(where: { $0.id == selected }) else {
            selected = rows[0].id
            return
        }
        selected = rows[(i + by + rows.count) % rows.count].id
    }

    /// Exactly the keys that do something right now.
    var hints: [ShortcutHint] {
        var out: [ShortcutHint] = []
        if rows.count > 1 { out.append(.init(key: "↑↓ ⇥", label: "Move")) }
        if lit != nil { out.append(.init(key: "↩", label: "Go")) }
        out.append(.init(key: "Type", label: "To find"))
        if !query.isEmpty { out.append(.init(key: "⌫", label: "A letter")) }
        else if stage != .top { out.append(.init(key: "⌫", label: "Back")) }
        out.append(.init(key: "⎋ ⌘K", label: "Close"))
        return out
    }

    // MARK: the list

    private mutating func list() {
        rows = listed()
        selected = rows.first?.id
    }

    private func listed() -> [CommandRow] {
        let blank = query.allSatisfy { $0 == " " }
        switch stage {
        case .top:
            return blank ? places : CommandMatch.rank(places, query, by: \.search)
        case .date:
            let found = blank ? [] : CommandDates.parse(query, today: sources.today).map { [dateRow($0)] } ?? []
            return found + (blank ? presets : CommandMatch.rank(presets, query, by: \.search))
        }
    }

    private var places: [CommandRow] {
        [CommandRow("today", "Today", symbol: "sun.max", step: .run(.today)),
         CommandRow("inbox", "Inbox", symbol: "tray", step: .run(.inbox)),
         CommandRow("journal", "Journal", symbol: "book", step: .run(.journal)),
         CommandRow("search", "Search", symbol: "magnifyingglass", step: .run(.search)),
         CommandRow("new", "New draft", symbol: "square.and.pencil", step: .run(.newDraft), search: "New draft write entry"),
         CommandRow("date", "Jump to a date", symbol: "calendar", step: .open(.date), search: "Jump to a date go day"),
         CommandRow("settings", "Settings", symbol: "gearshape", step: .run(.settings), search: "Settings preferences")]
    }

    private var presets: [CommandRow] {
        let calendar = Calendar.current
        func back(_ part: Calendar.Component, _ n: Int) -> Date {
            calendar.date(byAdding: part, value: -n, to: sources.today) ?? sources.today
        }
        return [("Today", sources.today), ("Yesterday", back(.day, 1)), ("A week ago", back(.day, 7)),
                ("A month ago", back(.month, 1)), ("A year ago", back(.year, 1))]
            .map { dateRow($0.1, title: $0.0) }
    }

    /// A day: where it would land, said before ↩ does it.
    private func dateRow(_ date: Date, title: String? = nil) -> CommandRow {
        let day = CommandDates.key(date)
        let name = CommandDates.fullDay.string(from: date)
        let count = sources.counts[day] ?? 0
        let nearest = sources.nearest(to: day)
        let detail: String
        if count > 0 { detail = (title == nil ? "" : name + " · ") + (count == 1 ? "1 entry" : "\(count) entries") }
        else if let nearest, let other = CommandDates.date(nearest) { detail = "Nothing that day: opens " + CommandDates.fullDay.string(from: other) }
        else { detail = "Nothing is filed yet" }
        return CommandRow("day:\(title ?? "typed"):\(day)", title ?? name, detail: detail, symbol: "calendar",
                          step: .run(.jump(nearest ?? day)))
    }
}

/// A time as typed on the monitor's date picker: `9`, `14`, `930`, `1430`,
/// `14:30`, `14.30`. Nil for anything that isn't one.
enum TypedTime {
    static func parse(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "." }).map(String.init)
        guard parts.count <= 2, let first = parts.first, parts.allSatisfy({ $0.allSatisfy(\.isASCII) }) else { return nil }
        let hour: Int?, minute: Int?
        if parts.count == 2 || text.last == ":" || text.last == "." {
            guard first.count <= 2, (parts.count < 2 || parts[1].count <= 2) else { return nil }
            hour = Int(first); minute = parts.count == 2 ? Int(parts[1]) : 0
        } else {
            switch first.count {
            case 1, 2: hour = Int(first); minute = 0
            case 3, 4: hour = Int(first.dropLast(2)); minute = Int(first.suffix(2))
            default: return nil
            }
        }
        guard let hour, let minute, (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }
}

/// The dates the menu reads and writes.
enum CommandDates {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = format; return f
    }
    private static let iso = formatter("yyyy-MM-dd")
    static let fullDay = formatter("EEEE d MMMM yyyy")

    static func key(_ date: Date) -> String { iso.string(from: date) }
    static func date(_ key: String) -> Date? { iso.date(from: key) }

    /// A day as typed: `2026-03-14`, `14/3/2026`, `14/3`, `14 March`, `14th mar 25`,
    /// `March 14`, `March 2025`, `2026-03`. With no year, the latest one that isn't
    /// in the future: this is a journal, so the 14th of December in March means last
    /// December's. Day first, as Quire writes dates everywhere else.
    static func parse(_ text: String, today: Date = Date(), calendar: Calendar = .current) -> Date? {
        let words = text.lowercased().split(whereSeparator: { " ,".contains($0) }).map(String.init)
        let numbers = text.split(whereSeparator: { "-/.".contains($0) }).map(String.init)
        var day: Int?, month: Int?, year: Int?
        if words.count == 1, numbers.count >= 2, numbers.allSatisfy({ Int($0) != nil }) {
            if numbers[0].count == 4 {   // 2026-03-14, 2026-03
                guard numbers.count <= 3 else { return nil }
                year = Int(numbers[0]); month = Int(numbers[1]); day = numbers.count == 3 ? Int(numbers[2]) : 1
            } else {                     // 14/3, 14/3/2026
                guard numbers.count <= 3 else { return nil }
                day = Int(numbers[0]); month = Int(numbers[1]); year = numbers.count == 3 ? fullYear(numbers[2]) : nil
            }
        } else {
            for word in words {
                if let m = monthNumber(word), month == nil { month = m; continue }
                let digits = word.prefix { $0.isNumber }
                guard let n = Int(digits), ["", "st", "nd", "rd", "th"].contains(word.dropFirst(digits.count)) else { return nil }
                if digits.count == 4 { year = n }
                else if day == nil { day = n }
                else if year == nil { year = fullYear(String(digits)) }
                else { return nil }
            }
            guard month != nil else { return nil }
            if day == nil { guard year != nil else { return nil }; day = 1 }   // March 2025
        }
        guard let day, let month else { return nil }
        func make(_ year: Int) -> Date? {
            let parts = DateComponents(year: year, month: month, day: day, hour: 12)
            guard let date = calendar.date(from: parts), calendar.component(.day, from: date) == day,
                  calendar.component(.month, from: date) == month else { return nil }
            return date
        }
        if let year { return make(year) }
        let now = calendar.component(.year, from: today)
        guard let this = make(now) else { return make(now - 1) }
        return calendar.startOfDay(for: this) > today ? make(now - 1) : this
    }

    private static func fullYear(_ text: String) -> Int? {
        guard let n = Int(text) else { return nil }
        return text.count <= 2 ? 2000 + n : n
    }

    private static func monthNumber(_ word: String) -> Int? {
        guard word.count >= 3 else { return nil }
        let names = formatter("MMMM").monthSymbols.map { $0.lowercased() }
        return names.firstIndex { $0.hasPrefix(word) }.map { $0 + 1 }
    }
}
