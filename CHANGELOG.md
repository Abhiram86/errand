# Changelog

## 0.7.4

- **Background Engine Transports & Cancellation (P12.1):** Headless background engine now handles native non-UI intents and location queries; mid-run cross-isolate cancellation terminates runs promptly via durable database polling; per-task wake-lock renewals prevent timeout during queued batches.
- **Shell Safety & Headless Correctness (P12.2):** Closed static shell bypass vectors for `$VAR` command positions and `env` prefixes with fail-closed safety categorization; serialized same-batch `save_report` executions; corrected unread counts to terminal, actually-notified runs only.
- **Scheduler UI & Query Bounds (P12.3):** Replaced unbounded database watches with 400-row SQL LIMIT queries; unread badge powered by exact `COUNT(*)` query; task tabs receive latest-log-only per row; synchronous scratch scanning offloaded to a background isolate.
- **Browser Lifecycle & Robust Navigation (P12.4):** Deduplicated DOM click dispatching; load waiters complete immediately on close/stop without 15-second hangs; safe back navigation on active turns; safe headless disposal without notifying disposed change listeners.
- **Fast Startup & Persistence Serialization (P12.5):** Extracted `CoalescingWriter` to serialize overlapping conversation persistence; message sends and voice input gate on fast settings core without waiting for live model catalog sync.
- **OTA Verification, API Guards & CI (P12.6):** Added SHA-256 integrity validation and streaming timeouts for APK downloads; guarded Android API-26 calls (`startForegroundService`, `getHintText`, `setColorized`) for API 24/25 compatibility; separated notification permission request codes; added Lite flavor boundary tests and GitHub Actions CI.
- **Bounded Memory & Untrusted Input (P12.7):** 30MB aggregate per-turn media budget on content parts; byte-bounded (64MB) true LRU document cache with in-flight parse deduplication; byte-bounded (8MB) PDF unit cache; streaming raw byte cap (5MB) & inactivity timeout for webfetch; sandboxed HTML report previews with external browser link opening.

## 0.7.3

- **Drift-Free Recurring Scheduling:** Recurring tasks now anchor to the fixed cadence grid (`start_at + N * repeat_after`) to completely eliminate schedule drift over time.
- **Headless Streaming Runner:** Autonomous background runs now utilize streaming with a 5-attempt retry budget and forward-progress preservation on network glitches.
- **Notify on Fresh Kill:** Background task cancellation and abrupt termination cleanly record final statuses without ghost notifications.
- **Manage Tasks UI & Performance:** Borderless modern layout, schema v8 query indexes for instant tab loading, and granular sub-minute countdown timers.
- **Architecture Modularization:** Decomposed monolithic task screens and tool definitions into maintainable, modular components (`lib/widgets/tasks/`, `model_picker_dialog.dart`, `browser_scripts.dart`, `intent_docs.dart`).

## 0.7.2

- **Scheduler Correctness & Safety:** Force scheduler stream refresh on app resume to prevent stale running statuses.
- **Ghost Notification Prevention:** Deleting a task stops its in-flight run and cancels active notifications before removal.
- **Safe Mid-Run Races:** Hardened cancellation handling and database error recovery during concurrent task execution.

## 0.7.0

- **Autonomous Background Tasks:** Schedule one-off and recurring agent tasks that run headlessly via native Android `AlarmManager` without keeping the app open.
- **Manage Tasks Screen:** Full-screen dashboard to monitor tasks, inspect execution logs, filter by status, and preview output reports.
- **Headless Report Collection:** Background agent writes reports directly to `.scratch/task-$taskId.*` (HTML dashboards or Markdown) with in-app preview and automatic relocation.
- **Task Toast Service:** Global, decoupled toast notifications with dedicated icons and direct "View" actions across all screens.
- **Exact Alarm & Notification Routing:** Native exact-alarm permission guidance and notification taps linking directly to unread task logs.
- **Clamped Markdown Tables:** Assistant message tables with horizontal scrolling, cell truncation, and quick table copying.
- **Per-Task Model Overrides:** Set custom models and providers per scheduled task with persistence across recurring runs.

## 0.6.4

- Fixed OTA state after installing an update so the old install prompt does not return.
- Update dismissal now lasts for the current app session and appears again on the next app open.
- Added a sidebar action to check for the latest release immediately.
- Added clear feedback for update checks, unavailable device APKs, and failed downloads or installs.
- Kept release notes tied to the installed version and added startup ordering so update state is settled before release notes are shown.
