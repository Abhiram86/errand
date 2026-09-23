# Changelog

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
