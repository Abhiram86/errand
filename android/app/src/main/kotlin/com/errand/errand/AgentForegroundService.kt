package com.errand.errand

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.ServiceCompat
import com.errand.errand.R

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

        /**
         * Backstop for a Dart side that never calls [stop]. A leaked service here
         * would hold the shared 6h/24h dataSync budget (see [onTimeout]) and
         * eventually break every future turn *and* every scheduled task. Generous
         * relative to a real turn, but far below the budget it would otherwise eat.
         */
        private const val SELF_TIMEOUT_MS = 15 * 60_000L

        fun start(context: Context) {
            val intent = Intent(context, AgentForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, AgentForegroundService::class.java))
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val selfTimeout = Runnable { stopSelfSafely() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Type-qualified overload: the legacy 2-arg form leaves the running
        // service without a declared type, which matters from Android 14.
        ServiceCompat.startForeground(
            this, NOTIFICATION_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )
        // Re-arm on every start so a restart cannot shorten the backstop.
        mainHandler.removeCallbacks(selfTimeout)
        mainHandler.postDelayed(selfTimeout, SELF_TIMEOUT_MS)
        return START_NOT_STICKY
    }

    /**
     * Android 15+ calls this once the app's 6h/24h dataSync budget is spent. Not
     * overriding it means the framework default does not stop the service and the
     * system raises `RemoteServiceException` instead.
     */
    override fun onTimeout(startId: Int, fgsType: Int) {
        super.onTimeout(startId, fgsType)
        mainHandler.removeCallbacks(selfTimeout)
        stopSelfSafely()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(selfTimeout)
        super.onDestroy()
    }

    private fun stopSelfSafely() {
        mainHandler.removeCallbacks(selfTimeout)
        ServiceCompat.stopForeground(this, Service.STOP_FOREGROUND_REMOVE)
        stopSelf()
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
            .setSmallIcon(R.drawable.ic_stat_errand)
            .setContentIntent(pendingTap)
            .setOngoing(true)
            .build()
    }
}
