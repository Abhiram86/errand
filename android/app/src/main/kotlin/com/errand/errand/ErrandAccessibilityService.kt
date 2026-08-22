package com.errand.errand

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.MethodChannel

/**
 * P2a screen-reading + P2b gated-injection accessibility service.
 *
 * P2a: serializes the active window's node tree to a compact text outline
 * and performs global navigation actions.
 * P2b (Tier A, Draft-mode): semantic node actions only — tap-by-label,
 * type-into-focused-field, scroll. NO blind coordinate taps; commit-looking
 * controls are refused at the Dart tool layer (see act_tool.dart).
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

        // Report WHICH cap bound the walk — "truncated" alone made the model
        // raise max_nodes when the character budget was the real limit.
        val charCapHit = truncated && sb.length >= maxChars
        val nodeCapHit = truncated && !charCapHit && visited >= maxNodes
        return mapOf(
            "ok" to true,
            "package" to pkg,
            "outline" to header + sb.toString(),
            "nodes" to visited,
            "maxNodes" to maxNodes,
            "charsUsed" to sb.length,
            "maxChars" to maxChars,
            "capHit" to when {
                charCapHit -> "chars"
                nodeCapHit -> "nodes"
                else -> null
            },
            "truncated" to truncated,
        )
    }

    /**
     * Word-boundary trim so long labels (mail snippets, list items) don't
     * cut mid-word like "Confirm your ema". Marks the cut with an ellipsis.
     */
    private fun trimLabel(raw: String, maxLen: Int = 120): String {
        // Apps like Gmail glue list fields into one contentDescription with
        // empty segments (", , , Spotify, , subject…") — collapse those gaps.
        val s = raw.replace('\n', ' ').replace(Regex("(),\\s*"), "").trim()
        if (s.length <= maxLen) return s
        val cut = s.lastIndexOf(' ', maxLen)
        return (if (cut > maxLen / 2) s.substring(0, cut) else s.substring(0, maxLen)) + "…"
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
        val label = node.text?.toString()?.let(::trimLabel)?.ifBlank { null }
            ?: node.contentDescription?.toString()?.let(::trimLabel)?.ifBlank { null }
            ?: node.hintText?.toString()?.let(::trimLabel)?.ifBlank { null }

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

    // ---- P2b: gated injection (Draft mode primitives) -----------------------
    //
    // Deliberately narrow: semantic targets only (label text from the screen
    // outline the agent already read), never raw coordinates. The commit-control
    // refusal lives in act_tool.dart so it stays unit-testable in Dart.

    /** Returns {ok, label?, error?, message?}. */
    fun tapByText(label: String, exact: Boolean): Map<String, Any?> {
        val root = rootInActiveWindow
            ?: return mapOf("ok" to false, "error" to "NO_WINDOW",
                "message" to "No active window content available.")

        val needle = label.trim().lowercase()
        if (needle.isEmpty()) {
            return mapOf("ok" to false, "error" to "EMPTY_LABEL",
                "message" to "Tap target label was empty.")
        }

        // (node, score, matchedText) triples; everything recycled after pick.
        val candidates = mutableListOf<Triple<AccessibilityNodeInfo, Int, String>>()
        collectMatchingClickable(root, needle, exact, candidates)

        val best = candidates.maxByOrNull { it.second }
        if (best == null) {
            candidates.forEach { it.first.recycle() }
            return mapOf("ok" to false, "error" to "NOT_FOUND",
                "message" to "No clickable element matching \"$label\" on the current screen. " +
                    "Re-read the screen and use the exact label.")
        }

        val clickedText = best.third

        // Track every node instance we touch so each is recycled exactly once.
        val touched = mutableListOf(best.first)
        var target: AccessibilityNodeInfo = best.first
        var hops = 0
        while (!target.isClickable && hops < 5) {
            val parent = target.parent ?: break
            touched.add(parent)
            target = parent
            hops++
        }

        val ok = target.isClickable && target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        touched.forEach { it.recycle() }

        return if (ok) {
            mapOf("ok" to true, "label" to clickedText,
                "message" to "Tapped \"$clickedText\"")
        } else {
            mapOf("ok" to false, "error" to "CLICK_FAILED",
                "message" to "Found \"$clickedText\" but could not click it.")
        }
    }

    private fun nodeLabel(node: AccessibilityNodeInfo): String? =
        node.text?.toString()?.trim()?.ifBlank { null }
            ?: node.contentDescription?.toString()?.trim()?.ifBlank { null }

    private fun matchScore(candidate: String, needle: String, exact: Boolean): Int? {
        val lower = candidate.lowercase()
        return when {
            lower == needle -> 3
            lower.startsWith(needle) -> 2
            !exact && lower.contains(needle) -> 1
            else -> null
        }
    }

    private fun collectMatchingClickable(
        node: AccessibilityNodeInfo,
        needle: String,
        exact: Boolean,
        out: MutableList<Triple<AccessibilityNodeInfo, Int, String>>,
    ) {
        // Any labeled match is a candidate; tapByText() walks up to the nearest
        // clickable ancestor afterwards (labels often live on child TextViews).
        val label = nodeLabel(node)
        if (label != null) {
            matchScore(label, needle, exact)?.let { score ->
                out.add(Triple(AccessibilityNodeInfo.obtain(node), score, label))
            }
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            collectMatchingClickable(child, needle, exact, out)
            child.recycle()
        }
    }

    /**
     * Types [text] into the focused editable field via ACTION_SET_TEXT.
     * NOTE: SET_TEXT REPLACES field content — to append, read the field from
     * the screen outline first and set the full combined string. Password
     * fields are refused unconditionally.
     * Returns {ok, error?, message?}.
     */
    fun typeText(text: String): Map<String, Any?> {
        val root = rootInActiveWindow
            ?: return mapOf("ok" to false, "error" to "NO_WINDOW",
                "message" to "No active window content available.")

        val focus = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: return mapOf("ok" to false, "error" to "NO_FOCUS",
                "message" to "No focused input field. Tap the field's label first " +
                    "(act tap) or ask the user to focus it.")

        try {
            if (!focus.isEditable) {
                return mapOf("ok" to false, "error" to "NOT_EDITABLE",
                    "message" to "The focused element is not an editable field.")
            }
            if (focus.isPassword) {
                return mapOf("ok" to false, "error" to "PASSWORD_FIELD",
                    "message" to "Refusing to type into a password field.")
            }
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            }
            val ok = focus.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            return if (ok) {
                mapOf("ok" to true, "chars" to text.length,
                    "message" to "Set field content (${text.length} chars). " +
                        "This does NOT submit — the user sends.")
            } else {
                mapOf("ok" to false, "error" to "SET_TEXT_FAILED",
                    "message" to "Field refused SET_TEXT (some apps don't support it).")
            }
        } finally {
            focus.recycle()
        }
    }

    /**
     * Scrolls the first visible scrollable node; falls back to a center-screen
     * swipe gesture when no scrollable node exposes actions (custom views).
     * [down] = scroll toward later content.
     *
     * End-of-list signal: a scrollable that only supports the OPPOSITE
     * direction means we're already at the end in the requested direction —
     * reported as at_end instead of blindly dispatching.
     */
    fun scroll(down: Boolean): Map<String, Any?> {
        val root = rootInActiveWindow
            ?: return mapOf("ok" to false, "error" to "NO_WINDOW",
                "message" to "No active window content available.")

        val targetAction = if (down) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD

        findScrollable(root, targetAction)?.let { scrollable ->
            try {
                if (scrollable.performAction(targetAction)) {
                    return mapOf("ok" to true, "method" to "node_action",
                        "message" to if (down) "Scrolled down" else "Scrolled up")
                }
            } finally {
                scrollable.recycle()
            }
        }

        val oppositeAction = if (down) AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
        findScrollable(root, oppositeAction)?.let {
            it.recycle()
            return mapOf("ok" to true, "at_end" to true, "method" to "node_action",
                "message" to if (down)
                    "Already at the END of this list — no more content below."
                else
                    "Already at the TOP of this list.")
        }

        // Gesture fallback: swipe up = scroll down. Needs API 24+ and
        // canPerformGestures; no reliable end-detection on this path.
        return if (swipeCenter(down)) {
            mapOf("ok" to true, "method" to "gesture",
                "message" to if (down) "Swiped up (scroll down)" else "Swiped down (scroll up)")
        } else {
            mapOf("ok" to false, "error" to "SCROLL_FAILED",
                "message" to "Nothing scrollable found and gesture dispatch failed.")
        }
    }

    /** First visible scrollable node whose actionList contains [actionId]. */
    private fun findScrollable(
        node: AccessibilityNodeInfo,
        actionId: Int,
    ): AccessibilityNodeInfo? {
        if (node.isScrollable && node.isVisibleToUser &&
            node.actionList.any { it.id == actionId }
        ) {
            return AccessibilityNodeInfo.obtain(node)
        }
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findScrollable(child, actionId)
            child.recycle()
            if (found != null) return found
        }
        return null
    }

    /** Vertical center-screen swipe; needs API 24+ and canPerformGestures. */
    private fun swipeCenter(scrollDown: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        val m = resources.displayMetrics
        val h = m.heightPixels.toFloat()
        val w = m.widthPixels / 2f
        val path = Path().apply {
            moveTo(w, if (scrollDown) h * 0.70f else h * 0.30f)
            lineTo(w, if (scrollDown) h * 0.30f else h * 0.70f)
        }
        val gesture = android.accessibilityservice.GestureDescription.Builder()
            .addStroke(
                android.accessibilityservice.GestureDescription.StrokeDescription(path, 0, 250))
            .build()
        return dispatchGesture(gesture, null, null)
    }
}
