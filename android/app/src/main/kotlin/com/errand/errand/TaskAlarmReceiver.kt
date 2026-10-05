package com.errand.errand

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.util.Log

/**
 * BroadcastReceiver triggered when an AlarmManager alarm fires for a scheduled task.
 *
 * Hands off execution immediately to [TaskExecutionService] so that execution continues
 * under a Foreground Service and WakeLock without hitting BroadcastReceiver ANR timeouts.
 *
 * Bridges the CPU sleep window between [onReceive] returning and [TaskExecutionService]
 * acquiring its own wake lock via a static 45-second fallback wake lock.
 */
class TaskAlarmReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "TaskAlarmReceiver"
        private const val BRIDGE_WAKELOCK_TIMEOUT_MS = 45_000L

        @Volatile
        private var bridgeWakeLock: PowerManager.WakeLock? = null

        /**
         * Releases the temporary receiver wake lock once [TaskExecutionService] has
         * started and acquired its own ongoing wake lock.
         */
        fun releaseWakeLock() {
            try {
                if (bridgeWakeLock?.isHeld == true) {
                    bridgeWakeLock?.release()
                }
                bridgeWakeLock = null
            } catch (e: Exception) {
                Log.w(TAG, "Error releasing receiver bridge wake lock", e)
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return
        val taskId = intent.getIntExtra(TaskAlarmManager.EXTRA_TASK_ID, -1)
        val taskTitle = intent.getStringExtra(TaskAlarmManager.EXTRA_TASK_TITLE) ?: "Scheduled Task"

        if (taskId <= 0) {
            Log.w(TAG, "Received alarm with invalid taskId: $taskId")
            return
        }

        // Bridge the CPU sleep window until TaskExecutionService acquires its own wake lock.
        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (bridgeWakeLock == null) {
                bridgeWakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "errand:TaskAlarmReceiverBridgeLock"
                ).apply {
                    setReferenceCounted(false)
                }
            }
            bridgeWakeLock?.acquire(BRIDGE_WAKELOCK_TIMEOUT_MS)
        } catch (e: Exception) {
            Log.e(TAG, "Error acquiring receiver bridge wake lock", e)
        }

        Log.d(TAG, "Alarm triggered for task $taskId ($taskTitle)")
        // Exact alarms start the service directly. An inexact alarm firing
        // here cannot legally start an FGS on Android 12+ (R2-H6) — on that
        // failure, hand to JobScheduler: the running job's temporary
        // allowlist makes the same start legal from TaskExecutionJobService.
        if (!TaskExecutionService.startForTask(context, taskId, taskTitle)) {
            Log.w(TAG, "Direct start failed for task $taskId; routing to job fallback")
            TaskAlarmManager.scheduleJobFallback(
                context,
                taskId,
                System.currentTimeMillis(),
                taskTitle
            )
        }
    }
}
