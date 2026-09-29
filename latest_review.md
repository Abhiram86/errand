# Code Review — Errand (`handy_flutter`) — Round 2

**Date:** 2026-09-30
**Commit reviewed:** `93c8c51` (33 commits ahead of tag `v0.7.4`)
**Supersedes:** the Round 1 review (2026-09-26, `C#`/`H#`/`M#`/`L#` IDs). All Round 1 items are
resolved and tracked as `P13.6.*` in `next_plan.md`; do not reuse those IDs.
**Scope:** 174 Dart files (~68.5K lines `lib/`), 12 Kotlin files (~4.7K lines), Gradle/manifest,
65 test files.

## How to use this file

- **IDs are stable and greppable.** Round 2 uses `R2-<severity><n>`:
  `R2-C*` critical · `R2-S*` security · `R2-H*` high · `R2-M*` medium · `R2-L*` low ·
  `R2-P*` performance · `R2-D*` duplication · `R2-R*` readability · `R2-F*` F-Droid.
  Cite the ID in commit messages and in `next_plan.md` (e.g. `13.6.20 (R2-C1)`).
- **Every finding was read and verified in the tree at `93c8c51`.** No speculative findings.
- **To claim an item done:** tick the box, add the commit SHA, and record the acceptance
  evidence (test name, or the exact check performed). A claim without evidence gets reopened.
- **Two items in `next_plan.md` are marked ✅ DONE but are not actually fixed on all paths.**
  See [§7](#7-claimed-fixed-but-still-open-on-some-paths-read-this-before-trusting-p136). Fix or
  re-triage these before starting new work.

## Verification baseline

| Check | Result |
|---|---|
| `flutter analyze` | ✅ clean, 0 issues |
| `flutter test` | ✅ 760/760 passing |
| `flutter --version` | 3.47.1 stable · Dart 3.13.1 |
| Build config | AGP 9.1.0 · Kotlin 2.4.0 · Gradle 9.3.1 · compile/target SDK 36 · minSdk 24 |
| Licence | MIT (`LICENSE`) — SPDX-clean |
| Secrets | none committed; `.env` untracked and gitignored |
| Deps | all BSD/Apache/MIT; no GMS/Firebase/proprietary SDKs |

The codebase is in genuinely good shape. The findings below are concentrated in the
native Android layer and in a handful of concurrency paths — not spread evenly.

---

## Priority order

Fix in this order. Each row is independently shippable.

| # | ID | Severity | One-line |
|---|---|---|---|
| 1 | `R2-C1` | **CRITICAL** | `FileProvider` exposes the whole filesystem; `open_file` takes LLM-controlled paths |
| 2 | `R2-F1` | **BLOCKER** | In-app OTA updater conflicts with F-Droid Inclusion Policy §5 |
| 3 | `R2-H1` | HIGH | `dataSync` FGS never handles `onTimeout()` → `RemoteServiceException` |
| 4 | `R2-H2` | HIGH | `AgentForegroundService` has no self-timeout → burns the shared 6h budget |
| 5 | `R2-H3` | HIGH | Foreground engine can't post notifications (`app_info` channel gap) |
| 6 | `R2-H4` | HIGH | Background engine blocks the platform thread up to 8s on geocoding |
| 7 | `R2-H5` | HIGH | Boot alarm restore reads a credential-encrypted WAL DB in direct boot |
| 8 | `R2-H6` | HIGH | Inexact-alarm fallback can't legally start an FGS → tasks never run |
| 9 | `R2-H7` | HIGH | `_runAgentTurn` has no re-entrancy guard → double agent turn |
| 10 | `R2-H8` | HIGH | `DocumentLruCache` double-inserts → inflated accounting + disposed-PDF use |
| 11 | `R2-H10` | HIGH | `dispose()` saves outside `CoalescingWriter` → lost final answer |
| 12 | `R2-H11` | HIGH | Single-task Resume never recomputes `nextRunAt` |
| 13 | `R2-R1` | HIGH* | 657-line shell-safety method — unreviewable, and it guards `rm -rf` |
| 14 | `R2-F2..F7` | BLOCKER* | F-Droid metadata, tags, Flutter pin, cache-mutating Gradle hook |
| 15 | `R2-H7` | HIGH | All a11y channel handlers run on the platform thread, uncapped |
| 16 | `R2-D1`, `R2-D2` | MED | Two biggest duplication extractions |

---

## 1. Security

### [ ] R2-C1 — CRITICAL — `FileProvider` exposes the entire device filesystem, driven by LLM output

**Files:** `android/app/src/main/res/xml/file_paths.xml:8` · `MainActivity.kt:455-503` · `MainActivity.kt:1094-1118`

```xml
<root-path name="root" path="." />
```

`root-path` maps *every* path on the device into the provider's namespace. Two handlers turn an
**agent-supplied string** directly into a `content://` URI carrying `FLAG_GRANT_READ_URI_PERMISSION`
and hand it to a third-party app:

- `open_file` / `open_url` — any `data` starting with `/` or `file://`; the only check is `file.exists()`.
- `installApk` — an arbitrary `filePath`.

Because the LLM produces those strings, a prompt-injected web page or a hostile tool result can
exfiltrate `/data/data/...`, key material, or other apps' databases. `MANAGE_EXTERNAL_STORAGE` in the
main manifest widens the readable set further.

**Fix**
1. Delete `<root-path name="root" path="." />`. Keep `<external-files-path>`, `<cache-path>`,
   `<files-path>`, and a narrowly scoped `<external-path path="Download/"/>` if genuinely needed.
2. In both handlers, canonicalize and enforce containment before `getUriForFile`:
   ```kotlin
   val f = File(rawPath).canonicalFile
   val allowed = listOf(workspaceDir, scratchDir, cacheDir).map { it.canonicalFile }
   if (allowed.none { f.toPath().startsWith(it.toPath()) }) {
       result.error("PATH_NOT_ALLOWED", "Path outside allowed roots", null); return@setMethodCallHandler
   }
   ```
3. Add a MIME allowlist instead of the `else -> "*/*"` fallthrough (`MainActivity.kt:493`).

**Acceptance:** a test asserting `/data/data/com.errand.errand/...` and `/etc/hosts` are rejected by
`open_file`, and that `FileProvider` no longer resolves a path outside the allowed roots.

### [ ] R2-S1 — HIGH — OTA install has no native integrity re-check and fails open

**Files:** `MainActivity.kt:1094-1118` · `lib/services/update_service.dart:560-564, 642-655, 704-708`

`installUpdate` calls `downloadApk` with the default `requireSha256 = false`, so a release with no
published checksum is installed on a **size check alone**. The native handler performs no
verification of its own, so a Dart-side bypass skips the digest entirely. Android does enforce the
signing-key match, so this is not arbitrary code — but a corrupted or downgraded binary is not
detected, and there is no anti-rollback check on `versionCode` anywhere natively.

**Fix:** default `requireSha256 = true`; re-verify the digest natively in `installApk` immediately
before firing the intent; consider rejecting `longVersionCode < installed`.

### [ ] R2-S2 — MEDIUM — `MANAGE_EXTERNAL_STORAGE` + `QUERY_ALL_PACKAGES` need justification

**File:** `AndroidManifest.xml:4, 8`

Both are declared in the **main** manifest, so they land in Full *and* Lite *and* debug. Both are
policy-restricted. `tools:ignore="QueryAllPackagesPermission"` silences lint but satisfies nothing
at F-Droid review or Play review. Note the app already declares a rich `<queries>` block
(`AndroidManifest.xml:115+`), so a good part of `QUERY_ALL_PACKAGES` may be droppable outright.

**Fix:** try removing `QUERY_ALL_PACKAGES` and measure what breaks — the `<queries>` block likely
already covers the needed visibility. Whatever remains, document in the F-Droid metadata.

### [ ] R2-S3 — MEDIUM — Adaptive launcher icon used as notification small icon

**Files:** `AgentForegroundService.kt:81` · `TaskExecutionService.kt:806` · `NotificationHelper.kt:78`

All three use `applicationInfo.icon` / `ic_launcher`, which resolves to
`mipmap-anydpi-v26/ic_launcher.xml` — an `<adaptive-icon>`. Adaptive icons are invalid as
notification small icons; the system renders a blank/white silhouette or drops the notification on
stricter launchers. `NotificationHelper` avoids it only when `isSuccess != null`, in which case it
uses `android.R.drawable.*` system icons that also tint badly.

**Fix:** add `res/drawable/ic_stat_errand.xml` (single-colour vector, white on transparent) and use
it in all three builders.

---

## 2. Platform / Android API correctness

### [ ] R2-H1 — HIGH — Neither `dataSync` foreground service implements `onTimeout()`

**Files:** `AgentForegroundService.kt:49-52` · `TaskExecutionService.kt:120-140` · `AndroidManifest.xml:92, 123`

Both services declare `android:foregroundServiceType="dataSync"` with
`FOREGROUND_SERVICE_DATA_SYNC` correctly declared, so the Android 14 type requirement is satisfied.
What is missing is the **Android 15+ timeout contract**: `dataSync` gets 6h per 24h, after which the
system calls `Service.onTimeout(int, int)`. Neither class overrides it and the framework default does
not stop the service, so the system throws:

```
Fatal Exception: android.app.RemoteServiceException: "A foreground service of
type dataSync did not stop within its timeout: [component name]"
```

The second half bites earlier: once the budget is exhausted, `startForegroundService` throws
`ForegroundServiceStartNotAllowedException("Time limit already exhausted…")`, which is swallowed at
`MainActivity.kt:754-761` and `TaskExecutionService.kt:61-71` — so scheduled tasks silently stop
running with no user-visible signal.

**Fix** in both services:
```kotlin
override fun onTimeout(startId: Int, fgsType: Int) {
    ServiceCompat.stopForeground(this, Service.STOP_FOREGROUND_REMOVE)
    stopSelf(startId)
}
```
Also surface the "exhausted" exception to Dart instead of swallowing it. See `R2-H2` for the other half.

### [ ] R2-H2 — HIGH — `AgentForegroundService` has no self-timeout and never calls `stopForeground`

**File:** `AgentForegroundService.kt:33-52` · driven from `lib/services/intent_service.dart:91-101`
(called at `chat_screen.dart:918, 1998, 2110, 2148, 2364`)

The service lives exactly as long as Dart says so. Every failure path between `startWorkIndicator` and
`stopWorkIndicator` — exception, early `return`, widget/dialog flow, agent crash — leaves a live FGS
pinned with an `setOngoing(true)` notification. That permanently consumes the shared 6h `dataSync`
budget from `R2-H1`, after which every future turn *and* every scheduled task fails to start.

`onStartCommand` also uses the legacy 2-arg `startForeground` with no type.

**Fix:** `mainHandler.postDelayed({ stopSelf() }, 15 * 60_000L)` in `onStartCommand`, and
`ServiceCompat.stopForeground(this, Service.STOP_FOREGROUND_REMOVE)` on the exit path.
`TaskExecutionService` is better behaved (bounded by watchdogs) but shares the missing `onTimeout`.

### [ ] R2-H3 — HIGH — Foreground engine cannot post notifications (`app_info` channel gap)

**Files:** `MainActivity.kt:1063-1120` · `lib/services/notification_service.dart:5, 26, 76-91`

`NotificationService` targets channel `"app_info"` and calls `hasNotificationPermission`,
`showNotification`, `cancelNotification`, `requestNotificationPermission`. The **foreground** engine's
`app_info` handler implements only `getVersion`, `getAppInfo`, `installApk` — everything else hits
`result.notImplemented()`.

Consequence chain:
- `hasPermission()` (`:76-84`) catches the `MissingPluginException` and returns **`false`**.
- `showNotification` then returns `false` at `:26` *before* ever invoking the channel — so its own
  `task_scheduler` fallback at `:39` is unreachable on this path.

The background engine **does** implement them (`TaskExecutionService.kt:465-487`), which is why this
only bites when the UI engine is alive. Separately, `requestNotificationPermission` is handled only
on the `"intent"` channel (`MainActivity.kt:772`), so `NotificationService.requestPermission()` is a
silent no-op — POST_NOTIFICATIONS is only ever requested via `IntentService` (`chat_screen.dart:335`).

**Impact is narrower than it first appears:** the main completion path (`task_scheduler_service.dart:1328`)
is gated on `!suppressNotification`, and the one foreground caller
(`spacey_task_row._runNow`) passes `suppressNotification: true`. It bites on the *failure* branches
(`task_scheduler_service.dart:927, 1025, 1107`) which do not check the flag.

**Fix:** add `"showNotification" | "cancelNotification" | "hasNotificationPermission"` to
`MainActivity`'s `app_info` branch, delegating to `NotificationHelper` exactly as
`TaskExecutionService` does. Better: point `NotificationService` at a single channel that both
engines implement identically — this class of bug is structural.

### [ ] R2-H4 — HIGH — Background engine blocks the platform thread up to 8s on geocoding

**File:** `TaskExecutionService.kt:553-582`

MethodChannel handlers run on the platform thread. This one calls `geocodeFuture.get(8, TimeUnit.SECONDS)`
**inline** (`:559`) against `Geocoder.getFromLocation`, which is network I/O. Any background task
using the `location` tool freezes the main looper for up to 8s (guaranteed jank, ANR risk), and
`mainHandler.post { result.success(data) }` at `:575` only runs *after* the block. It also allocates
and `shutdownNow()`s a new `Executors.newSingleThreadExecutor()` on every call.

`MainActivity.kt:1218-1249` shows the correct pattern: `geocodeExecutor.execute { … }` with a
long-lived `newCachedThreadPool()` field, offloading the whole thing.

> ⚠️ `next_plan.md` `P13.6.15` marks this **✅ DONE** — the fix landed in `MainActivity` only. See §7.

**Fix:** mirror `MainActivity` — one long-lived executor field on the service, offload the entire
geocode, `mainHandler.post` the reply. Shut the executor down in `onDestroy`.

### [ ] R2-H5 — HIGH — Boot alarm restore reads a credential-encrypted WAL DB in direct boot

**Files:** `TaskAlarmRestorer.kt:63-67, 134-140` · `AndroidManifest.xml:106`

Two compounding problems:
1. Drift opens `errand.sqlite` in **WAL** mode. A connection opened `OPEN_READONLY` against a WAL
   database needs write access to the `-shm`/`-wal` sidecars; without it SQLite throws
   (`attempt to write a readonly database` / `disk I/O error`).
2. `android:directBootAware="true"` runs the receiver **before the user unlocks**, but the DB is
   resolved from `context.getDir("flutter", MODE_PRIVATE)` (`:137`) — credential-encrypted storage,
   inaccessible in direct boot. `File.exists()` returns false or the open throws.

Either way the exception is classified `retryable = true` (`:118, :122`) and alarms are simply never
restored. The user sees no tasks fire until they open the app once, and `TaskBootReceiver.kt:37`
schedules a retry job that hits the identical wall.

**Fix:** drop `directBootAware` from the receiver (the restore only needs the DB readable *after*
unlock), **or** move the DB into `context.createDeviceProtectedStorageContext()`. Also open
`OPEN_READONLY` only after confirming no `-wal` file, else fall back to a read-write open so WAL
recovery can run.

### [ ] R2-H6 — HIGH — Inexact-alarm fallback cannot legally start a foreground service

**Files:** `TaskAlarmManager.kt:83-99` → `TaskAlarmReceiver.kt:30` → `TaskExecutionService.kt:61-71`

`SCHEDULE_EXACT_ALARM` is declared (not `USE_EXACT_ALARM`), so exact alarms are **not** pre-granted
to fresh installs on Android 14+. `scheduleExactAlarm` therefore catches `SecurityException`, logs,
downgrades to `setAndAllowWhileIdle`, and returns `false`. The alarm then fires into
`TaskAlarmReceiver`, which calls `startForTask` → `startForegroundService` **from a
BroadcastReceiver**.

The background-activity-launch exemption that permits this applies to **exact** alarms only. With the
inexact fallback, Android 12+ throws `ForegroundServiceStartNotAllowedException`, caught and only
`Log.e`'d at `:70`. The scheduled task never runs and nothing tells the user or Dart.

Compounding: Dart only emits a `debugPrint` for the `false` return
(`task_scheduler_service.dart:611-616`), which is stripped in release.

**Fix:** for the inexact path use `WorkManager`/`JobScheduler` (a `JobService` is exempt) instead of
an FGS. Call `canScheduleExactAlarms()` once before the first `scheduleAlarm` of a session and
surface the existing `openExactAlarmSettings` prompt — the capability is already implemented on both
engines but never consulted from the schedule path (see `R2-M3`).

### [ ] R2-H7 — HIGH — Accessibility tree operations run on the UI thread with uncapped walks

**Files:** `MainActivity.kt:893-1054` · `ErrandAccessibilityService.kt`

All a11y channel handlers run synchronously on the platform thread, calling `result.success(...)`
inline. Unlike the geocode path, nothing is offloaded:
- `readScreen` walks up to **1000 nodes / 32 000 chars** (`:179-189`) and sorts a 12k-char string per call.
- `collectMatchingClickable` (`:1028-1053`) has **no depth limit and no node cap**, calling
  `AccessibilityNodeInfo.obtain(node)` per label match — thousands of binder-backed objects on Gmail,
  Settings, Chrome.
- `findScrollable` (`:1226-1247`) is likewise depth-uncapped; `subtreeContainsText` re-walks subtrees.
- `scroll` can issue up to **30 back-to-back `performAction` calls** in a tight loop with no settle
  delay (`:1173-1176`).

**Fix:** run the whole a11y API on a dedicated single-thread executor and `post` the result to the
main thread. `PdfReaderPlugin.kt:42-61` already demonstrates the correct pattern. Add explicit
depth/node caps to `collectMatchingClickable` and `findScrollable`, and yield between scroll repeats.

### [ ] R2-M1 — MEDIUM — Accessibility service is force-disabled on activity finish and task removal

**Files:** `MainActivity.kt:249-254` · `ErrandAccessibilityService.kt:114-119`

```kotlin
// MainActivity.onDestroy
if (isFinishing) { ErrandAccessibilityService.instance?.disableSelf() }
// ErrandAccessibilityService.onTaskRemoved
disableSelf()
```

Pressing Back, or swiping Errand out of recents, silently switches off a system-level accessibility
service the user had to grant in Settings. This is the single biggest driver of "a11y randomly
stopped working" reports, and it makes the explicit `a11y`/`disable` method (`MainActivity.kt:880-892`)
redundant.

**Fix:** remove both `disableSelf()` calls; keep the explicit user-initiated `disable` method.

### [ ] R2-M2 — MEDIUM — `goAsync()` broadcast does unbounded DB + N-alarm work

**Files:** `TaskBootReceiver.kt:31-51` · `TaskAlarmRestorer.kt:83-104`

`pendingResult` is held until the thread finishes; the restore opens SQLite and registers one
`AlarmManager` alarm per `scheduled` row sequentially. With a large task table (or a slow WAL
checkpoint from `R2-H5`) this exceeds the ~10s `BroadcastReceiver` window → "did not finish" ANR,
which on Android 14+ also blocks boot.

**Fix:** cap alarms re-registered per broadcast (e.g. 200), log the remainder, and hand the rest to
`TaskAlarmRestorer.scheduleRetry`, which already exists and is correctly off the critical path.

### [ ] R2-M3 — MEDIUM — `canScheduleExactAlarms()` exists but is never consulted

**Files:** `TaskAlarmManager.kt:66-99` · `lib/services/task_scheduler_service.dart:611-616, 733-750`

Implemented on both engines, never called from the schedule path. See `R2-H6`.

### [ ] R2-M4 — MEDIUM — One shared `PendingIntent` (requestCode 0 + `FLAG_UPDATE_CURRENT`) per launch

**Files:** `MainActivity.kt:612-618, 669-675`

`PendingIntent` equality ignores extras, so two agent launches with the same action + data URI resolve
to the *same* pending intent and `FLAG_UPDATE_CURRENT` overwrites the first one's extras before
delivery. Concretely: two `mailto:` to the same address with different bodies, back to back. Since
`pi.send()` is asynchronous on Android 14+, the window is real.

**Fix:** use a monotonic `AtomicInteger` request code, or a unique data URI
(`Uri.parse("errand://launch/$n")`), per launch.

### [ ] R2-M5 — MEDIUM — `PendingIntent`s for background activity starts are never cancelled

**Files:** `MainActivity.kt:612, 669` · `AgentForegroundService.kt:67-70` · `TaskExecutionService.kt:790-797`

Each `PendingIntent.getActivity(...)` leaves a live system-side `PendingIntent` holding the target
component after `send()`. The API-34 branch creates one per agent intent action, unbounded per session.

**Fix:** hold the reference and `cancel()` it in a `finally` after the send completes (the send is
async, so cancel on the reply callback).

### [ ] R2-M6 — MEDIUM — 13-minute `PARTIAL_WAKE_LOCK` with no `WorkSource`

**Files:** `TaskExecutionService.kt:112-117, 172-182`

Both `newWakeLock` sites use the 1-arg constructor. On Android 11+ a wakelock without a work source
is unattributed and billed entirely to the app's uid. The 13-minute ceiling also exceeds the Dart-side
10-minute task cap, so a wedged run holds CPU for 3 minutes past the abort.

**Fix:** drive the work through `WorkManager` (which sets the source), or shorten the timeout to the
Dart cap and add `acquire(…, WorkSource)` where the API allows.

### [ ] R2-M7 — MEDIUM — `LocationListener` + 8s `Runnable` outlive the activity

**File:** `MainActivity.kt:1305-1338`

`lm.requestLocationUpdates(...)` is registered but never removed in `onPause`/`onDestroy`; the
timeout `Runnable` is only cancelled on the fix/cancel paths. If the activity is destroyed mid-request
the listener keeps the `LocationManager` binding alive and `result` completes on a detached engine.
The `try/catch` around `result.error` (`:1334`) masks it.

**Fix:** hold both in fields; `lm.removeUpdates(...)` + `handler.removeCallbacks(...)` in `onDestroy`.

### [ ] R2-M8 — MEDIUM — IME primitives are indistinguishable from "no field focused"

**File:** `ErrandAccessibilityService.kt:1341-1346, 879-891, 1430-1443`

`imeReady()` returns null whenever `getInputMethod()` is null. That method only returns non-null if
the *system* additionally granted the restricted input-method role (a separate toggle from enabling
the accessibility service, API 33+). All four IME entry points then return `NO_INPUT_FOCUS`, whose
message ("try global back instead" / "tap the field first") actively misleads the agent and the user.

**Fix:** distinguish `IME_ROLE_MISSING` (inputMethod == null) from `NO_INPUT_FOCUS` (no connection),
and detect the role via `Settings.Secure.DEFAULT_INPUT_METHOD` so the UI can prompt for it.

### [ ] R2-L1 — LOW — Contract/doc mismatches and deprecated-API residue

- **`globalAction` throws where Dart expects a string.** `ErrandAccessibilityService.kt:896` returns
  the message via `result.error("ACTION_ERR", err)`, but `lib/services/a11y_service.dart:144-149`
  documents *"returns null on success, an error message string otherwise"*. `invokeMethod` therefore
  throws `PlatformException` and the user sees
  `"Screen failed: PlatformException(ACTION_ERR, LOCK_SCREEN needs API 28+)"` via `screen_tool.dart:108`.
  Fix by returning `result.success(err)`, or catch `PlatformException` at `screen_tool.dart:275`.
- **`cancelNotification` id validation differs between engines.** `MainActivity.kt:798` returns
  `success(false)` for any missing/`<=0` id; `TaskExecutionService.kt:457-459` requires `id > 0`. Latent
  (Dart always sends positive), but align them.
- **Dead code:** `startForReschedule` / `ACTION_RESCHEDULE_ALL` (`TaskExecutionService.kt:53, 74-87`)
  are never called; if wired up they would fail on Android 12+ for the same reason as `R2-H6`.
- **Deprecated:** `stopForeground(true)` (`TaskExecutionService.kt:158`) → `ServiceCompat`;
  `getPackageInfo(pkg, 0)` (`MainActivity.kt:1067, 1075`) → `PackageInfoFlags.of(...)` (the
  permissions variant at `:329-337` already does it correctly); `getInitialRoute()` (`MainActivity.kt:76`).

---

## 3. Dart bugs

### [ ] R2-H8 — HIGH — `_runAgentTurn` has no re-entrancy guard → double agent turn

**Files:** `chat_screen.dart:1857-1872` (`_regenerate`) · `:1965-1995` (`_runAgentTurn`)

`_regenerate` checks `_busy` at entry, then `await _truncateFrom(...)` — a real async gap of arbitrary
length (it awaits `database.deleteMessage()` in a loop) — then calls `await _runAgentTurn()`.
`_runAgentTurn()` has **no `_busy` check of its own**; it only sets `_busy = true` inside its
`setState` at `:1994`.

Two taps on Retry/Regenerate within the truncation window both pass the guard and both reach
`_runAgentTurn`: two concurrent `AgentLoop`s against the same `_messages` and `_cancelToken`.

**Impact:** two LLM streams writing into the same working-message id, two `ToolRegistry`s, two final
answers (last write wins), two `_persistNow()` calls.

**Fix:** latch synchronously before any `await`:
```dart
if (_turnInFlight || _busy) return;
_turnInFlight = true;
try { /* … */ } finally { _turnInFlight = false; }
```

### [ ] R2-H9 — HIGH — `DocumentLruCache` double-inserts on the in-flight dedup path

**File:** `lib/tools/file_tools.dart:109-158`

The in-flight dedup (`:110-125`) lets N concurrent callers await the *same* `Future<LogicalDocument?>`.
Every one then falls through to the insertion block (`:127-155`) unconditionally:

- `_currentBytes += entrySize` runs N times for the same `key` (the map insert just overwrites), so
  `_currentBytes` inflates permanently and the eviction loop then evicts everything — degrading the
  cache to size-1 permanently.
- Worse, two different keys can hold **the same `LogicalDocument` instance**. When one key is evicted,
  `evicted.document.dispose()` runs (`:106, :144`) while the other key still references it. For a
  `PooledPdfDocument` that closes the native `PDDocument`, and a concurrent `read` then throws
  `StateError: Cannot read from a disposed PDF document.`

**Fix:** only the initiator inserts/evicts/accounts — guard the block with `if (isInitiator)`. Add a
`refCount` to `_CachedStructuredDocument` so `dispose()` runs only when the last reference drops.

### [ ] R2-H10 — HIGH — `dispose()` saves the final snapshot outside `CoalescingWriter`

**File:** `chat_screen.dart:909-935` (specifically `:919-926`)

```dart
_persistTimer?.cancel(); _persistTimer = null;
if (currentId != null) {
  unawaited(database.saveConversation(_snapshotConversation()));
}
```

This bypasses `_persistWriter` (`:201`, used at `:1336`). If a writer run is in flight, two
`saveConversation` transactions race; if the fire-and-forget one lands *first*, the older in-flight
snapshot overwrites it and the final streamed answer is lost from SQLite.

**Fix:** `unawaited(_persistWriter.run(() => database.saveConversation(_snapshotConversation())));`

### [ ] R2-H11 — HIGH — Single-task "Resume" never recomputes `nextRunAt`

**Files:** `spacey_task_row.dart:352-372` · correct reference impl `task_scheduler_service.dart:665-690`

Pausing writes only `status`/`updatedAt`. Resuming writes only `status = 'scheduled'` — `nextRunAt`
keeps its pre-pause value. `scheduleTask` (`task_scheduler_service.dart:600-603`) then does
`triggerAt = targetTime > nowMillis ? targetTime : nowMillis + 1000`, so **a task paused for a week
fires 1 second after resume** instead of at the next cadence slot. `resumeAllTasks()` (`:665-690`)
handles exactly this case with `calculateNextRunAt`; the single-task path does not.

**Fix:** recompute `nextRunAt` in the resume branch the same way `resumeAllTasks` does — or, better,
delete both hand-rolled versions and add `TaskSchedulerService.setPaused(taskId, bool)` (see `R2-D7`).

### [ ] R2-M10 — MEDIUM — SSE stream parsing uses unchecked casts that crash the turn with a raw `TypeError`

**File:** `lib/llm/llm_client.dart:641, 643, 709, 713`

```dart
final choices = data['choices'] as List<dynamic>? ?? const [];   // 641
final choice  = choices.first as Map<String, dynamic>;          // 643
accumulated.id   ??= toolCall['id'] as String?;                 // 709
accumulated.name ??= function['name'] as String?;               // 713
```

Every neighbouring branch in the same function guards carefully (`if (raw is! Map<String,dynamic>) continue;`
at `:692`, `error is Map` at `:624`). A non-conforming proxy returning `choices: "boom"` or `id: 42`
throws a `TypeError` that is **not** a `LlmException`, so it is not retried and surfaces as
`Unexpected error: type 'String' is not a subtype of type 'Map<String, dynamic>'`.

> ⚠️ `next_plan.md` `P13.6.11` claims this was fixed. See §7.

**Fix:** `if (choices.isEmpty) continue; final raw = choices.first; if (raw is! Map<String, dynamic>) continue;`
and `toolCall['id'] is String ? … : null`.

### [ ] R2-M11 — MEDIUM — `LlmClient.chat` `jsonDecode` is unguarded

**File:** `lib/llm/llm_client.dart:194`

A 200 response that is an HTML error page or truncated proxy body throws `FormatException`, which is
not a `LlmException` → not classified as transport → no retry, and the user sees
`Unexpected error: FormatException: Unexpected character`. Everything downstream in the same function
is properly validated.

**Fix:** wrap in `try { … } on FormatException catch (e) { throw LlmException('Malformed response: $e', transport: true); }`.

### [ ] R2-M12 — MEDIUM — `_backoff` polls in 100ms steps with an uncapped `Retry-After`

**File:** `lib/llm/llm_client.dart:308-330`

```dart
final delay = backoffDuration?.call(attempt) ??
    (seconds != null && seconds >= 0 ? Duration(seconds: seconds)
                                     : Duration(milliseconds: 800 * (1 << (attempt - 1))));
final stopwatch = Stopwatch()..start();
while (stopwatch.elapsed < delay) { … await Future.delayed(step <= 100ms); }
```

A server returning `Retry-After: 7200` produces **72 000 Timer round-trips** on the UI isolate (~30+
minutes of 10Hz wakeups) for one retry. `DateTime.now()` is also sampled once per iteration. There is
no ceiling on `seconds`, and the exponential fallback `800 * (1 << (attempt-1))` is uncapped — with
`maxAttempts: 5` in the headless path (`task_scheduler_service.dart:1078`) that is ~25s per redial,
repeatedly, on battery.

**Fix:** clamp the server hint (`min(seconds, 60)`), cap the exponential fallback with a named
constant, and use a single cancellable delay registered on the `CancelToken` (which already has
listeners) instead of the polling loop. Respect `Retry-After` as an upper bound, not only a lower one.

### [ ] R2-M13 — MEDIUM — `CoalescingWriter` silently drops the trailing write if `write()` throws

**File:** `lib/utils/coalescing_writer.dart:19-36`

```dart
do { _needsTrailing = false; await write(); } while (_needsTrailing);
} finally { _active = null; completer.complete(); }
```

If `write()` throws, the loop exits via the exception, `_needsTrailing` is discarded, and every caller
that set it (`await _active; return;` at `:22-23`) resolves as if its write completed. In
`_persistConversation` the error is caught and only `debugPrint`ed (`chat_screen.dart:1343-1345`), so a
transient `SQLITE_BUSY` during the final `_persistNow()` silently loses the assistant's final answer.
This compounds `R2-H10`.

**Fix:** catch inside the loop, reset `_needsTrailing = false` in the `finally`, and record
`lastError` so `run()` can rethrow to the caller that owned the write.

### [ ] R2-M14 — MEDIUM — Native `PDDocument` leak: the `Finalizer` safety net cannot work

**Files:** `lib/internal/document_reading/pdf_reader.dart:73-77, 101, 189` · `PdfReaderPlugin.kt:82, 138`

The native map `openDocuments: ConcurrentHashMap<String, PDDocument>` is only emptied by an explicit
`closePdf` channel call. The Dart GC safety net is:
```dart
static final _finalizer = Finalizer<_PdfFinalizerToken>((token) {
  try { token.channel.invokeMethod('closePdf', …).catchError((_) {}); } catch (_) {}
});
```
A Dart `Finalizer` callback runs on a finalizer thread with **no `BinaryMessenger` binding**, so
`invokeMethod` is a no-op or throws and is swallowed. Every path relying on it leaks a `PDDocument`
(memory-mapped file handle, up to 64MB) for the process lifetime. `TaskExecutionService.kt:491`
registers the plugin and **discards the returned `Pair`**, so `closeAll()` is unreachable for that
engine — which is destroyed and recreated every task-batch cycle.

**Fix:** drop the `Finalizer` (dead weight), bound the native side instead — cap `openDocuments.size`
and close the LRU entry in `openPdf` — and call `closeAll()` from engine teardown.

### [ ] R2-M15 — MEDIUM — `repeat_after` is unvalidated → int64 overflow → 1-second task loop

**Files:** `schedule_task_tool.dart:152-158` · `task_scheduler_service.dart:846-856, 600-603`

`_parseIntArg` accepts any positive int from the LLM. `calculateNextRunAt` computes
`startsAt + (n * repeatAfter)` with no overflow guard. For `repeat_after ≈ 9.2e18` the sum wraps
negative, `nextRunAt` is stored as a negative epoch, the `targetTime > nowMillis` check fails →
`triggerAt = nowMillis + 1000`. The task then **re-runs every second forever**, each run writing a log
row and a scratch report.

**Fix:** clamp at the tool boundary (`repeatAfter.clamp(60_000, 366 * 24 * 3600 * 1000)`) and add a
defensive floor `if (nextRun <= nowMillis) return nowMillis + 60000;` in `calculateNextRunAt`.

### [ ] R2-M16 — MEDIUM — Race in tool-output spill: shared `.part` temp file

**File:** `lib/services/tool_output_file_service.dart:150-152`

```dart
final tmp = File('${file.path}.part');
await tmp.writeAsString(stored, flush: true);
await tmp.rename(file.path);
```

The filename is derived deterministically from `callId` (`:117-126`). Two concurrent `processOutput`
calls for the same `callId` (LLM retry reusing an id, a stateless batch duplicating a call, or
`maybeSpillResult` racing a per-tool `processOutput`) write the same `.part`; the loser's `rename`
throws `FileSystemException` because the source is gone, failing the whole tool result.

**Fix:** make the temp name unique (`.${DateTime.now().microsecondsSinceEpoch}.part`) or serialise per
`callId` behind an in-flight map.

### [ ] R2-M17 — MEDIUM — Repeated notification taps push duplicate `ManageTasksScreen` routes

**File:** `lib/main.dart:154-170, 250-267`

`_notificationRouteOpened` is *set* in `_navigateToUnreadTasks` but never *read* as a guard, and
`_navigateToUpcomingTasks` has no guard at all. Every live `onTaskNotificationClicked` calls
`_navigateToUnreadTasks()` → `push(...)`. Three taps, or a live tap racing the cold-launch pending-click
route (`:143-150` vs `:154`), stacks multiple identical screens.

**Fix:** guard both with `if (_notificationRouteOpened) return;`.

### [ ] R2-M18 — MEDIUM — Unread-count semantics diverge between badge and service

**Files:** `task_scheduler_service.dart:397-411` · `manage_tasks_screen.dart:94-100`

Service: `status.isIn(['success','failed','timeout','cancelled'])`. Screen (`customSelect`):
`status != 'running'`. Any future/legacy status (e.g. `'pending'`, `'skipped'`) is counted by the badge
but not by `unreadNotificationCount()`, so "Mark all as read" and the startup banner can disagree with
the tab badge.

**Fix:** extract one shared predicate/SQL fragment and use it in both places.

### [ ] R2-L2 — LOW — Smaller correctness nits

- **`TextEditingController` leaked on every rename.** `chat_screen.dart:1701` creates it, hands it to a
  `TextField`, never disposes. Dispose after the `await showDialog(...)` returns.
- **`nextOffset` deliberately re-emits the last unit.** `document_models.dart:88`
  (`hasMore && end - offset > 1 ? end - 1 : end`) duplicates one unit on every page boundary, so paged
  PDF/DOCX reads inject a repeated block and re-fetch an already-cached page. If unintentional, this is
  an off-by-one. If intentional, document it at the `readTool` call site.
- **Swallowed stack traces hide the real failure.** `agent_runner.dart:346-351` and
  `task_scheduler_service.dart:1142-1148` reduce failures to `e.toString()`, so a disposed-PDF
  `StateError` surfaces with no indication of which tool or turn produced it. Use `catch (e, st)` and
  prefix the `errorMessage` with the failing tool/turn.

---

## 4. Performance

### [ ] R2-P1 — MED-HIGH — `ClampedTableView` lays out the entire table on every streaming frame

**File:** `lib/widgets/bubbles/clamped_table_view.dart:234-316`

`build()` constructs every `TableRow` and cell widget for **all** rows (no virtualisation) inside a
`Table` with `defaultColumnWidth: IntrinsicColumnWidth` — forcing Flutter's expensive double-pass
intrinsic layout over every cell. Each cell allocates a fresh `copyWith`, a `Container`, and (for
non-empty cells) a `Tooltip` with `text.substring(0, 300)`.

This is the `tableBuilder` for `GptMarkdown` (`message_bubble.dart:322`), so it re-runs on **every**
`_emitSnapshotNow` flush — immediately at each paragraph boundary, at least every 1200ms. A 50×8
generated table costs a full O(rows×cols) intrinsic layout several times per second while streaming.

**Fix:** (a) memoise row/cell construction keyed on `tableRows` identity; (b) replace `Table` +
`IntrinsicColumnWidth` with a horizontally-scrolling `Row` of fixed-width `Column`s, or wrap in a
`RepaintBoundary` and re-render only the trailing block.

### [ ] R2-P2 — MED-HIGH — Orphan/owned-file scans do synchronous recursive disk I/O on the UI isolate

**Files:** `manage_tasks_screen.dart:159-166` → `task_scheduler_service.dart:276-309, 177-256, 312-327`

The comment at `manage_tasks_screen.dart:132-134` claims "runs off the UI isolate", but only the first
half does. The remainder runs on the main isolate:
- `getOrphanedFiles()`: `db.select(db.schedulerTaskLogs).get()` — **every** log row, no `LIMIT`
  (`:280`) — then `scratch.listSync(recursive: true)` (`:298`).
- `getOwnedFilesForTask()`: `scratch.listSync(recursive: true)` (`:247`) plus up to 3
  `File.existsSync()` per path in `resolveReportPath` (`:99-114`).
- `sweepOrphanFiles()`: `file.lengthSync()` + `file.deleteSync()` per orphan (`:318-320`).

`getOwnedFilesForTask` runs from `SpaceyTaskRow._deleteTask` (`spacey_task_row.dart:375`) and from
`deleteLogsForTask` — i.e. **on a user tap**.

**Fix:** move the whole body into `Isolate.run(() …)` (as `_loadStorageSummary` already does for its
first half), pass plain path data across, and add `..limit(N)` to the log query.

### [ ] R2-P3 — MED-HIGH — `saveConversation` rewrites the entire message window on every persist

**File:** `lib/services/database.dart:351-368`

```dart
await batch((b) {
  for (final message in conversation.messages) {
    final existingRow = rowByMessageId[message.id];
    if (existingRow == null) { b.insert(…); } else { b.update(conversationMessages, …); }
  }
});
```

Full upsert, not a diff. During streaming `_schedulePersist` fires every 600ms
(`chat_screen.dart:1350`) and every 150ms on tool batches (`:2330`), so an N-message window with M
multi-KB tool results causes N `UPDATE`s rewriting M×KB of text, N times, inside a transaction. The
`selectOnly` at `:331-338` also re-reads all `(localId, messageId, sortOrder)` triples each time.

**Fix:** diff against a cached "last persisted message id → content hash" map held in the writer, and
only insert/update rows whose content actually changed. Cache the `rowByMessageId` map alongside it.

### [ ] R2-P4 — MED-HIGH — A new `DocumentLruCache` (and `ShellService`) per agent turn

**Files:** `tool_registry.dart:59-96` · `chat_screen.dart:2028-2049, 2084` · `file_tools.dart:178-189`

`ToolRegistry.defaults` builds `readTool(directory, …)` **without** a `documentCache`, so `readTool`
allocates a fresh `DocumentLruCache` with `ownsCache = true`; `registry.dispose()` at end of turn
(`:2084`) calls `cache.dispose()`. Consequences:
- A PDF/Office file read on page 3 of turn *N* is fully re-opened (native `PDDocument` re-created) on
  turn *N+1*.
- In-flight dedup and the 64MB/16-entry bounds are **per-turn, not per-session**.
- The `documentCache` injection parameter and its ownership logic are dead code.
- A new `ShellService` (with its own `_activeProcesses`) per turn; `dispose()` kills any
  still-registered process.

**Fix:** own a single `DocumentLruCache` and `ShellService` in `ChatScreen` and pass them via
`ToolRegistry.defaults(documentCache: …, shellService: …)`; only build the tool *wrappers* per turn.

### [ ] R2-P5 — MEDIUM — `hasContent` copies the whole buffer, per row, per frame

**Files:** `streaming_assistant_service.dart:107` · `chat_screen.dart:2950`

```dart
bool get hasContent => _fullPristineBuffer.toString().trim().isNotEmpty;
```

`StringBuffer.toString()` allocates a full copy of the accumulated turn. It is called 3× per
`_emitSnapshotNow` (`:370`, `:381`, `:385`), from `startReasoning`/`setCompacting`/`setRetry`, and —
worst — **once per tool-group row, per frame** from `chat_screen.dart:2950`
(`!_streamingService.hasContent` inside `itemBuilder`). For a 200KB answer with 20 tool groups that is
20 × 200KB of garbage per rebuild, several times per second.

**Fix:** track an incremental `bool _hasNonWhitespace` in `appendDelta`; expose
`int get length => _fullPristineBuffer.length`; build `fullPristineText` once per snapshot into a local.

### [ ] R2-P6 — MEDIUM — `_buildMessageList` does O(N) allocation + scans on every `setState`

**File:** `chat_screen.dart:2878-2914`

`build()` runs on every streaming flush and every tool call. Each run: `groupMessagesForDisplay`
allocates a fresh list over all N messages; the `latestActiveToolGroupIndex` backward scan is O(N);
`regenerateTargets` is an O(N) forward scan allocating a new `Map<int,String>`; every row allocates a
`SubtleFadeIn` (a `StatefulWidget` with its own `AnimationController` + `CurvedAnimation` + Ticker) and
a `postFrameCallback` closure (`:2936-2945`).

**Fix:** memoise `displayItems`/`regenerateTargets` against `_messages.length` + last message id; hoist
the streaming bubble into its own `StatefulWidget` keyed by `_workingMessageId` so only it rebuilds
per delta; only allocate the `postFrameCallback` for genuinely new ids.

### [ ] R2-P7 — MEDIUM — Unbounded `_olderConversations` through a non-builder `ListView`

**Files:** `chat_screen.dart:1427-1447` · `widgets/chat_sidebar.dart:108-163`

`_olderConversations.addAll(fresh)` is never trimmed for the session (only pruned on delete/rename).
`ChatSidebar` renders with `ListView(children: […])` — **not** `.builder` — so every loaded row is built
and laid out eagerly through a ~10-level-deep widget tree. `optionsBuilder(chat)` runs per row per
rebuild (allocating 3 `ChatOption`s + 3 closures each), and `ChatScreen.build()` creates a new
`optionsBuilder` closure every time — so the whole sidebar rebuilds on every streaming delta even when
hidden behind `AnimatedOpacity`.

**Fix:** cap `_olderConversations` (~200, drop oldest), switch to `ListView.builder`, and hoist
`optionsBuilder` to a tear-off field so the `ChatSidebar` element can short-circuit.

### [ ] R2-P8 — MEDIUM — 2-second `markTablesUpdated` poll re-runs three full window queries

**File:** `manage_tasks_screen.dart:292-307`

While any task is `running`, a 2s timer calls `_db.markTablesUpdated([schedulerTasks, schedulerTaskLogs])`,
invalidating all three watches: the 400-row task query, the 400-row log query, and the `COUNT(*)`
custom select. Each is re-materialised and re-sorted on the main isolate every 2s for the run's
duration. Same class of problem the CHANGELOG's 400-row `LIMIT` fix addressed, triggered by a poll
instead of by writes.

**Fix:** narrow to a `selectOnly` status poll, or drive running-state UI from `TaskProgressService`
(already wired in `agent_runner.dart:208-260`) instead of invalidating tables.

### [ ] R2-P9 — MEDIUM — `watchPinnedConversations()` has no `LIMIT` (the one remaining unbounded watch)

**File:** `lib/services/database.dart:736-745`

```dart
Stream<List<Conversation>> watchPinnedConversations() {
  final query = select(conversations)..where((c) => c.isPinned.equals(true))..orderBy(_summaryOrdering());
  return query.watch().map(...);
}
```

Every sibling read is bounded — `watchConversationSummaries(limit: 20)`, `loadConversation(messageLimit: 50)`,
the 400-row task/log watches — but this one re-materialises **every** pinned conversation (plus its
`Directory` construction at `:809`) on every write to `conversations`, which happens on every debounced
persist (~600ms during streaming) and on every pin toggle. Rendered as a full non-builder loop in
`chat_sidebar.dart:126-138`.

**Fix:** add a `limit` parameter mirroring `watchConversationSummaries`, cap at ~50.

### [ ] R2-P10 — LOW-MED — Smaller perf items

- **`ToolRegistry.all` re-serialises every tool schema per turn.** `tool_registry.dart:163`,
  `agent_loop.dart:175-188`. `all` allocates a new list and `_buildBody` re-encodes `tools.map((t) =>
  t.toJson())` on **every** `chat()`/`chatStream()` call — up to `maxTurnCount = 72` times per run.
  Cache `all` as `late final` and memoise the encoded JSON.
- **`cleanExpired()` fired once per spill.** `tool_output_file_service.dart:139` — a turn with 10 large
  tools launches 10 concurrent full directory sweeps. Debounce to at most once per 30s.
- **Synchronous `existsSync()`/`lengthSync()` inside dialog `itemBuilder`s.** `spacey_task_row.dart:465-471`
  and `task_logs_modal.dart:286` each `stat` twice per file, on the UI isolate, re-running on every
  checkbox toggle. Compute sizes once alongside `totalBytes` and pass a pre-built
  `List<({File f, int bytes})>` into the dialog.
- **`ShellService.executable` stats the filesystem per command.** `shell_service.dart:1742-1748` — a
  synchronous `stat` on the UI isolate per `execute()`. The answer can never change; resolve once in a
  `late final` field.
- **Widget state mutated inside `build()`.** `browser_widget.dart:98-100` (`_hasEverOpened = true`) and
  `manage_tasks_screen.dart:327` (`_syncRunningTasksPolling` creates/cancels a `Timer.periodic` in
  build). Neither throws today, but a discarded build leaves state mutated for a frame that never
  rendered, and a 2s timer can start from an uncommitted build.

---

## 5. Code duplication

Ranked by payoff. The first two are clear, mechanical wins.

### [ ] R2-D1 — Delete-with-files dialog duplicated verbatim (~140 lines)

**Locations:** `spacey_task_row.dart:374-554` (`_deleteTask`) · `task_logs_modal.dart:186-359`
(`_ClearLogsButton._handleClear`)

Identical: `getOwnedFilesForTask` → per-file `lengthSync()` sum → `showDialog<bool>` → `StatefulBuilder`
→ `AlertDialog` with the same chrome (`0xFF1E222B` / `0x161B22` / `0x30363D`), same `Checkbox(activeColor:
kBubbleUser)` + "Also delete N file(s) (bytes)" row, same expandable file list (`0xFF21262D` dividers),
same `Cancel`/`Delete` action row (`0xFF8B949E` / `kDanger`).

**Fix:** extract `lib/widgets/tasks/confirm_delete_with_files_sheet.dart` exposing
`showDeleteWithFilesSheet(BuildContext, {title, message, fileLabel, files, confirmLabel})`. Also hoists
`formatBytes` (see `R2-D3`).

### [ ] R2-D2 — Provider key/model resolution repeated 7× (~180 lines)

**Provider key resolution** — `chat_screen.dart:460-462, 493-501, 1055-1057, 1071-1083, 1968-1970` ·
`model_picker_dialog.dart:152-158, 189-191, 211-213, 255-265, 327-338` ·
`edit_task_model_sheet.dart:192-206` · `providers_tab.dart:136-138, 146-161` ·
`provider_form_dialog.dart:112-118` · `task_scheduler_service.dart:1065-1067`

> This is the clearest "already solved, not adopted" case in the codebase: the canonical
> implementation **already exists** at `app_settings.dart:113-117` (`_providerHasKey`) — it is private
> and never reused.

**Fix:** make `AppSettingsService.providerHasKey(LlmProvider)` and
`AppSettingsService.resolveApiKey(LlmProvider)` public, add `isOpenRouterProvider(LlmProvider)`, delete
the 7 copies.

**Model resolution** — `chat_screen.dart:474-576` vs `model_picker_dialog.dart:98-353`

Both implement the same "first-in-sorted-list, else preset, free-router special-case, free-router-with-key
is stale" priority. The `openrouter/free` / `openrouter/auto` / `kDefaultModelId` triple test is repeated 7×
across the two files.

**Fix:** extract `lib/services/model_resolution.dart` with `isFreeRouterId`, `pickInitialModel`,
`resolveModelForProvider`, `isStaleModel`. Both callers collapse to one-liners.

### [ ] R2-D3 — `formatBytes` triplicated byte-for-byte

`manage_tasks_screen.dart:189-193` · `spacey_task_row.dart:582-586` · `task_logs_modal.dart:180-184` —
verified byte-identical. A 4th variant `_formatSize` lives at `file_tools.dart:429-446`.

**Fix:** `lib/utils/format.dart` → `formatBytes(int)` and `formatBytesColumn(int, FileSystemEntityType)`.
Also delete `chat_screen.dart:3002`'s `_formatTokens`, a pure pass-through over
`widgets/context_footer.dart:6`'s `formatTokenCount`.

### [ ] R2-D4 — `list` and `find` tool handlers are near-clones (~100 lines)

`file_tools.dart:565-738` vs `:1063-1221`. Duplicated: the 10-line arg-decode block, 4 validation stanzas
with **byte-identical error strings**, `sortOrder` defaulting, workspace resolution + escape check,
`GrepFilter.compile` loop, the pagination window, and both result headers.

**Fix:** `lib/tools/paged_listing.dart` with `PagedListingRequest.fromArgs(Map)` and
`PagedListingResponse.render(…)`; each handler shrinks to ~40 lines.

### [ ] R2-D5 — A11y gate + screen-outline splitter duplicated

`screen_tool.dart:126-147` and `act_tool.dart:159-180` — identical gate blocks except one string; the
multi-line guidance strings are **character-identical**. `screen_tool.dart:255-262` and
`act_tool.dart:282-288` are the same 7-line splitter under two names.

**Fix:** `A11yService.requireEnabled()` returning `String?`; move the splitter to a shared module.

### [ ] R2-D6 — `act_tool` repeats the same two message blocks 4×/5×

`act_tool.dart:225-232, 379-386, 433-440, 492-499` (identical confirmation-modal message);
`:346-352, 406-411, 457-463, 467-474, 546-553` (`looksLikeCommitAction` guard + refusal);
`:355-364, 477-484, 560-568` (`COMMIT_REFUSAL` extraction).

**Fix:** one `commitRefusal(res, knownLabel)` helper + a single `_postActionProbe(svc, message)`.

### [ ] R2-D7 — Task status transitions hand-rolled in 4 places

`spacey_task_row.dart:352-372` (`_togglePause`) · `edit_task_model_sheet.dart:291-325` ·
`schedule_task_tool.dart:358-461` (`update` action) — all three bypass
`task_scheduler_service.dart:~780-830` (`computeEditTransition`), the intended single source.
`spacey_task_row` and `schedule_task_tool` both hand-roll the
`(paused|cancelled) → null nextRunAt; else → calculateNextRunAt(...)` logic. This is the direct cause of
`R2-H11`.

**Fix:** delete the two hand-rolled versions; add `TaskSchedulerService.setPaused(taskId, bool)` and
route everything through `computeEditTransition`.

### [ ] R2-D8 — MED — Other duplication

| What | Where |
|---|---|
| `model_catalog.testConnection` / `_fetch` share ~55 lines of HTTP plumbing | `model_catalog.dart:129-281` vs `:283-347` |
| `headless_browser_service` writes the same 26-line callback set twice | `headless_browser_service.dart:79-104` vs `:106-131` |
| `InAppWebViewSettings` 14-flag block ×3, support probe ×2 | `browser_widget.dart:588-607, 829-844` · `headless_browser_service.dart:58-75` |
| GitHub request block ×3 + self-duplicated `checkFirstLaunchAfterUpdate` | `update_service.dart:228-248, 449-457, 592` |
| webfetch URL validation + truncate + `kMaxWebFetchStoredChars` (declared twice) | `web_tools.dart:14, 162-205` vs `fallback_web_fetch_tool.dart:13, 59-171` |
| Workspace path resolution + `file://` stripping | `file_tools.dart:823-829, 839-846, 937-965` · `bash_tool.dart:88-90, 201-203` |
| Unread-log predicate 3× in Dart + 1× in raw SQL | `manage_tasks_screen.dart:96, 369-382, 1021-1027` |
| "Paginated ListView + Load more" ×3 (26 lines each) | `manage_tasks_screen.dart:958-989, 1105-1135, 1282-1312` |
| `processOutput` + `ToolCallResult(ok:true)` wrapper ×11 | `file_tools.dart` ×6 · `web_tools.dart` ×2 · `fallback_web_fetch_tool.dart` · `act_tool.dart` · `screen_tool.dart` |
| `settle_ms` / `max_nodes` int-clamp parsing ×5, with **3 different defaults** (350/1000/350) | `screen_tool.dart:169-171, 287-289` · `act_tool.dart:218-220` · `browser_tool.dart:427-432` |
| Floating top-of-screen card shell ×3; warning banner ×2 (~56 lines) | `a11y_toast_overlay.dart:37-58` · `unread_task_banner.dart:30-45` · `update_toast.dart:39-62` · `manage_tasks_screen.dart:590-687` |
| `llm_client` retry `catch` blocks ×9, byte-identical bodies | `llm_client.dart:251-283, 466-513` |
| 58 lines of byte-identical stdout/stderr truncation | `shell_service.dart:1834-1892` |
| Attachment-row UI in 3 places | `pending_attachments_banner.dart:50-73` · `settings/files_tab.dart:71-103` · `bubbles/message_bubble.dart:167-194` |
| Placeholder-prefix check written twice in one file | `message_bubble.dart:89-94, 305-309` |

**Shared literals to fix while you're in there:** `'handy_flutter/1.0'` User-Agent in 5 places;
`kMaxStoredChars` (`tool_output_file_service.dart:31`) vs `kMaxReadBytes` (`file_tools.dart:15`) — same
number, unrelated names; `'TTL is 10m'` (`file_tools.dart:271`) duplicating `ToolOutputFileService.ttl`
(line 42); `'Destructive Command'` sentinel compared as a magic string in
`command_confirmation_banner.dart:25, 36`; the `'init'` message id threaded through
`chat_screen.dart:1258` and `agent_loop.dart:522, 539`.

**Note — `llm_client.dart` is the counter-example:** `_backoff`, `_rethrowIfCancelled`,
`_parseHttpDateRetryAfter` and `cleanErrorMessage` are all single definitions. The problem is that
`tavily_client.dart`, `update_service.dart`, `models_dev_service.dart` and `browser_service.dart`
don't reuse `cleanErrorMessage` (only `model_catalog.dart:6` imports it), so Tavily
(`tavily_client.dart:87-96`) and models.dev (`models_dev_service.dart:127-131`) hand-roll a weaker
version of the same status-code→message logic.

---

## 6. Readability

### [ ] R2-R1 — HIGH — 657-line shell-safety method

**File:** `lib/services/shell_service.dart:617-1273` (`_analyzeDirectCommand`)

A single static method containing ~60 sequential `if (...) return ShellSafetyCheck(...)` guards covering
filesystem, archive tools, package managers, network tools, redirect sinks, and device control. It is
the **only** thing standing between an LLM and `rm -rf /`, and it cannot be reviewed, unit-tested per-rule,
or audited by section. A rule added at the top silently shadows every rule below it — order is load-bearing
(see the comment at `:610-616`) but nothing enforces it.

> Note: Round 1 `C1`/`H9`/`H10` (`P13.6.1`) fixed the *bypass vectors* here. The remaining problem is
> structural, not a bypass.

**Fix:** split into a `const` list of `(pattern, level, reason) -> ShellSafetyCheck` rule records, or one
private method per family (`_checkFilesystemTargets`, `_checkArchiveTools`, `_checkNetworkTools`,
`_checkRedirection`, …) each returning `ShellSafetyCheck?`, composed with `_worst(…)` in a 30-line
driver. Add a test that enumerates every rule.

### [ ] R2-R2 — HIGH — 438-line `executeTask` with no transaction boundary

**File:** `lib/services/task_scheduler_service.dart:943-1381`

One method does: allowlist guard → atomic DB claim → log insert (+ failure recovery) → payload decode →
LLM client construction → headless run with timeout → post-run DB re-read → outcome classification →
recurring reschedule → notification dispatch. Six `catch (_) {}` blocks silently swallow failures at
`:1010, 1039-1041, 1085, 1195-1199, 1243-1245`.

Every DB write is a "must not double-fire under AlarmManager+WorkManager concurrency" concern spread
across 438 lines with no transaction boundary — one missed branch corrupts scheduler state permanently.

**Fix:** extract `_claimTask`, `_openRunLog`, `_buildRunner`, `_runWithTimeout`, `_classifyOutcome`,
`_applySuccessTransition`, `_applyFailureTransition`, `_notifyOutcome`. Wrap claim+log-insert in a single
`db.transaction`. Replace bare `catch (_) {}` with a `_logSwallowed(step, e)` helper that `debugPrint`s.

### [ ] R2-R3 — HIGH — 2 993-line `_ChatScreenState` with 50 `setState` calls

**File:** `lib/screens/chat_screen.dart:75-3068`

Ten unrelated responsibilities in one class: model/provider selection & catalog healing, conversation
CRUD + pagination, persistence/coalescing, attachment staging, the agent turn, voice/STT, release notes,
OTA updates, a11y toasts, storage permission, and the entire UI tree.

**Impact is performance, not just taste:** every `setState` invalidates the whole tree including the
message `ListView`, and `build()` rebuilds composer, header, sidebar and all bubbles on each SSE delta
(see `R2-P6`).

**Fix:** extract at minimum `ModelSelectionController`, `ConversationListController`,
`AttachmentController`, `VoiceController`, `A11yToastController` (as `ChangeNotifier`/`ValueNotifier`).
Convert `_messages` to a `Listenable` so the `ListView` subscribes independently; keep the screen as
composition only.

### [ ] R2-R4 — HIGH — 925-line `configureFlutterEngine` holds all 8 channel contracts

**File:** `MainActivity.kt:267-1191`

`Task Scheduler (P9)` (`:275`), `Storage` (`:406`), `Intent` (`:434`), `Accessibility` (`:857`),
`App Info & OTA` (`:1063`), `Location` (`:1127`), `Widget` (`:1174`), `PdfReader` (`:1187`) — each a
`when (call.method)` with 40+ string cases and 14 `catch (_: Exception) {}`. Cannot be split across
files, reviewed in a PR, or unit-tested. `TaskExecutionService.kt:416-681` re-implements two of these
channels — invisible from either file, and the direct cause of `R2-H3`.

**Fix:** one Kotlin file per channel exposing `fun register(messenger, host)`. Extract the shared
`putExtraValue` / `reverseGeocode` helpers already duplicated between `MainActivity.kt:140, 724` and
`TaskExecutionService.kt:700, 724`.

### [ ] R2-R5 — HIGH — `manage_tasks_screen` `build()`: 213 lines, 3 nested StreamBuilders, broken indentation

**File:** `lib/screens/manage_tasks_screen.dart:322-535`

Nesting reaches 12+ levels: `StreamBuilder<SchedulerTaskRow>` → `builder` → `StreamBuilder<SchedulerTaskLogRow>`
→ `builder` → `StreamBuilder<int>` → `builder` → `Scaffold` → … The indentation at `:384-528` is
*wrong* (the `Scaffold` is indented to column 15 while its `return` is at column 13), so a reader cannot
trust the visual structure. Three independent streams also mean each re-emits the whole subtree.

**Fix:** merge into one `StreamBuilder` over a combined stream or a `StateNotifier<TaskListState>`.
Extract `_buildAppBar` / `_buildPopupMenu` so `build()` reads as ~6 lines. Re-run `dart format`.

### [ ] R2-R6 — MED — Correctness lies in comments and dead code

These are cheap to fix and high value for reader trust:

| Claim | Reality |
|---|---|
| `model_catalog.dart:455-461` — "rotating the API key never serves the previous key's catalog" | **False on every production path.** See §7. |
| `chat_screen.dart:1392` — `if (_sessionTrustedConversations.remove('__active_draft__'))` | `'__active_draft__'` is never added anywhere; the branch is unreachable. It *looks* like a security control. |
| `agent/tool.dart:16-34` — `requiresValidation`, documented in `architecture.md:87` as a live gate | Never set `true` by any production tool, never read by any production code (only `test/tool_registry_test.dart:42-49`). A field documented as a security control but never read is worse than no field. |
| `chat_screen.dart:2120` — `_startWorkingElapsedTimer()` | Empty body (gutted), still invoked every agent turn at `:1999`. |
| `chat_screen.dart:1155` — "Sending them as multimodal content parts **is the next step**" | `read` now returns `contentParts` (`file_tools.dart:744-749`). Comment is wrong. |
| `chat_screen.dart:2522-2525` — `final cleanWords = words;` | Name documents a sanitisation the comment says was removed. |
| `intent_tool.dart:251-253` — error text lists 5 valid actions | The `switch` (`:166-255`) also supports `docs`, `search`, `dial`, `open_maps`, `email`. |
| `agent/tool_registry.dart:190-203` — tool-name aliases | `extractTextTool` (`browser_tool.dart:435`) is **never registered** in `defaults` or `headless`, so `_tools['extract_text']` is always null; `actTool` registers `'screen_act'`, so `_tools['act']` is always null. Both fallbacks are dead and the assumption is propagated into `agent_loop.dart:335` and `chat_screen.dart:2200`. |
| `architecture.md:88, 91` | Tool list is missing `location`, `memory`, `browser`, `schedule_task`; the tool is `screen_act` not `act`; `_toLlmHistory` emits `'[User uploaded attached file(s)]'`, not the documented format. |
| `file_tools.dart:7`, `chat_sidebar.dart:152` | Commented-out code. |

**Fix:** replace the 5 alias blocks with a `const Map<String, List<String>> kToolNameAliases` and a
single lookup; delete the `extract_text` and `act` entries. Introduce a `const kToolNames` object so the
literals stop being duplicated across `agent_loop.dart:335-341`, `tool_registry.dart:179-202`, and
`chat_screen.dart:2199-2203`.

### [ ] R2-R7 — MED — `readTool` has no error taxonomy

**File:** `lib/tools/file_tools.dart:227-387` (161 lines)

Handles arg validation, media-vs-structured-vs-text dispatch, grep filtering for two different unit
systems (logical units vs byte ranges with `_countLinesBefore`), offset paging, and output spilling — with
a single `catch (e)` at `:381` turning *every* failure into `'Failed to read "…": $e'`. A malformed
document, a permission error, and an out-of-range offset all surface to the model as the same string, so
the agent cannot self-correct.

**Fix:** split into `_readMedia` / `_readStructured` / `_readTextRange` returning a `sealed class
ReadOutcome` with a `switch` in the handler. Give each failure a distinct `type:` — `bash_tool.dart`
already does this (`'timeout'`, `'user_denied'`, …); `read` just doesn't.

### [ ] R2-R8 — MED — `llm_client` stream reader: 7 ad-hoc upstream error shapes

**File:** `lib/llm/llm_client.dart:521-755` (235 lines)

Handles `data['error']` as String (`:621`) and Map (`:624`), `data['detail']` (`:631`),
`data['message']` (`:636`), `choice['error']` as Map (`:645`) and String (`:651`),
`finish_reason == 'error'` (`:656`) and `'content_filter'` (`:662`), plus a non-SSE JSON fallback branch
(`:536-586`). A `content_filter` stop and a hard generation failure are treated completely differently
(`transport: true` vs `false`) — a subtle retry-policy decision buried in a stream loop.

**Fix:** extract `LlmException? _extractStreamError(Map)` and `_extractChoiceError(Map)`; move the
non-SSE fallback into its own `_readJsonResponse`.

### [ ] R2-R9 — MED — Shell safety analysis runs twice per command

**Files:** `bash_tool.dart:124-170` · `shell_service.dart:1764`

`bashTool` calls `ShellSafetyCheck.analyze(...)` at `:124`, then `ShellService.execute` calls the *same*
analysis again at `:1764`. The result is also passed back in as `confirmDestructive: bool`; the second
analysis exists only to throw into `ToolRegistry`'s generic handler, surfacing as `type: 'handler_error'`.

**Impact:** doubles the cost of the most expensive regex work in the app, and the two analyses can
diverge if either call site is later given different `scratchPath`/`workingDirectory`.

**Fix:** have `ShellService.execute` accept the already-computed `ShellSafetyCheck`, or expose a
lower-level `ShellService.run(...)` that does no analysis.

### [ ] R2-R10 — LOW — Other readability items

- **Inconsistent sibling exception field names.** `ShellSecurityException.message` vs
  `ShellDraftConfirmationException.reason` for the identical concept (`shell_service.dart:1655-1672`) —
  every `catch` site must know which name to read. Standardise, or fold both into one
  `ShellRefusalException(level, reason, {pattern})` so callers branch on the enum.
- **Positional-index casting of a `Future.wait` result.** `settings_sheet.dart:122-137` — the compiler
  cannot catch a reordering and every use needs a cast. Use Dart 3 records: `(a, b, c).wait`.
- **Obfuscated dead branching in `build()`.** `manage_tasks_screen.dart:360-365` reduces to
  `t.status == 'running' || t.status == 'scheduled'` but is written as a 3-branch predicate.
- **`browser_service.open()` / `reload()` are ~80% duplicates** with unnamed delays
  (`shell_service`-style magic values `300ms`/`:506`, `500ms`/`:509`, `350ms`/`:521`, plus a hard-coded
  `Duration(seconds: 8)` at `:451` that ignores the `timeout` parameter). Extract a shared `_navigate(…)`
  and name the constants.
- **~103 `catch (_) {}` in `lib/`** (verified count) with no shared marker, so a genuinely diagnostic
  site is indistinguishable from a deliberately ignored one. A `debugPrint`-based `ignoreError(step, e)`
  helper makes the ~30 real ones visible.
- **Task status/type are magic strings at ~120 sites** across `task_scheduler_service.dart`,
  `schedule_task_tool.dart`, `spacey_task_row.dart`, `manage_tasks_screen.dart` (documented at
  `database.dart:135-136, 162`). A single typo in `'succes'` silently becomes a stuck task. Introduce
  `enum TaskStatus` / `enum TaskType` with `wire`/`fromWire`.

---

## 7. Claimed fixed, still open on some paths

**Read this before trusting `P13.6.*` in `next_plan.md`.** Two items are marked ✅ DONE but the fix
landed on only one of the two code paths. Both were re-verified at `93c8c51`.

### [ ] R2-X1 — `P13.6.15` (geocoding) — fixed in the foreground engine only

`P13.6.15` claims *"Shared `ExecutorService` + timed `Future.get` (8s limit) with cancellation on
timeout for geocoding"*. `MainActivity.kt:46` does declare
`private val geocodeExecutor = Executors.newCachedThreadPool()` and `:1218` correctly offloads via
`geocodeExecutor.execute { … }`.

But `TaskExecutionService.kt:553` still does:
```kotlin
val geocodeExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
// … geocodeFuture.get(8, TimeUnit.SECONDS)   // line 559, ON THE PLATFORM THREAD
geocodeExecutor.shutdownNow()                // line 581
```
The background engine allocates an executor per call *and* blocks the platform thread. This is
`R2-H4`. Reopen `P13.6.15` or close it by fixing `TaskExecutionService`.

### [ ] R2-X2 — `P13.6.10` (M15, model catalog cache key) — bypassed by all 9 call sites

`P13.6.10` claims *"cache key buckets by key-material hash, so key rotation never serves the stale
catalog"*. The hash is there — `model_catalog.dart:455-461` returns
`'$normalized|${key.isEmpty ? 'anon' : key.hashCode}'`.

But `:414-416` writes **two** entries:
```dart
final scoped = _cacheKey(baseUrl, apiKey);
_cache[scoped] = result;
_cache[_normalizeBaseUrl(baseUrl)] = result;   // unscoped alias
```
and every production reader calls `getCachedModels(baseUrl)` **without an `apiKey`**, falling through
`getCachedModels` (`:106-111`) to the `|auth` → `|anon` → bare-`normalized` chain. The bare-normalized
alias is the one that hits. `'$normalized|auth'` is never written by anything (dead branch).

So after a key rotation the picker still serves the previous key's catalog — exactly the failure the
comment claims to prevent. All 9 call sites affected: `chat_screen.dart:639, 731, 822, 838, 1276` (and
more), `model_picker_dialog.dart:86, 204, 236, 325`, `edit_task_model_sheet.dart:173`.

**Fix (pick one):** (a) delete the unscoped alias at `:416` and make all readers take a required
`apiKey`; or (b) drop the hash and store `Map<String, Map<String, List<ModelOption>>>` (baseUrl → keyHash).
Remove the `|auth` lookup. Add a test that rotates the key and asserts a refetch.

### [ ] R2-X3 — `P13.6.11` (non-streaming parse hardening) — streaming path still unguarded

`P13.6.11` claims *"`as Map` casts replaced with `is` checks … on both paths"*, and the **non-streaming**
path is indeed fixed. The **streaming** path still has four unchecked casts at
`llm_client.dart:641, 643, 709, 713` — see `R2-M10`. The acceptance test should cover both paths.

---

## 8. F-Droid readiness

**Verdict: not submittable yet.** Compliance is fundamentally sound — the blockers are
policy/metadata/tooling, not licensing.

### Already compliant ✅

MIT licence · all dependencies BSD/Apache/MIT (verified per-package) · no GMS/Firebase/proprietary SDKs ·
no hardcoded keys (`.env` untracked + gitignored) · `pubspec.lock` committed · no iOS/web/desktop dirs
(so the F-Droid `rm:` step is trivially satisfiable) · `*.jks` / `key.properties` gitignored ·
`GeneratedPluginRegistrant.java` untracked · Syncfusion already removed in favour of
`com.tom-roush:pdfbox-android` (Apache 2.0, Maven Central — allowed as a prebuilt FLOSS binary per
Inclusion Policy) · debug-signing fallback when `key.properties` is absent, which is what F-Droid wants.

### [ ] R2-F1 — BLOCKER — The in-app OTA updater conflicts with Inclusion Policy §5

**Policy text** (Inclusion Policy, *Security & Legal Compliance* §5): *"Applications must not download
additional executable binary files (e.g. add-ons, auto-updates, etc.) without explicit user consent.
Consent means it needs to be opt-in … and structured in a way that clearly explains to users that
they're choosing to bypass F-Droid's checks if they activate it."*

Current behaviour, all unconditional:
- `REQUEST_INSTALL_PACKAGES` in the main manifest (`AndroidManifest.xml:34`) — in **both** flavors.
- Auto-check on app start: `chat_screen.dart:370` → `UpdateService.instance.initialize()` →
  `unawaited(checkUpdate())` (`update_service.dart:88`).
- Auto-check again on every resume: `chat_screen.dart:944`.
- Re-checks throttled to every 2h (`update_service.dart:20, 437`).
- Downloads and installs APKs with SHA-256 + size verification.

The `Tracking` anti-feature also explicitly lists *"Checking for updates without your knowledge or
permission"* as a trigger. F-Droid 2.0 shipped 2026-09-24; self-updaters are being rejected on exactly
this ground.

**Fix — this is a product decision, not just a code change.** Recommended: gate the whole
`UpdateService` behind a build-time flag **or** a user setting that is **off by default**, and submit
with it disabled. A user-initiated "check for updates" button that explains it bypasses F-Droid is the
compliant alternative. Whichever route, the check must not run automatically.

### [ ] R2-F2 — BLOCKER — No `fastlane/metadata/`

Required for submission. Required files:

```
fastlane/metadata/android/en-US/short_description.txt   # <80 chars, no trailing dot
fastlane/metadata/android/en-US/full_description.txt
fastlane/metadata/android/en-US/changelogs/5.txt         # for versionCode 5, max 500 chars
fastlane/metadata/android/en-US/images/icon.png
fastlane/metadata/android/en-US/images/phoneScreenshots/*.png
```

### [ ] R2-F3 — BLOCKER — 33 commits ahead of the release tag; no `v0.7.5`

`git describe` → `v0.7.4`, but `HEAD` is 33 commits ahead and `pubspec.yaml:19` still reads
`version: 0.7.4+5`. F-Droid's `AutoUpdateMode: Version` + `UpdateCheckMode: Tags` needs a tag matching
the version. `pubspec.yaml` is already in the regex-extractable form F-Droid expects
(`UpdateCheckData: pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+`), so no Gradle change is needed.

Also note: the existing tag set is inconsistent — both `0.6.0`-style and `v0.6.0`-style tags exist.
F-Droid expects `v*`.

### [ ] R2-F4 — BLOCKER — No Flutter version pin; the metadata template depends on it

`.github/workflows/ci.yml:26` uses `channel: 'stable'` with no version. F-Droid's Flutter template
derives the SDK with:
```yaml
- flutterVersion=$(sed -n -E "s/.*flutter-version:\ '(.*)'/\1/p" .github/workflows/release.yml)
```
There is **no `release.yml`** in `.github/workflows/` — only `ci.yml`. The metadata cannot determine which
Flutter SDK to check out.

**Fix:** add `flutter-version: '3.47.1'` to a `release.yml` (the template reads that file specifically),
or to `ci.yml` and point `prebuild` at it.

### [ ] R2-F5 — BLOCKER — `settings.gradle.kts` mutates the pub cache at configure time

**File:** `android/settings.gradle.kts:29-45`

```kotlin
val pluginsDependenciesFile = file("../.flutter-plugins-dependencies")
// … for each plugin path, read android/build.gradle and WRITE the modified script back
buildGradle.writeText(script.replace("proguard-android.txt", "proguard-android-optimize.txt"))
```

This rewrites third-party plugin files inside the pub cache. On F-Droid the cache is read-only and
**scanned** before the build, so this either fails outright or silently produces a binary that differs
from what the scanner approved — a build-reproducibility problem, which is exactly what F-Droid's
infrastructure exists to prevent.

**Fix:** delete the write-back block and replace it with a proper `subprojects { }` hook in
`android/build.gradle.kts` (currently no such logic exists there), e.g. configuring
`proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), …)` for affected subprojects.
Nothing in the pub cache should ever be written by the build.

### [ ] R2-F6 — 58 MB of committed binaries

Tracked in git:
- `demo/errand_demo.gif` — **45 MB**
- `demo/errand_demo.mp4` — **13 MB**
- `assets/logo.png` — **4.4 MB**, and referenced **nowhere** and **not declared** in `pubspec.yaml`
  (the whole `assets:` block is commented out at `pubspec.yaml:80`)

Every F-Droid build clones the repo, and the scanner will flag these as non-source binaries. Untracked
but present on disk (keep them that way, or move off-machine): `first_sample.mp4` (29 MB),
`second_sample.mp4` (58 MB), `third_sample.mp4` (56 MB), `errand_demo_compressed.mp4` (5 MB).

**Fix:** delete `assets/logo.png` if unused; move the demo media to GitHub Releases or a docs branch and
reference it from the README, or add it to `scandelete` in the metadata. `.git` is already 94 MB.

### [ ] R2-F7 — Metadata details

- **Product flavors** are fine, but the metadata needs `gradle: [full]` to select one, and
  `versionCode` ordering rules if you split per ABI.
- **Permissions** need written justification: `MANAGE_EXTERNAL_STORAGE` and `QUERY_ALL_PACKAGES` (see
  `R2-S2`). Also `SCHEDULE_EXACT_ALARM` — and note `R2-H6` means background tasks **silently no-op**
  without `canScheduleExactAlarms()`, so a reviewer exercising the core feature will hit a dead end.
- **Suggested AntiFeatures to self-declare** if the features are kept:
  `NonFreeNet` (depends on OpenAI-compatible LLM providers) and possibly `Tracking` (update check).
- **`WebSite` / `SourceCode` / `IssueTracker` / `AuthorEmail`** must point at the public repo, and the
  author must be notified and not object (Inclusion Policy *Quality Control*, step 3).
- The repo has `LICENSE` (MIT) but no in-file licence headers — reviewers only require the repo-level
  file, so this is fine.
- `CHANGELOG.md` exists and is detailed; the `changelogs/<versionCode>.txt` files still need generating.

---

## 9. Mapping to `things_i_found.txt`

Not fully diagnosed here — pointers only, so the next agent doesn't re-triage from scratch.

| Your note | Related finding |
|---|---|
| 1. "composer still disabled after the agent finishes" | Look at `_busy` handling around `R2-H8` (re-entrancy latch) and the `finally` in `_runAgentTurn`. The `…working` placeholder is driven by `_workingMessageId` + `_updateWorkingPlaceholder` (`chat_screen.dart:2126`), which also backs `R2-P5`. |
| 2. "no spacing between settings tabs/sections" | Pure UI polish, `lib/widgets/settings/`. Not covered here. |
| 3. "autofocus works, keyboard doesn't" | `chat_screen.dart:381-388` calls `_composerFocusNode.requestFocus()` + `TextInput.show` after 150ms on cold start only. `MainActivity` soft-input handling and `windowSoftInputMode="adjustResize"` are the likely interaction. Not diagnosed. |
| 4. "reminders set a scheduled task instead of an alarm" | Routing in `system_prompt.dart` / `intent_tool.dart` vs `schedule_task_tool.dart`. The `SET_ALARM` intent is already in the manifest `<queries>` block (`AndroidManifest.xml`), so the capability exists. `R2-R6` notes `intent_tool.dart:251-253` under-documents its supported actions. |
| 5. paragraph-by-paragraph rendering | Already done — `streaming_assistant_service.dart` (see `R2-P5`, `R2-P1` for its perf cost). |
| 6. prompt editor on task item | Already done — `lib/widgets/tasks/edit_task_model_sheet.dart` (uncommitted changes present in the working tree). |
| 7. "linked files aren't getting deleted" | `R2-D1` (the delete dialog) and `R2-P2` (`getOwnedFilesForTask` scan). Also `task_scheduler_service.dart:177-256` — check `resolveReportPath` before the read passes. |

---

## 10. Verified clean — do not re-review

Checked at `93c8c51`. Listed so these don't get re-audited.

- **`chat_screen.dispose()`** (`chat_screen.dart:909-935`) — cancels all 3 subscriptions, disposes focus
  node, streaming service, controller, scroll, model catalog, LLM client. Correct.
- **`manage_tasks_screen._loadStorageSummary`** (`:132-155`) — already correctly offloads the recursive
  scratch scan to an `Isolate.run` with a `mounted` guard. (Only the *second* half is still on the main
  isolate — see `R2-P2`.)
- **Task/log watches are bounded** — `_maxWatchedTasks` / `_maxWatchedLogs` 400-row limits with
  `ORDER BY … DESC`, plus a separate exact `COUNT(*)`. Correct; `R2-P9` is the one remaining exception.
- **Agent loop iteration cap** — `agent_loop.dart:73, 157`, `defaultMaxTurns = 72`, with
  `RepeatedToolFailureException` for consecutive identical tool errors.
- **`secret_store.dart` key init** — properly serialised with a `Completer` mutex; documented threat
  model; AES-256-GCM with key stored outside the DB.
- **Backup rules** — `backup_rules.xml` / `data_extraction_rules.xml` correctly exclude `errand.key`
  from both cloud backup and device transfer, for both legacy and API-31+ paths.
- **`network_security_config.xml`** — cleartext scoped to localhost/127.0.0.1/10.0.2.2 only, which
  correctly covers the Ollama hint at `provider_form_dialog.dart:180`. No `usesCleartextTraffic`.
- **`TaskAlarmManager` PendingIntent identity** — correctly disambiguated by `requestCode = taskId`, with
  `FLAG_IMMUTABLE` + `FLAG_UPDATE_CURRENT`/`FLAG_NO_CREATE`. Cancellation works because
  `filterEquals` ignores extras. No data-URI uniquing needed here. (Distinct from `R2-M4`, which is
  about *activity launch* intents.)
- **Accessibility node recycling** — `ErrandAccessibilityService.kt:685-691, 828-836, 963-985` tracks
  obtained nodes in `touched`/`candidates` and recycles exactly once per path; `root` is recycled in
  `finally`. Only residual leak is the exception path out of `visitNode` (`:670-671`), which is harmless
  on API 33+ where `recycle()` is a no-op.
- **`TaskExecutionService` request queue** (`:97-99, 142-199`) — only touched from the main looper, and
  the `completed` flags on the three `Result` implementations correctly prevent double-advancement when
  a watchdog and a late Dart reply race. Solid.
- **No custom native WebView / JS bridge** — the browser is `flutter_inappwebview` entirely from Dart,
  with `allowUniversalAccessFromFileURLs: false` (`task_file_preview_screen.dart:243`).
- **Sealed classes used correctly** — `agent_loop.dart:13+` (`AgentEvent` hierarchy) and
  `agent_runner` events. Modern Dart 3 usage.
- **Zero `TODO` / `FIXME` / `HACK`** in `lib/`; zero bare `print()` (all `debugPrint`).
- **`VoiceWidgetProvider`** — `exported="true"` with `APPWIDGET_UPDATE` is the standard required pattern
  and carries no caller-controlled data (`updateAppWidget` only reads `appWidgetId` from the system).
  Not a finding.
- **`llm_client` error mapping** (`cleanErrorMessage`, `_httpStatusMessage`, `_backoff`,
  `_rethrowIfCancelled`, `_parseHttpDateRetryAfter`) — all single definitions, no copies. The best
  example of the codebase done right.

---

## Appendix — suggested batching

Nothing here is a new requirement; it's just an ordering that keeps the tree shippable.

1. **Security first** — `R2-C1`, then `R2-S1`. One commit, add the containment tests.
2. **F-Droid decisions** — resolve `R2-F1` (product call), then `R2-F2`–`R2-F5` + `R2-F7`. Tag `v0.7.5`.
3. **Android platform** — `R2-H1`+`R2-H2` together (they're one bug), then `R2-H3`, `R2-H4`, `R2-H5`,
   `R2-H6`, `R2-H7`.
4. **Dart concurrency** — `R2-H8`, `R2-H9`, `R2-H10`+`R2-M13` (they interact), `R2-H11`.
5. **Unblock honesty** — §7 first (`R2-X1`, `R2-X2`, `R2-X3`), since two are regressions of "done" work
   and one may change `P13.6`'s recorded status.
6. **Duplication** — `R2-D1`, `R2-D2`, `R2-D3`, then `R2-D7` (which also fixes `R2-H11`).
7. **Structural** — `R2-R1` (safety), then `R2-R2`, `R2-R4`, `R2-R3`, `R2-R5`.
8. **Performance** — `R2-P4`+`R2-P3`+`R2-P2` in that order (each feeds the next), then `R2-P1`, `R2-P5`.

When you land anything from this file, tick the box, add the SHA, and update `next_plan.md` with a
`P13.7` subsection referencing the `R2-*` IDs — do not renumber this file.
