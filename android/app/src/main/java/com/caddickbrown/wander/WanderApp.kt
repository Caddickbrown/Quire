package com.caddickbrown.wander

import android.app.Application
import com.caddickbrown.wander.ui.Fonts
import com.caddickbrown.wander.ui.Themes

/**
 * The catalogues are read once, at launch: themes.json and the font manifest are
 * the same two files on every platform, and both are small enough to parse on
 * the main thread before the first frame.
 */
class WanderApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Fonts.load(this)
        Themes.load(this)
    }
}
