# Handy — General-Purpose Android Agent (Flutter)

An on-device AI agent for Android: search, read, and safely edit any file the user grants
access to, and act on the phone via intents, notifications, and accessibility services.
The **loop + tools run on the device**; the LLM is cloud; Cloudflare (Worker → D1/KV) is a
lightweight data layer only.

> Why Flutter (researched Aug 2026): `dart:io` gives native `File`/`Directory`/`Process` — so
> the shell/real-filesystem work that would have forced Kotlin in RN/Expo needs **zero Kotlin**.
> Mature plugins cover SAF, a11y, and notifications. Flutter is AOT-compiled native (not a game
> engine); it renders its own UI and talks to the OS via platform channels.

---

## Main goals

1. **General-purpose agent loop on-device** — a small custom loop (model → `tool_call` → result)
   with an initial tool set: `read` · `write` · `find` · `grep`.
2. **Search/read any accessible file** — one-time SAF folder grant (persisted), then full
   read/write/walk over granted dirs.
3. **Safe editing** — structured `edit_file` ops, diff preview, undo snapshots.
4. **Act on the phone** — `open_url`, `dial`, `play_media`, `notify` (Phase 1); a11y
   `ui_read`/`ui_click`/`ui_type`/`ui_swipe`, `launch_app` (Phase 2); notification reading.
5. **Real commands, no root** — bundled static `busybox` in the app-private workspace, run via
   `dart:io Process` (Phase 3). No Termux, no allowlists, no Shizuku.
6. **Cloud data layer** — a thin Worker exposing D1 (sessions/transcripts) + KV (cache); AI
   Gateway optional for LLM caching/spend.

**Explicitly not:** hosting the loop in the cloud (files live on-device → keep the loop with
them), Termux dependence, root/Shizuku at first.

---

## Stack (verified on pub.dev, Jul–Aug 2026)

| Concern | Package / mechanism | Notes |
|---|---|---|
| SAF file access | **`saf` v2** (ivehement/saf) | `pickDirectory()` persisted grant; `walk()`; streamed read/write; `openFileDescriptor()` → live `/proc/self/fd/` path (feeds path-based tools) |
| Real files / processes | `dart:io` `File`·`Directory`·`Process` | bundled `busybox` in app dir; no Kotlin |
| App workspace dir | `path_provider` | `getApplicationDocumentsDirectory()` |
| LLM client | OpenAI-compatible over `http` (`dart_openai` / `open_responses` style) | `baseUrl` → OpenRouter or Cloudflare AI Gateway; custom simple loop preferred |
| Rich agent harness (optional) | `dart_agent_core` / `flutter_ai_sdk` ToolRunner | only if custom loop outgrows |
| a11y (Phase 2) | `flutter_accessibility_service` | click/setText/dispatchGesture/screenshot |
| Notifications (Phase 2) | `flutter_notification_listener` | read other apps' notifications |
| Local session store | `sqflite` (or `drift`) | active transcript + offline queue |
| Cloud data layer | Worker (D1 + KV) via `http` | JSON API; KV optional cache |

**SAF reality (Android 11+):** no app — not even Termux — can read arbitrary storage without
consent. Our answer: one persisted SAF tree grant + app-private workspace + `openFileDescriptor`
bridging, exactly like the previous RN plan but with `dart:io` instead of Kotlin modules.

---

## Architecture

```
Flutter (on-device)                          Cloudflare (data layer only)
┌───────────────────────────────┐             ┌──────────────────────────┐
│ chat UI  ← agent loop ← LLM ──┼───HTTP────▶│ AI Gateway (optional)     │
│ tools: read/write/find/grep    │             └──────────────────────────┘
│   SAF (saf) · dart:io Process  │             ┌──────────────────────────┐
│   a11y · notifications (P2)    │───HTTP────▶│ Worker → D1 (transcripts │
│ local: sqflite (session)       │  (background sync)  → KV (cache)      │
└───────────────────────────────┘             └──────────────────────────┘
```

Tool-call contract (shared between LLM schema, loop, and tools):

```dart
class ToolCall { final String id; final String name; final Map<String, dynamic> args; }
class ToolResult { final String id; final bool ok; final String output;
                   final List<String> filesChanged; final ToolError? error; }
```

---

## Order of work

1. Scaffold Flutter app + chat UI + LLM wiring (OpenRouter via OpenAI-compatible client).
2. **SAF grant + `read`/`write`/`find`/`grep`** — the "done and cool" milestone.
3. Custom agent loop with tool-calling + malformed-JSON feedback.
4. Safe-edit layer (diff preview + undo snapshots).
5. Cloud data layer (Worker D1/KV) + background sync from sqflite.
6. Phase 2: a11y ui tools + notification reading (EAS-analog: none — build APK locally/CI).
7. Phase 3: bundled busybox shell.

## Cut-lines
Shizuku/root, `MANAGE_EXTERNAL_STORAGE`, and cross-app notification reading are the most
Play-hostile/expensive. Everything through Phase 2 (plus busybox) is a complete standalone agent.
