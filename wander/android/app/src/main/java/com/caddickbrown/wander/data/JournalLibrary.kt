package com.caddickbrown.wander.data

import com.caddickbrown.wander.core.Entry
import com.caddickbrown.wander.core.Formats
import com.caddickbrown.wander.core.JournalPaths
import com.caddickbrown.wander.core.JournalParser
import java.io.IOException

/**
 * Every read and write Wander makes to a journal folder, with no UI anywhere
 * near it — ported from WanderCore/Sources/WanderCore/JournalLibrary.swift over
 * [SafTree] instead of FileManager.
 *
 * The layout is jnl's, which Nook also uses:
 *
 *     <base>/journal/YYYY/MM/DD.md   one file per day
 *     <base>/inbox.md                undated drafts
 */
class JournalLibrary(private val tree: SafTree) {

    val folderName: String get() = tree.displayName()

    fun dayFile(date: String): String? = JournalPaths.dayFile(date)

    fun isUnfiled(entry: Entry): Boolean = entry.source == JournalPaths.INBOX

    /** Where a retimed entry would end up, for display before the move. */
    fun destinationName(entry: Entry, day: String): String =
        if (isUnfiled(entry)) JournalPaths.INBOX else (dayFile(day) ?: day)

    fun ensureFolders() {
        tree.findOrCreate(JournalPaths.JOURNAL, DIR)
    }

    // MARK: Reading

    /**
     * Every entry in the folder, newest first.
     *
     * The walk is by directory rather than by path: resolving
     * journal/YYYY/MM/DD.md for each of a thousand files would be four provider
     * queries apiece, where descending the tree once is one query per directory.
     */
    fun load(): List<Entry> {
        tree.invalidate()
        val found = ArrayList<Entry>()

        // A file that can't be read is left out rather than failing the whole
        // journal: its entries are invisible, but its bytes are untouched, and
        // a write to it is refused on the way in (see [rewrite]).
        runCatching { tree.readText(JournalPaths.INBOX) }.getOrNull()?.let {
            found += JournalParser.parseEntries(it, JournalPaths.INBOX)
        }
        for (file in markdownFiles()) {
            val content = runCatching { tree.readText(tree.documentUri(file.node.documentId)) }
                .getOrNull() ?: continue
            found += JournalParser.parseEntries(content, file.path)
        }
        return JournalParser.sortedByTimestamp(found).reversed()
    }

    private data class Found(val path: String, val node: SafTree.Node)

    /** Every .md under journal/, depth first, with its relative path. */
    private fun markdownFiles(): List<Found> {
        val journal = runCatching { tree.find(JournalPaths.JOURNAL) }.getOrNull()
            ?: return emptyList()
        val out = ArrayList<Found>()
        fun walk(documentId: String, prefix: String) {
            for (child in tree.children(documentId)) {
                val path = "$prefix/${child.name}"
                if (child.isDirectory) {
                    walk(child.documentId, path)
                } else if (child.name.endsWith(".md", ignoreCase = true)) {
                    out.add(Found(path, child))
                }
            }
        }
        walk(journal, JournalPaths.JOURNAL)
        return out
    }

    /**
     * Stat-only change detector: count, total size, newest mtime. Enough to
     * catch an edit made in jnl, or by a sync client, while Wander was in the
     * background — and cheap enough to run on every resume.
     */
    fun fingerprint(): String {
        var count = 0
        var size = 0L
        var newest = 0L
        fun stat(node: SafTree.Node) {
            count += 1
            size += node.size
            newest = maxOf(newest, node.lastModified)
        }
        runCatching { tree.find(JournalPaths.INBOX) }.getOrNull()?.let { id ->
            tree.children(tree.root).firstOrNull { it.documentId == id }?.let(::stat)
        }
        for (file in markdownFiles()) stat(file.node)
        return "$count|$size|$newest"
    }

    // MARK: Writing
    //
    // Every write reads the file first and rewrites it whole. The read is the
    // dangerous half: a file that is there but can't be read, or isn't UTF-8,
    // throws out of [SafTree.readText] and the write never happens. Only a file
    // that is genuinely absent starts from empty.

    /**
     * Read [target], let [change] edit its entries, and write it back with its
     * preamble — deleting the file if nothing is left in it.
     */
    private fun rewrite(target: String, change: (List<Entry>) -> List<Entry>) {
        val existing = tree.readText(target) ?: ""
        val preamble = JournalParser.leadingPreamble(existing)
        val day = change(JournalParser.parseEntries(existing, target))
        val content = JournalParser.renderEntries(preamble, day)
        if (content == existing) return
        if (content.isBlank()) tree.delete(target) else tree.writeText(target, content)
    }

    /**
     * Rewrite the file that owns [entry], replacing the entry with the same
     * timestamp or appending it. Returns the entry with its source set.
     */
    fun persist(entry: Entry, previous: Entry?): Entry {
        val target = entry.source ?: previous?.source ?: dayFile(entry.date)
            ?: throw IllegalArgumentException("no file for ${entry.ts}")
        val stamped = entry.movedTo(target)
        rewrite(target) { day ->
            val list = day.toMutableList()
            val index = list.indexOfFirst { it.ts == entry.ts }
            if (index >= 0) list[index] = stamped else list.add(stamped)
            JournalParser.sortedByTimestamp(list)
        }
        return stamped
    }

    /** Take an entry out of its file, deleting the file if nothing is left. */
    fun remove(entry: Entry) {
        val target = entry.source ?: return
        rewrite(target) { day -> day.filter { it.ts != entry.ts } }
    }

    /**
     * Move [current] to [target] under the first free timestamp at or after
     * [desired] — the one primitive behind retiming, filing and unfiling.
     *
     * The destination is written before the source is touched: if the second
     * step fails, the entry is in both files rather than neither. A duplicate
     * can be deleted; a loss can't be undone. Within one file there is no
     * second step — the entry is replaced in a single rewrite.
     */
    fun move(current: Entry, target: String, desired: String): Entry {
        val stamp = freeStamp(desired, target, current)
        val moved = Entry.of(stamp, current.suffix, current.body, target)
        // An entry with neither title nor body is never written — moving an
        // untouched new entry to another day must not leave a stub.
        val keep = if (moved.isBlank) emptyList() else listOf(moved)

        if (current.source == target) {
            rewrite(target) { day ->
                JournalParser.sortedByTimestamp(day.filter { it.ts != current.ts } + keep)
            }
            return moved
        }
        if (!moved.isBlank) persist(moved, null)
        try {
            remove(current)
        } catch (error: Throwable) {
            throw IOException(
                "Moved to ${moved.source}, but it couldn't be taken out of " +
                    "${current.source} — it's in both for now. (${error.message})",
                error,
            )
        }
        return moved
    }

    /**
     * A free timestamp at or after [desired] in [target] — two entries in one
     * file may not share a second, since the timestamp is the entry's identity.
     */
    fun freeStamp(desired: String, target: String, excluding: Entry?): String {
        val content = tree.readText(target) ?: return desired
        val taken = JournalParser.parseEntries(content).mapTo(HashSet()) { it.ts }
        if (excluding != null && excluding.source == target) taken.remove(excluding.ts)
        var stamp = desired
        while (taken.contains(stamp)) stamp = Formats.nextSecond(stamp)
        return stamp
    }

    fun isReachable(): Boolean = tree.isReachable()

    private companion object {
        const val DIR = android.provider.DocumentsContract.Document.MIME_TYPE_DIR
    }
}
