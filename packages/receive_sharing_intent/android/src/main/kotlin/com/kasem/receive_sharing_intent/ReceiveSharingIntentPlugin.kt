package com.kasem.receive_sharing_intent

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.media.MediaMetadataRetriever.METADATA_KEY_DURATION
import android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC
import android.net.Uri
import android.os.Parcelable
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.NewIntentListener
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.URLConnection

private const val MESSAGES_CHANNEL = "receive_sharing_intent/messages"
private const val EVENTS_CHANNEL_MEDIA = "receive_sharing_intent/events-media"
private const val EVENTS_CHANNEL_TEXT = "receive_sharing_intent/events-text"

class ReceiveSharingIntentPlugin : FlutterPlugin, ActivityAware, MethodCallHandler,
        EventChannel.StreamHandler, NewIntentListener {

    private var initialMedia: JSONArray? = null
    private var latestMedia: JSONArray? = null
    private var initialError: String? = null

    private var eventSinkMedia: EventChannel.EventSink? = null

    private var binding: ActivityPluginBinding? = null
    private lateinit var applicationContext: Context

    private fun setupCallbackChannels(binaryMessenger: BinaryMessenger) {
        val mChannel = MethodChannel(binaryMessenger, MESSAGES_CHANNEL)
        mChannel.setMethodCallHandler(this)

        val eChannelMedia = EventChannel(binaryMessenger, EVENTS_CHANNEL_MEDIA)
        eChannelMedia.setStreamHandler(this)

        val eChannelText = EventChannel(binaryMessenger, EVENTS_CHANNEL_TEXT)
        eChannelText.setStreamHandler(this)
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        setupCallbackChannels(binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        eventSinkMedia = events
    }

    override fun onCancel(arguments: Any?) {
        eventSinkMedia = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getInitialMedia" -> {
                if (initialError != null) result.error("share_read_failed", initialError, null)
                else result.success(initialMedia?.toString())
            }
            "reset" -> {
                initialMedia = null
                latestMedia = null
                initialError = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun handleIntent(intent: Intent, initial: Boolean) {
        when {
            // Sharing or opening media (image, video, text, file)
            intent.type != null && (
                    intent.action == Intent.ACTION_VIEW
                            || intent.action == Intent.ACTION_SEND
                            || intent.action == Intent.ACTION_SEND_MULTIPLE) -> {

                val value = try {
                    getMediaUris(intent)
                } catch (error: Exception) {
                    if (initial) initialError = error.message ?: "Unable to read shared file"
                    eventSinkMedia?.error("share_read_failed", error.message, null)
                    return
                }
                initialError = null
                if (initial) initialMedia = value
                latestMedia = value
                eventSinkMedia?.success(latestMedia?.toString())
            }

            // Opening URL
            intent.action == Intent.ACTION_VIEW -> {
                val value = JSONArray(
                        listOf(JSONObject()
                                .put("path", intent.dataString)
                                .put("type", MediaType.URL.value))
                )
                if (initial) initialMedia = value
                latestMedia = value
                eventSinkMedia?.success(latestMedia?.toString())
            }
        }
    }

    private fun getMediaUris(intent: Intent?): JSONArray? {
        if (intent == null) return null

        return when (intent.action) {
            Intent.ACTION_VIEW -> {
                val uri = intent.data
                toJsonObject(uri, null, intent.type)?.let { JSONArray(listOf(it)) }
            }

            Intent.ACTION_SEND -> {
                val uris = sharedUris(intent)
                val items = uris.mapNotNull { toJsonObject(it, null, intent.type) }.toMutableList()
                // EXTRA_TEXT is a caption when a stream is also present.
                toJsonObject(null, intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(), null)
                    ?.let { items.add(it) }
                JSONArray(items)
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = sharedUris(intent)
                val mimeTypes = intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)

                val items = uris.mapIndexedNotNull { index, uri ->
                    toJsonObject(uri, null, mimeTypes?.getOrNull(index) ?: intent.type)
                }.toMutableList()
                toJsonObject(null, intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(), null)
                    ?.let { items.add(it) }
                JSONArray(items)
            }

            else -> null
        }
    }

    private fun sharedUris(intent: Intent): List<Uri> {
        val streams = if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            intent.parcelableArrayList<Uri>(Intent.EXTRA_STREAM).orEmpty()
        } else {
            listOfNotNull(intent.parcelable<Uri>(Intent.EXTRA_STREAM))
        }
        if (streams.isNotEmpty()) return streams.distinct()
        val clip = intent.clipData ?: return emptyList()
        return (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }.distinct()
    }

    // content can only be uri or string
    private fun toJsonObject(uri: Uri?, text: String?, mimeType: String?): JSONObject? {
        if (uri == null) {
            if (text.isNullOrBlank()) return null
            return JSONObject().put("path", text).put("type", MediaType.TEXT.value)
        }
        val path = FileDirectory.getAbsolutePath(applicationContext, uri)
        val mType = applicationContext.contentResolver.getType(uri)
            ?: mimeType?.takeUnless { it.contains('*') }
            ?: URLConnection.guessContentTypeFromName(path)
        // A text/* stream is a file; only EXTRA_TEXT is plain text.
        val type = MediaType.fromMimeType(mType).let {
            if (it == MediaType.TEXT || it == MediaType.URL) MediaType.FILE else it
        }
        val (thumbnail, duration) = getThumbnailAndDuration(path, type)
        return JSONObject()
                .put("path", path)
                .put("type", type.value)
                .put("mimeType", mType)
                .put("thumbnail", thumbnail)
                .put("duration", duration)
    }

    // Get video thumbnail and duration.
    private fun getThumbnailAndDuration(path: String, type: MediaType): Pair<String?, Long?> {
        if (type != MediaType.VIDEO) return Pair(null, null) // get thumbnail and duration for video only
        val retriever = MediaMetadataRetriever()
        retriever.setDataSource(path)
        val duration = retriever.extractMetadata(METADATA_KEY_DURATION)?.toLongOrNull()
        val bitmap = retriever.getScaledFrameAtTime(-1, OPTION_CLOSEST_SYNC, 360, 360)
        retriever.release()
        if (bitmap == null) return Pair(null, null)
        val targetFile = File(applicationContext.cacheDir, "${File(path).name}.png")
        FileOutputStream(targetFile).use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        bitmap.recycle()
        return Pair(targetFile.path, duration)
    }

    enum class MediaType(val value: String) {
        IMAGE("image"), VIDEO("video"), TEXT("text"), FILE("file"), URL("url");

        companion object {
            fun fromMimeType(mimeType: String?): MediaType {
                return when {
                    mimeType?.startsWith("image") == true -> IMAGE
                    mimeType?.startsWith("video") == true -> VIDEO
                    mimeType?.startsWith("text") == true -> TEXT
                    else -> FILE
                }
            }
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addOnNewIntentListener(this)
        handleIntent(binding.activity.intent, true)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        binding?.removeOnNewIntentListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addOnNewIntentListener(this)
    }

    override fun onDetachedFromActivity() {
        binding?.removeOnNewIntentListener(this)
    }

    override fun onNewIntent(intent: Intent): Boolean {
        handleIntent(intent, false)
        return false
    }

    inline fun <reified T : Parcelable> Intent.parcelable(key: String): T? = when {
        Build.VERSION.SDK_INT >= 33 -> getParcelableExtra(key, T::class.java)
        else -> @Suppress("DEPRECATION") getParcelableExtra(key) as? T
    }

    inline fun <reified T : Parcelable> Intent.parcelableArrayList(key: String): ArrayList<T>? = when {
        Build.VERSION.SDK_INT >= 33 -> getParcelableArrayListExtra(key, T::class.java)
        else -> @Suppress("DEPRECATION") getParcelableArrayListExtra(key)
    }
}
