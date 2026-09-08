package com.errand.errand

import android.Manifest
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

    override fun onDestroy() {
        if (isFinishing) {
            try {
                ErrandAccessibilityService.instance?.disableSelf()
            } catch (_: Exception) {}
        }
        super.onDestroy()
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

                            action == "open_file" || (action == "open_url" && data != null && (data.startsWith("/") || data.startsWith("file://"))) -> {
                                val rawPath = data ?: ""
                                val filePath = if (rawPath.startsWith("file://")) {
                                    Uri.parse(rawPath).path ?: rawPath.removePrefix("file://")
                                } else {
                                    rawPath
                                }
                                val file = File(filePath)
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
                                    else -> "*/*"
                                }

                                Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(contentUri, resolvedType)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    clipData = ClipData.newRawUri(null, contentUri)
                                    pkg?.let { this.`package` = it }
                                    extras?.forEach { (k, v) -> putExtra(k, v) }
                                }
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
                                        putExtra(k, v)
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
                        } else {
                            "launched"
                        }

                        val a11y = ErrandAccessibilityService.instance
                        val launchContext: Context = a11y ?: this

                        @Suppress("DEPRECATION")
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            val options = ActivityOptions.makeBasic()
                            options.setPendingIntentBackgroundActivityStartMode(
                                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                            )
                            val pi = PendingIntent.getActivity(
                                launchContext,
                                0,
                                intent,
                                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                            )
                            pi.send(launchContext, 0, null, null, null, null, options.toBundle())
                        } else {
                            launchContext.startActivity(intent)
                        }

                        result.success(outcome)

                    } catch (e: android.content.ActivityNotFoundException) {
                        result.error("NO_HANDLER", e.message, null)
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
                                0,
                                intent,
                                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                            )
                            pi.send(ctx, 0, null, null, null, null, options.toBundle())
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
    }
}