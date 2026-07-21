package com.lix.localshare

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class LocalShareForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseConnectionLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val address = intent?.getStringExtra(EXTRA_ADDRESS).orEmpty()
                val port = intent?.getIntExtra(EXTRA_PORT, 0) ?: 0
                startForeground(NOTIFICATION_ID, buildNotification(address, port))
                acquireConnectionLocks()
                return START_STICKY
            }
        }
    }

    override fun onDestroy() {
        releaseConnectionLocks()
        super.onDestroy()
    }

    private fun acquireConnectionLocks() {
        if (wakeLock == null) {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = powerManager
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:localshare-server")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        } else if (wakeLock?.isHeld != true) {
            wakeLock?.acquire()
        }

        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        if (wifiLock == null) {
            @Suppress("DEPRECATION")
            wifiLock = wifiManager
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "$packageName:localshare-wifi")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        } else if (wifiLock?.isHeld != true) {
            wifiLock?.acquire()
        }

        if (multicastLock == null) {
            multicastLock = wifiManager
                .createMulticastLock("$packageName:localshare-mdns")
                .apply {
                    setReferenceCounted(false)
                    acquire()
                }
        } else if (multicastLock?.isHeld != true) {
            multicastLock?.acquire()
        }
    }

    private fun releaseConnectionLocks() {
        runCatching {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        }
        multicastLock = null

        runCatching {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
        }
        wifiLock = null

        runCatching {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        }
        wakeLock = null
    }

    private fun buildNotification(address: String, port: Int): Notification {
        ensureChannel()
        val contentText = if (address.isNotBlank()) {
            "正在共享: $address"
        } else {
            "本地分享服务运行中，端口 $port"
        }
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("本地分享")
            .setContentText(contentText)
            .setSmallIcon(R.mipmap.launcher_icon)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "本地分享服务",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持本地分享服务在后台继续运行"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val ACTION_START = "localshare.action.START"
        const val ACTION_STOP = "localshare.action.STOP"
        const val EXTRA_ADDRESS = "address"
        const val EXTRA_PORT = "port"

        private const val CHANNEL_ID = "localshare_foreground_service"
        private const val NOTIFICATION_ID = 35773
    }
}
