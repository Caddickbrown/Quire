package com.caddickbrown.wander.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.caddickbrown.wander.store.JournalState

/** How the page is set, and which folder it is set from. */
@Composable
fun OptionsSheet(
    state: JournalState,
    settings: AppearanceSettings,
    onChooseFolder: () -> Unit,
    onOpenThemes: () -> Unit,
) {
    val theme = LocalTheme.current
    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Column {
            SectionLabel("Setting")
            FieldRow("Theme") {
                QuietButton(Themes.named(settings.themeId)?.name ?: "Almanac", onClick = onOpenThemes)
            }
            FieldRow("Type") {
                Stepper(
                    value = "${settings.typeSize.toInt()} pt",
                    down = { settings.typeSize = (settings.typeSize - 0.5f).coerceAtLeast(12f) },
                    up = { settings.typeSize = (settings.typeSize + 0.5f).coerceAtMost(30f) },
                )
            }
            FieldRow("Leading") {
                Stepper(
                    value = String.format("%.2f", settings.leading),
                    down = { settings.leading = (settings.leading - 0.05f).coerceAtLeast(0f) },
                    up = { settings.leading = (settings.leading + 0.05f).coerceAtMost(1.2f) },
                )
            }
            FieldRow("Focus") {
                QuietButton(if (settings.focusMode) "On" else "Off") {
                    settings.focusMode = !settings.focusMode
                }
            }
            FieldRow("Typewriter") {
                QuietButton(if (settings.typewriter) "On" else "Off") {
                    settings.typewriter = !settings.typewriter
                }
            }
            FieldRow("Paper") {
                QuietButton(settings.appearanceLabel) { settings.cycleAppearance() }
            }
        }

        Column {
            SectionLabel("Journal")
            FieldRow("Entries", "${state.entries.size}")
            FieldRow("Folder") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = state.folderName.ifEmpty { "—" },
                        style = uiStyle(13f).copy(color = theme.ink.color),
                    )
                    QuietButton("Change", onClick = onChooseFolder)
                }
            }
        }

        Marginalia(
            "Entries are plain markdown in the jnl layout — one file per day under "
                + "journal/YYYY/MM/, drafts in inbox.md. The same folder opens in the macOS "
                + "app, the iOS app and the jnl CLI, byte for byte.",
            modifier = Modifier.padding(bottom = 16.dp),
        )
    }
}

@Composable
private fun Stepper(value: String, down: () -> Unit, up: () -> Unit) {
    val theme = LocalTheme.current
    Row(verticalAlignment = Alignment.CenterVertically) {
        QuietButton("−", onClick = down)
        Text(
            text = value,
            style = uiStyle(13f).copy(color = theme.ink.color),
            modifier = Modifier.padding(horizontal = 4.dp),
        )
        QuietButton("+", onClick = up)
    }
}
