package com.caddickbrown.wander.core

/**
 * A single journal entry, in the jnl / Nook on-disk shape: a
 * `[YYYY-MM-DD HH:MM:SS] optional title` header line followed by the body.
 *
 * Ported from WanderCore/Sources/WanderCore/Entry.swift. The one deliberate
 * difference is [source]: the Apple builds hold a file URL, and this one holds
 * the path relative to the journal folder ("inbox.md", "journal/2026/09/08.md").
 * Android hands out `content://` document URIs rather than paths, and those are
 * neither stable nor comparable — the relative path is both, and the SAF layer
 * resolves it to a document when it comes time to read or write.
 */
data class Entry(
    val date: String,      // "YYYY-MM-DD"
    val ts: String,        // "YYYY-MM-DD HH:MM:SS"
    val suffix: String,    // text after the timestamp on the header line (the "title")
    val body: String,      // lines after the header, trimmed of leading/trailing blanks
    val raw: String,       // full original text including the normalised header line
    val source: String?,   // relative path of the file this was parsed from
) {
    /** Stable across reloads: one timestamp per file. Selection survives a re-read. */
    val id: String = "${source ?: "-"}#$ts"

    /** Counted once, at parse — the journal's total is a sum over thousands of these. */
    val wordCount: Int = Counts.words(body)

    /** The timestamp as a moment, parsed once off the digits. */
    val createdAt = Formats.moment(ts)

    /** The normalised header line, e.g. "[2026-05-10 08:00:00] A title". */
    val header: String get() = if (suffix.isEmpty()) "[$ts]" else "[$ts] $suffix"

    /**
     * Starred entries carry a trailing `*` on their title, so the flag lives in
     * the plain markdown and round-trips through the jnl CLI. The marker is a
     * standalone token — a bare `endsWith("*")` would also match a bold title
     * like `**Important**` and lose one `*` per un-star.
     */
    val isStarred: Boolean get() = suffix == "*" || suffix.endsWith(" *")

    /** The title with any trailing star marker (and its space) removed. */
    val displayTitle: String
        get() = if (!isStarred) suffix else suffix.dropLast(1).trim(' ', '\t')

    /**
     * One line for list rows: the title if there is one, else the first
     * non-empty body line with its markdown markers stripped.
     */
    val preview: String
        get() {
            val title = displayTitle
            if (title.isNotEmpty()) return title
            val first = body.split("\n").firstOrNull { it.isNotEmpty() } ?: ""
            return first.trim('#', '>', '-', '*', '_', ' ', '`')
        }

    /**
     * `@tag` tokens found anywhere in the raw text, in order of first appearance
     * and deduplicated — writing `@admin` three times still files under one tag.
     */
    val tags: List<String>
        get() {
            val seen = HashSet<String>()
            return JournalParser.splitTags(raw).filter { seen.add(it.lowercase()) }
        }

    /** Whether this entry lives in the undated inbox rather than a day file. */
    val isUnfiled: Boolean get() = source == JournalPaths.INBOX

    /** Rebuild from edited parts, keeping the timestamp (and so the file) fixed. */
    fun revised(title: String, body: String, starred: Boolean? = null): Entry {
        val star = starred ?: isStarred
        var suffix = title.trim()
        if (star) suffix = if (suffix.isEmpty()) "*" else "$suffix *"
        val cleanBody = body.trim()
        var head = "[$ts]"
        if (suffix.isNotEmpty()) head += " $suffix"
        val raw = if (cleanBody.isEmpty()) head else "$head\n$cleanBody"
        return Entry(date, ts, suffix, cleanBody, raw, source)
    }

    /** The same entry, said to live in another file. */
    fun movedTo(source: String?): Entry = copy(source = source)

    companion object {
        /** A blank entry stamped now, not yet written to disk. */
        fun blank(source: String? = null): Entry {
            val ts = Formats.stampNow()
            return Entry(ts.take(10), ts, "", "", "[$ts]", source)
        }

        /** An entry assembled from parts, with the header line normalised. */
        fun of(ts: String, suffix: String, body: String, source: String?): Entry {
            var head = "[$ts]"
            if (suffix.isNotEmpty()) head += " $suffix"
            return Entry(
                date = ts.take(10),
                ts = ts,
                suffix = suffix,
                body = body,
                raw = if (body.isEmpty()) head else "$head\n$body",
                source = source,
            )
        }
    }
}

/** Word / character counting, shared by the entry model and the status line. */
object Counts {
    /**
     * Counted by walking the characters rather than by split, which allocates a
     * list of substrings — the difference is an order of magnitude once the
     * caller is summing over a whole journal.
     */
    fun words(s: String): Int {
        var count = 0
        var inWord = false
        for (c in s) {
            if (c == ' ' || c == '\n' || c == '\t' || c == '\r') {
                inWord = false
            } else if (!inWord) {
                inWord = true
                count += 1
            }
        }
        return count
    }

    fun characters(s: String): Int = s.length

    /** Reading time in whole minutes, at the conventional 220 wpm, floored at 1. */
    fun readingMinutes(s: String): Int {
        val w = words(s)
        return if (w == 0) 0 else maxOf(1, Math.round(w / 220.0).toInt())
    }

    fun paragraphs(s: String): Int = s.split("\n\n").count { it.isNotBlank() }
}
