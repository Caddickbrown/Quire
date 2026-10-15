//
//  TimerActivity.swift
//  Quire
//
//  The app side of the writing-timer Live Activity: started when the sidebar
//  timer starts, ended on pause/reset/expiry. The countdown itself is drawn by
//  the system from `endDate`, so nothing updates per-second. iOS only — the
//  widget extension renders it (QuireWidget.swift).
//

#if os(iOS)
import Foundation
import ActivityKit

@MainActor
enum TimerActivityController {
    private static var activity: Activity<QuireTimerAttributes>?

    /// Start (or restart) the activity for a session with `remaining` seconds.
    static func start(remaining: Int, wordsToday: Int, wordGoal: Int) {
        guard remaining > 0, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let accent = UserDefaults.standard.string(forKey: "accentColor") ?? "blue"
        let endDate = Date().addingTimeInterval(TimeInterval(remaining))
        let state = QuireTimerAttributes.ContentState(endDate: endDate,
                                                     wordsToday: wordsToday,
                                                     wordGoal: wordGoal)
        activity = try? Activity.request(
            attributes: QuireTimerAttributes(accentRaw: accent),
            content: .init(state: state, staleDate: endDate.addingTimeInterval(60)))
    }

    /// Tear the activity down (pause, reset, expiry, or app quit).
    static func end() {
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
