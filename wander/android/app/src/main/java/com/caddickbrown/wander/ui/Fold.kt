package com.caddickbrown.wander.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker

/**
 * What the device is doing with itself.
 *
 * A Surface Duo is two screens with a hinge between them, and a foldable is one
 * screen that sometimes behaves like two. Both arrive through the same Jetpack
 * API as a [FoldingFeature], and both want the same thing from Wander: the
 * layout the Mac has had all along, with the index in one pane and the page in
 * the other, rather than a phone layout stretched across a gap.
 */
data class Fold(
    /** True when the feature actually divides the window into two logical panes. */
    val separating: Boolean,
    /** VERTICAL means the hinge runs top to bottom, so the panes sit side by side. */
    val vertical: Boolean,
    /** Where the hinge sits in window pixels: the near edge, and its thickness. */
    val positionPx: Int,
    val thicknessPx: Int,
    /** Tabletop or book posture — half flat, half upright. */
    val halfOpen: Boolean,
) {
    companion object {
        val none = Fold(
            separating = false, vertical = true,
            positionPx = 0, thicknessPx = 0, halfOpen = false,
        )
    }
}

/**
 * The current fold, kept up to date while the app is in the foreground.
 *
 * Collection stops below STARTED: a device being unfolded in the recents list is
 * of no interest, and the tracker is a hot flow that would otherwise keep the
 * activity referenced.
 */
@Composable
fun rememberFold(): Fold {
    val context = LocalContext.current
    val activity = remember(context) { context.findActivity() } ?: return Fold.none
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    val fold by produceState(initialValue = Fold.none, activity, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            WindowInfoTracker.getOrCreate(activity)
                .windowLayoutInfo(activity)
                .collect { info ->
                    val feature = info.displayFeatures
                        .filterIsInstance<FoldingFeature>()
                        .firstOrNull()
                    value = if (feature == null) Fold.none else Fold(
                        separating = feature.isSeparating,
                        vertical = feature.orientation == FoldingFeature.Orientation.VERTICAL,
                        positionPx = if (feature.orientation == FoldingFeature.Orientation.VERTICAL)
                            feature.bounds.left else feature.bounds.top,
                        thicknessPx = if (feature.orientation == FoldingFeature.Orientation.VERTICAL)
                            feature.bounds.width() else feature.bounds.height(),
                        halfOpen = feature.state == FoldingFeature.State.HALF_OPENED,
                    )
                }
        }
    }
    return fold
}

private fun Context.findActivity(): Activity? {
    var context = this
    while (context is ContextWrapper) {
        if (context is Activity) return context
        context = context.baseContext
    }
    return null
}
