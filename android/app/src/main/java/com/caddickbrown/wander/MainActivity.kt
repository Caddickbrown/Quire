package com.caddickbrown.wander

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.remember
import com.caddickbrown.wander.data.Settings
import com.caddickbrown.wander.store.JournalStore
import com.caddickbrown.wander.ui.AppearanceSettings
import com.caddickbrown.wander.ui.RootScreen

class MainActivity : ComponentActivity() {

    private val store: JournalStore by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The paper runs under the status and navigation bars; the page holds
        // its own insets, so the theme's colour is the whole screen.
        enableEdgeToEdge()
        setContent {
            val settings = remember { AppearanceSettings(Settings(this)) }
            RootScreen(
                store = store,
                settings = settings,
                systemDark = isSystemInDarkTheme(),
            )
        }
    }

    /**
     * Whatever is being typed is put away before the process can be taken — a
     * journal that loses the last sentence is not a journal.
     */
    override fun onStop() {
        store.flushNow()
        super.onStop()
    }
}
