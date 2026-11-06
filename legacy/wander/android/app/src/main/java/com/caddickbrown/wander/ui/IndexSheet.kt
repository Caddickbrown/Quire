package com.caddickbrown.wander.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.caddickbrown.wander.core.Entry
import com.caddickbrown.wander.core.Formats
import com.caddickbrown.wander.core.Page
import com.caddickbrown.wander.store.JournalState
import com.caddickbrown.wander.store.JournalStore
import com.caddickbrown.wander.store.Section

/**
 * The index: what is in the folder, by month, under the three pages.
 *
 * On the Mac this is a column that is always there. On a phone there is only
 * room for one thing at a time, so the page is the root — you land in what you
 * were writing — and this arrives as a sheet, the way it does on iOS.
 */
@Composable
fun IndexSheet(store: JournalStore, state: JournalState, onPick: () -> Unit) {
    val theme = LocalTheme.current
    Column(Modifier.fillMaxWidth().background(theme.panel.color)) {
        PageSwitches(store, state)
        Find(store, state)
        if (state.sections.isEmpty()) {
            Empty(state)
        } else {
            LazyColumn(Modifier.fillMaxWidth()) {
                for (section in state.sections) {
                    item(key = "section:${section.title}") { SectionHeader(section, state) }
                    items(section.entries, key = { it.id }) { entry ->
                        IndexRow(
                            entry = entry,
                            selected = entry.id == state.selection,
                            onClick = { store.select(entry.id); onPick() },
                            onFile = { store.toggleFiling(entry) },
                        )
                    }
                }
            }
        }
    }
}

/**
 * The masthead, cut down to what a sheet needs: the wordmark and the three
 * pages, over the heavy rule. The page you are on sits first and in the accent;
 * the others follow in grey.
 */
@Composable
private fun PageSwitches(store: JournalStore, state: JournalState) {
    val theme = LocalTheme.current
    val ordered = listOf(state.page) + Page.entries.filter { it != state.page }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
        Row(
            Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(13.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Text(theme.displayText("wander"), style = displayStyle(24f))
            for (page in ordered) {
                val active = page == state.page
                SmallCaps(
                    text = label(page, state),
                    tone = if (active) theme.accentInk else theme.muted,
                    modifier = Modifier
                        .clickable { store.show(page) }
                        .padding(vertical = 4.dp),
                )
            }
        }
        Rule(tone = theme.ink, weight = 2f)
    }
}

/** Only the inbox carries a count, because only the inbox is a queue. */
private fun label(page: Page, state: JournalState): String {
    if (page != Page.INBOX) return page.label
    val count = state.count(Page.INBOX)
    return if (count > 0) "${page.label} $count" else page.label
}

@Composable
private fun Find(store: JournalStore, state: JournalState) {
    val theme = LocalTheme.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
        SmallCaps("Find", modifier = Modifier.padding(bottom = 6.dp))
        BasicTextField(
            value = state.query,
            onValueChange = store::search,
            textStyle = uiStyle(14f).copy(color = theme.ink.color),
            singleLine = true,
            cursorBrush = SolidColor(theme.accent.color),
            modifier = Modifier.fillMaxWidth(),
            decorationBox = { field ->
                Box(Modifier.fillMaxWidth()) {
                    if (state.query.isEmpty()) {
                        Text(
                            "title, text or @tag",
                            style = uiStyle(14f).copy(color = theme.muted.opacity(0.7f).color),
                        )
                    }
                    field()
                }
            },
        )
        Rule(tone = theme.rule, modifier = Modifier.padding(top = 7.dp))
    }
}

@Composable
private fun SectionHeader(section: Section, state: JournalState) {
    val theme = LocalTheme.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SmallCaps(
            section.title,
            tone = if (section.inbox) theme.accentInk else theme.muted,
            modifier = Modifier.weight(1f),
        )
        SmallCaps("${section.entries.size}", tone = theme.muted)
    }
    Rule(tone = theme.ruleFaint, modifier = Modifier.padding(horizontal = 16.dp))
}

@Composable
private fun IndexRow(
    entry: Entry,
    selected: Boolean,
    onClick: () -> Unit,
    onFile: () -> Unit,
) {
    val theme = LocalTheme.current
    val shape = RoundedCornerShape(theme.corner.dp)
    val fill = when {
        selected -> theme.surface
        theme.rowStyle == RowStyle.CARD || theme.rowStyle == RowStyle.BLOCK -> theme.surface
        else -> theme.panel
    }

    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = if (theme.rowStyle == RowStyle.CARD) 4.dp else 0.dp)
            .clip(shape)
            .background(fill.color)
            .then(
                if (selected && theme.border > 0f)
                    Modifier.border(theme.border.dp, theme.accent.opacity(0.5f).color, shape)
                else Modifier
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (entry.isStarred) {
                Text(
                    "✱",
                    style = uiStyle(11f).copy(color = theme.accentInk.color),
                    modifier = Modifier.padding(end = 6.dp),
                )
            }
            Text(
                text = entry.preview.ifEmpty { "Untitled" },
                style = displayStyle(16f, theme.rowTitleWeight).copy(
                    color = if (entry.preview.isEmpty()) theme.muted.color else theme.ink.color,
                ),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            if (entry.isUnfiled) {
                QuietButton("File", tone = theme.accentInk, onClick = onFile)
            }
        }
        SmallCaps(meta(entry), modifier = Modifier.padding(top = 3.dp))
    }
    if (theme.rowStyle == RowStyle.RULE) {
        Rule(tone = theme.ruleFaint, modifier = Modifier.padding(horizontal = 16.dp))
    }
}

private fun meta(entry: Entry): String {
    val at = entry.createdAt ?: return ""
    val parts = mutableListOf(Formats.shortDay(at), Formats.clock(at))
    val words = entry.wordCount
    if (words > 0) parts.add("$words ${if (words == 1) "word" else "words"}")
    return parts.joinToString(" · ")
}

@Composable
private fun Empty(state: JournalState) {
    val theme = LocalTheme.current
    Column(Modifier.fillMaxWidth().padding(20.dp)) {
        Marginalia(
            when {
                state.query.isNotEmpty() -> "Nothing matches that."
                state.page == Page.INBOX -> "The inbox is empty. Everything is filed."
                state.page == Page.STARRED -> "Nothing starred yet."
                else -> "Nothing filed yet. New writing starts in the inbox."
            }
        )
    }
}
