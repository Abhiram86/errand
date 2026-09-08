# Errand — General-Purpose Android Agent (Flutter)

An on-device AI agent for Android: search, read, and navigate any file the user grants access to, with web search and structured document understanding. The **loop + tools + storage all run on-device**; only the LLM is cloud (OpenAI-compatible HTTP). Persistence is local — no external data layer.

> Why Flutter (researched Aug 2026): `dart:io` gives native `File`/`Directory`/`Process` — so EH work that would have forced Kotlin in RN/Expo needs **zero Kotlin**. Mature plugins cover a11y and notifications. Flutter is AOT-compiled native (not a game engine); it renders its own UI and talks to the OS via platform channels.

---

## Main goals

1. **General-purpose agent loop on-device** — small custom loop (model → `tool_call` → result) with streaming + reasoning, up to 72 turns per request, token-budgeted with auto-compaction.
2. **Search/read/navigate any accessible file** — `MANAGE_EXTERNAL_STORAGE` + `dart:io` over `/storage/emulated/0`; workspace abstraction (`WorkingDirectory` root vs current) with `read`, `workspace` (pwd/cd/list/find), and path-traversal guards.
3. **Structured document understanding** — logical pagination for PDF (via `read_pdf_text`), DOCX/XLSX/PPTX (via `archive`+`xml`), with per-unit labels, character budgeting, and overlap for continuity.
4. **Web-augmented answers** — `websearch`/`webfetch` via Tavily (`search` + `extract` to Markdown) so the agent can ground file questions with live context.
5. **Local-first conversations** — Drift/SQLite persistence (conversations, messages, attachments), pinned favourites, recent ordering, watch streams for the sidebar; survives restarts, no cloud sync required.
6. **Model freedom** — runtime model catalog (`GET /models`) with fallback list, searchable picker, per-conversation model/provider, streaming or non-streaming chat.

**Explicitly not:** hosting the loop in the cloud (files live on-device → keep the loop with them), a remote DB/sync layer, Termux dependence, root/Shizuku at first.

---

## Stack and current prototype

| Concern | Package / mechanism | Notes |
|---|---|---|
| File access (current) | Android `MANAGE_EXTERNAL_STORAGE` + `dart:io` | `Workspace` singleton over `storage_access` MethodChannel; root `/storage/emulated/0`, `WorkingDirectory` tracks `current` |
| File tools | `read`, `workspace` (`pwd`/`cd`/`list`/`find`) in `lib/tools/` | `read` does byte-range for text + logical pagination for PDF/DOCX/XLSX/PPTX; `find` is glob + max_depth; `cd` mutates `WorkingDirectory`; **grep filter on all** |
| Document readers | `read_pdf_text` + `archive` + `xml` | `lib/internal/document_reading/` → `LogicalDocument`/`LogicalRead` with character budget (256 KB) and overlap |
| Web tools | `tavily` via `http` | `TavilyClient` (`/search`, `/extract`), used by `websearch`/`webfetch` tools; Bearer `TAVILY_API_KEY` |
| LLM client | OpenAI-compatible over `http` | `lib/llm/llm_client.dart` → `POST /chat/completions` + SSE `stream:true`; `baseUrl` → OpenRouter / HF endpoint; custom loop preferred |
| Agent loop | `lib/agent/` | `Tool` schema + `ToolRegistry` (safe `execute` → `ToolCallResult.failure`) + `AgentLoop.run()` with streaming deltas, reasoning, 72-turn cap, token budget, auto-compaction |
| Local session store | `drift` + `drift_flutter` | `ErrandDatabase` (Conversations, ConversationMessages, ConversationAttachments), `saveConversation` transaction, `watchConversationSummaries`/`watchPinnedConversations` |
| Model catalog | `http` + `lib/services/model_catalog.dart` | `GET /models?output_modalities=text`, static cache + in-flight dedup, fallback `kFallbackModels` |
| UI | Flutter Material 3, dark theme | `ChatScreen` (lib/main.dart) + `ChatSidebar`, `ChatComposer` (multi-line), `MessageBubbles`, `ModelPicker`, `AppColors` |
| a11y / notifications (Phase 2) | `flutter_accessibility_service`, `flutter_notification_listener` | click/setText/dispatchGesture/screenshot; read other apps' notifications |
| Real commands, no root (Phase 3) | bundled static `busybox` + `dart:io Process` | in app-private workspace; no Termux, no allowlists, no Shizuku |
| Large output spill | `ToolOutputFileService` | `cache/tool_outputs/`, 512 KB cap, max 50 files, 10-min TTL; head/tail preview with header reservation; `read` tool opens spilled files directly |

The current prototype uses Android all-files access so the agent can operate on a shared storage root. SAF remains a possible future replacement if Play distribution or narrower user grants become requirements.

---

## Architecture

```
Flutter — entirely on-device                   Cloud (LLM + Web only)
┌─────────────────────────────────┐           ┌──────────────────────────┐
│ chat UI (ChatScreen + Sidebar)   │           │ LLM — OpenAI-compatible  │
│   ↕ messages, working bubble,    │──HTTP──▶ │  /chat/completions (SSE) │
│     model picker, composer       │◀──SSE──── │  OpenRouter / HF / custom│
│                                  │           └──────────────────────────┘
│ agent loop (72 turns, streaming + compaction) │ ┌──────────────────────────┐
│   ↕ Tool schemas / calls/results │──HTTP──▶ │ Tavily — /search,        │
│                                  │           │  /extract → Markdown     │
│ tools: read · workspace          │           └──────────────────────────┘
│   (pwd/cd/list/find) · websearch │
│   · webfetch  ─┬─ document       │
│                │  readers (PDF/  │
│                │  DOCX/XLSX/PPTX)│
│ workspace ─────┼─ dart:io ──────▶│ /storage/emulated/0
│  WorkingDirectory (root+current) │           (MANAGE_EXTERNAL_STORAGE)
│                                  │
│ persistence: Drift/SQLite        │
│  Conversations / Messages /      │
│  Attachments — watch streams     │
└─────────────────────────────────┘
```

Tool-call contract (shared between LLM schema, loop, and tools):

```dart
class ToolCall { final String id; final String name; final Map<String, dynamic> args; }
class ToolCallResult { final String id; final bool ok; final String output; final ToolCallError? error; }
```

---

## Order of work

1. ✅ Scaffold Flutter app + chat UI + LLM wiring (OpenAI-compatible client, streaming, reasoning).
2. ✅ **File navigation milestone** — `MANAGE_EXTERNAL_STORAGE` + `WorkingDirectory` + `read` / `workspace` (`pwd`/`cd`/`list`/`find`) with traversal guards.
3. ✅ Structured document readers — `LogicalDocument` pagination for PDF/DOCX/XLSX/PPTX (zip-bomb + size limits).
4. ✅ Custom agent loop with tool-calling (12 turns), malformed-JSON feedback, and streaming observers (`onTextDelta`/`onReasoningDelta`).
5. ✅ Local conversation store — Drift (conversations/messages/attachments), pin/recent ordering, debounced saves, watch streams.
6. ✅ Web augmentation — Tavily `websearch`/`webfetch` tools (Markdown extract, focused query).
7. ✅ Model freedom — catalog fetch + searchable `ModelPicker` + per-conversation model/provider + fallback list.
8. ✅ Android intent tool — 5 core actions (`open_file`/`open_url`/`open_app`/`settings` + raw `android_action` hatch, legacy routing kept) + FileProvider media, BAL-safe launch, `bringToFront`, UI reopen buttons (see `next_plan.md` §P0; unified Sep 2026).
9. ✅ Context budgeting (OPT-07) — history truncation + message windowing + sidebar pagination + merge-based saves (see `next_plan.md` §P1).
10. ✅ UX batch (P1.5) — stop/copy buttons, rename, edit-message & regenerate (history truncation), voice input (`speech_to_text`), plus abortable cancel + foreground work indicator. See `next_plan.md` §P1.5.
11. ✅ AccessibilityService (P2, partial) — screen read + global actions + gated Draft-mode injection (`act`: tap/type/scroll with commit refusal). Remaining: plan-preview approval card, risk-class metadata, Send-tier opt-in. See `next_plan.md` §P2.
12. ✅ **Large tool output file-caching** — `ToolOutputFileService` spill (512 KB, 10-min TTL, max 50 files) + head/tail preview with header reservation + `read` tool cache resolution (see `next_plan.md` §P4b #4).
13. ✅ **`grep` filter for heavy tools** — `screen`, `read`, `workspace` list/find, `act then_read` (see `next_plan.md` §P4b #5).
14. ✅ **A11y lifecycle & toast UX** — auto-disable on close, cold-start toast with restricted guidance, Settings chip with Enable/Disable, lazy paused-notice on intent launches, composer multi-line (see `next_plan.md` §P4b #6–7).
15. **P3** — image multimodality (on `attachedFileUris`), safe editing (`edit_file` + diff/undo), local retrieval (embeddings + FTS).
16. **Phase 3+:** bundled `busybox` shell via `dart:io Process` in app-private workspace.

## Cut-lines

Shizuku/root and cross-app notification reading are the most Play-hostile/expensive. Everything through step 7 is already a complete standalone agent; steps 8–11 are additive and keep all data on-device.
