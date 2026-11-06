package com.caddickbrown.wander.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.caddickbrown.wander.core.Formats
import com.caddickbrown.wander.core.JournalPaths
import com.caddickbrown.wander.store.Draft
import com.caddickbrown.wander.store.JournalState
import com.caddickbrown.wander.store.JournalStore
import java.time.LocalDate

/**
 * What the entry is and where it sits, then what the journal adds up to. The
 * same figures the stats column shows on the Mac, in the order it shows them.
 */
@Composable
fun StatsSheet(store: JournalStore, state: JournalState, draft: Draft) {
    val theme = LocalTheme.current
    val entry = state.selectedEntry

    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        if (theme.statsStyle == StatsStyle.FIGURES) {
            Figures(state, draft)
        }

        Column {
            SectionLabel("Filed")
            FieldRow("Number", state.selectedNumber?.let { "No. ${Formats.groupNumber(it)}" } ?: "—")
            FieldRow("Written") {
                val at = entry?.createdAt
                if (at == null) {
                    Text("—", style = uiStyle(13f).copy(color = theme.muted.color))
                } else {
                    QuietButton("${Formats.shortDay(at)} · ${Formats.clock(at)}") {
                        store.reschedulingEntry = entry
                    }
                }
            }
            FieldRow(
                label = "Tags",
                value = entry?.tags?.take(3)?.joinToString(" ")?.ifEmpty { "—" } ?: "—",
                tint = if (entry?.tags?.isNotEmpty() == true) theme.accentInk else theme.muted,
            )
            FieldRow("Status") {
                if (entry == null) {
                    Text("—", style = uiStyle(13f).copy(color = theme.muted.color))
                } else {
                    QuietButton(if (state.selectedIsUnfiled) "In the inbox" else "Filed") {
                        store.toggleFiling(entry)
                    }
                }
            }
            FieldRow("File", entry?.source?.let(JournalPaths::name) ?: "unsaved")
        }

        Column {
            SectionLabel("Journal")
            FieldRow("Entries", "${state.entries.size}")
            FieldRow("Words", Formats.thousands(state.totalWords))
            FieldRow("This month", "${state.entriesThisMonth}")
            FieldRow(
                label = "Streak",
                value = "${state.streak} ${if (state.streak == 1) "day" else "days"}",
                tint = if (state.streak > 0) theme.green else theme.muted,
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (entry != null && state.selectedIsUnfiled) {
                AccentBlock("File", modifier = Modifier.fillMaxWidth()) { store.toggleFiling(entry) }
            }
            if (entry != null) {
                AccentBlock(
                    title = "Copy markdown",
                    filled = !state.selectedIsUnfiled,
                    modifier = Modifier.fillMaxWidth(),
                ) { store.copyMarkdown(entry) }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Rule(tone = theme.rule)
            Marginalia(Prompts.today())
            Column(Modifier.padding(bottom = 16.dp)) {}
        }
    }
}

/** The big display numerals the board themes use instead of ruled rows. */
@Composable
private fun Figures(state: JournalState, draft: Draft) {
    val theme = LocalTheme.current
    val fills = theme.figureFills
    val figures = listOf(
        "Entries" to "${state.entries.size}",
        "Words" to Formats.thousands(state.totalWords),
        "Streak" to "${state.streak}",
    )
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        figures.forEachIndexed { index, (label, value) ->
            val fill = fills[index % fills.size]
            // Read the fill rather than assuming: several themes set accent or
            // green to near-black, which used to print black on black.
            val onFill = fill.readable(theme.paper, theme.ink)
            val shape = RoundedCornerShape(theme.corner.dp)
            Column(
                Modifier
                    .weight(1f)
                    .clip(shape)
                    .background(fill.color)
                    .then(
                        if (fill.hex == theme.surface.hex)
                            Modifier.border(theme.border.dp, theme.rule.color, shape)
                        else Modifier
                    )
                    .padding(horizontal = 12.dp, vertical = 12.dp),
            ) {
                SmallCaps(label, tone = onFill.opacity(0.75f))
                Text(
                    text = value,
                    style = displayStyle(30f * minOf(1.2f, theme.displayScale))
                        .copy(color = onFill.color),
                )
            }
        }
    }
}

/**
 * A different line each day, in the voice of an editor's note rather than a
 * prompt card. Deterministic on the date so it doesn't shuffle mid-session.
 */
object Prompts {
    val all = listOf(
        "Write the sentence you would rather not. It is usually the one carrying the entry.",
        "Detail before conclusion: what was on the table, what the light was doing, who spoke first.",
        "A journal is not a defence. Nobody is going to cross-examine the draft.",
        "If the day resists summary, put down three things in the order they happened and stop.",
        "The dull entries are the ones worth having in five years. Keep them.",
        "Name the thing you are avoiding, then leave it. Naming is enough for today.",
        "Write it as you would tell it to one person, and not as you would post it.",
        "What changed today that you would not have predicted on Monday?",
        "End mid-thought if you must. Tomorrow's entry can pick up the sentence.",
        "Tag it @later and let the future reader do the sorting.",
        "One page is a good day's work. Half a page still counts.",
        "Describe the room. The feeling tends to follow the furniture.",
    )

    fun today(): String = all[LocalDate.now().dayOfYear % all.size]
}
