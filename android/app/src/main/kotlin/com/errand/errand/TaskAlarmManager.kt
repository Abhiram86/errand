package com.errand.errand

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Coordinates native Android [AlarmManager] registrations for scheduled background tasks.
 *
 * Uses [AlarmManager.setExactAndAllowWhileIdle] (or [AlarmManager.setAlarmClock] when possible)
 * to ensure exact-time firing even when the device is in low-power Doze mode.
 */
object TaskAlarmManager {
    private const val TAG = "TaskAlarmManager"
    const val ACTION_TASK_ALARM = "com.errand.ACTION_TASK_ALARM"
    const val EXTRA_TASK_ID = "task_id"
    const val EXTRA_TASK_TITLE = "task_title"

    /**
     * Checks if exact alarms are allowed on Android 12+ (API 31+).
     */
    fun canScheduleExactAlarms(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            return alarmManager.canScheduleExactAlarms()
        }
        return true
    }

    /**
     * Schedules an exact alarm to wake the device at [triggerAtMillis] for [taskId].
     */
    fun scheduleExactAlarm(
        context: Context,
        taskId: Int,
        triggerAtMillis: Long,
        title: String
    ): Boolean {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, TaskAlarmReceiver::class.java).apply {
            action = ACTION_TASK_ALARM
            putExtra(EXTRA_TASK_ID, taskId)
            putExtra(EXTRA_TASK_TITLE, title)
        }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val pendingIntent = PendingIntent.getBroadcast(
            context,
            taskId,
            intent,
            flags
        )

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // setExactAndAllowWhileIdle punches through Doze mode at exact trigger time
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pendingIntent
                )
            } else {
                alarmManager.setExact(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pendingIntent
                )
            }
            Log.d(TAG, "Scheduled exact alarm for task $taskId at $triggerAtMillis")
            return true
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException scheduling exact alarm for task $taskId", e)
            // Fallback to inexact setAndAllowWhileIdle if exact alarm permission not granted
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pendingIntent
                )
            } else {
                alarmManager.set(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pendingIntent
                )
            }
            return false
        } catch (e: Exception) {
            Log.e(TAG, "Failed to schedule alarm for task $taskId", e)
            return false
        }
    }

    /**
     * Cancels any pending alarm for [taskId].
     */
    fun cancelAlarm(context: Context, taskId: Int) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, TaskAlarmReceiver::class.java).apply {
            action = ACTION_TASK_ALARM
            putExtra(EXTRA_TASK_ID, taskId)
        }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val pendingIntent = PendingIntent.getBroadcast(
            context,
            taskId,
            intent,
            flags
        )

        alarmManager.cancel(pendingIntent)
        pendingIntent.cancel()
        Log.d(TAG, "Cancelled alarm for task $taskId")
    }
}
