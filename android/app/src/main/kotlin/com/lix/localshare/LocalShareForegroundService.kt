package com.lix.localshare

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class LocalShareForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val address = intent?.getStringExtra(EXTRA_ADDRESS).orEmpty()
                val port = intent?.getIntExtra(EXTRA_PORT, 0) ?: 0
                startForeground(NOTIFICATION_ID, buildNotification(address, port))
                return START_STICKY
            }
        }
    }

    private fun buildNotification(address: String, port: Int): Notification {
        ensureChannel()
        val contentText = if (address.isNotBlank()) {
            "正在共享: $address"
        } else {
            "本地分享服务运行中，端口 $port"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("本地分享")
            .setContentText(contentText)
            .setSmallIcon(R.mipmap.launcher_icon)
            .setOngoing(true)
            .setSilent(true)
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
