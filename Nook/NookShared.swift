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

public struct NookSnapshot: Codable {
    public var currentStreak: Int = 0
    public var bestStreak: Int    = 0
    public var totalDays: Int     = 0
    public var totalEntries: Int  = 0
    public var totalWords: Int    = 0
    public var inboxDrafts: Int   = 0
    public var accentRaw: String  = "blue"
    public var updatedAt: Date    = .distantPast

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
