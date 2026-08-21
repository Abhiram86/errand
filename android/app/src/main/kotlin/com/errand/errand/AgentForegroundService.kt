package com.errand.errand

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Short-lived foreground service held ONLY while an agent turn is running.
 *
 * Why it exists: when the intent tool launches another app, Errand loses
 * visibility and Android moves it into the *cached* state. On Android 12+
 * (universally on 14+) the Cached Apps Freezer freezes cached processes
 * ~10 seconds later — and per AOSP, freezing terminates the app's active
 * TCP sockets ("prevents the server side from sending keepalive pings").
 * That is exactly why SSE streams died mid-flight whenever an intent opened
 * another app.
 *
 * A foreground service keeps the process out of the cached state entirely,
 * so sockets survive while the user is inside the launched app.
 */
class AgentForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "agent_work"
        private const val NOTIFICATION_ID = 4711

        fun start(context: Context) {
            val intent = Intent(context, AgentForegroundService::class.java)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, AgentForegroundService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Agent activity",
                    NotificationManager.IMPORTANCE_LOW,
                )
            )
        }

        val tapIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingTap = PendingIntent.getActivity(
            this, 0, tapIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Errand is working")
            .setContentText("Agent turn in progress — tap to return")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pendingTap)
            .setOngoing(true)
            .build()
    }
}
