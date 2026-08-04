package com.lix.localshare

import android.Manifest
import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.app.DownloadManager
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress

class MainActivity: FlutterActivity() {
    private var notificationPermissionResult: MethodChannel.Result? = null
    private var nsdRegistrationListener: NsdManager.RegistrationListener? = null
    private var registeredDiscoveryName: String? = null
    private var registeredDiscoveryHostname: String? = null
    private var registeredDiscoveryPort: Int? = null

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localshare/download")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enqueueDownload" -> {
                        val url = call.argument<String>("url").orEmpty()
                        val fileName = call.argument<String>("fileName").orEmpty()
                        val mimeType = call.argument<String>("mimeType").orEmpty()
                        try {
                            result.success(enqueueDownload(url, fileName, mimeType))
                        } catch (error: Exception) {
                            result.error("download_failed", error.message, null)
                        }
                    }
                    "saveFileToDownloads" -> {
                        val sourcePath = call.argument<String>("sourcePath").orEmpty()
                        val fileName = call.argument<String>("fileName").orEmpty()
                        val mimeType = call.argument<String>("mimeType").orEmpty()
                        try {
                            result.success(saveFileToDownloads(sourcePath, fileName, mimeType))
                        } catch (error: Exception) {
                            result.error("save_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "localshare/discovery")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "registerHttpService" -> {
                        val port = call.argument<Int>("port") ?: 0
                        val address = call.argument<String>("address").orEmpty()
                        if (port <= 0) {
                            result.error("invalid_port", "port must be > 0", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(registerHttpDiscoveryService(port, address))
                        } catch (error: Exception) {
                            result.error("discovery_failed", error.message, null)
                        }
                    }
                    "unregisterHttpService" -> {
                        unregisterHttpDiscoveryService()
                        result.success(null)
                    }
                    "getRegisteredHttpService" -> {
                        result.success(buildDiscoveryPayload())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun registerHttpDiscoveryService(port: Int, address: String): Map<String, String>? {
        val manager = getSystemService(NSD_SERVICE) as? NsdManager ?: return null
        unregisterHttpDiscoveryService()
        val serviceName = buildDiscoveryServiceName()
        val serviceInfo = NsdServiceInfo().apply {
            this.serviceName = serviceName
            serviceType = DISCOVERY_SERVICE_TYPE
            setPort(port)
        }
        applyAdvertisedAddress(serviceInfo, address)
        val listener = object : NsdManager.RegistrationListener {
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                registeredDiscoveryName = null
                registeredDiscoveryHostname = null
                registeredDiscoveryPort = null
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}

            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                registeredDiscoveryName = serviceInfo.serviceName
                registeredDiscoveryHostname = extractAdvertisedHostname(serviceInfo)
                registeredDiscoveryPort = serviceInfo.port.takeIf { it > 0 } ?: port
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                if (registeredDiscoveryName == serviceInfo.serviceName) {
                    registeredDiscoveryName = null
                }
                registeredDiscoveryHostname = null
                registeredDiscoveryPort = null
            }
        }
        nsdRegistrationListener = listener
        registeredDiscoveryName = serviceName
        registeredDiscoveryHostname = null
        registeredDiscoveryPort = port
        manager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
        return buildDiscoveryPayload()
    }

    private fun unregisterHttpDiscoveryService() {
        val manager = getSystemService(NSD_SERVICE) as? NsdManager ?: return
        val listener = nsdRegistrationListener ?: return
        try {
            manager.unregisterService(listener)
        } catch (_: IllegalArgumentException) {
        } finally {
            nsdRegistrationListener = null
            registeredDiscoveryName = null
            registeredDiscoveryHostname = null
            registeredDiscoveryPort = null
        }
    }

    private fun buildDiscoveryPayload(): Map<String, String>? {
        val serviceName = registeredDiscoveryName ?: return null
        val payload = mutableMapOf(
            "serviceName" to serviceName,
            "serviceType" to DISCOVERY_SERVICE_TYPE.removeSuffix("."),
            "hint" to "$serviceName${DISCOVERY_SERVICE_TYPE}local",
        )
        val hostname = registeredDiscoveryHostname
        val port = registeredDiscoveryPort
        if (!hostname.isNullOrBlank() && port != null && port > 0) {
            val normalizedHostname = hostname
                .trim()
                .removeSuffix(".")
                .let { if (it.endsWith(".local", ignoreCase = true)) it else "$it.local" }
            payload["hostname"] = normalizedHostname
            payload["bookmarkUrl"] = "http://$normalizedHostname:$port"
        }
        return payload
    }

    private fun applyAdvertisedAddress(serviceInfo: NsdServiceInfo, address: String) {
        if (Build.VERSION.SDK_INT < 34 || address.isBlank()) {
            return
        }
        try {
            val inetAddress = InetAddress.getByName(address)
            val method = NsdServiceInfo::class.java.getMethod(
                "setHostAddresses",
                MutableList::class.java,
            )
            method.invoke(serviceInfo, mutableListOf(inetAddress))
        } catch (_: Exception) {
        }
    }

    private fun extractAdvertisedHostname(serviceInfo: NsdServiceInfo): String? {
        return try {
            val method = NsdServiceInfo::class.java.getMethod("getHostname")
            (method.invoke(serviceInfo) as? String)
                ?.trim()
                ?.removeSuffix(".local")
                ?.removeSuffix(".local.")
                ?.ifBlank { null }
        } catch (_: Exception) {
            null
        }
    }

    @SuppressLint("HardwareIds")
    private fun buildDiscoveryServiceName(): String {
        val rawId = try {
            Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID).orEmpty()
        } catch (_: Exception) {
            ""
        }
        val suffix = rawId.takeLast(6).ifBlank { "local" }
        return DISCOVERY_SERVICE_NAME
    }

    private fun sanitizeServiceName(name: String): String {
        val normalized = name
            .lowercase()
            .replace(Regex("[^a-z0-9-]"), "-")
            .replace(Regex("-{2,}"), "-")
            .trim('-')
        return normalized.ifBlank { "localshare" }.take(48)
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
                    "timestamp" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        clip.description.timestamp
                    } else {
                        0L
                    },
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

    private fun enqueueDownload(url: String, fileName: String, mimeType: String): String {
        require(url.isNotBlank()) { "url is required" }
        val safeFileName = sanitizeFileName(fileName.ifBlank { "localshare-download" })
        val request = DownloadManager.Request(Uri.parse(url)).apply {
            if (mimeType.isNotBlank()) {
                setMimeType(mimeType)
            }
            setTitle(safeFileName)
            setDescription("LocalShare 下载")
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
            setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, safeFileName)
        }
        val manager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
        manager.enqueue(request)
        return safeFileName
    }

    private fun saveFileToDownloads(sourcePath: String, fileName: String, mimeType: String): String {
        require(sourcePath.isNotBlank()) { "sourcePath is required" }
        val sourceFile = File(sourcePath)
        require(sourceFile.exists()) { "source file does not exist" }
        val safeFileName = sanitizeFileName(fileName.ifBlank { sourceFile.name })
        val targetDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!targetDir.exists()) {
            targetDir.mkdirs()
        }
        val targetFile = File(targetDir, safeFileName)
        sourceFile.copyTo(targetFile, overwrite = true)
        if (mimeType.isNotBlank()) {
            sendBroadcast(
                Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE).apply {
                    data = Uri.fromFile(targetFile)
                },
            )
        }
        return targetFile.absolutePath
    }

    private fun sanitizeFileName(name: String): String {
        return name.replace(Regex("[\\\\/:*?\"<>|\\r\\n]"), "_").trim().ifBlank {
            "localshare-download"
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

    override fun onDestroy() {
        unregisterHttpDiscoveryService()
        super.onDestroy()
    }

    companion object {
        private const val REQUEST_POST_NOTIFICATIONS = 35773
        private const val DISCOVERY_SERVICE_TYPE = "_http._tcp."
        private const val DISCOVERY_SERVICE_NAME = "localshare"
    }
}
