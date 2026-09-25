package com.errand.errand

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Shared utility for dispatching and canceling native Android notifications
 * across both MainActivity and isolated background TaskExecutionService engines.
 */
object NotificationHelper {
    private const val TAG = "NotificationHelper"

    private val createdChannels = mutableSetOf<String>()

    fun showNotification(
        context: Context,
        id: Int,
        title: String,
        body: String,
        channelId: String = "scheduled_tasks",
        channelName: String = "Scheduled Tasks",
        isSuccess: Boolean? = null
    ): Boolean {
        try {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                createdChannels.add(channelId)
            ) {
                val channel = NotificationChannel(
                    channelId,
                    channelName,
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notifications for background scheduled tasks"
                    enableLights(true)
                    enableVibration(true)
                }
                manager.createNotificationChannel(channel)
            }

            val tapIntent = (context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra("task_id", id)
                putExtra("route", "manage_tasks_unread")
                putExtra("open_unread_tasks", true)
            }

            val pendingTap = PendingIntent.getActivity(
                context,
                id,
                tapIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            )

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, channelId)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

            val iconRes = when (isSuccess) {
                true -> android.R.drawable.checkbox_on_background
                false -> android.R.drawable.stat_notify_error
                null -> if (context.applicationInfo.icon != 0) context.applicationInfo.icon else android.R.drawable.ic_dialog_info
            }

            val notifColor = when (isSuccess) {
                true -> 0xFF238636.toInt() // Green
                false -> 0xFFDA3633.toInt() // Red
                null -> 0xFF58A6FF.toInt() // Blue
            }

            val notificationBuilder = builder
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setSmallIcon(iconRes)
                .setColor(notifColor)
                .setContentIntent(pendingTap)
                .setAutoCancel(true)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                notificationBuilder.setColorized(isSuccess != null)
            }

            val notification = notificationBuilder.build()

            manager.notify(id, notification)
            Log.d(TAG, "Notification $id ($title) delivered successfully")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show notification $id", e)
            return false
        }
    }

    fun cancelNotification(context: Context, id: Int): Boolean {
        try {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(id)
            return true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to cancel notification $id", e)
            return false
        }
    }

    fun hasPermission(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= 33) {
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }
}
