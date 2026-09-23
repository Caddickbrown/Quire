package com.caddickbrown.wander

import com.caddickbrown.wander.core.Counts
import com.caddickbrown.wander.core.Entry
import com.caddickbrown.wander.core.JournalPaths
import com.caddickbrown.wander.core.JournalParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The format is the contract between five programs — the macOS app, the iOS
 * app, the Tauri app, the `jnl` CLI and this one — so these tests are about
 * bytes, not behaviour. Anything that changes what lands on disk should fail
 * here first.
 */
class ParserTest {

    private val sample = """
        # My journal

        [2026-09-08 08:12:00] The long way round the reservoir *
        Left before seven and took the **long way** round.

        ## What the light was doing

        - ask about the boiler service @admin

        [2026-09-08 19:40:00] Evening
        Nothing much. @admin @Admin @later
    """.trimIndent()

    @Test
    fun `parses entries and leaves the preamble out of them`() {
        val entries = JournalParser.parseEntries(sample, "journal/2026/09/08.md")
        assertEquals(2, entries.size)
        assertEquals("2026-09-08 08:12:00", entries[0].ts)
        assertEquals("2026-09-08", entries[0].date)
        assertEquals("The long way round the reservoir *", entries[0].suffix)
        assertTrue(entries[0].body.startsWith("Left before seven"))
        assertFalse(entries[0].body.contains("My journal"))
    }

    @Test
    fun `preamble survives a rewrite`() {
        val preamble = JournalParser.leadingPreamble(sample)
        assertEquals("# My journal", preamble)

        val entries = JournalParser.parseEntries(sample, "journal/2026/09/08.md")
        val rendered = JournalParser.renderEntries(preamble, entries)
        // Round trip: everything that was there is still there, in order.
        assertTrue(rendered.startsWith("# My journal\n\n"))
        assertTrue(rendered.contains("[2026-09-08 08:12:00] The long way round the reservoir *"))
        assertTrue(rendered.contains("[2026-09-08 19:40:00] Evening"))
        assertTrue(rendered.endsWith("\n"))
    }

    @Test
    fun `rendering is idempotent, so a rewrite never churns the file`() {
        val preamble = JournalParser.leadingPreamble(sample)
        val once = JournalParser.renderEntries(preamble, JournalParser.parseEntries(sample, "x.md"))
        val twice = JournalParser.renderEntries(
            JournalParser.leadingPreamble(once),
            JournalParser.parseEntries(once, "x.md"),
        )
        // The bytes are the contract. Saving an untouched file must not change
        // it, or every entry would show as modified to a sync client.
        assertEquals(once, twice)
    }

    @Test
    fun `reparsing a render gives back the same entries`() {
        val first = JournalParser.parseEntries(sample, "x.md")
        val rendered = JournalParser.renderEntries(JournalParser.leadingPreamble(sample), first)
        val second = JournalParser.parseEntries(rendered, "x.md")
        assertEquals(first.map { it.ts }, second.map { it.ts })
        assertEquals(first.map { it.suffix }, second.map { it.suffix })
        assertEquals(first.map { it.body }, second.map { it.body })
        // `raw` is the one thing that legitimately differs: the file ends in a
        // newline, so on the way back the last entry's raw carries it. The Swift
        // and Rust ports do the same, and `renderEntries` trims it again, which
        // is why the rendered bytes above are stable regardless.
        assertEquals(
            first.map { JournalParser.trimRightNewlines(it.raw) },
            second.map { JournalParser.trimRightNewlines(it.raw) },
        )
    }

    @Test
    fun `a star is a standalone token, not any trailing asterisk`() {
        val starred = Entry.of("2026-01-01 09:00:00", "A title *", "", null)
        assertTrue(starred.isStarred)
        assertEquals("A title", starred.displayTitle)

        // The bug this guards: a bold title ends in an asterisk too, and
        // un-starring it used to eat one of them.
        val bold = Entry.of("2026-01-01 09:00:00", "**Important**", "", null)
        assertFalse(bold.isStarred)
        assertEquals("**Important**", bold.displayTitle)

        val bare = Entry.of("2026-01-01 09:00:00", "*", "", null)
        assertTrue(bare.isStarred)
        assertEquals("", bare.displayTitle)
    }

    @Test
    fun `starring round-trips through the title`() {
        val plain = Entry.of("2026-01-01 09:00:00", "A title", "Body", "inbox.md")
        val starred = plain.revised(plain.displayTitle, plain.body, starred = true)
        assertEquals("A title *", starred.suffix)
        val back = starred.revised(starred.displayTitle, starred.body, starred = false)
        assertEquals("A title", back.suffix)
        assertEquals(plain.raw, back.raw)
    }

    @Test
    fun `tags are deduplicated case-insensitively, in order of appearance`() {
        val entries = JournalParser.parseEntries(sample, "x.md")
        assertEquals(listOf("@admin", "@later"), entries[1].tags)
    }

    @Test
    fun `an en-dash date is normalised to hyphens`() {
        val text = "[2026–09–08 08:12:00] Title\nBody"
        val entry = JournalParser.parseEntries(text, "x.md").single()
        assertEquals("2026-09-08 08:12:00", entry.ts)
        assertEquals("2026-09-08", entry.date)
        assertTrue(entry.raw.startsWith("[2026-09-08 08:12:00]"))
    }

    @Test
    fun `entries sort chronologically and stably`() {
        val a = Entry.of("2026-01-01 09:00:00", "a", "", "x.md")
        val b = Entry.of("2026-01-01 08:00:00", "b", "", "x.md")
        val c = Entry.of("2026-01-01 09:00:00", "c", "", "x.md")
        val sorted = JournalParser.sortedByTimestamp(listOf(a, b, c))
        assertEquals(listOf("b", "a", "c"), sorted.map { it.suffix })
    }

    @Test
    fun `a day file is journal slash year slash month slash day`() {
        assertEquals("journal/2026/09/08.md", JournalPaths.dayFile("2026-09-08"))
        assertNull(JournalPaths.dayFile("nonsense"))
    }

    @Test
    fun `an entry in the inbox is unfiled and one in a day file is not`() {
        assertTrue(Entry.of("2026-01-01 09:00:00", "", "", "inbox.md").isUnfiled)
        assertFalse(Entry.of("2026-01-01 09:00:00", "", "", "journal/2026/01/01.md").isUnfiled)
        assertFalse(Entry.of("2026-01-01 09:00:00", "", "", null).isUnfiled)
    }

    @Test
    fun `an empty entry renders as a bare header`() {
        val blank = Entry.of("2026-01-01 09:00:00", "", "", "inbox.md")
        assertEquals("[2026-01-01 09:00:00]", blank.raw)
    }

    @Test
    fun `preview falls back to the first body line with its markers stripped`() {
        val entry = Entry.of("2026-01-01 09:00:00", "", "## A heading\nand more", "x.md")
        assertEquals("A heading", entry.preview)
    }

    @Test
    fun `counts walk the text the way the status line reports it`() {
        assertEquals(3, Counts.words("one two  three"))
        assertEquals(0, Counts.words("   \n\t "))
        assertEquals(0, Counts.readingMinutes(""))
        assertEquals(1, Counts.readingMinutes("a few words here"))
        assertEquals(2, Counts.paragraphs("one\n\ntwo"))
    }
}
