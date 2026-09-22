# Errand (Flutter) — Architecture Overview

This document maps the current implementation: a streaming chat UI, an OpenAI-compatible agent loop with reasoning, file reading (+ media) + on-device bash shell + web + Android intent + embedded browser + memory + autonomous task scheduler + accessibility tools, structured document readers, Drift persistence (v7, memories, scheduled tasks), ToolOutputFileService output caching, Full vs. Lite build flavors with split ABIs, and Android shared-storage access. Everything except the LLM and Tavily runs on-device.

## Big picture

The app keeps the conversation (and its persistence) on the phone and sends the history to the configured LLM. The LLM can call registered tools; tool results are fed back into the same loop until the model returns a final answer or 72 turns are reached. Streaming deltas and reasoning are forwarded to the UI live. History is budgeted in tokens against the selected model's native context window (`ContextBudget`), with automatic LLM-driven compaction when it overflows. Large tool outputs (>6,000 characters) are automatically cached to disk by `ToolOutputFileService` with head/tail previews.

```text
chat UI (lib/screens/chat_screen.dart)
     │  owns Conversation, _messages, _pendingAttachments (staging),
     │  _working state, WorkingDirectory, sidebar/composer/model picker
     │  + Drift watch streams (summaries + pinned)
     ▼
agent loop (lib/agent/agent_loop.dart) ──────────┐
     │  _toLlmHistory() + systemPromptBuilder      │
     │  UserMessage.attachedUris → text list      │  media via synthetic user message
     │  ToolCallResult.contentParts → user role   │
     │  up to 72 turns, pre/mid-step _compactIfNeeded, onTextDelta/onReasoning │
     ▼                                             │
LLM client (lib/llm/llm_client.dart)  ◀── HTTP/SSE ─┤ OpenRouter / HF / custom
     ▲  POST /chat/completions (stream:true)      │  baseUrl (AppSettingsService)
     │  tool schemas / tool_calls / reasoning      │  content: string | [text,image_url,input_audio,video_url]
     ▼                                             │
tool registry (lib/agent/tool_registry.dart)
     │  defaults: read (+media), bash, websearch, webfetch,
     │            intent, attached_files, memory, browser, schedule_task, plus screen + screen_act (Full flavor only)
     ├──────────┬──────────────┬─────────────┬─────────────┬─────────────┐
     ▼          ▼              ▼             ▼             ▼             ▼
 file tools   shell (bash)   web tools    intent tool   memory tool   browser tool
 (read+media) (/system/bin/  (websearch/  (6 actions:   (save/recall/ (DOM JS bridge,
              sh, Toybox)    webfetch)    open, docs)   update/list)   a11y snapshots)
     │           │             │             │             │             │
     └────┬──────┘             │             ▼             ▼             ▼
          ▼                    ▼       IntentService  ErrandDatabase BrowserService
   WorkingDirectory ──▶ dart:io     (channel "intent") (memories)  (InAppWebView)
   (root+current)      File/Dir      MainActivity.kt       │             │
          │                  │       (launch / BAL safe)   ▼             ▼
          ▼                  │                     SQLite (Drift v7) BrowserWidget
   document readers          │                     tasks/memories    (dock/preview/
     PDF · DOCX/XLSX/PPTX    │                                        full-screen)
     → LogicalDocument       │
       (paged, char-budgeted)│
                             │
     ToolOutputFileService ◀─┴── Cache outputs > 6k chars (<cacheDir>/tool_outputs/)

a11y (P2) ──▶ ErrandAccessibilityService (channel "a11y", Full flavor only)
             screen (read outline, globals) + screen_act (tap/type/scroll, Draft policy)

persistence (lib/services/database.dart)
  ErrandDatabase (drift, v7) — Conversations / ConversationMessages (+attachedUrisJson) /
                              ConversationAttachments / Memories / SchedulerTasks / SchedulerTaskLogs / AppSettings
  saveConversation (transaction, merge) · watchConversationSummaries · watchPinnedConversations

model catalog (lib/services/model_catalog.dart → lib/models/model_option.dart)
  GET /models (≈ OpenRouter /models?output_modalities=text) → parses
  architecture.input_modalities → ModelOption.supportsInput
  ModelPicker dialog (searchable, marquee)
```

## Conversation and messages

`lib/types/conversation.dart` is the runtime session container. It carries:

- the optional system prompt (`localSystemPrompt` — built per turn from `WorkingDirectory.current` + screen state + attached-file inventory);
- the complete `List<Message>` history;
- the current `Directory` snapshot;
- `attachedFileUris` — global inventory for the conversation (persisted via `ConversationAttachments`, shown in Settings → Local tab);
- `title`, `provider`/`model`, `isPinned`, `createdAt`/`updatedAt`.

`lib/types/message.dart` models the UI and history with typed messages:

- `UserMessage { text, attachedUris }` — user input; `attachedUris` is the ordered list of file URIs bound to this turn (persisted per-message, rendered as a card under the bubble);
- `AssistantMessage` — model responses (including streaming working bubble);
- `ToolMessage` — tool name, args (`ToolInvocation`), call ID, display preview (`text`), full `result`, plus `reasoning`/`reasoningDetails`;
- `CompactedNoticeMessage { text, summary }` — system divider marking an LLM-compaction point; `_toLlmHistory` starts from the latest one (older turns were summarized) and re-emits its summary as the `[COMPACTED …]` briefing;
- `ErrorMessage` — legacy typed error turn (transport errors are no longer inserted as messages; they surface as SnackBars via `_failWorking`).

ChatScreen keeps `List<String> _pendingAttachments` (`lib/main.dart`) as the **staged** state between `+` → `Attach file` and `Send`. On send it is snapshotted into `UserMessage.attachedUris` and also appended to the conversation's global `attachedFileUris` (deduped), then cleared. The pre-send pending card (`_buildPendingAttachments`) and the post-send message card (`lib/widgets/message_bubbles.dart: MessageBubble`) both render in order.

`lib/types/tool.dart` defines the runtime result: `ToolCallResult { id, ok, output, error?, contentParts? }` with `toText()` helper and `ToolCallError { type, message, retryable }`. `contentParts` carries OpenAI-compatible media parts (`image_url` / `input_audio` / `video_url`) for `read`'s media branch — delivered as a synthetic `user` message after the tool batch (tool-role media isn't portable across providers).

## The agent — `lib/agent/`

- **`tool.dart`** defines the LLM-facing `Tool` schema (`name`, `description`, `parameters`, `handler`) and parsed `ToolCall` (`id`, `name`, `arguments`). `ToolCall.toJson()` serializes arguments as a JSON string as required by OpenAI-compatible APIs. `requiresValidation` is internal metadata for future mutation tools; `onDispose`/`dispose()` releases tool-held resources (e.g. cached open documents).
- **`tool_registry.dart`** registers the current tools and safely executes a call, converting handler exceptions into `ToolCallResult.failure`. `ToolRegistry.defaults({currentDir, workingDirectory, supportsInput, getAttachedFiles, hasTavilyKey, enableA11yTools = true, shellService, getCancelToken})` contains `read` + `bash` + `websearch` + `webfetch` + `intent` + `attached_files`, and conditionally includes `screen` + `act` when `enableA11yTools` is true (Full flavor). In the Lite flavor, `ErrandAccessibilityService` is removed from `AndroidManifest.xml` and `A11yService.isSupportedSync` evaluates to false, omitting accessibility tools dynamically without branching code. `bash` executes on-device shell commands and synchronizes `workingDirectory.current` (superseding the retired `workspaceTool`). `supportsInput` (from `ModelCatalogService.supportsInput`) lets `read` fail honestly when the current model lacks `image`/`audio`/`video` support; `getAttachedFiles` lets `read` resolve file-picker cache paths outside the workspace and lets `attached_files` list the conversation inventory. `getCancelToken` wires the active turn's stop button into child process cancellation. `dispose()` fans out to every tool.
- **`agent_loop.dart`** exposes `run(Conversation)`. It builds the LLM message array (`system` + `_toLlmHistory`), injects the live system prompt each turn, and drives streaming (`chatStream`) or non-streaming (`chat`) via `LlmClient`.
  - `UserMessage.attachedUris` is rendered in `_toLlmHistory` as `text + "\n\n[Attached files:\n1. basename — uri]"` (no extra tool call needed for discovery).
  - An `AssistantMessage` immediately followed by `ToolMessage`s is merged into the synthesized assistant `tool_calls` message (carrying its text + first reasoning block); standalone consecutive `ToolMessage`s are reconstructed the same way. Either shape avoids back-to-back `assistant` roles, which strict providers reject.
  - Media `contentParts` from `read` are flushed as a synthetic `user` role message (`[Media file(s) you just read …]`) after the tool batch — preserves provider compatibility.
  - Loop cap is `defaultMaxTurns = 72` (ctor-overridable `maxTurnCount`); live turns carry reasoning via `toJson(includeReasoning: true)`.
  - Tool batches run **concurrently** (`Future.wait`) when stateless, sequentially when any call is stateful (`act`, `workspace cd`, `screen global`) — shared `WorkingDirectory`/screen state would race otherwise.
  - `_compactIfNeeded` runs **before the first turn and after every tool batch**: when `estimateLlmMessagesTokens` exceeds the model's `ContextBudget.compactionThreshold`, old blocks are LLM-summarized (deterministic fallback on failure/timeout) into a `[COMPACTED …]` user message + ack, keeping only the newest 1–2 tail blocks. The summarizer call is capped by `compactionTimeout` (60s default, ctor-overridable) so a saturated endpoint falls back instead of wedging the turn. A 1-block tail that still exceeds small-window targets is shrunk via `fitTailToTarget` (oldest tool contents head-trimmed to a 1K floor, newest spared till last, structure intact — never block drops). Stop during compaction rethrows with no divider written (nothing compacted); the UI placeholder flag is reset by the normal fail/stop paths. Emits `AgentCompacting`/`AgentCompacted` (UI divider + merge-save).
- **`context_budget.dart`** — token-based dynamic budget (replaced the 256K/200K/110K char constants, Sep 2026; char helpers kept as a compat layer). `ContextBudget{contextSize, reservedTokens: min(16K, 25% ctx)}` → `compactionThreshold = contextSize − reserved`, `targetTokens = 50%`. `contextSize` resolves per model: `ModelOption.contextLength` (catalog `context_length` → `ModelsDevService` fallback → 128K default). Estimation is `~3.8 chars/token` with flat vision/audio/video tile rates; media `List` parts are summed directly (no multi-MB `jsonEncode`). Builders: `buildCompactionPrompt` (structured Goal/Actions/Next-steps briefing), `buildDeterministicFallbackSummary` (first goal + files + recent tools + errors), `applyCompactedHistory` (system + compacted header + ack + tail). Legacy `truncateHistory`/`trimLlmMessages` (char-based, atomic tool-batch units, synthetic-media-aware mandatory tail) remain for the debug footer and tests.

## The LLM client — `lib/llm/llm_client.dart`

`LlmClient` is a small `package:http` client for `/chat/completions` with two paths:

- `chat()` — single JSON response, parses `choices[0].message.tool_calls` + `reasoning`/`reasoning_details`;
- `chatStream()` — SSE (`Accept: text/event-stream`, `stream:true`), forwards `content` deltas via `onTextDelta`, reasoning deltas via `onReasoningDelta`, and accumulates fragmented `tool_calls[].function.arguments` until `[DONE]`. Mid-stream transport failures retry (fresh POST per attempt): `onReset` clears the partial UI buffer once the next attempt establishes a stream, and `onRetry(attempt, reason)` fires before each redial so the UI can show a retry indicator.

`LlmMessage { content, toolCalls, reasoning, reasoningDetails }` is the parsed response. `_sseDataEvents` handles UTF-8 chunk reassembly and comment keepalives. API key + baseUrl + model come from `LlmConfig`, built at runtime from `AppSettingsService` (SQLite-backed settings).

**Resilience (added after free-model flakiness):**

- `_postWithRetry` / `_sendStreamWithRetry` — up to 3 attempts with exponential backoff (0.8s → 1.6s), honoring `Retry-After` on 429. Retries cover `SocketException`/`http.ClientException` (stale keep-alive sockets, mobile network switches — the classic "Software caused connection abort"), timeouts, and HTTP 429/5xx.
- Streaming requests are built via a **builder closure** (`http.Request` is single-use; re-sending a finalized request throws "Bad state: Can't finalize a finalized Request").
- Retry covers only time-to-response-headers for streams; mid-stream failures surface as `LlmException(transport: true)` ("Stream interrupted") and cannot be transparently resumed.
- `LlmException.transport` marks infra-side failures (connection lost, timeouts, 429/5xx) vs agent/tool mistakes — consumed by the UI error policy (below).

Keys are configured in-app (header gear icon → Settings sheet, Global tab) and stored AES-GCM encrypted in the app-settings table.

## The file, shell & workspace tools — lib/tools/

- **`read` (`file_tools.dart:readTool`)** — three branches:
  1. **Media** (`kMediaFormats`, `kMaxMediaBytes = 20 MiB`): `jpg/jpeg/png/webp/gif` → `image_url` data URL, `wav/mp3` → `input_audio {data, format}`, `mp4/webm/mov` → `video_url` data URL. Whole-file read, base64-encoded into `ToolCallResult.contentParts`; `output` stays a short summary (persisted/displayed). Capability-gated via `supportsInput(modality)` — `unsupported_modality` failure tells the model to switch models. 20 MiB pre-check is exact (`File.lengthSync`).
  2. **Structured** (`PDF/DOCX/XLSX/PPTX`): delegates to `readStructuredDocument` → `LogicalDocument.read(offset, length)` where `offset` is a logical unit index and `length` is a character budget (clamped to 256 KB). Path traversal is guarded via `path.relative` against `workspace.root`. Structured reads are memoized per-file in a registry-scoped map.
  3. **Text**: byte `offset`/`length` (default 512, max 512 KB) via `RandomAccessFile`.

  Optional `grep` argument (case-insensitive regex/substring): filters text/structured output to matching lines with file-relative 1-based line numbers; unpaginated length expands to 512 KB; structured grep filters body only (header reserved). Path resolution: `WorkingDirectory { root, current }` is the shared mutable cursor (mutated by `cd` or `bash`). `_resolveWorkspaceFile` enforces `path.relative` against `workspace.root`; `_resolveReadableFile` allows an explicit escape for cached tool output files (`<cacheDir>/tool_outputs/...`), **file_picker cache copies** (`/data/.../cache/file_picker/...`), and any URI in `attachedFileUris` (user-picked, so trusted) even though it lives outside `/storage/emulated/0`.

- **`bash` (`bash_tool.dart` + `services/shell_service.dart`)** — primary on-device command execution and filesystem navigation engine. Runs commands via `/system/bin/sh` using `Process.start` in `dart:io` under the application UID.
  - Interacts with Android's Toybox/Toolbox toolchain (`ls`, `cat`, `grep`, `find`, `sed`, `awk`, `cut`, `sort`, `uniq`, `wc`, `tr`, `head`, `tail`, `mkdir`, `cp`, `mv`, `rm`, `tar`, `gzip`, `df`, `du`, `ps`).
  - Directory sync: Automatically synchronizes `workingDirectory.current` on `cd` commands or `working_directory` arguments so subsequent tool calls (and system prompt builds) see the updated directory.
  - Execution safeguards: 30s default timeout per command, live cancellation abort wired to the chat UI stop button, and 512 KB stdout/stderr memory buffer guards.
  - Draft safety policy: Strictly blocks fork bombs, `su`/root escalation, and device reboots; requires explicit user confirmation flag `confirm_destructive: true` for bulk deletions and `rm -rf`.
  - Output spill: Results exceeding 6,000 characters automatically cache to disk via `ToolOutputFileService`.

- **`workspace` (`legacy_workspace_tool.dart:legacyWorkspaceTool`) [RETIRED / LEGACY]** — former directory router multiplexing `legacyListTool`/`legacyFindTool`/`legacyCdTool` (+ `pwd`). Retired from default `ToolRegistry.defaults` in favor of `bash`. Kept in the codebase with `legacy_` prefixes for backwards compatibility with persisted conversation history and unit test suites.
  - `list` / `legacyListTool` — non-recursive, optional `pattern` RegExp filter.
  - `find` / `legacyFindTool` — recursive glob (`*`/`?`, case-insensitive) with `type: file|dir`, `max_depth` (default 3, max 32), cap 500 results.
  - `cd` / `legacyCdTool` — mutates `workspace.current`.

- **`attached_files` (`attached_files_tool.dart`)** — zero-param lister: `attached_files` → `No files attached…` or `Attached files: N\n1. basename — uri`. Reads from `getAttachedFiles` (the conversation's global inventory). Lets the model discover non-pending history without guessing.

- **`grep_filter.dart`** — shared utility: `compile()` enforces pattern cap (200 chars) and a nested-quantifier ReDoS guard (falls back to escaped literal); `filter()` supports `header` (preserved), `withLineNumbers`, and `startLine` (for windowed reads); match cap 200 with overflow note.

## Structured document readers — `lib/internal/document_reading/`

- **`document_reader.dart`** — router by extension (`pdf`, `docx`/`docm`, `xlsx`/`xlsm`, `pptx`/`pptm`); legacy `doc/xls/ppt` and non-media images throw `UnsupportedError`. `readStructuredDocument` loads once; `readStructuredFile` paginates.
- **`document_models.dart`** — `LogicalDocument { format, units }` + `LogicalDocumentUnit { label, text }` + `LogicalRead { start, end, total, hasMore, nextOffset, output }`. Budget respects character count, with one-unit overlap when `end-offset > 1` for continuity. `toToolOutput` formats the tool response.
- **`open_xml_reader.dart`** — `_OpenXmlPackage` (zip via `archive`, XML via `xml`) with guards `_maxPackageBytes` (64 MB), `_maxPackageEntries` (2000), `_maxXmlPartBytes` (16 MB). Parsers: `_wordParagraphText`/`_wordTableRows` for DOCX, `_readSharedStrings`/`_cellValue` for XLSX (chunked into 1800-char row groups), slide `p` extraction for PPTX.
- **`pdf_reader.dart`** — `ReadPdfText.getPDFtextPaginated` → one `LogicalDocumentUnit` per page.

## Web tools — `lib/tools/web_tools.dart` + `lib/services/tavily_client.dart`

- `TavilyClient { search, extract, _post }` — `POST https://api.tavily.com/{search,extract}`, Bearer token from `AppSettingsService.tavilyKey`, JSON decode with status-range check. The web tools resolve the client **lazily per call** (not at registry construction), so saving a key in Settings takes effect immediately; an unset key is a clean `ToolCallResult.failure` pointing at Settings.
- `websearch` — `query → search` → titles/URLs/snippets (truncated to 1200 chars each).
- `webfetch` — `url (+ optional query) → extract` (Markdown, stored up to 100k chars, then spilled to a cache file with preview) from a single URL, focused when query is present.

## The intent tool — `lib/tools/intent_tool.dart` + `lib/services/intent_service.dart`

One LLM tool (`intent`) covering Android app/web/system actions. Layered design: **curated actions → generic `android_action` escape hatch → honest failure**. No per-app pattern matching anywhere.

**Core actions** (schema enum, unified Sep 2026 — was 17 curated): `open_file`, `open_url`, `open_app`, `settings` (+`page`), `intent`. URI-style legacy actions (`search`/`dial`/`open_maps`/`email`) still synthesize an `open_url` for old conversations. Custom Android actions, including alarms, timers, calendar insertion, sharing, wallpaper, uninstall, and settings panels, must use `action:"intent"` with the exact `android_action`, data URI, MIME type, package, and typed extras required by the target app. No domain-specific fields are synthesized.

- `_genericIntent` passes the normalized Android intent request through unchanged after validating the target and supported extra types. It does not guess aliases or manufacture app-specific extras. `_parseExtras` skips `null` values cleanly so optional schema arguments never cause null-pointer crashes.
- **URL safety** (`_openUrl`): auto-prefixes `https://` only for domain-like hosts (`_looksLikeWebHost`); blocks `javascript:`/`file:`; anything else fails with guidance pointing at `android_action`/`settings`. This prevents the model from "opening" settings names as web URLs. `open_file` takes an absolute device path and is served via `FileProvider` (see native side).
- **Generic escape hatch**: `action:"intent"` accepts a raw `android_action` string (e.g. `android.settings.DISPLAY_SETTINGS`, third-party `com.someapp.action.SYNC`) — new apps/actions need zero code changes.
- **UI reopen** (`isReopenable` + `replayIntentAction`): successful open-style intents (`open_file`/`open_url`/`open_app`/`settings` + legacy open-style actions) render an Open button on the tool bubble that re-fires the persisted args through the same handler. Side-effect/raw actions stay button-less unless view-style (`VIEW`/`MAIN`/`DIAL`/`SENDTO`/media-search or `android.settings.*`). Derived entirely from already-persisted data — no schema change, works for old conversations.
- All handlers are `async` and `await` the channel, so native errors (`NO_HANDLER`, `NO_PKG`, `FILE_NOT_FOUND`, `PENDING_INTENT_CANCELED`, `INTENT_SECURITY`, `INVALID_INTENT`, `INTENT_ERR`) become `ToolCallResult.failure` instead of fake success.

**Native side** (`MainActivity.kt`, channel `"intent"`):

- `launch` — builds the intent per action (`getLaunchIntentForPackage`; `open_file`/absolute paths via `FileProvider.getUriForFile` + `ClipData` grant + extension→MIME resolution with `FILE_NOT_FOUND` honest failure; `ACTION_SENDTO mailto:` with `EXTRA_SUBJECT/TEXT` + query-param fallback; `tel:`/`mailto:` scheme-sniffed to `DIAL`/`SENDTO`; explicit `androidAction` otherwise), preserves typed extras, adds `FLAG_ACTIVITY_NEW_TASK` (no `CLEAR_TOP`, so background apps survive), and adds `CATEGORY_BROWSABLE` for http(s).
- **Typed extras mapping** (`putExtraValue`): Maps Dart primitives and lists directly to Android typed extras: `Boolean`, `Byte`, `Short`, `Int`, `Long`, `Float`, `Double`, `String`, `CharSequence`, and string array lists (`ArrayList<String>`). Unsupported extra types throw `IllegalArgumentException` caught as `INVALID_INTENT`.
- **Debug intent logging** (`logIntent`): Gated by `ApplicationInfo.FLAG_DEBUGGABLE`; logs the final action, data URI, MIME type, package, component, categories, flags, and fully-typed extras map at the native boundary immediately prior to dispatch. Completely silent with zero overhead in release builds.
- **BAL safety**: Launched via `PendingIntent.getActivity` with `FLAG_IMMUTABLE or FLAG_UPDATE_CURRENT` and `ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED` on Android 14+ (falling back to `ErrandAccessibilityService` context) so background activity launches are never blocked by the OS.
- `resolveActivity` pre-check runs only when a package is explicitly pinned — implicit intents rely on `ActivityNotFoundException` (avoids `<queries>` visibility false-negatives on API 30+). Native failures use distinct `NO_HANDLER`, `PENDING_INTENT_CANCELED`, `INTENT_SECURITY`, and `INVALID_INTENT` errors. A successful dispatch does not verify target-side state changes.
- `canResolve` — passes the raw action through (plus `tel:`/`mailto:` sniffing) with optional `type` for `setDataAndType` checks.
- `bringToFront` — `REORDER_TO_FRONT + SINGLE_TOP` (same BAL-safe path) restores Errand after `screen`/`act` work in other apps; fired from `_replaceWorking`/`_failWorking` when `_externalAppWorkDone`.
- Manifest `<queries>` covers http(s)/`VIEW */*` file viewing, geo, `tel`/`DIAL`, `mailto`/`SENDTO`, spotify/whatsapp/tg deeplinks, calendar `INSERT`/share `SEND`, and pinned packages (spotify/maps/chrome). Includes the `FileProvider` declaration (`file_paths.xml`). System permissions for common intents (`SET_ALARM`, `SCHEDULE_EXACT_ALARM`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `WAKE_LOCK`, `VIBRATE`) are declared in the base manifest.

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

- `ModelCatalogService { load(baseUrl, apiKey) }` — `GET {baseUrl}/models`, parses `data[].id/name` + `architecture.input_modalities` (e.g. `["text","image","audio","file"]`, default `["text"]` when absent) + `context_length` (else `ModelsDevService` offline lookup, else null). Static `_cache` + `_inFlight` dedup; `supportsInput(modelId, modality, {baseUrl})` hits a single normalized catalog in O(n) when `baseUrl` is given (`true`/`false`/`null` = unknown endpoint). Deprecated entries (`status`/`deprecated` flags + known-dead ids) are filtered. Fallback is `kFallbackModels` + `kDefaultModelId`; the last user-picked model persists in the settings table. Provider mapped from `id` prefix (`qwen/… → Qwen`).
- `ModelOption { id, name, provider, inputModalities, hasExplicitModalities, contextLength? }` → consumed by `ModelPicker` (searchable dialog, header + list rows use marquee ` _ScrollingModelName` for long names) and by `AgentLoop` budget resolution (`getContextLength` → per-model `ContextBudget`).
- `ModelsDevService` — `models.dev` dynamic metadata service resolving native context-window tokens and input modalities (`modalities.input` e.g. text, image, audio, video) per model id when the provider catalog omits explicit specifications.
- `UpdateService` + `AppInfoService` — lightweight background OTA update system checking GitHub Releases (`GET /repos/Abhiram86/errand/releases/latest`) on a 2-hour cadence. Resolves matching flavor (`full` vs `lite`) and device ABI (`arm64-v8a`, `armeabi-v7a`, `x86_64`), streams APK to atomic `.tmp` files with size integrity verification, caches with a 2-day TTL in SQLite (`pref.app_update_info`), and surfaces a floating `UpdateToast` centered under the model picker for one-tap package installation.

## The UI — `lib/main.dart` + `lib/widgets/` + `lib/theme/`

`ChatScreen` (with `WidgetsBindingObserver`) owns:

- `ErrandDatabase.instance` + two watch subscriptions (`watchConversationSummaries`, `watchPinnedConversations`);
- `_messages`, `_activeConversation`, `_pendingAttachments` (staged), `_workingDirectory`, `_modelCatalog`, `_llm`, `_selectedModel`/`_models`, `_controller`/`_scroll`;
- streaming bookkeeping: `_workingMessageId`, `_workingText` (StringBuffer), `_workingFlushTimer` (40 ms), `_persistTimer` (600 ms), `_scrollPending`, `_pendingAttachments`.

Flow:

- **Attachments**: `+` → `Attach file` sheet (`file_picker`, `allowMultiple: true`, `file_picker: ^10.1.2`) → `List<String> _pendingAttachments` (in-memory staging, deduped against history). `_buildPendingAttachments` renders a `kInputBg` card above the composer (`Attached — will send with next message`, ordered `1. basename` rows, `×` → `_detachPending`). On `_send()`, the pending list plus any `editBase` (preserved from edited `UserMessage.attachedUris` or legacy suffix) is snapshotted into `UserMessage(attachedUris: snapshot)` and appended to the conversation's global `attachedFileUris` (for `Local` tab/history), then staging is cleared. Edited messages strip/recover the legacy `[Attached files:]` suffix via `_stripAttachedBlock`/`_extractAttachedUris`.
- **Settings sheet** (`lib/widgets/settings_sheet.dart`): `DefaultTabController(length:2)` → `Global` (OpenRouter/Tavily keys + base URL, AES-GCM) vs `Local` (attached files for current conversation — history + pending, deduped, with `+ Attach` and per-row remove). `TabBar.dividerColor: transparent`.
- `_send()` appends `UserMessage` (with `attachedUris`) + `AssistantMessage("…working")`, builds a `Conversation` snapshot (without the working bubble), and runs `AgentLoop` with `ToolRegistry.defaults(..., supportsInput, getAttachedFiles)` + `systemPromptBuilder` (includes `WorkingDirectory.current`, screen state, and `attachedFileUris` inventory) + `onEvent`/`onTextDelta`/`onReasoningDelta`. Tool events become `ToolMessage`s via `_appendToolMessage` (finalizes prior streamed text, inserts tool, creates fresh working bubble). Deltas flush via `_flushWorkingText` → `SelectableText`. Final answer replaces the working bubble via `_replaceWorking`.
- **Error policy**: exceptions from the loop (`LlmException`, transport or otherwise) go to `_failWorking` — the working bubble is removed and a SnackBar shows the message. Infra errors are never added to `_messages`, never persisted, never sent in history.
- `_persistConversation()` saves the active conversation (excluding the in-flight working bubble) to Drift; `_schedulePersist` debounces, `_persistNow` flushes. `_sortedConversations` sorts by `updatedAt` desc for the sidebar.
- Sidebar (`ChatSidebar`) shows pinned favourites + recent (watch-driven, sorted), with rename/pin/delete options, slide-in animation and scrim. `ChatComposer` has add/context actions + send (gated by `canSend`); drafts survive an accidental edit-tap (composer text is never overwritten while non-empty). `MessageBubbles` renders user bubbles as `SelectableText` plus an **attachment card** (`kInputBg`, `kBorder`, ordered `1. basename` rows) when `UserMessage.attachedUris` non-empty, assistant bubbles as `GptMarkdown` (tables/code/LaTeX; list-wide `SelectionArea` provides copy), `ToolMessageBubble` `ExpansionTile`s with friendly summary headers (e.g. `run command`, `open file`, `open app`, `dispatch intent`) that switch to raw arguments when expanded or in debug mode, tap-to-collapse anywhere on the tool output via `ExpansibleController` (avoids scrolling back up on long/streaming outputs), a context-aware copy button (copies full tool call & args in debug mode, or raw output in release mode), an Open button on successful open-style intent calls that replays the persisted args via `replayIntentAction`, and `CompactedDividerBubble` system dividers marking compaction points (`CompactedNoticeMessage`, persisted as `compacted` rows). Streaming uses height-eased + fade-in animation; the debug footer shows token-based budget state. Empty assistant turns are suppressed in rendering (and dropped from persistence going forward). `ModelPicker` rows use marquee for long names (no `ellipsis` truncation). Theme is `AppColors` + dark `ColorScheme` + `ThemeData(useMaterial3:true)`.

Storage permission is checked on start and on `AppLifecycleState.resumed`, with a one-at-a-time dialog prompt.

## Persistence — `lib/services/database.dart`

Drift database `ErrandDatabase` (5 tables, schema v5):

- `Conversations { id PK, localSystemPrompt?, title, currentDir, provider?, model?, isPinned, createdAt, updatedAt }`
- `ConversationMessages { localId autoinc PK, conversationId FK→Conversations.id, messageId, sortOrder, messageType (user/assistant/tool/error/compacted), messageText, toolName?, toolArgumentsJson?, result?, reasoning?, reasoningDetailsJson?, error?, attachedUrisJson? }` — `attachedUrisJson` (v4) stores `UserMessage.attachedUris` as JSON array; `compacted` rows store the `CompactedNoticeMessage` summary in `result`.
- `ConversationAttachments { conversationId FK, uri, PK(conversationId, uri) }` — global inventory per conversation (from Settings → Local + message history).
- `Memories { id PK (UUID), key? unique, content, tagsJson, createdAt, updatedAt }` — persistent cross-conversation knowledge, facts, and user preferences (v5).
- `AppSettings { key PK, value }` — generic runtime KV store: encrypted API secrets (OpenRouter/Tavily keys, base-URL override) + plain preferences (voice locale, last-selected model, a11y prompt flag). Encryption lives in `SecretStore` (AES-256-GCM, key file at `<app-support>/errand.key`, outside the DB); `AppSettingsService` is the typed access layer with an in-memory cache. Replaces the former shared_preferences usage.

Key ops:

- `saveConversation(Conversation)` — `transaction`: `insertOnConflictUpdate` conversation row, then merge messages by `messageId` (new rows appended after max `sortOrder`, known rows updated in place — window-safe), attachments rewritten. Backed by a UNIQUE index on `(conversation_id, message_id)` and a `(conversation_id, sort_order)` lookup index (schema v2). Message companion now includes `attachedUrisJson` for `UserMessage`.
- `replaceAllMessages(conversationId, messages)` — full delete + sequential reinsert (`sortOrder` 0..n). Currently uncalled (compaction merge-saves its divider and retains pre-divider rows as a never-re-sent audit trail); carries a window-safety contract — argument must be the COMPLETE history, never a loaded subset.
- `deleteConversation`, `pinConversation` (toggle), `touchConversation` (bump `updatedAt`).
- `loadConversation(id)` / `_loadMessages` / `_loadAttachmentUris`, plus `insertMessage`/`replaceMessage`/`deleteMessage`.
- `watchConversationSummaries()` / `watchPinnedConversations()` — ordered streams for the sidebar.
- Memory ops (`saveMemory`, `getMemoryByKey`, `recallMemories`, `updateMemory`, `deleteMemory`, `listMemories`, `watchAllMemories`).
- `getSetting(key)` / `setSetting(key, value)` / `deleteSetting(key)` — raw KV upserts/removals consumed by `AppSettingsService`.

`schemaVersion = 5`, `NativeDatabase` (or `drift_flutter` on device), `inMemory()` for tests. v1→v2 migration dedupes message rows, then creates the two indexes above; v2→v3 adds the app-settings table; v3→v4 adds `attachedUrisJson`; v4→v5 adds the `memories` table.

## The memory subsystem — `lib/services/memory_service.dart` & `lib/tools/memory_tool.dart` (P5b)

- **`MemoryService`** — provides typed persistence operations over the Drift `memories` table:
  - `save(content, {key, tags})` — saves or updates a memory with unique key collision resolution and JSON tags.
  - `recall(query, {tags, limit})` — case-insensitive substring search matching across content, keys, and tags.
  - `update(id/key, content, {tags})` — updates content or categorization.
  - `delete(id/key)` — purges specific memories.
  - `list({limit, offset, tags})` — browses recent memories.
- **`memory` tool** (`lib/tools/memory_tool.dart`) — LLM tool exposing `save`, `recall`, `update`, `delete`, and `list` actions.
- **Passive knowledge digest**: `SystemPromptService` automatically injects a compact, token-budgeted list of active user preferences and facts into the prompt on every turn without requiring explicit tool roundtrips.
- **Memory management UI**: dedicated view in the Settings sheet allowing users to view, search, manually create, edit, or purge memories.

## The embedded browser — `lib/services/browser_service.dart` & `lib/widgets/browser_widget.dart` (P6a)

- **`BrowserService`** — singleton service managing the embedded browser lifecycle:
  - Backed by `flutter_inappwebview` with `InAppWebViewController`.
  - Maintains navigation state (`currentUrl`, `currentTitle`, `isLoading`, `progress`).
  - Controls display modes via `ValueNotifier<BrowserDisplayMode>` (`closed`, `preview`, `fullScreen`).
  - **Adaptive preview zoom**: sets zoom scale to `0.80` in preview mode to widen visible page content, restoring to `1.0` in full-screen mode.
  - Exposes programmatic control: `openUrl(url)`, `goBack()`, `goForward()`, `reload()`, `stopLoading()`, `close()`.
  - DOM JS execution via `evaluateJavascript` and visual screenshot fallback via `takeScreenshot`.
  - Accessibility tree snapshot extraction: parses DOM elements (`a`, `button`, `input`, `select`, `textarea`, interactive roles) into a compact numbered tree with `[e1]`, `[e2]` references.
- **`browser` tool** (`lib/tools/browser_tool.dart`) — unified agent tool with actions:
  - `open`: loads target URL, validates HTTP/HTTPS schemes, auto-opens the preview card.
  - `snapshot`: extracts the interactive DOM accessibility outline.
  - `act`: interacts with page elements via click, type, select, or scroll using DOM events and JS dispatch.
  - `screenshot`: captures visible viewport for multimodal models.
  - `extract_text`: extracts cleaned text content from the current page.
  - `close`: closes the browser session and collapses the UI.
  - `back` / `forward` / `reload`: page history navigation.
- **`BrowserWidget`** — responsive multi-mode overlay:
  - Smooth morphing animations across compact dock bar (50px), preview card (floating above composer), and full-screen modal.
  - **Composer focus isolation**: Preview card compacts to the 50px dock bar only when the chat composer is actively focused, keeping the preview expanded while typing inside web page inputs.
  - Full-screen mode features floating glass address bar, reload/stop buttons, back/forward buttons, zoom restore, and minimize/close actions.

## Reading order

1. `lib/types/message.dart`, `lib/types/conversation.dart`, `lib/types/tool.dart`
2. `lib/agent/tool.dart` → `tool_registry.dart` → `agent_loop.dart` (+ `context_budget.dart`)
3. `lib/services/workspace.dart` + `lib/tools/file_tools.dart` (incl. media branch) + `lib/tools/bash_tool.dart` (active shell) + `lib/tools/memory_tool.dart` + `lib/tools/browser_tool.dart`
4. `lib/services/browser_service.dart` + `lib/widgets/browser_widget.dart`
5. `lib/internal/document_reading/` (models → reader → open_xml/pdf)
6. `lib/tools/web_tools.dart` + `lib/services/tavily_client.dart`
7. `lib/tools/intent_tool.dart` + `lib/services/intent_service.dart` + `MainActivity.kt` (intent channel)
8. `lib/tools/screen_tool.dart` + `lib/tools/act_tool.dart` (`screen_act`) + `lib/services/a11y_service.dart` + `ErrandAccessibilityService.kt` (a11y channel)
9. `lib/llm/llm_client.dart`
10. `lib/services/database.dart` + `lib/services/model_catalog.dart` + `lib/models/model_option.dart`
11. `lib/main.dart` + `lib/bootstrap.dart` + `lib/app.dart` + `lib/screens/chat_screen.dart` + `lib/widgets/`

## The accessibility tools — `screen` + `screen_act` (P2)

One user-enabled accessibility service (`ErrandAccessibilityService`, bound
via `BIND_ACCESSIBILITY_SERVICE`, config in `res/xml/`) backs two tools over
the `"a11y"` MethodChannel. Static-instance pattern: a null instance IS the
"not enabled" signal; Android 13+ "Restricted setting" for sideloads is
detected via AppOps and surfaced as enablement guidance.

- **`screen`** — read-only. Serializes the active window's node tree into a
  compact outline (`[ref] Class "label" [flags] @bounds`) with viewport
  partitioning and jitter reduction:
  - **Visible vs. Off-screen**: Elements are partitioned by the screen viewport.
    Visible elements are sorted visually (top-to-bottom, left-to-right) and emitted
    first with priority on the character budget. Off-screen elements (e.g. adjacent
    `ViewPager` tabs like WhatsApp Communities) are grouped under a distinct
    `--- Off-screen ---` section, eliminating outline interleaving.
  - **Upfront ref mapping**: The full `elementRefs` map is constructed across all
    interactive elements before serialization, so `act tap ref:n` refs remain valid
    regardless of outline character cuts.
  - **Interactive prioritization**: Character budget reserves space for visible
    actionable controls so bottom buttons aren't crowded out by walls of static text.
  - **Jitter reduction**: Unlabeled non-interactive structural containers (`FrameLayout`,
    `ViewGroup`, spacer `ImageView`) are omitted; redundant container child labels are
    deduplicated; consecutive duplicate static lines collapse to `(xN)`; TalkBack
    boilerplate (`"double tap to activate"`, `"tap to add new status"`) is stripped.
  - Truncation reports WHICH cap hit (`capHit: chars | nodes`) plus real counts.
  - `settle_ms` guards against stale reads after navigation.
  - Global actions: back / home / recents / notifications / quick_settings /
    lock_screen (API 28+).
- **`screen_act` (formerly `act`)** — gated injection, **Draft policy** (*agent prepares, user
  sends*): tap-by-label walks up to the nearest clickable ancestor;
  tap-by-ref addresses `[ref]` from the last read;
  type uses ACTION_SET_TEXT on the focused field (never submits; password
  fields refused); scroll prefers node actions with a gesture fallback.
  Commit-looking controls (send/pay/delete/confirm…) are refused Dart-side
  by word-boundary matching, reporting the matched pattern. No coordinate
  taps exist at all. With `then_read: true`, returns the updated screen
  outline automatically in the same turn.

## Large tool output file caching — `ToolOutputFileService`

`ToolOutputFileService` (`lib/services/tool_output_file_service.dart`) acts as
the universal context-protection layer for data-heavy tools:

- **Spill threshold (6,000 chars)**: Outputs $\le$ 6k characters are returned inline
  directly (no file overhead).
- **10-minute TTL file caching (default, configurable)**: When a tool produces $> 6,000$ characters, the
  entire unabridged output (up to a 512 KB store cap) is saved into `<cacheDir>/tool_outputs/tool-<callId>_<hash>-output.txt`
  (atomic tmp+rename write; truncated sanitized id + hash so retries/collisions are safe).
  Sweep is opportunistic — expired (> TTL) and over-cap (max 50 files) entries are deleted
  on the next large-output spill; there is no background timer.
- **Head/tail preview with header reservation**: Returns the leading metadata header block
  (up to the first blank line — `Screen:`, `File:`, `Source:`, etc., capped at 1.5k chars)
  plus the initial 2,000 chars and the final 2,000 chars, separated by a standard truncation
  banner containing the exact file path and instructions to use `read` (with `grep`, `offset`, and `length`)
  to inspect deeper. Already-spilled previews pass through the registry safety net untouched,
  so per-tool spills and the net can never overwrite each other.
- **Tool integration**: Integrated across `bash` (shell commands & directory listings), `read`, `webfetch` (extract stored up to 100k chars), `websearch`, `screen`, and `act then_read` (as well as legacy `workspace`), with a safety-net wrap in `ToolRegistry.execute`. `_resolveReadableFile` allows `read` to open and grep only files inside the spill directory (post-normalize containment check — no substring allowlist), plus user-attached URIs and `file_picker` cache copies.

## Multimodality — `read` + `attached_files` (P3)

- **`read` media branch** (`lib/tools/file_tools.dart`, `kMediaFormats`, `kMaxMediaBytes`) — image/audio/video whole-file read into `ToolCallResult.contentParts` as OpenAI-compatible `image_url` / `input_audio` / `video_url` data URLs. Capability-gated via `ModelCatalogService.supportsInput(modelId, modality)` (parsed from `architecture.input_modalities`). `file_picker: ^10.1.2` supplies the URIs.
- **`attached_files` tool** (`lib/tools/attached_files_tool.dart`) — lists the conversation's global inventory (`Conversation.attachedFileUris`) so the model can discover history without guessing.
- **Staging vs history**: `ChatScreen._pendingAttachments` (in-memory, shown as pre-send card) → on send snapshotted into `UserMessage.attachedUris` (`ConversationMessages.attachedUrisJson`, v4) + appended to `ConversationAttachments` (global). `_toLlmHistory` renders `UserMessage.attachedUris` as the `[Attached files: …]` text list; `estimateLlmMessageTokens` sums `List` part payloads directly (flat vision/audio/video tile rates when opaque) for the budget guard.

## Build flavors & release packaging

Errand is structured into two Gradle product flavors (`android/app/build.gradle.kts`):

- **Full (`com.errand.errand`)**:
  - Full feature set including OS automation.
  - Manifest includes `ErrandAccessibilityService` bound via `BIND_ACCESSIBILITY_SERVICE` to power the `screen` and `act` accessibility tools.
  - Declares system permissions for broad automation (`MANAGE_EXTERNAL_STORAGE`, `RECORD_AUDIO`, `SET_ALARM`, `SCHEDULE_EXACT_ALARM`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `WAKE_LOCK`, `VIBRATE`, `FOREGROUND_SERVICE_DATA_SYNC`, `POST_NOTIFICATIONS`, `SYSTEM_ALERT_WINDOW`).
- **Lite (`com.errand.errand.lite`)**:
  - Lean, privacy-focused build without accessibility service or sensitive automation permissions.
  - Manifest overlay (`android/app/src/lite/AndroidManifest.xml`) strips the service declaration via `<service android:name=".ErrandAccessibilityService" tools:node="remove" />`.
  - **Dynamic runtime detection**: Kotlin's `"isSupported"` method checks `packageManager.queryIntentServices(...)` for the accessibility service within Errand's package. When stripped in Lite, it returns `false`, causing Dart's `A11yService.isSupportedSync` to evaluate to false. `ToolRegistry.defaults(enableA11yTools: false)` then cleanly omits `screen` and `act` without needing Dart compile-time branches or flavor forks.
- **Split ABI Releases**:
  - Builds are published using split per ABI (`arm64-v8a`, `armeabi-v7a`, `x86_64`), producing 6 lean APKs (3 Full + 3 Lite) with architecture-specific native binaries.

## Next steps

- Stream-stall watchdog for `chatStream` (inactivity timeout per SSE event; `_streamTimeout` only covers time-to-headers).
- ✅ Done Sep 2026: per-model dynamic budget + pre/mid-step auto-compaction (was: entry-only truncation, `maxTurns` 18, full compaction TODO) — see `context_budget.dart: ContextBudget`.
- ✅ Done Sep 2026: Office/PDF streaming hardening (`_StreamingOpenXmlPackage` guards, lazy `PooledPdfDocument` pages, `structuredDocuments` LRU + stat invalidation).
- ✅ Done Sep 2026: Large tool output file-caching (`ToolOutputFileService` + 10-min TTL + 2k/2k preview + `read` tool cache resolution).
- ✅ Done Sep 2026: Accessibility outline viewport partitioning (visible vs off-screen separation, upfront ref mapping, interactive line prioritization, jitter compression).
- ✅ Done Sep 2026: On-device shell execution tool (`bashTool` + `ShellService`, `/system/bin/sh`, Toybox/Toolbox, timeouts, live cancellation, Draft confirmation policy for destructive mutations) fully superseding the legacy `workspace` tool.
- ✅ Done Sep 2026: Android custom intent normalization (core actions, typed extra preservation for primitives, string lists & integer lists, null-skipping, `logIntent` boundary debugging, BAL safety).
- ✅ Done Sep 2026: Tool UX refinements (`ToolMessageBubble` one-tap collapse via `ExpansibleController`, debug full tool-call copying, friendly action headers, and `ToolGroupBubble` sequential tool call grouping with animated morphing).
- ✅ Done Sep 2026: Intent on-demand documentation tool (`action: 'docs'`) with verified specifications for `alarm`, `calendar`, `timer`, and `location`/`maps`.
- ✅ Done Sep 2026: Architectural modularization decomposing `lib/main.dart` from 2,570 lines to 41 lines.
- ✅ Done Sep 2026: Full vs. Lite build flavors with dynamic accessibility service stripping and split-per-ABI release packaging.
- ✅ Done Sep 2026 (v0.6.1): In-app background OTA update system with flavor/ABI matching, atomic download verification, 2-day TTL cache, and post-update first launch release notes sheet (`UpdateService`).
- ✅ Done Sep 2026 (v0.6.1): Dynamic provider defaulting and model sorting by release date via `models.dev` catalog.
- ✅ Done Sep 2026 (v0.6.1): Unified `OptionsModalSheet` with 75% max height limit and scrollable content across sidebar and message bubble menus.
- ✅ Done Sep 2026 (v0.6.1): Animated multi-color sweep-gradient glowing border around `ChatComposer` while the assistant is processing turns.
- ✅ Done Sep 2026 (v0.6.2): Default working directory to `/storage/emulated/0/Documents/Errand/`, filesystem output hygiene in system prompt, and automatic `.scratch/` directory creation.
- ✅ Done Sep 2026 (v0.6.3): Interactive bash safety confirmation modal (`Accept` / `Deny` / `Trust`), mid-stream LLM retry with on-reset buffer cleanup and UI indicator, Google OAuth user-agent sanitization & multi-window popups, compact overflow-free browser toolbar, and live model auto-selection on provider configuration.
- ✅ Done Sep 2026 (v0.6.4): Hardened OTA update lifecycle (session-scoped dismissal, manual sidebar update check, post-install state reconciliation, download/install error toasts, and tag-verified release notes).
- ✅ Done Sep 2026 (v0.7.0): Autonomous background task scheduler (schema v7: scheduler_task & scheduler_task_log, exact Android AlarmManager scheduling, headless AgentRunner execution loop, direct .scratch/ output report collection, TaskToastService, and ManageTasksScreen with status filters, pagination, and file previews).
- Safe-edit tool (`write`/`edit_file` with diff preview + undo) — needs the write-policy decision originally blocking it.
- Local retrieval (embeddings/FTS) over recent docs for context budgeting.
- Evaluate SAF as an alternative to `MANAGE_EXTERNAL_STORAGE` for Play distribution.
- P4 — hardening release + guided refactor (see `next_plan.md` §P4 + `refactor.md` progress log).
