//
//  QuireCommands.swift
//  Quire
//
//  Everything Quire can do, as the ⌘K menu lists it: every action, in every
//  place (App Kit's MONITOR.md). The menu itself (its keys, recents, steps,
//  previews) is the kit's, `kit/swift/CommandPalette.swift`; this is Quire's
//  list, built from a plain `QuireCommandState`, with no UIKit, so the tests
//  build it exactly as the app does. `Design/CommandMenu.swift` makes the state
//  from what's on screen and does what each command says.
//

import Foundation

/// One key prompt: the glyph and what it does.
struct ShortcutHint: Identifiable, Equatable {
    let key: String
    let label: String
    var id: String { key + label }
}

/// What Esc does on the monitor, as the hint bar says it. Each press takes one step:
/// an open entry goes back to the list it came from, and a list goes to Today.
enum DeskEscape {
    case entry, list, sheet

    var hint: ShortcutHint {
        switch self {
        case .entry: return ShortcutHint(key: "⎋", label: "Back")
        case .list: return ShortcutHint(key: "⎋", label: "Today")
        case .sheet: return ShortcutHint(key: "⎋", label: "Close")
        }
    }
}

/// The monitor's look after ⌘K's Dark or Light mode: it follows the phone,
/// unless it's in disguise (hidden mode's VS Code), which it keeps, or the
/// monitor would show Quire's own page with the journal on it. The ids are
/// `ExternalTheme.followPhone` and `ExternalTheme.vsCode`.
enum MonitorThemeRule {
    static let followPhone = "phone"
    static let disguise = "vscode"
    static func afterDarkOrLight(_ current: String?) -> String {
        current == disguise ? disguise : followPhone
    }
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

// MARK: - What the menu can make happen

/// A value a setting can be set to.
enum QuirePref: Equatable {
    case bool(Bool), int(Int), double(Double), string(String)
}

/// The settings the menu writes, by the keys the app keeps them under.
enum QuirePrefKey {
    static let theme = "quireTheme"
    static let prompts = "writingPrompts"
    static let goalOn = "wordGoalEnabled"
    static let goal = "wordGoal"
    static let fontSize = "fontSize"
    static let typewriter = "typewriterScroll"
    static let focusParagraph = "focusParagraph"
    static let autoTranscribe = "autoTranscribe"
    static let reminder = "dailyReminder"
    static let weekly = "weeklyResurfacing"
    static let weeklyDay = "weeklyResurfacingWeekday"
    static let weeklyHour = "weeklyResurfacingHour"
    static let appLock = "appLock"
    static let appLockGrace = "appLockGraceSeconds"
    static let spotlight = "spotlightIndexing"
    static let dataSaver = "dataSaver"
    static let splitTags = "splitTags"
    static let backupInterval = "backupInterval"
    static let backupKeep = "backupKeepCount"
    static let monitorTheme = "deskMonitorTheme"
    static let monitorTextSize = "externalDisplayTextSize"
    static let monitorHints = "showShortcutHints"
    static let dimPhone = "dimWithExternalDisplay"
    static let dimLevel = "externalDisplayDimLevel"
    static let mediaSort = "assetSort"
    static let mediaGroup = "assetGrouping"
}

/// What can be done to the entry that's open or selected.
enum QuireEntryAction: String, Equatable {
    case open, edit, star, unstar, file, unfile, retime, delete, close
}

/// What can be done on the page being written, without closing it.
enum QuireComposerAction: String, Equatable {
    case finish, save, retime, focus, prompt, star, voice
    case photoLibrary, takePhoto, video, file
    case discard, close
    /// The save failed: the ways on.
    case retry, copyToInbox, copyText, closeKeeping
}

/// Settings → Macros.
enum QuireMacro: String, Equatable, CaseIterable {
    case cleanUp, sortInbox, fileAll, transfer, conflicts, mergeExSplit, compressMedia, transcribeAll, clearOrphans
}

enum QuireCommand: Equatable {
    case today, inbox, journal, lookBack, search, settings, newDraft
    case searchFor(String)
    /// A page of Settings on the phone, by `SettingsGroup`'s raw value.
    case settingsPage(String)
    /// The Media Library, perhaps showing one kind ("image", "video", "audio") or finding a name.
    case media(kind: String?, find: String?)
    /// The Journal, on this day ("2026-03-14").
    case jump(String)
    case randomEntry, randomDraft
    /// An entry by its id, from Open entry….
    case openEntry(String)
    /// The Journal shows this split journal, or the main one.
    case splitJournal(String?)
    case starredOnly(Bool)
    case sidebar(collapsed: Bool)
    case writeLine(String)
    case anotherPrompt
    /// The selected or open entry, by id.
    case entry(QuireEntryAction, String)
    case composer(QuireComposerAction)
    case saveSearch(String)
    case removeSearch(String)
    /// A setting: written, and whatever follows from it done.
    case pref(String, QuirePref)
    case darkMode(Bool)
    case reminderTime(hour: Int, minute: Int)
    case pauseMonitor
    case backupNow
    case macro(QuireMacro)
    case closeSettings

    /// Done where it's chosen, over a sheet or the page being written, rather than after leaving it.
    var staysOverSheets: Bool {
        switch self {
        case .composer, .pref, .darkMode, .reminderTime, .pauseMonitor, .backupNow, .saveSearch, .removeSearch:
            return true
        default:
            return false
        }
    }
}

// MARK: - What the menu needs to know

struct QuireCommandState: Equatable {
    enum Face: String, Equatable { case today, inbox, journal, lookBack }

    struct Item: Equatable {
        var id: String
        var title: String
        /// "Sat 14 Mar 2026, 09:30"
        var when: String
        var isDraft = false
        var isStarred = false
        /// Its page is open, rather than its row selected.
        var isOpen = false
        /// The split journal it's in, if one.
        var journal: String?
    }

    /// The page being written.
    struct Composer: Equatable {
        var title = ""
        var isDraft = true
        var starred = false
        var focus = false
        var recording = false
        var saveFailed = false
    }

    struct Theme: Equatable {
        var id: String
        var name: String
        var dark = false
    }

    struct Search: Equatable {
        var name: String
        var query: String
    }

    struct Settings: Equatable {
        var theme = "auto"
        /// What shows now, "auto" resolved.
        var dark = false
        var prompts = false
        var goalOn = false
        var goal = 750
        var fontSize = 18.0
        var typewriter = false
        var focusParagraph = false
        var autoTranscribe = false
        var reminder = false
        var reminderHour = 20
        var reminderMinute = 0
        var weekly = false
        var weeklyDay = 1
        var weeklyHour = 10
        var appLock = false
        var appLockGrace = 0.0
        var canLock = true
        var spotlight = false
        var dataSaver = false
        var splitTags = ""
        var backupInterval = "off"
        var backupKeep = 10
        var mediaSort = "newest"
        var mediaGroup = "none"
    }

    struct Monitor: Equatable {
        var paused = false
        var theme = "phone"
        var themes: [Theme] = []
        var textSize = "regular"
        var hints = true
        var dim = false
        var dimLevel = 0.02
    }

    var face = Face.today
    var selected: Item?
    var composer: Composer?
    var searchOpen = false
    /// What's in Search's box, while it's open: Pin a search… starts from it.
    var searchQuery = ""
    var settingsOpen = false
    var mediaOpen = false
    /// The menu is drawn on the monitor: nothing that only the phone shows is offered.
    var monitorShows = false
    var regularWidth = false
    var sidebarCollapsed = false
    var journalStarred = false
    var journalSplit: String?
    var splits: [String] = []
    /// Everything that can be opened by name: drafts, then the journal, newest first.
    var entries: [Item] = []
    var drafts = 0
    var counts: [String: Int] = [:]
    var today = Date()
    var searches: [Search] = []
    var tags: [String] = []
    /// Today's prompt, when prompts are on.
    var prompt: String?
    var settings = Settings()
    var themes: [Theme] = []
    /// Nil with no monitor plugged in.
    var monitor: Monitor?
    var backupFolderSet = false
    var backupRunning = false
    var lastBackup: String?

    static let vsCode = "vscode"
    static let followPhone = "phone"
    static let fontSizes: [Double] = [16, 18, 20, 22, 24, 26]
    static let goals = [100, 250, 500, 750, 1000]
    static let monitorSizes = [("small", "Small"), ("regular", "Regular"), ("large", "Large")]
    static let backupIntervals = [("off", "Off"), ("daily", "Daily"), ("weekly", "Weekly"),
                                  ("monthly", "Monthly (30 days)"), ("onChange", "On every change")]
    static let keeps = [3, 5, 10, 20, 30, 50]
    static let graces: [(Double, String)] = [(0, "Immediately"), (60, "After 1 minute"), (300, "After 5 minutes"),
                                             (900, "After 15 minutes")]
    static let dimLevels: [(Double, String)] = [(0.02, "2%"), (0.1, "10%"), (0.25, "25%"), (0.5, "50%")]
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let mediaKinds = [("image", "Photos"), ("video", "Video"), ("audio", "Audio")]
    static let mediaSorts = [("newest", "Newest first"), ("oldest", "Oldest first"), ("largest", "Largest first"),
                             ("kind", "By kind"), ("name", "By name")]
    static let mediaGroups = [("none", "No grouping"), ("day", "By day"), ("month", "By month"), ("year", "By year")]
    /// Settings' pages on the phone: `SettingsGroup`'s raw values.
    static let pages: [(id: String, title: String, words: [String])] = [
        ("folder", "Folder and backups", ["storage", "icloud", "restore", "location"]),
        ("macros", "Macros", ["tools", "maintenance", "tag review"]),
        ("maintenance", "Import and export", ["day one", "pdf", "markdown", "backup"]),
        ("looks", "Writing and display", ["font", "type", "dates", "calendar"]),
        ("reminders", "Reminders", ["notifications", "nudge"]),
        ("privacy", "Privacy", ["face id", "lock", "spotlight"]),
        ("media", "Media", ["data saver", "photos"]),
        ("journal", "Split tags and templates", ["templates", "split"]),
        ("display", "External display", ["monitor", "screen"]),
        ("help", "Help", ["shortcuts", "how to", "what's new", "changelog", "keys"]),
    ]
}

// MARK: - The list

struct QuireCommandList: CommandList {
    typealias Row = CommandRow<QuireCommand>
    let state: QuireCommandState
    /// Built once: the menu asks for the list again at every key.
    let all: [Row]

    init(state: QuireCommandState) {
        self.state = state
        self.all = Self.build(state)
    }

    func prompt(stage: String?) -> String { "Do anything, or go anywhere" }

    func rows(stage: String?, typing: Bool) -> [Row] { all }

    static func == (a: QuireCommandList, b: QuireCommandList) -> Bool { a.state == b.state }

    private static func build(_ s: QuireCommandState) -> [Row] {
        var out: [Row] = []
        if let c = s.composer {
            out += composer(c, s)
        } else if let item = s.selected {
            out += entry(item, s)
        }
        out += places(s)
        out += writing(s)
        out += finding(s)
        out += looks(s)
        out += writingSettings(s)
        out += reminders(s)
        if let m = s.monitor { out += monitor(m, s) }
        out += data(s)
        out += macros(s)
        if !s.monitorShows { out += pages(s) }
        return out
    }

    // MARK: The entry that's selected or open

    private static func entry(_ item: QuireCommandState.Item, _ s: QuireCommandState) -> [Row] {
        let named = "“\(item.title.isEmpty ? "Untitled" : item.title)”"
        let id = item.id
        var out: [Row] = []
        if !item.isOpen {
            out.append(Row("entry.open", "Open", detail: "↩", symbol: "doc.text", step: .run(.entry(.open, id)),
                           synonyms: ["read", "view", "show"], context: named))
        }
        out.append(Row("entry.edit", "Edit", detail: "e", symbol: "pencil", step: .run(.entry(.edit, id)),
                       synonyms: ["write", "change text", "compose"], context: named))
        out.append(Row.toggle("entry.star", isOn: item.isStarred, turnOn: "Star", turnOff: "Unstar",
                              states: ("Starred", "Not starred"), detail: "*", symbol: item.isStarred ? "star.fill" : "star",
                              action: .entry(item.isStarred ? .unstar : .star, id), synonyms: ["favourite", "favorite", "flag"],
                              context: named))
        if item.isDraft {
            out.append(Row("entry.file", "File", detail: "f", symbol: "archivebox", step: .run(.entry(.file, id)),
                           synonyms: ["journal", "done", "move to journal", "archive"], context: named))
        } else {
            out.append(Row("entry.unfile", "Return to Inbox", detail: "u", symbol: "tray.and.arrow.up",
                           step: .run(.entry(.unfile, id)), synonyms: ["unfile", "draft", "back to inbox"], context: named))
        }
        out.append(Row("entry.retime", "Change date and time", detail: "t", symbol: "clock", step: .run(.entry(.retime, id)),
                       synonyms: ["retime", "when", "timestamp", "move day"], context: named))
        let kind = item.isDraft ? "draft" : "entry"
        let yes = Row("entry.delete.yes", "Delete this \(kind)", symbol: "trash", step: .run(.entry(.delete, id)),
                      confirms: true, destructive: true, context: named)
        out.append(Row("entry.delete", "Delete…", detail: "d", symbol: "trash",
                       step: .pick(CommandPick(prompt: "Delete \(named)? Esc keeps it.", choices: [yes], searchable: false)),
                       confirms: true, synonyms: ["remove", "bin", "trash"], destructive: true, context: named))
        if item.isOpen {
            out.append(Row("entry.close", "Close the page", detail: "⎋", symbol: "xmark", step: .run(.entry(.close, id)),
                           synonyms: ["back", "list"], context: named))
        }
        return out
    }

    // MARK: The page being written

    private static func composer(_ c: QuireCommandState.Composer, _ s: QuireCommandState) -> [Row] {
        let named = c.title.isEmpty ? "This page" : "“\(c.title)”"
        func row(_ id: String, _ title: String, _ detail: String?, _ symbol: String, _ action: QuireComposerAction,
                 _ synonyms: [String] = []) -> Row {
            Row("composer." + id, title, detail: detail, symbol: symbol, step: .run(.composer(action)),
                synonyms: synonyms, context: named)
        }
        var out: [Row] = []
        if c.saveFailed {
            out += [row("retry", "Retry the save", nil, "arrow.clockwise", .retry, ["again", "save"]),
                    row("copyToInbox", "Save a copy to the Inbox", nil, "tray.and.arrow.down", .copyToInbox, ["recover", "keep"]),
                    row("copyText", "Copy the text", nil, "doc.on.doc", .copyText, ["clipboard"]),
                    row("closeKeeping", "Close and keep for later", nil, "xmark.circle", .closeKeeping, ["leave"])]
        }
        out.append(c.isDraft ? row("finish", "File", "^J", "archivebox", .finish, ["done", "journal", "finish"])
                             : row("finish", "Done", "^J", "checkmark", .finish, ["finish", "close", "save"]))
        out.append(row("save", "Save now", "^S", "square.and.arrow.down", .save, ["write"]))
        out.append(row("retime", "Date and time", "^T", "clock", .retime, ["stamp", "when", "retime", "change date"]))
        out.append(Row.toggle("composer.focus", isOn: c.focus, turnOn: "Focus mode", turnOff: "Leave focus mode",
                              detail: "^F", symbol: "eye", action: .composer(.focus), synonyms: ["quiet", "distraction"],
                              context: named))
        out.append(row("prompt", "Insert a prompt", "^P", "text.bubble", .prompt, ["idea", "question"]))
        out.append(Row.toggle("composer.star", isOn: c.starred, turnOn: "Star this page", turnOff: "Unstar this page",
                              states: ("Starred", "Not starred"), symbol: c.starred ? "star.fill" : "star",
                              action: .composer(.star), synonyms: ["favourite", "favorite"], context: named))
        out.append(Row.toggle("composer.voice", isOn: c.recording, turnOn: "Record a voice note", turnOff: "Stop recording",
                              states: ("Recording", "Off"), symbol: "mic", action: .composer(.voice),
                              synonyms: ["audio", "memo", "dictate"], context: named))
        // The pickers and the camera are the phone's own screens.
        if !s.monitorShows {
            out += [row("photoLibrary", "Attach from Photos", nil, "photo.on.rectangle", .photoLibrary, ["picture", "image", "library"]),
                    row("takePhoto", "Take a photo", nil, "camera", .takePhoto, ["camera", "picture"]),
                    row("video", "Record a video", nil, "video", .video, ["film", "movie", "camera"]),
                    row("file", "Attach a file", nil, "paperclip", .file, ["document", "attachment"])]
        }
        if c.isDraft {
            let yes = Row("composer.discard.yes", "Discard this draft", symbol: "trash", step: .run(.composer(.discard)),
                          confirms: true, destructive: true, context: named)
            out.append(Row("composer.discard", "Discard…", detail: "^D", symbol: "trash",
                           step: .pick(CommandPick(prompt: "Discard the draft? Esc keeps it.", choices: [yes], searchable: false)),
                           confirms: true, synonyms: ["delete", "throw away", "bin"], destructive: true, context: named))
        }
        out.append(row("close", "Close the page", "⎋", "xmark", .close, ["back", "leave"]))
        return out
    }

    // MARK: Places

    private static func places(_ s: QuireCommandState) -> [Row] {
        var out: [Row] = [
            Row("go.today", "Today", symbol: "sun.max", step: .run(.today), synonyms: ["home", "go to today"]),
            Row("go.inbox", "Inbox", detail: s.drafts == 0 ? nil : s.drafts == 1 ? "1 draft" : "\(s.drafts) drafts",
                symbol: "tray", step: .run(.inbox), synonyms: ["drafts", "go to inbox"]),
            Row("go.journal", "Journal", symbol: "book", step: .run(.journal), synonyms: ["filed", "entries", "go to journal"]),
            Row("go.lookBack", "Look back", symbol: "clock.arrow.circlepath", step: .run(.lookBack),
                synonyms: ["on this day", "stats", "streak", "history", "go to look back"]),
            Row("go.search", "Search", detail: "/", symbol: "magnifyingglass", step: .run(.search), synonyms: ["find"]),
            Row("go.searchFor", "Search for…", symbol: "text.magnifyingglass",
                step: .ask(CommandAsk(prompt: "Words, @tag, tag:, before:, is:starred", symbol: "magnifyingglass",
                                      title: { "Search for “\($0)”" }, make: { text in text.isEmpty ? nil : .searchFor(text) })),
                synonyms: ["find", "query", "look for"]),
            Row("go.settings", "Settings", detail: ",", symbol: "gearshape", step: .run(.settings),
                synonyms: ["preferences", "options"]),
        ]
        if !s.monitorShows {
            out.append(Row("go.media", "Media Library", symbol: "photo.on.rectangle", step: .run(.media(kind: nil, find: nil)),
                           synonyms: ["photos", "attachments", "pictures", "video", "audio", "files"]))
        }
        out.append(jumpRow(s))
        if !s.entries.isEmpty { out.append(openEntryRow(s)) }
        if s.counts.values.contains(where: { $0 > 0 }) {
            out.append(Row("go.random", "A random entry", detail: "r", symbol: "dice", step: .run(.randomEntry),
                           synonyms: ["surprise", "dice", "any"]))
        }
        if s.drafts > 0 {
            out.append(Row("go.randomDraft", "A random draft", symbol: "dice", step: .run(.randomDraft),
                           synonyms: ["surprise", "dice", "inbox"]))
        }
        out.append(Row.toggle("journal.starred", isOn: s.journalStarred, turnOn: "Show starred entries only",
                              turnOff: "Show every entry", states: ("Starred only", "All"), symbol: "star",
                              action: .starredOnly(!s.journalStarred), synonyms: ["filter", "favourites", "all", "journal"]))
        if !s.splits.isEmpty {
            let choices = [Row("main", "The journal", symbol: "book", step: .run(.splitJournal(nil)),
                               synonyms: ["main"], isCurrent: s.journalSplit == nil)]
                + s.splits.map { Row("split." + $0, $0, symbol: "books.vertical", step: .run(.splitJournal($0)),
                                     isCurrent: s.journalSplit == $0) }
            out.append(Row("journal.split", "Read a journal…", detail: s.journalSplit ?? "The journal",
                           symbol: "books.vertical",
                           step: .pick(CommandPick(prompt: "Which journal?", choices: choices)),
                           synonyms: ["split", "split journal", "choose journal"]))
        }
        if s.regularWidth {
            out.append(Row.toggle("sidebar", isOn: s.sidebarCollapsed, turnOn: "Fold the sidebar", turnOff: "Show the sidebar",
                                  states: ("Folded", "Shown"), symbol: "sidebar.left",
                                  action: .sidebar(collapsed: !s.sidebarCollapsed), synonyms: ["collapse", "expand", "hide"]))
        }
        if s.settingsOpen {
            out.append(Row("settings.close", "Close settings", detail: "⎋", symbol: "xmark", step: .run(.closeSettings),
                           synonyms: ["done", "leave"]))
        }
        return out
    }

    /// A typed day, or a preset, said before ↩ does it: where it would land, and what's there.
    private static func jumpRow(_ s: QuireCommandState) -> Row {
        let sources = CommandSources(counts: s.counts, today: s.today)
        func landing(_ date: Date) -> (day: String, detail: String) {
            let day = CommandDates.key(date)
            let count = sources.counts[day] ?? 0
            let nearest = sources.nearest(to: day)
            if count > 0 { return (day, count == 1 ? "1 entry" : "\(count) entries") }
            if let nearest, let other = CommandDates.date(nearest) {
                return (nearest, "Nothing that day: opens " + CommandDates.fullDay.string(from: other))
            }
            return (day, "Nothing is filed yet")
        }
        let calendar = Calendar.current
        func back(_ part: Calendar.Component, _ n: Int) -> Date { calendar.date(byAdding: part, value: -n, to: s.today) ?? s.today }
        let presets = [("today", "Today", s.today), ("yesterday", "Yesterday", back(.day, 1)), ("week", "A week ago", back(.day, 7)),
                       ("month", "A month ago", back(.month, 1)), ("year", "A year ago", back(.year, 1))]
            .map { id, title, date -> Row in
                let l = landing(date)
                return Row("day." + id, title, detail: CommandDates.fullDay.string(from: date) + " · " + l.detail,
                           symbol: "calendar", step: .run(.jump(l.day)))
            }
        return Row("go.date", "Jump to a date…", symbol: "calendar",
                   step: .ask(CommandAsk(prompt: "A date: 14 March, 14/3, 2026-03-14", suggestions: presets, symbol: "calendar",
                                         nothing: "That isn't a date. Try 14 March.",
                                         title: { text in
                                             guard let date = CommandDates.parse(text, today: s.today) else { return text }
                                             return CommandDates.fullDay.string(from: date) + " · " + landing(date).detail
                                         },
                                         make: { text in CommandDates.parse(text, today: s.today).map { .jump(landing($0).day) } })),
                   synonyms: ["go to day", "calendar", "when", "date"])
    }

    private static func openEntryRow(_ s: QuireCommandState) -> Row {
        let choices = s.entries.map { e in
            Row("open." + e.id, e.title.isEmpty ? "Untitled" : e.title,
                detail: e.when + (e.isDraft ? " · draft" : e.journal.map { " · " + $0 } ?? ""),
                symbol: e.isDraft ? "tray" : e.isStarred ? "star.fill" : "doc.text", step: .run(.openEntry(e.id)))
        }
        return Row("go.entry", "Open an entry…", symbol: "doc.text.magnifyingglass",
                   step: .pick(CommandPick(prompt: "Which entry? Type its title", choices: choices,
                                           nothing: "No entry by that name. Try Search for….", searchable: false)),
                   synonyms: ["find", "go to entry", "title", "draft"])
    }

    // MARK: Writing

    private static func writing(_ s: QuireCommandState) -> [Row] {
        var out: [Row] = [
            Row("new", "New draft", detail: "n", symbol: "square.and.pencil", step: .run(.newDraft),
                synonyms: ["write", "entry", "compose", "begin", "new entry"]),
            Row("writeLine", "Write a line…", symbol: "text.insert",
                step: .ask(CommandAsk(prompt: "A line, straight to the Inbox", symbol: "tray.and.arrow.down",
                                      title: { "Save “\($0)” to the Inbox" },
                                      make: { $0.isEmpty ? nil : .writeLine($0) })),
                synonyms: ["capture", "quick note", "jot", "inbox"]),
        ]
        if let prompt = s.prompt {
            out.append(Row("writePrompt", "Write from today’s prompt", detail: prompt, symbol: "text.bubble",
                           step: .run(.newDraft), synonyms: ["prompt", "idea"]))
            if s.face == .today, s.composer == nil {
                out.append(Row("anotherPrompt", "Another prompt", detail: "p", symbol: "shuffle", step: .run(.anotherPrompt),
                               synonyms: ["reroll", "next prompt", "shuffle"]))
            }
        }
        return out
    }

    // MARK: Search, saved searches and tags

    private static func finding(_ s: QuireCommandState) -> [Row] {
        var out: [Row] = []
        if !s.searches.isEmpty {
            let runs = s.searches.map { Row("saved." + $0.name, $0.name, detail: $0.name == $0.query ? nil : $0.query,
                                            symbol: "pin", step: .run(.searchFor($0.query))) }
            out.append(Row("search.saved", "Saved search…", symbol: "pin",
                           step: .pick(CommandPick(prompt: "Which search?", choices: runs)),
                           synonyms: ["pinned", "smart folder", "run search"]))
            let removes = s.searches.map { search -> Row in
                let yes = Row("yes", "Remove “\(search.name)”", symbol: "pin.slash", step: .run(.removeSearch(search.name)),
                              confirms: true, destructive: true)
                return Row("remove." + search.name, search.name, symbol: "pin.slash",
                           step: .pick(CommandPick(prompt: "Remove this saved search? Esc keeps it.", choices: [yes],
                                                   searchable: false)),
                           confirms: true, destructive: true)
            }
            out.append(Row("search.remove", "Remove a saved search…", symbol: "pin.slash",
                           step: .pick(CommandPick(prompt: "Which search?", choices: removes, searchable: false)),
                           confirms: true, synonyms: ["unpin", "delete search"], destructive: true))
        }
        out.append(Row("search.save", "Pin a search…", symbol: "pin",
                       step: .ask(CommandAsk(prompt: "The query to keep, as Search reads it",
                                      initial: s.searchOpen ? s.searchQuery : "", symbol: "pin",
                                             title: { "Pin “\($0)”" }, make: { $0.isEmpty ? nil : .saveSearch($0) })),
                       synonyms: ["save search", "smart folder", "keep search"]))
        if !s.tags.isEmpty {
            let tags = s.tags.map { Row("tag." + $0, $0, symbol: "number", step: .run(.searchFor($0))) }
            out.append(Row("search.tag", "Search a tag…", symbol: "number",
                           step: .pick(CommandPick(prompt: "Which tag?", choices: tags)),
                           synonyms: ["tags", "@", "label"]))
        }
        return out
    }

    // MARK: Looks

    private static func looks(_ s: QuireCommandState) -> [Row] {
        let set = s.settings
        let themes = [QuireCommandState.Theme(id: "auto", name: "Auto (light by day, dark by night)")] + s.themes
        let choices = themes.map { t in
            Row(t.id, t.name, detail: t.id == "auto" ? nil : t.dark ? "Dark" : "Light", symbol: "paintpalette",
                step: .run(.pref(QuirePrefKey.theme, .string(t.id))), synonyms: t.dark ? ["dark", "night"] : ["light", "day"],
                preview: .pref(QuirePrefKey.theme, .string(t.id)), isCurrent: set.theme == t.id)
        }
        let current = themes.first { $0.id == set.theme }?.name
        var out = [
            Row("theme", "Theme…", detail: current, symbol: "paintpalette",
                step: .pick(CommandPick(prompt: "Which theme? ↑↓ to try each", choices: choices,
                                        revert: .pref(QuirePrefKey.theme, .string(set.theme)))),
                synonyms: ["look", "colours", "colors", "palette", "appearance"]),
            Row.toggle("dark", isOn: set.dark, turnOn: "Dark mode", turnOff: "Light mode", states: ("Dark", "Light"),
                       symbol: "circle.lefthalf.filled", action: .darkMode(!set.dark), synonyms: ["night", "day", "appearance"]),
        ]
        let sizes = QuireCommandState.fontSizes.map { size in
            Row("size.\(Int(size))", "\(Int(size)) px", symbol: "textformat.size", step: .run(.pref(QuirePrefKey.fontSize, .double(size))),
                preview: .pref(QuirePrefKey.fontSize, .double(size)), isCurrent: set.fontSize == size)
        }
        out.append(Row("textSize", "Text size…", detail: "\(Int(set.fontSize)) px", symbol: "textformat.size",
                       step: .pick(CommandPick(prompt: "How big?", choices: sizes,
                                               revert: .pref(QuirePrefKey.fontSize, .double(set.fontSize)))),
                       synonyms: ["font size", "bigger", "smaller", "larger"]))
        return out
    }

    // MARK: Writing settings

    private static func writingSettings(_ s: QuireCommandState) -> [Row] {
        let set = s.settings
        func flag(_ id: String, _ on: Bool, _ turnOn: String, _ turnOff: String, _ key: String, _ symbol: String,
                  _ synonyms: [String] = []) -> Row {
            Row.toggle(id, isOn: on, turnOn: turnOn, turnOff: turnOff, symbol: symbol, action: .pref(key, .bool(!on)),
                       synonyms: synonyms)
        }
        var out = [
            flag("prompts", set.prompts, "Show writing prompts", "Stop showing writing prompts", QuirePrefKey.prompts,
                 "text.bubble", ["writing prompts", "ideas"]),
            flag("goal", set.goalOn, "Set a daily word goal", "Turn off the daily word goal", QuirePrefKey.goalOn,
                 "target", ["words", "target"]),
        ]
        if set.goalOn {
            let goals = QuireCommandState.goals.map {
                Row("goal.\($0)", "\($0) words", symbol: "target", step: .run(.pref(QuirePrefKey.goal, .int($0))),
                    isCurrent: set.goal == $0)
            }
            out.append(Row("goalAmount", "Daily word goal…", detail: "\(set.goal) words", symbol: "target",
                           step: .pick(CommandPick(prompt: "How many words a day?", choices: goals)), synonyms: ["target"]))
        }
        out += [
            flag("typewriter", set.typewriter, "Typewriter scrolling", "Stop typewriter scrolling", QuirePrefKey.typewriter,
                 "text.aligncenter", ["centre line", "center"]),
            flag("focusParagraph", set.focusParagraph, "Focus the current paragraph", "Stop focusing the paragraph",
                 QuirePrefKey.focusParagraph, "text.justify", ["dim", "highlight paragraph"]),
            flag("transcribe", set.autoTranscribe, "Transcribe voice notes", "Stop transcribing voice notes",
                 QuirePrefKey.autoTranscribe, "text.quote", ["memo", "speech", "dictation"]),
            flag("dataSaver", set.dataSaver, "Turn on Data Saver", "Turn off Data Saver", QuirePrefKey.dataSaver,
                 "arrow.down.circle", ["compress", "media", "smaller photos"]),
            Row("splitTags", "Split tags…", detail: set.splitTags.isEmpty ? "None" : set.splitTags, symbol: "number",
                step: .ask(CommandAsk(prompt: "Tags that file to their own journal, e.g. work dreams", initial: set.splitTags,
                                      symbol: "number", title: { "Split tags: \($0)" },
                                      make: { $0 == set.splitTags ? nil : .pref(QuirePrefKey.splitTags, .string($0)) })),
                synonyms: ["split journals", "tags"]),
            flag("spotlight", set.spotlight, "Show entries in Spotlight", "Hide entries from Spotlight",
                 QuirePrefKey.spotlight, "magnifyingglass.circle", ["system search", "index"]),
        ]
        if set.canLock || set.appLock {
            out.append(flag("lock", set.appLock, "Lock with Face ID", "Stop locking with Face ID", QuirePrefKey.appLock,
                            "faceid", ["app lock", "privacy", "passcode", "touch id"]))
        }
        if set.appLock {
            let graces = QuireCommandState.graces.map { secs, title in
                Row("grace.\(Int(secs))", title, symbol: "lock", step: .run(.pref(QuirePrefKey.appLockGrace, .double(secs))),
                    isCurrent: set.appLockGrace == secs)
            }
            out.append(Row("lockGrace", "Relock…", detail: QuireCommandState.graces.first { $0.0 == set.appLockGrace }?.1,
                           symbol: "lock", step: .pick(CommandPick(prompt: "Lock again when?", choices: graces)),
                           synonyms: ["face id", "delay"]))
        }
        return out
    }

    // MARK: Reminders

    private static func reminders(_ s: QuireCommandState) -> [Row] {
        let set = s.settings
        func clock(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }
        var out = [Row.toggle("reminder", isOn: set.reminder, turnOn: "Remind me to write each day",
                              turnOff: "Stop the daily reminder", detail: set.reminder ? clock(set.reminderHour, set.reminderMinute) : nil,
                              symbol: "bell", action: .pref(QuirePrefKey.reminder, .bool(!set.reminder)),
                              synonyms: ["notification", "nudge", "daily reminder"])]
        if set.reminder {
            let times = [(7, 0), (8, 0), (12, 0), (18, 0), (20, 0), (21, 0), (22, 0)].map { h, m in
                Row("at.\(h)", clock(h, m), symbol: "clock", step: .run(.reminderTime(hour: h, minute: m)),
                    isCurrent: set.reminderHour == h && set.reminderMinute == m)
            }
            out.append(Row("reminderTime", "Daily reminder at…", detail: clock(set.reminderHour, set.reminderMinute),
                           symbol: "clock",
                           step: .ask(CommandAsk(prompt: "A time: 9, 1930, 21:15", suggestions: times, symbol: "clock",
                                                 nothing: "That isn't a time. Try 21:00.",
                                                 title: { t in TypedTime.parse(t).map { "Remind me at " + clock($0.hour, $0.minute) } ?? t },
                                                 make: { TypedTime.parse($0).map { .reminderTime(hour: $0.hour, minute: $0.minute) } })),
                           synonyms: ["reminder time", "when"]))
        }
        out.append(Row.toggle("weekly", isOn: set.weekly, turnOn: "Send “From your journal” each week",
                              turnOff: "Stop the weekly “From your journal”", symbol: "envelope.open",
                              action: .pref(QuirePrefKey.weekly, .bool(!set.weekly)),
                              synonyms: ["resurface", "weekly note", "memories", "notification"]))
        if set.weekly {
            let days = QuireCommandState.weekdays.enumerated().map { i, name in
                Row("day.\(i + 1)", name, symbol: "calendar", step: .run(.pref(QuirePrefKey.weeklyDay, .int(i + 1))),
                    isCurrent: set.weeklyDay == i + 1)
            }
            let hours = (6..<23).map { h in
                Row("hour.\(h)", clock(h, 0), symbol: "clock", step: .run(.pref(QuirePrefKey.weeklyHour, .int(h))),
                    isCurrent: set.weeklyHour == h)
            }
            let day = QuireCommandState.weekdays.indices.contains(set.weeklyDay - 1) ? QuireCommandState.weekdays[set.weeklyDay - 1] : nil
            out.append(Row("weeklyDay", "Weekly note on…", detail: day, symbol: "calendar",
                           step: .pick(CommandPick(prompt: "Which day?", choices: days)), synonyms: ["from your journal"]))
            out.append(Row("weeklyHour", "Weekly note around…", detail: clock(set.weeklyHour, 0), symbol: "clock",
                           step: .pick(CommandPick(prompt: "About what time?", choices: hours)), synonyms: ["from your journal"]))
        }
        return out
    }

    // MARK: The monitor

    private static func monitor(_ m: QuireCommandState.Monitor, _ s: QuireCommandState) -> [Row] {
        let themes = [QuireCommandState.Theme(id: QuireCommandState.followPhone, name: "Same as the phone")] + m.themes
            + [QuireCommandState.Theme(id: QuireCommandState.vsCode, name: "VS Code (hidden)", dark: true)]
        let choices = themes.map { t in
            Row("m." + t.id, t.name, symbol: t.id == QuireCommandState.vsCode ? "chevron.left.forwardslash.chevron.right" : "display",
                step: .run(.pref(QuirePrefKey.monitorTheme, .string(t.id))),
                synonyms: t.id == QuireCommandState.vsCode ? ["disguise", "hidden", "code", "work"] : [],
                preview: .pref(QuirePrefKey.monitorTheme, .string(t.id)), isCurrent: m.theme == t.id)
        }
        let sizes = QuireCommandState.monitorSizes.map { id, title in
            Row("ms." + id, title, symbol: "textformat.size", step: .run(.pref(QuirePrefKey.monitorTextSize, .string(id))),
                preview: .pref(QuirePrefKey.monitorTextSize, .string(id)), isCurrent: m.textSize == id)
        }
        let disguised = m.theme == QuireCommandState.vsCode
        var out = [
            Row("monitor.theme", "Monitor theme…", detail: themes.first { $0.id == m.theme }?.name, symbol: "display",
                step: .pick(CommandPick(prompt: "Which look on the monitor? ↑↓ to try each", choices: choices,
                                        revert: .pref(QuirePrefKey.monitorTheme, .string(m.theme)))),
                synonyms: ["external display", "screen look"]),
            Row.toggle("monitor.disguise", isOn: disguised, turnOn: "Disguise the monitor as VS Code",
                       turnOff: "Stop disguising the monitor", symbol: "chevron.left.forwardslash.chevron.right",
                       action: .pref(QuirePrefKey.monitorTheme, .string(disguised ? QuireCommandState.followPhone : QuireCommandState.vsCode)),
                       synonyms: ["hidden mode", "code", "work"]),
            Row.toggle("monitor.pause", isOn: m.paused, turnOn: "Pause the monitor", turnOff: "Resume the monitor",
                       states: ("Paused", "Showing"), detail: "⌥⌘P", symbol: "pause.rectangle", action: .pauseMonitor,
                       synonyms: ["blank", "hide screen"]),
            Row("monitor.size", "Monitor text size…", detail: QuireCommandState.monitorSizes.first { $0.0 == m.textSize }?.1,
                symbol: "textformat.size",
                step: .pick(CommandPick(prompt: "How big on the monitor?", choices: sizes,
                                        revert: .pref(QuirePrefKey.monitorTextSize, .string(m.textSize)))),
                synonyms: ["bigger", "smaller", "zoom"]),
            Row.toggle("monitor.hints", isOn: m.hints, turnOn: "Show key hints on the monitor", turnOff: "Hide key hints",
                       detail: "⌥⌘H", symbol: "keyboard", action: .pref(QuirePrefKey.monitorHints, .bool(!m.hints)),
                       synonyms: ["shortcuts", "hint bar"]),
            Row.toggle("monitor.dim", isOn: m.dim, turnOn: "Dim the phone screen", turnOff: "Stop dimming the phone",
                       symbol: "sun.min", action: .pref(QuirePrefKey.dimPhone, .bool(!m.dim)), synonyms: ["brightness", "dark phone"]),
        ]
        if m.dim {
            let levels = QuireCommandState.dimLevels.map { level, title in
                Row("dim.\(title)", title, symbol: "sun.min", step: .run(.pref(QuirePrefKey.dimLevel, .double(level))),
                    preview: .pref(QuirePrefKey.dimLevel, .double(level)), isCurrent: abs(m.dimLevel - level) < 0.005)
            }
            out.append(Row("monitor.dimLevel", "Dim the phone to…", detail: "\(Int((m.dimLevel * 100).rounded()))%",
                           symbol: "sun.min",
                           step: .pick(CommandPick(prompt: "How dim?", choices: levels,
                                                   revert: .pref(QuirePrefKey.dimLevel, .double(m.dimLevel)))),
                           synonyms: ["brightness"]))
        }
        return out
    }

    // MARK: Backups and media

    private static func data(_ s: QuireCommandState) -> [Row] {
        let set = s.settings
        var out: [Row] = []
        if s.backupFolderSet {
            out.append(Row("backup.now", s.backupRunning ? "Backing up…" : "Back up now", detail: s.lastBackup,
                           symbol: "externaldrive", step: .run(.backupNow), synonyms: ["copy", "save a copy"]))
        }
        let intervals = QuireCommandState.backupIntervals.map { id, title in
            Row("bi." + id, title, symbol: "clock.arrow.2.circlepath", step: .run(.pref(QuirePrefKey.backupInterval, .string(id))),
                isCurrent: set.backupInterval == id)
        }
        out.append(Row("backup.interval", "Back up automatically…",
                       detail: QuireCommandState.backupIntervals.first { $0.0 == set.backupInterval }?.1,
                       symbol: "clock.arrow.2.circlepath",
                       step: .pick(CommandPick(prompt: "How often?", choices: intervals)), synonyms: ["backup schedule", "interval"]))
        let keeps = QuireCommandState.keeps.map { n in
            Row("keep.\(n)", "Keep the last \(n)", symbol: "square.stack", step: .run(.pref(QuirePrefKey.backupKeep, .int(n))),
                isCurrent: set.backupKeep == n)
        }
        out.append(Row("backup.keep", "Backups to keep…", detail: "\(set.backupKeep)", symbol: "square.stack",
                       step: .pick(CommandPick(prompt: "How many backups?", choices: keeps)), synonyms: ["backup count"]))
        let sorts = QuireCommandState.mediaSorts.map { id, title in
            Row("sort." + id, title, symbol: "arrow.up.arrow.down", step: .run(.pref(QuirePrefKey.mediaSort, .string(id))),
                isCurrent: set.mediaSort == id)
        }
        let groups = QuireCommandState.mediaGroups.map { id, title in
            Row("group." + id, title, symbol: "square.grid.2x2", step: .run(.pref(QuirePrefKey.mediaGroup, .string(id))),
                isCurrent: set.mediaGroup == id)
        }
        out.append(Row("media.sort", "Sort media…", detail: QuireCommandState.mediaSorts.first { $0.0 == set.mediaSort }?.1,
                       symbol: "arrow.up.arrow.down", step: .pick(CommandPick(prompt: "Media in what order?", choices: sorts)),
                       synonyms: ["media library order", "photos"]))
        out.append(Row("media.group", "Group media…", detail: QuireCommandState.mediaGroups.first { $0.0 == set.mediaGroup }?.1,
                       symbol: "square.grid.2x2", step: .pick(CommandPick(prompt: "Group media by?", choices: groups)),
                       synonyms: ["media library", "photos"]))
        if !s.monitorShows {
            let kinds = QuireCommandState.mediaKinds.map { id, title in
                Row("kind." + id, title, symbol: "photo", step: .run(.media(kind: id, find: nil)))
            }
            out.append(Row("media.kind", "Show media of one kind…", symbol: "photo",
                           step: .pick(CommandPick(prompt: "Which kind?", choices: kinds)),
                           synonyms: ["photos", "videos", "audio", "filter media"]))
            out.append(Row("media.find", "Find media…", symbol: "magnifyingglass",
                           step: .ask(CommandAsk(prompt: "Part of a file name", symbol: "magnifyingglass",
                                                 title: { "Media named “\($0)”" }, make: { $0.isEmpty ? nil : .media(kind: nil, find: $0) })),
                           synonyms: ["photo", "file", "attachment"]))
        }
        return out
    }

    // MARK: Macros

    private static func macros(_ s: QuireCommandState) -> [Row] {
        func run(_ m: QuireMacro, _ title: String, _ symbol: String, _ synonyms: [String]) -> Row {
            Row("macro." + m.rawValue, title, symbol: symbol, step: .run(.macro(m)), synonyms: synonyms + ["macro"])
        }
        /// One that changes a lot at once asks first, as Settings does, in the menu.
        func asking(_ m: QuireMacro, _ title: String, _ question: String, _ yes: String, _ symbol: String,
                    _ synonyms: [String], destructive: Bool = false) -> Row {
            let go = Row("yes", yes, symbol: symbol, step: .run(.macro(m)), confirms: true, destructive: destructive)
            return Row("macro." + m.rawValue, title, symbol: symbol,
                       step: .pick(CommandPick(prompt: question + " Esc leaves it.", choices: [go], searchable: false)),
                       confirms: true, synonyms: synonyms + ["macro"], destructive: destructive)
        }
        var out = [
            run(.cleanUp, "Clean up the journal", "wand.and.sparkles", ["tidy", "format", "duplicates", "jnl"]),
            run(.sortInbox, "Sort the Inbox", "arrow.up.arrow.down", ["order drafts", "date order"]),
        ]
        if s.drafts > 0 {
            out.append(asking(.fileAll, "File every draft…", "File every draft?",
                              s.drafts == 1 ? "File the one draft" : "File all \(s.drafts) drafts", "archivebox",
                              ["file all", "empty inbox"]))
        }
        out += [
            asking(.transfer, "File transfer.md…", "File transfer.md?", "File it", "doc.badge.arrow.up", ["jnl", "batch"]),
            asking(.conflicts, "Merge conflict copies…", "Merge conflict copies?", "Merge them", "arrow.triangle.merge",
                   ["sync", "icloud", "duplicates"]),
            asking(.mergeExSplit, "Merge ex-split journals…",
                   "Every split journal whose tag is no longer a split tag goes back into the journal.", "Merge them",
                   "arrow.triangle.merge", ["split", "old journals"]),
            run(.compressMedia, "Compress existing media", "photo.badge.arrow.down", ["shrink", "data saver", "heic"]),
            run(.transcribeAll, "Transcribe every voice note", "text.quote", ["memos", "speech", "transcripts"]),
            asking(.clearOrphans, "Clear orphan media…",
                   "Move media no entry uses out of assets/? Copies are kept for 30 days.", "Clear unused media",
                   "photo.badge.exclamationmark", ["unused", "unused files", "delete media"], destructive: true),
        ]
        return out
    }

    // MARK: Settings' pages, on the phone

    private static func pages(_ s: QuireCommandState) -> [Row] {
        let choices = QuireCommandState.pages.map { page in
            Row("page." + page.id, page.title, symbol: "gearshape", step: .run(.settingsPage(page.id)), synonyms: page.words)
        }
        func page(_ id: String, _ title: String, _ to: String, _ symbol: String, _ synonyms: [String]) -> Row {
            Row(id, title, detail: QuireCommandState.pages.first { $0.id == to }.map { "Settings › " + $0.title },
                symbol: symbol, step: .run(.settingsPage(to)), synonyms: synonyms)
        }
        return [
            Row("settings.page", "Settings page…", symbol: "gearshape",
                step: .pick(CommandPick(prompt: "Which page?", choices: choices)), synonyms: ["preferences", "options"]),
            page("folder.choose", "Choose the journal folder…", "folder", "folder", ["location", "storage", "icloud", "default folder"]),
            page("backup.folder", "Choose a backup folder…", "folder", "externaldrive", ["backups"]),
            page("backup.restore", "Restore a backup…", "folder", "clock.arrow.circlepath", ["undo", "recover"]),
            page("export.markdown", "Export markdown…", "maintenance", "square.and.arrow.up", ["export", "md", "save"]),
            page("export.pdf", "Export PDF…", "maintenance", "doc.richtext", ["print", "book"]),
            page("import.dayone", "Import from Day One…", "maintenance", "square.and.arrow.down", ["import", "json"]),
            page("import.markdown", "Import a markdown folder…", "maintenance", "folder.badge.plus", ["import", "text files"]),
            page("templates", "Templates…", "journal", "doc.on.doc", ["new template", "delete template"]),
            page("tagReview", "Tag review…", "macros", "checkmark.seal", ["tags", "merge tags"]),
            page("help.new", "What’s new", "help", "sparkles", ["changelog", "release notes"]),
            page("help.keys", "Keyboard shortcuts and how-to", "help", "keyboard", ["help", "keys", "how to"]),
        ]
    }
}
