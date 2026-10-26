package com.caddickbrown.wander.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/**
 * On a phone the themes are swiped through full size, not picked off a grid of
 * thumbnails: a theme is mostly type and paper, and neither reads at thumbnail
 * size. Each page is the theme drawing itself.
 */
@Composable
fun ThemeSwiper(
    settings: AppearanceSettings,
    systemDark: Boolean,
    onDone: () -> Unit,
) {
    val catalogue = Themes.all
    if (catalogue.isEmpty()) return
    val start = catalogue.indexOfFirst { it.id == settings.themeId }.coerceAtLeast(0)
    val pager = rememberPagerState(initialPage = start) { catalogue.size }

    // Swiping is choosing — the theme applies as it comes past, so what you are
    // looking at is always what the app now is.
    LaunchedEffect(pager) {
        snapshotFlow { pager.currentPage }.collect { page ->
            catalogue.getOrNull(page)?.let { settings.themeId = it.id; settings.persist() }
        }
    }

    HorizontalPager(state = pager, modifier = Modifier.fillMaxSize()) { page ->
        val entry = catalogue[page]
        val theme = entry.resolve(settings.dark(systemDark))
        WanderTheme(theme) {
            Preview(theme = theme, note = entry.note, position = "${page + 1} / ${catalogue.size}", onDone = onDone)
        }
    }
}

@Composable
private fun Preview(theme: Theme, note: String, position: String, onDone: () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .background(theme.paper.color)
            .padding(horizontal = 24.dp, vertical = 28.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(theme.displayText("wander"), style = displayStyle(22f), modifier = Modifier.weight(1f))
            SmallCaps(position)
        }
        Rule(tone = theme.ink, weight = theme.mastheadRule.coerceAtLeast(1f), modifier = Modifier.padding(top = 10.dp))

        Column(Modifier.weight(1f).padding(top = 26.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (theme.kicker) SmallCaps("Tuesday · @reservoir", tone = theme.accentInk)
            Text(theme.displayText(theme.name), style = displayStyle(theme.titleSize))
            SmallCaps("Tuesday, 8 September 2026 · 08:12")
            Rule(tone = theme.rule)
            Text(
                text = "Left before seven and took the long way round the reservoir, which "
                    + "adds twenty minutes and, this morning, was worth every one of them.",
                style = proseStyle(theme.proseSize),
            )
            Text(
                text = "The dull entries are the ones worth having in five years.",
                style = proseStyle(theme.proseSize).copy(color = theme.muted.color),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("@admin", style = proseStyle(theme.proseSize).copy(color = theme.accentInk.color))
                Text("@later", style = proseStyle(theme.proseSize).copy(color = theme.accentInk.color))
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(
                text = note,
                style = uiStyle(12f).copy(color = theme.muted.color),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SmallCaps(theme.recommended.label, modifier = Modifier.weight(1f))
                Box { AccentBlock("Use this one", onClick = onDone) }
            }
        }
    }
}
