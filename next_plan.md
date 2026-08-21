# Next Plan — Status & Roadmap

> **Updated Aug 21 2026.** P0 (DIY Intent tool) is **shipped** — see "P0 shipped" below for what landed vs the original design. P1 (OPT-07 truncation) is next, design frozen. P2 (AccessibilityService) queued after P1 + stability pass.

---

## ✅ P0 — DIY Intent Tool (SHIPPED)

The original design (one `intent` tool, second MethodChannel, zero deps) shipped with significant hardening beyond it. Current state:

### Tool surface — grew from 6 to 17 curated actions

`open_url`, `search`, `open_app`, `open_maps`, `dial`, `email`, `alarm`, `timer`, `calendar_event`, `media_play`, `share`, `wallpaper`, `uninstall`, `settings_panel` (+`panel`), `settings` (+`page`), `system` (+`setting`/`value`), `intent`.

Plus a **generic escape hatch**: `action:"intent"` accepts raw `android_action` strings (`android.settings.*`, third-party actions) so new apps need zero code changes. Design principle: *curated actions → generic android_action → honest failure*. No per-app pattern matching.

### Hardening beyond original plan

- All handlers `async`/`await` — native errors (`NO_HANDLER`, `NO_PKG`) become real failures instead of fire-and-forget fake success.
- Safe extras parsing (`Map<dynamic,dynamic>` → `Map<String,String>`; no CastErrors from LLM JSON).
- URL safety: https auto-prefix only for domain-like hosts; `javascript:`/`file:` blocked; settings names never become web URLs.
- `resolveActivity` pre-check only when package pinned (API 30+ `<queries>` visibility false-negatives); implicit intents rely on `ActivityNotFoundException`.
- Email via `ACTION_SENDTO mailto:` + RFC-6068 query params + `EXTRA_SUBJECT/TEXT`; share defaults MIME `text/plain`; uninstall strips package constraint (uninstaller lives in `com.android.packageinstaller`).
- Alarm `"HH:mm"` parsing with range validation; Kotlin int-coercion limited to HOUR/MINUTES/LENGTH extras.
- Dark mode: `UiModeManager.setNightMode()` **with read-back verification** → permission-gated `Settings.Secure/Global.putInt("ui_night_mode")` → honest fallback opening `DARK_THEME_SETTINGS`. (An earlier AppCompatDelegate reflection step was removed: it only changed the app's own theme, not the system's, and ran unverified.) Research finding: system-wide night mode is gated behind privileged `MODIFY_DAY_NIGHT_MODE`; reliable sideload path is one-time `adb shell pm grant com.handy.handy_flutter android.permission.WRITE_SECURE_SETTINGS`.
- Idempotent permission flow (`hasWriteSettings` / `requestWriteSettings` returns granted-state; no re-opening Settings when already ON).
- Manifest `<queries>`: http(s)/geo/tel/mailto/spotify/whatsapp/tg schemes, SET_ALARM/SET_TIMER/SHOW_ALARMS/calendar INSERT/SEND/package DELETE/MEDIA_PLAY_FROM_SEARCH, all four Settings Panels, pinned packages.

### Known limits (researched, accepted)

- Bluetooth/Wi-Fi/airplane/mobile-data toggles are impossible for 3P apps (API 29/33 restrictions). Sanctioned UX = Settings Panels (`settings_panel` action) and settings pages (`settings` action).
- Reading/cleaning mail requires Gmail API OAuth (cloud) — rejected per user; Tier-0 intents only.
- System-wide dark mode needs adb-granted `WRITE_SECURE_SETTINGS` on most builds (see above).

---

## ✅ P1 — OPT-07 Context & History Truncation (SHIPPED)

> Landed Aug 21 2026. One deviation from the frozen design: **no schema v2** —
> `currentContextSize`/`messageOffset` columns were dropped because truncation
> is recomputed per turn from in-memory history and window state is derived
> from row counts at query time. No migration needed.

1. **Truncation** (`lib/agent/context_budget.dart`, pure + unit-tested):
   assumed 256K char window; truncation triggers above 200K soft limit and
   keeps a ≤110K suffix (100–125K target band). Consecutive tool messages are
   one atomic unit (never split a batch); everything from the last
   `UserMessage` on is mandatory even over target. Any single tool result is
   head-clamped to 32K regardless (`[...truncated N chars]`). Applied at one
   place: `AgentLoop.run` boundary — non-destructive, full history stays for
   persistence/UI.
2. **Message windowing**: opening a conversation loads the newest 50 messages
   (`loadConversation(id, messageLimit:)`); scrolling near the top loads the
   previous page (`loadOlderMessages(beforeMessageId:)`) with a spinner and
   viewport-anchored prepend (no jump).
3. **Sidebar pagination**: live watch limited to first 20 recents;
   `loadOlderConversations(beforeUpdatedAt, beforeId)` cursor-pages append on scroll-to-bottom
   with a spinner, deduped by id against the watched page.
4. **Shared paging engine** (`lib/widgets/paging.dart`): `PagedFetcher<T>`
   (loading guard, has-more, key-dedupe), `shouldLoadMore` edge detector,
   `LoadMoreIndicator` spinner — reused by both scroll surfaces.
5. **Persistence made merge-safe**: `saveConversation` upserts messages by
   messageId instead of delete-all+reinsert, so rows outside the loaded
   window survive saves. `_failWorking` now explicitly deletes a persisted
   working bubble. Attachments still rewrite (small, composer-derived).
6. **Debug footer** (kDebugMode only): `ctx ~NK / 200K · N msgs loaded`.

---

## 🧭 P2 — AccessibilityService (queued)

After P1 + stability pass. Screen-tree reading (`AccessibilityNodeInfo`) + gesture injection (`dispatchGesture`) → full on-device automation (Tasker-class), including UI-only toggles like dark mode via actually tapping Settings. Requires manual user enable in accessibility settings; big privacy/trust story to design first.

Related future candidates (on-device, non-cloud): NotificationListenerService (read/dismiss notifications), ML Kit document scanner + OCR (~300KB, no camera perm), BiometricPrompt gating for destructive actions.

---

## ✅ Also shipped alongside P0 (LLM client resilience + error policy)

- `_postWithRetry` / `_sendStreamWithRetry`: 3 attempts, exponential backoff, `Retry-After` honored. Fixes free-model flakiness ("Software caused connection abort") including stale keep-alive sockets.
- Streaming requests built per attempt via builder closure (fixes "Bad state: Can't finalize a finalized Request" when app backgrounds during intent launches).
- `LlmException.transport` flag distinguishes infra failures from agent mistakes.
- Error policy: transport/API errors → SnackBar via `_failWorking` (working bubble removed, nothing persisted/context); tool-call errors → shown inline AND added to context (agent's business).

## Known open items

- Stream-stall watchdog for `chatStream` (headers timeout only; a stalled mid-stream hangs `_busy`). ~20 LOC inactivity transformer.
- Malformed SSE JSON surfaces as generic "Unexpected error" toast (harmless, cosmetic).
