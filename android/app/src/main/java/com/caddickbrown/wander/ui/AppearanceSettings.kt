package com.caddickbrown.wander.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.caddickbrown.wander.data.Settings

/**
 * The look, held as Compose state and written through to [Settings] as it
 * changes — the equivalent of the Apple builds' `@AppStorage`, which does the
 * same two jobs in one property wrapper.
 */
class AppearanceSettings(private val settings: Settings) {

    var themeId by mutableStateOf(settings.themeId)
    var appearance by mutableStateOf(settings.appearance)
    var typeSize by mutableFloatStateOf(settings.typeSize)
    var leading by mutableFloatStateOf(settings.leading)
    var focusMode by mutableStateOf(settings.focusMode)
    var typewriter by mutableStateOf(settings.typewriter)

    /** Called on every change; cheap, and keeps the file the single record. */
    fun persist() {
        settings.themeId = themeId
        settings.appearance = appearance
        settings.typeSize = typeSize
        settings.leading = leading
        settings.focusMode = focusMode
        settings.typewriter = typewriter
    }

    val appearanceLabel: String
        get() = when (appearance) {
            "light" -> "Light"
            "dark" -> "Dark"
            else -> "System"
        }

    fun cycleAppearance() {
        appearance = when (appearance) {
            "system" -> "light"
            "light" -> "dark"
            else -> "system"
        }
    }

    /** Whether the dark half of the theme is the one to draw. */
    fun dark(systemDark: Boolean): Boolean = when (appearance) {
        "light" -> false
        "dark" -> true
        else -> systemDark
    }
}
