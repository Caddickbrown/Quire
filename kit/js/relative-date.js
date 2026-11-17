// Relative dates, worded the same in every app. The Swift twin is
// kit/swift/RelativeDate.swift; both must pass kit/vectors/relative-date.json.
//
//   under a minute      just now
//   under an hour       5 min ago
//   earlier today       14:02
//   yesterday           Yesterday 14:02
//   2–6 days ago        Tue
//   this year           12 Oct
//   older               12 Oct 2025
//
// Days are calendar days in `timeZone` (default: the device's), not 24-hour
// spans, so 23:59 last night is "Yesterday" at 00:01. A future date reads as
// its time if it is today, otherwise as its date.

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function localParts(date, timeZone) {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone, year: "numeric", month: "numeric", day: "numeric",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(date);
  const get = (type) => Number(parts.find((p) => p.type === type).value);
  const y = get("year"), m = get("month"), d = get("day");
  const day = Date.UTC(y, m - 1, d) / 864e5; // calendar day number, zone-free
  const hh = String(get("hour")).padStart(2, "0");
  const mm = String(get("minute")).padStart(2, "0");
  return { y, m, d, day, time: `${hh}:${mm}`, weekday: WEEKDAYS[new Date(day * 864e5).getUTCDay()] };
}

/**
 * @param {Date} date      the moment to describe
 * @param {Date} [now]     the moment to describe it from
 * @param {{timeZone?: string}} [options]
 * @returns {string}
 */
export function relativeDate(date, now = new Date(), { timeZone } = {}) {
  const ms = now.getTime() - date.getTime();
  if (Math.abs(ms) < 60_000) return "just now";
  if (ms > 0 && ms < 3_600_000) return `${Math.floor(ms / 60_000)} min ago`;

  const then = localParts(date, timeZone);
  const today = localParts(now, timeZone);
  const daysAgo = today.day - then.day;

  if (daysAgo === 0) return then.time;
  if (daysAgo === 1) return `Yesterday ${then.time}`;
  if (daysAgo >= 2 && daysAgo <= 6) return then.weekday;
  const short = `${then.d} ${MONTHS[then.m - 1]}`;
  return then.y === today.y ? short : `${short} ${then.y}`;
}
