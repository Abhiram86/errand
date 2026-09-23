package com.errand.errand

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import android.os.Build
import android.os.PersistableBundle
import android.util.Log
import java.io.File

/**
 * Restores AlarmManager entries without starting Flutter or a foreground service.
 *
 * Drift's default Android database directory is path_provider's application
 * documents directory. On Android that is Context.getDir("flutter", ...), so
 * driftDatabase(name: 'errand') resolves to <flutter-dir>/errand.sqlite.
 *
 * This intentionally reads only the scheduler projection needed to recreate an
 * alarm. Task state recovery remains owned by Dart and is not part of the boot
 * critical path.
 */
object TaskAlarmRestorer {
    private const val TAG = "TaskAlarmRestorer"
    private const val P10_TAG = "P10"
    private const val DATABASE_FILE = "errand.sqlite"
    private const val SCHEDULER_TABLE = "scheduler_task"
    private const val RETRY_JOB_ID = 41_017

    data class Result(
        val taskCount: Int,
        val exactAlarmCount: Int,
        val inexactAlarmCount: Int,
        val retryable: Boolean,
    ) {
        val alarmCount: Int get() = exactAlarmCount + inexactAlarmCount
    }

    /**
     * Re-registers all rows that Drift considers schedulable.
     *
     * A missing database/table means the app has not initialized scheduling
     * yet, so retrying would only create boot noise. Other SQLite failures are
     * retryable because they can be transient around package replacement.
     */
    fun restore(context: Context): Result {
        val startedAt = System.currentTimeMillis()
        val databaseFile = resolveDatabaseFile(context)

        if (databaseFile == null) {
            Log.i(TAG, "No Drift database yet; skipping boot alarm restore")
            return Result(taskCount = 0, exactAlarmCount = 0, inexactAlarmCount = 0, retryable = false)
        }

        var database: SQLiteDatabase? = null
        var taskCount = 0
        var exactCount = 0
        var inexactCount = 0

        return try {
            database = SQLiteDatabase.openDatabase(
                databaseFile.path,
                null,
                SQLiteDatabase.OPEN_READONLY,
            )

            database.query(
                SCHEDULER_TABLE,
                arrayOf("id", "title", "status", "starts_at", "next_run_at"),
                "status = ?",
                arrayOf("scheduled"),
                null,
                null,
                "id ASC",
            ).use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow("id")
                val titleIndex = cursor.getColumnIndexOrThrow("title")
                val startsAtIndex = cursor.getColumnIndexOrThrow("starts_at")
                val nextRunAtIndex = cursor.getColumnIndexOrThrow("next_run_at")

                while (cursor.moveToNext()) {
                    val taskId = cursor.getInt(idIndex)
                    if (taskId <= 0) continue

                    taskCount++
                    val title = cursor.getString(titleIndex)?.ifBlank { "Scheduled Task" }
                        ?: "Scheduled Task"
                    val storedTrigger = if (cursor.isNull(nextRunAtIndex)) {
                        cursor.getLong(startsAtIndex)
                    } else {
                        cursor.getLong(nextRunAtIndex)
                    }
                    val triggerAt = maxOf(storedTrigger, System.currentTimeMillis() + 1_000L)

                    // A false return means exact permission was unavailable and
                    // an inexact alarm was registered instead — not a failure.
                    if (TaskAlarmManager.scheduleExactAlarm(context, taskId, triggerAt, title)) {
                        exactCount++
                    } else {
                        inexactCount++
                    }
                }
            }

            val elapsed = System.currentTimeMillis() - startedAt
            Log.i(TAG, "Restored ${exactCount + inexactCount}/$taskCount alarms in ${elapsed}ms")
            Log.i(P10_TAG, "boot_reschedule_done count=$taskCount exact=$exactCount inexact=$inexactCount duration_ms=$elapsed")
            Result(taskCount, exactCount, inexactCount, retryable = false)
        } catch (error: SQLiteException) {
            val message = error.message.orEmpty()
            if (message.contains("no such table", ignoreCase = true)) {
                Log.i(TAG, "Scheduler table is not initialized yet; skipping boot alarm restore")
                Result(taskCount, exactCount, inexactCount, retryable = false)
            } else {
                Log.e(TAG, "SQLite failed during boot alarm restore; requesting retry", error)
                Result(taskCount, exactCount, inexactCount, retryable = true)
            }
        } catch (error: Exception) {
            Log.e(TAG, "Boot alarm restore failed; requesting retry", error)
            Result(taskCount, exactCount, inexactCount, retryable = true)
        } finally {
            database?.close()
        }
    }

    /**
     * Locates the Drift database without hardcoding path_provider internals.
     * Checks the standard database directory first, then the Flutter documents
     * directory where drift currently resolves it. Returns null when absent
     * (fresh install — nothing to restore).
     */
    private fun resolveDatabaseFile(context: Context): File? {
        val candidates = listOf(
            context.getDatabasePath(DATABASE_FILE),
            File(context.getDir("flutter", Context.MODE_PRIVATE), DATABASE_FILE),
        )
        return candidates.firstOrNull { it.exists() }
    }

    /** In-flight guard so overlapping boot broadcasts share one restore pass. */
    private val restoreInFlight = java.util.concurrent.atomic.AtomicBoolean(false)

    /**
     * Restores alarms unless another restore is already running, in which case
     * the in-flight result is shared. Returns null when skipped.
     */
    fun restoreOnce(context: Context): Result? {
        if (!restoreInFlight.compareAndSet(false, true)) {
            Log.i(TAG, "Boot alarm restore already in flight; skipping duplicate")
            return null
        }
        return try {
            restore(context)
        } finally {
            restoreInFlight.set(false)
        }
    }

    /** Enqueues a short retry job; JobScheduler supplies backoff after failure. */
    fun scheduleRetry(context: Context, reason: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return

        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        val component = ComponentName(context, TaskAlarmRescheduleJobService::class.java)
        val extras = PersistableBundle().apply {
            putString("reason", reason)
        }
        val job = JobInfo.Builder(RETRY_JOB_ID, component)
            .setMinimumLatency(0L)
            .setOverrideDeadline(30_000L)
            .setBackoffCriteria(10_000L, JobInfo.BACKOFF_POLICY_LINEAR)
            .setExtras(extras)
            .build()

        val result = scheduler.schedule(job)
        Log.i(TAG, "Boot alarm restore retry scheduled result=$result reason=$reason")
    }
}
