package com.errand.errand

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Foreground service that guarantees process survival and CPU wake-lock while a background
 * task executes.
 *
 * If the application UI is active, delegates to the existing Flutter engine.
 * If the application is in the background or killed, spins up an isolated background FlutterEngine,
 * executes [backgroundTaskMain], invokes the requested operation, and cleanly disposes when finished.
 */
class TaskExecutionService : Service() {
    companion object {
        private const val TAG = "TaskExecutionService"
        private const val CHANNEL_ID = "scheduled_tasks_service"
        private const val NOTIFICATION_ID = 5823

        const val ACTION_EXECUTE_TASK = "com.errand.ACTION_EXECUTE_TASK"
        const val ACTION_RESCHEDULE_ALL = "com.errand.ACTION_RESCHEDULE_ALL"

        fun startForTask(context: Context, taskId: Int, taskTitle: String) {
            val intent = Intent(context, TaskExecutionService::class.java).apply {
                action = ACTION_EXECUTE_TASK
                putExtra(TaskAlarmManager.EXTRA_TASK_ID, taskId)
                putExtra(TaskAlarmManager.EXTRA_TASK_TITLE, taskTitle)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun startForReschedule(context: Context) {
            val intent = Intent(context, TaskExecutionService::class.java).apply {
                action = ACTION_RESCHEDULE_ALL
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var backgroundEngine: FlutterEngine? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "errand:TaskExecutionWakeLock"
        ).apply {
            setReferenceCounted(false)
            acquire(15 * 60 * 1000L) // 15-minute safety timeout
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(TaskAlarmManager.EXTRA_TASK_TITLE) ?: "Task in progress"
        startForeground(NOTIFICATION_ID, buildForegroundNotification(title))

        val action = intent?.action
        if (action == ACTION_EXECUTE_TASK) {
            val taskId = intent.getIntExtra(TaskAlarmManager.EXTRA_TASK_ID, -1)
            if (taskId > 0) {
                runTask(taskId)
            } else {
                stopExecution()
            }
        } else if (action == ACTION_RESCHEDULE_ALL) {
            runRescheduleAll()
        } else {
            stopExecution()
        }

        return START_NOT_STICKY
    }

    private fun runTask(taskId: Int) {
        val mainChannel = MainActivity.schedulerChannel
        if (mainChannel != null) {
            Log.d(TAG, "Dispatching executeTask($taskId) to active MainActivity engine")
            mainChannel.invokeMethod(
                "executeTask",
                mapOf("taskId" to taskId),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        Log.d(TAG, "Task $taskId completed on main engine: $result")
                        stopExecution()
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        Log.e(TAG, "Task $taskId failed on main engine: $code: $message")
                        stopExecution()
                    }

                    override fun notImplemented() {
                        Log.w(TAG, "executeTask not implemented on main engine, spinning background engine")
                        runTaskOnBackgroundEngine(taskId)
                    }
                }
            )
            return
        }

        runTaskOnBackgroundEngine(taskId)
    }

    private fun runTaskOnBackgroundEngine(taskId: Int) {
        mainHandler.post {
            try {
                Log.d(TAG, "Starting background FlutterEngine for task $taskId")
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)

                val engine = FlutterEngine(applicationContext)
                backgroundEngine = engine
                GeneratedPluginRegistrant.registerWith(engine)

                val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "task_scheduler")
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "scheduleAlarm" -> {
                            val id = call.argument<Int>("taskId") ?: -1
                            val trigger = call.argument<Number>("triggerAtMillis")?.toLong() ?: 0L
                            val title = call.argument<String>("title") ?: ""
                            if (id > 0 && trigger > 0) {
                                TaskAlarmManager.scheduleExactAlarm(applicationContext, id, trigger, title)
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        }
                        "cancelAlarm" -> {
                            val id = call.argument<Int>("taskId") ?: -1
                            if (id > 0) {
                                TaskAlarmManager.cancelAlarm(applicationContext, id)
                            }
                            result.success(true)
                        }
                        "canScheduleExactAlarms" -> {
                            result.success(TaskAlarmManager.canScheduleExactAlarms(applicationContext))
                        }
                        else -> result.notImplemented()
                    }
                }

                val entrypoint = DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "backgroundTaskMain"
                )
                engine.dartExecutor.executeDartEntrypoint(entrypoint)

                // Give Dart a short moment to attach its MethodCallHandler, then invoke executeTask
                mainHandler.postDelayed({
                    channel.invokeMethod(
                        "executeTask",
                        mapOf("taskId" to taskId),
                        object : MethodChannel.Result {
                            override fun success(res: Any?) {
                                Log.d(TAG, "Background execution of task $taskId completed: $res")
                                stopExecution()
                            }

                            override fun error(code: String, msg: String?, details: Any?) {
                                Log.e(TAG, "Background execution of task $taskId failed: $code: $msg")
                                stopExecution()
                            }

                            override fun notImplemented() {
                                Log.e(TAG, "executeTask not implemented in backgroundTaskMain")
                                stopExecution()
                            }
                        }
                    )
                }, 500)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize background Flutter engine", e)
                stopExecution()
            }
        }
    }

    private fun runRescheduleAll() {
        val mainChannel = MainActivity.schedulerChannel
        if (mainChannel != null) {
            mainChannel.invokeMethod("rescheduleAll", null, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    Log.d(TAG, "Rescheduled all tasks via main engine")
                    stopExecution()
                }
                override fun error(code: String, message: String?, details: Any?) {
                    stopExecution()
                }
                override fun notImplemented() {
                    stopExecution()
                }
            })
            return
        }

        mainHandler.post {
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)

                val engine = FlutterEngine(applicationContext)
                backgroundEngine = engine
                GeneratedPluginRegistrant.registerWith(engine)

                val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "task_scheduler")
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "scheduleAlarm" -> {
                            val id = call.argument<Int>("taskId") ?: -1
                            val trigger = call.argument<Number>("triggerAtMillis")?.toLong() ?: 0L
                            val title = call.argument<String>("title") ?: ""
                            if (id > 0 && trigger > 0) {
                                TaskAlarmManager.scheduleExactAlarm(applicationContext, id, trigger, title)
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        }
                        "cancelAlarm" -> {
                            val id = call.argument<Int>("taskId") ?: -1
                            if (id > 0) {
                                TaskAlarmManager.cancelAlarm(applicationContext, id)
                            }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                }

                val entrypoint = DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "backgroundTaskMain"
                )
                engine.dartExecutor.executeDartEntrypoint(entrypoint)

                mainHandler.postDelayed({
                    channel.invokeMethod("rescheduleAll", null, object : MethodChannel.Result {
                        override fun success(res: Any?) {
                            Log.d(TAG, "Rescheduled all tasks via background engine: $res")
                            stopExecution()
                        }
                        override fun error(code: String, msg: String?, details: Any?) {
                            stopExecution()
                        }
                        override fun notImplemented() {
                            stopExecution()
                        }
                    })
                }, 500)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to reschedule via background engine", e)
                stopExecution()
            }
        }
    }

    private fun stopExecution() {
        mainHandler.post {
            try {
                backgroundEngine?.destroy()
                backgroundEngine = null
            } catch (e: Exception) {
                Log.e(TAG, "Error destroying background engine", e)
            }

            try {
                if (wakeLock?.isHeld == true) {
                    wakeLock?.release()
                }
                wakeLock = null
            } catch (e: Exception) {
                Log.e(TAG, "Error releasing wake lock", e)
            }

            stopForeground(true)
            stopSelf()
        }
    }

    override fun onDestroy() {
        stopExecution()
        super.onDestroy()
    }

    private fun buildForegroundNotification(taskTitle: String): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Scheduled Tasks Service",
                    NotificationManager.IMPORTANCE_LOW,
                )
            )
        }

        val tapIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingTap = PendingIntent.getActivity(
            this, 0, tapIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Errand Scheduled Task")
            .setContentText("Executing: $taskTitle")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pendingTap)
            .setOngoing(true)
            .build()
    }
}
