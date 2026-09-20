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
import java.util.ArrayDeque

/**
 * Foreground service that guarantees process survival and CPU wake-lock while background
 * tasks execute.
 *
 * Concurrency & Reliability Architecture:
 * - Queues concurrent onStartCommand alarm requests and processes them sequentially.
 * - Reuses a single background FlutterEngine instance across queued runs.
 * - Waits for Dart to signal readiness (onEngineReady) with retry polling fallback to eliminate fixed-sleep race conditions.
 * - Only stops the service with stopSelf(lastStartId) once all queued tasks have finished.
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

    private data class ServiceRequest(
        val action: String,
        val taskId: Int,
        val taskTitle: String,
        val startId: Int
    )

    private val requestQueue = ArrayDeque<ServiceRequest>()
    private var isProcessing = false
    private var lastStartId = -1

    private var wakeLock: PowerManager.WakeLock? = null
    private var backgroundEngine: FlutterEngine? = null
    private var isEngineReady = false
    private val engineReadyCallbacks = ArrayList<() -> Unit>()
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
        lastStartId = startId
        val action = intent?.action ?: ""
        val taskId = intent?.getIntExtra(TaskAlarmManager.EXTRA_TASK_ID, -1) ?: -1
        val title = intent?.getStringExtra(TaskAlarmManager.EXTRA_TASK_TITLE) ?: "Task in progress"

        startForeground(NOTIFICATION_ID, buildForegroundNotification(title))

        val request = ServiceRequest(action, taskId, title, startId)
        requestQueue.addLast(request)

        if (!isProcessing) {
            processNextRequest()
        }

        return START_NOT_STICKY
    }

    private fun processNextRequest() {
        mainHandler.post {
            if (requestQueue.isEmpty()) {
                Log.d(TAG, "Request queue empty; shutting down service with startId $lastStartId")
                isProcessing = false
                destroyBackgroundEngine()

                try {
                    if (wakeLock?.isHeld == true) {
                        wakeLock?.release()
                    }
                    wakeLock = null
                } catch (e: Exception) {
                    Log.e(TAG, "Error releasing wake lock", e)
                }

                stopForeground(true)
                stopSelf(lastStartId)
                return@post
            }

            isProcessing = true
            val request = requestQueue.removeFirst()

            // Update foreground notification with current task title
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.notify(NOTIFICATION_ID, buildForegroundNotification(request.taskTitle))

            // Check if active foreground UI engine is available
            val mainChannel = MainActivity.schedulerChannel
            if (mainChannel != null) {
                dispatchToMainEngine(request, mainChannel)
            } else {
                dispatchToBackgroundEngine(request)
            }
        }
    }

    private fun dispatchToMainEngine(request: ServiceRequest, mainChannel: MethodChannel) {
        val methodName = if (request.action == ACTION_EXECUTE_TASK) "executeTask" else "rescheduleAll"
        val methodArgs = if (request.action == ACTION_EXECUTE_TASK) mapOf("taskId" to request.taskId) else null

        Log.d(TAG, "Dispatching $methodName to active MainActivity engine")
        mainChannel.invokeMethod(methodName, methodArgs, object : MethodChannel.Result {
            override fun success(result: Any?) {
                Log.d(TAG, "$methodName completed on main engine: $result")
                processNextRequest()
            }

            override fun error(code: String, message: String?, details: Any?) {
                Log.e(TAG, "$methodName failed on main engine: $code: $message")
                processNextRequest()
            }

            override fun notImplemented() {
                Log.w(TAG, "$methodName not implemented on main engine, falling back to background engine")
                dispatchToBackgroundEngine(request)
            }
        })
    }

    private fun dispatchToBackgroundEngine(request: ServiceRequest) {
        ensureBackgroundEngine { engine ->
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "task_scheduler")
            val methodName = if (request.action == ACTION_EXECUTE_TASK) "executeTask" else "rescheduleAll"
            val methodArgs = if (request.action == ACTION_EXECUTE_TASK) mapOf("taskId" to request.taskId) else null

            waitForEngineReady {
                Log.d(TAG, "Invoking $methodName on background engine (taskId: ${request.taskId})")
                channel.invokeMethod(methodName, methodArgs, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        Log.d(TAG, "Background $methodName completed: $result")
                        processNextRequest()
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        Log.e(TAG, "Background $methodName failed: $code: $message")
                        processNextRequest()
                    }

                    override fun notImplemented() {
                        Log.e(TAG, "Background $methodName not implemented in backgroundTaskMain")
                        processNextRequest()
                    }
                })
            }
        }
    }

    private fun ensureBackgroundEngine(onReady: (FlutterEngine) -> Unit) {
        val existing = backgroundEngine
        if (existing != null) {
            onReady(existing)
            return
        }

        try {
            Log.d(TAG, "Initializing new background FlutterEngine")
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val engine = FlutterEngine(applicationContext)
            backgroundEngine = engine
            GeneratedPluginRegistrant.registerWith(engine)

            setupEngineChannels(engine)

            val entrypoint = DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "backgroundTaskMain"
            )
            engine.dartExecutor.executeDartEntrypoint(entrypoint)
            onReady(engine)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize background Flutter engine", e)
            processNextRequest()
        }
    }

    private fun waitForEngineReady(onReady: () -> Unit) {
        if (isEngineReady) {
            onReady()
            return
        }

        engineReadyCallbacks.add(onReady)

        // Polling fallback in case Dart does not signal or onEngineReady is delayed
        var attempts = 0
        fun poll() {
            if (isEngineReady) return
            attempts++
            if (attempts >= 10) { // 5.0 seconds maximum fallback timeout
                Log.w(TAG, "Timed out waiting for Dart onEngineReady; proceeding with invocation attempt")
                onEngineSignaledReady()
            } else {
                mainHandler.postDelayed({ poll() }, 500)
            }
        }
        mainHandler.postDelayed({ poll() }, 500)
    }

    private fun onEngineSignaledReady() {
        if (isEngineReady) return
        isEngineReady = true
        val callbacks = ArrayList(engineReadyCallbacks)
        engineReadyCallbacks.clear()
        for (cb in callbacks) {
            try {
                cb()
            } catch (e: Exception) {
                Log.e(TAG, "Error executing engineReady callback", e)
            }
        }
    }

    private fun setupEngineChannels(engine: FlutterEngine) {
        val schedulerChannel = MethodChannel(engine.dartExecutor.binaryMessenger, "task_scheduler")
        schedulerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "onEngineReady" -> {
                    Log.d(TAG, "Dart backgroundTaskMain signaled onEngineReady")
                    onEngineSignaledReady()
                    result.success(true)
                }
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
                "showNotification" -> {
                    val id = call.argument<Int>("id") ?: 1000
                    val title = call.argument<String>("title") ?: "Errand Task"
                    val body = call.argument<String>("body") ?: ""
                    val channelId = call.argument<String>("channelId") ?: "scheduled_tasks"
                    val channelName = call.argument<String>("channelName") ?: "Scheduled Tasks"
                    val ok = NotificationHelper.showNotification(applicationContext, id, title, body, channelId, channelName)
                    result.success(ok)
                }
                "cancelNotification" -> {
                    val id = call.argument<Int>("id") ?: -1
                    val ok = if (id > 0) NotificationHelper.cancelNotification(applicationContext, id) else false
                    result.success(ok)
                }
                else -> result.notImplemented()
            }
        }

        val appInfoChannel = MethodChannel(engine.dartExecutor.binaryMessenger, "app_info")
        appInfoChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "showNotification" -> {
                    val id = call.argument<Int>("id") ?: 1000
                    val title = call.argument<String>("title") ?: "Errand Task"
                    val body = call.argument<String>("body") ?: ""
                    val channelId = call.argument<String>("channelId") ?: "scheduled_tasks"
                    val channelName = call.argument<String>("channelName") ?: "Scheduled Tasks"
                    val ok = NotificationHelper.showNotification(applicationContext, id, title, body, channelId, channelName)
                    result.success(ok)
                }
                "cancelNotification" -> {
                    val id = call.argument<Int>("id") ?: -1
                    val ok = if (id > 0) NotificationHelper.cancelNotification(applicationContext, id) else false
                    result.success(ok)
                }
                "hasNotificationPermission" -> {
                    result.success(NotificationHelper.hasPermission(applicationContext))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun destroyBackgroundEngine() {
        try {
            isEngineReady = false
            engineReadyCallbacks.clear()
            backgroundEngine?.destroy()
            backgroundEngine = null
        } catch (e: Exception) {
            Log.e(TAG, "Error destroying background engine", e)
        }
    }

    override fun onDestroy() {
        destroyBackgroundEngine()
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
            wakeLock = null
        } catch (_) {}
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
            ?: Intent(this, MainActivity::class.java)
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

        val iconRes = if (applicationInfo.icon != 0) applicationInfo.icon else android.R.drawable.ic_dialog_info

        return builder
            .setContentTitle("Errand Scheduled Task")
            .setContentText("Executing: $taskTitle")
            .setSmallIcon(iconRes)
            .setContentIntent(pendingTap)
            .setOngoing(true)
            .build()
    }
}
