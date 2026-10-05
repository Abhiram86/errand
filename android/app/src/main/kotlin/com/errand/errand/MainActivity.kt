package com.errand.errand

import android.Manifest
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.ActivityManager
import android.app.ActivityOptions
import android.app.ApplicationExitInfo
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import java.util.Locale
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

class MainActivity : FlutterActivity() {

    companion object {
        var schedulerChannel: MethodChannel? = null
        @Volatile
        var isResumed: Boolean = false
    }

    private val geocodeExecutor = Executors.newCachedThreadPool()

    /**
     * Monotonic request codes for activity-launch PendingIntents.
     *
     * PendingIntent equality ignores extras, so a constant request code makes
     * every launch with the same action+data resolve to one pending intent.
     */
    private val launchRequestCodes = java.util.concurrent.atomic.AtomicInteger(0)

    /** In-flight single-shot location request, torn down in [onDestroy]. */
    private var pendingLocationListener: LocationListener? = null
    private var pendingLocationRunnable: Runnable? = null
    private val locationHandler = Handler(Looper.getMainLooper())

    private fun clearPendingLocationRequest() {
        pendingLocationListener = null
        pendingLocationRunnable?.let { locationHandler.removeCallbacks(it) }
        pendingLocationRunnable = null
    }

    private val STORAGE_CHANNEL = "storage_access"
    private val INTENT_CHANNEL = "intent"
    private val A11Y_CHANNEL = "a11y"
    private val APP_INFO_CHANNEL = "app_info"
    private val LOCATION_CHANNEL = "location"
    private val WIDGET_CHANNEL = "widget"
    private val SCHEDULER_CHANNEL = "task_scheduler"

    private var widgetChannel: MethodChannel? = null
    private var pdfPlugin: PdfReaderPlugin? = null
    private var pendingVoicePrompt: Boolean = false
    private var pendingTaskNotification: Map<String, Any>? = null
    private var initialNotificationRoute = false

    /**
     * Fire-and-forget: needed to SHOW the foreground-service notification on
     * API 33+. The service itself runs either way — without the grant the
     * notification is just hidden.
     */
    private fun requestPostNotificationsPermission() {
        if (Build.VERSION.SDK_INT >= 33) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_CODE
            )
        }
    }

    /**
     * Resolves [rawPath] and enforces that it stays inside an allowed root.
     *
     * The path is attacker-influenced: `open_file` and `installApk` both take a
     * string that originates from the LLM, which in turn may have read it from a
     * prompt-injected web page. Handing such a path to FileProvider and granting
     * FLAG_GRANT_READ_URI_PERMISSION would let a tool result exfiltrate any file
     * this process can read, so containment is checked here rather than trusting
     * the caller. Canonicalization resolves `..` and symlinks before the check.
     *
     * @return the canonical File, or null when the path escapes every allowed root.
     */

    /** Streams [file] through SHA-256, or null if it cannot be read. */
    private fun sha256Of(file: File): String? = try {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        digest.digest().joinToString("") { "%02x".format(it) }
    } catch (e: Exception) {
        Log.e("ErrandInstall", "SHA-256 failed for ${file.path}", e)
        null
    }

    /**
     * `versionCode` of an installed package, or null when unavailable.
     * Uses [PackageInfoFlags] on API 33+ to avoid the deprecated flags form.
     */
    private fun apkVersionCodeOf(pkg: String): Long? = try {
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(pkg, 0)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    } catch (e: Exception) {
        null
    }

    /**
     * `versionCode` of a candidate APK file, or null when unreadable/not an APK.
     *
     * Parsed via [PackageManager.getPackageArchiveInfo], which only reads the
     * manifest — it does not install or execute anything.
     */
    private fun apkVersionCodeOf(file: File): Long? = try {
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageArchiveInfo(
                file.absolutePath, PackageManager.PackageInfoFlags.of(0)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageArchiveInfo(file.absolutePath, 0)
        } ?: return null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    } catch (e: Exception) {
        Log.e("ErrandInstall", "Could not read archive info for ${file.path}", e)
        null
    }

    private fun taskNotificationInitialRoute(incomingIntent: Intent?): String? {
        if (incomingIntent == null) return null
        val taskId = incomingIntent.getIntExtra("task_id", -1)
        val route = incomingIntent.getStringExtra("route")
        val openUnread = incomingIntent.getBooleanExtra("open_unread_tasks", false)
        if (taskId <= 0 && route != "manage_tasks_unread" && !openUnread) {
            return null
        }
        // Omit taskId unless valid: Dart treats a missing param as null,
        // while "-1" would skew the same-task tap dedup.
        val query = if (taskId > 0) "?taskId=$taskId" else ""
        return "/manage_tasks_unread$query"
    }

    private fun tryOpenOemAutostartSettings(): Boolean {
        val oemIntents = listOf(
            // Xiaomi / MIUI / HyperOS
            Intent().setComponent(ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")),
            // Huawei
            Intent().setComponent(ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity")),
            Intent().setComponent(ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity")),
            // Oppo / Realme (ColorOS)
            Intent().setComponent(ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity")),
            Intent().setComponent(ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity")),
            Intent().setComponent(ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity")),
            // Vivo
            Intent().setComponent(ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity")),
            Intent().setComponent(ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity")),
            // Samsung
            Intent().setComponent(ComponentName("com.samsung.android.lool", "com.samsung.android.sm.ui.battery.BatteryActivity"))
        )

        for (targetIntent in oemIntents) {
            try {
                targetIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                if (packageManager.resolveActivity(targetIntent, PackageManager.MATCH_DEFAULT_ONLY) != null) {
                    startActivity(targetIntent)
                    return true
                }
            } catch (_: Exception) {}
        }
        return false
    }

    override fun getInitialRoute(): String {
        val route = taskNotificationInitialRoute(intent)
        initialNotificationRoute = route != null
        return route ?: "/"
    }

    private fun logP10(message: String) {
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            Log.d("P10", message)
        }
    }

    private fun checkVoicePromptIntent(incomingIntent: Intent?) {
        if (incomingIntent == null) return
        val isVoiceAction = incomingIntent.action == VoiceWidgetProvider.ACTION_VOICE_PROMPT ||
                incomingIntent.getBooleanExtra(VoiceWidgetProvider.EXTRA_AUTO_VOICE, false)
        if (isVoiceAction) {
            // Always latch the pending flag so a tap is never lost when the
            // Dart listener isn't attached yet; the live stream (below) is
            // deduped Dart-side by the listening/busy guard.
            pendingVoicePrompt = true
            try {
                widgetChannel?.invokeMethod("onVoicePrompt", null)
            } catch (_: Exception) {}
        }
    }

    private fun checkTaskNotificationIntent(incomingIntent: Intent?) {
        if (incomingIntent == null) return
        val taskId = incomingIntent.getIntExtra("task_id", -1)
        val route = incomingIntent.getStringExtra("route")
        val openUnread = incomingIntent.getBooleanExtra("open_unread_tasks", false)
        if (taskId > 0 || route == "manage_tasks_unread" || openUnread) {
            logP10("notification_tap taskId=$taskId route=$route")
            val data = mapOf(
                "taskId" to taskId,
                "route" to (route ?: "manage_tasks_unread"),
                "initialTab" to 1
            )
            pendingTaskNotification = data
            try {
                schedulerChannel?.invokeMethod("onTaskNotificationClicked", data)
            } catch (_: Exception) {}
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        checkVoicePromptIntent(intent)
        checkTaskNotificationIntent(intent)
    }

    private val MIC_PERMISSION_CODE = 9001
    private var micPermissionResult: MethodChannel.Result? = null

    private val LOCATION_PERMISSION_CODE = 9002
    private var locationPermissionResult: MethodChannel.Result? = null

    // Dedicated code: the notification permission request must not reuse
    // LOCATION_PERMISSION_CODE, or its grant/deny would resolve a pending
    // location result with the wrong answer.
    private val NOTIFICATION_PERMISSION_CODE = 9003

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
                } else {
                    throw IllegalArgumentException(
                        "Unsupported list extra '$key': only string or integer lists are supported"
                    )
                }
            }
            else -> {
                throw IllegalArgumentException(
                    "Unsupported extra '$key' value type: ${value.javaClass.name}"
                )
            }
        }
    }

    /**
     * Debug-only snapshot of the fully-built intent immediately before launch.
     * This is intentionally kept at the native boundary so it shows the actual
     * action, package/component, flags, and runtime types delivered to Android.
    */
    private fun logIntent(
        label: String,
        intent: Intent,
        launchContext: Context? = null,
        isA11y: Boolean = false,
        transport: String? = null
    ) {
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0) return

        Log.d("ErrandIntent", "========== $label ==========")
        Log.d("ErrandIntent", "action      = ${intent.action}")
        Log.d("ErrandIntent", "data        = ${intent.data}")
        Log.d("ErrandIntent", "type        = ${intent.type}")
        Log.d("ErrandIntent", "package     = ${intent.`package`}")
        Log.d("ErrandIntent", "component   = ${intent.component}")
        Log.d("ErrandIntent", "categories  = ${intent.categories}")
        Log.d("ErrandIntent", "flags       = 0x${intent.flags.toString(16)}")

        val extras = intent.extras
        if (extras == null) {
            Log.d("ErrandIntent", "extras      = null")
        } else {
            Log.d("ErrandIntent", "extras:")
            for (key in extras.keySet()) {
                val value = extras.get(key)
                Log.d(
                    "ErrandIntent",
                    "  $key = $value [${value?.javaClass?.name}]"
                )
            }
        }

        Log.d("ErrandIntent", "resolved    = ${intent.resolveActivity(packageManager)}")
        if (launchContext != null) {
            Log.d(
                "ErrandIntent",
                "launchContext = ${launchContext.javaClass.name}, " +
                    "accessibilityContext = $isA11y, " +
                    "androidVersion = ${Build.VERSION.SDK_INT}"
            )
        }
        if (transport != null) {
            Log.d("ErrandIntent", "transport   = $transport")
        }
        Log.d("ErrandIntent", "================================")
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MIC_PERMISSION_CODE) {
            micPermissionResult?.success(
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            )
            micPermissionResult = null
        } else if (requestCode == LOCATION_PERMISSION_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults.any { it == PackageManager.PERMISSION_GRANTED }
            locationPermissionResult?.success(granted)
            locationPermissionResult = null
        }
        // NOTIFICATION_PERMISSION_CODE is intentionally unhandled: that
        // request is fire-and-forget with no pending result to complete.
    }

    override fun onResume() {
        super.onResume()
        isResumed = true
    }

    override fun onPause() {
        isResumed = false
        super.onPause()
    }

    override fun onDestroy() {
        isResumed = false
        // Deliberately does NOT disable the accessibility service here. Pressing
        // Back (isFinishing) must not revoke a grant the user made in Settings;
        // that silently broke screen reading until the user re-enabled it, and it
        // made the explicit a11y/disable channel method below redundant. Use the
        // Settings screen or the disable channel method to turn it off.

        // Release any in-flight location request: the LocationManager listener
        // and the 8s timeout outlived the activity otherwise, keeping the
        // system binding alive and replying to a dead engine.
        try {
            pendingLocationListener?.let { l ->
                (getSystemService(Context.LOCATION_SERVICE) as? LocationManager)
                    ?.removeUpdates(l)
            }
        } catch (_: Exception) {}
        clearPendingLocationRequest()

        widgetChannel?.setMethodCallHandler(null)
        widgetChannel = null
        schedulerChannel?.setMethodCallHandler(null)
        schedulerChannel = null
        pdfPlugin?.closeAll()
        pdfPlugin = null
        try {
            geocodeExecutor.shutdownNow()
        } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        logP10("configureFlutterEngine_start")
        super.configureFlutterEngine(flutterEngine)

        // ---- Task Scheduler Channel (P9) ----
        val scheduler = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCHEDULER_CHANNEL)
        schedulerChannel = scheduler
        logP10("scheduler_channel_installed")
        scheduler.setMethodCallHandler { call, result ->
            when (call.method) {
                "scheduleAlarm" -> {
                    val taskId = call.argument<Int>("taskId") ?: -1
                    val trigger = call.argument<Number>("triggerAtMillis")?.toLong() ?: 0L
                    val title = call.argument<String>("title") ?: "Scheduled Task"
                    if (taskId > 0 && trigger > 0) {
                        val ok = TaskAlarmManager.scheduleExactAlarm(this, taskId, trigger, title)
                        result.success(ok)
                    } else {
                        result.success(false)
                    }
                }
                "cancelAlarm" -> {
                    val taskId = call.argument<Int>("taskId") ?: -1
                    if (taskId > 0) {
                        TaskAlarmManager.cancelAlarm(this, taskId)
                    }
                    result.success(true)
                }
                // R2-H6: JobScheduler fallback for when exact alarms are
                // unavailable. Mirrors scheduleAlarm; returns true only when
                // the job was accepted.
                "scheduleJob" -> {
                    val taskId = call.argument<Int>("taskId") ?: -1
                    val trigger = call.argument<Number>("triggerAtMillis")?.toLong() ?: 0L
                    val title = call.argument<String>("title") ?: "Scheduled Task"
                    if (taskId > 0 && trigger > 0) {
                        val ok = TaskAlarmManager.scheduleJobFallback(this, taskId, trigger, title)
                        result.success(ok)
                    } else {
                        result.success(false)
                    }
                }
                "canScheduleExactAlarms" -> {
                    result.success(TaskAlarmManager.canScheduleExactAlarms(this))
                }
                "openExactAlarmSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        try {
                            val intent = Intent(android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                                data = android.net.Uri.parse("package:$packageName")
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e("MainActivity", "Failed to open exact alarm settings", e)
                            result.success(false)
                        }
                    } else {
                        result.success(false)
                    }
                }
                "isIgnoringBatteryOptimizations" -> {
                    try {
                        val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    } catch (e: Exception) {
                        Log.e("MainActivity", "Battery exemption query failed", e)
                        result.success(false)
                    }
                }
                "requestBatteryExemption" -> {
                    // Full flavor declares REQUEST_IGNORE_BATTERY_OPTIMIZATIONS and can show the direct dialog.
                    // Lite flavor does not declare it; on lite, launching ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                    // silently finishes without throwing or displaying any UI.
                    val hasDirectPermission = try {
                        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            packageManager.getPackageInfo(
                                packageName,
                                PackageManager.PackageInfoFlags.of(PackageManager.GET_PERMISSIONS.toLong())
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS)
                        }
                        info.requestedPermissions?.contains("android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS") == true
                    } catch (_: Exception) {
                        false
                    }

                    if (hasDirectPermission) {
                        try {
                            val intent = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                            ).apply {
                                data = android.net.Uri.parse("package:$packageName")
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(intent)
                            result.success(true)
                            return@setMethodCallHandler
                        } catch (e: Exception) {
                            Log.w("MainActivity", "Direct battery exemption dialog failed, falling back to app details", e)
                        }
                    }

                    try {
                        // Primary fallback (and default for lite flavor): open Errand's App Info page
                        // where the user can configure Battery -> Unrestricted (or "No restrictions" on Xiaomi/Oppo).
                        val appDetailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = android.net.Uri.parse("package:$packageName")
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(appDetailsIntent)
                        result.success(true)
                    } catch (e2: Exception) {
                        try {
                            // Last resort: open the system battery optimization list
                            val batteryListIntent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                            startActivity(batteryListIntent)
                            result.success(true)
                        } catch (e3: Exception) {
                            Log.e("MainActivity", "Battery exemption request fallback failed", e3)
                            result.success(false)
                        }
                    }
                }
                "getPendingNotificationClick" -> {
                    logP10("pending_lookup_native_start")
                    val pending = pendingTaskNotification
                    pendingTaskNotification = null
                    logP10(
                        "pending_lookup_native_done found=${pending != null} " +
                            "taskId=${pending?.get("taskId")}"
                    )
                    result.success(pending)
                }
                "getHistoricalExitReasons" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val maxNum = call.argument<Int>("maxNum") ?: 5
                            val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                            val reasons = am?.getHistoricalProcessExitReasons(packageName, 0, maxNum) ?: emptyList()
                            val list = reasons.map { info ->
                                val reasonName = when (info.reason) {
                                    ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
                                    ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
                                    ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
                                    ApplicationExitInfo.REASON_CRASH -> "CRASH"
                                    ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
                                    ApplicationExitInfo.REASON_ANR -> "ANR"
                                    ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
                                    ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
                                    ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
                                    ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
                                    ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
                                    ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
                                    ApplicationExitInfo.REASON_OTHER -> "OTHER"
                                    14 -> "FREEZER"
                                    else -> "UNKNOWN_${info.reason}"
                                }
                                mapOf(
                                    "reason" to info.reason,
                                    "reasonName" to reasonName,
                                    "status" to info.status,
                                    "timestamp" to info.timestamp,
                                    "description" to (info.description ?: ""),
                                    "importance" to info.importance
                                )
                            }
                            result.success(list)
                        } catch (e: Exception) {
                            Log.e("MainActivity", "Failed to query historical exit reasons", e)
                            result.success(emptyList<Map<String, Any>>())
                        }
                    } else {
                        result.success(emptyList<Map<String, Any>>())
                    }
                }
                "openOemBatterySettings" -> {
                    val opened = tryOpenOemAutostartSettings()
                    result.success(opened)
                }
                else -> result.notImplemented()
            }
        }
        if (initialNotificationRoute) {
            logP10("notification_initial_route")
            initialNotificationRoute = false
        } else {
            checkTaskNotificationIntent(intent)
        }

        // ---- Storage channel (unchanged) ----
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STORAGE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        result.success(Environment.isExternalStorageManager())
                    } else {
                        result.success(true)
                    }
                }
                "requestPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION
                        ).apply {
                            data = Uri.parse("package:$packageName")
                        }
                        startActivity(intent)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // ---- Intent channel ----
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INTENT_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {

                "launch" -> {
                    try {
                        val action = call.argument<String>("action") ?: "open_url"
                        val androidAction = call.argument<String>("androidAction")
                        val data = call.argument<String>("data")
                        val pkg = call.argument<String>("package")
                        val type = call.argument<String>("type")
                        val extras = call.argument<Map<String, Any?>>("extras")

                        val intent: Intent? = when {
                            action == "open_app" -> {
                                if (pkg == null) {
                                    result.error("NO_PKG", "Missing package for open_app", null)
                                    return@setMethodCallHandler
                                }
                                packageManager.getLaunchIntentForPackage(pkg)
                            }

                            action == "open_file" || (action == "open_url" && data != null && (data.startsWith("/") || data.startsWith("file://"))) -> {
                                val rawPath = data ?: ""
                                val filePath = if (rawPath.startsWith("file://")) {
                                    Uri.parse(rawPath).path ?: rawPath.removePrefix("file://")
                                } else {
                                    rawPath
                                }
                                val file = resolveContainedFile(filePath)
                                if (file == null) {
                                    result.error(
                                        "PATH_NOT_ALLOWED",
                                        "Path is outside the allowed storage roots: $filePath",
                                        null,
                                    )
                                    return@setMethodCallHandler
                                }
                                if (!file.exists()) {
                                    result.error("FILE_NOT_FOUND", "File does not exist: ${file.absolutePath}", null)
                                    return@setMethodCallHandler
                                }

                                val authority = "${applicationContext.packageName}.fileprovider"
                                val contentUri = FileProvider.getUriForFile(this, authority, file)

                                val extension = MimeTypeMap.getFileExtensionFromUrl(contentUri.toString())
                                    .ifEmpty { file.extension }
                                    .lowercase()
                                val resolvedType = type ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: when (extension) {
                                    "mp3" -> "audio/mpeg"
                                    "wav" -> "audio/wav"
                                    "ogg", "oga" -> "audio/ogg"
                                    "m4a", "aac" -> "audio/mp4"
                                    "flac" -> "audio/flac"
                                    "mp4" -> "video/mp4"
                                    "mkv" -> "video/x-matroska"
                                    "webm" -> "video/webm"
                                    "avi" -> "video/avi"
                                    "jpg", "jpeg" -> "image/jpeg"
                                    "png" -> "image/png"
                                    "gif" -> "image/gif"
                                    "webp" -> "image/webp"
                                    "svg" -> "image/svg+xml"
                                    "pdf" -> "application/pdf"
                                    "txt" -> "text/plain"
                                    "json" -> "application/json"
                                    "html" -> "text/html"
                                    else -> null
                                }

                                // MIME allowlist (R2-C1 step 3): the `type`
                                // argument above is caller-supplied, so the
                                // final type is validated, not just the
                                // extension-derived one. Unknown or executable
                                // types fail closed instead of launching a
                                // generic handler via "*/*".
                                val typeAllowed = resolvedType != null &&
                                    (resolvedType.startsWith("audio/") ||
                                        resolvedType.startsWith("video/") ||
                                        resolvedType.startsWith("image/") ||
                                        resolvedType.startsWith("text/") ||
                                        resolvedType == "application/pdf" ||
                                        resolvedType == "application/json")
                                if (!typeAllowed) {
                                    result.error(
                                        "UNSUPPORTED_TYPE",
                                        "No viewer mapping for .$extension; refusing generic handler",
                                        null,
                                    )
                                    return@setMethodCallHandler
                                }

                                Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(contentUri, resolvedType)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    clipData = ClipData.newRawUri(null, contentUri)
                                    pkg?.let { this.`package` = it }
                                    extras?.forEach { (k, v) -> putExtraValue(this, k, v) }
                                }
                            }

                            action == "email" -> {
                                val uri = Uri.parse(data ?: "mailto:")
                                Intent(Intent.ACTION_SENDTO, uri).apply {
                                    val subject = extras?.get("subject")?.toString()
                                        ?: uri.getQueryParameter("subject")
                                    val body = extras?.get("body")?.toString()
                                        ?: uri.getQueryParameter("body")

                                    subject?.let { putExtra(Intent.EXTRA_SUBJECT, it) }
                                    body?.let { putExtra(Intent.EXTRA_TEXT, it) }
                                    pkg?.let { this.`package` = it }
                                }
                            }

                            else -> {
                                val act = when {
                                    androidAction != null -> androidAction
                                    action == "dial" || data?.startsWith("tel:") == true -> Intent.ACTION_DIAL
                                    data?.startsWith("mailto:") == true -> Intent.ACTION_SENDTO
                                    else -> Intent.ACTION_VIEW
                                }
                                Intent(act).apply {
                                    val uri = data?.let { Uri.parse(it) }
                                    if (uri != null && type != null) {
                                        setDataAndType(uri, type)
                                    } else if (uri != null) {
                                        this.data = uri
                                    } else if (type != null) {
                                        this.type = type
                                    }

                                    if (uri?.scheme?.lowercase() in listOf("http", "https")) {
                                        addCategory(Intent.CATEGORY_BROWSABLE)
                                    }
                                    pkg?.let { this.`package` = it }
                                    extras?.forEach { (k, v) ->
                                        putExtraValue(this, k, v)
                                    }
                                }
                            }
                        }

                        if (intent == null) {
                            result.error("NO_HANDLER", "Could not build intent for $action", null)
                            return@setMethodCallHandler
                        }

                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

                        // Only pre-check resolvability when explicitly pinned to a package —
                        // resolveActivity is subject to <queries> visibility and returns null
                        // for unqueried handlers even when startActivity would succeed.
                        // For implicit intents we rely on ActivityNotFoundException below.
                        val exemptFromPinnedCheck =
                            intent.action == Intent.ACTION_DELETE ||
                                intent.action == Intent.ACTION_SENDTO
                        if (pkg != null && !exemptFromPinnedCheck &&
                            intent.resolveActivity(packageManager) == null
                        ) {
                            result.error("NO_HANDLER", "No activity found for $action $data pkg=$pkg", null)
                            return@setMethodCallHandler
                        }

                        val queryIntent = Intent(intent.action).apply {
                            if (intent.data != null && intent.type != null) {
                                setDataAndType(intent.data, intent.type)
                            } else if (intent.data != null) {
                                this.data = intent.data
                            } else if (intent.type != null) {
                                this.type = intent.type
                            }
                        }
                        val handlers = if (pkg == null) {
                            packageManager.queryIntentActivities(queryIntent, PackageManager.MATCH_DEFAULT_ONLY)
                        } else {
                            emptyList()
                        }
                        val outcome = if (pkg == null && handlers.size > 1) {
                            "launched (choose app if prompted)"
                        } else if (action == "open_app" && pkg != null) {
                            val label = try {
                                val info = packageManager.getApplicationInfo(pkg, 0)
                                packageManager.getApplicationLabel(info).toString()
                            } catch (_: Exception) {
                                null
                            }
                            if (!label.isNullOrEmpty()) "launched: $label" else "launched"
                        } else {
                            "launched"
                        }

                        val a11y = ErrandAccessibilityService.instance
                        val launchContext: Context = a11y ?: this
                        val transport = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            "PendingIntent.getActivity().send()"
                        } else {
                            "Context.startActivity()"
                        }

                        logIntent("before launch", intent, launchContext, a11y != null, transport)

                        @Suppress("DEPRECATION")
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            val options = ActivityOptions.makeBasic()
                            options.setPendingIntentBackgroundActivityStartMode(
                                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                            )
                            // A distinct request code per launch. PendingIntent
                            // equality ignores extras, so a constant 0 made two
                            // launches with the same action+data resolve to the
                            // SAME pending intent, and FLAG_UPDATE_CURRENT
                            // overwrote the first one's extras before delivery —
                            // e.g. two mailto: to one address with different
                            // bodies, where the first could arrive with the
                            // second's payload. send() is async on API 34+, so
                            // the window is real.
                            val requestCode = launchRequestCodes.incrementAndGet()
                            val pi = PendingIntent.getActivity(
                                launchContext,
                                requestCode,
                                intent,
                                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                            )
                            try {
                                pi.send(launchContext, 0, null, null, null, null, options.toBundle())
                            } finally {
                                // Release the system-side reference; without
                                // this each launch leaks a PendingIntent that
                                // keeps the target component alive.
                                pi.cancel()
                            }
                        } else {
                            launchContext.startActivity(intent)
                        }

                        result.success(outcome)

                    } catch (e: android.content.ActivityNotFoundException) {
                        result.error(
                            "NO_HANDLER",
                            "No activity can handle this intent: ${e.message}",
                            null
                        )
                    } catch (e: PendingIntent.CanceledException) {
                        result.error(
                            "PENDING_INTENT_CANCELED",
                            "Android canceled this pending intent: ${e.message}",
                            null
                        )
                    } catch (e: SecurityException) {
                        result.error(
                            "INTENT_SECURITY",
                            "Android rejected this intent: ${e.message}",
                            null
                        )
                    } catch (e: IllegalArgumentException) {
                        result.error(
                            "INVALID_INTENT",
                            "Invalid intent: ${e.message}",
                            null
                        )
                    } catch (e: Exception) {
                        result.error("INTENT_ERR", e.message, null)
                    }
                }

                "bringToFront" -> {
                    try {
                        val a11y = ErrandAccessibilityService.instance
                        val ctx: Context = a11y ?: this
                        val intent = Intent(ctx, MainActivity::class.java).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        }
                        @Suppress("DEPRECATION")
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            val options = ActivityOptions.makeBasic()
                            options.setPendingIntentBackgroundActivityStartMode(
                                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                            )
                            val pi = PendingIntent.getActivity(
                                ctx,
                                launchRequestCodes.incrementAndGet(),
                                intent,
                                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                            )
                            try {
                                pi.send(ctx, 0, null, null, null, null, options.toBundle())
                            } finally {
                                // Same release as the launch path: each call
                                // otherwise leaks a system-side PendingIntent.
                                pi.cancel()
                            }
                        } else {
                            ctx.startActivity(intent)
                        }
                        result.success("brought_to_front")
                    } catch (e: Exception) {
                        result.error("BRING_TO_FRONT_ERR", e.message, null)
                    }
                }

                "canResolve" -> {
                    try {
                        val action = call.argument<String>("action") ?: Intent.ACTION_VIEW
                        val data = call.argument<String>("data")
                        val pkg = call.argument<String>("package")
                        val type = call.argument<String>("type")

                        val act = when {
                            action == "dial" || data?.startsWith("tel:") == true -> Intent.ACTION_DIAL
                            action == "email" || data?.startsWith("mailto:") == true -> Intent.ACTION_SENDTO
                            else -> action
                        }

                        val intent = Intent(act).apply {
                            val uri = data?.let { Uri.parse(it) }
                            if (uri != null && type != null) {
                                setDataAndType(uri, type)
                            } else if (uri != null) {
                                this.data = uri
                            } else if (type != null) {
                                this.type = type
                            }
                            if (uri?.scheme?.lowercase() in listOf("http", "https")) {
                                addCategory(Intent.CATEGORY_BROWSABLE)
                            }
                            pkg?.let { this.`package` = it }
                        }
                        result.success(intent.resolveActivity(packageManager) != null)
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

                "getAppLabel" -> {
                    val p = call.argument<String>("package")
                    if (p.isNullOrEmpty()) {
                        result.success(null)
                    } else {
                        try {
                            val info = packageManager.getApplicationInfo(p, 0)
                            val label = packageManager.getApplicationLabel(info).toString()
                            result.success(label)
                        } catch (_: Exception) {
                            result.success(null)
                        }
                    }
                }

                "startWorkIndicator" -> {
                    try {
                        AgentForegroundService.start(this)
                        result.success("started")
                    } catch (e: Exception) {
                        result.error("FGS_ERR", e.message, null)
                    }
                }

                "stopWorkIndicator" -> {
                    try {
                        AgentForegroundService.stop(this)
                        result.success("stopped")
                    } catch (e: Exception) {
                        result.error("FGS_ERR", e.message, null)
                    }
                }

                "requestNotificationPermission" -> {
                    requestPostNotificationsPermission()
                    result.success(null)
                }

                "showNotification" -> {
                    val id = call.argument<Int>("id") ?: 1000
                    val title = call.argument<String>("title") ?: "Errand Task"
                    val body = call.argument<String>("body") ?: ""
                    val channelId = call.argument<String>("channelId") ?: "scheduled_tasks"
                    val channelName = call.argument<String>("channelName") ?: "Scheduled Tasks"
                    val isSuccess = call.argument<Boolean>("isSuccess")
                    val ok = NotificationHelper.showNotification(this, id, title, body, channelId, channelName, isSuccess)
                    result.success(ok)
                }

                "cancelNotification" -> {
                    val id = call.argument<Int>("id") ?: return@setMethodCallHandler result.success(false)
                    val ok = NotificationHelper.cancelNotification(this, id)
                    result.success(ok)
                }

                "hasNotificationPermission" -> {
                    result.success(NotificationHelper.hasPermission(this))
                }

                "hasMicPermission" -> {
                    result.success(
                        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
                            PackageManager.PERMISSION_GRANTED
                    )
                }

                "requestMicPermission" -> {
                    val granted = ContextCompat.checkSelfPermission(
                        this, Manifest.permission.RECORD_AUDIO
                    ) == PackageManager.PERMISSION_GRANTED
                    if (granted) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    // Reply arrives via onRequestPermissionsResult.
                    micPermissionResult = result
                    ActivityCompat.requestPermissions(
                        this, arrayOf(Manifest.permission.RECORD_AUDIO), MIC_PERMISSION_CODE
                    )
                }

                "copyRichText" -> {
                    try {
                        val text = call.argument<String>("text") ?: ""
                        val html = call.argument<String>("html") ?: ""
                        if (text.isEmpty() && html.isEmpty()) {
                            result.error("EMPTY_CLIP", "Both text and html are empty", null)
                        } else {
                            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
                            val clip = ClipData.newHtmlText("Errand", text, html)
                            clipboard.setPrimaryClip(clip)
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        Log.e("MainActivity", "Failed to copy rich text", e)
                        result.error("CLIPBOARD_ERR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        // ---- Accessibility (P2a: read-only screen access) ----
        // Delegates to the live ErrandAccessibilityService via its static
        // instance; a null instance IS the "not enabled" signal.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            A11Y_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isEnabled" -> result.success(ErrandAccessibilityService.isConnected())
                "isSupported" -> {
                    val intent = Intent("android.accessibilityservice.AccessibilityService").apply {
                        `package` = packageName
                    }
                    val services = packageManager.queryIntentServices(intent, 0)
                    result.success(services.isNotEmpty())
                }
                "isRestricted" -> result.success(ErrandAccessibilityService.isRestricted(this))
                "openSettings" -> {
                    try {
                        // Deep link straight to our own service toggle when possible;
                        // fall back to the accessibility list page.
                        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                        startActivity(intent)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERR", e.message, null)
                    }
                }
                "disable" -> {
                    try {
                        val svc = ErrandAccessibilityService.instance
                        if (svc != null) {
                            svc.disableSelf()
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        result.error("DISABLE_ERR", e.message, null)
                    }
                }
                "readScreen" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            val maxNodes = call.argument<Int>("maxNodes") ?: 300
                            val full = call.argument<Boolean>("full") ?: false
                            val probe = call.argument<Boolean>("probe") ?: false
                            result.success(svc.readScreen(maxNodes = maxNodes, full = full, probe = probe))
                        } catch (e: Exception) {
                            result.error("READ_ERR", e.message, null)
                        }
                    }
                }
                "globalAction" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        val name = call.argument<String>("name") ?: ""
                        val err = svc.performGlobalActionByName(name)
                        if (err != null) result.error("ACTION_ERR", err, null)
                        else result.success(null)
                    }
                }

                "takeScreenshot" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        val temp = call.argument<Boolean>("temp") ?: true
                        val qualityArg = call.argument<String>("quality")?.trim()?.lowercase()
                        val quality = if (qualityArg == "hd" || qualityArg == "sd") qualityArg else if (temp) "sd" else "hd"
                        svc.takeScreenshot(quality = quality, temp = temp) { res ->
                            runOnUiThread {
                                if (res["ok"] == true) {
                                    result.success(res)
                                } else {
                                    result.error(
                                        res["error"] as? String ?: "CAPTURE_FAILED",
                                        res["message"] as? String,
                                        res
                                    )
                                }
                            }
                        }
                    }
                }

                "imeFieldInfo" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            result.success(svc.imeFieldInfo())
                        } catch (e: Exception) {
                            result.error("IME_ERR", e.message, null)
                        }
                    }
                }

                "imeCommit" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            val text = call.argument<String>("text") ?: ""
                            val replaceAll = call.argument<Boolean>("replaceAll") ?: true
                            result.success(svc.imeCommit(text, replaceAll))
                        } catch (e: Exception) {
                            result.error("IME_ERR", e.message, null)
                        }
                    }
                }

                "imeSendTab" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            result.success(svc.imeSendTab())
                        } catch (e: Exception) {
                            result.error("IME_ERR", e.message, null)
                        }
                    }
                }

                "imeSendEscape" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            result.success(svc.imeSendEscape())
                        } catch (e: Exception) {
                            result.error("IME_ERR", e.message, null)
                        }
                    }
                }
                "tapRef" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            val ref = call.argument<Int>("ref") ?: 0
                            val longClick = call.argument<Boolean>("longClick") ?: false
                            result.success(svc.tapByRef(ref, longClick))
                        } catch (e: Exception) {
                            result.error("TAP_ERR", e.message, null)
                        }
                    }
                }

                "tapByText" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            val label = call.argument<String>("label") ?: ""
                            val exact = call.argument<Boolean>("exact") ?: false
                            val occurrence = call.argument<Int>("occurrence") ?: 1
                            result.success(svc.tapByText(label, exact, occurrence))
                        } catch (e: Exception) {
                            result.error("TAP_ERR", e.message, null)
                        }
                    }
                }
                "typeText" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            val text = call.argument<String>("text") ?: ""
                            result.success(svc.typeText(text))
                        } catch (e: Exception) {
                            result.error("TYPE_ERR", e.message, null)
                        }
                    }
                }
                "scroll" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            val direction = call.argument<String>("direction") ?: "down"
                            val times = call.argument<Int>("times") ?: 1
                            val nearLabel = call.argument<String>("nearLabel")
                            result.success(svc.scroll(direction, times, nearLabel))
                        } catch (e: Exception) {
                            result.error("SCROLL_ERR", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ---- App Info & OTA installer channel ----
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_INFO_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // NotificationService targets this channel. Without these three the
                // foreground engine's hasPermission() returns false, and
                // showNotification() then bails before its own fallback — so
                // notification_sent is never recorded for foreground-originated runs.
                "showNotification" -> {
                    val id = call.argument<Int>("id") ?: 1000
                    val title = call.argument<String>("title") ?: "Errand Task"
                    val body = call.argument<String>("body") ?: ""
                    val channelId = call.argument<String>("channelId") ?: "scheduled_tasks"
                    val channelName = call.argument<String>("channelName") ?: "Scheduled Tasks"
                    val isSuccess = call.argument<Boolean>("isSuccess")
                    val ok = NotificationHelper.showNotification(
                        this, id, title, body, channelId, channelName, isSuccess
                    )
                    result.success(ok)
                }
                "cancelNotification" -> {
                    val id = call.argument<Int>("id") ?: -1
                    // Same contract as the background engine's handler (id > 0).
                    val ok = if (id > 0) NotificationHelper.cancelNotification(this, id) else false
                    result.success(ok)
                }
                "hasNotificationPermission" -> {
                    result.success(NotificationHelper.hasPermission(this))
                }
                // Also reachable from NotificationService, which targets this channel.
                "requestNotificationPermission" -> {
                    requestPostNotificationsPermission()
                    result.success(null)
                }
                "getVersion" -> {
                    try {
                        val packageInfo = packageManager.getPackageInfo(packageName, 0)
                        result.success(packageInfo.versionName)
                    } catch (e: Exception) {
                        result.error("VERSION_ERR", e.message, null)
                    }
                }
                "getAppInfo" -> {
                    try {
                        val packageInfo = packageManager.getPackageInfo(packageName, 0)
                        val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            packageManager.getInstallSourceInfo(packageName).installingPackageName
                        } else {
                            @Suppress("DEPRECATION")
                            packageManager.getInstallerPackageName(packageName)
                        }
                        result.success(
                            mapOf(
                                "versionName" to packageInfo.versionName,
                                "packageName" to packageName,
                                "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a"),
                                "installerPackage" to installer
                            )
                        )
                    } catch (e: Exception) {
                        result.error("APP_INFO_ERR", e.message, null)
                    }
                }
                "installApk" -> {
                    val path = call.argument<String>("filePath")
                    if (path.isNullOrEmpty()) {
                        result.error("NO_PATH", "filePath is required", null)
                        return@setMethodCallHandler
                    }
                    val file = resolveContainedFile(path)
                    if (file == null) {
                        result.error(
                            "PATH_NOT_ALLOWED",
                            "APK path is outside the allowed storage roots: $path",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    if (!file.exists()) {
                        result.error("FILE_NOT_FOUND", "APK file does not exist: $path", null)
                        return@setMethodCallHandler
                    }

                    // Verify the candidate before handing it to the package
                    // installer. Android enforces the signing key on install, so
                    // this is not an arbitrary-code path — but the file itself is
                    // still untrusted input, and a Dart-side bypass of the
                    // download-time checks must not be able to skip verification.
                    val expectedSha = call.argument<String>("sha256")
                    if (!expectedSha.isNullOrBlank()) {
                        val actual = sha256Of(file)
                        if (actual == null) {
                            result.error("VERIFY_ERR", "Could not read $path for verification", null)
                            return@setMethodCallHandler
                        }
                        if (!actual.equals(expectedSha.trim(), ignoreCase = true)) {
                            Log.e("ErrandInstall", "SHA-256 mismatch for $path; refusing to install")
                            result.error("SHA_MISMATCH", "APK checksum does not match; refusing to install", null)
                            return@setMethodCallHandler
                        }
                    } else {
                        Log.e("ErrandInstall", "installApk called without an expected sha256; refusing")
                        result.error(
                            "NO_CHECKSUM",
                            "Refusing to install without a published SHA-256 to verify against",
                            null,
                        )
                        return@setMethodCallHandler
                    }

                    // Anti-rollback: never hand the installer a build older than
                    // the one running. Without this, a validly-signed historical
                    // APK could downgrade the app (and re-introduce old bugs or
                    // vulns) even though the platform would accept it.
                    val newVersion = apkVersionCodeOf(file)
                    val currentVersion = apkVersionCodeOf(this.packageName)
                    if (newVersion != null && currentVersion != null && newVersion < currentVersion) {
                        Log.e(
                            "ErrandInstall",
                            "Refusing downgrade: candidate $newVersion < installed $currentVersion"
                        )
                        result.error(
                            "DOWNGRADE_BLOCKED",
                            "Refusing to install an older build ($newVersion < $currentVersion)",
                            null,
                        )
                        return@setMethodCallHandler
                    }

                    try {
                        val authority = "$packageName.fileprovider"
                        val contentUri = FileProvider.getUriForFile(this, authority, file)
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(contentUri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INSTALL_ERR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ---- Location channel ----
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LOCATION_CHANNEL
        ).setMethodCallHandler { call, result ->
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
                    val fine = ContextCompat.checkSelfPermission(
                        this, Manifest.permission.ACCESS_FINE_LOCATION
                    ) == PackageManager.PERMISSION_GRANTED
                    val coarse = ContextCompat.checkSelfPermission(
                        this, Manifest.permission.ACCESS_COARSE_LOCATION
                    ) == PackageManager.PERMISSION_GRANTED
                    if (fine || coarse) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    locationPermissionResult = result
                    ActivityCompat.requestPermissions(
                        this,
                        arrayOf(
                            Manifest.permission.ACCESS_FINE_LOCATION,
                            Manifest.permission.ACCESS_COARSE_LOCATION
                        ),
                        LOCATION_PERMISSION_CODE
                    )
                }

                "getLocation" -> {
                    fetchLocation(result)
                }

                else -> result.notImplemented()
            }
        }

        // ---- Widget channel (P7) ----
        widgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WIDGET_CHANNEL
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeInitialVoicePrompt" -> {
                        val shouldTrigger = pendingVoicePrompt
                        pendingVoicePrompt = false
                        result.success(shouldTrigger)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // ---- PDF Reader Channel (P15) ----
        pdfPlugin = PdfReaderPlugin.registerWith(flutterEngine.dartExecutor.binaryMessenger, this).second

        // Check if cold-started with widget voice intent
        checkVoicePromptIntent(intent)
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

    private fun dispatchLocationResult(location: Location, result: MethodChannel.Result) {
        geocodeExecutor.execute {
            val future = geocodeExecutor.submit<Map<String, Any?>> {
                reverseGeocode(location)
            }
            val addressMap = try {
                future.get(8, TimeUnit.SECONDS)
            } catch (_: TimeoutException) {
                future.cancel(true)
                mapOf("error" to "Geocoding timed out after 8s")
            } catch (e: Exception) {
                mapOf("error" to (e.message ?: "Geocoding failed"))
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
            runOnUiThread {
                try {
                    result.success(data)
                } catch (_: Exception) {
                    // Second reply after a timeout race — already answered.
                }
            }
        }
    }

    private fun fetchLocation(result: MethodChannel.Result) {
        val fineGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarseGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

        if (!fineGranted && !coarseGranted) {
            result.error("PERMISSION_DENIED", "Location permission is not granted.", null)
            return
        }

        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            result.error("LOCATION_UNAVAILABLE", "LocationManager service is unavailable", null)
            return
        }

        val gpsEnabled = try { lm.isProviderEnabled(LocationManager.GPS_PROVIDER) } catch (_: Exception) { false }
        val networkEnabled = try { lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) } catch (_: Exception) { false }

        if (!gpsEnabled && !networkEnabled) {
            result.error("LOCATION_DISABLED", "Location services (GPS and Network) are turned off on the device.", null)
            return
        }

        var bestLocation: Location? = null
        if (gpsEnabled) {
            try {
                val loc = lm.getLastKnownLocation(LocationManager.GPS_PROVIDER)
                if (loc != null) bestLocation = loc
            } catch (_: SecurityException) {}
        }
        if (networkEnabled) {
            try {
                val loc = lm.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
                if (loc != null) {
                    if (bestLocation == null || loc.time > bestLocation.time || (loc.hasAccuracy() && bestLocation.hasAccuracy() && loc.accuracy < bestLocation.accuracy)) {
                        bestLocation = loc
                    }
                }
            } catch (_: SecurityException) {}
        }

        // If we have a cached fix younger than 5 minutes, use it directly
        if (bestLocation != null && (System.currentTimeMillis() - bestLocation.time) < 5 * 60 * 1000) {
            dispatchLocationResult(bestLocation, result)
            return
        }

        val provider = if (gpsEnabled && fineGranted) LocationManager.GPS_PROVIDER else LocationManager.NETWORK_PROVIDER
        var dispatched = false
        val handler = Handler(Looper.getMainLooper())
        lateinit var timeoutRunnable: Runnable

        val listener = object : LocationListener {
            override fun onLocationChanged(loc: Location) {
                synchronized(this@MainActivity) {
                    if (dispatched) return
                    dispatched = true
                }
                handler.removeCallbacks(timeoutRunnable)
                try { lm.removeUpdates(this) } catch (_: Exception) {}
                clearPendingLocationRequest()
                dispatchLocationResult(loc, result)
            }
            override fun onProviderDisabled(p: String) {}
            override fun onProviderEnabled(p: String) {}
            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(p: String?, s: Int, e: android.os.Bundle?) {}
        }

        timeoutRunnable = Runnable {
            synchronized(this@MainActivity) {
                if (dispatched) return@Runnable
                dispatched = true
            }
            try { lm.removeUpdates(listener) } catch (_: Exception) {}
            clearPendingLocationRequest()
            if (bestLocation != null) {
                dispatchLocationResult(bestLocation, result)
            } else {
                try {
                    result.error("LOCATION_TIMEOUT", "Timed out waiting for GPS/Network location fix.", null)
                } catch (_: Exception) {}
            }
        }

        // Track the in-flight request so onDestroy can tear it down. These were
        // locals, so a destroyed activity left the LocationManager binding
        // alive and the 8s timeout still fired — replying to a MethodChannel
        // Result whose engine was already gone.
        pendingLocationListener = listener
        pendingLocationRunnable = timeoutRunnable
        handler.postDelayed(timeoutRunnable, 8000)

        try {
            lm.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
        } catch (e: Exception) {
            val shouldReply: Boolean
            synchronized(this@MainActivity) {
                shouldReply = !dispatched
                dispatched = true
            }
            if (shouldReply) {
                handler.removeCallbacks(timeoutRunnable)
                if (bestLocation != null) {
                    dispatchLocationResult(bestLocation, result)
                } else {
                    try {
                        result.error("LOCATION_ERR", e.message, null)
                    } catch (_: Exception) {}
                }
            }
        }
    }
}
