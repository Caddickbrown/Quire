//
//  Reminders.swift
//  Nook
//
//  Notifications, all of them:
//
//  * The daily writing reminder — a rolling fortnight of local notifications
//    at a user-chosen time, streak-aware: a day that already has an entry
//    cancels that evening's nudge, and the copy carries the streak. Its
//    "Write a line…" action takes text right in the banner and lands it in
//    the inbox through the same headless path Siri uses — no app launch.
//    Tapping the banner itself opens the composer.
//  * The weekly resurfacing note — an opt-in "From your journal" teaser
//    (starred first, then On This Day, then random) whose tap deep-links to
//    the entry.
//  * NotificationResponder — the UNUserNotificationCenter delegate that wires
//    both up — and NotificationRouter, the box it hands taps to so a cold
//    launch can't outrun the UI.
//

import Foundation
import UserNotifications

extension Notification.Name {
    /// The journal changed outside the UI (a quick-write from a banner).
    static let nookJournalChangedExternally = Notification.Name("com.caddickbrown.nook.journalChangedExternally")
}

// MARK: - Tap routing

/// Where a notification tap wants the app to go. Taps route through this
/// observable box rather than a one-shot `NotificationCenter` post because a
/// tap can land *before* the UI is listening — on a cold launch `didReceive`
/// arrives around the time the first view appears, and a post made a moment
/// too early is simply lost. `@Published` replays its current value to whoever
/// subscribes, so the tap still gets picked up whichever order they happen in.
@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()

    enum Action: Equatable {
        /// The daily reminder: open the composer on a blank draft.
        case write
        /// The weekly resurfacing note: open the entry it teased. `journal` is
        /// the split journal it lives in, when it isn't in the archive or the
        /// inbox — without it the tap on a split-journal entry found nothing.
        case entry(date: String, ts: String, journal: String? = nil)
    }

    @Published var pending: Action?
}

// MARK: - Delegate (actions + taps)

/// The notification-center delegate: routes the reminder's inline text into a
/// draft and resurfacing taps to their entry. Installed once at app start.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationResponder()

    static let reminderCategory = "nook.reminder"
    static let resurfaceCategory = "nook.resurface"
    static let writeActionID = "nook.write"

    /// Set the delegate and register the actionable categories. Called from
    /// NookApp.init, before any notification can be delivered to the app.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let write = UNTextInputNotificationAction(
            identifier: Self.writeActionID,
            title: "Write a line…",
            options: [],
            textInputButtonTitle: "Save",
            textInputPlaceholder: "A few words is plenty")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.reminderCategory,
                                   actions: [write], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.resurfaceCategory,
                                   actions: [], intentIdentifiers: []),
        ])
    }

    /// Show reminders even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if response.actionIdentifier == Self.writeActionID,
           let text = (response as? UNTextInputNotificationResponse)?.userText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { @MainActor in
                _ = try? JournalStore.quickAddDraft(title: "", body: text)
                NotificationCenter.default.post(name: .nookJournalChangedExternally, object: nil)
                completionHandler()
            }
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // A resurfacing note names an entry; the daily reminder doesn't —
            // tapping that one means "let me write", so it opens the composer.
            let action: NotificationRouter.Action
            if let ts = userInfo["ts"] as? String, !ts.isEmpty {
                let journal = userInfo["journal"] as? String
                action = .entry(date: userInfo["date"] as? String ?? "", ts: ts,
                                journal: (journal?.isEmpty ?? true) ? nil : journal)
            } else {
                action = .write
            }
            Task { @MainActor in
                NotificationRouter.shared.pending = action
                completionHandler()
            }
            return
        }
        completionHandler()
    }
}

@MainActor
enum ReminderScheduler {
    static let enabledKey = "dailyReminder"
    static let hourKey = "dailyReminderHour"
    static let minuteKey = "dailyReminderMinute"
    private static let requestID = "nook.dailyReminder"   // the pre-window single request
    private static let requestPrefix = "nook.dailyReminder."
    /// How many days of reminders are kept planned at a time. A repeating
    /// trigger can't skip the one evening that's already been written, and a
    /// lone one-shot for tomorrow leaves you with nothing at all if Nook isn't
    /// opened tomorrow — so a window of dated one-shots is planned instead and
    /// re-planned on every refresh.
    private static let horizon = 14

    static var defaultHour: Int { 21 }

    /// Re-plan the pending notifications. Called when the setting changes and
    /// after every store rebuild (which is when "has an entry today" can flip).
    static func refresh(hasEntryToday: Bool, streak: Int) {
        let defaults = UserDefaults.standard
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: [requestID] + (0..<horizon).map { "\(requestPrefix)\($0)" })
        guard defaults.bool(forKey: enabledKey) else { return }

        let hour = defaults.object(forKey: hourKey) as? Int ?? defaultHour
        let minute = defaults.object(forKey: minuteKey) as? Int ?? 0
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let now = Date()

        var slot = 0
        for offset in 0..<horizon {
            // Today's nudge is pointless once today has an entry.
            if offset == 0 && hasEntryToday { continue }
            guard let day = cal.date(byAdding: .day, value: offset, to: today),
                  let fire = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fire > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Time to write"
            // Only the next one can honestly talk about the streak — the days
            // behind it are planned blind, in case Nook isn't opened before
            // they fire.
            content.body = slot == 0 && streak > 1
                ? "Day \(streak + 1) is waiting — keep the streak going."
                : "A few lines is all it takes."
            content.sound = .default
            content.categoryIdentifier = NotificationResponder.reminderCategory

            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            center.add(UNNotificationRequest(
                identifier: "\(requestPrefix)\(slot)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            slot += 1
        }
    }

    /// Ask for permission when the user switches the reminder on. Returns
    /// whether notifications are allowed.
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }
}

// MARK: - Weekly resurfacing ("From your journal")

/// One notification a week teasing an old entry — starred first, then
/// On This Day, then random — tapping it opens the entry. The entry is chosen
/// when the notification is planned (app activation), one-shot, then re-planned
/// after it fires.
@MainActor
enum ResurfacingScheduler {
    static let enabledKey = "weeklyResurfacing"
    static let weekdayKey = "weeklyResurfacingWeekday"   // 1 = Sunday … 7 = Saturday
    static let hourKey = "weeklyResurfacingHour"
    private static let requestID = "nook.weeklyResurface"

    static var defaultWeekday: Int { 1 }   // Sunday
    static var defaultHour: Int { 10 }

    /// Make sure the next weekly note is planned (or cancelled). Cheap when
    /// one is already pending; called on app activation and from Settings.
    static func ensureScheduled(store: JournalStore) async {
        let defaults = UserDefaults.standard
        let center = UNUserNotificationCenter.current()
        guard defaults.bool(forKey: enabledKey) else {
            center.removePendingNotificationRequests(withIdentifiers: [requestID])
            return
        }
        let pending = await center.pendingNotificationRequests()
        guard !pending.contains(where: { $0.identifier == requestID }) else { return }

        // Pick what to resurface, best pool first.
        var date = "", ts = "", preview = "", journal = ""
        if let pick = store.starredEntries().randomElement() {
            preview = pick.entry.preview
            ts = pick.entry.ts
            // The pool spans the archive, the inbox and the split journals, so
            // the tap needs to know which — an archive-only hint used to leave
            // a split-journal pick opening nothing.
            switch pick.source {
            case .archive(let d):   date = d
            case .journal(let n):   journal = n
            case .inbox:            break
            }
        } else if let day = store.onThisDay().first, let entry = day.entries.first {
            date = day.date; ts = entry.ts; preview = entry.preview
        } else if let pick = store.randomEntry() {
            date = pick.date; ts = pick.entry.ts; preview = pick.entry.preview
        }
        guard !ts.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "From your journal"
        content.body = preview.isEmpty ? "A page worth rereading." : preview
        content.sound = .default
        content.categoryIdentifier = NotificationResponder.resurfaceCategory
        content.userInfo = ["date": date, "ts": ts, "journal": journal]

        var when = DateComponents()
        when.weekday = defaults.object(forKey: weekdayKey) as? Int ?? defaultWeekday
        when.hour = defaults.object(forKey: hourKey) as? Int ?? defaultHour
        // One-shot: the next activation after it fires plans the following one
        // with a freshly chosen entry.
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: trigger))
    }

    /// The setting changed — replan from scratch.
    static func settingsChanged(store: JournalStore) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestID])
        Task { await ensureScheduled(store: store) }
    }
}
