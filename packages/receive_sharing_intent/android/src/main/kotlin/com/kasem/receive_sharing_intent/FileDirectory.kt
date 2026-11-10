package com.kasem.receive_sharing_intent

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File

object FileDirectory {
    // Use the granted URI, including DocumentsProvider URIs. A filesystem path
    // derived from a document ID is not readable under scoped storage.
    fun getAbsolutePath(context: Context, uri: Uri): String {
        require(uri.scheme == "content" || uri.scheme == "file") { "Unsupported shared file URI" }
        val displayName = if (uri.scheme == "content") {
            try {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (it.moveToFirst() && index >= 0) it.getString(index) else null
                }
            } catch (_: Exception) {
                null // A provider may allow reading without allowing metadata queries.
            }
        } else uri.lastPathSegment
        val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(context.contentResolver.getType(uri))
        val safeName = displayName?.substringAfterLast('/')?.substringAfterLast('\\')
            ?.replace(Regex("[\\p{Cntrl}]"), "_")
            ?.takeUnless { it.isBlank() || it == "." || it == ".." }
            ?: "shared-file.${extension ?: "bin"}"
        // Separate directories preserve both original names and same-name files
        // in a batch (or in successive shares).
        val directory = File(context.cacheDir, "shared-incoming").apply { mkdirs() }
        val batch = File(directory, java.util.UUID.randomUUID().toString()).apply { check(mkdir()) { "Unable to create share cache" } }
        val target = File(batch, safeName)
        try {
            val input = context.contentResolver.openInputStream(uri)
                ?: throw java.io.IOException("Unable to open shared file")
            input.use { source -> target.outputStream().use { source.copyTo(it) } }
            return target.absolutePath
        } catch (error: Exception) {
            target.delete()
            batch.delete()
            throw error
        }
    }
}
