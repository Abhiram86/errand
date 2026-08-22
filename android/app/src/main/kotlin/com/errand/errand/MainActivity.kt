package com.errand.errand

import android.Manifest
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val STORAGE_CHANNEL = "storage_access"
    private val INTENT_CHANNEL = "intent"
    private val A11Y_CHANNEL = "a11y"

    private val MIC_PERMISSION_CODE = 9001
    private var micPermissionResult: MethodChannel.Result? = null

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
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                        val extras = call.argument<Map<String, String>>("extras")

                        val intent: Intent? = when {
                            action == "open_app" -> {
                                if (pkg == null) {
                                    result.error("NO_PKG", "Missing package for open_app", null)
                                    return@setMethodCallHandler
                                }
                                packageManager.getLaunchIntentForPackage(pkg)
                            }
                            action == "email" -> {
                                val uri = Uri.parse(data ?: "mailto:")
                                Intent(Intent.ACTION_SENDTO, uri).apply {
                                    val subject = extras?.get("subject") ?: uri.getQueryParameter("subject")
                                    val body = extras?.get("body") ?: uri.getQueryParameter("body")

                                    subject?.let { putExtra(Intent.EXTRA_SUBJECT, it) }
                                    body?.let { putExtra(Intent.EXTRA_TEXT, it) }
                                    pkg?.let { this.`package` = it }
                                }
                            }
                            else -> {
                                // Custom-action intents (alarm/timer/calendar/share/panels/etc.)
                                // pass an explicit androidAction; everything else defaults to VIEW.
                                val act = when {
                                    androidAction != null -> androidAction
                                    action == "dial" -> Intent.ACTION_DIAL
                                    else -> Intent.ACTION_VIEW
                                }
                                Intent(act).apply {
                                    data?.let {
                                        val uri = Uri.parse(it)
                                        this.data = uri
                                        if (uri.scheme?.lowercase() in listOf("http", "https")) {
                                            addCategory(Intent.CATEGORY_BROWSABLE)
                                        }
                                    }
                                    pkg?.let { this.`package` = it }
                                    extras?.forEach { (k, v) ->
                                        // Only these AlarmClock extras are ints; anything
                                        // else (e.g. MESSAGE) must stay a String.
                                        val isIntExtra = k == "android.intent.extra.alarm.HOUR" ||
                                            k == "android.intent.extra.alarm.MINUTES" ||
                                            k == "android.intent.extra.alarm.LENGTH"
                                        if (isIntExtra) {
                                            // Skip non-numeric values instead of coercing to 0
                                            // (a coerced LENGTH would set a 0-second timer).
                                            v.toIntOrNull()?.let { putExtra(k, it) }
                                        } else {
                                            putExtra(k, v)
                                        }
                                    }
                                    type?.let { this.type = it }
                                }
                            }
                        }

                        if (intent == null) {
                            result.error("NO_HANDLER", "Could not build intent for $action", null)
                            return@setMethodCallHandler
                        }

                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)

                        // Only pre-check resolvability when explicitly pinned to a package —
                        // resolveActivity is subject to <queries> visibility and returns null
                        // for unqueried handlers even when startActivity would succeed.
                        // For implicit intents we rely on ActivityNotFoundException below.
                        // ACTION_DELETE (uninstall) and ACTION_SENDTO (email) are excluded:
                        // their handlers live in other packages (packageinstaller / mail
                        // apps), so pinning checks against the target package are wrong.
                        val exemptFromPinnedCheck =
                            intent.action == Intent.ACTION_DELETE ||
                                intent.action == Intent.ACTION_SENDTO
                        if (pkg != null && !exemptFromPinnedCheck &&
                            intent.resolveActivity(packageManager) == null
                        ) {
                            result.error("NO_HANDLER", "No activity found for $action $data pkg=$pkg", null)
                            return@setMethodCallHandler
                        }

                        startActivity(intent)
                        result.success("launched")

                    } catch (e: android.content.ActivityNotFoundException) {
                        result.error("NO_HANDLER", e.message, null)
                    } catch (e: Exception) {
                        result.error("INTENT_ERR", e.message, null)
                    }
                }

                "canResolve" -> {
                    try {
                        val action = call.argument<String>("action") ?: Intent.ACTION_VIEW
                        val data = call.argument<String>("data")
                        val pkg = call.argument<String>("package")

                        val act = when (action) {
                            "dial" -> Intent.ACTION_DIAL
                            "email" -> Intent.ACTION_SENDTO
                            else -> Intent.ACTION_VIEW
                        }

                        val intent = Intent(act).apply {
                            data?.let {
                                val uri = Uri.parse(it)
                                this.data = uri
                                if (uri.scheme?.lowercase() in listOf("http", "https")) {
                                    addCategory(Intent.CATEGORY_BROWSABLE)
                                }
                            }
                            pkg?.let { this.`package` = it }
                        }
                        result.success(intent.resolveActivity(packageManager) != null)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }

                "hasWriteSettings" -> {
                    result.success(Settings.System.canWrite(this))
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
                    // Fire-and-forget: needed to SHOW the foreground-service
                    // notification on API 33+. The service itself runs either
                    // way — without the grant the notification is just hidden.
                    if (Build.VERSION.SDK_INT >= 33) {
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            9002
                        )
                    }
                    result.success(null)
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

                "requestWriteSettings" -> {
                    // Already granted — don't open settings, just report granted.
                    if (Settings.System.canWrite(this)) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    try {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_WRITE_SETTINGS,
                            Uri.parse("package:$packageName")
                        ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                        if (intent.resolveActivity(packageManager) == null) {
                            // Fallback for OEMs that don't handle package Uri
                            val fallback = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS)
                                .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                            startActivity(fallback)
                        } else {
                            startActivity(intent)
                        }
                        result.success(false)
                    } catch (e: Exception) {
                        result.error("INTENT_ERR", e.message, null)
                    }
                }

                "system_toggle" -> {
                    try {
                        val setting = call.argument<String>("setting")
                        val value = call.argument<Int>("value") ?: 0

                        when (setting) {
                            "dark_mode" -> {
                                // 1) Try UiModeManager first — no WRITE_SETTINGS needed on most devices.
                                // Read back after set: some builds silently ignore 3P calls, so
                                // only report success if the mode actually changed.
                                try {
                                    val uiManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                                    val mode = if (value > 0) UiModeManager.MODE_NIGHT_YES else UiModeManager.MODE_NIGHT_NO
                                    uiManager.nightMode = mode
                                    if (uiManager.nightMode == mode) {
                                        result.success("Dark mode set to ${if (value > 0) "ON" else "OFF"} via UiModeManager")
                                        return@setMethodCallHandler
                                    }
                                    // Silently ignored — fall through to Settings path.
                                } catch (_: Exception) {
                                    // fall through to Settings path
                                }

                                // 2) System-wide via Settings — requires permission and still
                                // may be blocked (WRITE_SECURE_SETTINGS). Check permission now.
                                // (The old AppCompatDelegate reflection path was removed: it
                                // only changed THIS app's theme, not the system's, and it ran
                                // unverified — flipping the app dark while reporting failure.)
                                if (!Settings.System.canWrite(this)) {
                                    result.error("PERMISSION_MISSING", "WRITE_SETTINGS not granted. Call requestWriteSettings.", null)
                                    return@setMethodCallHandler
                                }

                                var ok = false
                                try {
                                    ok = Settings.Secure.putInt(contentResolver, "ui_night_mode", if (value > 0) 2 else 1)
                                } catch (_: SecurityException) {}
                                if (!ok) {
                                    try {
                                        ok = Settings.Global.putInt(contentResolver, "ui_night_mode", if (value > 0) 2 else 1)
                                    } catch (_: SecurityException) {}
                                }
                                if (ok) {
                                    result.success("Dark mode set to ${if (value > 0) "ON" else "OFF"} via Settings")
                                    return@setMethodCallHandler
                                }

                                // 3) All programmatic paths blocked — open system UI.
                                // This is the honest fallback for stock Android where
                                // WRITE_SECURE_SETTINGS is required.
                                try {
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                        val darkIntent = Intent("android.settings.DARK_THEME_SETTINGS")
                                            .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                                        if (darkIntent.resolveActivity(packageManager) != null) {
                                            startActivity(darkIntent)
                                            result.success("System blocks programmatic dark mode. Opened Dark Theme settings — please toggle manually.")
                                            return@setMethodCallHandler
                                        }
                                    }
                                    val displayIntent = Intent(Settings.ACTION_DISPLAY_SETTINGS)
                                        .apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                                    startActivity(displayIntent)
                                    result.success("System blocks programmatic dark mode. Opened Display settings — please toggle Dark theme manually.")
                                } catch (e2: Exception) {
                                    result.error("TOGGLE_ERR", "System restricts programmatic dark mode (needs WRITE_SECURE_SETTINGS). Open Settings > Display > Dark theme manually. ${e2.message}", null)
                                }
                            }
                            else -> {
                                result.error("UNKNOWN_SETTING", "Setting '$setting' is not supported.", null)
                            }
                        }
                    } catch (e: SecurityException) {
                        result.error("PERMISSION_DENIED", "WRITE_SETTINGS permission denied.", null)
                    } catch (e: Exception) {
                        result.error("TOGGLE_ERR", e.message, null)
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
                "readScreen" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            val maxNodes = call.argument<Int>("maxNodes") ?: 300
                            result.success(svc.readScreen(maxNodes = maxNodes))
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
                "tapByText" -> {
                    val svc = ErrandAccessibilityService.instance
                    if (svc == null) {
                        result.error("NOT_ENABLED", "Accessibility service is not enabled.", null)
                    } else {
                        try {
                            val label = call.argument<String>("label") ?: ""
                            val exact = call.argument<Boolean>("exact") ?: false
                            result.success(svc.tapByText(label, exact))
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
                            val down = call.argument<Boolean>("down") ?: true
                            result.success(svc.scroll(down))
                        } catch (e: Exception) {
                            result.error("SCROLL_ERR", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}