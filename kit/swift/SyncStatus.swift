// The connection status line, worded the same in every app that talks to a
// self-hosted server. The JS twin is kit/js/sync-status.js; both must pass
// kit/vectors/sync-status.json. Wording: kit/specs/WORDS.md.
//
// Each app draws the line in its own style; `tone` names the colour role to
// draw it in.

import Foundation

enum SyncStatus: Equatable {
    case connected(lastSync: Date)
    case syncing
    case unreachable
    case unauthorised
    case never

    enum Tone: Equatable { case done, inkSecondary, late }

    struct Line: Equatable {
        let text: String
        let tone: Tone
    }

    func line(now: Date = Date(), timeZone: TimeZone = .current) -> Line {
        switch self {
        case .connected(let lastSync):
            var when = RelativeDate.string(for: lastSync, now: now, timeZone: timeZone)
            if when.hasPrefix("Yesterday") { when = "y" + when.dropFirst() }
            return Line(text: "Connected · Last synced \(when)", tone: .done)
        case .syncing:
            return Line(text: "Syncing…", tone: .inkSecondary)
        case .unreachable:
            return Line(text: "Couldn't reach the server. Your changes are safe on this device.", tone: .late)
        case .unauthorised:
            return Line(text: "The server didn't accept the token.", tone: .late)
        case .never:
            return Line(text: "Not connected", tone: .inkSecondary)
        }
    }
}
