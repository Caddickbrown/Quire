package com.caddickbrown.wander.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The theme in force, handed down the tree the way SwiftUI's environment does. */
val LocalTheme: ProvidableCompositionLocal<Theme> = compositionLocalOf { Themes.fallback }

@Composable
fun WanderTheme(theme: Theme, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalTheme provides theme, content = content)
}

// MARK: Type

/** Body prose, as the theme sets it. */
@Composable
fun proseStyle(size: Float = LocalTheme.current.proseSize): TextStyle {
    val theme = LocalTheme.current
    return TextStyle(
        fontFamily = Fonts.family(theme.proseFace),
        fontWeight = theme.proseWeight,
        fontSize = size.sp,
        color = theme.prose.color,
        lineHeight = (size * theme.lineHeight).sp,
    )
}

/** The display face — titles, the wordmark, the stats figures. */
@Composable
fun displayStyle(size: Float, weight: FontWeight? = null): TextStyle {
    val theme = LocalTheme.current
    return TextStyle(
        fontFamily = Fonts.family(theme.displayFace),
        fontWeight = weight ?: theme.displayWeight,
        fontSize = size.sp,
        letterSpacing = theme.displayTracking.sp,
        color = theme.ink.color,
    )
}

/** Interface text that isn't a label: field values, the search field, row meta. */
@Composable
fun uiStyle(size: Float = 13f, weight: FontWeight = FontWeight.Normal): TextStyle {
    val theme = LocalTheme.current
    return TextStyle(
        fontFamily = Fonts.family(theme.labelFace),
        fontWeight = weight,
        fontSize = size.sp,
        color = theme.prose.color,
    )
}

/**
 * The small-caps line the whole interface is labelled in: the dateline, the
 * counts, the section rules, every field name.
 */
@Composable
fun SmallCaps(
    text: String,
    modifier: Modifier = Modifier,
    tone: Tone? = null,
    size: Float? = null,
) {
    val theme = LocalTheme.current
    Text(
        text = theme.labelText(text),
        modifier = modifier,
        style = TextStyle(
            fontFamily = Fonts.family(theme.labelFace),
            fontWeight = theme.labelWeight,
            fontSize = (size ?: theme.labelSize).sp,
            letterSpacing = theme.labelTracking.sp,
            color = (tone ?: theme.muted).color,
        ),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/** A hairline, or whatever weight the theme rules at. */
@Composable
fun Rule(modifier: Modifier = Modifier, tone: Tone? = null, weight: Float = 1f) {
    val theme = LocalTheme.current
    Box(
        modifier
            .fillMaxWidth()
            .height(weight.dp)
            .background((tone ?: theme.rule).color)
    )
}

/** A text button in the accent, with no chrome of its own. */
@Composable
fun QuietButton(
    title: String,
    modifier: Modifier = Modifier,
    tone: Tone? = null,
    onClick: () -> Unit,
) {
    val theme = LocalTheme.current
    SmallCaps(
        text = title,
        modifier = modifier
            .clickable(onClick = onClick)
            .padding(horizontal = 6.dp, vertical = 6.dp),
        tone = tone ?: theme.accentInk,
    )
}

/** The block button: filled in themes that fill their buttons, outlined in the rest. */
@Composable
fun AccentBlock(
    title: String,
    modifier: Modifier = Modifier,
    filled: Boolean? = null,
    onClick: () -> Unit,
) {
    val theme = LocalTheme.current
    val solid = filled ?: theme.filledButtons
    val shape = RoundedCornerShape(theme.corner.dp)
    val fill = if (solid) theme.accent else Tone(theme.accent.hex, 0f)
    val label = if (solid) theme.accent.readable(theme.paper, theme.ink) else theme.accentInk
    Box(
        modifier
            .clip(shape)
            .background(fill.color)
            .then(
                if (solid) Modifier
                else Modifier.border(theme.border.dp, theme.rule.color, shape)
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 11.dp),
        contentAlignment = Alignment.Center,
    ) {
        SmallCaps(title, tone = label)
    }
}

/** A label on the left, a value on the right, over a hairline. */
@Composable
fun FieldRow(
    label: String,
    modifier: Modifier = Modifier,
    value: @Composable () -> Unit,
) {
    val theme = LocalTheme.current
    androidx.compose.foundation.layout.Column(modifier.fillMaxWidth()) {
        androidx.compose.foundation.layout.Row(
            modifier = Modifier.fillMaxWidth().padding(vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SmallCaps(label, modifier = Modifier.weight(1f))
            value()
        }
        Rule(tone = theme.ruleFaint)
    }
}

@Composable
fun FieldRow(label: String, value: String, tint: Tone? = null) {
    val theme = LocalTheme.current
    FieldRow(label) {
        Text(
            text = value,
            style = uiStyle(13f).copy(color = (tint ?: theme.ink).color),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    val theme = LocalTheme.current
    androidx.compose.foundation.layout.Column(modifier.fillMaxWidth()) {
        SmallCaps(text, tone = theme.ink, modifier = Modifier.padding(bottom = 7.dp))
        Rule(tone = theme.ink, weight = 1f)
    }
}

/** An editor's note, set as marginalia rather than as body text. */
@Composable
fun Marginalia(text: String, modifier: Modifier = Modifier) {
    val theme = LocalTheme.current
    Text(
        text = text,
        modifier = modifier,
        style = TextStyle(
            fontFamily = Fonts.family(theme.proseFace),
            fontWeight = theme.proseWeight,
            fontSize = 13.sp,
            lineHeight = 19.sp,
            color = theme.muted.color,
            textAlign = TextAlign.Start,
        ),
    )
}
