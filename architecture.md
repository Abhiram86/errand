# Errand (Flutter) — Architecture Overview

This document maps the current implementation: a streaming chat UI, an OpenAI-compatible agent loop with reasoning, file + workspace + web + Android-intent tools, structured document readers, Drift persistence, and Android shared-storage access. Everything except the LLM and Tavily runs on-device.

## Big picture

The app keeps the conversation (and its persistence) on the phone and sends the history to the configured LLM. The LLM can call the registered file/web tools; tool results are fed back into the same loop until the model returns a final answer or 18 turns are reached. Streaming deltas and reasoning are forwarded to the UI live.

```text
chat UI (lib/main.dart: ChatScreen)
     │  owns Conversation, _messages, _working state,
     │  WorkingDirectory, sidebar/composer/model picker
     │  + Drift watch streams (summaries + pinned)
     ▼
agent loop (lib/agent/agent_loop.dart) ──────────┐
     │  _toLlmHistory() + systemPromptBuilder      │
     │  up to 18 turns, onTextDelta/onReasoning   │
     ▼                                             │
LLM client (lib/llm/llm_client.dart)  ◀── HTTP/SSE ─┤ OpenRouter / HF / custom
     ▲  POST /chat/completions (stream:true)      │  baseUrl (AppSettingsService)
     │  tool schemas / tool_calls / reasoning      │
     ▼                                             │
tool registry (lib/agent/tool_registry.dart)
     │  defaults: read, workspace, websearch, webfetch,
     │            intent, screen, act
     ├──────────┬──────────────┬─────────────┴─────────┐
     ▼          ▼              ▼                       ▼
 file tools   workspace    web tools              intent tool
 (read)       tool         (websearch/webfetch    (open_url/search/email/
              (pwd/cd/list/ → Tavily)                alarm/timer/share/settings/
              find)                                  system toggles …)
     │           │             │                        │
     └────┬──────┘             │                        ▼
          ▼                    ▼                 IntentService
   WorkingDirectory ──▶ dart:io ──▶ /storage/emulated/0  (channel "intent")
   (root+current)      File/Dir   MANAGE_EXTERNAL_STORAGE   │
          │                  │       TavilyClient              ▼
          │                  │       (api.tavily.com)    MainActivity.kt
          ▼                  │                     second handler: launch /
   document readers          │                     canResolve / hasWriteSettings /
     PDF · DOCX/XLSX/PPTX    │                     requestWriteSettings / system_toggle
     → LogicalDocument       │                     (UiModeManager dark mode w/ read-back,
       (paged, char-budgeted)│                      settings-panel fallbacks)

persistence (lib/services/database.dart)
  ErrandDatabase (drift) — Conversations / ConversationMessages / ConversationAttachments
  saveConversation (transaction) · watchConversationSummaries · watchPinnedConversations

model catalog (lib/services/model_catalog.dart → lib/models/model_option.dart)
  GET /models?output_modalities=text → ModelPicker dialog (searchable)
```

## Conversation and messages

`lib/types/conversation.dart` is the runtime session container. It carries:

- the optional system prompt (`localSystemPrompt` — built per turn from `WorkingDirectory.current`);
- the complete `List<Message>` history;
- the current `Directory` snapshot;
- `title`, `provider`/`model`, `isPinned`, `createdAt`/`updatedAt`.

`lib/types/message.dart` models the UI and history with typed messages:

- `UserMessage` — user input;
- `AssistantMessage` — model responses (including streaming working bubble);
- `ToolMessage` — tool name, args (`ToolInvocation`), call ID, display preview (`text`), full `result`, plus `reasoning`/`reasoningDetails`;
- `ErrorMessage` — legacy typed error turn (transport errors are no longer inserted as messages; they surface as SnackBars via `_failWorking`).

The UI stores a short tool preview for rendering (truncated), while the complete tool result is retained for future LLM requests and persisted to Drift.

`lib/types/tool.dart` defines the runtime result: `ToolCallResult { id, ok, output, error? }` with `toText()` helper and `ToolCallError { type, message, retryable }`.

## The agent — `lib/agent/`

- **`tool.dart`** defines the LLM-facing `Tool` schema (`name`, `description`, `parameters`, `handler`) and parsed `ToolCall` (`id`, `name`, `arguments`). `ToolCall.toJson()` serializes arguments as a JSON string as required by OpenAI-compatible APIs. `requiresValidation` is internal metadata for future mutation tools.
- **`tool_registry.dart`** registers the current tools and safely executes a call, converting handler exceptions into `ToolCallResult.failure`. `ToolRegistry.defaults({currentDir, workingDirectory})` currently contains `read` + `workspace` (which multiplexes `list`/`find`/`cd`/`pwd`) + `websearch` + `webfetch` + `intent` + `screen` + `act`.
- **`agent_loop.dart`** exposes `run(Conversation)`. It builds the LLM message array (`system` + `_toLlmHistory`), injects the live system prompt each turn, and drives streaming (`chatStream`) or non-streaming (`chat`) via `LlmClient`. Consecutive `ToolMessage`s are reconstructed as one assistant `tool_calls` message + matching `tool` result messages. Tool events are emitted via `onEvent` (`AgentToolCall` with `reasoning`). Loop cap is 18 turns.

## The LLM client — `lib/llm/llm_client.dart`

`LlmClient` is a small `package:http` client for `/chat/completions` with two paths:

- `chat()` — single JSON response, parses `choices[0].message.tool_calls` + `reasoning`/`reasoning_details`;
- `chatStream()` — SSE (`Accept: text/event-stream`, `stream:true`), forwards `content` deltas via `onTextDelta`, reasoning deltas via `onReasoningDelta`, and accumulates fragmented `tool_calls[].function.arguments` until `[DONE]`.

`LlmMessage { content, toolCalls, reasoning, reasoningDetails }` is the parsed response. `_sseDataEvents` handles UTF-8 chunk reassembly and comment keepalives. API key + baseUrl + model come from `LlmConfig`, built at runtime from `AppSettingsService` (SQLite-backed settings; no more compile-time dart-defines).

**Resilience (added after free-model flakiness):**

- `_postWithRetry` / `_sendStreamWithRetry` — up to 3 attempts with exponential backoff (0.8s → 1.6s), honoring `Retry-After` on 429. Retries cover `SocketException`/`http.ClientException` (stale keep-alive sockets, mobile network switches — the classic "Software caused connection abort"), timeouts, and HTTP 429/5xx.
- Streaming requests are built via a **builder closure** (`http.Request` is single-use; re-sending a finalized request throws "Bad state: Can't finalize a finalized Request").
- Retry covers only time-to-response-headers for streams; mid-stream failures surface as `LlmException(transport: true)` ("Stream interrupted") and cannot be transparently resumed.
- `LlmException.transport` marks infra-side failures (connection lost, timeouts, 429/5xx) vs agent/tool mistakes — consumed by the UI error policy (below).

Keys are configured in-app (header gear icon → Settings sheet) and stored
AES-GCM encrypted in the app-settings table.

## The file & workspace tools — `lib/tools/`

- **`read` (`file_tools.dart:readTool`)** — reads a bounded range. For text files: byte `offset`/`length` (default 512, max 512 KB) via `RandomAccessFile`. For structured files (PDF/DOCX/XLSX/PPTX): delegates to `readStructuredDocument` → `LogicalDocument.read(offset, length)` where `offset` is a logical unit index and `length` is a character budget (clamped to 256 KB). Path traversal is guarded via `path.relative` against `workspace.root`. Structured reads are memoized per-file in a registry-scoped map.
- **`workspace` (`workspace_tool.dart`)** — router with `action` enum `pwd|cd|list|find` multiplexing `listTool`/`findTool`/`cdTool` (+ `pwd`). Relative paths resolve from `workspace.current`; absolute paths must stay inside `workspace.root`. `WorkingDirectory { root, current }` is the shared mutable cursor (mutated by `cd`).
  - `list` — non-recursive, optional `pattern` RegExp filter, returns paths relative to `current`.
  - `find` — recursive glob (`*`/`?`, case-insensitive) with `type: file|dir`, `max_depth` (default 3, max 32), cap 500 results, skips inaccessible branches and reports them.
  - `cd` — validates target is a directory, then mutates `workspace.current`.

## Structured document readers — `lib/internal/document_reading/`

- **`document_reader.dart`** — router by extension (`pdf`, `docx`/`docm`, `xlsx`/`xlsm`, `pptx`/`pptm`); legacy `doc/xls/ppt` and images throw `UnsupportedError` (future vision path). `readStructuredDocument` loads once; `readStructuredFile` paginates.
- **`document_models.dart`** — `LogicalDocument { format, units }` + `LogicalDocumentUnit { label, text }` + `LogicalRead { start, end, total, hasMore, nextOffset, output }`. Budget respects character count, with one-unit overlap when `end-offset > 1` for continuity. `toToolOutput` formats the tool response.
- **`open_xml_reader.dart`** — `_OpenXmlPackage` (zip via `archive`, XML via `xml`) with guards `_maxPackageBytes` (64 MB), `_maxPackageEntries` (2000), `_maxXmlPartBytes` (16 MB). Parsers: `_wordParagraphText`/`_wordTableRows` for DOCX, `_readSharedStrings`/`_cellValue` for XLSX (chunked into 1800-char row groups), slide `p` extraction for PPTX.
- **`pdf_reader.dart`** — `ReadPdfText.getPDFtextPaginated` → one `LogicalDocumentUnit` per page.

## Web tools — `lib/tools/web_tools.dart` + `lib/services/tavily_client.dart`

- `TavilyClient { search, extract, _post }` — `POST https://api.tavily.com/{search,extract}`, Bearer token from `AppSettingsService.tavilyKey`, JSON decode with status-range check. The web tools resolve the client **lazily per call** (not at registry construction), so saving a key in Settings takes effect immediately; an unset key is a clean `ToolCallResult.failure` pointing at Settings.
- `websearch` — `query → search` → titles/URLs/snippets (truncated to 1200 chars each).
- `webfetch` — `url (+ optional query) → extract` (Markdown, 20k char cap) from a single URL, focused when query is present.

## The intent tool — `lib/tools/intent_tool.dart` + `lib/services/intent_service.dart`

One LLM tool (`intent`) covering Android app/web/system actions. Layered design: **curated actions → generic `android_action` escape hatch → honest failure**. No per-app pattern matching anywhere.

**Curated actions** (schema enum): `open_url`, `search`, `open_app`, `open_maps`, `dial`, `email`, `alarm`, `timer`, `calendar_event`, `media_play`, `share`, `wallpaper`, `uninstall`, `settings_panel` (+`panel`), `settings` (+`page`), `system` (+`setting`/`value`), `intent`.

- `_genericIntent` maps curated names to real Android action constants (`_androidActions`/`_panelActions`) and builds validated extras: alarm parses `"HH:mm"` into `android.intent.extra.alarm.HOUR/MINUTES` (range-checked), timer minutes→seconds, share defaults MIME to `text/plain`, uninstall strips the package constraint (the uninstaller lives in `com.android.packageinstaller`; pinning the target package would break resolution).
- **URL safety** (`_openUrl`): auto-prefixes `https://` only for domain-like hosts (`_looksLikeWebHost`); blocks `javascript:`/`file:`; anything else fails with guidance pointing at `android_action`/`settings`. This prevents the model from "opening" settings names as web URLs.
- **Generic escape hatch**: `action:"intent"` accepts a raw `android_action` string (e.g. `android.settings.DISPLAY_SETTINGS`, third-party `com.someapp.action.SYNC`) — new apps/actions need zero code changes.
- **UI reopen** (`isReopenable` + `replayIntentAction`): successful open-style intents (`open_url`/`open_app`/`open_maps`/`search`/`dial`/`media_play`/`email`/`share`/`wallpaper`/`settings`/`settings_panel`) render an Open button on the tool bubble that re-fires the persisted args through the same handler. Side-effect actions (alarm/timer/calendar, system toggle, uninstall, raw `intent`) stay button-less. Derived entirely from already-persisted data — no schema change, works for old conversations.
- All handlers are `async` and `await` the channel, so native errors (`NO_HANDLER`, `NO_PKG`, `INTENT_ERR`) become `ToolCallResult.failure` instead of fake success.

**Native side** (`MainActivity.kt`, channel `"intent"`):

- `launch` — builds the intent per action (`getLaunchIntentForPackage`, `ACTION_SENDTO mailto:` with `EXTRA_SUBJECT/TEXT` + query-param fallback, `ACTION_DIAL` for dial, explicit `androidAction` otherwise), adds `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_CLEAR_TOP`, adds `CATEGORY_BROWSABLE` for http(s). `resolveActivity` pre-check runs only when a package is explicitly pinned — implicit intents rely on `ActivityNotFoundException` (avoids `<queries>` visibility false-negatives on API 30+).
- `canResolve` — same mapping for pre-flight checks.
- `hasWriteSettings` / `requestWriteSettings` — idempotent `WRITE_SETTINGS` flow (returns granted-state; OEM fallback without package Uri).
- `system_toggle` — dark mode tries `UiModeManager.setNightMode()` first **with read-back verification** (some builds silently ignore 3P calls), then permission-gated `Settings.Secure/Global.putInt("ui_night_mode")`, finally opens `DARK_THEME_SETTINGS`/Display settings honestly. Note: system-wide night mode is effectively gated behind privileged `MODIFY_DAY_NIGHT_MODE`/`WRITE_SECURE_SETTINGS`; the adb-grantable path is `adb shell pm grant com.errand.errand android.permission.WRITE_SECURE_SETTINGS`.
- Manifest `<queries>` covers http(s)/geo/tel/mailto/spotify/whatsapp/tg schemes, alarm/calendar/share/delete/media-search actions, settings panels, and pinned packages (spotify/maps/chrome).

**Error policy** (deliberate split):

- **Tool-call errors** → collected in `ToolMessage`s, shown inline, AND added to context (agent's business).
- **Transport/API errors** (connection aborts, timeouts, 429/5xx — *not* the agent's fault) → `_failWorking` removes the working bubble and shows a SnackBar; never persisted, never enters context.

## The workspace — `lib/services/workspace.dart`

`Workspace` is a singleton over the `storage_access` MethodChannel:

- `hasPermission` → `Environment.isExternalStorageManager()` (Android R+; pre-R returns true);
- `requestPermission()` → `Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION` intent;
- `root` → `Directory('/storage/emulated/0')`.

Missing/failed channel calls are mapped to "no permission" rather than crashing. Direct `dart:io` paths are used, not SAF/DocumentFile. Manifest + `MainActivity.kt` declare and handle the permission.

## The model catalog — `lib/services/model_catalog.dart` + `lib/models/model_option.dart`

- `ModelCatalogService { load(baseUrl, apiKey) }` — `GET {baseUrl}/models?output_modalities=text`, parses `data[].id/name`, maps provider from `id` prefix (`qwen/… → Qwen`). Static `_cache` + `_inFlight` dedup; fallback is `kFallbackModels` + `kDefaultModelId`; the last user-picked model persists in the settings table.
- `ModelOption { id, name, provider }` → consumed by `ModelPicker`.

## The UI — `lib/main.dart` + `lib/widgets/` + `lib/theme/`

`ChatScreen` (with `WidgetsBindingObserver`) owns:

- `ErrandDatabase.instance` + two watch subscriptions (`watchConversationSummaries`, `watchPinnedConversations`);
- `_messages`, `_activeConversation`, `_workingDirectory`, `_modelCatalog`, `_llm`, `_selectedModel`/`_models`, `_controller`/`_scroll`;
- streaming bookkeeping: `_workingMessageId`, `_workingText` (StringBuffer), `_workingFlushTimer` (40 ms), `_persistTimer` (600 ms), `_scrollPending`.

Flow:

- `_send()` appends `UserMessage` + `AssistantMessage("…working")`, builds a `Conversation` snapshot (without the working bubble), and runs `AgentLoop` with `ToolRegistry.defaults(currentDir: root, workingDirectory)` + `systemPromptBuilder` + `onEvent`/`onTextDelta`/`onReasoningDelta`. Tool events become `ToolMessage`s via `_appendToolMessage` (finalizes prior streamed text, inserts tool, creates fresh working bubble). Deltas flush via `_flushWorkingText` → `SelectableText`. Final answer replaces the working bubble via `_replaceWorking`.
- **Error policy**: exceptions from the loop (`LlmException`, transport or otherwise) go to `_failWorking` — the working bubble is removed and a SnackBar shows the message. Infra errors are never added to `_messages`, never persisted, never sent in history.
- `_persistConversation()` saves the active conversation (excluding the in-flight working bubble) to Drift; `_schedulePersist` debounces, `_persistNow` flushes. `_sortedConversations` sorts by `updatedAt` desc for the sidebar.
- Sidebar (`ChatSidebar`) shows pinned favourites + recent (watch-driven, sorted), with rename/pin/delete options, slide-in animation and scrim. `ChatComposer` has add/context actions + send (gated by `canSend`). `MessageBubbles` renders user bubbles as `SelectableText`, assistant bubbles as `GptMarkdown` (tables/code/LaTeX; list-wide `SelectionArea` provides copy), and `ToolMessageBubble` `ExpansionTile`s (header truncated, output truncated for display only) with an Open button on successful open-style intent calls that replays the persisted args via `replayIntentAction`. Empty assistant turns are suppressed in rendering (and dropped from persistence going forward). `ModelPicker` is a searchable dialog with marquee for long names. Theme is `AppColors` + dark `ColorScheme` + `ThemeData(useMaterial3:true)`.

Storage permission is checked on start and on `AppLifecycleState.resumed`, with a one-at-a-time dialog prompt.

## Persistence — `lib/services/database.dart`

Drift database `ErrandDatabase` (4 tables):

- `Conversations { id PK, localSystemPrompt?, title, currentDir, provider?, model?, isPinned, createdAt, updatedAt }`
- `ConversationMessages { localId autoinc PK, conversationId FK→Conversations.id, messageId, sortOrder, messageType (user/assistant/tool/error), messageText, toolName?, toolArgumentsJson?, result?, reasoning?, reasoningDetailsJson?, error? }`
- `ConversationAttachments { conversationId FK, uri, PK(conversationId, uri) }`
- `AppSettings { key PK, value }` — generic runtime KV store: encrypted API secrets (OpenRouter/Tavily keys, base-URL override) + plain preferences (voice locale, last-selected model, a11y prompt flag). Encryption lives in `SecretStore` (AES-256-GCM, key file at `<app-support>/errand.key`, outside the DB); `AppSettingsService` is the typed access layer with an in-memory cache. Replaces the former shared_preferences usage.

Key ops:

- `saveConversation(Conversation)` — `transaction`: `insertOnConflictUpdate` conversation row, then merge messages by `messageId` (new rows appended after max `sortOrder`, known rows updated in place — window-safe), attachments rewritten. Backed by a UNIQUE index on `(conversation_id, message_id)` and a `(conversation_id, sort_order)` lookup index (schema v2).
- `deleteConversation`, `pinConversation` (toggle), `touchConversation` (bump `updatedAt`).
- `loadConversation(id)` / `_loadMessages` / `_loadAttachmentUris`, plus `insertMessage`/`replaceMessage`/`deleteMessage`.
- `watchConversationSummaries()` / `watchPinnedConversations()` — ordered streams for the sidebar.
- `getSetting(key)` / `setSetting(key, value)` / `deleteSetting(key)` — raw KV upserts/removals consumed by `AppSettingsService`.

`schemaVersion = 3`, `NativeDatabase` (or `drift_flutter` on device), `inMemory()` for tests. v1→v2 migration dedupes message rows, then creates the two indexes above; v2→v3 adds the app-settings table.

## Reading order

1. `lib/types/message.dart`, `lib/types/conversation.dart`, `lib/types/tool.dart`
2. `lib/agent/tool.dart` → `tool_registry.dart` → `agent_loop.dart`
3. `lib/services/workspace.dart` + `lib/tools/file_tools.dart` + `lib/tools/workspace_tool.dart`
4. `lib/internal/document_reading/` (models → reader → open_xml/pdf)
5. `lib/tools/web_tools.dart` + `lib/services/tavily_client.dart`
6. `lib/tools/intent_tool.dart` + `lib/services/intent_service.dart` + `MainActivity.kt` (intent channel)
7. `lib/tools/screen_tool.dart` + `lib/tools/act_tool.dart` + `lib/services/a11y_service.dart` + `ErrandAccessibilityService.kt` (a11y channel)
8. `lib/llm/llm_client.dart`
9. `lib/services/database.dart` + `lib/services/model_catalog.dart`
10. `lib/main.dart` + `lib/widgets/` + `lib/theme/app_colors.dart`

## The accessibility tools — `screen` + `act` (P2)

One user-enabled accessibility service (`ErrandAccessibilityService`, bound
via `BIND_ACCESSIBILITY_SERVICE`, config in `res/xml/`) backs two tools over
the `"a11y"` MethodChannel. Static-instance pattern: a null instance IS the
"not enabled" signal; Android 13+ "Restricted setting" for sideloads is
detected via AppOps and surfaced as enablement guidance.

- **`screen`** — read-only. Serializes the active window's node tree into a
  compact outline (`[depth] Class "label" [clickable,…]`) with independent
  depth/node/char caps; labels trim at word boundaries and empty-segment
  glue is collapsed. Truncation reports WHICH cap hit (`capHit: chars |
  nodes`) plus real counts, so the model doesn't retry uselessly.
  `settle_ms` (default 350) guards against stale reads after navigation.
  Global actions: back / home / recents / notifications / quick_settings /
  lock_screen (API 28+).
- **`act`** — gated injection, **Draft policy** (*agent prepares, user
  sends*): tap-by-label walks up to the nearest clickable ancestor;
  type uses ACTION_SET_TEXT on the focused field (never submits; password
  fields refused); scroll prefers node actions with a gesture fallback.
  Commit-looking controls (send/pay/delete/confirm…) are refused Dart-side
  by word-boundary matching, reporting the matched pattern. No coordinate
  taps exist at all.

## Next steps

- **P2 — AccessibilityService**: Tier S (read + globals) and Tier A Draft-mode
  (tap/type/scroll with commit refusal) **shipped** — see `next_plan.md` §P2
  for tier list, Play-policy findings, and remaining deferred items (plan-
  preview card, coordinate fallback for empty-semantics apps).
- Stream-stall watchdog for `chatStream` (inactivity timeout per SSE event; `_streamTimeout` only covers time-to-headers).
- Per-turn context re-truncation inside long agent runs (truncation currently happens once at run start; maxTurns is 18).
- Harden `_OpenXmlPackage.load` (streaming zip decode, pre-decode size check) and unify `UnsupportedError` → `ToolCallResult.failure` mapping.
- P3 — image multimodality (build on `attachedFileUris`), safe-edit tool (`write`/`edit_file` with diff preview + undo), local retrieval (embeddings/FTS).
- Evaluate SAF as an alternative to `MANAGE_EXTERNAL_STORAGE` for Play distribution.
