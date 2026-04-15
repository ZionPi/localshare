package com.lix.localshare

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private var notificationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localshare/lifecycle")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "closeApp" -> {
                        runOnUiThread {
                            finishAndRemoveTask()
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localshare/service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundService" -> {
                        val address = call.argument<String>("address").orEmpty()
                        val port = call.argument<Int>("port") ?: 0
                        val intent = Intent(this, LocalShareForegroundService::class.java).apply {
                            action = LocalShareForegroundService.ACTION_START
                            putExtra(LocalShareForegroundService.EXTRA_ADDRESS, address)
                            putExtra(LocalShareForegroundService.EXTRA_PORT, port)
                        }
                        ContextCompat.startForegroundService(this, intent)
                        result.success(null)
                    }
                    "stopForegroundService" -> {
                        val intent = Intent(this, LocalShareForegroundService::class.java).apply {
                            action = LocalShareForegroundService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                            result.success(true)
                        } else if (ContextCompat.checkSelfPermission(
                                this,
                                Manifest.permission.POST_NOTIFICATIONS,
                            ) == PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(true)
                        } else {
                            notificationPermissionResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQUEST_POST_NOTIFICATIONS,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localshare/clipboard")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readClipboardPayload" -> result.success(readClipboardPayload())
                    else -> result.notImplemented()
                }
            }
    }

    private fun readClipboardPayload(): Map<String, Any> {
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip ?: return mapOf("type" to "empty")
        val imagePayload = findImagePayload(clip)
        if (imagePayload != null) {
            return imagePayload
        }
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            val text = item.coerceToText(this)?.toString()?.trim().orEmpty()
            if (text.isNotEmpty()) {
                return mapOf(
                    "type" to "text",
                    "text" to text,
                )
            }
        }
        return mapOf("type" to "empty")
    }

    private fun findImagePayload(clip: ClipData): Map<String, Any>? {
        for (index in 0 until clip.itemCount) {
            val item = clip.getItemAt(index)
            val uri = item.uri ?: continue
            val mimeType = contentResolver.getType(uri).orEmpty()
            if (!mimeType.startsWith("image/")) {
                continue
            }
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: continue
            if (bytes.isEmpty()) {
                continue
            }
            return mapOf(
                "type" to "image",
                "name" to resolveDisplayName(uri, mimeType),
                "mimeType" to mimeType,
                "bytes" to bytes,
            )
        }
        return null
    }

    private fun resolveDisplayName(uri: Uri, mimeType: String): String {
        val fileNameFromQuery = queryDisplayName(uri)
        if (!fileNameFromQuery.isNullOrBlank()) {
            return fileNameFromQuery
        }
        val extension = MimeTypeMap.getSingleton()
            .getExtensionFromMimeType(mimeType)
            ?.ifBlank { null }
            ?: "bin"
        return "pasted-image.$extension"
    }

    private fun queryDisplayName(uri: Uri): String? {
        val cursor: Cursor = contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        ) ?: return null
        cursor.use {
            if (!it.moveToFirst()) {
                return null
            }
            val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index < 0) {
                return null
            }
            return it.getString(index)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_POST_NOTIFICATIONS) {
            return
        }
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        notificationPermissionResult?.success(granted)
        notificationPermissionResult = null
    }

    companion object {
        private const val REQUEST_POST_NOTIFICATIONS = 35773
    }
}
