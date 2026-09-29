package com.caddickbrown.wander

import android.app.Application
import com.caddickbrown.wander.ui.Fonts
import com.caddickbrown.wander.ui.Themes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * The catalogues are read once, at launch: themes.json and the font manifest are
 * the same two files on every platform, and both are small enough to parse on
 * the main thread before the first frame.
 */
class WanderApp : Application() {

    /**
     * Where writes run: as long-lived as the process, not the screen. A save
     * started as the activity finishes must not be cancelled with its
     * ViewModel — the text it carries exists nowhere else.
     */
    val writes = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onCreate() {
        super.onCreate()
        Fonts.load(this)
        Themes.load(this)
    }
}
