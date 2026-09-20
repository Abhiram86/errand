# Next Plan — Status & Roadmap

> **Updated Sep 2026.** P0 through P5a (v0.5.5), v0.5.6, P5b (memory subsystem, schema v5), P6a (embedded browser agent tools, v0.6.0), v0.6.1 (background OTA updates, post-update release notes, model sorting by release date, dynamic provider defaults, unified options modal sheet, animated composer glow), v0.6.2 (default working directory to Documents/Errand, filesystem hygiene, scratch directory auto-creation), v0.6.3 (interactive bash safety modal, mid-stream LLM retry, Google OAuth user-agent sanitization, multi-window popups, overflow-free browser toolbar, and live model auto-selection on provider configuration), and v0.6.4 (hardened OTA update prompts, session-scoped dismissal, manual sidebar check, post-install cleanup, and error feedback) are all **SHIPPED**.
> **Active Milestone:** **P6b — Browser Rough Edges & Android PlatformView Optimizations**.

---

## 🧭 Active & Upcoming Roadmap

### 🟡 P6b — Browser Rough Edges & Android PlatformView Optimizations (ACTIVE)

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

### 🟡 P9 — Autonomous Scheduler & Headless Background Engine (ACTIVE)

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

#### 2. Headless Agent Runner Execution Slices (IN PROGRESS)

- **Slice 1: Tool Safety Guards for Headless Mode (COMPLETED)**
  - `bash`: `isHeadless: true`. Destructive operations needing confirmation (`rm -rf`, bulk deletions) fail fast with `headless_destructive_blocked`. Added bash arithmetic note (`echo \$((expr))`) in system prompt.
  - `schedule_task`: `isHeadless: true` and `currentTaskId`. Disallows `action: "create"` and `action: "delete"` with `headless_recursion_blocked`. Disallows editing other tasks outside `currentTaskId` with `headless_cross_task_edit_blocked`. Preserves `delay_seconds` alongside `starts_at` for relative time ease.
  - `memory`: `isHeadless: true`. Disallows background writes (`create`, `edit`) with `headless_memory_write_blocked`; allows introspection (`find`, `read`).
  - Unit tests verifying all guards in `test/headless_tool_guards_test.dart` and `test/schedule_task_tool_test.dart` (28/28 tests passing).

- **Slice 2: Headless Browser Service & Tool (COMPLETED)**
  - `HeadlessBrowserService`: Subclasses `BrowserService` using `HeadlessInAppWebView`.
  - 1-to-1 feature parity (`open`, `close`, `reload`, `snapshot`, `extract_text`, `execute_dom_js`, `act`, `screenshot` offscreen).
  - Testable with mock/injected controller override to enable robust unit and integration tests.
  - Completely detached from the Flutter chat widget tree (no UI popping or dock bar animations).
  - Clean `dispose()` and `disposeHeadlessView()` on turn completion.
  - `browserTool`: Updated to accept `isHeadless: true` and instantiate `HeadlessBrowserService` automatically.
  - Unit tests verifying offscreen operation, screenshots, parity, and teardown in `test/headless_browser_test.dart` (9/9 tests passing).

- **Slice 3: Headless System Prompt & ToolRegistry (COMPLETED)**
  - `headlessSystemPromptFor(...)`: Tailored prompt instructing the model it is running headlessly as a background task. Injects active execution context (task ID, title, workspace, scratch directory, user location). Enforces intent policy (alarms, timers, calendar entries allowed; UI app launches disallowed), output delivery to `.scratch/` (`task_<id>_<timestamp>.md`), bash math advice (`echo \$((expr))`), and headless tool rules. Strictly excludes interactive screen automation prompts.
  - `ToolRegistry.headless(...)`: Factory constructor registering the headless toolset (`read`, `bash`, `websearch`, `webfetch`, `intent`, `location`, `memory`, `browser`, `schedule_task`). Strictly excludes `screen`, `screen_act`, `act`, and `attached_files`. Passes `isHeadless: true` to `bash`, `memory`, `browser`, and `schedule_task`. Binds `currentTaskId` to enforce task edit isolation.
  - Unit tests in `test/headless_system_prompt_and_registry_test.dart` (7/7 tests passing).

- **Slice 4: Headless AgentRunner Integration & Lifecycle Hardening (COMPLETED)**
  - `AgentRunner.runHeadless(...)`: Executes an isolated, headless background agent turn for a scheduled task. Injects `ToolRegistry.headless`, binds `currentTaskId`, uses `headlessSystemPromptFor`, runs `AgentLoop` on a single-turn `Conversation`, saves the output markdown report to `.scratch/task_<id>_<timestamp>.md`, logs report save failures via `debugPrint`, and guarantees `registry.dispose()` cleanup in `finally`.
  - `TaskSchedulerService.executeTask(taskId, ...)`: Coordinates the full execution turn when an alarm or worker fires:
    - **Allowlist Guard & Atomic Claim:** Restricts execution to `status: scheduled` (or `failed` for manual retry); uses conditional SQL update `WHERE id = ? AND status IN ('scheduled', 'failed')` to atomically transition to `running`, preventing double-fire races between AlarmManager and WorkManager. Rejects already `running`, `completed`, `paused`, and `cancelled` tasks.
    - **Timeout & CancelToken:** Enforces execution timeout (`timeout`, default 10m) with `CancelToken` cancellation; logs `status: 'timeout'` on expiry.
    - **Resource Lifecycle:** Closes locally instantiated `LlmClient` instances in `finally` to prevent connection leaks.
    - **Resilient Recurring Retries:** Reschedules recurring tasks for `finishMillis + repeatAfter` on failure so transient glitches do not kill scheduled tasks, unless consecutive failures reach `retriesPerTurn`.
    - **Counter Reset:** Automatically resets `failures` to 0 upon successful execution.
    - **Bounded Notifications:** Safely clamps notification summary body to 250 characters before calling `NotificationService`.
    - **Recovery Sweep:** Provides `recoverStuckTasks()` to sweep and recover tasks left in `running` status after process kills or system crashes.
  - Unit tests in `test/headless_agent_runner_test.dart` (12/12 tests passing; 74/74 total tests across all scheduler & headless suites).

#### 3. Native Background Wake-Up & Task UI (UPCOMING)
- **Native AlarmManager & WorkManager:**
  - `AlarmManager` (`setExactAndAllowWhileIdle`): For exact wall-clock one-off alarms and tasks.
  - `WorkManager`: For recurring background tasks surviving reboots.
  - `BOOT_COMPLETED` receiver to reschedule active tasks on reboot.
- **Dedicated Tasks Screen:**
  - Full-screen UI (`TasksScreen` via `Navigator.push`), navigated from top of `ChatSidebar`. (NO nested bottom sheets).
  - In-app markdown preview for task reports in `.scratch/`.

---

### ✅ P6c — Filesystem Hygiene, Interactive Safety & Browser OAuth (COMPLETED)

Goal: Protect user storage from clutter, safeguard system integrity with session-bound interactive confirmation, and enable seamless browser authentication.

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

