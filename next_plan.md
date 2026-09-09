# Next Plan — Status & Roadmap

> **Updated Sep 2026.** P0, P1, P1.5, P2, P3 (multimodality), P4a (guided refactor), P4b (hardening + memory), and v0.5.1 resilience enhancements are all shipped — **v0.5.1**.

---

## ✅ P0 — DIY Intent Tool (SHIPPED)

The original design (one `intent` tool, second MethodChannel, zero deps) shipped with significant hardening beyond it. Current state:

### Tool surface — grew from 6 to 17 curated actions

`open_url`, `search`, `open_app`, `open_maps`, `dial`, `email`, `alarm`, `timer`, `calendar_event`, `media_play`, `share`, `wallpaper`, `uninstall`, `settings_panel` (+`panel`), `settings` (+`page`), `system` (+`setting`/`value`), `intent`.

Plus a **generic escape hatch**: `action:"intent"` accepts raw `android_action` strings (`android.settings.*`, third-party actions) so new apps need zero code changes. Design principle: *curated actions → generic android_action → honest failure*. No per-app pattern matching.

> **Sep 2026 update (`225b599`):** unified to 5 core actions — `open_file` (new, `FileProvider` + MIME resolution), `open_url`, `open_app`, `settings`, `intent` — with backward-compatible routing for legacy actions (`search`/`dial`/`open_maps`/`email` → `open_url`; `calendar_event`/`media_play`/`share`/`wallpaper`/`uninstall`/`settings_panel` → generic). `alarm`/`timer`/`system` (dark-mode toggle) removed; UI toggles go through `act`. Native `launch` is BAL-safe (`PendingIntent` + a11y-context fallback), reports chooser sheets, and `bringToFront` restores Errand after `screen`/`act` work.

### Hardening beyond original plan

- All handlers `async`/`await` — native errors (`NO_HANDLER`, `NO_PKG`) become real failures instead of fire-and-forget fake success.
- Safe extras parsing (`Map<dynamic,dynamic>` → `Map<String,String>`; no CastErrors from LLM JSON).
- URL safety: https auto-prefix only for domain-like hosts; `javascript:`/`file:` blocked; settings names never become web URLs.
- `resolveActivity` pre-check only when package pinned (API 30+ `<queries>` visibility false-negatives); implicit intents rely on `ActivityNotFoundException`.
- Email via `ACTION_SENDTO mailto:` + RFC-6068 query params + `EXTRA_SUBJECT/TEXT`; share defaults MIME `text/plain`; uninstall strips package constraint (uninstaller lives in `com.android.packageinstaller`).
- Alarm `"HH:mm"` parsing with range validation; Kotlin int-coercion limited to HOUR/MINUTES/LENGTH extras.
- Dark mode: `UiModeManager.setNightMode()` **with read-back verification** → permission-gated `Settings.Secure/Global.putInt("ui_night_mode")` → honest fallback opening `DARK_THEME_SETTINGS`. (An earlier AppCompatDelegate reflection step was removed: it only changed the app's own theme, not the system's, and ran unverified.) Research finding: system-wide night mode is gated behind privileged `MODIFY_DAY_NIGHT_MODE`; reliable sideload path is one-time `adb shell pm grant com.errand.errand android.permission.WRITE_SECURE_SETTINGS`.
- Idempotent permission flow (`hasWriteSettings` / `requestWriteSettings` returns granted-state; no re-opening Settings when already ON).
- **Sep 2026 update (`225b599`):** the whole dark-mode ladder + `WRITE_SETTINGS` flow + `nextAlarm` ground-truth were removed from the intent channel; UI toggles are `act`-driven now.
- Manifest `<queries>`: http(s)/geo/tel/mailto/spotify/whatsapp/tg schemes, SET_ALARM/SET_TIMER/SHOW_ALARMS/calendar INSERT/SEND/package DELETE/MEDIA_PLAY_FROM_SEARCH, all four Settings Panels, pinned packages.

### Known limits (researched, accepted)

- Bluetooth/Wi-Fi/airplane/mobile-data toggles are impossible for 3P apps (API 29/33 restrictions). Sanctioned UX = Settings Panels (`settings_panel` action) and settings pages (`settings` action).
- Reading/cleaning mail requires Gmail API OAuth (cloud) — rejected per user; Tier-0 intents only.
- System-wide dark mode needs adb-granted `WRITE_SECURE_SETTINGS` on most builds (see above).

---

## ✅ P1 — OPT-07 Context & History Truncation (SHIPPED)

> Landed Aug 21 2026. Deviations from the frozen design: **no
> `currentContextSize`/`messageOffset` columns** — truncation is recomputed
> per turn from in-memory history and window state is derived from row counts
> at query time. A **schema v2 migration was still added** (review follow-up):
> UNIQUE index on `(conversation_id, message_id)` + `(conversation_id,
> sort_order)` lookup index, with a dedupe pass for pre-v2 rows.

1. **Truncation** (`lib/agent/context_budget.dart`, pure + unit-tested):
   assumed 256K char window; truncation triggers above 200K soft limit and
   keeps a ≤110K suffix (100–125K target band). Consecutive tool messages are
   one atomic unit (never split a batch); everything from the last
   `UserMessage` on is mandatory even over target. Any single tool result is
   head-clamped to 32K regardless (`[...truncated N chars]`). Applied at one
   place: `AgentLoop.run` boundary — non-destructive, full history stays for
   persistence/UI.
   > **Sep 2026 update (`dbe2757` + fixes):** superseded by token-based `ContextBudget` (per-model `contextSize`, reserve `min(16K, 25%)`, `~3.8 chars/token`, `models.dev` fallback) with pre-turn + mid-step LLM compaction (deterministic fallback under a 60s `compactionTimeout`; oversized tails shrink via `fitTailToTarget`, never block drops). `CompactedNoticeMessage` divider merge-saved via `compacted` rows (pre-divider rows retained, never re-sent). Char-based `truncateHistory`/`trimLlmMessages` kept as compat/tested layer. Loop cap `18 → 72` (ctor-overridable).
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

## ✅ UI polish (markdown, intent reopen, empty-bubble handling)

- **Markdown rendering**: assistant turns render via `gpt_markdown` (bold,
  tables, code, LaTeX); user turns stay plain `SelectableText`. The message
  list is wrapped in a `SelectionArea` for copy-anywhere selection.
- **Intent reopen buttons**: successful open-style intent tool bubbles
  (`open_url`, `open_app`, `open_maps`, `search`, `dial`, `media_play`,
  `email`, `share`, `wallpaper`, `settings`, `settings_panel`) show an Open
  button that re-fires the persisted args through the same
  `handleIntentAction` path as the agent — identical URL safety and error
  mapping. Side-effect actions (alarm/timer/calendar, system toggle,
  uninstall, raw `intent`) stay button-less. Derived entirely from persisted
  data; works for conversations stored before the feature existed.
- **Empty-bubble suppression**: whitespace-only streaming deltas no longer
  blank the …working placeholder; empty final answers drop the bubble (and
  delete its persisted row) instead of rendering an empty turn.

---

## ✅ P1.5 — UX Batch (SHIPPED Aug 21–22 2026, except item 6 → deferred to P3)

> All items are UI/history-manipulation work on top of the existing
> merge-save + windowing machinery. Also landed with this batch: abortable
> LLM cancellation (stop works during slow time-to-first-token via socket
> close, elapsed-seconds on the working bubble) and a foreground work
> indicator (dataSync FGS held while a turn runs — fixes SSE streams dying
> when an intent tool sends Errand to the background and Android's
> cached-apps freezer kills its sockets ~10s later).

### 1. Stop button + copy buttons (SHIPPED Aug 21 2026)
- While `_busy`, the rounded send button becomes a **square stop** button.
  Cancellation = a cancel flag threaded into `LlmClient.chatStream`/`chat`,
  checked between SSE events and at agent-loop turn boundaries. Partial text
  is kept as the final answer (marked "(stopped)"). In-flight native tool
  calls can't be interrupted — cancel takes effect at the next boundary.
  Pairs with the stream-stall watchdog (open items below).
- **Copy buttons**: one-tap copy icon on assistant bubbles and tool output
  (SelectionArea stays for free-form selection).

### 2. Finish Rename (SHIPPED Aug 21 2026)
- Dialog → `renameConversation(id, title)` in DB; sidebar updates via the
  existing watch stream; older loaded pages refreshed in place.

### 3. Edit user message (SHIPPED Aug 21 2026)
- Tap own bubble → loads text into composer (banner + cancel above the
  composer). On resend, history is truncated from that message onward
  (later messages AND their tool runs), then the loop runs fresh.
- Merge-based saves keep rows outside the loaded window — truncation
  explicitly `deleteMessage`s every removed row (`_truncateFrom`).

### 4. Regenerate answer (SHIPPED Aug 21 2026)
- Refresh icon on the last assistant bubble of a completed turn. Same
  `_truncateFrom` machinery applied from just after the last user message,
  then re-run via the shared `_runAgentTurn` (extracted from `_send`).

### 5. Voice input (`speech_to_text`) (SHIPPED Aug 21 2026)
- Mic icon (accent blue) on the send button when the composer is empty;
  turns red while listening (tap again to stop); switches to the send arrow
  when there is text. Live partial results replace the composer text.
- First-use language picker over `speech.locales()`, choice persisted via
  **shared_preferences** (one string key — schema v3 not needed for this).
- Plugin wraps Android's built-in SpeechRecognizer: zero shipped model
  weight, quality/network behavior follows the device's voice typing.
- Mic permission via the existing "intent" MethodChannel
  (`hasMicPermission`/`requestMicPermission`, awaitable through
  `onRequestPermissionsResult`) — no `permission_handler` dependency.
- Emulator note: enable the Google app + grant it mic access, and install an
  offline language under Settings → Voice → Offline recognition, or
  `listen` fails with `error_audio_error`.

### 6. Multimodality — images only (DEFERRED → P3)
- **Attach path**: composer image picker → OpenAI-compatible `image_url`
  content parts (base64 data URLs) on user messages.
- **Agent path**: new `image` tool — model locates an image via
  `workspace.find`, then reads it; the tool result carries the image as a
  content part for the next turn. This is the path the old
  `document_reader` `UnsupportedError("future vision path")` reserved.
- Loop changes: `_toLlmHistory` must emit multimodal content arrays;
  persistence needs attachment↔message linkage beyond the current
  conversation-level table (schema v3).
- Error policy: non-vision model selected → honest failure telling the user
  to switch models (reuse the transport-vs-agent error split).
- **Existing hook**: `Conversation.attachedFileUris` + the
  `conversation_attachments` table already persist per-conversation file
  URIs (unused so far) — image attach should build on that instead of
  inventing new storage.

---

## 🧭 P2 — AccessibilityService (NEXT)

Screen-tree reading (`AccessibilityNodeInfo`) + gesture injection
(`dispatchGesture`) → on-device automation (Tasker-class), including UI-only
toggles like dark mode by actually tapping Settings. Requires manual user
enable in accessibility settings. **Researched Aug 22 2026 — capability and
policy limits mapped; scope split into tiers below.**

### Research findings (Aug 2026)

**Policy — Play distribution of gestures is dead, sideload is fine:**
- **Play policy updated Oct 30 2025**: the Accessibility API now explicitly
  *cannot* be used by "an app that autonomously initiates, plans, and executes
  actions or decisions" — written specifically against AI agents. Errand's
  agent loop is exactly that. Non-autonomous uses still require a Play Console
  declaration + demo video + prominent in-app disclosure.
- **Conclusion**: P2 is **sideload/F-Droid only**, consistent with our existing
  model (MANAGE_EXTERNAL_STORAGE, adb-granted WRITE_SECURE_SETTINGS).
  Document as such; never ship Tier A to Play.
- **Android 13+ "Restricted setting"**: sideloaded APKs get the service
  grayed out ("For your security…"). Unlocks: App Info → ⋮ → **Allow
  restricted settings** (+ biometric confirm), session-based installers
  (F-Droid/Zapstore unaffected), or one-time
  `adb shell appops set com.errand.errand ACCESS_RESTRICTED_SETTINGS allow`
  (same spirit as the existing WRITE_SECURE_SETTINGS grant). The app should
  detect this state (`AppOpsManager.checkOpNoThrow("android:access_restricted_settings", …)`)
  and show honest instructions instead of a dead toggle.
- **Android 17 / Advanced Protection Mode**: blocks non-`isAccessibilityTool`
  apps from the API entirely. We can't honestly declare `isAccessibilityTool`
  → AAPM users are locked out regardless. Accepted limit.

**Platform walls (accepted):**
- `FLAG_SECURE` blocks `takeScreenshot()` but not node reading.
- `isAccessibilityDataSensitive` (Android 14) hides views from non-declared
  tools; adoption growing (OTP fields, password managers) — some targets will
  go invisible over time.
- Banking/finance apps run anti-a11y SDKs (ThreatMark etc.) that detect and
  block us. Don't fight it.
- Compose/Flutter/Canvas-heavy apps may expose empty trees without semantics;
  coordinate-tap fallback covers this blind.
- No programmatic enable, ever — manual user enablement in Settings is by
  design.

### Capability tier list

#### 🟢 Tier S — P2a: read + safe globals (SHIPPED Aug 22 2026)
1. **`ErrandAccessibilityService`** — Kotlin service + XML config
   (`canRetrieveWindowContent`, `canPerformGestures`, `canTakeScreenshot`,
   `flagReportViewIds`, `feedbackGeneric`). Static-instance + MethodChannel
   `"a11y"` mirroring `"intent"` (service lives independent of the Flutter
   engine). Methods: `isEnabled`, `isRestricted` (appops check),
   `openSettings`, `readScreen`, `globalAction`, later `gesture`.
2. **`screen` tool** — serialize active-window tree into a compact outline
   (`[i] Button "Allow" bounds=[…] clickable`), char-budgeted like
   `LogicalDocument`, reusing the existing 32K per-result clamp; depth/result
   caps from day one.
3. **Global actions**: back, home, recents, notification shade, lock screen
   (API 28+), screenshot (API 30+, fails cleanly on FLAG_SECURE windows).
4. **Dark mode payoff** — open Display settings via the existing intent tool,
   find the "Dark theme" toggle node, tap it. Retires the fragile
   UiModeManager → putInt → DARK_THEME_SETTINGS ladder on every OEM, no
   WRITE_SECURE_SETTINGS needed.
5. **State awareness** — `isEnabled`/restricted-state surfaced through
   `_systemPromptFor` ("screen control available / not enabled — tell user
   how") + persistent "Errand can see your screen" indicator (reuse FGS
   notification pattern from AgentForegroundService).
6. **Read-back verification** — listen for `TYPE_WINDOW_STATE_CHANGED` after
   actions to confirm a tap landed (same discipline as the dark-mode ladder).

#### 🟡 Tier A — P2b: gated gesture injection (Deny / Draft / Send model)

> **Draft-mode subset SHIPPED Aug 22 2026**: tap-by-label (commit-word
> refusal, matched-pattern reporting), SET_TEXT typing (password-refused,
> never submits), direction-aware scroll with deterministic `at_end`, plus
> Gmail-session hardening (cap-reason reporting, word-boundary labels,
> settle_ms, sequential-call prompt guidance). Remaining: plan-preview card
> (#11 UI), risk-class metadata (#7), Send-tier opt-in, coordinate fallback
> (#13).
>
> **ViewPager off-screen pollution — SHIPPED Sep 2026 (`cf31018`):** Solved via
> viewport partitioning! Rather than fragile heuristic page drops, elements are
> partitioned by viewport bounds. Visible items are emitted first in visual reading
> order; off-screen nodes (e.g. adjacent ViewPager tabs like WhatsApp Communities)
> are grouped under a distinct `--- Off-screen ---` section. Combined with upfront
> full ref mapping, interactive line prioritization, repetitive static list compression,
> and TalkBack boilerplate stripping.

**Consent model — risk-tiered three-way gate, not binary Approve/Deny.**
Rule of thumb: *the model may prepare anything, only the user pulls
triggers.* Draft-as-default also keeps committing flows outside Play's
"autonomously executes" clause even in principle — the user performs the
final act.

| Option | Behavior | Default for |
|---|---|---|
| **Deny** | Step dropped; agent told "user declined", continues or aborts | — |
| **Draft** ⭐ | Agent does everything except the commit: opens chat, types into the field, fills forms — **leaves Send untapped**, then tells the user "review & send" | Anything irreversible: messages, emails, posts, payments, deletes |
| **Send** | Full auto-completion | Reversible actions only: navigation taps, scrolls, opening apps, toggles |

7. **Risk classes** — `Tool.requiresValidation` graduates into an
   `actionRisk` metadata: `readonly` (no gate) / `reversible`
   (batch-approve OK) / `committing` (**draft-only unless user upgrades**) /
   `dangerous` (per-step approval always). Applied per intent-action too:
   `dial` ≈ committing, `alarm` reversible, `uninstall` dangerous. Same
   open-style vs side-effect split the reopen-button logic already uses.
   Enforcement hook point: `ToolRegistry.execute` honoring the flag
   (`CancelToken` proves mid-loop external control already works).
8. **Tap by text/label** — `findAccessibilityNodeInfosByText` →
   `ACTION_CLICK`, classified by risk class above.
9. **Type into focused field** — `ACTION_SET_TEXT` on editable nodes. Note:
   SET_TEXT never fires keyboard enter-to-send, which is why Draft mode is
   reliable — typed text just sits in the field. Fallback for apps without
   SET_TEXT support: clipboard-paste gesture. Hard gate: never auto-type
   into password/OTP-ish fields (`isPassword` + heuristics).
10. **Swipe/scroll** — `dispatchGesture` + continued strokes;
    navigation-grade, reversible class.
11. **Plan preview + draft verification** (the preview story):
    - **Upfront plan card** rendered in chat while Errand is still
      foreground: numbered steps with risk badges, commit steps marked
      `SKIPPED — you send`; user picks Approve · Edit · Deny once for the
      whole batch. This also sidesteps the "chat UI is behind the target
      app after launch" problem — no overlay bubble or notification-action
      approval needed in v1.
    - **Post-draft verification**: one extra `readScreen` after typing →
      tool result shows the field content (`typed: "…" ✓`) so chat history
      doubles as the receipt (ToolMessages already give us this).
    - Commit-control detection via label/class heuristics (text ∈ {send,
      post, publish, pay…}); if no confident match → silently stays in
      Draft mode (safe-by-default).
12. **Longer loops — DONE Sep 2026 (`dbe2757`)**. Cap went
    12 → 18 → 72 (`defaultMaxTurns`, ctor-overridable `maxTurnCount`), with
    mandatory mid-run compaction (pre-turn + post-batch `_compactIfNeeded`,
    newest 1–2 tail blocks kept, rest LLM-summarized with deterministic
    fallback; persistence/UI history untouched except the persisted
    `CompactedNoticeMessage` divider). Original plan below, kept for record:
    - Raise `maxTurns` to ~40 (make it an `AgentLoop` constructor param).
    - **Mid-run compaction is mandatory with that** — entry truncation only
      sees persisted history; screen outlines are up to ~24K chars per read,
      so a long run can exceed the window mid-flight even though each turn
      fit. After each completed turn, if the running payload exceeds
      `kContextSoftLimit`, drop the oldest complete *turn units* (one
      assistant message + its tool results — same atomic shape
      `_toLlmHistory` synthesizes, so removal never orphans a tool call),
      always keeping the newest ~6 turns and the system prompt. Local-only:
      persistence/UI history untouched. If the model needs dropped context,
      it re-runs `screen read` — same recovery a human would do.
    - Each step already = one ToolMessage = free audit log, so compacted
      turns stay reviewable in chat even after leaving the LLM payload.
13. *(deferred)* Coordinate fallback tap for empty-semantics apps; require
    screenshot preview before approving (blind taps are the riskiest form).
    Known Draft-mode gap: apps that don't expose input fields via semantics
    degrade to "agent can't help here" — correct failure.

#### 🟠 Tier B — adjacent wins (opportunistic, cheaper APIs)
14. Notification reader/dismissal — `NotificationListenerService`, lighter
    permission, no gesture hell.
15. "What's on my screen" queries — Tier-S reading + existing websearch.
16. Focus/app-blocker mode — foreground-app detection + self-return-home;
    policy-gray on Play, fine sideloaded.

#### 🔴 Tier C — never build
- Reading OTP/2FA codes or automating banking/payment flows (anti-abuse SDKs
  fight this; malware-shaped).
- Background always-on event monitoring / keylogging patterns — only listen
  during an active agent turn.
- Programmatic enablement / bypassing Restricted Settings.
- Any Play distribution of Tier A (Oct 2025 policy prohibits autonomous
  execution outright).

### Cut line
**P2a = all of Tier S. P2b = items 8–10 under the Deny/Draft/Send gate +
item 11 previews. Items 12–13 deferred. Tier B opportunistic. Tier C never.**

Design notes carried over from P1.5 planning:
- Foreground-service plumbing from P1.5 (start/stop with a work lifecycle +
  typed service declaration) is directly reusable for the accessibility
  service's "Errand is automating" indicator and the batch-approval flow.

Related future candidates (on-device, non-cloud): ML Kit document scanner +
OCR (~300KB, no camera perm), BiometricPrompt gating for destructive actions.

---

## ✅ P3 — Multimodality (SHIPPED Aug 28 2026)

**Image/audio/video multimodality built *inside* `read` (`lib/tools/file_tools.dart`) — no separate service — as requested Aug 26–28.**

- **Media read inside `read`** — `kMediaFormats` (jpg/jpeg/png/webp/gif · wav/mp3 · mp4/webm/mov, 20 MiB cap) → `ToolCallResult.contentParts` as OpenAI-compatible `image_url` / `input_audio` / `video_url` data URLs. Whole-file, base64, `file_picker` cache-aware (`_resolveReadableFile` allows `/data/.../cache/file_picker` + any `attachedFileUris`). Capability-gated via `ModelCatalogService.supportsInput` (`architecture.input_modalities` → `ModelOption.inputModalities`); unknown endpoints (`null`) allow the attempt, known-unsupported → `unsupported_modality` honest failure. Delivered as synthetic `user` message after tool batch (`lib/agent/agent_loop.dart: pendingMediaParts`) — tool-role media isn't portable. Counted in `context_budget` `List`-content path.
- **Attach UX** — `+` → `file_picker` (`allowMultiple: true`) → `ChatScreen._pendingAttachments` staging (pre-send card above composer) → on Send snapshotted into `UserMessage.attachedUris` (ordered, `ConversationMessages.attachedUrisJson` col, schema v4) + appended to global `ConversationAttachments` inventory. Card persists under the user bubble (in order), also visible in Settings → `Local` tab (history+pending). Legacy `[Attached files:]` suffix handled for old messages via `_stripAttachedBlock`/`_extractAttachedUris`.
- **Discovery** — `attached_files` tool (`lib/tools/attached_files_tool.dart`, zero params) lists the global inventory; system prompt also injects `Attached files (n):` when non-empty. `ToolRegistry.defaults(supportsInput, getAttachedFiles)` wires both.
- **Verified**: `file_picker: ^10.1.2`, `flutter analyze` clean, 81 tests (new `file_tools_media_test.dart` + `model_catalog` modality tests).

*Deferred from original P3 scope:*
- Safe editing tool (`write`/`edit_file` with diff preview + undo) → **moved to Backlog** (needs write-policy decision, not P3).
- Local retrieval (embeddings/FTS) → **deferred** (stays backlog, not P3).

**Backlog (from P3):**
- `write`/`edit_file` + local retrieval — queued after P4; not in P3 ship.

---

## 🧭 P4 — Guided refactor + hardening release (swapped Aug 28: ex-P4b now first)

### P4a — v0.5.0 (guided service-by-service refactor)

Context: ~99% of the Dart code is AI-written; the goal is to understand
and own it, then shrink and harden it — NOT a line-by-line rewrite.

Process (per service):
1. **Walkthrough** — I explain the service line by line (what each piece
   does and why it exists).
2. **Core-algorithm revisit** — together we decide what to cut, merge, or
   simplify; optimize for reliability and faster response.
3. **Rewrite service-scoped** — small, contained diffs; tests updated per
   service before moving on.

Service order (dependency-driven, leaf services first):
1. `model_catalog.dart` + `models/model_option.dart` (smallest, isolated)
2. `tavily_client.dart` + web tools
3. `workspace.dart` + `file_tools.dart` + `workspace_tool.dart`
4. `internal/document_reading/` (readers)
5. `intent_service.dart` + `intent_tool.dart`
6. `llm_client.dart` (+ CancelToken/retry)
7. `agent/context_budget.dart` + `agent_loop.dart`
8. `services/database.dart` (schema v4 — now includes P3's `attachedUrisJson`)
9. `a11y_service.dart` + `ErrandAccessibilityService.kt` + screen/act tools
10. `main.dart` + widgets last (UI depends on everything above)

Rules of engagement during P4a:
- No feature changes inside refactor steps — behavior parity verified by
  the existing test suite (plus new tests where coverage is thin).
- Any bug found during walkthrough gets fixed inline but noted separately.
- Each service lands as its own commit so regressions are bisectable.

### P4b — v0.5.0 (hardening + memory)

1. **Play Protect / policy hardening (legal-ish, feature-preserving).**
   Goal: reduce the chance Play Protect flags Errand as a threat without
   dropping any capability. Sideload-first app, so this is about reputation
   hygiene, not Play compliance:
   - Audit every permission against actual usage; remove anything unused.
   - Document (in-repo) why each sensitive API is used: a11y service
     (screen read/injection — user-enabled, disclosure string already
     honest), MANAGE_EXTERNAL_STORAGE, WRITE_SECURE_SETTINGS,
     RECORD_AUDIO, IME flag. Keep the accessibility `isAccessibilityTool`
     question answered truthfully (we are NOT an accessibility tool →
     accept Restricted-settings friction rather than lie).
   - Avoid patterns Play Protect heuristics dislike: no dynamic code
     loading, no reflection into private APIs, no silent installs; keep
     all injection behind the explicit user-enabled service.
   - Verify the release build is signed consistently and minified with the
     current proguard rules; re-check that no debug endpoints ship.
   - If Play Protect still flags: capture the verdict via
     `ApplicationExitInfo` / Play Console if ever published, and fall back
     to documenting "add to Play Protect allowlist" in README.
2. **Small UX improvements** — ad-hoc list, e.g.: settings sheet polish,
   better error toasts, composer tweaks found during daily use. Scope
   flexes; nothing structural.
3. **Global memory tool + table (schema v5).**
   - New `memories` table: key/value or freeform rows (id, content, tags?,
     createdAt/updatedAt) — persistent across conversations.
   - New `memory` tool for the agent: search/recall, save, update, delete;
     editable by the user too (simple UI later or via chat command).
   - System-prompt hook: inject a short "known facts" digest so the agent
     uses memory without explicit recall calls when relevant.
   - Note: was v4 in old plan; now v5 after P3's `attachedUrisJson` consumed v4.
4. **Large Tool Output File-Caching (replaces 24k char hard clamp) — ✅ SHIPPED Sep 2026.**
   - Created `ToolOutputFileService` (`lib/services/tool_output_file_service.dart`) to spill outputs exceeding 6k characters into a cache file via `path_provider` (`cache/tool_outputs/tool-{id}_{hash}-output.txt`, atomic tmp+rename write, 512 KB store cap, max 50 files) with a 10-minute default TTL (configurable).
   - Returns a concise preview reserving the leading metadata header block plus the initial 2k and final 2k characters along with the created file path:
     `[... Output truncated: showing first X and last Y of Z characters. Full output saved to: <filePath> (TTL: 10m). Use read tool with path: "<filePath>" (supports grep, offset, length) to inspect further. ...]`
   - Applied across all text-heavy tools (`screen`, `act then_read`, `read`, `workspace` list/find, `webfetch` (extract stored up to 100k chars), `websearch`) and integrated into `ToolRegistry.execute` as a universal safety net (already-spilled previews pass through untouched so the two layers never overwrite each other).
   - Sweep is opportunistic (expired/over-cap files deleted on the next large spill — no background timer). Updated `_resolveReadableFile` so the `read` tool opens only files inside the spill directory (post-normalize containment check) and reports a regenerate hint for expired spills.
5. **`grep` argument for data-heavy tools (`screen_tool`, `read_tool`, `workspace_tool`) — ✅ SHIPPED Sep 2026.**
   - Added optional `grep` argument (case-insensitive substring/regex filter via `GrepFilter`) across `screen` (outline filter, forces full read), `read` (document/text filter with line numbers, expands unpaginated length to 512KB), and `workspace` (`find`/`list` output entries filter).
   - Allows the model to pull only matching lines (e.g. `screen read grep:"Total"` or `read path:"..." grep:"API_KEY"`) instead of loading 2–4k tokens of irrelevant content.
   - Evaluated before caching/truncation, allowing single-turn precision retrieval. Safe fallback to escaped literal match on invalid regex syntax.
   - `GrepFilter` hardening: 200-char pattern cap, nested-quantifier ReDoS guard, 200-match cap with overflow note; structured grep filters body only (header reserved); `list`/`find` grep runs before pagination with honest match counts.

6. **A11y lifecycle & toast UX — ✅ SHIPPED Sep 2026.**
   - Service auto-disables on task removal (`onTaskRemoved`) and when `MainActivity` finishes (`onDestroy` with `isFinishing`) — keeps other apps secure per the sideload model.
   - Cold start shows a dismissible toast (8s auto-dismiss) when screen access is off, with **Restricted-setting steps** when `isRestricted()` is true. Dismissal persists via `a11yPromptDismissed`; re-enable clears the flag so future off-cycles re-notify.
   - Settings sheet (Tools tab) shows Active/Disabled chip with **Enable in Settings** / **Disable now** buttons; resumes refresh the chip via `WidgetsBindingObserver` (no stale state after toggling in system Settings).
   - `intent` open-style actions (`open_file`/`open_url`/`open_app`/`settings`/`intent`) lazily append a paused-notice **after successful launch** — no wasted channel call on failures, no false positive on channel errors. UI replay (`replayIntentAction`) skips the check entirely.

7. **Composer multi-line** — ✅ SHIPPED Sep 2026. `TextInputAction.newline` (was `send`), Enter inserts a newline up to 4 visible lines; Send button is the only submit path.
8. **Web, Visual & Catalog Resilience — ✅ SHIPPED Sep 2026 (v0.5.1).**
   - **Offline/free web fetch fallback:** Added on-device `webfetch` extraction using `reader_mode` + `html2md` when Tavily API key is absent or when Tavily returns errors. `websearch` guides agent to fallback search engines (e.g. DuckDuckGo Lite via `webfetch`).
   - **Accessibility visual screenshot fallback:** Added `screenshot` action in `screen` tool via Android accessibility screenshot API (`takeScreenshot`) returning base64 vision parts.
   - **Background catalog prefetching:** Immediately kicks off background catalog fetch on API key save or provider change; prevents stale cache wipes.
   - **ModelPicker live refresh:** Dynamically updates dialog options upon refresh completion, auto-fetches for providers with keys, and links OpenRouter default preset models to `kFallbackModels`.

**Backlog (deferred from P3):** `write`/`edit_file` with diff preview + undo — needs write-policy decision, queued after P4b.

---

## ✅ Also shipped alongside P0 (LLM client resilience + error policy)

- `_postWithRetry` / `_sendStreamWithRetry`: 3 attempts, exponential backoff, `Retry-After` honored. Fixes free-model flakiness ("Software caused connection abort") including stale keep-alive sockets.
- Streaming requests built per attempt via builder closure (fixes "Bad state: Can't finalize a finalized Request" when app backgrounds during intent launches).
- `LlmException.transport` flag distinguishes infra failures from agent mistakes.
- Error policy: transport/API errors → SnackBar via `_failWorking` (working bubble removed, nothing persisted/context); tool-call errors → shown inline AND added to context (agent's business).

## Known open items

- Stream-stall watchdog for `chatStream` (headers timeout only; a stalled mid-stream hangs `_busy`). ~20 LOC inactivity transformer.
- Malformed SSE JSON surfaces as generic "Unexpected error" toast (harmless, cosmetic).
