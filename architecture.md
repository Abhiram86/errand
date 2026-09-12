# Errand (Flutter) — Architecture Overview

This document maps the current implementation: a streaming chat UI, an OpenAI-compatible agent loop with reasoning, file + workspace + web + Android-intent + accessibility + **multimodal media** tools, structured document readers, Drift persistence (v4), and Android shared-storage access. Everything except the LLM and Tavily runs on-device.

## Big picture

The app keeps the conversation (and its persistence) on the phone and sends the history to the configured LLM. The LLM can call the registered file/web tools; tool results are fed back into the same loop until the model returns a final answer or 72 turns are reached. Streaming deltas and reasoning are forwarded to the UI live. History is budgeted in tokens against the selected model's native context window (`ContextBudget`), with automatic LLM-driven compaction when it overflows.

```text
chat UI (lib/main.dart: ChatScreen)
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
     │  defaults: read (+media), workspace, bash, websearch, webfetch,
     │            intent, attached_files, plus screen + act (Full flavor only)
     ├──────────┬──────────────┬─────────────┴─────────┐
     ▼          ▼              ▼                       ▼
 file tools   workspace    web tools              intent tool
 (read+media) tool         (websearch/webfetch    (open_url/search/email/
             (pwd/cd/list/ → Tavily)                alarm/timer/share/settings/
              find)                                  system toggles …)
     │           │             │                        │
     └────┬──────┘             │                        ▼
          ▼                    ▼                 IntentService
   WorkingDirectory ──▶ dart:io ──▶ /storage/emulated/0  (channel "intent")
   (root+current)      File/Dir   MANAGE_EXTERNAL_STORAGE   │
          │                  │       TavilyClient              ▼
          │                  │       (api.tavily.com)    MainActivity.kt
          ▼                  │                     second handler: launch (FileProvider
   document readers          │                     media, BAL-safe PendingIntent, chooser detect) /
     PDF · DOCX/XLSX/PPTX    │                     canResolve / bringToFront
     → LogicalDocument       │                     (dark-mode toggle + WRITE_SETTINGS flow removed;
       (paged, char-budgeted)│                      a11y act handles UI toggles instead)

a11y (P2) ──▶ ErrandAccessibilityService (channel "a11y")
             screen (read outline, globals) + act (tap/type/scroll, Draft policy)

persistence (lib/services/database.dart)
  ErrandDatabase (drift, v4) — Conversations / ConversationMessages (+attachedUrisJson) /
                               ConversationAttachments / AppSettings
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
- **`tool_registry.dart`** registers the current tools and safely executes a call, converting handler exceptions into `ToolCallResult.failure`. `ToolRegistry.defaults({currentDir, workingDirectory, supportsInput, getAttachedFiles, enableA11yTools = true})` contains `read` + `workspace` (`list`/`find`/`cd`/`pwd`) + `websearch` + `webfetch` + `intent` + `attached_files`, and conditionally includes `screen` + `act` when `enableA11yTools` is true (Full flavor). In the Lite flavor, `enableA11yTools` is false and accessibility tools are omitted. `supportsInput` (from `ModelCatalogService.supportsInput`) lets `read` fail honestly when the current model lacks `image`/`audio`/`video` support; `getAttachedFiles` lets `read` resolve file-picker cache paths outside the workspace and lets `attached_files` list the conversation inventory. `dispose()` fans out to every tool.
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
- `chatStream()` — SSE (`Accept: text/event-stream`, `stream:true`), forwards `content` deltas via `onTextDelta`, reasoning deltas via `onReasoningDelta`, and accumulates fragmented `tool_calls[].function.arguments` until `[DONE]`.

`LlmMessage { content, toolCalls, reasoning, reasoningDetails }` is the parsed response. `_sseDataEvents` handles UTF-8 chunk reassembly and comment keepalives. API key + baseUrl + model come from `LlmConfig`, built at runtime from `AppSettingsService` (SQLite-backed settings).

**Resilience (added after free-model flakiness):**

- `_postWithRetry` / `_sendStreamWithRetry` — up to 3 attempts with exponential backoff (0.8s → 1.6s), honoring `Retry-After` on 429. Retries cover `SocketException`/`http.ClientException` (stale keep-alive sockets, mobile network switches — the classic "Software caused connection abort"), timeouts, and HTTP 429/5xx.
- Streaming requests are built via a **builder closure** (`http.Request` is single-use; re-sending a finalized request throws "Bad state: Can't finalize a finalized Request").
- Retry covers only time-to-response-headers for streams; mid-stream failures surface as `LlmException(transport: true)` ("Stream interrupted") and cannot be transparently resumed.
- `LlmException.transport` marks infra-side failures (connection lost, timeouts, 429/5xx) vs agent/tool mistakes — consumed by the UI error policy (below).

Keys are configured in-app (header gear icon → Settings sheet, Global tab) and stored AES-GCM encrypted in the app-settings table.

## The file & workspace tools — `lib/tools/`

- **`read` (`file_tools.dart:readTool`)** — three branches:
  1. **Media** (`kMediaFormats`, `kMaxMediaBytes = 20 MiB`): `jpg/jpeg/png/webp/gif` → `image_url` data URL, `wav/mp3` → `input_audio {data, format}`, `mp4/webm/mov` → `video_url` data URL. Whole-file read, base64-encoded into `ToolCallResult.contentParts`; `output` stays a short summary (persisted/displayed). Capability-gated via `supportsInput(modality)` — `unsupported_modality` failure tells the model to switch models. 20 MiB pre-check is exact (`File.lengthSync`).
  2. **Structured** (`PDF/DOCX/XLSX/PPTX`): delegates to `readStructuredDocument` → `LogicalDocument.read(offset, length)` where `offset` is a logical unit index and `length` is a character budget (clamped to 256 KB). Path traversal is guarded via `path.relative` against `workspace.root`. Structured reads are memoized per-file in a registry-scoped map.
  3. **Text**: byte `offset`/`length` (default 512, max 512 KB) via `RandomAccessFile`.

  Optional `grep` argument (case-insensitive regex/substring): filters text/structured output to matching lines with file-relative 1-based line numbers; unpaginated length expands to 512 KB; structured grep filters body only (header reserved). Path resolution: `WorkingDirectory { root, current }` is the shared mutable cursor (mutated by `cd`). `_resolveWorkspaceFile` enforces `path.relative` against `workspace.root`; `_resolveReadableFile` allows an explicit escape for **file_picker cache copies** (`/data/.../cache/file_picker/...`) and any URI in `attachedFileUris` (user-picked, so trusted) even though it lives outside `/storage/emulated/0`.

- **`workspace` (`legacy_workspace_tool.dart:legacyWorkspaceTool`) [RETIRED / LEGACY]** — former router with `action` enum `pwd|cd|list|find` multiplexing `legacyListTool`/`legacyFindTool`/`legacyCdTool` (+ `pwd`). Retired from default `ToolRegistry.defaults` in favor of `bash`. Kept in the codebase with `legacy_` prefixes for backwards compatibility and test suites.
  - `list` / `legacyListTool` — non-recursive, optional `pattern` RegExp filter.
  - `find` / `legacyFindTool` — recursive glob (`*`/`?`, case-insensitive) with `type: file|dir`, `max_depth` (default 3, max 32), cap 500 results.
  - `cd` / `legacyCdTool` — mutates `workspace.current`.
  - Active directory navigation and listing are now handled by `bash` (`bashTool`), with `workingDirectory.current` automatically synchronized when `cd` commands or `working_directory` arguments are executed.

- **`attached_files` (`attached_files_tool.dart`)** — zero-param lister: `attached_files` → `No files attached…` or `Attached files: N\n1. basename — uri`. Reads from `getAttachedFiles` (the conversation's global inventory). Lets the model discover non-pending history without guessing.

- **`bash` (`bash_tool.dart` + `services/shell_service.dart`)** — executes on-device shell commands via `/system/bin/sh` using `Process.start` in `dart:io`. Runs within the application UID and respects/updates `workingDirectory.current` across shared storage and sandbox paths. Provides access to Android Toybox/Toolbox utilities (`ls`, `cat`, `grep`, `find`, `sed`, `awk`, `cut`, `sort`, `uniq`, `wc`, `tr`, `head`, `tail`, `mkdir`, `cp`, `mv`, `rm`, `tar`, `gzip`, `df`, `du`, `ps`). Automatically persists directory changes on `cd` commands or `working_directory` arguments. Enforces 30s per-command timeouts, clean cancellation abort via stop button, memory buffer guards (512 KB), and Draft safety policies (strictly blocks fork bombs, su/root, and reboot; requires `confirm_destructive: true` for bulk deletions and `rm -rf`). Large outputs automatically route through `ToolOutputFileService`.

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

**Core actions** (schema enum, unified Sep 2026 — was 17 curated): `open_file`, `open_url`, `open_app`, `settings` (+`page`), `intent`. Legacy actions still route for old conversations: `search`/`dial`/`open_maps`/`email` synthesize an `open_url` (`google.com/search`, `tel:`, `geo:`, `mailto:`); `calendar_event`/`media_play`/`share`/`wallpaper`/`uninstall`/`settings_panel` fall through to `_genericIntent`. `alarm`/`timer`/`system` (dark-mode toggle) were removed — dark-mode-style toggles are done via the `act` tool instead.

- `_genericIntent` maps curated names to real Android action constants and builds validated extras: share defaults MIME to `text/plain`, uninstall strips the package constraint (the uninstaller lives in `com.android.packageinstaller`; pinning the target package would break resolution).
- **URL safety** (`_openUrl`): auto-prefixes `https://` only for domain-like hosts (`_looksLikeWebHost`); blocks `javascript:`/`file:`; anything else fails with guidance pointing at `android_action`/`settings`. This prevents the model from "opening" settings names as web URLs. `open_file` takes an absolute device path and is served via `FileProvider` (see native side).
- **Generic escape hatch**: `action:"intent"` accepts a raw `android_action` string (e.g. `android.settings.DISPLAY_SETTINGS`, third-party `com.someapp.action.SYNC`) — new apps/actions need zero code changes.
- **UI reopen** (`isReopenable` + `replayIntentAction`): successful open-style intents (`open_file`/`open_url`/`open_app`/`settings` + legacy open-style actions) render an Open button on the tool bubble that re-fires the persisted args through the same handler. Side-effect/raw actions stay button-less unless view-style (`VIEW`/`MAIN`/`DIAL`/`SENDTO`/media-search or `android.settings.*`). Derived entirely from already-persisted data — no schema change, works for old conversations.
- All handlers are `async` and `await` the channel, so native errors (`NO_HANDLER`, `NO_PKG`, `FILE_NOT_FOUND`, `INTENT_ERR`) become `ToolCallResult.failure` instead of fake success.

**Native side** (`MainActivity.kt`, channel `"intent"`):

- `launch` — builds the intent per action (`getLaunchIntentForPackage`; `open_file`/absolute paths via `FileProvider.getUriForFile` + `ClipData` grant + extension→MIME resolution with `FILE_NOT_FOUND` honest failure; `ACTION_SENDTO mailto:` with `EXTRA_SUBJECT/TEXT` + query-param fallback; `tel:`/`mailto:` scheme-sniffed to `DIAL`/`SENDTO`; explicit `androidAction` otherwise), adds `FLAG_ACTIVITY_NEW_TASK` (no `CLEAR_TOP`, so background apps survive), adds `CATEGORY_BROWSABLE` for http(s). Launched via `PendingIntent` with `MODE_BACKGROUND_ACTIVITY_START_ALLOWED` on Android 14+ (a11y-service context fallback) so backgrounded starts aren't blocked. `resolveActivity` pre-check runs only when a package is explicitly pinned — implicit intents rely on `ActivityNotFoundException` (avoids `<queries>` visibility false-negatives on API 30+). `queryIntentActivities` detects multi-handler targets and reports `launched (choose app if prompted)` so the agent knows a chooser sheet appeared.
- `canResolve` — passes the raw action through (plus `tel:`/`mailto:` sniffing) with optional `type` for `setDataAndType` checks.
- `bringToFront` — `REORDER_TO_FRONT + SINGLE_TOP` (same BAL-safe path) restores Errand after `screen`/`act` work in other apps; fired from `_replaceWorking`/`_failWorking` when `_externalAppWorkDone`.
- Manifest `<queries>` covers http(s)/`VIEW */*` file viewing, geo, `tel`/`DIAL`, `mailto`/`SENDTO`, spotify/whatsapp/tg deeplinks, calendar `INSERT`/share `SEND`, and pinned packages (spotify/maps/chrome). Includes the `FileProvider` declaration (`file_paths.xml`). Alarm/timer/panel/delete queries were pruned with the removed actions.

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
- `ModelsDevService` — offline `models.dev` snapshot resolving native context-window tokens per model id for the dynamic budget when the catalog omits `context_length`.

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
- Sidebar (`ChatSidebar`) shows pinned favourites + recent (watch-driven, sorted), with rename/pin/delete options, slide-in animation and scrim. `ChatComposer` has add/context actions + send (gated by `canSend`); drafts survive an accidental edit-tap (composer text is never overwritten while non-empty). `MessageBubbles` renders user bubbles as `SelectableText` plus an **attachment card** (`kInputBg`, `kBorder`, ordered `1. basename` rows) when `UserMessage.attachedUris` non-empty, assistant bubbles as `GptMarkdown` (tables/code/LaTeX; list-wide `SelectionArea` provides copy), `ToolMessageBubble` `ExpansionTile`s (header truncated, output truncated for display only) with an Open button on successful open-style intent calls that replays the persisted args via `replayIntentAction`, and `CompactedDividerBubble` system dividers marking compaction points (`CompactedNoticeMessage`, persisted as `compacted` rows). Streaming uses height-eased + fade-in animation; the debug footer shows token-based budget state. Empty assistant turns are suppressed in rendering (and dropped from persistence going forward). `ModelPicker` rows use marquee for long names (no `ellipsis` truncation). Theme is `AppColors` + dark `ColorScheme` + `ThemeData(useMaterial3:true)`.

Storage permission is checked on start and on `AppLifecycleState.resumed`, with a one-at-a-time dialog prompt.

## Persistence — `lib/services/database.dart`

Drift database `ErrandDatabase` (4 tables + v4):

- `Conversations { id PK, localSystemPrompt?, title, currentDir, provider?, model?, isPinned, createdAt, updatedAt }`
- `ConversationMessages { localId autoinc PK, conversationId FK→Conversations.id, messageId, sortOrder, messageType (user/assistant/tool/error/compacted), messageText, toolName?, toolArgumentsJson?, result?, reasoning?, reasoningDetailsJson?, error?, attachedUrisJson? }` — `attachedUrisJson` (v4) stores `UserMessage.attachedUris` as JSON array; `compacted` rows store the `CompactedNoticeMessage` summary in `result`.
- `ConversationAttachments { conversationId FK, uri, PK(conversationId, uri) }` — global inventory per conversation (from Settings → Local + message history).
- `AppSettings { key PK, value }` — generic runtime KV store: encrypted API secrets (OpenRouter/Tavily keys, base-URL override) + plain preferences (voice locale, last-selected model, a11y prompt flag). Encryption lives in `SecretStore` (AES-256-GCM, key file at `<app-support>/errand.key`, outside the DB); `AppSettingsService` is the typed access layer with an in-memory cache. Replaces the former shared_preferences usage.

Key ops:

- `saveConversation(Conversation)` — `transaction`: `insertOnConflictUpdate` conversation row, then merge messages by `messageId` (new rows appended after max `sortOrder`, known rows updated in place — window-safe), attachments rewritten. Backed by a UNIQUE index on `(conversation_id, message_id)` and a `(conversation_id, sort_order)` lookup index (schema v2). Message companion now includes `attachedUrisJson` for `UserMessage`.
- `replaceAllMessages(conversationId, messages)` — full delete + sequential reinsert (`sortOrder` 0..n). Currently uncalled (compaction merge-saves its divider and retains pre-divider rows as a never-re-sent audit trail); carries a window-safety contract — argument must be the COMPLETE history, never a loaded subset.
- `deleteConversation`, `pinConversation` (toggle), `touchConversation` (bump `updatedAt`).
- `loadConversation(id)` / `_loadMessages` / `_loadAttachmentUris`, plus `insertMessage`/`replaceMessage`/`deleteMessage`.
- `watchConversationSummaries()` / `watchPinnedConversations()` — ordered streams for the sidebar.
- `getSetting(key)` / `setSetting(key, value)` / `deleteSetting(key)` — raw KV upserts/removals consumed by `AppSettingsService`.

`schemaVersion = 4`, `NativeDatabase` (or `drift_flutter` on device), `inMemory()` for tests. v1→v2 migration dedupes message rows, then creates the two indexes above; v2→v3 adds the app-settings table; v3→v4 adds `attachedUrisJson`.

## Reading order

1. `lib/types/message.dart`, `lib/types/conversation.dart`, `lib/types/tool.dart`
2. `lib/agent/tool.dart` → `tool_registry.dart` → `agent_loop.dart` (+ `context_budget.dart`)
3. `lib/services/workspace.dart` + `lib/tools/file_tools.dart` (incl. media branch) + `lib/tools/legacy_workspace_tool.dart` + `lib/tools/attached_files_tool.dart` + `lib/tools/bash_tool.dart`
4. `lib/internal/document_reading/` (models → reader → open_xml/pdf)
5. `lib/tools/web_tools.dart` + `lib/services/tavily_client.dart`
6. `lib/tools/intent_tool.dart` + `lib/services/intent_service.dart` + `MainActivity.kt` (intent channel)
7. `lib/tools/screen_tool.dart` + `lib/tools/act_tool.dart` + `lib/services/a11y_service.dart` + `ErrandAccessibilityService.kt` (a11y channel)
8. `lib/llm/llm_client.dart`
9. `lib/services/database.dart` + `lib/services/model_catalog.dart` + `lib/models/model_option.dart`
10. `lib/main.dart` + `lib/widgets/` + `lib/theme/app_colors.dart`

## The accessibility tools — `screen` + `act` (P2)

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
- **`act`** — gated injection, **Draft policy** (*agent prepares, user
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
- **Tool integration**: Integrated across `screen`, `act then_read`, `read`,
  `workspace` (`list`/`find`), `webfetch` (extract stored up to 100k chars), and `websearch`, with a safety-net wrap
  in `ToolRegistry.execute`. `_resolveReadableFile` allows `read` to open and grep
  only files inside the spill directory (post-normalize containment check — no
  substring allowlist), plus user-attached URIs and `file_picker` cache copies.

## Multimodality — `read` + `attached_files` (P3)

- **`read` media branch** (`lib/tools/file_tools.dart`, `kMediaFormats`, `kMaxMediaBytes`) — image/audio/video whole-file read into `ToolCallResult.contentParts` as OpenAI-compatible `image_url` / `input_audio` / `video_url` data URLs. Capability-gated via `ModelCatalogService.supportsInput(modelId, modality)` (parsed from `architecture.input_modalities`). `file_picker: ^10.1.2` supplies the URIs.
- **`attached_files` tool** (`lib/tools/attached_files_tool.dart`) — lists the conversation's global inventory (`Conversation.attachedFileUris`) so the model can discover history without guessing.
- **Staging vs history**: `ChatScreen._pendingAttachments` (in-memory, shown as pre-send card) → on send snapshotted into `UserMessage.attachedUris` (`ConversationMessages.attachedUrisJson`, v4) + appended to `ConversationAttachments` (global). `_toLlmHistory` renders `UserMessage.attachedUris` as the `[Attached files: …]` text list; `estimateLlmMessageTokens` sums `List` part payloads directly (flat vision/audio/video tile rates when opaque) for the budget guard.

## Next steps

- Stream-stall watchdog for `chatStream` (inactivity timeout per SSE event; `_streamTimeout` only covers time-to-headers).
- ✅ Done Sep 2026: per-model dynamic budget + pre/mid-step auto-compaction (was: entry-only truncation, `maxTurns` 18, full compaction TODO) — see `context_budget.dart: ContextBudget`.
- ✅ Done Sep 2026: Office/PDF streaming hardening (`_StreamingOpenXmlPackage` guards, lazy `PooledPdfDocument` pages, `structuredDocuments` LRU + stat invalidation).
- ✅ Done Sep 2026: Large tool output file-caching (`ToolOutputFileService` + 10-min TTL + 2k/2k preview + `read` tool cache resolution).
- ✅ Done Sep 2026: Accessibility outline viewport partitioning (visible vs off-screen separation, upfront ref mapping, interactive line prioritization, jitter compression).
- ✅ Done Sep 2026: P5a on-device shell execution tool (`/system/bin/sh`, Toybox/Toolbox, timeouts, cancellation, Draft confirmation policy for destructive mutations).
- Safe-edit tool (`write`/`edit_file` with diff preview + undo) — needs the write-policy decision originally blocking it.
- Local retrieval (embeddings/FTS) over recent docs for context budgeting.
- Evaluate SAF as an alternative to `MANAGE_EXTERNAL_STORAGE` for Play distribution.
- P4 — hardening release + guided refactor (see `next_plan.md` §P4 + `refactor.md` progress log).

