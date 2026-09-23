package com.caddickbrown.wander.store

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.caddickbrown.wander.core.Counts
import com.caddickbrown.wander.core.Entry
import com.caddickbrown.wander.core.Formats
import com.caddickbrown.wander.core.JournalIndex
import com.caddickbrown.wander.core.JournalPaths
import com.caddickbrown.wander.core.JournalParser
import com.caddickbrown.wander.core.Page
import com.caddickbrown.wander.data.JournalLibrary
import com.caddickbrown.wander.data.SafTree
import com.caddickbrown.wander.data.Settings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDateTime

/**
 * The text being typed, held apart from the rest of the state on purpose.
 *
 * Everything the index, the masthead and the stats sheet read is derived from
 * the whole journal, so publishing a keystroke into the store would rebuild all
 * of it — thousands of entries regrouped and recounted per character. Only the
 * editor and the live counts read a [Draft], so typing costs what typing should;
 * the store hears about it once, on the debounced save.
 */
class Draft {
    var title by mutableStateOf("")
    var body by mutableStateOf("")
}

sealed interface SaveState {
    data object Idle : SaveState
    data object Editing : SaveState
    data class Saved(val at: LocalDateTime) : SaveState
    data class Failed(val message: String) : SaveState
}

/** One section of the index: a month of the journal, or the whole inbox. */
data class Section(val title: String, val entries: List<Entry>, val inbox: Boolean)

/**
 * Everything derived from the journal as a whole. Held rather than computed:
 * each field walks every entry, and a Compose frame reads several of them
 * several times over.
 */
data class JournalState(
    /** Whether a folder has been chosen and opened. Part of the state, not a
     *  property of the store: the first-run screen gives way to the journal the
     *  moment it flips, and only state a composition reads can do that. */
    val folderChosen: Boolean = false,
    val ready: Boolean = false,
    val loading: Boolean = false,
    val entries: List<Entry> = emptyList(),     // newest first
    val sections: List<Section> = emptyList(),
    val selection: String? = null,
    val selectedEntry: Entry? = null,
    val selectedIsUnfiled: Boolean = false,
    val selectedNumber: Int? = null,
    val page: Page = Page.JOURNAL,
    val query: String = "",
    val saveState: SaveState = SaveState.Idle,
    val totalWords: Int = 0,
    val entriesThisMonth: Int = 0,
    val streak: Int = 0,
    val counts: Map<Page, Int> = emptyMap(),
    val folderName: String = "",
    val error: String? = null,
) {
    fun count(page: Page): Int = counts[page] ?: 0
}

class JournalStore(app: Application) : AndroidViewModel(app) {

    private val settings = Settings(app)
    private var library: JournalLibrary? = null

    private val _state = MutableStateFlow(JournalState(page = Page.of(settings.page)))
    val state: StateFlow<JournalState> = _state.asStateFlow()

    /** The live text of the selected entry, bound straight to the editor. */
    val draft = Draft()

    /** The entry a delete has been asked for; the page confirms before it goes. */
    var deletionCandidate by mutableStateOf<Entry?>(null)

    /** The entry whose date and time are being changed, if the sheet is open. */
    var reschedulingEntry by mutableStateOf<Entry?>(null)

    private var draftEntry: Entry? = null
    private var dirty = false
    private var saveJob: Job? = null
    private var lastFingerprint = ""
    private var fingerprintPending = false

    init {
        settings.rememberedFolder()?.let { open(it, remember = false) }
    }

    // MARK: The folder

    /** Adopt a folder the picker handed over, or one remembered from last launch. */
    fun open(uri: Uri, remember: Boolean = true) {
        flushNow()
        if (remember) settings.adopt(uri)
        val tree = SafTree(getApplication(), uri)
        val opened = JournalLibrary(tree)
        library = opened
        draftEntry = null
        _state.update {
            it.copy(selection = null, folderChosen = true, ready = false, loading = true, error = null)
        }
        viewModelScope.launch {
            val reachable = withContext(Dispatchers.IO) {
                opened.isReachable().also { if (it) opened.ensureFolders() }
            }
            if (!reachable) {
                library = null
                _state.update {
                    it.copy(
                        folderChosen = false,
                        loading = false,
                        error = "That folder can't be opened any more.",
                    )
                }
                return@launch
            }
            val name = withContext(Dispatchers.IO) { opened.folderName }
            _state.update { it.copy(folderName = name) }
            reload(select = true)
        }
    }

    fun forgetFolder() {
        library = null
        _state.value = JournalState(page = _state.value.page)
    }

    // MARK: Loading

    fun reload(select: Boolean = false) {
        val library = library ?: return
        viewModelScope.launch {
            _state.update { it.copy(loading = true) }
            val (entries, fingerprint) = withContext(Dispatchers.IO) {
                library.load() to library.fingerprint()
            }
            lastFingerprint = fingerprint

            // A new entry lives only in memory until it has text — it is given
            // inbox.md as its home at once, but nothing is written there until
            // something is typed. A reload must not drop it on the floor.
            val kept = draftEntry
            val list = if (kept != null && kept.source != null &&
                entries.none { it.id == kept.id } && (kept.suffix.isEmpty() && kept.body.isEmpty())
            ) listOf(kept) + entries else entries

            _state.update { it.copy(entries = list, ready = true, loading = false) }
            rebuildIndex()
            val current = _state.value.selection
            if (select || current == null || list.none { it.id == current }) {
                select(firstVisibleId())
            }
        }
    }

    /**
     * Skip the re-read when nothing on disk has changed — an edit made in jnl,
     * or arriving through a sync client while Wander was in the background,
     * still shows up on resume.
     */
    fun reloadIfChanged() {
        val library = library ?: return
        if (dirty || fingerprintPending) return
        viewModelScope.launch {
            val current = withContext(Dispatchers.IO) { library.fingerprint() }
            if (current == lastFingerprint) return@launch
            val keep = _state.value.selection
            reload()
            if (keep != null) select(keep)
        }
    }

    private fun firstVisibleId(): String? =
        _state.value.sections.firstOrNull()?.entries?.firstOrNull()?.id

    // MARK: Selection and drafts

    fun select(id: String?) {
        if (id == _state.value.selection && draftEntry != null) return
        flushNow()
        val entry = _state.value.entries.firstOrNull { it.id == id }
        draftEntry = entry
        draft.title = entry?.displayTitle ?: ""
        draft.body = entry?.body ?: ""
        dirty = false
        _state.update { it.copy(selection = id, saveState = SaveState.Idle) }
        rebuildSelection()
    }

    /** Switch page, keeping the open entry if it belongs there. */
    fun show(page: Page) {
        if (page == _state.value.page) return
        settings.page = page.key
        _state.update { it.copy(page = page) }
        rebuildIndex()
        val visible = _state.value.sections.flatMap { it.entries }
        val selection = _state.value.selection
        if (selection != null && visible.any { it.id == selection }) return
        select(visible.firstOrNull()?.id)
    }

    fun search(query: String) {
        if (query == _state.value.query) return
        _state.update { it.copy(query = query) }
        rebuildIndex()
    }

    /**
     * Called by the editor on every keystroke; the write itself is debounced.
     * The draft is compared against the entry rather than trusted, because
     * loading a different entry also changes the bound text — an edit is only an
     * edit when the text differs from what is filed.
     */
    fun edited() {
        val base = draftEntry ?: return
        if (draft.title == base.displayTitle && draft.body == base.body) {
            saveJob?.cancel()
            dirty = false
            if (_state.value.saveState == SaveState.Editing) {
                _state.update { it.copy(saveState = SaveState.Idle) }
            }
            return
        }
        dirty = true
        if (_state.value.saveState != SaveState.Editing) {
            _state.update { it.copy(saveState = SaveState.Editing) }
        }
        saveJob?.cancel()
        saveJob = viewModelScope.launch {
            delay(700)
            flush()
        }
    }

    /** Fold the draft back into the entry and rewrite its file. */
    fun flush() {
        val library = library ?: return
        saveJob?.cancel()
        saveJob = null
        val base = draftEntry ?: return
        if (!dirty) return
        dirty = false

        val revised = base.revised(draft.title, draft.body)
        val isEmpty = revised.suffix.isEmpty() && revised.body.isEmpty()

        // Trailing whitespace alone can't cost a file rewrite.
        if (revised.raw == base.raw && base.source != null) {
            _state.update { it.copy(saveState = SaveState.Saved(LocalDateTime.now())) }
            return
        }

        viewModelScope.launch {
            try {
                if (isEmpty) {
                    // Never leave an empty stub on disk. If it was written
                    // earlier (title typed, then deleted), take it back out.
                    withContext(Dispatchers.IO) { if (base.source != null) library.remove(base) }
                    replaceInMemory(base, revised)
                    _state.update { it.copy(saveState = SaveState.Idle) }
                } else {
                    val written = withContext(Dispatchers.IO) { library.persist(revised, base) }
                    replaceInMemory(base, written)
                    _state.update { it.copy(saveState = SaveState.Saved(LocalDateTime.now())) }
                }
                refreshFingerprint()
            } catch (error: Throwable) {
                dirty = true
                _state.update {
                    it.copy(saveState = SaveState.Failed(error.message ?: "write failed"))
                }
            }
        }
    }

    /** The save the lifecycle asks for when the app goes to the background. */
    fun flushNow() = flush()

    /**
     * Re-take the folder's fingerprint after a write of our own, off the main
     * thread: it stats every file in the journal, and a save happens while the
     * writing carries on.
     */
    private fun refreshFingerprint() {
        val library = library ?: return
        fingerprintPending = true
        viewModelScope.launch {
            val taken = withContext(Dispatchers.IO) { library.fingerprint() }
            lastFingerprint = taken
            fingerprintPending = false
        }
    }

    private fun replaceInMemory(old: Entry, new: Entry) {
        val entries = _state.value.entries.toMutableList()
        val index = entries.indexOfFirst { it.id == old.id }
        if (index >= 0) entries[index] = new else entries.add(0, new)
        draftEntry = new
        val selection = if (_state.value.selection == old.id) new.id else _state.value.selection
        _state.update { it.copy(entries = entries, selection = selection) }
        rebuildIndex()
    }

    // MARK: Moving between files

    /**
     * Move an entry to [target] under the timestamp [desired] — the one
     * primitive behind retiming, filing and unfiling.
     */
    private suspend fun move(current: Entry, target: String, desired: String) {
        val library = library ?: return
        try {
            val written = withContext(Dispatchers.IO) {
                val stamp = library.freeStamp(desired, target, current)
                val moved = Entry.of(stamp, current.suffix, current.body, target)
                library.remove(current)
                // An entry with neither title nor body is never written — moving
                // an untouched new entry to another day must not leave a stub.
                if (moved.suffix.isEmpty() && moved.body.isEmpty()) moved
                else library.persist(moved, null)
            }
            val blank = written.suffix.isEmpty() && written.body.isEmpty()
            val entries = _state.value.entries.filter { it.id != current.id } + written
            val ordered = JournalParser.sortedByTimestamp(entries).reversed()
            draftEntry = written
            draft.title = written.displayTitle
            draft.body = written.body
            dirty = false
            _state.update {
                it.copy(
                    entries = ordered,
                    selection = written.id,
                    saveState = if (blank) SaveState.Idle else SaveState.Saved(LocalDateTime.now()),
                )
            }
            rebuildIndex()
            refreshFingerprint()
        } catch (error: Throwable) {
            _state.update { it.copy(saveState = SaveState.Failed(error.message ?: "move failed")) }
        }
    }

    /**
     * Change an entry's timestamp. For a filed entry the date is the filename,
     * so this moves it between day files. A draft stays in inbox.md, which isn't
     * dated — retiming there must not quietly file it.
     */
    fun reschedule(entry: Entry, at: LocalDateTime) {
        val library = library ?: return
        viewModelScope.launch {
            flush()
            val current = _state.value.entries.firstOrNull { it.id == entry.id } ?: entry
            val stamp = Formats.stamp(at)
            if (stamp == current.ts) return@launch
            val target = if (library.isUnfiled(current)) JournalPaths.INBOX
            else library.dayFile(stamp.take(10)) ?: return@launch
            move(current, target, stamp)
        }
    }

    /** Draft to journal: inbox.md into journal/YYYY/MM/DD.md, by its own date. */
    fun file(entry: Entry) {
        val library = library ?: return
        viewModelScope.launch {
            flush()
            val current = _state.value.entries.firstOrNull { it.id == entry.id } ?: entry
            val target = library.dayFile(current.date) ?: return@launch
            move(current, target, current.ts)
        }
    }

    /** Journal to draft: back to inbox.md, to be worked on and filed again. */
    fun unfile(entry: Entry) {
        viewModelScope.launch {
            flush()
            val current = _state.value.entries.firstOrNull { it.id == entry.id } ?: entry
            if (current.isUnfiled) return@launch
            move(current, JournalPaths.INBOX, current.ts)
        }
    }

    /**
     * Toggle whichever way the entry sits, and follow it to the page it now
     * lives on so the open entry doesn't vanish from the index.
     */
    fun toggleFiling(entry: Entry) {
        val wasUnfiled = entry.isUnfiled
        if (wasUnfiled) file(entry) else unfile(entry)
        val page = _state.value.page
        if (page == Page.JOURNAL && !wasUnfiled) show(Page.INBOX)
        else if (page == Page.INBOX && wasUnfiled) show(Page.JOURNAL)
    }

    fun destinationName(entry: Entry, at: LocalDateTime): String =
        library?.destinationName(entry, Formats.stamp(at).take(10)) ?: ""

    // MARK: Commands

    /**
     * Start writing. New work goes to inbox.md, not into the dated record: what
     * you have just begun is rarely ready to belong to a day, and filing it
     * later is one tap. There is no second way to start.
     */
    fun newEntry() {
        if (library == null) return
        flushNow()
        show(Page.INBOX)
        val entry = Entry.blank(JournalPaths.INBOX)
        _state.update { it.copy(entries = listOf(entry) + it.entries) }
        rebuildIndex()
        draftEntry = entry
        draft.title = ""
        draft.body = ""
        dirty = false
        _state.update { it.copy(selection = entry.id, saveState = SaveState.Idle) }
        rebuildSelection()
    }

    fun delete(entry: Entry) {
        val library = library ?: return
        saveJob?.cancel()
        dirty = false
        viewModelScope.launch {
            withContext(Dispatchers.IO) { runCatching { library.remove(entry) } }
            val entries = _state.value.entries.filter { it.id != entry.id }
            val wasSelected = _state.value.selection == entry.id
            _state.update { it.copy(entries = entries) }
            rebuildIndex()
            if (wasSelected) {
                draftEntry = null
                select(firstVisibleId())
            }
            refreshFingerprint()
        }
    }

    fun toggleStar(entry: Entry) {
        val library = library ?: return
        val flipped = entry.revised(entry.displayTitle, entry.body, !entry.isStarred)
        if (flipped.suffix.isEmpty() && flipped.body.isEmpty()) return
        viewModelScope.launch {
            val written = withContext(Dispatchers.IO) {
                runCatching { library.persist(flipped, entry) }.getOrNull()
            } ?: return@launch
            replaceInMemory(entry, written)
            _state.update { it.copy(saveState = SaveState.Saved(LocalDateTime.now())) }
        }
    }

    fun toggleStarOnSelection() {
        flushNow()
        _state.value.selectedEntry?.let(::toggleStar)
    }

    /** Move the selection through the index: -1 newer, +1 older. */
    fun step(delta: Int) {
        val list = _state.value.sections.flatMap { it.entries }
        if (list.isEmpty()) return
        val current = list.indexOfFirst { it.id == _state.value.selection }
        if (current < 0) return select(list.first().id)
        select(list[(current + delta).coerceIn(0, list.size - 1)].id)
    }

    /**
     * Copy an entry's markdown — header line included, so it can be pasted
     * straight into another jnl file.
     */
    fun copyMarkdown(entry: Entry) {
        flushNow()
        val current = _state.value.entries.firstOrNull { it.id == entry.id } ?: entry
        val clipboard = getApplication<Application>()
            .getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("wander", current.raw))
    }

    // MARK: Derived

    /**
     * Recompute everything the index and the sheets read. One pass over the
     * journal, on the changes that can move the answer: a reload, an edit folded
     * back in, a new search, a different page.
     */
    private fun rebuildIndex() {
        val current = _state.value
        val needle = current.query.trim().lowercase()
        val visible = if (needle.isEmpty()) current.entries
        else current.entries.filter { it.raw.lowercase().contains(needle) }

        val journal = ArrayList<Entry>()
        val inbox = ArrayList<Entry>()
        val starred = ArrayList<Entry>()
        for (entry in visible) {
            if (entry.isUnfiled) inbox.add(entry) else journal.add(entry)
            if (entry.isStarred) starred.add(entry)
        }

        val sections = when (current.page) {
            Page.JOURNAL -> JournalIndex.months(journal).map { Section(it.title, it.entries, false) }
            Page.INBOX -> if (inbox.isEmpty()) emptyList() else listOf(Section("Inbox", inbox, true))
            Page.STARRED -> JournalIndex.months(starred).map { Section(it.title, it.entries, false) }
        }

        // The badges count the whole journal, not the search — a filtered count
        // beside "Inbox" would read as the queue having emptied.
        val counts = if (needle.isEmpty()) {
            mapOf(Page.JOURNAL to journal.size, Page.INBOX to inbox.size, Page.STARRED to starred.size)
        } else {
            var j = 0; var i = 0; var s = 0
            for (entry in current.entries) {
                if (entry.isUnfiled) i += 1 else j += 1
                if (entry.isStarred) s += 1
            }
            mapOf(Page.JOURNAL to j, Page.INBOX to i, Page.STARRED to s)
        }

        var words = 0
        for (entry in current.entries) words += entry.wordCount
        val month = Formats.today().take(7)
        val thisMonth = current.entries.count { it.date.startsWith(month) }

        _state.update {
            it.copy(
                sections = sections,
                counts = counts,
                totalWords = words,
                entriesThisMonth = thisMonth,
                streak = JournalIndex.streak(it.entries),
            )
        }
        rebuildSelection()
    }

    /** The three things that follow the selection rather than the journal. */
    private fun rebuildSelection() {
        val current = _state.value
        val index = current.entries.indexOfFirst { it.id == current.selection }
        if (index < 0) {
            _state.update {
                it.copy(selectedEntry = null, selectedIsUnfiled = false, selectedNumber = null)
            }
            return
        }
        val entry = current.entries[index]
        _state.update {
            it.copy(
                selectedEntry = entry,
                selectedIsUnfiled = entry.isUnfiled,
                selectedNumber = it.entries.size - index,
            )
        }
    }

    // MARK: Live counts, for the status line

    fun liveCounts(): String {
        val words = Counts.words(draft.body)
        val characters = Counts.characters(draft.body)
        val minutes = Counts.readingMinutes(draft.body)
        val parts = mutableListOf(
            "$words ${if (words == 1) "word" else "words"}",
            "$characters characters",
        )
        if (minutes > 0) parts.add("$minutes min read")
        return parts.joinToString(" · ")
    }
}
