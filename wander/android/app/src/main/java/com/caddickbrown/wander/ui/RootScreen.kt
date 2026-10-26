package com.caddickbrown.wander.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.caddickbrown.wander.core.Page
import com.caddickbrown.wander.editor.ProseEditText
import com.caddickbrown.wander.store.JournalStore

/**
 * The shell.
 *
 * On a phone there is room for one thing at a time, so the page is the root —
 * you land in what you were writing — and the index, the stats and the options
 * arrive as sheets. That is the shape the iOS build settled on, and there is no
 * reason for Android to disagree with it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RootScreen(
    store: JournalStore,
    settings: AppearanceSettings,
    systemDark: Boolean,
) {
    val state by store.state.collectAsStateWithLifecycle()
    val theme = Themes.resolve(settings.themeId, settings.dark(systemDark))

    var showingIndex by remember { mutableStateOf(false) }
    var showingStats by remember { mutableStateOf(false) }
    var showingOptions by remember { mutableStateOf(false) }
    var showingThemes by remember { mutableStateOf(false) }
    var editor by remember { mutableStateOf<ProseEditText?>(null) }
    val fold = rememberFold()

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocumentTree()
    ) { uri -> if (uri != null) store.open(uri) }

    // Anything the user changes about the look is written straight through.
    LaunchedEffect(settings) {
        snapshotFlow {
            listOf(
                settings.themeId, settings.appearance, settings.typeSize,
                settings.leading, settings.focusMode, settings.typewriter,
            )
        }.collect { settings.persist() }
    }

    // A journal folder is shared — with jnl, with a sync client, with the desktop
    // app — so what is on screen is re-checked against the disk on every resume,
    // and whatever is being typed is put away when the app goes to the back.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> store.reloadIfChanged()
                Lifecycle.Event.ON_PAUSE -> store.flushNow()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    WanderTheme(theme) {
        Box(Modifier.fillMaxSize().background(theme.paper.color)) {
            if (!state.folderChosen) {
                FolderScreen(
                    error = state.error,
                    onChoose = { picker.launch(null) },
                    modifier = Modifier.statusBarsPadding().navigationBarsPadding(),
                )
            } else {
                Shell(
                    store = store,
                    state = state,
                    settings = settings,
                    fold = fold,
                    onIndex = { showingIndex = true },
                    onStats = { showingStats = true },
                    onOptions = { showingOptions = true },
                    onThemes = { showingThemes = true },
                    onEditorReady = { editor = it },
                    onBold = { editor?.wrapSelection("**") },
                    onItalic = { editor?.wrapSelection("_") },
                )
            }
        }

        if (showingIndex) {
            ModalBottomSheet(
                onDismissRequest = { showingIndex = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = theme.panel.color,
            ) {
                Box(Modifier.fillMaxHeight(0.92f)) {
                    IndexSheet(store, state) { showingIndex = false }
                }
            }
        }

        if (showingStats) {
            ModalBottomSheet(
                onDismissRequest = { showingStats = false },
                containerColor = theme.panel.color,
            ) { StatsSheet(store, state, store.draft) }
        }

        if (showingOptions) {
            ModalBottomSheet(
                onDismissRequest = { showingOptions = false },
                containerColor = theme.panel.color,
            ) {
                OptionsSheet(
                    state = state,
                    settings = settings,
                    onChooseFolder = { showingOptions = false; picker.launch(null) },
                    onOpenThemes = { showingOptions = false; showingThemes = true },
                )
            }
        }

        store.reschedulingEntry?.let { entry ->
            ModalBottomSheet(
                onDismissRequest = { store.reschedulingEntry = null },
                containerColor = theme.panel.color,
            ) {
                RescheduleSheet(entry, store) { store.reschedulingEntry = null }
            }
        }

        if (showingThemes) {
            Dialog(
                onDismissRequest = { showingThemes = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                ThemeSwiper(settings, systemDark) { showingThemes = false }
            }
        }

        store.deletionCandidate?.let { entry ->
            AlertDialog(
                onDismissRequest = { store.deletionCandidate = null },
                containerColor = theme.panel.color,
                title = { Text("Delete this entry?", style = displayStyle(20f)) },
                text = {
                    Marginalia(
                        "It is taken out of ${entry.source ?: "the journal"}. "
                            + "There is no undo — the file is rewritten without it."
                    )
                },
                confirmButton = {
                    TextButton(onClick = {
                        store.delete(entry)
                        store.deletionCandidate = null
                    }) { SmallCaps("Delete", tone = theme.accentInk) }
                },
                dismissButton = {
                    TextButton(onClick = { store.deletionCandidate = null }) {
                        SmallCaps("Keep")
                    }
                },
            )
        }
    }
}

/**
 * The masthead. It stays put in focus mode too, because you should always be
 * able to see what you are writing into.
 */
@Composable
private fun Masthead(
    store: JournalStore,
    state: com.caddickbrown.wander.store.JournalState,
    showIndexButton: Boolean,
    onIndex: () -> Unit,
    onStats: () -> Unit,
    onOptions: () -> Unit,
    onThemes: () -> Unit,
    onBold: () -> Unit,
    onItalic: () -> Unit,
) {
    val theme = LocalTheme.current
    var menu by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxWidth().background(theme.paper.color)) {
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 10.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (showIndexButton) {
                SmallCaps(
                    "Index",
                    modifier = Modifier.clickable(onClick = onIndex).padding(vertical = 6.dp),
                )
            }
            Text(theme.displayText("wander"), style = displayStyle(19f))
            SmallCaps(state.page.label, tone = theme.accentInk, modifier = Modifier.weight(1f))

            SmallCaps("B", tone = theme.ink, modifier = Modifier.clickable(onClick = onBold).padding(6.dp))
            SmallCaps("I", tone = theme.ink, modifier = Modifier.clickable(onClick = onItalic).padding(6.dp))
            SmallCaps("New", tone = theme.accentInk, modifier = Modifier
                .clickable { store.newEntry() }
                .padding(6.dp))

            Box {
                SmallCaps("⋯", tone = theme.ink, size = 16f, modifier = Modifier
                    .clickable { menu = true }
                    .padding(6.dp))
                DropdownMenu(
                    expanded = menu,
                    onDismissRequest = { menu = false },
                    containerColor = theme.panel.color,
                ) {
                    val entry = state.selectedEntry
                    if (entry != null) {
                        Item(if (entry.isStarred) "Unstar" else "Star") {
                            menu = false; store.toggleStar(entry)
                        }
                        Item(if (state.selectedIsUnfiled) "File" else "Return to inbox") {
                            menu = false; store.toggleFiling(entry)
                        }
                        Item("Date & time…") { menu = false; store.reschedulingEntry = entry }
                        Item("Copy markdown") { menu = false; store.copyMarkdown(entry) }
                        Item("Delete…") { menu = false; store.deletionCandidate = entry }
                    }
                    Item("Stats") { menu = false; onStats() }
                    Item("Options") { menu = false; onOptions() }
                    Item("Themes…") { menu = false; onThemes() }
                }
            }
        }
        when (theme.mastheadStyle) {
            MastheadStyle.NONE -> Unit
            MastheadStyle.DOUBLE -> {
                Rule(tone = theme.ink, weight = theme.mastheadRule.coerceAtLeast(1f))
                Spacer(Modifier.padding(top = 2.dp))
                Rule(tone = theme.rule)
            }
            else -> Rule(tone = theme.ink, weight = theme.mastheadRule.coerceAtLeast(1f))
        }
    }
}

@Composable
private fun Item(title: String, onClick: () -> Unit) {
    DropdownMenuItem(text = { SmallCaps(title, tone = LocalTheme.current.ink) }, onClick = onClick)
}

/**
 * First run, and whenever the grant is gone.
 *
 * Android is the one platform where the folder cannot simply be assumed: there
 * is no ~/Documents to fall back on, and no path the app may read without being
 * handed it. So the first thing Wander does is ask — and, unlike an app-private
 * directory, what comes back is a folder the user can also point Syncthing at.
 */
@Composable
private fun FolderScreen(error: String?, onChoose: () -> Unit, modifier: Modifier = Modifier) {
    val theme = LocalTheme.current
    Column(
        modifier
            .fillMaxSize()
            .padding(horizontal = 28.dp, vertical = 40.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Text(theme.displayText("wander"), style = displayStyle(34f))
        SmallCaps("A journal in plain markdown")
        Rule(tone = theme.ink, weight = 2f)
        Marginalia(
            "Choose the folder your journal lives in. An existing jnl or Nook folder "
                + "opens as-is; an empty one is set up with inbox.md and journal/ on the "
                + "first entry.\n\nPick a folder a sync client already watches and the same "
                + "files open on the Mac, on iOS and in the jnl CLI.",
            modifier = Modifier.widthIn(max = 420.dp),
        )
        if (error != null) SmallCaps(error, tone = theme.accent)
        AccentBlock("Choose folder", modifier = Modifier.widthIn(max = 240.dp), onClick = onChoose)
    }
}

/**
 * One pane or two.
 *
 * A phone gets the page, with the index as a sheet. A Surface Duo, an open
 * foldable or a tablet gets what the Mac gets: the index beside the page, both
 * live at once, which is the layout this app was designed in and the one it is
 * happiest in.
 *
 * The split is taken from the hinge where there is one, so the index ends on the
 * left screen and the page begins on the right, with the gap left empty rather
 * than having a line of prose fall into it. Where there is no hinge — a tablet,
 * or an unfolded inner screen with no separating feature — the index takes a
 * column of its own and the page takes the rest.
 */
@Composable
private fun Shell(
    store: JournalStore,
    state: com.caddickbrown.wander.store.JournalState,
    settings: AppearanceSettings,
    fold: Fold,
    onIndex: () -> Unit,
    onStats: () -> Unit,
    onOptions: () -> Unit,
    onThemes: () -> Unit,
    onEditorReady: (ProseEditText) -> Unit,
    onBold: () -> Unit,
    onItalic: () -> Unit,
) {
    val theme = LocalTheme.current
    val density = LocalDensity.current

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val wideEnough = maxWidth >= 720.dp
        val sideBySide = (fold.separating && fold.vertical) || wideEnough
        // A tabletop or book posture with a horizontal hinge: the page sits in
        // the raised half, the index in the flat half, which is where a hand
        // resting on the device expects to find a list.
        val stacked = fold.separating && !fold.vertical && maxHeight >= 600.dp

        val page = @Composable { modifier: Modifier ->
            Column(modifier) {
                Masthead(
                    store = store,
                    state = state,
                    showIndexButton = !sideBySide && !stacked,
                    onIndex = onIndex,
                    onStats = onStats,
                    onOptions = onOptions,
                    onThemes = onThemes,
                    onBold = onBold,
                    onItalic = onItalic,
                )
                EditorScreen(
                    store = store,
                    state = state,
                    draft = store.draft,
                    typeSize = settings.typeSize,
                    leading = settings.leading,
                    focusMode = settings.focusMode,
                    typewriter = settings.typewriter,
                    onEditorReady = onEditorReady,
                    modifier = Modifier.fillMaxWidth().weight(1f),
                )
            }
        }

        // The index in a pane stays put when a row is picked; only a sheet
        // closes behind a selection.
        val index = @Composable { modifier: Modifier ->
            Box(modifier.background(theme.panel.color)) {
                IndexSheet(store, state) {}
            }
        }

        val outer = Modifier.fillMaxSize().statusBarsPadding().imePadding()

        when {
            sideBySide -> {
                // The hinge is reported in window pixels; where there isn't one,
                // the index simply takes a column.
                val hinge = with(density) { fold.positionPx.toDp() }
                val gap = with(density) { fold.thicknessPx.toDp() }
                val indexWidth = if (fold.separating && fold.vertical && hinge > 200.dp) hinge
                else 340.dp
                Row(outer) {
                    index(Modifier.width(indexWidth).fillMaxHeight())
                    if (gap > 0.dp) {
                        // Nothing is drawn across the hinge — a seam through a
                        // sentence is worse than a margin.
                        Box(Modifier.width(gap).fillMaxHeight().background(theme.ink.color))
                    } else {
                        Box(Modifier.width(1.dp).fillMaxHeight().background(theme.rule.color))
                    }
                    page(Modifier.weight(1f).fillMaxHeight())
                }
            }

            stacked -> {
                val top = with(density) { fold.positionPx.toDp() }
                val gap = with(density) { fold.thicknessPx.toDp() }
                Column(outer) {
                    page(Modifier.fillMaxWidth().height(top.coerceAtLeast(240.dp)))
                    Box(Modifier.fillMaxWidth().height(gap.coerceAtLeast(1.dp)).background(theme.ink.color))
                    index(Modifier.fillMaxWidth().weight(1f))
                }
            }

            // The phone: the page is the root, and the index is a sheet.
            else -> page(outer)
        }
    }
}
