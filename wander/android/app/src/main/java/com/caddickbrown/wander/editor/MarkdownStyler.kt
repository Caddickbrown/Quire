package com.caddickbrown.wander.editor

import android.text.Spannable
import android.text.Spanned
import androidx.compose.ui.text.font.FontWeight
import com.caddickbrown.wander.ui.FaceSpec
import com.caddickbrown.wander.ui.Fonts
import com.caddickbrown.wander.ui.Theme

/**
 * Draws markdown as typography rather than as syntax. The text stays plain
 * markdown — what changes is how it looks: headings take the display serif,
 * quotes go italic and indent, code takes a tinted monospace, and every marker
 * (#, **, >, backtick) fades back so the prose reads clean with the structure
 * still visible.
 *
 * Ported rule for rule from Sources/Wander/Support/MarkdownStyle.swift. The one
 * thing that is not a port is what it does to the text: nothing. It only ever
 * adds and removes spans, never a character, which is what lets it run on every
 * keystroke without the input method losing its place.
 */
class MarkdownStyler(
    private val theme: Theme,
    private val size: Float,          // px
    private val leading: Float,
    private val dimInactive: Boolean,
) {

    private companion object {
        // Line-bound block rules.
        val heading = Regex("""^(#{1,6})[ \t]+(.*)$""", RegexOption.MULTILINE)
        val quote = Regex("""^([ \t]*>[ \t]?)(.*)$""", RegexOption.MULTILINE)
        val bullet = Regex("""^([ \t]*)([-*+]|\d{1,3}\.)[ \t]+""", RegexOption.MULTILINE)
        val divider = Regex("""^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$""", RegexOption.MULTILINE)
        val fence = Regex("""^```.*?^```""", setOf(RegexOption.MULTILINE, RegexOption.DOT_MATCHES_ALL))

        // Inline rules.
        val strong = Regex("""(\*\*|__)(?=\S)(.+?)(?<=\S)\1""")
        val emphasis = Regex("""(?<![*\w])([*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![*\w])""")
        val code = Regex("""`([^`\n]+)`""")
        val link = Regex("""\[([^\]\n]*)\]\(([^)\s]+)\)""")
        val tag = Regex("""@[a-zA-Z][a-zA-Z0-9_-]*""")

        /** Above this, a keystroke restyles its own paragraph rather than the lot. */
        const val WHOLE_TEXT_LIMIT = 8_000

        val headingScale = floatArrayOf(1.55f, 1.30f, 1.14f, 1.04f, 1.0f, 1.0f)
    }

    private val marker = theme.muted.opacity(0.45f).argb

    /**
     * Restyle [text]. [caret] is where the insertion point is — its paragraph is
     * the unit restyled on a keystroke, and the one left lit in focus mode.
     */
    fun apply(text: Spannable, caret: Int, restyleAll: Boolean) {
        val length = text.length
        val whole = 0 to length

        // Focus mode dims everything outside the live paragraph, so it has to
        // see the whole text however long it is.
        val target = if (restyleAll || dimInactive || length <= WHOLE_TEXT_LIMIT) whole
        else paragraphRange(text, caret.coerceIn(0, length))

        clear(text, target.first, target.second)

        val (from, to) = target
        val slice = text.substring(from, to)

        fun span(what: Any, start: Int, end: Int) {
            val s = from + start
            val e = from + end
            if (s < 0 || e > length || e <= s) return
            text.setSpan(what, s, e, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }

        fun face(spec: FaceSpec, weight: FontWeight, italic: Boolean = false) =
            WTypeface(Fonts.typeface(spec, weight, italic))

        // The base: body face, prose colour, over the whole restyled range.
        span(face(theme.proseFace, theme.proseWeight), 0, slice.length)
        span(WForeground(theme.prose.argb), 0, slice.length)

        // Headings — the display sizes carry the hierarchy, the hashes fade.
        for (m in heading.findAll(slice)) {
            val hashes = m.groups[1] ?: continue
            val level = hashes.value.length
            val scale = headingScale[(level - 1).coerceIn(0, 5)]
            span(face(theme.displayFace, FontWeight.SemiBold), m.range.first, m.range.last + 1)
            span(WSize((size * scale).toInt()), m.range.first, m.range.last + 1)
            span(WForeground(theme.ink.argb), m.range.first, m.range.last + 1)
            span(WSpaceAbove((size * 0.9f).toInt()), m.range.first, m.range.last + 1)
            // The hashes stay, but at body size and hairline grey, so they read
            // as a printer's mark beside the heading rather than part of it.
            span(face(theme.proseFace, theme.proseWeight), hashes.range.first, hashes.range.last + 1)
            span(WSize((size * 0.85f).toInt()), hashes.range.first, hashes.range.last + 1)
            span(WForeground(marker), hashes.range.first, hashes.range.last + 1)
        }

        // Block quotes — italic, indented, in the muted voice of a margin note.
        for (m in quote.findAll(slice)) {
            val mark = m.groups[1] ?: continue
            span(face(theme.proseFace, theme.proseWeight, italic = true), m.range.first, m.range.last + 1)
            span(WForeground(theme.muted.argb), m.range.first, m.range.last + 1)
            span(WIndent((size * 1.1f).toInt()), m.range.first, m.range.last + 1)
            span(face(theme.proseFace, theme.proseWeight), mark.range.first, mark.range.last + 1)
            span(WForeground(marker), mark.range.first, mark.range.last + 1)
        }

        // List markers pick up the accent; the item hangs off the marker.
        for (m in bullet.findAll(slice)) {
            val mark = m.groups[2] ?: continue
            span(WIndent((size * 1.2f).toInt()), m.range.first, m.range.last + 1)
            span(WForeground(theme.accent.argb), mark.range.first, mark.range.last + 1)
        }

        for (m in divider.findAll(slice)) {
            span(WForeground(marker), m.range.first, m.range.last + 1)
        }

        for (m in strong.findAll(slice)) {
            val inner = m.groups[2] ?: continue
            val fence = m.groups[1]?.value?.length ?: 2
            span(face(theme.proseFace, FontWeight.Bold), inner.range.first, inner.range.last + 1)
            span(WForeground(theme.ink.argb), inner.range.first, inner.range.last + 1)
            span(WForeground(marker), m.range.first, m.range.first + fence)
            span(WForeground(marker), m.range.last + 1 - fence, m.range.last + 1)
        }

        for (m in emphasis.findAll(slice)) {
            val inner = m.groups[2] ?: continue
            span(face(theme.proseFace, theme.proseWeight, italic = true), inner.range.first, inner.range.last + 1)
            span(WForeground(marker), m.range.first, m.range.first + 1)
            span(WForeground(marker), m.range.last, m.range.last + 1)
        }

        for (m in code.findAll(slice)) {
            val inner = m.groups[1] ?: continue
            span(face(theme.monoFace, FontWeight.Normal), m.range.first, m.range.last + 1)
            span(WSize((size * 0.88f).toInt()), m.range.first, m.range.last + 1)
            span(WBackground(theme.rule.opacity(0.5f).argb), m.range.first, m.range.last + 1)
            span(WForeground(theme.ink.argb), inner.range.first, inner.range.last + 1)
            span(WForeground(marker), m.range.first, m.range.first + 1)
            span(WForeground(marker), m.range.last, m.range.last + 1)
        }

        for (m in fence.findAll(slice)) {
            span(face(theme.monoFace, FontWeight.Normal), m.range.first, m.range.last + 1)
            span(WSize((size * 0.88f).toInt()), m.range.first, m.range.last + 1)
            span(WForeground(theme.prose.argb), m.range.first, m.range.last + 1)
            span(WBackground(theme.rule.opacity(0.35f).argb), m.range.first, m.range.last + 1)
            span(WIndent((size * 0.6f).toInt()), m.range.first, m.range.last + 1)
        }

        for (m in link.findAll(slice)) {
            val label = m.groups[1] ?: continue
            val url = m.groups[2] ?: continue
            span(WForeground(theme.accent.argb), label.range.first, label.range.last + 1)
            span(WUnderline(), label.range.first, label.range.last + 1)
            span(WForeground(marker), url.range.first, url.range.last + 1)
            span(face(theme.monoFace, FontWeight.Normal), url.range.first, url.range.last + 1)
            span(WSize((size * 0.8f).toInt()), url.range.first, url.range.last + 1)
        }

        // @tags — the same tokens Nook and jnl index on.
        for (m in tag.findAll(slice)) {
            span(WForeground(theme.accent.argb), m.range.first, m.range.last + 1)
        }

        // Focus mode: everything but the paragraph under the caret recedes.
        if (dimInactive) {
            val (liveStart, liveEnd) = paragraphRange(text, caret.coerceIn(0, length))
            val faded = theme.muted.opacity(0.38f).argb
            if (liveStart > 0) span(WForeground(faded), 0, liveStart)
            if (liveEnd < length) span(WForeground(faded), liveEnd, length)
        }
    }

    /** Take Wander's own spans out of a range, leaving the platform's alone. */
    private fun clear(text: Spannable, from: Int, to: Int) {
        for (span in text.getSpans(from, to, WanderSpan::class.java)) text.removeSpan(span)
    }

    /** The paragraph containing [at] — a run between blank-line boundaries. */
    private fun paragraphRange(text: CharSequence, at: Int): Pair<Int, Int> {
        var start = at
        while (start > 0 && text[start - 1] != '\n') start -= 1
        var end = at
        while (end < text.length && text[end] != '\n') end += 1
        return start to end
    }
}
