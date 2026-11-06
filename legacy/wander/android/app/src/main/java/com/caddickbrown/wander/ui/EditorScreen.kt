package com.caddickbrown.wander.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.unit.dp
import com.caddickbrown.wander.core.Counts
import com.caddickbrown.wander.core.Entry
import com.caddickbrown.wander.core.Formats
import com.caddickbrown.wander.editor.ProseEditText
import com.caddickbrown.wander.editor.ProseEditor
import com.caddickbrown.wander.editor.ProseStyle
import com.caddickbrown.wander.store.Draft
import com.caddickbrown.wander.store.JournalState
import com.caddickbrown.wander.store.JournalStore
import com.caddickbrown.wander.store.SaveState

/**
 * One entry, set as a page: a serif title, a small-caps dateline, the rule, then
 * the prose. On a phone the measure is the screen, so the margins are what the
 * theme can afford rather than what a wide window would give away.
 */
@Composable
fun EditorScreen(
    store: JournalStore,
    state: JournalState,
    draft: Draft,
    typeSize: Float,
    leading: Float,
    focusMode: Boolean,
    typewriter: Boolean,
    onEditorReady: (ProseEditText) -> Unit,
    modifier: Modifier = Modifier,
) {
    val theme = LocalTheme.current
    val entry = state.selectedEntry

    Box(modifier.fillMaxSize().background(theme.paper.color)) {
        if (entry == null) {
            Blank(store, modifier = Modifier.align(Alignment.TopStart))
        } else {
            Column(Modifier.fillMaxSize().padding(horizontal = 20.dp)) {
                Header(store, state, draft, entry)
                Rule(tone = theme.ink)
                ProseEditor(
                    text = draft.body,
                    style = ProseStyle(
                        theme = theme,
                        size = typeSize,
                        leading = leading,
                        typewriter = typewriter,
                        dimInactive = focusMode,
                    ),
                    onTextChange = { body ->
                        if (body != draft.body) {
                            draft.body = body
                            store.edited()
                        }
                    },
                    onViewReady = onEditorReady,
                    modifier = Modifier.fillMaxWidth().weight(1f).padding(top = 12.dp),
                )
                Rule(tone = theme.rule)
                Status(state, draft)
            }
        }
    }
}

@Composable
private fun Header(store: JournalStore, state: JournalState, draft: Draft, entry: Entry) {
    val theme = LocalTheme.current
    Column(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 11.dp)) {
        if (theme.kicker) {
            val kicker = kickerText(entry)
            if (kicker.isNotEmpty()) {
                SmallCaps(kicker, tone = theme.accentInk, modifier = Modifier.padding(bottom = 7.dp))
            }
        }

        val titleStyle = displayStyle(theme.titleSize)
        BasicTextField(
            value = draft.title,
            onValueChange = { draft.title = it; store.edited() },
            textStyle = titleStyle,
            singleLine = false,
            cursorBrush = SolidColor(theme.accent.color),
            modifier = Modifier.fillMaxWidth(),
            decorationBox = { field ->
                Box {
                    if (draft.title.isEmpty()) {
                        Text(
                            text = if (theme.displayUppercase) "UNTITLED" else "Untitled",
                            style = titleStyle.copy(color = theme.muted.opacity(0.5f).color),
                        )
                    }
                    field()
                }
            },
        )

        Spacer(Modifier.padding(top = 9.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            SmallCaps(
                text = dateline(entry),
                modifier = Modifier
                    .weight(1f)
                    .clickable { store.reschedulingEntry = entry },
            )
            if (state.selectedIsUnfiled) {
                QuietButton("File", tone = theme.accentInk) { store.toggleFiling(entry) }
            }
            QuietButton(
                title = if (entry.isStarred) "✱ Starred" else "Star",
                tone = theme.accentInk,
            ) { store.toggleStar(entry) }
        }
    }
}

@Composable
private fun Status(state: JournalState, draft: Draft) {
    val theme = LocalTheme.current
    // Read from the draft, not the store: the counts move with every keystroke
    // and nothing else on the page should.
    val body = draft.body
    val counts = remember(body) {
        val words = Counts.words(body)
        val characters = Counts.characters(body)
        val minutes = Counts.readingMinutes(body)
        buildList {
            add("$words ${if (words == 1) "word" else "words"}")
            add("$characters characters")
            if (minutes > 0) add("$minutes min read")
        }.joinToString(" · ")
    }
    Row(
        Modifier.fillMaxWidth().padding(top = 9.dp, bottom = 10.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SmallCaps(counts, modifier = Modifier.weight(1f))
        val save = state.saveState
        SmallCaps(
            text = when (save) {
                // Every entry has a file from the moment it's made, so "has a
                // source" says nothing; a blank entry is the one never written.
                is SaveState.Idle ->
                    if (state.selectedEntry?.isBlank != false) "Unsaved draft" else "Saved"
                is SaveState.Editing -> "Writing…"
                is SaveState.Saved -> "Saved ${Formats.clock(save.at)}"
                is SaveState.Failed -> "Not saved — ${save.message}"
            },
            tone = if (save is SaveState.Failed) theme.accent else theme.muted,
        )
    }
}

@Composable
private fun Blank(store: JournalStore, modifier: Modifier = Modifier) {
    val theme = LocalTheme.current
    Column(
        modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 36.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Nothing open", style = displayStyle(34f))
        Marginalia(
            "Tap the pencil to start an entry. It begins in inbox.md, and filing it "
                + "moves it into journal/YYYY/MM/DD.md — plain markdown either way, the "
                + "same files jnl and Nook read.",
            modifier = Modifier.widthIn(max = 380.dp),
        )
        AccentBlock("New entry", modifier = Modifier.widthIn(max = 200.dp)) { store.newEntry() }
    }
}

/** The magazine kicker: the day, and the first tag if the entry carries one. */
private fun kickerText(entry: Entry): String {
    val at = entry.createdAt ?: return ""
    val day = Formats.longDay(at).substringBefore(",")
    val tag = entry.tags.firstOrNull()
    return if (tag != null) "$day · $tag" else day
}

private fun dateline(entry: Entry): String {
    val at = entry.createdAt ?: return ""
    val parts = mutableListOf(Formats.longDay(at), Formats.clock(at))
    val tags = entry.tags
    if (tags.isNotEmpty()) parts.add(tags.take(4).joinToString(" "))
    return parts.joinToString(" · ")
}
