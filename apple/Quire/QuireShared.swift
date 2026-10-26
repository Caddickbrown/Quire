//
//  QuireShared.swift
//  Quire
//
//  Data shared between the main app and the widget extension via
//  an App Group UserDefaults container. The main app writes a
//  QuireSnapshot after every reload; the widget reads it on its
//  timeline refresh.
//
//  Both targets must include this file (add it to the widget extension
//  target in Xcode alongside QuireWidget.swift).
//

import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif
// ActivityKit imports on macOS but its types are iOS-only, so gate on the OS.
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

#if os(iOS) && canImport(ActivityKit)
/// The writing-timer Live Activity (Dynamic Island / Lock Screen countdown).
/// Defined here because the app starts it and the widget extension renders it.
public struct QuireTimerAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// When the session ends — the system counts down to it, so the app
        /// never has to push per-second updates.
        public var endDate: Date
        public var wordsToday: Int
        /// 0 when the word goal is off.
        public var wordGoal: Int
        public init(endDate: Date, wordsToday: Int, wordGoal: Int) {
            self.endDate = endDate
            self.wordsToday = wordsToday
            self.wordGoal = wordGoal
        }
    }
    public var accentRaw: String
    /// The Quire look (themes.json id, or "auto"); nil from an older app build.
    public var themeID: String?
    public init(accentRaw: String = "blue", themeID: String? = nil) {
        self.accentRaw = accentRaw
        self.themeID = themeID
    }
}
#endif

public struct QuireSnapshot: Codable, Equatable {
    public var currentStreak: Int = 0
    public var bestStreak: Int    = 0
    public var totalDays: Int     = 0
    public var totalEntries: Int  = 0
    public var totalWords: Int    = 0
    public var inboxDrafts: Int   = 0
    public var accentRaw: String  = "blue"
    public var updatedAt: Date    = .distantPast

    // Later additions — optionals so a snapshot written by an older app build
    // (or read by an older widget) still decodes.
    /// Words written today (archive + drafts dated today).
    public var wordsToday: Int?
    /// The user's daily word goal; nil or 0 when the goal is off.
    public var wordGoal: Int?
    /// "On this day" tease: preview of an entry from this date in a past year,
    /// plus where it lives so the widget can deep-link straight to it.
    public var onThisDayPreview: String?
    public var onThisDayYearsAgo: Int?
    public var onThisDayDate: String?
    public var onThisDayTS: String?
    /// The next line of the teased entry's body, under its title.
    public var onThisDayExcerpt: String?
    /// The look the app is in (themes.json id, or "auto"), so the widget
    /// matches it.
    public var themeID: String?
    /// The day (`dayKey`) the "today" figures describe. A widget showing a
    /// later day reads today's words as 0 rather than yesterday's.
    public var day: String?
    /// Entries filed today, and whether anything at all was written today.
    public var filedToday: Int?
    public var wroteToday: Bool?

    public init() {}

    /// Decoded field by field, every one of them optional, so a snapshot the
    /// app wrote under a different shape — a field renamed, a new one added,
    /// an old one dropped — still yields a usable snapshot instead of throwing
    /// and blanking the widget back to zeros.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentStreak = try c.decodeIfPresent(Int.self, forKey: .currentStreak) ?? 0
        bestStreak    = try c.decodeIfPresent(Int.self, forKey: .bestStreak) ?? 0
        totalDays     = try c.decodeIfPresent(Int.self, forKey: .totalDays) ?? 0
        totalEntries  = try c.decodeIfPresent(Int.self, forKey: .totalEntries) ?? 0
        totalWords    = try c.decodeIfPresent(Int.self, forKey: .totalWords) ?? 0
        inboxDrafts   = try c.decodeIfPresent(Int.self, forKey: .inboxDrafts) ?? 0
        accentRaw     = try c.decodeIfPresent(String.self, forKey: .accentRaw) ?? "blue"
        updatedAt     = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        wordsToday    = try c.decodeIfPresent(Int.self, forKey: .wordsToday)
        wordGoal      = try c.decodeIfPresent(Int.self, forKey: .wordGoal)
        onThisDayPreview  = try c.decodeIfPresent(String.self, forKey: .onThisDayPreview)
        onThisDayYearsAgo = try c.decodeIfPresent(Int.self, forKey: .onThisDayYearsAgo)
        onThisDayDate     = try c.decodeIfPresent(String.self, forKey: .onThisDayDate)
        onThisDayTS       = try c.decodeIfPresent(String.self, forKey: .onThisDayTS)
        onThisDayExcerpt  = try c.decodeIfPresent(String.self, forKey: .onThisDayExcerpt)
        themeID    = try c.decodeIfPresent(String.self, forKey: .themeID)
        day        = try c.decodeIfPresent(String.self, forKey: .day)
        filedToday = try c.decodeIfPresent(Int.self, forKey: .filedToday)
        wroteToday = try c.decodeIfPresent(Bool.self, forKey: .wroteToday)
    }

    enum CodingKeys: String, CodingKey {
        case currentStreak, bestStreak, totalDays, totalEntries, totalWords
        case inboxDrafts, accentRaw, updatedAt, wordsToday, wordGoal
        case onThisDayPreview, onThisDayYearsAgo, onThisDayDate, onThisDayTS
        case onThisDayExcerpt, themeID, day, filedToday, wroteToday
    }

    /// "2026-10-26" for a date in the device's calendar: the key `day` holds.
    public static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Deep link to one entry (`quire://entry?date=…&ts=…`), used by the widget
    /// and notifications; the app resolves it via the archive lookup.
    public static func entryURL(date: String, ts: String) -> URL? {
        var c = URLComponents()
        c.scheme = "quire"
        c.host = "entry"
        c.queryItems = [URLQueryItem(name: "date", value: date),
                        URLQueryItem(name: "ts", value: ts)]
        return c.url
    }

    // App Group suite shared between app + widget extension.
    public static let suiteName = "group.com.caddickbrown.quire"
    public static let defaultsKey = "quire.widgetSnapshot"

    public static func load() -> QuireSnapshot {
        guard
            let defaults = UserDefaults(suiteName: suiteName),
            let data     = defaults.data(forKey: defaultsKey),
            let snap     = try? JSONDecoder().decode(QuireSnapshot.self, from: data)
        else { return QuireSnapshot() }
        return snap
    }

    public func save() {
        guard
            let defaults = UserDefaults(suiteName: QuireSnapshot.suiteName),
            let data     = try? JSONEncoder().encode(self)
        else { return }
        defaults.set(data, forKey: QuireSnapshot.defaultsKey)
        defaults.synchronize()
    }

    /// The look changed in the app: tell the widgets now rather than at the
    /// next journal rebuild.
    public static func updateTheme(_ id: String) {
        var snap = load()
        guard snap.themeID != id else { return }
        snap.themeID = id
        snap.save()
        reloadWidgets()
    }

    public static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

/// The deck of writing prompts, and which one is up today. The offset (each
/// "another prompt" — `p` in the app, the widget's button) lives in the App
/// Group so the app and its widgets show the same prompt.
public enum QuirePrompts {
    public static let deck: [String] = [
        "What surprised you today?",
        "What would you tell yourself a year ago?",
        "Describe where you are right now — all five senses.",
        "What's the smallest thing that made you smile lately?",
        "What are you avoiding writing about?",
        "Who did you last have a real conversation with?",
        "What did you almost do today?",
        "What's changed since this time last month?",
        "Write about something you're looking forward to.",
        "What's a question you can't answer yet?",
        "What did you notice on the way somewhere today?",
        "What would you do with a free afternoon tomorrow?",
        "What's worth remembering about this week?",
        "Describe today in exactly three sentences.",
        "What are you carrying that you could put down?",
        "What did you learn the hard way recently?",
        "Write the first paragraph of the story of today.",
        "What sound, smell, or taste took you somewhere else?",
        "What do you want more of? Less of?",
        "Who deserves a thank-you you haven't sent?",
    ]

    public static let offsetKey = "quirePromptOffset"
    public static var defaults: UserDefaults {
        UserDefaults(suiteName: QuireSnapshot.suiteName) ?? .standard
    }
    public static var offset: Int { defaults.integer(forKey: offsetKey) }

    /// Today's prompt (the day of the year walks the deck), `offset` rerolls on.
    public static func prompt(on date: Date = Date(), offset: Int) -> String {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 0
        let n = deck.count
        return deck[((day + offset) % n + n) % n]
    }

    /// Another prompt, everywhere.
    public static func next() {
        defaults.set(offset + 1, forKey: offsetKey)
        QuireSnapshot.reloadWidgets()
    }
}
