//
//  NookShared.swift
//  Nook
//
//  Data shared between the main app and the widget extension via
//  an App Group UserDefaults container. The main app writes a
//  NookSnapshot after every reload; the widget reads it on its
//  timeline refresh.
//
//  Both targets must include this file (add it to the widget extension
//  target in Xcode alongside NookWidget.swift).
//

import Foundation
// ActivityKit imports on macOS but its types are iOS-only, so gate on the OS.
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

#if os(iOS) && canImport(ActivityKit)
/// The writing-timer Live Activity (Dynamic Island / Lock Screen countdown).
/// Defined here because the app starts it and the widget extension renders it.
public struct NookTimerAttributes: ActivityAttributes {
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
    public init(accentRaw: String = "blue") { self.accentRaw = accentRaw }
}
#endif

public struct NookSnapshot: Codable {
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

    /// Deep link to one entry (`nook://entry?date=…&ts=…`), used by the widget
    /// and notifications; the app resolves it via the archive lookup.
    public static func entryURL(date: String, ts: String) -> URL? {
        var c = URLComponents()
        c.scheme = "nook"
        c.host = "entry"
        c.queryItems = [URLQueryItem(name: "date", value: date),
                        URLQueryItem(name: "ts", value: ts)]
        return c.url
    }

    // App Group suite shared between app + widget extension.
    public static let suiteName = "group.com.caddickbrown.nook"
    public static let defaultsKey = "nook.widgetSnapshot"

    public static func load() -> NookSnapshot {
        guard
            let defaults = UserDefaults(suiteName: suiteName),
            let data     = defaults.data(forKey: defaultsKey),
            let snap     = try? JSONDecoder().decode(NookSnapshot.self, from: data)
        else { return NookSnapshot() }
        return snap
    }

    public func save() {
        guard
            let defaults = UserDefaults(suiteName: NookSnapshot.suiteName),
            let data     = try? JSONEncoder().encode(self)
        else { return }
        defaults.set(data, forKey: NookSnapshot.defaultsKey)
        defaults.synchronize()
    }
}
