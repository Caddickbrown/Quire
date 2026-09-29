package com.caddickbrown.wander.core

/**
 * Pure parsing/rendering of the jnl markdown format, ported from
 * WanderCore/Sources/WanderCore/JournalParser.swift (itself a port of the Go
 * `jnl` CLI) so Wander's files round-trip byte-identically with jnl, Nook, the
 * Apple builds and the Tauri build: a `[YYYY-MM-DD HH:MM:SS] optional title`
 * header line followed by the body.
 *
 * No Android dependencies — this file is plain Kotlin and unit-testable as such.
 */
object JournalParser {

    // Header: [YYYY-MM-DD HH:MM:SS] optional trailing text.
    // Accepts ASCII hyphen or en-dash in the date (jnl normalises to hyphen).
    private val headerRegex = Regex("""^\[(\d{4}[-–]\d{2}[-–]\d{2}) (\d{2}:\d{2}:\d{2})\](.*)""")

    private val tagRegex = Regex("""@[a-zA-Z][a-zA-Z0-9_-]*""")

    private data class Header(val date: String, val time: String, val suffix: String)

    private fun matchHeader(line: String): Header? {
        val m = headerRegex.find(line) ?: return null
        return Header(m.groupValues[1], m.groupValues[2], m.groupValues[3])
    }

    fun isHeaderLine(line: String): Boolean = matchHeader(line) != null

    /**
     * The one form every file is read in: LF line endings and no byte-order
     * mark. A file saved on Windows with CRLF would otherwise keep a `\r` on
     * every interior line and come back half CRLF, half LF after a rewrite; a
     * leading BOM would stop the first header matching `^\[`, so the first
     * entry would be read as preamble and never shown. Both are dropped on the
     * next write, which is jnl's form too: LF, no BOM.
     */
    fun normalise(content: String): String =
        content.removePrefix("\uFEFF").replace("\r\n", "\n")

    /**
     * Split file content into entries. Content before the first header is
     * dropped here — [leadingPreamble] preserves it across a rewrite.
     */
    fun parseEntries(content: String, source: String? = null): List<Entry> {
        val entries = ArrayList<Entry>()
        var cur = ArrayList<String>()
        var curTS = ""
        var curDate = ""
        var curSuffix = ""

        fun flush() {
            if (curTS.isEmpty()) return
            val body = cur.drop(1).joinToString("\n").trim()
            entries.add(
                Entry(
                    date = curDate, ts = curTS, suffix = curSuffix,
                    body = body, raw = cur.joinToString("\n"), source = source,
                )
            )
        }

        for (line in normalise(content).split("\n")) {
            val h = matchHeader(line)
            if (h != null) {
                flush()
                curDate = h.date.replace('–', '-')
                curTS = "$curDate ${h.time}"
                curSuffix = h.suffix.trim()
                // Normalise the header to ASCII hyphens so raw round-trips cleanly.
                var normHeader = "[$curTS]"
                if (curSuffix.isNotEmpty()) normHeader += " $curSuffix"
                cur = arrayListOf(normHeader)
            } else if (curTS.isNotEmpty()) {
                cur.add(line)
            }
        }
        flush()
        return entries
    }

    /**
     * Content before the first header (or "" if only blank/absent). Rewrites
     * must preserve this or a hand-written file header would be lost.
     */
    fun leadingPreamble(content: String): String {
        val pre = ArrayList<String>()
        for (line in normalise(content).split("\n")) {
            if (matchHeader(line) != null) break
            pre.add(line)
        }
        val text = trimRightNewlines(pre.joinToString("\n"))
        return if (text.isBlank()) "" else text
    }

    /**
     * Copy ordered by timestamp, oldest first. Stable; input untouched.
     * ts is fixed-width, so a lexicographic compare is chronological.
     */
    fun sortedByTimestamp(entries: List<Entry>): List<Entry> =
        entries.sortedBy { it.ts }   // Kotlin's sort is stable

    /**
     * Rebuild file content from a preamble + entries, preserving the preamble
     * and each entry's raw text. Returns "" when there is nothing.
     */
    fun renderEntries(preamble: String, entries: List<Entry>): String {
        val parts = ArrayList<String>()
        if (preamble.isNotEmpty()) parts.add(trimRightNewlines(preamble))
        for (e in entries) parts.add(trimRightNewlines(e.raw))
        if (parts.isEmpty()) return ""
        return parts.joinToString("\n\n") + "\n"
    }

    /** All `@tag` tokens in [s], in order of appearance. */
    fun splitTags(s: String): List<String> = tagRegex.findAll(s).map { it.value }.toList()

    /** Trim only trailing "\n" (Go's strings.TrimRight(s, "\n")). */
    fun trimRightNewlines(s: String): String = s.trimEnd('\n')
}

/** The three views onto one folder. */
enum class Page(val key: String, val label: String) {
    JOURNAL("journal", "Journal"),
    INBOX("inbox", "Inbox"),
    STARRED("starred", "Starred");

    companion object {
        fun of(key: String?): Page = entries.firstOrNull { it.key == key } ?: JOURNAL
    }
}

/** Grouping and counting shared by every front end. */
object JournalIndex {

    data class Month(val title: String, val entries: List<Entry>)

    /**
     * Entries grouped into month sections, newest month first.
     *
     * [list] arrives sorted by timestamp, so a month is a run rather than a
     * bucket: the sections are slices of it.
     */
    fun months(list: List<Entry>): List<Month> {
        if (list.isEmpty()) return emptyList()
        val out = ArrayList<Month>()
        var start = 0
        var key = list[0].date.take(7)   // YYYY-MM
        for (index in 1 until list.size) {
            val next = list[index].date.take(7)
            if (next == key) continue
            out.add(Month(monthTitle(key), list.subList(start, index)))
            start = index
            key = next
        }
        out.add(Month(monthTitle(key), list.subList(start, list.size)))
        return out
    }

    /** Memoised: there are as many of these as the journal has months. */
    private val monthTitles = HashMap<String, String>()

    private fun monthTitle(key: String): String =
        monthTitles.getOrPut(key) { Formats.monthTitle(key) }

    /**
     * Consecutive days written, counting back from today — or from yesterday, so
     * a streak isn't reported broken before the day's first entry.
     */
    fun streak(entries: List<Entry>): Int {
        val days = entries.mapTo(HashSet()) { it.date }
        if (days.isEmpty()) return 0
        var cursor = java.time.LocalDate.now()
        if (!days.contains(Formats.day(cursor))) {
            cursor = cursor.minusDays(1)
            if (!days.contains(Formats.day(cursor))) return 0
        }
        var count = 0
        while (days.contains(Formats.day(cursor))) {
            count += 1
            cursor = cursor.minusDays(1)
        }
        return count
    }

    fun matches(entry: Entry, query: String): Boolean {
        val q = query.trim().lowercase()
        return q.isEmpty() || entry.raw.lowercase().contains(q)
    }
}
