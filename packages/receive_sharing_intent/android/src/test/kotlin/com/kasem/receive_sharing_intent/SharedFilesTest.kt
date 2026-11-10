package com.kasem.receive_sharing_intent

import android.content.ClipData
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class SharedFilesTest {
    private lateinit var plugin: ReceiveSharingIntentPlugin

    @Before fun setup() {
        val provider = Robolectric.buildContentProvider(ShareProvider::class.java).create().get()
        ShadowContentResolver.registerProviderInternal("shared.test", provider)
        plugin = ReceiveSharingIntentPlugin()
        plugin.javaClass.getDeclaredField("applicationContext").apply { isAccessible = true }
            .set(plugin, RuntimeEnvironment.getApplication())
    }

    private fun read(intent: Intent): JSONArray = plugin.javaClass
        .getDeclaredMethod("getMediaUris", Intent::class.java).apply { isAccessible = true }
        .invoke(plugin, intent) as JSONArray

    private fun uri(id: String = "one") = Uri.parse("content://shared.test/$id")
    private fun send(mime: String = "text/plain") = Intent(Intent.ACTION_SEND).apply {
        type = mime
        putExtra(Intent.EXTRA_STREAM, uri())
    }

    @Test fun allFileFormatsRemainFiles() {
        for (mime in listOf("text/plain", "text/csv", "text/html", "application/pdf", "application/zip", "application/octet-stream", "*/*")) {
            val file = read(send(mime)).getJSONObject(0)
            assertEquals("file", file.getString("type"))
            assertEquals("报告.csv", File(file.getString("path")).name)
            assertEquals("contents-one", File(file.getString("path")).readText())
        }
    }

    @Test fun textFileAndCaptionAreSeparate() {
        val items = read(send().putExtra(Intent.EXTRA_TEXT, "说明"))
        assertEquals(2, items.length())
        assertEquals("file", items.getJSONObject(0).getString("type"))
        assertEquals("text", items.getJSONObject(1).getString("type"))
        assertEquals("说明", items.getJSONObject(1).getString("path"))
    }

    @Test fun plainTextIncludingPathLookingTextIsNeverOpenedAsFile() {
        for (text in listOf("hello", "/storage/emulated/0/Download/a.txt", "https://example.com")) {
            val item = read(Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
            }).getJSONObject(0)
            assertEquals("text", item.getString("type"))
            assertEquals(text, item.getString("path"))
        }
    }

    @Test fun multipleSameNameFilesKeepDistinctContents() {
        val items = read(Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = "text/csv"
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(uri(), uri("two")))
        })
        assertEquals(2, items.length())
        val first = items.getJSONObject(0)
        val second = items.getJSONObject(1)
        assertEquals("file", first.getString("type"))
        assertEquals("file", second.getString("type"))
        assertNotEquals(first.getString("path"), second.getString("path"))
        assertEquals("contents-one", File(first.getString("path")).readText())
        assertEquals("contents-two", File(second.getString("path")).readText())
    }

    @Test fun clipDataOnlyFilesAreRead() {
        for (action in listOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) {
            val items = read(Intent(action).apply {
                type = "text/csv"
                clipData = ClipData.newRawUri("file", uri()).apply { addItem(ClipData.Item(uri("two"))) }
            })
            assertEquals(2, items.length())
            assertEquals("file", items.getJSONObject(0).getString("type"))
        }
    }

    @Test fun documentUriIsReadThroughProvider() {
        val document = Uri.parse("content://shared.test/document/primary%3ADownload%2Fa.csv")
        val result = read(send().putExtra(Intent.EXTRA_STREAM, document)).getJSONObject(0)
        assertTrue(File(result.getString("path")).readText().startsWith("contents-"))
    }

    @Test fun providerMimeTypeIsPreservedForImages() {
        val result = read(send("*/*").putExtra(Intent.EXTRA_STREAM, uri("image"))).getJSONObject(0)
        assertEquals("image", result.getString("type"))
        assertEquals("image/png", result.getString("mimeType"))
    }

    @Test fun unreadableFileFailsInsteadOfFallingBackToCaptionOrPath() {
        try {
            read(send().putExtra(Intent.EXTRA_STREAM, uri("missing")).putExtra(Intent.EXTRA_TEXT, "caption"))
            fail("must report file read failure")
        } catch (error: java.lang.reflect.InvocationTargetException) {
            assertTrue(error.cause is java.io.FileNotFoundException)
        }
    }

    @Test fun localFileUriIsCopiedIntoCache() {
        val source = File.createTempFile("share-test", ".txt").apply { writeText("local data") }
        try {
            val result = read(send().putExtra(Intent.EXTRA_STREAM, Uri.fromFile(source))).getJSONObject(0)
            assertEquals("file", result.getString("type"))
            assertNotEquals(source.path, result.getString("path"))
            assertEquals("local data", File(result.getString("path")).readText())
        } finally { source.delete() }
    }
}

class ShareProvider : ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: Uri) = if (uri.lastPathSegment == "image") "image/png" else null
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor =
        MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply { addRow(arrayOf("报告.csv")) }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (uri.lastPathSegment == "missing") throw java.io.FileNotFoundException("missing")
        val file = File.createTempFile("provider", ".bin", context!!.cacheDir)
        file.writeText("contents-${uri.lastPathSegment}")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
