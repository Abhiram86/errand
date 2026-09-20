package com.errand.errand

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * BroadcastReceiver triggered when an AlarmManager alarm fires for a scheduled task.
 *
 * Hands off execution immediately to [TaskExecutionService] so that execution continues
 * under a Foreground Service and WakeLock without hitting BroadcastReceiver ANR timeouts.
 */
class TaskAlarmReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "TaskAlarmReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return
        val taskId = intent.getIntExtra(TaskAlarmManager.EXTRA_TASK_ID, -1)
        val taskTitle = intent.getStringExtra(TaskAlarmManager.EXTRA_TASK_TITLE) ?: "Scheduled Task"

        if (taskId <= 0) {
            Log.w(TAG, "Received alarm with invalid taskId: $taskId")
            return
        }

        Log.d(TAG, "Alarm triggered for task $taskId ($taskTitle)")
        TaskExecutionService.startForTask(context, taskId, taskTitle)
    }
}
