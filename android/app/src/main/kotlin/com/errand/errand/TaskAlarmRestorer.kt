package com.errand.errand

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.ContentValues
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

    /**
     * Ceiling on alarms registered inside one broadcast. A BroadcastReceiver has
     * roughly a 10s budget before the system ANRs it, and an ANR during
     * BOOT_COMPLETED blocks the boot. Anything beyond this is deferred to
     * [scheduleRetry], which runs in a JobService off the critical path.
     */
    private const val MAX_ALARMS_PER_BROADCAST = 200

    /**
     * A task that came due less than this long ago still runs now.
     */
    private const val FRESHNESS_WINDOW_MS = 30 * 60 * 1000L
    private const val LOG_TABLE = "scheduler_task_log"

    data class Result(
        val taskCount: Int,
        val exactAlarmCount: Int,
        val inexactAlarmCount: Int,
        val retryable: Boolean,
        val skippedCount: Int = 0,
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
    /**
     * @param missedReason human cause recorded on skip rows, e.g.
     * "device was rebooting" vs "app was updating".
     */
    fun restore(context: Context, missedReason: String = "device was rebooting"): Result {
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
        var skippedCount = 0

        return try {
            // Read-write, not read-only: a WAL database with a hot journal
            // needs write access to the -shm/-wal sidecars for recovery,
            // and the skip path below writes. SELECT-only callers are
            // unaffected.
            database = SQLiteDatabase.openDatabase(
                databaseFile.path,
                null,
                SQLiteDatabase.OPEN_READWRITE,
            )

            var deferredCount = 0
            database.query(
                SCHEDULER_TABLE,
                arrayOf("id", "title", "status", "type", "starts_at", "next_run_at", "repeat_after"),
                "status IN (?, ?)",
                arrayOf("scheduled", "failed"),
                null,
                null,
                "id ASC",
            ).use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow("id")
                val titleIndex = cursor.getColumnIndexOrThrow("title")
                val statusIndex = cursor.getColumnIndexOrThrow("status")
                val typeIndex = cursor.getColumnIndexOrThrow("type")
                val startsAtIndex = cursor.getColumnIndexOrThrow("starts_at")
                val nextRunAtIndex = cursor.getColumnIndexOrThrow("next_run_at")
                val repeatAfterIndex = cursor.getColumnIndexOrThrow("repeat_after")

                while (cursor.moveToNext()) {
                    val taskId = cursor.getInt(idIndex)
                    if (taskId <= 0) continue

                    val status = cursor.getString(statusIndex)
                    val storedTrigger = if (cursor.isNull(nextRunAtIndex)) {
                        cursor.getLong(startsAtIndex)
                    } else {
                        cursor.getLong(nextRunAtIndex)
                    }
                    val now = System.currentTimeMillis()
                    // A `failed` row carries no retry intent of its own: only
                    // restore it when its stored trigger is still in the
                    // future, i.e. a live alarm died with the reboot. A
                    // past-due failed row is left alone — clamping it to
                    // now+1s would re-fire a dead one-off on every boot.
                    // (`running` rows are deliberately NOT selected here:
                    // executeTask rejects them, and Dart's recoverStuckTasks
                    // reconciles them — rescheduling recurring runs and
                    // failing one-offs — on the next Flutter start.)
                    if (status == "failed" && storedTrigger <= now) {
                        continue
                    }

                    // Past-due handling. Future triggers restore verbatim.
                    // Recurring rows jump to the next future grid slot (and
                    // persist it so the UI stops showing a stale time). Rows
                    // that only just lapsed (boot took minutes) run now. A
                    // long-dead one-off is recorded as skipped with a reason
                    // instead of firing hours late.
                    val triggerAt: Long
                    if (storedTrigger > now) {
                        triggerAt = storedTrigger
                    } else {
                        val repeatAfter = if (cursor.isNull(repeatAfterIndex)) {
                            0L
                        } else {
                            cursor.getLong(repeatAfterIndex)
                        }
                        if (cursor.getString(typeIndex) == "recurring" && repeatAfter > 0) {
                            triggerAt = nextGridSlot(
                                cursor.getLong(startsAtIndex), repeatAfter, now
                            )
                            updateNextRunAt(database, taskId, triggerAt, now)
                        } else if (now - storedTrigger < FRESHNESS_WINDOW_MS) {
                            triggerAt = now + 1_000L
                        } else {
                            markSkipped(database, taskId, storedTrigger, status, missedReason, now)
                            skippedCount++
                            continue
                        }
                    }

                    taskCount++
                    val title = cursor.getString(titleIndex)?.ifBlank { "Scheduled Task" }
                        ?: "Scheduled Task"

                    // Broadcast receivers get roughly a 10s window before the
                    // system ANRs them, and an ANR during BOOT_COMPLETED blocks
                    // the boot itself. Registering one AlarmManager alarm per
                    // task sequentially can exceed that on a large task table,
                    // so cap the work here and hand the rest to scheduleRetry,
                    // which already runs off the critical path.
                    if (taskCount > MAX_ALARMS_PER_BROADCAST) {
                        deferredCount++
                        continue
                    }

                    // A false return means exact permission was unavailable and
                    // an inexact alarm was registered instead — not a failure.
                    if (TaskAlarmManager.scheduleExactAlarm(context, taskId, triggerAt, title)) {
                        exactCount++
                    } else {
                        inexactCount++
                    }
                }
                if (deferredCount > 0) {
                    Log.w(
                        TAG,
                        "Deferred $deferredCount alarms past the per-broadcast cap; scheduling retry"
                    )
                    scheduleRetry(context, "deferred")
                }
            }

            val elapsed = System.currentTimeMillis() - startedAt
            Log.i(TAG, "Restored ${exactCount + inexactCount}/$taskCount alarms in ${elapsed}ms deferred=$deferredCount skipped=$skippedCount")
            Log.i(P10_TAG, "boot_reschedule_done count=$taskCount exact=$exactCount inexact=$inexactCount deferred=$deferredCount skipped=$skippedCount duration_ms=$elapsed")
            Result(taskCount, exactCount, inexactCount, retryable = false, skippedCount = skippedCount)
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
    /**
     * Next future grid slot for a past-due recurring task (closed form,
     * mirroring Dart `calculateNextRunAt`). The overflow guard matches Dart:
     * an absurd interval wraps the sum negative, which fails the
     * `next <= now` check and falls back to now+60s instead of scheduling
     * in the past forever.
     */
    private fun nextGridSlot(startsAt: Long, repeatAfter: Long, now: Long): Long {
        if (repeatAfter <= 0 || startsAt >= now) return maxOf(startsAt, now + 1_000L)
        val elapsed = now - startsAt
        val n = (elapsed / repeatAfter) + 1
        val next = startsAt + (n * repeatAfter)
        return if (next <= now) now + 60_000L else next
    }

    /**
     * Persists a recomputed slot so the UI stops showing a stale time.
     * Guarded on live statuses: a concurrent Dart-side transition (pause,
     * delete, manual reschedule) is never clobbered by a boot pass.
     */
    private fun updateNextRunAt(database: SQLiteDatabase?, taskId: Int, nextRunAt: Long, now: Long) {
        if (database == null) return
        try {
            val values = ContentValues().apply {
                put("next_run_at", nextRunAt)
                put("updated_at", now)
            }
            database.update(
                SCHEDULER_TABLE, values,
                "id = ? AND status IN ('scheduled', 'failed')",
                arrayOf(taskId.toString())
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not persist recomputed slot for task $taskId", e)
        }
    }

    /**
     * Records a long-dead one-off as skipped with a human reason instead of
     * firing it hours late. Only `scheduled` rows: past-due `failed` rows
     * already tell their story and must keep their filter placement. The
     * task flip is guarded (returns flipped count); the log row is written
     * only when the flip landed, so a concurrent Dart transition can never
     * produce a skip row for a task that moved on. `skipped` never enters
     * the unread badge (it is not a terminal notify status), so this stays
     * a silent history entry the Runs tab can explain.
     */
    private fun markSkipped(
        database: SQLiteDatabase?,
        taskId: Int,
        storedTrigger: Long,
        status: String,
        reason: String,
        now: Long
    ) {
        if (database == null || status != "scheduled") return
        try {
            val taskValues = ContentValues().apply {
                put("status", "cancelled")
                putNull("next_run_at")
                put("updated_at", now)
            }
            val flipped = database.update(
                SCHEDULER_TABLE, taskValues,
                "id = ? AND status = ?",
                arrayOf(taskId.toString(), "scheduled")
            )
            if (flipped > 0) {
                val logValues = ContentValues().apply {
                    put("scheduler_task_id", taskId)
                    put("scheduled_for", storedTrigger)
                    put("status", "skipped")
                    put("error_message", "Skipped \u2014 $reason")
                    put("notification_sent", 0)
                    put("notification_seen", 0)
                    put("created_at", now)
                    put("updated_at", now)
                }
                database.insertOrThrow(LOG_TABLE, null, logValues)
                Log.i(TAG, "Marked task $taskId skipped ($reason)")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not record skip for task $taskId", e)
        }
    }

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
    fun restoreOnce(context: Context, missedReason: String = "device was rebooting"): Result? {
        if (!restoreInFlight.compareAndSet(false, true)) {
            Log.i(TAG, "Boot alarm restore already in flight; skipping duplicate")
            return null
        }
        return try {
            restore(context, missedReason)
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
