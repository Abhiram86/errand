# Next Plan — Status & Roadmap

> **Updated Sep 2026.** P0 through P11 are shipped. The current codebase is schema v8. `flutter analyze` reports no Dart issues, all 569 tests pass, and Android lint currently fails with four API-level errors plus non-blocking warnings.
> **Active Milestone:** **P12 — Reliability, lifecycle, security, and performance hardening**. P6b browser PlatformView work remains queued behind P12.

---

## 🧭 Active & Upcoming Roadmap

### 🟡 P6b — Browser Rough Edges & Android PlatformView Optimizations (QUEUED)

Goal: Smooth out transitions, eliminate PlatformView reparenting, and decouple Android window insets from embedded web rendering.

---

### ✅ P7 — Android Home Screen Voice Widget & Audio-Reactive Composer (SHIPPED)

Goal: Provide 1-tap instant voice prompt access from the phone home screen.

1. **Native Android Home Screen AppWidget (`VoiceWidgetProvider`):** (SHIPPED)
   - Standard Android `AppWidgetProvider` using `RemoteViews` with zero added third-party Flutter dependencies.
   - Dark/glassmorphism pill layout with Errand logo and Mic button.
   - PendingIntent targeting `MainActivity` with action `com.errand.ACTION_VOICE_PROMPT`.
   - On app launch/resume with the voice action flag, auto-initializes `SpeechService` and activates listening without requiring extra user taps. Fully functional across Full and Lite flavors.

2. **Audio-Reactive Composer Glow:** (SHIPPED in ab6d990)
   - Live sound level stream in `SpeechService` via `SpeechListenOptions(onSoundLevelChange: ...)`.
   - Dynamic `ChatComposer` border glow spread, opacity, and sweep gradient in real time according to vocal RMS amplitude.
   - Lightweight linear interpolation (`lerpDouble`) to eliminate jitter and prevent battery drain by constraining rebuilds only during active voice sessions.

3. **ChatGPT Full-Width Layout & Clamped Markdown Tables:** (SHIPPED in 0f2cd4f)
   - Transparent, full-width assistant message layout for clean reading of code blocks and tables.
   - `_buildClampedTable` custom `tableBuilder` enforcing cell `maxWidth: 220`, `maxLines: 4`, ellipsis overflow, tooltip preview, and horizontal scrolling with `Scrollbar`.
   - Row-by-row streaming buffer in `_handleTextDelta` that suppresses partial unclosed table row re-renders and flushes on `\n` to prevent table UI jitter.

---

### ✅ P8 — Device Location Access & Context Awareness (SHIPPED in ab6d990)

Goal: Give the agent access to user coordinates and reverse-geocoded address via native Android APIs, solving the bash permission boundary.

1. **Permissions & Native Channel:** (SHIPPED)
   - Declared `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION` in `AndroidManifest.xml`.
   - Native MethodChannel in `MainActivity.kt` using Android's `LocationManager` and `Geocoder.getFromLocation()` for reverse geocoding (city, country, address).
2. **Tool Strategy & Context Digest:** (SHIPPED)
   - Dedicated `location` tool (`get_coordinates`, `get_address`) for explicit on-demand location queries.
   - Passive system prompt digest (coarse locality: City, Country) injected on turn start so local questions (weather, local queries) resolve without extra tool roundtrips.

---

### ✅ P9 — Autonomous Scheduler & Headless Background Engine (SHIPPED in v0.7.0)

Goal: Enable the model to schedule one-off and recurring tasks that execute autonomously in the background and dispatch native Android notifications, with full parity across Full and Lite flavors.

#### 1. Schema & Foundation (SHIPPED)
- **Database Schema v7 (`ErrandDatabase`):**
  - `SchedulerTasks`: `id`, `title`, `type` (`one_off`/`recurring`), `status` (`scheduled`, `paused`, `running`, `completed`, `failed`, `cancelled`), `payload_json`, `starts_at`, `next_run_at`, `repeat_after` (interval in millis), `timezone`, `notify` (boolean), `last_run_at`, `total_runs`, `failures`, `retries_per_turn`, timestamps.
  - `SchedulerTaskLogs`: `id`, `scheduler_task_id` (FK with `ON DELETE CASCADE`), `scheduled_for`, `started_at`, `finished_at`, `status`, `no_attempts`, `error_message`, `output_file_path`, `summary`, `notification_sent`, `notification_seen`, timestamps.
- **`schedule_task` Tool:**
  - Standardized on `action` discriminator (`create`, `edit`, `delete`, `get`, `list`, `logs`).
  - Uses exact `starts_at` (ISO 8601 string or epoch millis) and `repeat_after` interval millis.
- **Native Android Notification Channel:**
  - MethodChannel in `MainActivity.kt` (`showNotification`, `cancelNotification`, `hasNotificationPermission`) with `BigTextStyle` and launch intent back to Errand.
  - Dart `NotificationService` wrapper.

#### 2. Headless Agent Runner Execution Slices (SHIPPED)

- **Slice 1: Tool Safety Guards for Headless Mode (COMPLETED)**
  - `bash`: `isHeadless: true`. Destructive operations needing confirmation (`rm -rf`, bulk deletions) fail fast with `headless_destructive_blocked`. Added bash arithmetic note (`echo \$((expr))`) in system prompt.
  - `schedule_task`: `isHeadless: true` and `currentTaskId`. Disallows `action: "create"` and `action: "delete"` with `headless_recursion_blocked`. Disallows editing other tasks outside `currentTaskId` with `headless_cross_task_edit_blocked`. Preserves `delay_seconds` alongside `starts_at` for relative time ease.
  - `memory`: `isHeadless: true`. Disallows background writes (`create`, `edit`) with `headless_memory_write_blocked`; allows introspection (`find`, `read`).
  - Unit tests verifying all guards in `test/headless_tool_guards_test.dart` and `test/schedule_task_tool_test.dart`.

- **Slice 2: Headless Browser Service & Tool (COMPLETED)**
  - `HeadlessBrowserService`: Subclasses `BrowserService` using `HeadlessInAppWebView`.
  - 1-to-1 feature parity (`open`, `close`, `reload`, `snapshot`, `extract_text`, `execute_dom_js`, `act`, `screenshot` offscreen).
  - Testable with mock/injected controller override to enable robust unit and integration tests.
  - Completely detached from the Flutter chat widget tree (no UI popping or dock bar animations).
  - Clean `dispose()` and `disposeHeadlessView()` on turn completion.
  - `browserTool`: Updated to accept `isHeadless: true` and instantiate `HeadlessBrowserService` automatically.

- **Slice 3: Headless System Prompt & ToolRegistry (COMPLETED)**
  - `headlessSystemPromptFor(...)`: Tailored prompt instructing the model it is running headlessly as a background task. Injects active execution context (task ID, title, workspace, scratch directory, user location). Enforces intent policy (alarms, timers, calendar entries allowed; UI app launches disallowed), output delivery to `.scratch/` (`task-$taskId.<ext>`), bash math advice (`echo \$((expr))`), and headless tool rules. Strictly excludes interactive screen automation prompts.
  - `ToolRegistry.headless(...)`: Factory constructor registering the headless toolset (`read`, `bash`, `websearch`, `webfetch`, `intent`, `location`, `memory`, `browser`, `schedule_task`). Strictly excludes `screen`, `screen_act`, `act`, and `attached_files`. Passes `isHeadless: true` to `bash`, `memory`, `browser`, and `schedule_task`. Binds `currentTaskId` to enforce task edit isolation.

- **Slice 4: Headless AgentRunner Integration & Lifecycle Hardening (COMPLETED)**
  - `AgentRunner.runHeadless(...)`: Executes an isolated, headless background agent turn for a scheduled task. Injects `ToolRegistry.headless`, binds `currentTaskId`, uses `headlessSystemPromptFor`, runs `AgentLoop` on a single-turn `Conversation`, saves the output report directly to `.scratch/task-$taskId.<ext>`, with automatic relocation fallback for rogue output files.
  - `TaskSchedulerService.executeTask(taskId, ...)`: Coordinates the full execution turn when an alarm fires:
    - **Allowlist Guard & Atomic Claim:** Restricts execution to `status: scheduled` (or `failed` for manual retry); uses conditional SQL update `WHERE id = ? AND status IN ('scheduled', 'failed')` to atomically transition to `running`, preventing double-fire races. Rejects already `running`, `completed`, `paused`, and `cancelled` tasks.
    - **Timeout & CancelToken:** Enforces execution timeout (`timeout`, default 10m) with `CancelToken` cancellation; logs `status: 'timeout'` on expiry.
    - **Resource Lifecycle:** Closes locally instantiated `LlmClient` instances in `finally` to prevent connection leaks.
    - **Resilient Recurring Retries:** Reschedules recurring tasks for `finishMillis + repeatAfter` on failure so transient glitches do not kill scheduled tasks, unless consecutive failures reach `retriesPerTurn`.
    - **Counter Reset:** Automatically resets `failures` to 0 upon successful execution.
    - **Bounded Notifications:** Safely clamps notification summary body to 250 characters before calling `NotificationService`.
    - **Recovery Sweep:** Provides `recoverStuckTasks()` to sweep and recover tasks left in `running` status after process kills or system crashes.

#### 3. Native Background Wake-Up & Task UI (SHIPPED)
- **Native AlarmManager Integration:**
  - `TaskAlarmManager.kt`: Native scheduling via Android `AlarmManager.setExactAndAllowWhileIdle()` across Full and Lite flavors.
  - `TaskExecutionService.kt`: Headless engine host service running background agent turns.
  - `TaskBootReceiver.kt`: `BOOT_COMPLETED` receiver to automatically reschedule active tasks on phone reboot.
  - Exact alarm permission guidance banner when exact scheduling is denied by OS.
- **Dedicated Manage Tasks Screen:**
  - Full-screen dashboard (`ManageTasksScreen` via `Navigator.push`), navigated from top of `ChatSidebar`.
  - Filterable by active, completed, failed, and unread tabs with page-size limit dropdown.
  - Inline model picker with persistence across recurring runs.
  - `TaskFilePreviewScreen` for in-app HTML and Markdown rendering of task outputs.
- **Task Toast Service:**
  - Global `TaskToastService` broadcasting create/edit/delete events across screens without prop drilling.

#### 4. v0.7.1 hardening (SHIPPED)
- **Runner-owned reports:** headless-only `save_report` tool + per-run `HeadlessReportCollector`; model supplies content, handler owns the sandboxed `task-<id>-<startedAt>[-<name>].<ext>` path (allowlist, 500KB cap, last-call-wins); final-answer fallback + keep-newest-10 pruning replace the old filesystem scavenging.
- **Per-task model/provider overrides** in the tool schema and payload, editable from the Manage Tasks sheet with settings-ready refresh.
- **Tappable chat links** (`onLinkTap`): http(s) opens externally, `file://`/bare local paths resolve sandboxed into in-app md/html preview or the system viewer.
- **Copy tables as Markdown+HTML**, compact unread banner, session-scoped storage footer, `AppProfile` debug/profile markers.

#### 5. v0.7.2 & v0.7.3 releases (SHIPPED)
- **v0.7.2:** Fixed stale task statuses via resume refresh, ghost notifications on task delete, cancel preservation during background runs, and atomic delete race safety.
- **v0.7.3:** Headless streaming runner with 5-attempt retry budget, drift-free anchor grid recurring scheduler (`start_at + N * repeat_after`), notify on fresh kill, borderless modern Manage Tasks UI, schema v8 query indexing, granular sub-minute countdown timers, and architectural decomposition into modular components (`lib/widgets/tasks/`, `model_picker_dialog.dart`, `browser_scripts.dart`, `intent_docs.dart`).

### 🟡 P10: Scheduler launch performance and lazy notification navigation

Goal: Make notification taps reach the unread task view quickly, without competing with app startup, settings loading, full scheduler rescheduling, or unbounded database reads.

1. **Measure the three launch paths first:**
   - Profile cold notification tap, warm notification tap, and normal app launch.
   - Record time from notification tap to Flutter engine start, first app frame, notification route push, first route frame, and first useful task row.
   - Validate on both small and large task/log histories.
   - Use profile (never debug) builds on a mid-range device, and set numeric targets (e.g. cold tap-to-first-row under 2 seconds) so the success criteria below are testable.

2. **Start the UI before nonessential startup work (DONE — deferred bootstrap after first frame):**
   - `runApp()` now runs before `AppSettingsService.ensureLoaded()`; stuck-task recovery and alarm rescheduling were later dropped from app launch entirely (native boot/package-update receiver owns restoration).
   - Move `runApp()` ahead of `AppSettingsService.ensureLoaded()` and `TaskSchedulerService.rescheduleAllActiveTasks()` in `lib/main.dart`.
   - Keep `TaskSchedulerService.initialize()` (cheap channel-handler setup, also needed by the background engine path) before `runApp`; defer only the heavy settings load and reschedule.
   - Render the app shell immediately and gate settings-dependent subtrees (theme, provider/model state) on a settings-ready future — the first frame must not assume settings are loaded.
   - Run settings loading, provider/model hydration, stuck-task recovery, and alarm rescheduling after the first visible frame.
   - Safe to defer: native alarms survive app-process death, so already-registered alarms cannot be lost while rescheduling waits. Still preserve reliable alarm recovery and never remove the boot receiver or native background execution path.

3. **Make notification routing single-shot and lightweight (DONE — platform initial-route deep link `/manage_tasks_unread?taskId=` with same-task dedup flags):**
   - Queue the native pending notification until the navigator is ready.
   - Treat the pending-intent lookup and live notification stream as one event source so one tap cannot push duplicate `ManageTasksScreen` routes.
   - Open directly into an unread-task loading state, then populate it as soon as the first query completes.

4. **Load only unread data for the first notification frame:**
   - Replace the initial unbounded task and log streams in `ManageTasksScreen` with a bounded query for the newest unread logs, ordered by `created_at` and limited to the first page.
   - Join those logs with the required task fields instead of loading every task and filtering in Dart.
   - Load more logs only when the user requests them.
   - Query unread counts separately if needed, rather than deriving them from the full log table.

5. **Lazy-load the other task tabs:**
   - Build the Unread tab first because notification taps start there.
   - Query Upcoming only when that tab is selected.
   - Query All Tasks and historical logs only when the user selects that tab.
   - Prefer one-shot queries with manual refresh over perpetual `watch()` streams on the lazy tabs; invalidate per tab using the existing `TaskToastService` broadcast (create/edit/delete events) instead of re-querying everything on every change.

6. **Add indexes for the screen’s actual queries (DONE — Schema v8):**
   - Bumped `schemaVersion` 7→8 with an `onUpgrade` path; added migration-backed indexes for `scheduler_task(created_at DESC)` and `scheduler_task_log(created_at DESC)`.
   - Added compound index for `scheduler_task_log(notification_seen, created_at DESC)` to support fast unread queries.

7. **Reduce rebuilds after the screen is visible (DONE — _TaskTimingInfo widget):**
   - Replaced the full-screen 1-second `setState()` timer with a focused `_TaskTimingInfo` StatefulWidget.
   - Ticks at 1-second granularity only for sub-60-second horizons; uses 15-second ticks beyond that; runs 0 ticks when paused/completed/cancelled.
   - Completely avoids rebuilding the app bar, tab labels, filters, search bar, and other task rows once per second.

8. **Optimize scheduler rescheduling separately:**
   - Keep rescheduling off the notification critical path.
   - Eliminate the redundant re-read: `scheduleTask(taskId)` re-fetches the row the reschedule query already holds — add a `scheduleTaskRow` overload taking the fetched row.
   - Avoid the current per-task database read followed by a separate native method-channel call where possible.
   - Consider one query that returns all scheduling data, followed by a native batch scheduling method if profiling shows startup contention with larger task sets.

9. **Use background isolates only when profiling proves they are needed:**
   - Do not move ordinary bounded database reads to an isolate by default.
   - Consider an isolate only for CPU-heavy decryption, large JSON parsing, or other measured work that blocks the UI thread.
   - Keep platform-channel calls and database ownership within the supported execution context.

Success criteria:

- The notification route begins rendering before settings loading and alarm rescheduling finish.
- The first unread task row appears without loading the complete task and log history.
- Warm notification taps do not push duplicate screens.
- Cold notification taps feel close to normal app launch on the same device.
- Profile builds show no sustained frame drops while the unread screen opens.

#### Profile evidence and optimization status

The reboot path is now independent of Flutter startup. `TaskBootReceiver` reads the native scheduler tables and restored 3/3 alarms in 36ms. The alarms then launched the headless execution service normally, and tasks completed after the reboot.

The cold notification flow improvements:

1. **Pending-intent lookup handoff gap (DONE):**
   - Non-blocking future started during `TaskSchedulerService.initialize()` in `main()` before `runApp()`.
   - Matching markers around `configureFlutterEngine_start`, `scheduler_channel_installed`, `pending_lookup_native_start`, and `pending_lookup_native_done`.
   - Cold routing callback post-frame awaits the in-flight future without an extra 624–794ms pre-route wait.
   - Native pending route latched and single-shot cleared via `clearPendingNotificationClick()`.
2. **Schema v8 composite indexing (DONE):**
   - `scheduler_task(created_at DESC)`
   - `scheduler_task_log(created_at DESC)`
   - `scheduler_task_log(notification_seen, created_at DESC)`
3. **Targeted countdown widget (DONE):**
   - `_TaskTimingInfo` eliminates the 1-second whole-screen rebuild loop.

---

### ✅ P11: Scheduler reliability & management follow-ups (COMPLETED)

Goal: Close the remaining scheduler gaps — silent failures, rigid intervals, and management at scale.

1. **Notify on fresh killed runs (COMPLETED).** `recoverStuckTasks` timeout transitions now inspect `task.notify` and recency (`freshKillWindow` default 4 hours). Dispatches a failure notification on fresh kills while recovering older stale tasks silently.
2. **Anchor-based interval scheduling (Option A strict grid, COMPLETED).** Replaced fixed-delay drift (`finishMillis + repeatAfter`) with anchored periodic grid calculation: `calculateNextRunAt(startsAt: startsAt, repeatAfter: repeatAfter, nowMillis: nowMillis)`. Eliminates interval drift across repeated runs and keeps manual triggers snapped to schedule.
3. **Searchable model picker in the task sheet (COMPLETED).** Replaced static dropdown in `_EditTaskModelSheet` with `showModelPickerDialog` (reusing chat `ModelPicker` dialog, search filtering, and release-date sorting).
4. **Task text search (COMPLETED).** Debounced title & ID search input field on the All Tasks tab in `ManageTasksScreen` with active-filter combination and empty state messaging.
5. **Pause-all / resume-all (COMPLETED).** `pauseAllTasks()` and `resumeAllTasks()` on `TaskSchedulerService` with native alarm cancel/schedule, AppBar popup menu on `ManageTasksScreen`, `TaskToastService` broadcasts, and tool actions in `schedule_task`.

---

### P12: Reliability, lifecycle, security, and performance hardening (ACTIVE)

Goal: Remove the confirmed correctness and memory-safety gaps found in the September 2026 codebase review, ordered by severity. P12 is a stabilization milestone. It must preserve the shipped P0-P11 behavior while making safety checks fail closed, lifecycle operations deterministic, background execution observable/cancellable across isolates, and large-data paths bounded.

#### Review baseline

- `flutter analyze`: no issues.
- `flutter test`: 569 tests passed.
- `./gradlew :app:lintLiteDebug :app:lintFullDebug`: reported with four Android `NewApi` errors and 40 warnings (consistent with the three unguarded API-26 calls below; lint not re-run locally).
- No source files were changed by the review.

#### P12.1 Background-engine transports (highest severity)

Headless background runs cannot use the `intent`/`location` channels: `setupEngineChannels` wires only `task_scheduler` + `app_info`, so calls fail with `MissingPluginException`. This silently breaks the autonomous flows P9 promised, and undercuts the "explicit broadcasts allowed" headless policy.

1. **Wire transports or shrink the registry.** Either register `intent` (non-UI subset) and `location` (cached fix) on the background engine, or remove tools from the headless registry when their transport cannot run there.
2. **Add cross-isolate cancellation.** Cancellation today is the in-process `_runningTokens` map; the DB `cancelled` status is only re-read after the run finishes. Forward cancellation to the owning isolate and add a durable DB check mid-run (per turn/tool call).
3. **Refresh progress beyond resume.** The `resumed` invalidation hook exists; add a bounded visible-screen polling fallback or task-change events so open screens cannot go stale.
4. **Renew the wake lock per queued task.** Today a single 15-minute lock covers the whole queue, so a second queued 10-minute task runs with ~1 minute of lock left. Refresh before each item, release when the queue empties.

#### P12.2 Shell policy and headless execution correctness

1. **Fail closed on proven bypasses (P0).** Executed and confirmed: `$VAR` in command position (`X="rm -rf /sdcard"; $X`) and the `env` prefix (`env rm -rf /sdcard`) both return `safe`. Treat unanalyzable expansions as untrusted. `eval`/`source`/`sh -c`/substitutions/`find -exec` are already handled; aliases need nothing (non-interactive shell never expands them). Add regressions for the two confirmed vectors.
2. **Serialize same-batch `save_report`.** Classify it stateful so concurrent calls in one batch run in order; last-wins is only proven across sequential turns.
3. **Correct unread semantics.** Count only terminal logs whose notification was actually sent; exclude `running` rows and `notify: false` logs; mark notification taps consistently.

#### P12.3 Scheduler UI and database performance

- Replace full-table watches with bounded SQL queries and cursor pagination.
- Match the sidebar Dart sort to the database `(updatedAt, id)` cursor: `_sortedConversations` re-sorts by `updatedAt` alone, so timestamp ties can jump rows or skip them across pages.
- Query counts separately and avoid loading all logs for task-only tabs.
- Move synchronous scratch scanning off the UI isolate.
- (Done, dropped from scope: sidebar ordering already is an `(updatedAt, id)` cursor with matching pagination.)

#### P12.4 Browser and widget lifecycle

- Dispatch one browser click instead of both a synthetic event and `el.click()`.
- Complete or fail pending load waiters when navigation closes or stops (today they hang to the 15s timeout).
- Fix headless browser disposal so it cannot notify a disposed `ChangeNotifier`.
- Make busy-route back navigation cancel or finalize the active turn safely.
- Check `mounted` after async work in task preview widgets and close short-lived HTTP clients.

#### P12.5 Conversation persistence

- Serialize or coalesce overlapping saves (`_persistNow` fires `unawaited` with no mutex). Saves are otherwise already debounced (600ms) with identity-based merge — no rescan/rewrite problem exists.
- Bind pending persistence to one conversation and flush it before switching or disposal.
- Gate config-dependent actions on explicit settings readiness.

#### P12.6 OTA, API guards, and flavor tests (small, grouped)

- Require exact APK length, add total/inactivity timeouts, and validate a release hash or signature when available. (Partial-file cleanup already exists.)
- Guard three API-26 calls for minSdk 24: `startForegroundService` (AgentForegroundService, crash if reached), `getHintText` (narrow: Full + a11y + old device), `setColorized` (caught → silent notification failure, not crash).
- Fix the notification permission request code: it reuses `LOCATION_PERMISSION_CODE` (`9002`), so a notification grant/deny can resolve a pending location result with the wrong answer. Use a dedicated code with an explicit (ignored) branch.
- Lite boundary is defined (manifest strip + runtime omission + README contract); add a test locking it.
- Add CI for Flutter analysis, tests, and both Android lint variants.

#### P12.7 Bounded memory and untrusted input (backlog-grade)

- Add aggregate per-turn byte budgets for media, screenshots, and `contentParts` (today only a 20MB per-file cap).
- Replace count-only document caching with a byte-bounded true LRU and in-flight parse deduplication.
- Bound the zero-key `webfetch` fallback with a raw response cap and inactivity timeout. (Tavily path and fallback timeouts/caps already exist — verify, don't rebuild.)
- Sandbox generated HTML report previews.

#### P12 acceptance criteria

- Background headless runs can use every registered headless tool's transport, and cancellation reaches the owning isolate mid-run.
- Destructive commands cannot bypass safety through `$VAR` command position or `env` prefix (proven vectors have regressions).
- `save_report` calls in one batch execute in order; unread counts reflect terminal, actually-notified runs.
- Task UI refreshes after background-isolate writes without loading unbounded result sets.
- Browser clicks fire once, pending waits resolve on close/stop, and headless disposal is safe.
- Overlapping saves are serialized; APK downloads time out and reject mismatched files.
- Android lint reports zero errors for Full and Lite; Lite test locks the permission boundary.

---

### ✅ P6c — Filesystem Hygiene, Interactive Safety & Browser OAuth (COMPLETED)

Goal: Protect user storage from clutter, safeguard system integrity with session-bound interactive confirmation, and enable seamless browser authentication.

P12 narrows the static command parser concern below to the two executed bypasses (`$VAR` in command position, `env` prefix); `eval`/`source`/`sh -c`/substitutions/`find -exec` are already handled and aliases never expand in non-interactive shells. The current shipped classifier is bypassable through exactly those two vectors, so the policy is not yet considered hardened.

1. **Storage & Working Directory Hygiene:** (SHIPPED in v0.6.2)
   - Default all agent-created files and text outputs to `/storage/emulated/0/Documents/Errand/` instead of cluttering storage root (`/storage/emulated/0/`).
   - Route ephemeral/scratch operations (temporary scripts, intermediary logs) to app-internal `scratch/` cache directory.
   - Refine system prompt guidelines and `WorkingDirectory` default initialization to enforce output hygiene across all file and shell tools.

2. **Interactive Bash Safety & Trust Mechanism (`Accept` / `Deny` / `Trust`):** (SHIPPED in cef6a57)
   - Intercept destructive shell commands (`rm`, `rm -r`, `rm *`, bulk `mv`, `truncate`, `find -delete`, `sed -i` outside scratch) at tool execution.
   - Present a sleek, floating confirmation card directly above the composer with command details and 3 choices:
     - **Accept:** Executes the command once.
     - **Deny:** Cancels execution and informs agent via graceful tool failure (`User denied execution of command: $command`).
     - **Trust:** Session-scoped auto-acceptance for the active conversation. Persisted in RAM only (`Set<String> _trustedConversationIds`). Resets immediately on conversation switch or app close/restart.

3. **In-App Browser OAuth & Multi-Window Support:** (SHIPPED)
   - Sanitize embedded WebView user-agent by stripping `; wv` and `Version/4.0` to bypass Google/GitHub `403: disallowed_useragent` blocks.
   - Enable `supportMultipleWindows: true` and `javaScriptCanOpenWindowsAutomatically: true`.
   - Handle `onCreateWindow` with modal `OAuthPopupDialog` containing a dedicated child `InAppWebView(windowId: ...)` and `onCloseWindow` auto-dismissal to support Google/GitHub OAuth popup dialogues smoothly within the in-app browser.
   - Provide direct "Open in external browser" toolbar button escape hatch to launch the active URL in external Chrome.

---

#### Known Rough Edges & Potential Problems Identified

1. **Keyboard Transition Choppiness / Micro-Stutter:**
   - *Symptom:* When focusing the Errand composer, the soft keyboard lifts smoothly before the browser has ever opened. Once the browser has opened (even if subsequently closed), the keyboard lift transition experiences noticeable frame drops.
   - *Root Cause A (PlatformView Reparenting via GlobalKey):* When toggling between preview and compact/closed modes, `_buildPersistentWebView()` was moved between the active animated card container and the root offstage container. Live reparenting of a native `PlatformView` across widget tree branches at the exact frame the keyboard starts animating forces the native view hierarchy to reconcile and drop frames.
   - *Root Cause B (Offstage Inset Synchronization):* The hidden offstage container was positioned at `bottom: 0` inside a `Scaffold` with `resizeToAvoidBottomInset: true`. Every frame of the ~250ms keyboard animation changed layout bounds, causing Android's `PlatformViewsController` and `SurfaceSyncGroup` to synchronize frame buffers across processes on every frame even while offstage.
   - *Root Cause C (Hybrid Composition Overhead):* `useHybridComposition: true` delegates compositing directly to Android's `SurfaceFlinger`. Synchronization overhead during concurrent layout animations (`BrowserDockSpacer`, `BrowserWidget`, soft keyboard) spikes GPU/CPU load.

2. **Architectural Evaluation & Selected Solution:**
   - Three architectural approaches were evaluated to resolve the keyboard transition choppiness:
     * **Case 1 (Live GlobalKey Reparenting across branches):** *Rejected.* Reparenting a live native `PlatformView` between the preview card and root offstage tree during window inset animation forces Android `PlatformViewsController` to reconcile surfaces mid-animation, dropping frames.
     * **Case 2 (Zero-Reparenting Stable Hierarchy + Fixed Offstage Bounds):**  ***SELECTED BEST SOLUTION.*** Mount the `InAppWebView` permanently in a single slot. In preview/dock modes, resize container constraints and overlay controls rather than reparenting across widget tree branches. When closed/minimized, pin the offstage view to fixed coordinates (`top: 0, left: 0, width: 1, height: 1`) completely decoupled from bottom keyboard insets, and pause JS timers via `pauseTimers()`. This provides smooth 60/120 FPS keyboard animations while preserving 100% of DOM state, form drafts, active sessions, and autonomous agent JS execution.
     * **Case 3 (Complete Unmounting / Destruction on Close):** *Rejected.* Disposing the WebView on close destroys the Chromium process. This wipes active DOM state, aborts running agent web actions if preview closes, and loses multi-turn continuity.
   - **Implementation Blueprint for Case 2:**
     * **Single Permanent Slot:** Keep `InAppWebView` mounted in a dedicated persistent subtree.
     * **Decoupled Offstage Geometry:** Pin the offstage container to `top: 0, left: 0` so Android soft keyboard window insets never trigger layout passes or `SurfaceSyncGroup` buffer re-allocation on the hidden view.
     * **Render Layer Isolation:** Wrap the `PlatformView` in a `RepaintBoundary` to prevent chat timeline repaints from invalidating the native texture surface.
     * **Timer Management:** Call `pauseTimers()` when minimized/offstage and `resumeTimers()` when brought back to foreground preview/fullscreen.
     * **Profile Mode Verification:** Profile using `flutter run --profile` to ensure zero dropped frames on lower-end Android hardware.

---

### 🌐 P6 — Embedded Web Agent Tools (Closing the Lite vs. Full Gap)

Goal: Enable autonomous, safe web navigation and interaction directly within Errand, eliminating the need to bounce the user to external browsers while remaining fully functional on both Full and Lite flavors (zero accessibility permissions required).

#### 🔵 P6a — Embedded Browser Agent Tools

Goal: give Lite the automation Full gets from a11y, for any task that can be done in a browser (form fill, scheduling, lookup, checkout drafts). Single controllable WebView, visible to the user as the agent works, with pause-and-delegate for logins.

1. **Package choice: `flutter_inappwebview`.**
   - `evaluateJavascript` + `addJavaScriptHandler` (typed JSON) for DOM bridge, `takeScreenshot` (visible viewport PNG) for visual fallback, `incognito` flag, `ContentBlocker`, `shouldOverrideUrlLoading`.
   - `webview_flutter` rejected as primary: no screenshot API; framework `RepaintBoundary` capture returns blank on `PlatformView`.

2. **Single WebView + `Offstage` visibility (no headless <-> in-app toggle).**
   - One `InAppWebViewController` owned by a `BrowserService` singleton (mirrors `A11yService` pattern). Keep it alive across turns/sheet expands.
   - Headless promotion (`HeadlessInAppWebView` -> visible) is crash-prone on config/size change; avoid it for the main view. Optional headless only for background prefetch, never as the toggle path.
   - Render: `DraggableScrollableSheet (0.25 collapsed squircle -> 1.0 full)` + `ClipRRect`/`ContinuousRectangleBorder`, same sheet style as Settings sheet. Collapsed = `Offstage` live view or screenshot thumbnail; expanded = live interactive view. `Offstage` skips compositing/GPU but keeps session + controller (does not fully free RAM — call `pauseTimers` when hidden, `resume` on show). Drag handle lives outside WebView gesture area to avoid scroll-vs-drag fights.

3. **Dual-mode control (JS first, vision fallback).**
   - Snapshot JS: `querySelectorAll('a,button,input,select,textarea,[role],[onclick],form')` capped at 100-150 nodes -> `{id,role,name,tag,href,type,value,disabled,rect}` via `getBoundingClientRect`, tag `data-agent-id`. Return JSON string, `jsonDecode` in Dart. Reuse 6k spill + `grep` conventions from `screen`/`read`.
   - Act JS: `querySelector('[data-agent-id="N"]').click()` / `MouseEvent` dispatch for SPAs; `focus + execCommand('insertText') + input/change` events for React inputs; `scrollIntoView({block:center})` before act.
   - `takeScreenshot` only on ambiguity / shadowDOM / canvas. Prefix all page output with `UNTRUSTED_PAGE_DATA:`.

4. **Agent tools (registered unconditionally in `ToolRegistry.defaults`, Lite-safe — no a11y permission):**
   - `browser_open{url}` — `http/https` only, per-task `allowedDomains` check, `onLoadStop + ~800ms` settle.
   - `browser_snapshot{}` — DOM outline + `url/title/scroll`.
   - `browser_act{ref, action: click|type|select|scroll, text?, confirm?}` — resolves `data-agent-id`; refuses password/OTP autofill and `pay/submit/delete` without `confirm:true`.
   - `browser_shot{}` — viewport PNG into `contentParts image_url` for multimodal models.
   - `browser_close{clear?}` — ends task; clears per ephemeral setting below.

5. **Sessions: ephemeral default, persistent opt-in.**
   - Chromium `CookieManager` persists by default across restarts. Default = ephemeral (`incognito:true`, `thirdPartyCookiesEnabled:false`, clear cookies/cache/storage on close). Opt-in "Remember login" = persistent store + domain/expiry row + one-tap Clear. Store is process-global (controllers share it); no per-tab isolation without manual clear.
   - Chrome/Custom Tab logins cannot be imported (separate jars). User logs in once inside agent WebView, then it sticks.

6. **Auth wall reality + handoff.**
   - Google OAuth (`accounts.google.com`) returns `403 disallowed_useragent` in any embedded WebView per Secure Browsers policy (Sep 2021); Play Console flags `Usage of WebViews for Authentication`. Same class of breakage for Microsoft Conditional Access/passkeys, Apple. Plain forms + most non-Google OAuth work fine. No UA spoofing.
   - On `input[type=password] | captcha | checkout/pay | cross-origin/auth URL`: tool returns `{needs_user:true}`, loop pauses, sheet offers `[Take Over] [Open in Chrome] [Cancel]`. Custom Tab / system browser handles Google/SSO (URL bar visible), result returns via redirect token — not cookie copy. Agent re-snapshots on Continue. Passwords use placeholder injection (`x_pass` in history, host injects value, `use_vision:false` on auth pages).

7. **Safety (extends Draft policy from `act`):**
   - `shouldOverrideUrlLoading` gate + block `intent://, file://, data:, javascript:` from pages; cross-origin nav auto-pauses.
   - Classify `read(auto) / draft(auto-fill, needs approval) / commit(submit, login, pay, send, delete, upload, permission — always Confirm/Edit/Discard card with origin + masked values)`. Typing into untrusted origins counts as commit. Single human-timeout -> abort + clear draft. Audit-log all calls.

---

### 📦 Backlog & Future Items

- **Safe File Editing Tool (`write` / `edit_file`):** In-place file modification with structured diff preview, user approval gating, and atomic backup/undo mechanisms.
- **Local Semantic Retrieval:** On-device embeddings / SQLite FTS5 for local documents and memory recall.
- **Stream-Stall Watchdog:** SSE inactivity transformer for `chatStream` to cleanly recover from frozen network sockets.

---

## ✅ Shipped Milestones

### ✅ P0 — Android Intent Tool & Native System Surface
- **Curated Intent Actions:** Comprehensive intent surface (`open_file`, `open_url`, `open_app`, `settings`, `intent`, `docs`) covering alarms, timers, calendar entries, sharing, maps, email, media playback, uninstall, and settings panels.
- **Generic Escape Hatch:** Normalized `action: "intent"` accepts arbitrary `android_action` strings with typed extras mapping (`int`, `double`, `bool`, `String`) for third-party apps without code changes.
- **On-Demand Intent Documentation (`docs`):** Agent inspects exact Android actions, URIs, and extra schemas for `alarm`, `timer`, `location`, `calendar`, `web_search`, `email`, and `media_capture` before dispatching.
- **System Hardening:** Async native error handling (`NO_HANDLER`, `NO_PKG`), strict URL auto-prefix validation, RFC-6068 email queries, `FileProvider` URI resolution, BAL-safe launch (`PendingIntent` + a11y context fallback), and selective `bringToFront`.
- **App Discovery & Alias Matching:** SQLite-cached launcher package inventory with fuzzy alias resolution (e.g. YouTube Music, BookMyShow) and top-10 suggestions on launch failures.

### ✅ P1 — Context Budgeting, History Compaction & Pagination
- **Token-Based Context Budgeting:** Dynamic `ContextBudget` calibrated per model (~3.8 chars/token, model `contextSize`, reserving `min(16K, 25%)` output tokens with `models.dev` fallback).
- **Auto-Compaction & Truncation:** Pre-turn and mid-run LLM history compaction with deterministic fallbacks under a 60-second timeout; persisted `CompactedNoticeMessage` dividers preserve pre-compaction turns without re-sending them.
- **Windowed Message & Sidebar Loading:** Initial 50-message conversation window with prepending viewport-anchored scroll pagination (`loadOlderMessages`); sidebar cursor-based pagination for recents (`PagedFetcher<T>`).
- **Merge-Safe Database Upserts:** Message-level upserting in `saveConversation` ensuring out-of-window messages remain intact.

### ✅ P1.5 — Conversational UX, Control & Resiliency
- **Abortable Cancellation (Stop Button):** Dynamic send/stop button toggling with cancel flags threaded into SSE streaming and turn boundaries; preserves partial output.
- **Message Editing & Branching:** Edit user message with cascade deletion of subsequent turns (`_truncateFrom`); regenerate response from last user turn.
- **Voice Input:** Integrated `speech_to_text` wrapping Android's built-in `SpeechRecognizer` with first-use language selection and persistent preference storage.
- **Foreground Execution Guard:** Active `dataSync` Foreground Service keeps SSE streams alive when intent launches push Errand to the background.
- **Network Resilience & Error Policy:** 3-attempt exponential backoff with `Retry-After` honoring for API calls; clear separation between transport errors (transient SnackBars) and tool errors (inline context).

### ✅ P2 — Accessibility Service & Screen Automation (Tier S & Draft Tier A)
- **Kotlin Accessibility Service:** `ErrandAccessibilityService` with `canRetrieveWindowContent`, `canPerformGestures`, and `canTakeScreenshot` capabilities; method channel `"a11y"` mirroring `"intent"`.
- **Screen Outline Tool (`screen`):** Compact outline serialization with viewport partitioning (visible items emitted first in visual reading order; off-screen nodes grouped under `--- Off-screen ---`); TalkBack boilerplate stripping and list compression.
- **Global Actions:** Back, home, recents, notification shade, lock screen, and screenshot capture.
- **Gated Draft-Mode Gestures (`act`):** Tap by label with commit refusal, `ACTION_SET_TEXT` typing with password/OTP field refusal, and directional scrolling with deterministic `at_end` detection.
- **Extended Turn Cap:** Agent loop cap extended to 72 turns with mid-run compaction.
- **Lifecycle & Privacy:** Auto-disables on app removal and finish; cold-start restricted settings guidance; Settings sheet Enable/Disable toggle.

### ✅ P3 — Media Multimodality & Attachment Pipeline
- **Integrated Media Reading:** `read` tool directly processes media (`kMediaFormats`: jpg, png, webp, gif, wav, mp3, mp4, webm, mov up to 20 MiB) into OpenAI-compatible data URLs.
- **Capability Gating:** `ModelCatalogService.supportsInput` checks model capability before dispatching multimodal payloads.
- **Composer Attachment Workflow:** Multi-file picker (`+`), staging card preview, and schema v4 ordered tracking (`ConversationMessages.attachedUrisJson`).
- **Discovery Tool:** `attached_files` tool provides instant inventory of conversation attachments. Verified with 81 unit/integration tests.

### ✅ P4 — Architecture Refactor & Operational Hardening (v0.5.0 – v0.5.2)
- **P4a Service Refactor (v0.5.0):** Systematic refactoring across all core modules (`model_catalog`, `tavily_client`, `workspace`, document readers, `intent_service`, `llm_client`, `agent_loop`, `database`, `a11y_service`, and UI) maintaining strict backward compatibility.
- **Dual Build Flavors (v0.5.2):** Full flavor retains accessibility automation for sideloaders; Lite flavor strips the accessibility service entirely from the manifest for zero-friction distribution.
- **Large Output Spill Caching:** `ToolOutputFileService` spills command/tool outputs exceeding 6k characters into temporary cache files (512 KB cap, 10-minute TTL, max 50 files) with head/tail previews and direct `read` cache resolution.
- **Heavy Tool `grep` Filtering:** Optional `grep` parameter for `screen`, `read`, and `workspace` tools with ReDoS protection and match limits.
- **Resilient Web & Visual Fallbacks (v0.5.1):** Offline `webfetch` via `reader_mode` + `html2md` fallback; accessibility screenshot capture; background model catalog prefetching and live `ModelPicker` updates.

### ✅ P5a — On-Device Shell Execution Tool (`/system/bin/sh`) (v0.5.5)
- **Direct Shell Invocation:** `ShellService` and `bashTool` execute on-device commands via `/system/bin/sh` using `Process.start` in `dart:io`.
- **Toybox / Toolbox Utility Suite:** Instant access to CLI utilities (`ls`, `cat`, `grep`, `find`, `sed`, `awk`, `cut`, `sort`, `uniq`, `wc`, `tr`, `head`, `tail`, `mkdir`, `cp`, `mv`, `rm`, `tar`, `gzip`, `df`, `du`, `ps`).
- **Directory Persistence:** Automatically tracks and mutates `WorkingDirectory.current` across turns and file tools.
- **Safety Policy:** Strictly blocks privilege escalation (`su`/`sudo`), reboot/shutdown, and fork bombs. Destructive mutations (`rm -rf`, wildcards) enforce Draft confirmation (`confirm_destructive: true`).
- **Workspace Tool Retirement:** Standalone `workspace` router retired from defaults; folder exploration unified under `bashTool`.

### ✅ v0.5.6 — Intent Documentation, Tool Call Grouping UI & Modularity
- **Intent Documentation Action:** Added `intent(action: "docs", name: "...")` for schema inspection across core Android actions.
- **Typed Extras Support:** Normalized integer lists and primitive types in platform channels (`MainActivity.kt`).
- **Grouped Tool Call UI (`ToolGroupBubble`):** Consecutive tool executions grouped into a unified timeline card with animated status transitions (`running`, `completed`, `failed`), step counter badges, and nested collapsible accordions.
- **Keyed Provider Prioritization:** Providers with configured API keys appear first in the LLM selection UI.
- **Entrypoint Modularization:** Decomposed `lib/main.dart` into `lib/bootstrap.dart`, `lib/app.dart`, and `lib/screens/chat_screen.dart`.

### ✅ P5b — Global Memory System & Persistent Knowledge Tool (v0.6.0, Schema v5)
- **Database Persistence (Schema v5):** Added `memories` table in Drift with UUID primary keys, unique slugs (`key`), content, JSON tags, and update tracking.
- **Agent Memory Tool (`memory`):** Dedicated tool with actions `save`, `recall`, `update`, `delete`, and `list` for cross-conversation user memory.
- **System Prompt Knowledge Digest:** Automatic passive injection of known user facts and preferences into the system prompt.
- **User Memory Management UI:** Dedicated management view in Settings allowing inspection, manual creation, editing, and deletion of memories.

### ✅ P6a — Embedded Browser Agent Tools & Morphing UI (v0.6.0)
- **Autonomous Embedded Browser (`browser`):** In-app web agent capabilities based on `flutter_inappwebview` with direct DOM JS interaction, accessibility tree snapshots, screenshot fallback, and text extraction.
- **Morphing Card & Dock UI (`BrowserWidget`):** Responsive embedded browser UI featuring smooth morphing across compact dock bar (50px), floating preview card (with adaptive 0.80 zoom), and full-screen modal with custom controls.
- **Composer Focus Isolation:** Browser preview card collapses to the compact dock bar only when the chat composer is actively focused, keeping the preview expanded while typing inside web page inputs.
- **Tool Hierarchy Alignment:** Streamlined tool selection policy: Intent $\to$ Browser $\to$ `screen_act` (accessibility).
- **Native Action Renaming:** Renamed native accessibility action tool to `screen_act` for clear disambiguation from web browser actions.
