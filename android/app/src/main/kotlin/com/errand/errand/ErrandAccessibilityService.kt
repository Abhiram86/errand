package com.errand.errand

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.InputMethod
import android.app.AppOpsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.EditorInfo
import androidx.core.content.ContextCompat
import kotlin.math.abs

/**
 * P2a screen-reading + P2b gated-injection accessibility service.
 *
 * P2a: serializes the active window's node tree to a compact text outline
 * and performs global navigation actions.
 * P2b (Tier A, Draft-mode): semantic node actions only — tap-by-label,
 * type-into-focused-field, scroll. NO blind coordinate taps; commit-looking
 * controls are refused here AND at the Dart tool layer (see act_tool.dart).
 *
 * Lifecycle notes:
 * - Android instantiates this class itself when the user enables it in
 *   Settings > Accessibility. We never construct it manually.
 * - The static [instance] lets MainActivity's "a11y" MethodChannel reach the
 *   running service without any extra plumbing. It is null whenever the
 *   service is disabled — that null IS the "not enabled" signal.
 *
 * Dart contract (A11yService / channel "a11y"): keep method names, map keys,
 * and error codes stable. Tools call through that handle only.
 */
class ErrandAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile
        var instance: ErrandAccessibilityService? = null
            private set

        // Outline/interaction budgets.
        private const val MAX_OUTLINE_CHARS = 12000
        private const val MAX_TAP_HOPS = 5
        private const val MAX_REF_DEPTH = 25
        private const val MAX_WHEEL_STEPS = 30
        /** Max px drift allowed when resolving a numeric ref against the live tree. */
        private const val REF_BOUNDS_SLOP_PX = 24

        /**
         * Mirror of kCommitWords in lib/tools/act_tool.dart (Draft policy).
         * Keep in sync.
         */
        private val COMMIT_WORDS = setOf(
            "send", "post", "publish", "tweet", "reply-all",
            "pay", "buy", "purchase", "checkout", "order", "transfer", "subscribe",
            "delete", "remove", "uninstall", "confirm", "agree", "accept",
            "approve", "authorize", "sign",
        )

        private val RESTRICTED_PACKAGES = setOf(
            "com.phonepe.app",
            "com.google.android.apps.nbu.paisa.user",
            "net.one97.paytm",
            "in.org.npci.upiapp",
            "com.sbi.upi",
            "com.sbi.lotusintouch",
            "com.sbicard.omnichannel",
            "com.msf.kbank.mobile",
            "com.snapwork.hdfc",
            "com.csam.icici.bank.imobile",
            "com.axis.mobile",
            "com.bankofbaroda.mconnect",
            "com.dreamplug.androidapp",
            "com.zerodha.kite3",
            "com.nextbillion.groww",
            "com.x8bit.bitwarden",
            "com.onepassword.android",
            "com.google.android.apps.authenticator2",
        )

        /**
         * Returns true if [pkg] is a known banking, payment, or password-manager app.
         * Errand strictly refuses to inspect or interact with restricted apps.
         */
        fun isRestrictedApp(context: Context, pkg: String): Boolean {
            val lower = pkg.lowercase()
            if (pkg in RESTRICTED_PACKAGES) return true
            return lower.contains("sbi") ||
                lower.contains("bank") ||
                lower.contains("paytm") ||
                lower.contains("phonepe") ||
                lower.contains("upi") ||
                lower.contains("wallet")
        }

        /** Shuts down the running accessibility service via disableSelf(). */
        fun disable(): Boolean {
            val inst = instance ?: return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                inst.disableSelf()
                return true
            }
            return false
        }

        /** True if the app has been granted WRITE_SECURE_SETTINGS via ADB or Shizuku. */
        fun hasSecureSettings(context: Context): Boolean {
            return ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.WRITE_SECURE_SETTINGS
            ) == PackageManager.PERMISSION_GRANTED
        }

        /** Programmatically enables this service if WRITE_SECURE_SETTINGS is granted. */
        fun enableProgrammatically(context: Context): Boolean {
            if (!hasSecureSettings(context)) return false
            return try {
                val cr = context.contentResolver
                val component = ComponentName(context, ErrandAccessibilityService::class.java).flattenToString()
                val current = Settings.Secure.getString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
                if (!current.split(':').contains(component)) {
                    val updated = if (current.isEmpty()) component else "$current:$component"
                    Settings.Secure.putString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, updated)
                    Settings.Secure.putInt(cr, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
                }
                true
            } catch (_: Exception) {
                false
            }
        }

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
            // OR so XML flags (e.g. FLAG_INCLUDE_NOT_IMPORTANT_VIEWS) survive.
            flags = flags or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_INPUT_METHOD_EDITOR
            notificationTimeout = 100
        }
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        try {
            disable()
        } catch (_: Exception) {}
        super.onTaskRemoved(rootIntent)
    }

    override fun onInterrupt() {}

    // Only listening for window changes right now; no background monitoring.
    // Everything the agent does is pulled on-demand via readScreen().
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    // ---- Screen reading ----------------------------------------------------

    /**
     * Serializes the active window into a compact outline (v2).
     *
     * - INTERACTIVE elements (clickable/editable/scrollable) get a stable
     *   numeric ref [n], valid until the next read: `act tap ref:n`
     *   addresses them without label collisions.
     * - Interactive entries carry viewport bounds; off-screen ones are
     *   marked [off-screen ↑↓←→].
     * - Static text is included trimmed, without refs/geometry.
     * - Entries sorted by on-screen position (top, then left): visual order.
     * - Identical outlines short-circuit to UNCHANGED unless full=true.
     * - probe=true returns ONLY whether the screen changed since the last
     *   read, without updating the stored snapshot (effect check).
     */
    fun readScreen(
        maxNodes: Int = 300,
        maxDepth: Int = 15,
        maxChars: Int = MAX_OUTLINE_CHARS,
        full: Boolean = false,
        probe: Boolean = false,
    ): Map<String, Any?> {
        val root = rootInActiveWindow
            ?: return mapOf(
                "ok" to false,
                "error" to "NO_WINDOW",
                "message" to "No active window content available. The foreground app may not expose semantics.",
            )
        try {
            val pkg = root.packageName?.toString() ?: "unknown"
            if (isRestrictedApp(this, pkg)) {
                return mapOf(
                    "ok" to false,
                    "error" to "RESTRICTED_APP_REFUSED",
                    "package" to pkg,
                    "message" to "Errand strictly refuses to inspect or interact with sensitive/financial app: $pkg",
                )
            }
            val dm = resources.displayMetrics
            val viewportW = dm.widthPixels
            val viewportH = dm.heightPixels
            val entries = mutableListOf<Entry>()
            var visited = 0
            activeTab = null // per-read scratch; see visitNode
            overlayCandidateFound = null
            val truncated = try {
                visitNode(root, 0, maxDepth, maxChars, entries) { visited++ < maxNodes }
            } catch (_: Exception) {
                // Stale tree mid-walk: keep whatever we collected.
                true
            }
            // Visual reading order, not tree order.
            entries.sortWith(compareBy({ it.bounds.top }, { it.bounds.left }))
            val refs = mutableMapOf<Int, RefEntry>()
            val body = StringBuilder()
            var refCounter = 0
            var charsUsed = 0
            for (e in entries) {
                val line: String
                if (e.interactive) {
                    refCounter++
                    refs[refCounter] = RefEntry(label = e.label, cls = e.cls, rect = e.bounds)
                    val off = offScreenTag(e.bounds, viewportW, viewportH)
                    val pos = off ?: "@${e.bounds.left},${e.bounds.top} ${e.bounds.width()}x${e.bounds.height()}"
                    line = "[$refCounter] ${e.cls}" +
                        (e.vid?.let { " id=$it" } ?: "") +
                        (e.label?.let { " \"$it\"" } ?: "") +
                        (if (e.flags.isEmpty()) "" else " [${e.flags.joinToString(",")}]") +
                        " $pos"
                } else {
                    line = "${e.cls}" +
                        (e.label?.let { " \"$it\"" } ?: "") +
                        (if (e.flags.isEmpty()) "" else " [${e.flags.joinToString(",")}]")
                }
                if (charsUsed + line.length > maxChars) break
                charsUsed += line.length + 1
                body.append(line).append('\n')
            }
            elementRefs = refs
            val tab = activeTab
            val wins = try { windows } catch (_: Exception) { emptyList() }
            val focusedTitle = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                wins.firstOrNull { it.isFocused }?.getTitle()?.toString()?.takeIf { it.isNotBlank() }
            } else null
            val header = "Screen: package=$pkg" +
                (tab?.let { "  active-tab=\"$it\"" } ?: "") +
                (if (wins.size > 1) "  windows=${wins.size}" else "") +
                (focusedTitle?.let { "  focused-window=\"$it\"" } ?: "") +
                "  viewport=${viewportW}x${viewportH}\n" +
                (overlayCandidateFound?.let {
                    "WARN possible OVERLAY covering screen: $it -- taps may be swallowed; route around or ask the user.\n"
                } ?: "")
            val outlineText = header + body
            // Probe mode: effect check only. Does NOT update the stored snapshot,
            // so a subsequent real read still diffs against the pre-action state.
            if (probe) {
                return mapOf("ok" to true, "changed" to (outlineText != lastOutline))
            }
            // Verification re-reads are the biggest token sink: if nothing changed
            // since the previous read, say so in one line instead of re-dumping.
            val unchanged = !full && lastOutline == outlineText
            lastOutline = outlineText
            if (unchanged) {
                return mapOf(
                    "ok" to true,
                    "unchanged" to true,
                    "package" to pkg,
                    "message" to "Screen is UNCHANGED since your previous read -- everything " +
                        "reported earlier still applies. Pass full:true only if you believe " +
                        "this snapshot is stale.",
                )
            }
            val charCapHit = truncated || charsUsed >= maxChars
            val nodeCapHit = truncated && !charCapHit && visited >= maxNodes
            return mapOf(
                "ok" to true,
                "package" to pkg,
                "outline" to outlineText,
                "nodes" to visited,
                "maxNodes" to maxNodes,
                "charsUsed" to charsUsed,
                "maxChars" to maxChars,
                "elements" to refCounter,
                "capHit" to when {
                    charCapHit -> "chars"
                    nodeCapHit -> "nodes"
                    else -> null
                },
                "truncated" to truncated,
            )
        } finally {
            recycleQuietly(root)
        }
    }

    /**
     * Word-boundary trim so long labels (mail snippets, list items) don't
     * cut mid-word like "Confirm your ema". Marks the cut with an ellipsis.
     */
    private fun trimLabel(raw: String, maxLen: Int = 120): String {
        // Apps like Gmail glue list fields into one contentDescription with
        // empty segments (", , , Spotify, , subject…") — collapse those gaps.
        val s = raw.replace('\n', ' ')
            .replace(Regex(",(\\s*,)+"), ",")
            .replace(Regex("\\s{2,}"), " ")
            .trim()
            .trim(',')
            .trim()
        if (s.length <= maxLen) return s
        val cut = s.lastIndexOf(' ', maxLen)
        return (if (cut > maxLen / 2) s.substring(0, cut) else s.substring(0, maxLen)) + "…"
    }

    /** Per-read scratch: first selected node's label seen during the walk. */
    private var activeTab: String? = null

    /**
     * Captured when the system creates our restricted input-method role
     * (API 33+, requires FLAG_INPUT_METHOD_EDITOR). Null until then.
     */
    private var inputMethod: InputMethod? = null

    override fun onCreateInputMethod(): InputMethod {
        val im = super.onCreateInputMethod()
        inputMethod = im
        return im
    }

    /**
     * Class name of a fullscreen-ish clickable view seen above content --
     * the consent-wall / modal-backdrop tell. Surfaced as an overlay warning
     * in the outline header.
     */
    private var overlayCandidateFound: String? = null

    /**
     * Numeric refs -> element identity, rebuilt on every non-probe read.
     * `act tap ref:n` resolves through this map by matching (bounds, class,
     * label) against the live tree.
     */
    private var elementRefs: Map<Int, RefEntry> = emptyMap()

    private data class RefEntry(val label: String?, val cls: String, val rect: Rect)

    private data class Entry(
        val bounds: Rect,
        val cls: String,
        val vid: String?,
        val label: String?,
        val flags: List<String>,
        val interactive: Boolean,
    )

    private data class TapCandidate(
        val node: AccessibilityNodeInfo,
        val score: Int,
        val text: String,
        val bounds: Rect,
    )

    /**
     * Previous read's outline text. Identical consecutive reads return
     * UNCHANGED instead of re-dumping — verification re-reads were the
     * biggest token sink in long screen flows.
     */
    private var lastOutline: String? = null

    /**
     * Collects one structured entry per emitted node. Sorting (visual order)
     * and numeric ref assignment happen in [readScreen].
     */
    private fun visitNode(
        node: AccessibilityNodeInfo,
        depth: Int,
        maxDepth: Int,
        maxChars: Int,
        entries: MutableList<Entry>,
        budget: () -> Boolean,
    ): Boolean {
        val bounds = try {
            Rect().also { node.getBoundsInScreen(it) }
        } catch (_: Exception) {
            return false
        }
        if (depth > maxDepth) return false
        if (charsCollected(entries) >= maxChars || !budget()) {
            return true
        }
        val cls = node.className?.toString()?.substringAfterLast('.') ?: "View"
        val vid = node.viewIdResourceName
            ?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
        val label = node.text?.toString()?.let(::trimLabel)?.ifBlank { null }
            ?: node.contentDescription?.toString()?.let(::trimLabel)?.ifBlank { null }
            ?: node.hintText?.toString()?.let(::trimLabel)?.ifBlank { null }
        if (node.isSelected && activeTab == null) {
            activeTab = label ?: cls
        }
        val clickable = node.isClickable
        val interactive = clickable || node.isEditable || node.isScrollable
        // Fullscreen-ish clickable above content: the consent-wall /
        // modal-backdrop tell. Scroll/list container classes are excluded --
        // a full-screen RecyclerView is a normal feed, not an overlay.
        val isContainerClass = cls in setOf(
            "RecyclerView", "ListView", "GridView", "ViewPager",
            "ScrollView", "NestedScrollView", "ViewPager2",
        )
        if (clickable && !isContainerClass &&
            bounds.width() >= viewportW() * 0.9 &&
            bounds.height() >= viewportH() * 0.6
        ) {
            overlayCandidateFound = overlayCandidateFound ?: cls
        }
        val flags = buildList {
            if (clickable) add("clickable")
            if (node.isEditable) add("editable")
            if (node.isChecked) add("checked")
            if (node.isSelected) add("selected")
            if (node.isScrollable) add("scrollable")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Material switches report On/Off here instead of isChecked.
                node.stateDescription?.toString()?.trim()
                    ?.takeIf { it.isNotBlank() }
                    ?.let { add("state=$it") }
            }
            node.collectionItemInfo?.let { ci ->
                if (ci.rowIndex >= 0) add("row=${ci.rowIndex}")
            }
        }
        if (!node.isVisibleToUser && label == null && !interactive) {
            // Skip invisible structural nodes; keep labeled or actionable ones.
        } else {
            entries.add(
                Entry(
                    bounds = bounds,
                    cls = cls,
                    vid = vid,
                    label = label,
                    flags = flags,
                    interactive = interactive,
                )
            )
        }
        val childCount = try { node.childCount } catch (_: Exception) { return false }
        for (i in 0 until childCount) {
            val child = try { node.getChild(i) } catch (_: Exception) { null } ?: continue
            val cut = visitNode(child, depth + 1, maxDepth, maxChars, entries, budget)
            recycleQuietly(child)
            if (cut) return true
        }
        return false
    }

    private fun viewportW(): Int = resources.displayMetrics.widthPixels
    private fun viewportH(): Int = resources.displayMetrics.heightPixels

    private fun charsCollected(entries: MutableList<Entry>): Int =
        entries.sumOf { it.cls.length + (it.label?.length ?: 0) + 24 }

    private fun offScreenTag(b: Rect, vw: Int, vh: Int): String? = when {
        b.bottom <= 0 -> "[off-screen above]"
        b.top >= vh -> "[off-screen below]"
        b.right <= 0 -> "[off-screen left]"
        b.left >= vw -> "[off-screen right]"
        else -> null
    }

    private fun recycleQuietly(node: AccessibilityNodeInfo?) {
        if (node == null) return
        try {
            node.recycle()
        } catch (_: Exception) {
        }
    }

    /**
     * Draft-policy commit-word match. Same split rules as tapByRef so Dart
     * and native stay aligned. Returns the matched token, or null.
     */
    private fun commitMatch(label: String?): String? {
        if (label == null) return null
        val words = label.lowercase().split(Regex("[^a-z-]+")).filter { it.isNotEmpty() }
        return words.firstOrNull { it in COMMIT_WORDS || it.split("-").any(COMMIT_WORDS::contains) }
    }

    private fun rectClose(a: Rect, b: Rect, slop: Int): Boolean =
        abs(a.left - b.left) <= slop &&
            abs(a.top - b.top) <= slop &&
            abs(a.right - b.right) <= slop &&
            abs(a.bottom - b.bottom) <= slop

    /**
     * Resolves a numeric ref from the last read against the LIVE tree by
     * matching (bounds, class, label). Exact bounds win; otherwise the
     * closest node within [REF_BOUNDS_SLOP_PX] (keyboard / inset jitter).
     * Returns an obtained node, or null when the screen changed too much.
     */
    private fun findNodeByRef(
        node: AccessibilityNodeInfo,
        ref: RefEntry,
    ): AccessibilityNodeInfo? {
        var best: AccessibilityNodeInfo? = null
        var bestDist = Int.MAX_VALUE
        var exact = false

        fun consider(candidate: AccessibilityNodeInfo, b: Rect) {
            val sameCls = candidate.className?.toString()?.substringAfterLast('.') == ref.cls
            if (!sameCls) return
            val l = nodeLabel(candidate)?.let(::trimLabel)
            if (ref.label != null && l != ref.label) return
            if (b == ref.rect) {
                recycleQuietly(best)
                best = AccessibilityNodeInfo.obtain(candidate)
                bestDist = 0
                exact = true
                return
            }
            if (exact) return
            if (!rectClose(b, ref.rect, REF_BOUNDS_SLOP_PX)) return
            val dist = abs(b.centerX() - ref.rect.centerX()) + abs(b.centerY() - ref.rect.centerY())
            if (dist < bestDist) {
                recycleQuietly(best)
                best = AccessibilityNodeInfo.obtain(candidate)
                bestDist = dist
            }
        }

        fun walk(n: AccessibilityNodeInfo, depth: Int): Boolean {
            if (exact || depth > MAX_REF_DEPTH) return exact
            try {
                val b = Rect().also { n.getBoundsInScreen(it) }
                consider(n, b)
                if (exact) return true
                val childCount = n.childCount
                for (i in 0 until childCount) {
                    val child = n.getChild(i) ?: continue
                    val found = walk(child, depth + 1)
                    recycleQuietly(child)
                    if (found) return true
                }
            } catch (_: Exception) {
                // Stale node — skip this subtree.
            }
            return exact
        }

        walk(node, 0)
        return best
    }

    /** Long-click variant of [tapByRef]. */
    fun longPressByRef(ref: Int): Map<String, Any?> = tapByRef(ref, longClick = true)

    /**
     * Taps (or long-clicks) the element addressed by a numeric ref from the
     * last read. Honest failure when the ref is stale.
     *
     * Draft-policy note: refs bypass act_tool.dart's Dart-side label refusal,
     * so the same commit-word guard is mirrored here. Keep the word list in
     * sync with kCommitWords in lib/tools/act_tool.dart.
     */
    fun tapByRef(ref: Int, longClick: Boolean = false): Map<String, Any?> {
        val root = rootInActiveWindow
            ?: return mapOf("ok" to false, "error" to "NO_WINDOW",
                "message" to "No active window content available.")
        try {
            val pkg = root.packageName?.toString() ?: "unknown"
            if (isRestrictedApp(this, pkg)) {
                return mapOf(
                    "ok" to false,
                    "error" to "RESTRICTED_APP_REFUSED",
                    "package" to pkg,
                    "message" to "Errand strictly refuses to interact with sensitive/financial app: $pkg",
                )
            }
            val entry = elementRefs[ref]
                ?: return mapOf("ok" to false, "error" to "STALE_REF",
                    "message" to "Ref $ref is not known. Re-read the screen; refs are renumbered on every read.")
            if (!longClick) {
                val matched = commitMatch(entry.label)
                if (matched != null) {
                    return mapOf("ok" to false, "error" to "COMMIT_REFUSAL",
                        "message" to "Refusing to tap [$ref] \"${entry.label?.lowercase()}\" -- matches commit pattern \"$matched\". " +
                            "Draft policy: Errand prepares, the USER presses Send/Confirm/Pay/etc.")
                }
            }
            val target = findNodeByRef(root, entry)
                ?: return mapOf("ok" to false, "error" to "STALE_REF",
                    "message" to "Element [$ref] (\"${entry.label ?: entry.cls}\") is no longer at its position -- the screen changed. Re-read first.")
            val touched = mutableListOf(target)
            var t: AccessibilityNodeInfo = target
            var hops = 0
            while (!t.isClickable && hops < MAX_TAP_HOPS) {
                val parent = t.parent ?: break
                touched.add(parent)
                t = parent
                hops++
            }
            val action = if (longClick) AccessibilityNodeInfo.ACTION_LONG_CLICK
            else AccessibilityNodeInfo.ACTION_CLICK
            val ok = t.isClickable && t.performAction(action)
            touched.forEach { recycleQuietly(it) }
            return if (ok) {
                mapOf("ok" to true,
                    "message" to (if (longClick) "Long-pressed" else "Tapped") +
                        " [$ref] \"${entry.label ?: entry.cls}\"")
            } else {
                mapOf("ok" to false, "error" to "CLICK_FAILED",
                    "message" to "Element [$ref] found but refused the click. Some apps only respond to taps on the parent row -- try tapping a sibling label instead.")
            }
        } finally {
            recycleQuietly(root)
        }
    }

    /** Sends Escape through the focused field's input connection. */
    fun imeSendEscape(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return mapOf("ok" to false, "error" to "NEEDS_API_33",
                "message" to "Escape needs Android 13+.")
        }
        val conn = imeReady()
            ?: return mapOf("ok" to false, "error" to "NO_INPUT_FOCUS",
                "message" to "Escape needs a focused field to deliver the key. Try global back instead.")
        conn.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ESCAPE))
        conn.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ESCAPE))
        return mapOf("ok" to true, "message" to "Sent Escape.")
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
            "return_to_errand" -> {
                val intent = Intent(this, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                }
                startActivity(intent)
                return null
            }
            else -> return "Unknown global action '$name'"
        }
        return if (performGlobalAction(action)) null else "Global action '$name' failed"
    }

    // ---- P2b: gated injection (Draft mode primitives) -----------------------
    //
    // Deliberately narrow: semantic targets only (label text from the screen
    // outline the agent already read), never raw coordinates. The commit-control
    // refusal is mirrored here (not only in act_tool.dart) so refs AND labels
    // cannot bypass Draft policy.

    /** Returns {ok, label?, error?, message?}. */
    fun tapByText(label: String, exact: Boolean, occurrence: Int = 1): Map<String, Any?> {
        val root = rootInActiveWindow
            ?: return mapOf("ok" to false, "error" to "NO_WINDOW",
                "message" to "No active window content available.")

        val pkg = root.packageName?.toString() ?: "unknown"
        if (isRestrictedApp(this, pkg)) {
            recycleQuietly(root)
            return mapOf(
                "ok" to false,
                "error" to "RESTRICTED_APP_REFUSED",
                "package" to pkg,
                "message" to "Errand strictly refuses to interact with sensitive/financial app: $pkg",
            )
        }

        val needle = label.trim().lowercase()
        if (needle.isEmpty()) {
            recycleQuietly(root)
            return mapOf("ok" to false, "error" to "EMPTY_LABEL",
                "message" to "Tap target label was empty.")
        }
        try {
            val candidates = mutableListOf<TapCandidate>()
            collectMatchingClickable(root, needle, exact, candidates)
            // Identical labels are common in list UIs (five alarms, five "Off"
            // switches) — [occurrence] is the 1-based index WITHIN the
            // best-scoring pool, matching the outline's top-to-bottom order.
            val bestScore = candidates.maxOfOrNull { it.score }
            if (bestScore == null) {
                candidates.forEach { recycleQuietly(it.node) }
                return mapOf("ok" to false, "error" to "NOT_FOUND",
                    "message" to "No clickable element matching \"$label\" on the current screen. " +
                        "Re-read the screen and use the exact label.")
            }
            val pool = candidates.filter { it.score == bestScore }
                .sortedWith(compareBy({ it.bounds.top }, { it.bounds.left }))
            if (occurrence !in 1..pool.size) {
                val msg = "Found ${pool.size} match(es) for \"$label\"; occurrence " +
                    "$occurrence is out of range (1-${pool.size})."
                candidates.forEach { recycleQuietly(it.node) }
                return mapOf("ok" to false, "error" to "OCCURRENCE_OUT_OF_RANGE",
                    "message" to msg)
            }
            val picked = pool[occurrence - 1]
            val clickedText = picked.text
            val matched = commitMatch(clickedText)
            if (matched != null) {
                candidates.forEach { recycleQuietly(it.node) }
                return mapOf("ok" to false, "error" to "COMMIT_REFUSAL",
                    "message" to "Refusing to tap \"$clickedText\" -- matches commit pattern \"$matched\". " +
                        "Draft policy: Errand prepares, the USER presses Send/Confirm/Pay/etc.")
            }
            // Track every node instance we touch so each is recycled exactly once.
            val touched = mutableListOf(picked.node)
            var target: AccessibilityNodeInfo = picked.node
            var hops = 0
            while (!target.isClickable && hops < MAX_TAP_HOPS) {
                val parent = target.parent ?: break
                touched.add(parent)
                target = parent
                hops++
            }
            val ok = target.isClickable && target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            touched.forEach { recycleQuietly(it) }
            candidates.forEach { if (it !== picked) recycleQuietly(it.node) }
            val which = if (pool.size > 1) " (match $occurrence of ${pool.size})" else ""
            return if (ok) {
                mapOf("ok" to true, "label" to clickedText,
                    "message" to "Tapped \"$clickedText\"$which")
            } else {
                mapOf("ok" to false, "error" to "CLICK_FAILED",
                    "message" to "Found \"$clickedText\" but could not click it. Some apps " +
                        "only respond to taps on the parent ROW — try tapping the row's " +
                        "title/time label instead of the control itself.")
            }
        } finally {
            recycleQuietly(root)
        }
    }

    private fun nodeLabel(node: AccessibilityNodeInfo): String? =
        node.text?.toString()?.trim()?.ifBlank { null }
            ?: node.contentDescription?.toString()?.trim()?.ifBlank { null }
            // Web form fields often expose ONLY their placeholder as hint —
            // the reader shows hints, so the tapper must match them too.
            ?: node.hintText?.toString()?.trim()?.ifBlank { null }

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
        out: MutableList<TapCandidate>,
    ) {
        try {
            // Any labeled match is a candidate; tapByText() walks up to the nearest
            // clickable ancestor afterwards (labels often live on child TextViews).
            val label = nodeLabel(node)
            if (label != null) {
                matchScore(label, needle, exact)?.let { score ->
                    val bounds = Rect().also { node.getBoundsInScreen(it) }
                    out.add(TapCandidate(AccessibilityNodeInfo.obtain(node), score, label, bounds))
                }
            }
            val childCount = node.childCount
            for (i in 0 until childCount) {
                val child = node.getChild(i) ?: continue
                collectMatchingClickable(child, needle, exact, out)
                recycleQuietly(child)
            }
        } catch (_: Exception) {
            // Stale node — skip this subtree.
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
        try {
            val pkg = root.packageName?.toString() ?: "unknown"
            if (isRestrictedApp(this, pkg)) {
                return mapOf(
                    "ok" to false,
                    "error" to "RESTRICTED_APP_REFUSED",
                    "package" to pkg,
                    "message" to "Errand strictly refuses to interact with sensitive/financial app: $pkg",
                )
            }
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
                recycleQuietly(focus)
            }
        } finally {
            recycleQuietly(root)
        }
    }

    /**
     * Scrolls [times] times (1..30); falls back to a center-screen swipe
     * gesture when no scrollable node exposes actions (custom views).
     * [down] = scroll toward later content.
     *
     * Targeting: with [nearLabel], only scrollables whose subtree contains
     * that text are considered — this is how the agent picks the MINUTE wheel
     * instead of the hour one, or the alarm list instead of a ViewPager page.
     *
     * End-of-list signal: a scrollable supporting only the OPPOSITE action
     * means we're at the end in the requested direction — reported as
     * at_end instead of dispatching blind scrolls.
     */
    fun scroll(
        direction: String,
        times: Int = 1,
        nearLabel: String? = null,
    ): Map<String, Any?> {
        when (direction) {
            "up", "down", "left", "right" -> Unit
            else -> return mapOf(
                "ok" to false,
                "error" to "BAD_DIRECTION",
                "message" to "direction must be up, down, left, or right.",
            )
        }
        val root = rootInActiveWindow
            ?: return mapOf("ok" to false, "error" to "NO_WINDOW",
                "message" to "No active window content available.")
        try {
            val pkg = root.packageName?.toString() ?: "unknown"
            if (isRestrictedApp(this, pkg)) {
                return mapOf(
                    "ok" to false,
                    "error" to "RESTRICTED_APP_REFUSED",
                    "package" to pkg,
                    "message" to "Errand strictly refuses to interact with sensitive/financial app: $pkg",
                )
            }
            val clamped = times.coerceIn(1, MAX_WHEEL_STEPS)
            // Vertical containers expose FORWARD/BACKWARD. Horizontal ones expose
            // SCROLL_LEFT/RIGHT on API 34+; older devices fall back to gestures.
            val targetAction = when {
                direction == "down" -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                direction == "up" -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                    direction == "left" ->
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                    direction == "right" ->
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id
                direction == "left" -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                else -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            }
            val oppositeAction = oppositeScrollAction(targetAction)
            // Near-label targeting: the needle must appear somewhere inside the
            // scrollable's subtree (e.g. "52" for the minutes wheel, "Ring once"
            // for the alarms list). Case-insensitive.
            val scrollable = nearLabel?.trim()?.takeIf { it.isNotEmpty() }?.let { needle ->
                findScrollableContaining(root, targetAction, needle.lowercase())
                    ?: return mapOf(
                        "ok" to false,
                        "error" to "NO_TARGET_SCROLLABLE",
                        "message" to "No scrollable area containing \"$nearLabel\" found. " +
                            "Re-read the screen; the label must be currently visible.",
                    )
            } ?: run {
                findScrollable(root, targetAction)
                    ?: oppositeAction?.let { opp ->
                        findScrollable(root, opp)?.let {
                            recycleQuietly(it)
                            return mapOf("ok" to true, "at_end" to true, "method" to "node_action",
                                "message" to "Already at the END of this direction ($direction) -- nothing further that way.")
                        }
                    }
                    ?: return gestureFallbackScroll(direction)
            }
            scrollable.let { s ->
                try {
                    var done = 0
                    repeat(clamped) {
                        if (s.performAction(targetAction)) done++
                    }
                    if (done > 0) {
                        return mapOf("ok" to true, "method" to "node_action", "scrolled" to done,
                            "message" to "Scrolled $direction ×$done" +
                                (if (nearLabel != null) " (targeted by \"$nearLabel\")" else ""))
                    }
                } finally {
                    recycleQuietly(s)
                }
            }
            return gestureFallbackScroll(direction)
        } finally {
            recycleQuietly(root)
        }
    }

    /** Opposite scroll action, or null when we cannot name one. */
    private fun oppositeScrollAction(actionId: Int): Int? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            when (actionId) {
                AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id ->
                    return AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id
                AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id ->
                    return AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id
            }
        }
        return when (actionId) {
            AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            else -> null
        }
    }

    private fun gestureFallbackScroll(direction: String): Map<String, Any?> =
        when {
            direction == "left" && swipeHorizontal(right = false) ->
                mapOf("ok" to true, "method" to "gesture", "message" to "Swiped right-to-left")
            direction == "right" && swipeHorizontal(right = true) ->
                mapOf("ok" to true, "method" to "gesture", "message" to "Swiped left-to-right")
            direction == "down" && swipeCenter(scrollDown = true) ->
                mapOf("ok" to true, "method" to "gesture", "message" to "Swiped up (scroll down)")
            direction == "up" && swipeCenter(scrollDown = false) ->
                mapOf("ok" to true, "method" to "gesture", "message" to "Swiped down (scroll up)")
            else -> mapOf("ok" to false, "error" to "SCROLL_FAILED",
                "message" to "Nothing scrollable found and gesture dispatch failed.")
        }

    /** First visible scrollable node whose actionList contains [actionId]. */
    private fun findScrollable(
        node: AccessibilityNodeInfo,
        actionId: Int,
    ): AccessibilityNodeInfo? {
        try {
            if (node.isScrollable && node.isVisibleToUser &&
                node.actionList.any { it.id == actionId }
            ) {
                return AccessibilityNodeInfo.obtain(node)
            }
            val childCount = node.childCount
            for (i in 0 until childCount) {
                val child = node.getChild(i) ?: continue
                val found = findScrollable(child, actionId)
                recycleQuietly(child)
                if (found != null) return found
            }
        } catch (_: Exception) {
            // Stale node — skip this subtree.
        }
        return null
    }

    /** Like [findScrollable], but the node's subtree must contain [needle]. */
    private fun findScrollableContaining(
        node: AccessibilityNodeInfo,
        actionId: Int,
        needle: String,
        depth: Int = 0,
    ): AccessibilityNodeInfo? {
        if (depth >= 12) return null
        try {
            if (node.isScrollable && node.isVisibleToUser &&
                node.actionList.any { it.id == actionId } &&
                subtreeContainsText(node, needle)
            ) {
                return AccessibilityNodeInfo.obtain(node)
            }
            val childCount = node.childCount
            for (i in 0 until childCount) {
                val child = node.getChild(i) ?: continue
                val found = findScrollableContaining(child, actionId, needle, depth + 1)
                recycleQuietly(child)
                if (found != null) return found
            }
        } catch (_: Exception) {
            // Stale node — skip this subtree.
        }
        return null
    }

    private fun subtreeContainsText(
        node: AccessibilityNodeInfo,
        needle: String,
        depth: Int = 0,
    ): Boolean {
        if (depth >= 12) return false
        try {
            node.text?.toString()?.lowercase()?.contains(needle)?.let { if (it) return true }
            node.contentDescription?.toString()?.lowercase()?.contains(needle)?.let { if (it) return true }
            val childCount = node.childCount
            for (i in 0 until childCount) {
                val child = node.getChild(i) ?: continue
                val found = subtreeContainsText(child, needle, depth + 1)
                recycleQuietly(child)
                if (found) return true
            }
        } catch (_: Exception) {
            return false
        }
        return false
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

    /** Horizontal swipe for carousels: [right]=move toward later content. */
    private fun swipeHorizontal(right: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        val m = resources.displayMetrics
        val y = (m.heightPixels / 2f)
        val leftX = m.widthPixels * 0.75f
        val rightX = m.widthPixels * 0.25f
        val path = Path().apply {
            moveTo(if (right) leftX else rightX, y)
            lineTo(if (right) rightX else leftX, y)
        }
        val gesture = android.accessibilityservice.GestureDescription.Builder()
            .addStroke(
                android.accessibilityservice.GestureDescription.StrokeDescription(path, 0, 250))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    // ---- P2b+: IME-mode text primitives (API 33+) ---------------------------
    //
    // With FLAG_INPUT_METHOD_EDITOR the service becomes a restricted input
    // method: it gets an InputConnection to the FOCUSED field even when that
    // field doesn't support ACTION_SET_TEXT (common in web inputs), plus
    // honest read-back of field contents via getSurroundingText.

    private fun imeReady(): InputMethod.AccessibilityInputConnection? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        val im = inputMethod ?: getInputMethod() ?: return null
        if (!im.currentInputStarted) return null
        return im.currentInputConnection
    }

    /** Recycle-safe: true if the focused node is a password field. */
    private fun focusedIsPassword(): Boolean {
        val root = rootInActiveWindow ?: return false
        try {
            val focus = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
            try {
                return focus.isPassword
            } finally {
                recycleQuietly(focus)
            }
        } catch (_: Exception) {
            return false
        } finally {
            recycleQuietly(root)
        }
    }

    /**
     * Identity + content of the currently focused editable field. This is
     * the verification primitive: it answers "what field is focused and what
     * does it contain" without trusting any screen rendering.
     */
    fun imeFieldInfo(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return mapOf("ok" to false, "error" to "NEEDS_API_33",
                "message" to "Field introspection needs Android 13+.")
        }
        val conn = imeReady()
            ?: return mapOf("ok" to false, "error" to "NO_INPUT_FOCUS",
                "message" to "No focused editable field. Tap the field first (act tap).")
        val editor: EditorInfo? = inputMethod?.currentInputEditorInfo
        val surrounding = try {
            conn.getSurroundingText(2048, 2048, 0)
        } catch (_: Exception) { null }
        val content = surrounding?.text?.toString()
        return mapOf(
            "ok" to true,
            "fieldId" to editor?.fieldId,
            "hint" to editor?.hintText?.toString(),
            "content" to (content ?: ""),
            "message" to ("Focused field contains ${content?.length ?: 0} chars." +
                (editor?.hintText?.let { " Hint: $it." } ?: "")),
        )
    }

    /**
     * Types [text] into the focused field via IME commit — works on web
     * inputs where ACTION_SET_TEXT is refused. [replaceAll] selects the
     * existing content first; otherwise text is inserted at the cursor.
     * Returns the post-write field content for verification.
     * Password fields are refused (same policy as [typeText]).
     */
    fun imeCommit(text: String, replaceAll: Boolean): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return mapOf("ok" to false, "error" to "NEEDS_API_33",
                "message" to "IME typing needs Android 13+.")
        }
        val conn = imeReady()
            ?: return mapOf("ok" to false, "error" to "NO_INPUT_FOCUS",
                "message" to "No focused editable field. Tap the field first (act tap).")
        if (focusedIsPassword()) {
            return mapOf("ok" to false, "error" to "PASSWORD_FIELD",
                "message" to "Refusing to type into a password field.")
        }
        if (replaceAll) {
            val st = try {
                conn.getSurroundingText(4096, 4096, 0)
            } catch (_: Exception) { null }
            val len = st?.text?.length ?: 0
            if (len > 0) conn.setSelection(0, len)
        }
        conn.commitText(text, 1, null)
        val after = try {
            conn.getSurroundingText(4096, 4096, 0)?.text?.toString() ?: ""
        } catch (_: Exception) { "" }
        return mapOf("ok" to true, "content" to after,
            "message" to "Committed ${text.length} chars via IME. Field now contains " +
                "${after.length} chars.")
    }

    /** Sends Tab through the focused field's input connection (field hop). */
    fun imeSendTab(): Map<String, Any?> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return mapOf("ok" to false, "error" to "NEEDS_API_33",
                "message" to "Tab hop needs Android 13+.")
        }
        val conn = imeReady()
            ?: return mapOf("ok" to false, "error" to "NO_INPUT_FOCUS",
                "message" to "No focused editable field to Tab from. Tap a field first.")
        conn.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_TAB))
        conn.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_TAB))
        return mapOf("ok" to true,
            "message" to "Sent Tab — focus should move to the next field.")
    }
}
