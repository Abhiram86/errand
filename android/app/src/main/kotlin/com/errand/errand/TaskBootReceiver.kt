package com.errand.errand

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.app.AlarmManager
import android.util.Log

/**
 * Listens for system boot completion ([Intent.ACTION_BOOT_COMPLETED]) or app update
 * ([Intent.ACTION_MY_PACKAGE_REPLACED]) to reschedule all active tasks in SQLite.
 */
class TaskBootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "TaskBootReceiver"
        private const val P10_TAG = "P10"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED
        ) {
            val startedAt = System.currentTimeMillis()
            Log.i(TAG, "Received $action; restoring alarms without Flutter/FGS")
            Log.i(P10_TAG, "boot_reschedule_start action=$action")

            val pendingResult = goAsync()
            Thread({
                try {
                    val result = TaskAlarmRestorer.restore(context.applicationContext)
                    if (result.retryable) {
                        TaskAlarmRestorer.scheduleRetry(context.applicationContext, action)
                    }
                    val elapsed = System.currentTimeMillis() - startedAt
                    Log.i(
                        TAG,
                        "Boot alarm restore finished tasks=${result.taskCount} " +
                            "alarms=${result.alarmCount} retryable=${result.retryable} elapsed=${elapsed}ms",
                    )
                } catch (error: Exception) {
                    Log.e(TAG, "Unexpected boot alarm restore failure", error)
                    TaskAlarmRestorer.scheduleRetry(context.applicationContext, action)
                } finally {
                    pendingResult.finish()
                }
            }, "errand-alarm-restore").start()
        }
    }
}
