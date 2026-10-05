package com.errand.errand

import android.app.job.JobParameters
import android.app.job.JobService
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.os.Build
import android.util.Log
import java.io.File

/**
 * Executes a scheduled task from [JobScheduler] when exact alarms are
 * unavailable (R2-H6 fallback).
 *
 * An inexact alarm firing into [TaskAlarmReceiver] cannot legally start a
 * foreground service on Android 12+. The receiver therefore schedules an
 * immediate job here instead: while this job runs, the app sits on the
 * temporary allowlist, so [TaskExecutionService.startForTask] succeeds where
 * the receiver-direct start threw `ForegroundServiceStartNotAllowedException`.
 *
 * The hand-off is fire-and-monitor: after starting the service, the worker
 * polls the execution-log row until it leaves `running` (or a ceiling hits),
 * then releases the job. The Dart run is fully independent — an early release
 * only frees the job slot; it never aborts the task. The claim guard in
 * `executeTask` rejects duplicate starts, so a retried job can never
 * double-run a task.
 */
class TaskExecutionJobService : JobService() {
    companion object {
        private const val TAG = "TaskExecutionJob"
        const val EXTRA_TASK_ID = "task_id"
        const val EXTRA_TASK_TITLE = "task_title"

        /** Upper bound on the monitor loop; the Dart run caps itself at 10 min. */
        private const val MAX_WAIT_MS = 11 * 60 * 1000L
        private const val POLL_MS = 20_000L

        private const val DATABASE_FILE = "errand.sqlite"
        private const val LOG_TABLE = "scheduler_task_log"
    }

    @Volatile
    private var stopped = false
    private var worker: Thread? = null

    override fun onStartJob(params: JobParameters): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return false
        val taskId = params.extras.getInt(EXTRA_TASK_ID, -1)
        if (taskId <= 0) return false
        val title = params.extras.getString(EXTRA_TASK_TITLE) ?: "Scheduled Task"

        stopped = false
        TaskAlarmReceiver.releaseWakeLock()
        Log.i(TAG, "Execution job started for task $taskId")

        worker = Thread({
            try {
                TaskExecutionService.startForTask(applicationContext, taskId, title)
                val deadline = System.currentTimeMillis() + MAX_WAIT_MS
                while (!stopped && System.currentTimeMillis() < deadline) {
                    try {
                        Thread.sleep(POLL_MS)
                    } catch (_: InterruptedException) {
                        break
                    }
                    if (stopped) break
                    if (isRunTerminal(taskId)) break
                }
            } catch (e: Exception) {
                Log.e(TAG, "Execution job failed for task $taskId", e)
            } finally {
                if (!stopped) jobFinished(params, false)
            }
        }, "errand-task-execution-$taskId").also { it.start() }

        // Async: the worker releases the job when the run terminates.
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        stopped = true
        worker?.interrupt()
        worker = null
        // Do NOT reschedule: the Dart run continues independently of the job,
        // and the next alarm owns the future. Rescheduling here would risk a
        // second start racing the still-running task.
        Log.i(TAG, "Execution job stopped by system; not rescheduling")
        return false
    }

    /**
     * True when the latest execution-log row for [taskId] reached a terminal
     * status, or when no row exists yet but the task itself left `running`
     * (recovered/deleted out from under the run). Read-only open: never blocks
     * WAL recovery, never mutates. Any read failure keeps waiting — the
     * deadline, not the database, bounds the loop.
     */
    private fun isRunTerminal(taskId: Int): Boolean {
        var database: SQLiteDatabase? = null
        return try {
            val databaseFile: File? = listOf(
                applicationContext.getDatabasePath(DATABASE_FILE),
                File(
                    applicationContext.getDir("flutter", MODE_PRIVATE),
                    DATABASE_FILE
                ),
            ).firstOrNull { it.exists() } ?: return false
            database = SQLiteDatabase.openDatabase(
                databaseFile.path,
                null,
                SQLiteDatabase.OPEN_READONLY,
            )
            database!!.rawQuery(
                "SELECT status FROM $LOG_TABLE WHERE scheduler_task_id = ? " +
                    "ORDER BY id DESC LIMIT 1",
                arrayOf(taskId.toString())
            ).use { cursor ->
                if (!cursor.moveToFirst()) return@use false
                cursor.getString(0) != "running"
            }
        } catch (_: SQLiteException) {
            false
        } catch (_: Exception) {
            false
        } finally {
            try {
                database?.close()
            } catch (_: Exception) {
            }
        }
    }
}
