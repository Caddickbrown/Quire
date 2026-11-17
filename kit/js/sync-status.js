// The connection status line, worded the same in every app that talks to a
// self-hosted server. The Swift twin is kit/swift/SyncStatus.swift; both must
// pass kit/vectors/sync-status.json. Wording: kit/specs/WORDS.md.
//
// A status is one of:
//   { state: "connected", lastSync: Date }
//   { state: "syncing" }
//   { state: "unreachable" }
//   { state: "unauthorised" }
//   { state: "never" }
//
// `tone` names the colour role to draw the line in: "done", "inkSecondary" or "late".

import { relativeDate } from "./relative-date.js";

/**
 * @param {{state: string, lastSync?: Date}} status
 * @param {Date} [now]
 * @param {{timeZone?: string}} [options]
 * @returns {{text: string, tone: "done" | "inkSecondary" | "late"}}
 */
export function statusLine(status, now = new Date(), options = {}) {
  switch (status.state) {
    case "connected": {
      const when = relativeDate(status.lastSync, now, options).replace(/^Yesterday/, "yesterday");
      return { text: `Connected · Last synced ${when}`, tone: "done" };
    }
    case "syncing":
      return { text: "Syncing…", tone: "inkSecondary" };
    case "unreachable":
      return { text: "Couldn't reach the server. Your changes are safe on this device.", tone: "late" };
    case "unauthorised":
      return { text: "The server didn't accept the token.", tone: "late" };
    case "never":
      return { text: "Not connected", tone: "inkSecondary" };
    default:
      throw new Error(`unknown sync state: ${status.state}`);
  }
}
