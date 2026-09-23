package com.errand.errand

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Build
import android.util.Log

/**
 * Retry path for boot alarm restoration when the receiver hits a transient
 * database/process failure. It never starts a foreground service.
 */
class TaskAlarmRescheduleJobService : JobService() {
    companion object {
        private const val TAG = "TaskAlarmRescheduleJob"
    }

    @Volatile
    private var stopped = false

    private var worker: Thread? = null

    override fun onStartJob(params: JobParameters): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false

        stopped = false
        val reason = params.extras.getString("reason") ?: "unknown"
        Log.i(TAG, "Retry job started reason=$reason")
        Log.i("P10", "boot_reschedule_retry_start reason=$reason")

        worker = Thread({
            // Guarded: a receiver restore may already be running. Skip rather
            // than duplicate — boot broadcasts routinely arrive in bursts.
            val result = TaskAlarmRestorer.restoreOnce(applicationContext)
            if (!stopped) {
                if (result == null) {
                    Log.i(TAG, "Retry job skipped; restore already in flight")
                    jobFinished(params, false)
                } else {
                    Log.i(TAG, "Retry job finished retryable=${result.retryable}")
                    jobFinished(params, result.retryable)
                }
            }
        }, "errand-alarm-restore-retry").also { it.start() }

        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        stopped = true
        worker?.interrupt()
        worker = null
        Log.w(TAG, "Retry job stopped; requesting another attempt")
        return true
    }
}
