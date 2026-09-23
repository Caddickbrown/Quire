package com.caddickbrown.wander.editor

import android.graphics.Paint
import android.graphics.Typeface
import android.text.TextPaint
import android.text.style.AbsoluteSizeSpan
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.LeadingMarginSpan
import android.text.style.LineHeightSpan
import android.text.style.MetricAffectingSpan
import android.text.style.UnderlineSpan

/**
 * Spans the styler owns.
 *
 * Every span Wander applies implements [WanderSpan], so a restyle can clear its
 * own work out of a range without touching anything the platform put there —
 * the IME's composing underline, the selection, a spell-checker's mark. That
 * distinction is the whole trick of styling a live text view: the text object is
 * shared with the input method, and reaching into it indiscriminately is what
 * makes editors on Android fight the keyboard.
 */
interface WanderSpan

class WForeground(color: Int) : ForegroundColorSpan(color), WanderSpan

class WBackground(color: Int) : BackgroundColorSpan(color), WanderSpan

class WSize(sizePx: Int) : AbsoluteSizeSpan(sizePx, false), WanderSpan

class WUnderline : UnderlineSpan(), WanderSpan

class WIndent(every: Int) : LeadingMarginSpan.Standard(every), WanderSpan

/**
 * A typeface, applied as itself rather than by family name.
 *
 * `TypefaceSpan(Typeface)` only arrived in API 28, and the app runs from 26 —
 * and even where it exists it will not carry a face loaded from assets on every
 * vendor's text stack. Setting the paint's typeface directly always works.
 */
class WTypeface(private val typeface: Typeface) : MetricAffectingSpan(), WanderSpan {
    override fun updateDrawState(paint: TextPaint) = apply(paint)
    override fun updateMeasureState(paint: TextPaint) = apply(paint)
    private fun apply(paint: Paint) {
        paint.typeface = typeface
    }
}

/**
 * Air above a paragraph — what a heading needs and what Android, unlike
 * TextKit, has no paragraph-spacing attribute for. Added to the ascent of the
 * paragraph's first line only, so the gap lands above the heading rather than
 * inside it.
 */
class WSpaceAbove(private val space: Int) : LineHeightSpan, WanderSpan {
    override fun chooseHeight(
        text: CharSequence, start: Int, end: Int,
        spanstartv: Int, lineHeight: Int, fm: Paint.FontMetricsInt,
    ) {
        val spanStart = (text as? android.text.Spanned)?.getSpanStart(this) ?: return
        if (start != spanStart) return
        fm.ascent -= space
        fm.top -= space
    }
}
