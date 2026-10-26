package com.caddickbrown.wander.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DatePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.caddickbrown.wander.core.Entry
import com.caddickbrown.wander.store.JournalStore
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * Change an entry's date and time.
 *
 * For a filed entry the date *is* the filename, so this moves the entry between
 * day files; a draft stays in inbox.md, which isn't dated. The sheet says which
 * of the two is about to happen before it happens.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RescheduleSheet(entry: Entry, store: JournalStore, onDone: () -> Unit) {
    val theme = LocalTheme.current
    val at = entry.createdAt ?: LocalDateTime.now()

    val dateState = rememberDatePickerState(
        initialSelectedDateMillis = at.toLocalDate()
            .atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
    )
    val timeState = rememberTimePickerState(
        initialHour = at.hour, initialMinute = at.minute, is24Hour = true,
    )

    val chosen = remember(dateState.selectedDateMillis, timeState.hour, timeState.minute) {
        val millis = dateState.selectedDateMillis
        val date = if (millis == null) at.toLocalDate()
        else Instant.ofEpochMilli(millis).atZone(ZoneId.of("UTC")).toLocalDate()
        LocalDateTime.of(date, java.time.LocalTime.of(timeState.hour, timeState.minute, at.second))
    }

    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        SectionLabel("Date & time")
        DatePicker(state = dateState, title = null, headline = null, showModeToggle = false)
        TimePicker(state = timeState)

        FieldRow("Moves to", store.destinationName(entry, chosen))

        Row(
            Modifier.fillMaxWidth().padding(bottom = 20.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            AccentBlock("Cancel", filled = false, modifier = Modifier.weight(1f)) { onDone() }
            AccentBlock("Move", modifier = Modifier.weight(1f)) {
                store.reschedule(entry, chosen)
                onDone()
            }
        }
    }
}
