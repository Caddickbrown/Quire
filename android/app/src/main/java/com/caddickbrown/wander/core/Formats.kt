package com.caddickbrown.wander.core

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

/**
 * Date formats used across the app. Fixed-locale where the string is a file
 * format ([STAMP]), user-locale where it is read by a person.
 *
 * The timestamps are local wall-clock times with no zone in them — that is the
 * jnl format, and it is what makes a journal folder portable between a laptop
 * in London and a phone in Lisbon. `LocalDateTime` is the type that says so.
 */
object Formats {
    const val STAMP = "yyyy-MM-dd HH:mm:ss"

    private val stampFormat: DateTimeFormatter =
        DateTimeFormatter.ofPattern(STAMP, Locale.US)
    private val dayFormat: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd", Locale.US)
    private val clockFormat: DateTimeFormatter =
        DateTimeFormatter.ofPattern("HH:mm", Locale.US)

    fun stamp(at: LocalDateTime): String = stampFormat.format(at)

    fun stampNow(): String = stamp(LocalDateTime.now().withNano(0))

    fun day(at: LocalDate): String = dayFormat.format(at)

    fun today(): String = day(LocalDate.now())

    fun clock(at: LocalDateTime): String = clockFormat.format(at)

    /** "Tuesday, 8 September 2026" */
    fun longDay(at: LocalDateTime): String {
        val weekday = at.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.getDefault())
        val month = at.month.getDisplayName(TextStyle.FULL, Locale.getDefault())
        return "$weekday, ${at.dayOfMonth} $month ${at.year}"
    }

    /** "8 Sep" */
    fun shortDay(at: LocalDateTime): String {
        val month = at.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())
        return "${at.dayOfMonth} $month"
    }

    /** "September 2026" — the index's month rules. */
    fun monthTitle(key: String): String {
        val date = runCatching { LocalDate.parse("$key-01", dayFormat) }.getOrNull()
            ?: return key
        val month = date.month.getDisplayName(TextStyle.FULL, Locale.getDefault())
        return "$month ${date.year}"
    }

    /**
     * "YYYY-MM-DD HH:MM:SS" to a moment, read straight off the digits.
     *
     * This is the parser without the parser: the shape is fixed and ours, and
     * `DateTimeFormatter` is far too slow to run over every entry in a journal
     * when the index is being rebuilt.
     */
    fun moment(ts: String): LocalDateTime? {
        if (ts.length < 19) return null
        fun number(at: Int, length: Int): Int? {
            var value = 0
            for (i in at until at + length) {
                val c = ts[i]
                if (c < '0' || c > '9') return null
                value = value * 10 + (c - '0')
            }
            return value
        }
        val year = number(0, 4) ?: return null
        val month = number(5, 2) ?: return null
        val day = number(8, 2) ?: return null
        val hour = number(11, 2) ?: return null
        val minute = number(14, 2) ?: return null
        val second = number(17, 2) ?: return null
        return runCatching { LocalDateTime.of(year, month, day, hour, minute, second) }.getOrNull()
    }

    /** One second later, in stamp form — used to find a free timestamp. */
    fun nextSecond(ts: String): String {
        val moment = moment(ts) ?: return ts
        return stamp(moment.plusSeconds(1))
    }

    fun groupNumber(n: Int): String = String.format(Locale.US, "%03d", n)

    fun thousands(n: Int): String = String.format(Locale.getDefault(), "%,d", n)
}

/** Where things live inside a journal folder. */
object JournalPaths {
    const val INBOX = "inbox.md"
    const val JOURNAL = "journal"

    /** journal/YYYY/MM/DD.md for a "YYYY-MM-DD" date, or null if it isn't one. */
    fun dayFile(date: String): String? {
        val parts = date.split("-")
        if (parts.size != 3) return null
        return "$JOURNAL/${parts[0]}/${parts[1]}/${parts[2]}.md"
    }

    /** The last component of a relative path, for display. */
    fun name(path: String): String = path.substringAfterLast('/')
}
