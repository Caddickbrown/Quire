package com.caddickbrown.wander.data

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * A day file whose bytes are not UTF-8. Refused rather than decoded lossily:
 * a lossy decode followed by a rewrite would replace every bad byte with U+FFFD
 * on disk, and the reader's remedy — re-save the file as UTF-8 — is different
 * from any other write failure's.
 */
class NotUtf8Exception : IOException(
    "This file isn't valid UTF-8. " +
        "Open it in an editor and re-save it as UTF-8."
)

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
 * holding the previous bytes so a failed write can be put back, and syncs to
 * the device before it returns.
 *
 * And one rule for reading: "not there" and "couldn't be read" are different
 * answers. [readText] returns null only for the first and throws for the
 * second, because a caller that is about to rewrite a file must never mistake
 * an unreadable one for an empty one — that is how a day's entries are lost.
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

    /**
     * Every child of a directory, in one query — or an empty list if the
     * provider won't answer. For walks, where a directory that can't be read is
     * a directory with nothing in it.
     */
    fun children(documentId: String): List<Node> =
        runCatching { query(documentId) }.getOrDefault(emptyList())

    /** Every child of a directory, throwing if the provider fails. */
    private fun query(documentId: String): List<Node> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        val out = ArrayList<Node>()
        val cursor = resolver.query(uri, projection, null, null, null)
            ?: throw IOException("the folder did not answer")
        cursor.use {
            while (it.moveToNext()) {
                out.add(
                    Node(
                        documentId = it.getString(0),
                        name = it.getString(1) ?: "",
                        mimeType = it.getString(2) ?: "",
                        lastModified = if (it.isNull(3)) 0L else it.getLong(3),
                        size = if (it.isNull(4)) 0L else it.getLong(4),
                    )
                )
            }
        }
        return out
    }

    /**
     * The document id at a relative path, or null if nothing is there. Throws
     * if a directory on the way can't be listed: an answer of "absent" has to
     * mean absent, or a write would take the file for new and replace it.
     */
    fun find(path: String): String? {
        if (resolved.containsKey(path)) return resolved[path]
        var current = rootId
        for (segment in path.split('/')) {
            if (segment.isEmpty()) continue
            val child = query(current).firstOrNull { it.name == segment }
            if (child == null) {
                resolved[path] = null
                return null
            }
            current = child.documentId
        }
        resolved[path] = current
        return current
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
            val existing = query(current).firstOrNull { it.name == segment }
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

    /** A file's text, null if there is no file, throwing if it can't be read. */
    fun readText(path: String): String? {
        val id = find(path) ?: return null
        return try {
            readText(documentUri(id))
        } catch (missing: FileNotFoundException) {
            // A cached id can outlive its file — deleted in another app since
            // the last reload. Ask the folder again before calling it an error.
            resolved.remove(path)
            val fresh = find(path) ?: return null
            if (fresh == id) throw missing
            readText(documentUri(fresh))
        }
    }

    /** A document's text, throwing if it can't be read or isn't UTF-8. */
    fun readText(uri: Uri): String = decode(readBytes(uri))

    private fun readBytes(uri: Uri): ByteArray =
        resolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw FileNotFoundException("cannot open $uri")

    /** Strict UTF-8: a bad byte is an error, never a silent U+FFFD. */
    private fun decode(bytes: ByteArray): String {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        return try {
            decoder.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (error: CharacterCodingException) {
            throw NotUtf8Exception()
        }
    }

    /**
     * Replace a file's contents. Not atomic — SAF offers no way to swap one
     * document for another — so the previous bytes are held and put back if the
     * write fails part way, which is the nearest thing to the guarantee the
     * other builds get from a rename.
     */
    fun writeText(path: String, content: String) {
        val id = findOrCreate(path) ?: throw FileNotFoundException("cannot create $path")
        val uri = documentUri(id)
        // The raw bytes, not decoded text: putting them back must restore the
        // file exactly, whatever it held.
        val previous = runCatching { readBytes(uri) }.getOrNull()
        try {
            write(uri, content.toByteArray(Charsets.UTF_8))
        } catch (error: Throwable) {
            if (previous != null) runCatching { write(uri, previous) }
            throw error
        }
    }

    /**
     * Truncate and write, then sync to the device before closing — a save that
     * returns has reached the disk, not a buffer the process takes with it.
     */
    private fun write(uri: Uri, bytes: ByteArray) {
        // "wt" truncates; without the t a shorter write leaves the tail of
        // the old file behind it.
        val stream = resolver.openOutputStream(uri, "wt")
            ?: throw FileNotFoundException("cannot open $uri for writing")
        stream.use {
            it.write(bytes)
            it.flush()
            // Local providers hand back a file; a cloud provider may hand back
            // a pipe, which has nothing to sync and says so by throwing.
            (it as? FileOutputStream)?.let { file -> runCatching { file.fd.sync() } }
        }
    }

    /** Delete a file, throwing if it is there and won't go. */
    fun delete(path: String) {
        val id = find(path) ?: return
        resolved.remove(path)
        if (!DocumentsContract.deleteDocument(resolver, documentUri(id))) {
            throw IOException("cannot delete $path")
        }
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

    /**
     * Whether the grant still stands — the folder can be deleted or the SD card
     * pulled. Asks the provider directly rather than through [children], which
     * would answer an unreachable folder with an empty list.
     */
    fun isReachable(): Boolean = runCatching {
        val root = resolver.query(
            documentUri(rootId),
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
            null, null, null,
        )?.use { it.moveToFirst() } ?: false
        root && run { query(rootId); true }
    }.getOrDefault(false)

    val root: String get() = rootId
}
