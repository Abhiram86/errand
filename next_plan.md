# Next Plan — Status & Roadmap

> **Updated Sep 2026.** P0 through P11 are shipped. The current codebase is schema v8. `flutter analyze` reports no Dart issues, all 569 tests pass, and Android lint currently fails with four API-level errors plus non-blocking warnings.
> **Active Milestone:** **P13 — Task storage ownership (report files)**. P12 shipped in v0.7.4. P6b browser PlatformView work remains queued.

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

### ✅ P10: Scheduler launch performance and lazy notification navigation (COMPLETED)

Goal: Make notification taps reach the unread task view quickly, without competing with app startup, settings loading, full scheduler rescheduling, or unbounded database reads.

1. **Measure the three launch paths first (DONE):**
   - Profile cold notification tap, warm notification tap, and normal app launch.
   - Record time from notification tap to Flutter engine start, first app frame, notification route push, first route frame, and first useful task row.
   - Validate on both small and large task/log histories.
   - Target met: cold tap-to-first-row under 2 seconds.

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

4. **Load only unread data for the first notification frame (DONE — P12.3):**
   - Replaced unbounded task and log streams in `ManageTasksScreen` with a bounded SQL LIMIT (400) query for logs.
   - Indexed compound unread query on `scheduler_task_log(notification_seen, created_at DESC)`.
   - Query unread counts separately with indexed `COUNT(*)` query.

5. **Lazy-load the other task tabs (DONE — P12.3):**
   - Built the Unread tab first for notification taps.
   - Task tabs receive latest-log-only per row instead of loading full log histories.
   - Invalidation driven by `TaskToastService` broadcasts.

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

### ✅ P12: Reliability, lifecycle, security, and performance hardening (COMPLETED v0.7.4)

Goal: Remove the confirmed correctness and memory-safety gaps found in the September 2026 codebase review, ordered by severity. All P12 milestones are implemented, verified with 618 passing tests, and shipped in v0.7.4.

#### P12.1 Background-engine transports & cancellation (COMPLETED)
1. **Transports wired:** `intent` (non-UI broadcasts/alarms/timers) and `location` (cached fix) registered on the background engine (`MainActivity.kt`).
2. **Cross-isolate cancellation:** Mid-run cancellation forwarded across isolates with mid-turn database status checks.
3. **Task refresh & wake locks:** Invalidation hooks refreshed on task lifecycle events; wake lock renewed per queued task item.

#### P12.2 Shell policy and headless execution correctness (COMPLETED)
1. **Fail-closed shell safety:** `$VAR` command expansion and `env` prefixes classified as untrusted/destructive under Draft policy with regression tests.
2. **Serialized `save_report`:** Stateful batch serialization ensures last-call-wins determinism.
3. **Correct unread semantics:** Terminal, actually-notified logs counted; `running` and `notify: false` logs excluded.

#### P12.3 Scheduler UI and database performance (COMPLETED)
- Replaced full-table watches with 400-row bounded SQL LIMIT queries and cursor pagination.
- Separate indexed `COUNT(*)` query powers the exact unread badge.
- Tasks tabs display latest-log-only per row instead of loading full historical log arrays.
- Offloaded synchronous scratch directory scanning to background isolate.

#### P12.4 Browser and widget lifecycle (COMPLETED)
- Unified DOM click dispatching.
- Pending load waiters resolve immediately on close/stop without 15s timeout hangs.
- Safe headless browser disposal without notifying disposed listeners.
- Safe back navigation cancels active turns without leaking unmounted states.
- Clean `mounted` checks in preview widgets and auto-closing short-lived catalog HTTP clients.

#### P12.5 Conversation persistence (COMPLETED)
- Extracted `CoalescingWriter` to serialize overlapping database persistence calls.
- Bound pending writes to active conversation and flushed on switch/disposal.
- Chat message sending and voice input gated on fast settings core readiness.

#### P12.6 OTA, API guards, and flavor tests (COMPLETED)
- Fail-closed SHA-256 integrity verification, total timeouts (5m), and inactivity timeouts (30s) for APK downloads.
- Android API-26 guards for `startForegroundService`, `getHintText`, and `setColorized` (0 Android lint errors).
- Separated notification permission request code from location requests.
- Flavor boundary unit test locking the Lite manifest contract.
- Added GitHub Actions CI workflow for Flutter analysis, tests, and Android lint.

#### P12.7 Bounded memory and untrusted input (COMPLETED)
- 30MB aggregate per-turn media budget for tool content parts in `AgentLoop`.
- Byte-bounded (64MB) true LRU document cache with in-flight parse deduplication (`DocumentLruCache`).
- 8MB byte-bounded true LRU PDF unit extraction cache.
- 5MB raw response byte cap and 10s inactivity streaming timeout in fallback `webfetch`.
- Sandboxed HTML report previews with external browser link opening.

---

### 🟡 P13 — Cutting edges (ACTIVE)

Goal: harden the surfaces that are currently best-effort into deterministic, owned, and diagnosable behavior. Every outcome labeled, every file owned, no silent partials.

#### P13.1 Report paths + linked files + delete hook

- **Keep `output_file_path` as the report path (no rename).** The column stays exactly as-is, so no `DROP COLUMN` (unsafe on old-device SQLite) or table rebuild is needed. The agent-facing name `report_path` is presentation-only: tool schemas, `schedule_task` output mapping (`schedule_task_tool.dart:732`), and headless prompts say `report_path`; all writes still target `output_file_path`.
- **Store scratch-relative paths going forward.** Current writes are absolute (`agent_runner.dart:277` → stored at `task_scheduler_service.dart:858`), which rot across reinstalls/cache clears. Normalize to scratch-relative on write; convert legacy absolute values on read (strip the scratch prefix when present).
- **Add only `linked_files` (TEXT JSON array, default `[]`).** Safe `ADD COLUMN` migration (schema v9). Holds auxiliary outputs alongside the primary report so one task's full footprint is enumerable: `report_path + linked_files`.
- **Delete hook with informed prompt.** `deleteTask(id, {bool deleteFiles})` removes the files in `report_path`/`linked_files` when asked. UI prompt shows count + bytes ("Also delete 7 report files (2.3 MB)?"), checkbox defaults checked. The storage manager's per-task clear reuses this hook.
- **Orphan sweep.** Files in scratch referenced by neither column (crash between write and log insert) are listed via one directory scan + one query, surfaced as an "Orphaned files (N, X MB) [clear]" section in the storage manager, optionally on boot.

Acceptance:
- New reports store scratch-relative paths; legacy absolute paths still resolve.
- `linked_files` round-trips through create/edit/prune (keep-newest-10 prunes linked files with their report).
- Deleting a task with the box checked leaves zero owned files; unchecked leaves them (visible in the sweep).
- Orphan sweep lists exactly the unreferenced files, nothing owned.

#### P13.2 Deterministic browser outcomes (no silent partials)

Contract: 100% *labeled* outcomes, not 100% success (the live web forbids that). Every browser step ends as verified success, typed failure with cause, or explicit-unknown with evidence. "Assumed ok" stops existing.

1. **Condition-waits kill all fixed sleeps.** Audit every fixed delay on the browser path (800ms settle, 300/500ms retry delays, 350ms render delay) and replace with poll-until-condition-or-timeout: `waitForUrl`, `waitForSelector(visible/stable)`, `waitForDomQuiet`. Each returns condition-met-with-timestamp or `TIMEOUT` with what was actually observed.
2. **Ref freshness.** Stamp snapshots with an epoch; `act` re-resolves its ref at action time (attached, visible, enabled, topmost via `elementFromPoint`) and rejects stale/detached refs with `SNAPSHOT_STALE: re-snapshot` instead of firing into the void.
3. **Act→verify loop.** Every mutating act declares its expected effect (URL change, element appeared/vanished, text present); the tool verifies post-action by re-query. Result is `VERIFIED` or `FAILED(effect not observed)`.
4. **Typed error taxonomy + retry policy.** Exhaustive results: `OK_VERIFIED`, `NOT_FOUND`, `NOT_INTERACTABLE(covered|disabled|hidden)`, `NAV_TIMEOUT`, `HTTP_ERROR(code)`, `STALE_SNAPSHOT`, `AMBIGUOUS` (unknown — re-probe required, never reported as success). Retryable (timeout, stale) vs terminal (repeat not-found, auth wall) classified in the tool; per-class retry budgets replace the flat consecutive-error cap.
5. **Evidence bundle on every failure.** Snapshot slice + console errors + HTTP status + final URL + screenshot attached to the failure result, so the diagnosis is deterministic even when the outcome is uncertain.
6. **Self-check matrix suite.** Local test page with one of each nasty case (shadow DOM, covered button, JS-gated field, SPA hash-nav, delayed render, 503 page, auth wall) asserting the taxonomy cell-by-cell — a public determinism scoreboard.

Acceptance:
- Zero fixed sleeps remain on the browser act/load path; every wait returns evidence.
- Stale-ref act is rejected 100% of the time without touching the page.
- Every mutating act returns `VERIFIED` or a typed failure; no unverified `ok` leaves the tool.
- `AMBIGUOUS` is never auto-retried into a success claim; terminal classes abort with diagnosis.
- Matrix suite green on all cells; any red cell names the exact uncovered case.

#### P13.3 Intent tool docs + honest outcome labeling

Problem: outside alarms (solid) and calendar (okay), intent actions are unreliable — and Android's permission/activity model means most effects are unverifiable by design (fire-and-forget; no read-back without extra permissions). So unlike 13.2, failure-checking can't close the gap. What can: docs that tell the truth per action, and outcomes that never overclaim.

1. **Per-action reliability tiers in `docs`.** Every documented action gets a tier: `verified` (alarms — exercised on-device), `partial` (calendar — works, edge cases known), `fire-and-forget` (effect unverifiable, dispatched-only), `experimental` (known-broken or OEM-dependent). Tiers ride with the action schema, not a wiki nobody reads.
2. **Exact extras + caveats per action.** Required vs optional extras, OS-version minimums, OEM variance notes (Samsung vs Pixel dispatch behavior), and BAL/background-launch limits where they bite. Demote or remove actions that can't be documented honestly.
3. **Outcome vocabulary that matches the platform.** Results are `DISPATCHED` (system accepted — never "timer created"), `NO_HANDLER` (deterministic failure via pre-flight `canResolve`, already in `IntentService`), `BLOCKED` (BAL/background restriction with the user-facing remedy), `UNKNOWN` (accepted, effect unverifiable). The agent is instructed to report these verbs, not invent completions.
4. **Pre-flight `canResolve` everywhere it applies.** Turn blind attempts into deterministic `NO_HANDLER` before dispatch, with the top fuzzy-match suggestions on failure (existing behavior, now mandatory path).
5. **Verify-after where a read-back exists.** Where a follow-up query is possible without new permissions, the agent flow does dispatch-then-confirm; where it needs a new permission (e.g. calendar read-back), the spec names it explicitly as a costed option instead of silently skipping verification.
6. **On-device action matrix.** One row per documented action: handler present? dispatch accepted? effect confirmable? Run per release (and ideally per major OEM) so tier labels are measured, not vibes.

Acceptance:
- Every `docs` action carries a tier + extras schema + caveats; zero undocumented actions reachable by the agent.
- No tool result or prompt language claims an unverifiable effect (grep-able: "created/set/started" only beside verified paths).
- `NO_HANDLER`/`BLOCKED`/`UNKNOWN` are distinct, tested results with user-actionable messages.
- Matrix run attached per release; any tier change is backed by a matrix delta.

#### P13.4 Profile + optimize background runs (mobile-data slow/faily)

Problem (researched, Sep 2026): headless runs are slow and failure-prone on mobile data. Structural causes, all verified in code: 30s timeout × 5 LLM attempts + backoff ≈ 2.7 min worst case per call (`llm_client.dart`, `task_scheduler_service.dart:718`); no connectivity check anywhere, so dead links burn the full budget; background FlutterEngine cold-starts per alarm batch; Doze fires `setExactAndAllowWhileIdle` alarms while keeping network restricted (`PARTIAL_WAKE_LOCK` holds CPU, not network) so all attempts fail fast and the task goes red; WiFi→data handoffs kill keep-alive sockets mid-stream; every transient blip becomes FAILED + notification while foreground retries feel normal.

1. **Mine the logs first (profiling).** Break down existing runs by failure class (transport/offline vs timeout vs model error), attempt counts, per-call durations, and WiFi-vs-data where inferable. Decides whether Doze/offline dominates (→ items 2–4 suffice) or timeout tuning is needed. No code, ~1 hour analysis.
2. **Pre-flight reachability probe + defer-instead-of-fail.** One short check (provider host connect, ~5s) before spending attempts. Offline → reschedule (recurring: next grid slot; one-off: +N backoff) instead of FAILED. Converts "faily" into "patient".
3. **Split transport failure from task failure in UX.** Offline/timeout-class errors on retryable schedules → "waiting for network" state with no failure notification; notify only when retries are truly exhausted with no next run.
4. **Network-preference toggle (WiFi-only per task or global).** Direct answer to metered-data complaints; pairs with item 2 for exact-time tasks.
5. **Cheaper first attempt on metered links** (probe semantics, short timeout) instead of a uniform 30s — cuts perceived slowness without touching the success path. WorkManager-with-`CONNECTED`-constraint explicitly deferred: sacrifices exactness, revisit only if exact-time tasks fail disproportionately.

Acceptance:
- Log breakdown attached; build items justified by it, not vibes.
- Offline at alarm time never produces FAILED; reschedule path covered by tests.
- Transport-class errors never trigger failure notifications on retryable schedules (tested).
- Metered-link p95 attempt waste (time spent on attempts that fail transport-class) drops; measured before/after from log durations.

#### P13.5 Small nits batch

1. **Voice widget listening icon.** The audio-reactive border glow stays; the icon must swap microphone → stop while listening (tapping stops). Currently shows mic in both states, which misreads as "tap to start" mid-dictation.
2. **Composer autofocus on cold open.** Request focus post-first-frame on fresh app open so the keyboard is up and the user can type immediately. Resume-from-background must NOT re-focus (keyboard popping over resumed content annoys); gate on cold start only.
3. **Unread tab is really run history.** The tab mixes unseen notifications with the full log list behind filter chips, so "Unread" misnames it. Rename without restructuring: tab **Runs**, first chip **New (n)** (was "Unread (n)"), rest unchanged. Every row is an execution run; the badge keeps meaning "new since you last looked".
4. **Title generation as a declared tool group.** Conversation titles come from an explicit agent tool call (`conversations → write_title` on the first turn), rendered in the grouped tool-call UI with its description like any other tool — visible and explainable, never silent background magic. Fallback to first-user-message truncation on failure; re-title only on explicit request or extreme topic drift (gated, never eager).

#### P13.6 External review findings (verified, `latest_review.md`)

All items below were independently verified against the tree (26/30 confirmed as-written; H5 downgraded to cleanup — double `close()` is idempotent-harmless; M16 reframed — activity launches are properly blocked, only arbitrary *broadcast* actions pass). Fix in subsection order; each carries its own acceptance.

- **13.6.1 Shell parser normalization (C1, H9, H10).** Strip backslash-escapes/quotes before executable classification (closes `\rm`, `"r"m` bypasses, proven untested); add `_isSystemPath` blocks to `mv`/`cp`/`shred`/`truncate` targets (`cp` currently has no branch at all); detect `<(`/`>(` process substitution. Acceptance: quoting-vector regression tests alongside the existing `$VAR`/`env` ones; no named destructive binary reachable under any quoting.
- **13.6.2 Commit guard on ref path (C2).** Enforce `looksLikeCommitAction` for numeric-ref taps (resolve label via `tapByRef` result or refuse destructive refs in the service). Acceptance: `ref` tap on a Pay/Delete-labeled node is refused with the same error as the label path.
- **13.6.3 File-read path gate (C3).** Replace `contains()` substring checks with `path.isWithin` against resolved picker-cache/screenshot dirs + `resolveSymbolicLinksSync` before `exists()`. Acceptance: planted-path test (substring path outside the real dirs) is rejected.
- **13.6.4 Compaction alternation (H1).** Track last emitted role in `_toLlmHistory`; skip the post-compaction assistant ack when already `assistant` (the low-level path already does this). Acceptance: no consecutive same-role messages post-compaction on strict providers.
- **13.6.5 Background engine lifecycle (H2, H3).** Set `backgroundEngine` only after successful `executeDartEntrypoint`; destroy + null on init failure before advancing the queue; move engine creation off the main thread. Acceptance: killed-engine init fails one task loudly, never poisons all future tasks; no UI-thread engine creation.
- **13.6.6 Stream bounds (H4).** Cap accumulated bytes per stream (~8–16MB) + hard total-duration timeout on top of the 30s inactivity watchdog. Acceptance: dribbling-server test terminates bounded in bytes and time.
- **13.6.7 Scheduler post-run correctness (H6 open + H5 ✅ DONE).** H5: redundant second `close()` removed (verified idempotent-harmless first). H6 still open: use re-read `freshTask` for all post-run status updates (type/interval/failures currently go stale over mid-run edits). Acceptance: edit-during-run test keeps user values.
- **13.6.8 ChatScreen working-bubble isolation (H7, H8).** Extract the …working placeholder into its own `StatefulWidget` with a scoped timer; `mounted`/disposed guards on all async callbacks. Acceptance: per-second rebuild scoped to one widget; navigate-mid-turn never throws.
- **13.6.9 Catch-up spin + compaction cap (loop ✅ DONE, cap ✅ DONE, 60s floor deliberately skipped).** Both linear catch-up loops replaced with closed-form `calculateNextRunAt` (zero behavior change; `repeat_after: 1` edit returns instantly, proven by regression test) — no 60s floor added, sub-minute schedules are legitimate. Compaction summary capped at `targetTokens`-as-chars. Acceptance: `repeat_after: 1` completes promptly by test; echo-history summary cannot loop compaction.
- **13.6.10 Model/catalog matching (M2 open, M15 ✅ DONE).** M15: cache key buckets by key-material hash, so key rotation never serves the stale catalog. M2 still open: prefer exact/slug matches in `lookupContextTokens` (bidirectional `contains` misfires). Acceptance: misfire regression cases.
- **13.6.11 Non-streaming parse hardening (M3 ✅ DONE).** `as Map` casts replaced with `is` checks; non-map elements skipped exactly like the streaming path, so a hostile proxy can't smuggle a `TypeError` past retry classification. Acceptance: hostile-protocol test on both paths.
- **13.6.12 Tool scope + memory hygiene (M6, M7, M9).** Confine `bash working_directory` to the workspace root without persisting the mutation; push memory `find` filtering/scoring into SQL with `LIMIT`; pass `currentConversationId` as a resolver, not a construction-time value. Acceptance: CWD-escape test, memory-scale test, switch-conversation attribution test.
- **13.6.13 Persistence races (M17 ✅ DONE, M8 open).** M17: `ensureKey` serialized via `Completer` mutex (existing encrypt/decrypt suite still green). M8 still open: transaction-wrap `insertMessage` sort-order read-then-write. Acceptance: concurrent-insert and concurrent-init tests.
- **13.6.14 Document expansion accounting (M10).** Enforce the LRU ceiling against expanded bytes (`totalPartBytes`), not compressed `stat.size`; revisit the 4× expansion cap. Acceptance: zip-bomb fixture stays under budget in heap terms.
- **13.6.15 Native threads + broadcast policy (M11, M16).** Shared `ExecutorService` + timed `Future.get` for geocoding; allowlist broadcast actions at the Dart headless layer (native already blocks activities). Acceptance: hung-geocoder test terminates; non-listed broadcast rejected.
- **13.6.16 ChatScreen build hygiene (M13 ✅ DONE, M14 ✅ DONE, M12 open).** M13: `_animatedMessageIds` mutation moved to post-frame callback. M14: sidebar-watch `setState` gated on sidebar visibility (fields still update, pinned rows verified sidebar-only). M12 still open: precompute regenerate-target/latest-tool-group once per message list. Acceptance: build cost linear in messages; no build-time side effects.
- **13.6.17 Token estimation (M1 ✅ DONE).** ASCII at 3.8 chars/token, non-ASCII runs at 1.5 (CJK/emoji/Devanagari), pinned by unit test. Acceptance: Japanese conversation compacts before the real window overflows.
- **13.6.18 Low cleanup batch (L2/L4/L6/L9/L10 ✅ DONE; L5 ❌ refuted; L8 ❌ disputed; L1/L7 open).** Done: caught `getLocation` chain, mounted-guarded sheet `setState`, deleted ~80 lines of commented-out tools, `RepeatedToolFailureException` doc fix, HTTP-date `Retry-After`. L5 refuted — the import provides `CancelToken` (removal broke the build, reverted). L8 disputed — the `estimate*Chars` family has test callers, not dead. Open: L1 `ListenableBuilder`, L7 `_splitScreenHeader` dedup (churn exceeds value).

---

### 🟡 P14 — Everyday surface (QUEUED)

Goal: features a non-technical user understands in one sentence, built by composing shipped systems. No new engines.

#### P14.1 Briefing chips over composer

ChatGPT-style: 3–4 horizontally scrollable floating chips above the composer, generated from live state — morning briefing, unread task runs, follow-ups, contextual starters. Tapping a chip sends it (or pre-fills the composer). Dynamic per time-of-day and app state, cached per session, never blocking first frame.

Acceptance:
- Chips render post-first-frame from a cheap state read (no network on the critical path).
- Tap either sends or pre-fills (decided per chip kind, consistent).
- Empty/loading states degrade to hidden, never to spinners or stale chips.

#### P14.2 Read-aloud on assistant bubbles

`flutter_tts` play/stop button beside copy/retry at the end of assistant bubbles. Stops on new turn, screen disposal, or toggling; exactly one utterance at a time. Pairs with the existing voice widget into a complete eyes-free loop (mic in, speech out).

Acceptance:
- Play/stop state never desyncs from the engine (rapid taps, turn switches, disposal all covered by tests).
- No audio overlap: starting one utterance stops any active one.
- Respects silent/vibrate mode with a documented behavior (duck or skip, no crash).

#### P14.3 Conversations tool (title gen + scoped cross-reference)

One `conversations` tool, three actions. No raw SQL exec (prompt-injection via stored untrusted content, token bloat, schema coupling) — curated read paths with baked-in limits. `search` discovers, `recall` reads deep; excerpts never bloat search responses.

1. **`write_title` (self-scope, current convo only).** Agent proposes the title string in the call (no extra summarizer LLM call); tool sanitizes (length cap, strip quotes/"Chat about…" prefixes) and persists. System prompt triggers it once, end of first turn; renders in the grouped tool UI. Fallback is truncated first user message; re-title gated behind explicit request or extreme drift, never eager. No background jobs, no turn counters, no `write_summary` periodic job (titles + excerpts answer cross-referencing without summary infrastructure; summaries, if ever needed, generate lazily at title time).
2. **`search` (global, read-only) — two phases enforced server-side, never a full-corpus body scan.** Phase 1: keyword over all titles (tiny table, cheap) + recency-ranked recent-N → candidate convo IDs, never bodies. Phase 2: message-body scan restricted to those IDs, excerpt hits capped (10–20) with convo id + turn ref. Time is the primary limiter: default 30-day window, explicit `since`/`until`, recent-first with title-match boost; widening the window is an explicit second call, each step bounded.
3. **`recall` (current convo default, global by reference) — message-specific reads.** Fetches exact messages by convo id + message/turn ref plus a bounded context window (±N messages, capped), full bodies instead of excerpts. Convo ID omitted means current convo. Consumes references produced by `search`; nothing here discovers, everything here reads deep. Same read-only, UNTRUSTED-disciplined, headless-allowed posture as `search`.
- **Scope rules** (mirrors `schedule_task` `currentTaskId`): bind `currentConversationId`; `write_title` valid on current only; `search` reads everything, writes nothing; headless runs get `search` only (same policy as the memory tool). Returned rows keep UNTRUSTED discipline.
- **Latency posture:** plain `LIKE`, titles-before-messages, prefix-before-substring; duration marker on every call. FTS5 graduates from backlog only if measured p95 exceeds ~200ms or corpus passes ~50k messages.

Acceptance:
- No query path touches message bodies without a bounded convo-ID set (grep-able: every body query carries an ID filter + LIMIT).
- First-turn title appears via declared tool call with fallback proven by test (failing generation → truncated first message).
- Re-title never fires unprompted (test: topic drift without request leaves title intact).
- Search across a seeded multi-convo corpus returns excerpts with correct convo/turn refs inside one call; window widening demonstrated by test.
- `recall` by ref returns full bodies plus bounded context window; window cap enforced by test (over-wide request clamps, never unbounded).

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
