package com.errand.errand

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Listens for system boot completion ([Intent.ACTION_BOOT_COMPLETED]) or app update
 * ([Intent.ACTION_MY_PACKAGE_REPLACED]) to reschedule all active tasks in SQLite.
 */
class TaskBootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "TaskBootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == "android.intent.action.QUICKBOOT_POWERON"
        ) {
            Log.d(TAG, "Boot or package update received: triggering task reschedule")
            try {
                TaskExecutionService.startForReschedule(context)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start reschedule from boot receiver", e)
            }
        }
    }
}
