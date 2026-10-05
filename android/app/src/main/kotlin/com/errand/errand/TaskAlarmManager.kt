package com.errand.errand

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PersistableBundle
import android.util.Log

/**
 * Coordinates native Android [AlarmManager] registrations for scheduled background tasks.
 *
 * Uses [AlarmManager.setExactAndAllowWhileIdle] to fire at exact trigger times when
 * exact-alarm permission is granted, with graceful downgrade to inexact
 * [AlarmManager.setAndAllowWhileIdle] otherwise.
 *
 * Note: while idle, Android throttles [AlarmManager.setExactAndAllowWhileIdle] to
 * roughly one alarm per ~9 minutes per app, so closely spaced tasks may be delayed.
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
     * Fallback scheduler for when exact alarms are unavailable (R2-H6).
     *
     * An inexact alarm firing into [TaskAlarmReceiver] cannot legally start a
     * foreground service on Android 12+ (`ForegroundServiceStartNotAllowed-
     * Exception`, previously only logged). A [JobScheduler] job can: the
     * running job puts the app on the temporary allowlist, so the FGS start
     * from [TaskExecutionJobService] is legal. Timing is inexact by design —
     * Dart surfaces that via the inexact-fallback flag.
     *
     * The job id IS the task id, mirroring alarm PendingIntent identity:
     * rescheduling overwrites, cancelling removes. Requires API 21+ (minSdk
     * is 24). Persisted across reboots; the boot restore re-registers alarms
     * from the database, which supersede stale jobs.
     */
    fun scheduleJobFallback(
        context: Context,
        taskId: Int,
        triggerAtMillis: Long,
        title: String
    ): Boolean {
        if (taskId <= 0 || triggerAtMillis <= 0) return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        return try {
            val scheduler =
                context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
            val extras = PersistableBundle().apply {
                putInt(TaskExecutionJobService.EXTRA_TASK_ID, taskId)
                putString(TaskExecutionJobService.EXTRA_TASK_TITLE, title)
            }
            val delay = maxOf(0L, triggerAtMillis - System.currentTimeMillis())
            val job = JobInfo.Builder(
                taskId,
                ComponentName(context, TaskExecutionJobService::class.java)
            )
                .setMinimumLatency(delay)
                .setOverrideDeadline(delay + JOB_GRACE_MS)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_NONE)
                .setPersisted(true)
                .setExtras(extras)
                .build()
            val scheduled =
                scheduler.schedule(job) == JobScheduler.RESULT_SUCCESS
            Log.d(TAG, "Scheduled job fallback for task $taskId (delay=${delay}ms): $scheduled")
            scheduled
        } catch (e: Exception) {
            Log.e(TAG, "Failed to schedule job fallback for task $taskId", e)
            false
        }
    }

    /**
     * Cancels any pending alarm for [taskId]. Uses FLAG_NO_CREATE so no
     * PendingIntent is resurrected just to cancel it.
     */
    fun cancelAlarm(context: Context, taskId: Int) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, TaskAlarmReceiver::class.java).apply {
            action = ACTION_TASK_ALARM
        }

        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_NO_CREATE
        }

        val pendingIntent = PendingIntent.getBroadcast(
            context,
            taskId,
            intent,
            flags
        ) ?: return

        alarmManager.cancel(pendingIntent)
        pendingIntent.cancel()
        cancelJobFallback(context, taskId)
        Log.d(TAG, "Cancelled alarm for task $taskId")
    }

    /**
     * Cancels a pending job-fallback registration for [taskId], if any.
     * Called from [cancelAlarm] so one entry point tears down both paths;
     * cancelling a non-existent job is a no-op.
     */
    fun cancelJobFallback(context: Context, taskId: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        try {
            val scheduler =
                context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
            scheduler.cancel(taskId)
        } catch (e: Exception) {
            Log.w(TAG, "Error cancelling job fallback for task $taskId", e)
        }
    }

    companion object {
        private const val JOB_GRACE_MS = 10 * 60 * 1000L
    }
}
