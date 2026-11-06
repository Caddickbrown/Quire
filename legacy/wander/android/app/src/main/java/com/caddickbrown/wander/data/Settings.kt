package com.caddickbrown.wander.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.edit

/**
 * The folder the user chose, and the handful of preferences that decide how the
 * page is set. The Apple builds keep a security-scoped bookmark in UserDefaults
 * so the grant survives the folder being moved; the Android equivalent is a
 * persisted URI permission on the tree, taken when the folder is picked and
 * released when another is chosen in its place.
 */
class Settings(context: Context) {

    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("wander", Context.MODE_PRIVATE)

    var folderUri: Uri?
        get() = prefs.getString(FOLDER, null)?.let(Uri::parse)
        private set(value) = prefs.edit { putString(FOLDER, value?.toString()) }

    var page: String
        get() = prefs.getString(PAGE, "journal") ?: "journal"
        set(value) = prefs.edit { putString(PAGE, value) }

    var themeId: String
        get() = prefs.getString(THEME, "almanac") ?: "almanac"
        set(value) = prefs.edit { putString(THEME, value) }

    /** "system", "light" or "dark". */
    var appearance: String
        get() = prefs.getString(APPEARANCE, "system") ?: "system"
        set(value) = prefs.edit { putString(APPEARANCE, value) }

    var typeSize: Float
        get() = prefs.getFloat(TYPE_SIZE, 17.5f)
        set(value) = prefs.edit { putFloat(TYPE_SIZE, value) }

    var leading: Float
        get() = prefs.getFloat(LEADING, 0.3f)
        set(value) = prefs.edit { putFloat(LEADING, value) }

    var focusMode: Boolean
        get() = prefs.getBoolean(FOCUS, false)
        set(value) = prefs.edit { putBoolean(FOCUS, value) }

    var typewriter: Boolean
        get() = prefs.getBoolean(TYPEWRITER, false)
        set(value) = prefs.edit { putBoolean(TYPEWRITER, value) }

    /**
     * Remember a folder the picker just handed over, and hold the grant open
     * across launches. Without the persisted permission the URI stops working
     * the moment the process dies, which is the Android bug everyone hits once.
     */
    fun adopt(uri: Uri) {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        folderUri?.takeIf { it != uri }?.let { old ->
            runCatching { app.contentResolver.releasePersistableUriPermission(old, flags) }
        }
        runCatching { app.contentResolver.takePersistableUriPermission(uri, flags) }
        folderUri = uri
    }

    /** The remembered folder, if the grant is still held. */
    fun rememberedFolder(): Uri? {
        val uri = folderUri ?: return null
        val held = app.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        return if (held) uri else null
    }

    private companion object {
        const val FOLDER = "journalFolderUri"
        const val PAGE = "page"
        const val THEME = "theme"
        const val APPEARANCE = "appearance"
        const val TYPE_SIZE = "typeSize"
        const val LEADING = "lineSpacing"
        const val FOCUS = "focusMode"
        const val TYPEWRITER = "typewriter"
    }
}
