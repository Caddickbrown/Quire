package com.caddickbrown.wander.data

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.FileNotFoundException

/**
 * A journal folder reached through the Storage Access Framework.
 *
 * This is the file half of the app, and the one part with no counterpart in the
 * macOS, iOS, Linux or Tauri builds: those open a folder by path, and Android
 * does not hand out paths. What it hands out is a tree URI the user granted,
 * under which every file is addressed by an opaque document id.
 *
 * Two consequences shape everything below.
 *
 * First, a path has to be walked to be resolved — "journal/2026/09/08.md" is
 * four queries, not one `open`. So resolutions are cached, and a directory's
 * children are read in a single cursor with every column the caller could want,
 * rather than one `DocumentFile` call per attribute (which is what makes
 * `DocumentFile` unusable over a journal of any size).
 *
 * Second, there is no rename-over-an-existing-file, so [writeText] cannot be
 * the atomic replace the other builds use. It truncates and rewrites in place,
 * holding the previous bytes so a failed write can be put back.
 */
class SafTree(private val context: Context, val treeUri: Uri) {

    private val resolver: ContentResolver get() = context.contentResolver
    private val rootId: String = DocumentsContract.getTreeDocumentId(treeUri)

    /** Relative path to document id. Cleared whenever the folder is re-read. */
    private val resolved = HashMap<String, String?>()

    /** One file as the provider describes it. */
    data class Node(
        val documentId: String,
        val name: String,
        val mimeType: String,
        val lastModified: Long,
        val size: Long,
    ) {
        val isDirectory: Boolean get() = mimeType == DocumentsContract.Document.MIME_TYPE_DIR
    }

    private val projection = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_SIZE,
    )

    fun documentUri(documentId: String): Uri =
        DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)

    /** Every child of a directory, in one query. */
    fun children(documentId: String): List<Node> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        val out = ArrayList<Node>()
        runCatching {
            resolver.query(uri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    out.add(
                        Node(
                            documentId = cursor.getString(0),
                            name = cursor.getString(1) ?: "",
                            mimeType = cursor.getString(2) ?: "",
                            lastModified = if (cursor.isNull(3)) 0L else cursor.getLong(3),
                            size = if (cursor.isNull(4)) 0L else cursor.getLong(4),
                        )
                    )
                }
            }
        }
        return out
    }

    /** The document id at a relative path, or null if nothing is there. */
    fun find(path: String): String? = resolved.getOrPut(path) {
        var current = rootId
        for (segment in path.split('/')) {
            if (segment.isEmpty()) continue
            val child = children(current).firstOrNull { it.name == segment } ?: return@getOrPut null
            current = child.documentId
        }
        current
    }

    fun exists(path: String): Boolean = find(path) != null

    /**
     * The document id at a relative path, creating the file and every directory
     * above it if they are not there yet.
     */
    fun findOrCreate(path: String, mimeType: String = "text/markdown"): String? {
        resolved[path]?.let { return it }
        val segments = path.split('/').filter { it.isNotEmpty() }
        if (segments.isEmpty()) return null
        var current = rootId
        for ((index, segment) in segments.withIndex()) {
            val last = index == segments.lastIndex
            val existing = children(current).firstOrNull { it.name == segment }
            current = if (existing != null) {
                existing.documentId
            } else {
                val created = runCatching {
                    DocumentsContract.createDocument(
                        resolver,
                        documentUri(current),
                        if (last) mimeType else DocumentsContract.Document.MIME_TYPE_DIR,
                        segment,
                    )
                }.getOrNull() ?: return null
                DocumentsContract.getDocumentId(created)
            }
        }
        resolved[path] = current
        return current
    }

    fun readText(path: String): String? {
        val id = find(path) ?: return null
        return readText(documentUri(id))
    }

    fun readText(uri: Uri): String? = runCatching {
        resolver.openInputStream(uri)?.use { it.readBytes().toString(Charsets.UTF_8) }
    }.getOrNull()

    /**
     * Replace a file's contents. Not atomic — SAF offers no way to swap one
     * document for another — so the previous bytes are held and put back if the
     * write fails part way, which is the nearest thing to the guarantee the
     * other builds get from a rename.
     */
    fun writeText(path: String, content: String) {
        val id = findOrCreate(path) ?: throw FileNotFoundException("cannot create $path")
        val uri = documentUri(id)
        val previous = readText(uri)
        try {
            // "wt" truncates; without the t a shorter write leaves the tail of
            // the old file behind it.
            resolver.openOutputStream(uri, "wt")?.use { stream ->
                stream.write(content.toByteArray(Charsets.UTF_8))
                stream.flush()
            } ?: throw FileNotFoundException("cannot open $path for writing")
        } catch (error: Throwable) {
            if (previous != null) {
                runCatching {
                    resolver.openOutputStream(uri, "wt")?.use {
                        it.write(previous.toByteArray(Charsets.UTF_8))
                    }
                }
            }
            throw error
        }
    }

    fun delete(path: String) {
        val id = find(path) ?: return
        runCatching { DocumentsContract.deleteDocument(resolver, documentUri(id)) }
        resolved.remove(path)
    }

    /** Forget every cached resolution — after a write, a delete or a reload. */
    fun invalidate() = resolved.clear()

    /** The folder's display name, for the options panel. */
    fun displayName(): String {
        val uri = documentUri(rootId)
        return runCatching {
            resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull() ?: treeUri.lastPathSegment?.substringAfterLast('/') ?: "journal"

    }

    /** Whether the grant still stands — the folder can be deleted or the SD card pulled. */
    fun isReachable(): Boolean = runCatching { children(rootId); true }.getOrDefault(false)

    val root: String get() = rootId
}
