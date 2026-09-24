package com.errand.errand

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.util.ArrayDeque
import java.util.Locale

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
        // High constant far outside task-row-id range so task notifications
        // (keyed by task id) can never overwrite the foreground notification.
        private const val NOTIFICATION_ID = 2_000_000_007
        private val MAIN_ENGINE_TIMEOUT_MS = 30_000L
        private val BACKGROUND_ENGINE_TIMEOUT_MS = 12 * 60 * 1000L
        private const val TASK_WAKELOCK_TIMEOUT_MS = (10 * 60 * 1000L) + 60_000L // 10 min task timeout + 60s margin = 11 minutes

        const val ACTION_EXECUTE_TASK = "com.errand.ACTION_EXECUTE_TASK"
        const val ACTION_RESCHEDULE_ALL = "com.errand.ACTION_RESCHEDULE_ALL"

        fun startForTask(context: Context, taskId: Int, taskTitle: String) {
            val intent = Intent(context, TaskExecutionService::class.java).apply {
                action = ACTION_EXECUTE_TASK
                putExtra(TaskAlarmManager.EXTRA_TASK_ID, taskId)
                putExtra(TaskAlarmManager.EXTRA_TASK_TITLE, taskTitle)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 12+ background-start restriction (or dead process):
                // nothing further we can do here; the alarm is logged below.
                Log.e(TAG, "Failed to start TaskExecutionService for task $taskId", e)
            }
        }

        fun startForReschedule(context: Context) {
            val intent = Intent(context, TaskExecutionService::class.java).apply {
                action = ACTION_RESCHEDULE_ALL
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start TaskExecutionService for reschedule", e)
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
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        lastStartId = startId
        val action = intent.action ?: ""
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

            // Renew wake lock for this specific task. A re-acquire on an
            // already-held non-reference-counted lock does not reliably
            // extend its timeout, so release first when held.
            try {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                if (wakeLock == null) {
                    wakeLock = powerManager.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        "errand:TaskExecutionWakeLock"
                    ).apply {
                        setReferenceCounted(false)
                    }
                }
                try {
                    if (wakeLock?.isHeld == true) wakeLock?.release()
                } catch (_: Exception) {}
                wakeLock?.acquire(TASK_WAKELOCK_TIMEOUT_MS)
            } catch (e: Exception) {
                Log.e(TAG, "Error acquiring wake lock for queued task", e)
            }

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

    private fun dispatchToMainEngine(
        request: ServiceRequest,
        mainChannel: MethodChannel
    ) {
        val methodName =
            if (request.action == ACTION_EXECUTE_TASK) "executeTask"
            else "rescheduleAll"

        val methodArgs =
            if (request.action == ACTION_EXECUTE_TASK) {
                mapOf("taskId" to request.taskId)
            } else {
                null
            }

        Log.d(TAG, "Dispatching $methodName to active MainActivity engine")

        var completed = false

        val timeoutRunnable = Runnable {
            if (completed) return@Runnable

            completed = true

            Log.w(
                TAG,
                "$methodName timed out on main engine, falling back to background engine"
            )

            dispatchToBackgroundEngine(request)
        }

        mainHandler.postDelayed(timeoutRunnable, MAIN_ENGINE_TIMEOUT_MS)

        mainChannel.invokeMethod(
            methodName,
            methodArgs,
            object : MethodChannel.Result {

                override fun success(result: Any?) {
                    if (completed) return
                    completed = true

                    mainHandler.removeCallbacks(timeoutRunnable)

                    Log.d(TAG, "$methodName completed on main engine: $result")
                    processNextRequest()
                }

                override fun error(
                    code: String,
                    message: String?,
                    details: Any?
                ) {
                    if (completed) return
                    completed = true

                    mainHandler.removeCallbacks(timeoutRunnable)

                    Log.e(
                        TAG,
                        "$methodName failed on main engine: $code: $message"
                    )

                    // Fall through to the background engine: the failure may be
                    // transient (e.g. Dart-side DB contention). The task claim
                    // guard makes a duplicate run safe.
                    dispatchToBackgroundEngine(request)
                }

                override fun notImplemented() {
                    if (completed) return
                    completed = true

                    mainHandler.removeCallbacks(timeoutRunnable)

                    Log.w(
                        TAG,
                        "$methodName not implemented on main engine, " +
                            "falling back to background engine"
                    )

                    dispatchToBackgroundEngine(request)
                }
            }
        )
    }

    private fun dispatchToBackgroundEngine(request: ServiceRequest) {
        ensureBackgroundEngine { engine ->
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "task_scheduler")
            val methodName = if (request.action == ACTION_EXECUTE_TASK) "executeTask" else "rescheduleAll"
            val methodArgs = if (request.action == ACTION_EXECUTE_TASK) mapOf("taskId" to request.taskId) else null

            waitForEngineReady {
                Log.d(TAG, "Invoking $methodName on background engine (taskId: ${request.taskId})")
                var completed = false
                // Watchdog: Dart caps runs at 10 min, so silence beyond 12 min
                // means the engine wedged. Advance the queue instead of
                // stalling forever; the completed flag prevents double-advance
                // if Dart responds late.
                val watchdog = Runnable {
                    if (completed) return@Runnable
                    completed = true
                    Log.w(TAG, "Background $methodName timed out; advancing queue")
                    processNextRequest()
                }
                mainHandler.postDelayed(watchdog, BACKGROUND_ENGINE_TIMEOUT_MS)
                channel.invokeMethod(methodName, methodArgs, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (completed) return
                        completed = true
                        mainHandler.removeCallbacks(watchdog)
                        Log.d(TAG, "Background $methodName completed: $result")
                        processNextRequest()
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        if (completed) return
                        completed = true
                        mainHandler.removeCallbacks(watchdog)
                        Log.e(TAG, "Background $methodName failed: $code: $message")
                        processNextRequest()
                    }

                    override fun notImplemented() {
                        if (completed) return
                        completed = true
                        mainHandler.removeCallbacks(watchdog)
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
                        val scheduled = TaskAlarmManager.scheduleExactAlarm(applicationContext, id, trigger, title)
                        result.success(scheduled)
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
                    val isSuccess = call.argument<Boolean>("isSuccess")
                    val ok = NotificationHelper.showNotification(applicationContext, id, title, body, channelId, channelName, isSuccess)
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

        setupLocationChannel(engine)
        setupIntentChannel(engine)
    }

    private fun setupLocationChannel(engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "location")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> {
                    val fine = ContextCompat.checkSelfPermission(
                        this, Manifest.permission.ACCESS_FINE_LOCATION
                    ) == PackageManager.PERMISSION_GRANTED
                    val coarse = ContextCompat.checkSelfPermission(
                        this, Manifest.permission.ACCESS_COARSE_LOCATION
                    ) == PackageManager.PERMISSION_GRANTED
                    result.success(fine || coarse)
                }
                "requestPermission" -> {
                    // Headless background service cannot show interactive permission dialogs
                    result.success(false)
                }
                "getLocation" -> {
                    val fine = ContextCompat.checkSelfPermission(
                        this, Manifest.permission.ACCESS_FINE_LOCATION
                    ) == PackageManager.PERMISSION_GRANTED
                    val coarse = ContextCompat.checkSelfPermission(
                        this, Manifest.permission.ACCESS_COARSE_LOCATION
                    ) == PackageManager.PERMISSION_GRANTED

                    if (!fine && !coarse) {
                        result.error("PERMISSION_DENIED", "Location permission is not granted.", null)
                        return@setMethodCallHandler
                    }

                    val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                    if (lm == null) {
                        result.error("LOCATION_UNAVAILABLE", "LocationManager service is unavailable", null)
                        return@setMethodCallHandler
                    }

                    var bestLocation: Location? = null
                    try {
                        val gpsLoc = lm.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                        if (gpsLoc != null) bestLocation = gpsLoc
                    } catch (_: SecurityException) {}
                    try {
                        val netLoc = lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
                        if (netLoc != null) {
                            if (bestLocation == null || netLoc.time > bestLocation.time ||
                                (netLoc.hasAccuracy() && bestLocation.hasAccuracy() && netLoc.accuracy < bestLocation.accuracy)) {
                                bestLocation = netLoc
                            }
                        }
                    } catch (_: SecurityException) {}

                    val location = bestLocation
                    if (location == null) {
                        result.error("LOCATION_UNAVAILABLE", "No cached location fix available.", null)
                        return@setMethodCallHandler
                    }

                    // Geocoder does network I/O: bound it so a hung lookup
                    // cannot leak a thread or stall the result forever.
                    val geocodeExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
                    try {
                        val geocodeFuture = geocodeExecutor.submit<Map<String, Any?>> {
                            reverseGeocode(location)
                        }
                        val addressMap = try {
                            geocodeFuture.get(8, java.util.concurrent.TimeUnit.SECONDS)
                        } catch (_: Exception) {
                            geocodeFuture.cancel(true)
                            emptyMap<String, Any?>()
                        }
                        val data = mapOf(
                            "latitude" to location.latitude,
                            "longitude" to location.longitude,
                            "accuracy" to location.accuracy.toDouble(),
                            "altitude" to location.altitude,
                            "speed" to location.speed.toDouble(),
                            "bearing" to location.bearing.toDouble(),
                            "timestamp" to location.time,
                            "provider" to (location.provider ?: "unknown"),
                            "address" to addressMap
                        )
                        mainHandler.post {
                            try {
                                result.success(data)
                            } catch (_: Exception) {}
                        }
                    } finally {
                        geocodeExecutor.shutdownNow()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setupIntentChannel(engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "intent")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "launch" -> {
                    try {
                        val action = call.argument<String>("action") ?: ""
                        val androidAction = call.argument<String>("androidAction")
                        val data = call.argument<String>("data")
                        val pkg = call.argument<String>("package")
                        val type = call.argument<String>("type")
                        val extras = call.argument<Map<String, Any?>>("extras")

                        val isBroadcast = (androidAction != null && !isActivityAction(androidAction))

                        if (!isBroadcast) {
                            result.error(
                                "BAL_BLOCKED",
                                "Activity launch ($action / $androidAction) is prohibited from headless background execution (Android BAL restrictions). Only explicit broadcasts and cached location are allowed.",
                                null
                            )
                            return@setMethodCallHandler
                        }

                        val intent = Intent(androidAction ?: Intent.ACTION_DEFAULT).apply {
                            val uri = data?.let { Uri.parse(it) }
                            if (uri != null && type != null) {
                                setDataAndType(uri, type)
                            } else if (uri != null) {
                                this.data = uri
                            } else if (type != null) {
                                this.type = type
                            }
                            pkg?.let { this.`package` = it }
                            extras?.forEach { (k, v) -> putExtraValue(this, k, v) }
                        }

                        sendBroadcast(intent)
                        result.success("broadcast_sent")
                    } catch (e: Exception) {
                        result.error("INTENT_ERR", e.message, null)
                    }
                }
                "canResolve" -> {
                    try {
                        val action = call.argument<String>("action") ?: Intent.ACTION_VIEW
                        val data = call.argument<String>("data")
                        val pkg = call.argument<String>("package")
                        val type = call.argument<String>("type")

                        val intent = Intent(action).apply {
                            val uri = data?.let { Uri.parse(it) }
                            if (uri != null && type != null) {
                                setDataAndType(uri, type)
                            } else if (uri != null) {
                                this.data = uri
                            } else if (type != null) {
                                this.type = type
                            }
                            pkg?.let { this.`package` = it }
                        }
                        val resolved = packageManager.queryBroadcastReceivers(intent, 0).isNotEmpty() ||
                            intent.resolveActivity(packageManager) != null
                        result.success(resolved)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "getInstalledApps" -> {
                    try {
                        val launcherIntent = Intent(Intent.ACTION_MAIN).apply {
                            addCategory(Intent.CATEGORY_LAUNCHER)
                        }
                        val resolveInfos = packageManager.queryIntentActivities(launcherIntent, 0)
                        val apps = resolveInfos.mapNotNull { ri ->
                            val p = ri.activityInfo?.packageName ?: return@mapNotNull null
                            val l = try {
                                ri.loadLabel(packageManager)?.toString() ?: p
                            } catch (_: Exception) {
                                p
                            }
                            mapOf("package" to p, "label" to l)
                        }.distinctBy { it["package"] }
                        result.success(apps)
                    } catch (e: Exception) {
                        result.error("APPS_ERR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isActivityAction(action: String): Boolean {
        return action.startsWith("android.settings.") ||
            action == Intent.ACTION_VIEW ||
            action == Intent.ACTION_MAIN ||
            action == Intent.ACTION_DIAL ||
            action == Intent.ACTION_CALL ||
            action == Intent.ACTION_SEND ||
            action == Intent.ACTION_SENDTO ||
            action == Intent.ACTION_WEB_SEARCH ||
            action.startsWith("android.intent.action.SET_") ||
            action.startsWith("android.intent.action.SHOW_") ||
            action.startsWith("android.intent.action.DISMISS_") ||
            action.startsWith("android.intent.action.SNOOZE_") ||
            action == Intent.ACTION_INSERT ||
            action == Intent.ACTION_EDIT ||
            action.startsWith("android.media.action.")
    }

    private fun reverseGeocode(location: Location): Map<String, Any?> {
        val geocoder = Geocoder(this, Locale.getDefault())
        return try {
            @Suppress("DEPRECATION")
            val addresses = geocoder.getFromLocation(location.latitude, location.longitude, 1)
            if (!addresses.isNullOrEmpty()) {
                val addr = addresses[0]
                mapOf(
                    "city" to (addr.locality ?: addr.subAdminArea ?: ""),
                    "state" to (addr.adminArea ?: ""),
                    "country" to (addr.countryName ?: ""),
                    "countryCode" to (addr.countryCode ?: ""),
                    "postalCode" to (addr.postalCode ?: ""),
                    "street" to (addr.thoroughfare ?: ""),
                    "formatted" to (if (addr.maxAddressLineIndex >= 0) addr.getAddressLine(0) else "")
                )
            } else {
                emptyMap()
            }
        } catch (e: Exception) {
            mapOf("error" to (e.message ?: "Geocoding failed"))
        }
    }

    private fun putExtraValue(intent: Intent, key: String, value: Any?) {
        when (value) {
            null -> return
            is Boolean -> intent.putExtra(key, value)
            is Byte -> intent.putExtra(key, value)
            is Short -> intent.putExtra(key, value)
            is Int -> intent.putExtra(key, value)
            is Long -> intent.putExtra(key, value)
            is Float -> intent.putExtra(key, value)
            is Double -> intent.putExtra(key, value)
            is String -> intent.putExtra(key, value)
            is CharSequence -> intent.putExtra(key, value)
            is List<*> -> {
                if (value.all { it is String }) {
                    intent.putStringArrayListExtra(
                        key,
                        ArrayList(value.filterIsInstance<String>())
                    )
                } else if (value.all { it is Number }) {
                    intent.putIntegerArrayListExtra(
                        key,
                        ArrayList(value.filterIsInstance<Number>().map { it.toInt() })
                    )
                }
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
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wake lock", e)
        }
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
