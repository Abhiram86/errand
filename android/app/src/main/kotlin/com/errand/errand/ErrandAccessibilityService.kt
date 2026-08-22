package com.errand.errand

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.MethodChannel

/**
 * P2a screen-reading accessibility service.
 *
 * Read-only for now (Tier S): serializes the active window's node tree to a
 * compact text outline and performs global navigation actions. Gesture/node
 * injection is Tier A and intentionally absent.
 *
 * Lifecycle notes:
 * - Android instantiates this class itself when the user enables it in
 *   Settings > Accessibility. We never construct it manually.
 * - The static [instance] lets MainActivity's "a11y" MethodChannel reach the
 *   running service without any extra plumbing. It is null whenever the
 *   service is disabled — that null IS the "not enabled" signal.
 */
class ErrandAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: ErrandAccessibilityService? = null
            private set

        /** True only while the user has enabled (and the system has bound) the service. */
        fun isConnected(): Boolean = instance != null

        /**
         * True when Android 13+ blocks enabling the service because the app was
         * sideloaded via the non-session installer ("Restricted setting").
         * The unlock is App Info -> ⋮ -> Allow restricted settings, or
         * `adb shell appops set com.errand.errand ACCESS_RESTRICTED_SETTINGS allow`.
         */
        fun isRestricted(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
            return try {
                val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
                val info = context.packageManager.getApplicationInfo(context.packageName, 0)
                val mode = appOps.unsafeCheckOpNoThrow(
                    "android:access_restricted_settings", info.uid, context.packageName
                )
                mode == AppOpsManager.MODE_ERRORED || mode == AppOpsManager.MODE_IGNORED
            } catch (_: Exception) {
                false
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        serviceInfo = serviceInfo.apply {
            eventTypes = AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            flags = AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            notificationTimeout = 100
        }
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {}

    // Only listening for window changes right now; no background monitoring.
    // Everything the agent does is pulled on-demand via readScreen().
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    // ---- Screen reading ----------------------------------------------------

    /**
     * Serializes the active window into a compact outline:
     *   [12] Button "Allow" [clickable]
     * Depth-, node- and char-capped DFS; a char budget is enforced here so
     * we don't build megabyte strings natively, and again on the Dart side
     * as the final backstop.
     */
    fun readScreen(
        maxNodes: Int = 300,
        maxDepth: Int = 15,
        maxChars: Int = 12000,
    ): Map<String, Any?> {
        val root = rootInActiveWindow
            ?: return mapOf(
                "ok" to false,
                "error" to "NO_WINDOW",
                "message" to "No active window content available. The foreground app may not expose semantics.",
            )

        val sb = StringBuilder()
        var visited = 0
        val truncated = visitNode(root, 0, maxDepth, maxChars, sb) { visited++ < maxNodes }

        val pkg = root.packageName?.toString() ?: "unknown"
        val header = "Screen: package=$pkg\n"
        return mapOf(
            "ok" to true,
            "package" to pkg,
            "outline" to header + sb.toString(),
            "nodes" to visited,
            "truncated" to truncated,
        )
    }

    /** Returns true if the walk was cut short by a cap. */
    private fun visitNode(
        node: AccessibilityNodeInfo,
        depth: Int,
        maxDepth: Int,
        maxChars: Int,
        sb: StringBuilder,
        budget: () -> Boolean,
    ): Boolean {
        if (depth > maxDepth || sb.length >= maxChars || !budget()) return true

        val cls = node.className?.toString()?.substringAfterLast('.') ?: "View"
        val label = node.text?.toString()?.take(120)?.ifBlank { null }
            ?: node.contentDescription?.toString()?.take(120)?.ifBlank { null }
            ?: node.hintText?.toString()?.take(120)?.ifBlank { null }

        val actionable = node.isClickable || node.isScrollable || node.isEditable
        if (!node.isVisibleToUser && label == null && !actionable) {
            // Skip invisible structural nodes — but keep invisible ones that
            // carry text (off-screen list content) or are actionable
            // (collapsed menus), which the outline exists to surface.
        } else {
            val flags = buildList {
                if (node.isClickable) add("clickable")
                if (node.isEditable) add("editable")
                if (node.isChecked) add("checked")
                if (node.isSelected) add("selected")
                if (node.isScrollable) add("scrollable")
            }
            sb.append('[').append(depth).append("] ").append(cls)
            if (label != null) sb.append(" \"").append(label.replace("\n", " ")).append('"')
            if (flags.isNotEmpty()) sb.append(" [").append(flags.joinToString(",")).append(']')
            sb.append('\n')
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val cut = visitNode(child, depth + 1, maxDepth, maxChars, sb, budget)
            child.recycle()
            if (cut) return true
        }
        return false
    }

    // ---- Global actions ------------------------------------------------------

    /** Returns an error string, or null on success. */
    fun performGlobalActionByName(name: String): String? {
        val action = when (name) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
            "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
            "lock_screen" ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) GLOBAL_ACTION_LOCK_SCREEN
                else return "LOCK_SCREEN needs API 28+"
            else -> return "Unknown global action '$name'"
        }
        return if (performGlobalAction(action)) null else "Global action '$name' failed"
    }
}
