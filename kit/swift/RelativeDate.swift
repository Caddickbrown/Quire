// Relative dates, worded the same in every app. The JS twin is
// kit/js/relative-date.js; both must pass kit/vectors/relative-date.json.
//
//   under a minute      just now
//   under an hour       5 min ago
//   earlier today       14:02
//   yesterday           Yesterday 14:02
//   2–6 days ago        Tue
//   this year           12 Oct
//   older               12 Oct 2025
//
// Days are calendar days in `timeZone`, not 24-hour spans, so 23:59 last night
// is "Yesterday" at 00:01. A future date reads as its time if it is today,
// otherwise as its date. The words are fixed English, not localised, so every
// app and the web read the same.

import Foundation

enum RelativeDate {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func string(for date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if abs(seconds) < 60 { return "just now" }
        if seconds > 0, seconds < 3600 { return "\(Int(seconds / 60)) min ago" }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let then = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        let thisYear = calendar.component(.year, from: now)
        let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day ?? 0
        let time = String(format: "%02d:%02d", then.hour ?? 0, then.minute ?? 0)

        switch daysAgo {
        case 0: return time
        case 1: return "Yesterday \(time)"
        case 2...6: return weekdays[(then.weekday ?? 1) - 1]
        default:
            let short = "\(then.day ?? 1) \(months[(then.month ?? 1) - 1])"
            return then.year == thisYear ? short : "\(short) \(then.year ?? thisYear)"
        }
    }
}
