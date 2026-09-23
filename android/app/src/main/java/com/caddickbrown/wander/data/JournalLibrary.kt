package com.caddickbrown.wander.data

import com.caddickbrown.wander.core.Entry
import com.caddickbrown.wander.core.Formats
import com.caddickbrown.wander.core.JournalPaths
import com.caddickbrown.wander.core.JournalParser

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

        tree.readText(JournalPaths.INBOX)?.let {
            found += JournalParser.parseEntries(it, JournalPaths.INBOX)
        }
        for (file in markdownFiles()) {
            val content = tree.readText(tree.documentUri(file.node.documentId)) ?: continue
            found += JournalParser.parseEntries(content, file.path)
        }
        return JournalParser.sortedByTimestamp(found).reversed()
    }

    private data class Found(val path: String, val node: SafTree.Node)

    /** Every .md under journal/, depth first, with its relative path. */
    private fun markdownFiles(): List<Found> {
        val journal = tree.find(JournalPaths.JOURNAL) ?: return emptyList()
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
        tree.find(JournalPaths.INBOX)?.let { id ->
            tree.children(tree.root).firstOrNull { it.documentId == id }?.let(::stat)
        }
        for (file in markdownFiles()) stat(file.node)
        return "$count|$size|$newest"
    }

    // MARK: Writing

    /**
     * Rewrite the file that owns [entry], replacing the entry with the same
     * timestamp or appending it. Returns the entry with its source set.
     */
    fun persist(entry: Entry, previous: Entry?): Entry {
        val target = entry.source ?: previous?.source ?: dayFile(entry.date)
            ?: throw IllegalArgumentException("no file for ${entry.ts}")

        val existing = tree.readText(target) ?: ""
        val preamble = JournalParser.leadingPreamble(existing)
        val day = JournalParser.parseEntries(existing, target).toMutableList()

        val stamped = entry.movedTo(target)
        val index = day.indexOfFirst { it.ts == entry.ts }
        if (index >= 0) day[index] = stamped else day.add(stamped)

        val content = JournalParser.renderEntries(preamble, JournalParser.sortedByTimestamp(day))
        tree.writeText(target, content)
        return stamped
    }

    /** Take an entry out of its file, deleting the file if nothing is left. */
    fun remove(entry: Entry) {
        val target = entry.source ?: return
        val existing = tree.readText(target) ?: return
        val preamble = JournalParser.leadingPreamble(existing)
        val day = JournalParser.parseEntries(existing, target).filter { it.ts != entry.ts }
        val content = JournalParser.renderEntries(preamble, day)
        if (content.isBlank()) tree.delete(target) else tree.writeText(target, content)
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
