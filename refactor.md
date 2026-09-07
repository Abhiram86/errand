# Refactor Memory — P4a Guided Service-by-Service (v0.3.0)

> **Purpose:** Long-context memory for this and future sessions. `next_plan.md` + `architecture.md` + `lib/main.dart` are the big-3; this file is the *compressed* survivor when history truncates. Update it after every service step.
> **Last updated:** 2026-09-07 | **Status:** P4a #1,2,4–7 done (3 partial, 8–10 open) | **Schema:** Drift v4 + `compacted` rows

---

## 1. Big Picture (10s recall)

```
ChatScreen (lib/main.dart)  owns Conversation, _messages, _pendingAttachments,
  + Drift watches + WorkingDirectory + LlmClient + model picker + paging
    │
AgentLoop (lib/agent/agent_loop.dart:45)  72 turns, ContextBudget tokens,
  pre/mid-step _compactIfNeeded, concurrent stateless tools
    │  UserMessage.attachedUris → "[Attached files:]" text
    │  ToolCallResult.contentParts → synthetic user message (tool-role media not portable)
    │  CompactedNoticeMessage divider → effectiveHistory restart + replaceAllMessages
    ▼
LlmClient (lib/llm/llm_client.dart:94)  POST /chat/completions stream:true
  SSE + retry(3, backoff 0.8s→1.6s, Retry-After) + CancelToken socket-close
    ▼
ToolRegistry.defaults (lib/agent/tool_registry.dart:24)  8 tools:
  read(+media) | workspace(pwd/cd/list/find) | websearch | webfetch
  | intent(17 actions+android_action hatch) | screen | act | attached_files
    ├─▶ WorkingDirectory{root:/storage/emulated/0, current} → dart:io
    ├─▶ LogicalDocument (lib/internal/document_reading/) PDF/DOCX/XLSX/PPTX char-budgeted
    ├─▶ TavilyClient (api.tavily.com) lazy per-call
    ├─▶ IntentService → MainActivity.kt channel "intent"
    └─▶ A11yService → ErrandAccessibilityService.kt channel "a11y"
          screen outline (depth/node/char caps) + act Draft policy (prepare, user sends)

Persistence: ErrandDatabase (lib/services/database.dart) Drift v4 + `compacted` rows
  Conversations | ConversationMessages(+attachedUrisJson) | ConversationAttachments | AppSettings
  saveConversation: merge by (conversation_id,message_id), window-safe. UNIQUE(message_id)+sort_order index.
  replaceAllMessages: full rewrite after compaction (clean sortOrder).
  AppSettings: AES-GCM SecretStore (errand.key) for keys, plain for prefs.

ModelCatalog: GET {baseUrl}/models → architecture.input_modalities + context_length
  → ModelOption(supportsInput, contextLength); ModelsDevService offline fallback; deprecated filtered
```

**Error split (critical invariant):** Tool errors → `ToolMessage` inline + context. Transport/API (429/5xx/socket/timeout) → `_failWorking` SnackBar, never persisted/context. `LlmException.transport` flag.

---

## 2. P4a Intent

> ~99% AI-written code — goal is to *own & harden*, not rewrite line-by-line. Shrink, simplify, optimize reliability/latency.

**Process per service (next_plan.md:366):**
1. Walkthrough — explain every line/why it exists
2. Core-algorithm revisit — cut/merge/simplify together
3. Rewrite service-scoped — small diff, tests updated, own commit (bisectable)

**Rules:**
- No feature changes — behavior parity via `81 tests` (`file_tools_media_test.dart` etc.)
- Bug found → fix inline, note separately
- One service = one commit

---

## 3. Service Inventory — Full Map

### 3a. Inside `lib/services/` (10 files) — DO NOT confuse with "all services"

| File | Class/Service |
|------|---------------|
| `a11y_service.dart` | `A11yService` (isEnabled/isRestricted/readScreen/gesture) |
| `app_settings.dart` | `AppSettingsService` (typed KV over AppSettings table, cache) |
| `database.dart` (+`.g.dart`) | `ErrandDatabase` Drift v4 |
| `intent_service.dart` | `IntentService` (launch/canResolve/bringToFront/FGS indicator; write-settings + alarm removed) |
| `model_catalog.dart` | `ModelCatalogService` (cache+inFlight dedup, supportsInput O(n), contextLength, deprecated filter) |
| `models_dev_service.dart` | `ModelsDevService` (offline models.dev context-window lookup) |
| `secret_store.dart` | `SecretStore` AES-256-GCM |
| `speech_service.dart` | `SpeechService` (mic, SpeechToText wrapper) |
| `tavily_client.dart` | `TavilyClient` (search/extract) |
| `workspace.dart` | `Workspace` singleton + `WorkingDirectory` |

### 3b. Outside `lib/services/` — the other 16 service-like layers (P4a scope)

| # | P4a Order | Service | File(s) | Key Invariant |
|---|-----------|---------|---------|---------------|
| 1 | **1** | `ModelOption` | `lib/models/model_option.dart` | `inputModalities` default `["text"]`, provider from id prefix, `contextLength?` for budget |
| 2 | 6 | `LlmClient`+`CancelToken` | `lib/llm/llm_client.dart` | cancellable backoff, stream 429-retry, non-SSE fallback, `cleanErrorMessage`, `includeReasoning` flag |
| 3 | 7 | `AgentLoop`+`ContextBudget`+`ToolRegistry` | `lib/agent/agent_loop.dart:45` `context_budget.dart` `tool_registry.dart:15` `tool.dart` | 72 turns, token `ContextBudget` + pre/mid `_compactIfNeeded`, concurrent stateless tools, `Tool.dispose` |
| 4 | 3 | `read` (text+structured+media) | `lib/tools/file_tools.dart` | 20 MiB pre-check, `_resolveReadableFile` cache escape, `contentParts` synthetic, 32K clamp, LRU doc cache + stat invalidation |
| 5 | 3 | `workspace` tool | `lib/tools/workspace_tool.dart` | `pwd/cd/list/find`, `max_depth` 32 cap 500, `path.relative` traversal guard |
| 6 | 2 | `websearch`/`webfetch` | `lib/tools/web_tools.dart` | lazy TavilyClient, unset key → honest failure |
| 7 | 5 | `intent` tool | `lib/tools/intent_tool.dart` | 5 core (`open_file/open_url/open_app/settings/intent`) + legacy routing; `isReopenable` open-style only |
| 8 | 9 | `screen`/`act` | `lib/tools/screen_tool.dart` `act_tool.dart` | caps+`settle_ms` 350, Draft-policy word-boundary commit refuse, no coord taps |
| 9 | 3 | `attached_files` | `lib/tools/attached_files_tool.dart` | zero-param, reads global inventory |
| 10 | 4 | `LogicalDocument` readers | `lib/internal/document_reading/*` | `_maxPackageBytes` 64MB, zip/xml guards, 256KB char budget |
| 11 | 10 | `ChatScreen`/`ErrandApp` | `lib/main.dart:78,108` | `_pendingAttachments` staging → `UserMessage.attachedUris`, `PagedFetcher` 20/50, `SelectionArea`, `…working · Ns` ticker |
| 12 | 10 | Widgets | `lib/widgets/*.dart` | `paging.dart:PagedFetcher`, `message_bubbles.dart:SelectionArea+Open btn`, `model_picker: _ScrollingModelName marquee 7s, clip/visible truncation` |
| 13 | — | Types | `lib/types/*.dart` | `Conversation.attachedFileUris` global, `ToolCallResult.contentParts`, `CompactedNoticeMessage` divider |
| 14 | — | Theme | `lib/theme/app_colors.dart` | `kDarkBg` etc. dark M3 |
| 15 | 9 | Native Kotlin | `android/.../MainActivity.kt` `ErrandAccessibilityService.kt` `AgentForegroundService.kt` | `NEW_TASK` (no `CLEAR_TOP`), `FileProvider`, BAL-safe `PendingIntent`, `bringToFront`, `resolveActivity` only when pinned, `isRestricted` AppOps |

---

## 4. P4a Dependency Order (leaf-first) — next_plan.md:374

```
1  model_catalog.dart + model_option.dart          ← smallest, isolated      [x] 2026-08-29 (+contextLength 09-07)
2  tavily_client.dart + web_tools                  ← web layer               [x] 2026-09-01
3  workspace.dart + file_tools.dart + workspace_tool + attached_files_tool  [~] partial (LRU+dispose via fa6d2ec; resolvers unsplit)
4  internal/document_reading/ (4 files)            ← structured readers      [x] 83f367b + fa6d2ec
5  intent_service.dart + intent_tool.dart + MainActivity.kt                  [x] 225b599 (5-action unify)
6  llm_client.dart (+ CancelToken/retry)           ← resilience core         [x] d75d86d
7  agent/context_budget.dart + agent_loop.dart     ← dynamic budget+compaction [x] dbe2757
8  services/database.dart (schema v4 + compacted)  ← +replaceAllMessages     [~] partial (compaction half via dbe2757)
9  a11y_service.dart + ErrandAccessibilityService.kt + screen/act tools      [ ]
10 main.dart + widgets last                        ← depends on all above    [x] walkthrough 2026-09-07 (2209 lines; no rewrite — owns everything, see §3b-11)
```

Mark `[x]` when walkthrough+revisit+rewrite+tests pass. One commit per row.

---

## 5. Cross-Cutting Invariants to Preserve

- **Window-safe persistence:** `saveConversation` merge by `messageId`, never `deleteAll+reinsert`. `truncateFrom` must `deleteMessage` explicitly. `attachedUrisJson` v4 col + `ConversationAttachments` global table.
- **Attachment flow:** `ChatScreen._pendingAttachments` (in-mem) → `_send()` snapshot → `UserMessage.attachedUris` + `Conversation.attachedFileUris` (Local tab, `attached_files` tool, `systemPromptFor` injection). Legacy `[Attached files:]` suffix via `_stripAttachedBlock`.
- **Media transport:** `read` media → `contentParts` → `AgentLoop:pendingMediaParts` → synthetic `user` message `[Media file(s) you just read…]`. Capability-gated `supportsInput != false` allows unknown endpoints.
- **Context budget (rewritten Sep 2026):** token-based `ContextBudget(contextSize − min(16K,25%))`, `target = 50%`, `~3.8 chars/token`, flat media tile rates. Pre-turn + post-batch `_compactIfNeeded` (newest 1–2 tail blocks kept, rest LLM-summarized w/ deterministic fallback under a 60s `compactionTimeout`). Oversized 1-block tails shrink via `fitTailToTarget` (content trims, never block drops). `CompactedNoticeMessage` divider → `effectiveHistory` restart + merge-save (`replaceAllMessages` kept unused under a full-history-only contract) + `CompactedDividerBubble`. Per-result 32K clamp + tool-batch atomicity kept. Char `truncateHistory`/`trimLlmMessages` kept as compat layer (footer/tests).
- **Intent safety:** 5 core → legacy routing → generic → honest fail. URL `https://` prefix only for `_looksLikeWebHost`, block `javascript:/file:`. `resolveActivity` only when package pinned. `open_file` via `FileProvider` + MIME sniff, `FILE_NOT_FOUND` honest failure. BAL-safe launch (`PendingIntent` + a11y fallback), chooser-sheet reporting.
- **Loop concurrency rule:** `Future.wait` only when no stateful call in batch (`act`, `workspace cd`, `screen global` force sequential — shared cursor/screen would race).
- **A11y Draft policy:** agent prepares, user sends; `act` refuses `send/pay/delete…` by word-boundary, `isPassword` gate, scroll gesture fallback.
- **P2/P3 policy:** P2 sideload-only (Oct 30 2025 Play ban on autonomous a11y). `isAccessibilityTool=false` truthfully → `Restricted setting` friction accepted.

---

## 6. Progress Log

| Date | Service | Action | Notes | Commit |
|------|---------|--------|-------|--------|
| 2026-08-28 | — | Created `refactor.md` | Memory file init after big-3 review | — |
| 2026-08-29 | 1 `model_catalog` | `supportsInput(baseUrl)` + exception wrap | `supportsInput` now O(n) single-catalog when `baseUrl` given (normalized), fallback O(total) scans all caches when null. `main.dart:1250` now passes `effectiveBaseUrl`. Wrapped `_fetch`: `Uri.parse` FormatException, `ClientException`/`catch`, `jsonDecode` FormatException, processing catch → all `ModelCatalogException`. Tests: 2/2 pass. | — |
| 2026-08-29 | 1+10 `model_picker` trigger | Truncation/marquee tweak (`_ScrollingModelName`) | `duration 9s→7s`, non-animating `Text` now `softWrap:false, overflow:clip`, animating branch `Transform→child` fix + `overflow:visible`, both use `SizedBox(painter.width)` clipping. Prevents ellipsis bleed in header/dialog rows. | — |
| 2026-09-01 | 2 `tavily_client` | Exception handling hardening | Wrapped `Uri.parse` FormatException, `jsonEncode` catch, `TimeoutException`, `ClientException` + generic `catch → TavilyException('Network error')`. Keeps web_tools `catch→ToolCallResult.failure` honest. `web_tools_test 2/2` pass, `analyze` clean. | — |
| 2026-09-01 | 3 doc readers | Full-parse-upfront problem logged | PDF: `read_pdf_text` extracts ALL pages via platform channel (2× RAM during transfer). Office: `_OpenXmlPackage.load` decompresses ALL ZIP entries + full XML DOM. Solution: `syncfusion_flutter_pdf` (page-range extraction, low effort) + `office_oxide` Rust FFI (replaces all Office readers, medium effort). | — |
| 2026-09-01 | 4 doc readers | Patch streaming retained (uncommitted) | **`pdf_reader.dart:20` PooledPdfDocument** kept lazy `PdfTextExtractor` (streaming) — fixed `factory PooledPdfDocument` `PdfDocument(inputBytes:)` `try→FormatException`, per-page `extractText` in `try→''` (blank on corrupt page). **`open_xml_reader.dart:280` streaming kept** — fixed `_StreamingOpenXmlPackage` from sync `lengthSync`+`file.content` (held media inflated) to async `load()` with `await file.length()`, `_maxPackageEntries=2000` guard, `!isXml&&!isRels` skip *before* `readBytes`, `_maxPackageBytes*4` overflow checks, `ArchiveException→FormatException`, `Uint8List` map backing; `readXlsxDocument:152` now reads `xl/workbook.xml` via `_readWorkbookSheetNames` for real sheet names (numeric sort fallback), header/footer `XmlEnd(p)`→`\n`. Added `dart:typed_data` import. `document_reader.dart:1` is thin router (`export`, `readStructuredDocument` legacy guards). `analyze` clean, `document_reader_test 1/1` pass. | — (uncommitted) |
| 2026-09-05 | 5 `intent` | 5-action unify + FileProvider + BAL-safe launch (`225b599`) | `open_file` (`FileProvider`+`ClipData`+MIME, `FILE_NOT_FOUND`), `PendingIntent MODE_BACKGROUND_ACTIVITY_START_ALLOWED` + a11y fallback, chooser detection, `bringToFront` (`REORDER_TO_FRONT`, `_externalAppWorkDone` on screen/act), `CLEAR_TOP` dropped, write-settings/`system_toggle`/`nextAlarm` + alarm queries removed. Legacy routing keeps old chats working. `intent_tool_test` + reopen tests pass. | `225b599` |
| 2026-09-05 | 4+3 `doc-reading`/`file_tools` | Lazy PDF units + LRU doc cache (`fa6d2ec`) | `_LazyPdfUnitList` (32-page evict, scanned-page placeholder, 256K page cap, base `dispose()`), `readTool` 10-doc LRU + `stat` invalidation + dispose-on-evict, DOCX grouping + PPTX/XLSX rel-order. `pdf/open_xml_reader` tests pass. | `fa6d2ec` |
| 2026-09-06 | 6 `llm_client` | Transport hardening + error UX (`d75d86d`) | Trailing-slash URI, per-attempt close, cancellable backoff, stream 429-retry w/ drain, `HttpException`, non-SSE JSON fallback, SSE error shapes, tool-index fallback, empty guard, `cleanErrorMessage`, `includeReasoning` flag. `main.dart`: cancel-reset reorder, clamped toasts. `model_catalog`: deprecated filter. | `d75d86d` |
| 2026-09-06 | 7 (wip) `agent` | Concurrency + merge + token-est (`e6bb95d`, intermediate) | `Future.wait` for stateless batches (stateful gate: `act`/`cd`/`screen global`), assistant-text→`tool_calls` merge (strict-provider fix), media-aware `_llmMessageChars`, synthetic-media-excluded mandatory tail, `Tool.onDispose`/`registry.dispose`. `agent_loop/tool_registry/context_budget` tests. Superseded by `dbe2757`. | `e6bb95d` |
| 2026-09-07 | 7 `agent` | Dynamic budget + auto-compaction (`dbe2757`) | `ContextBudget` tokens (reserve `min(16K,25%)`, 128K default, `ModelsDevService` fallback, per-preset `contextLength`), `_compactIfNeeded` pre-turn + post-batch (1–2 tail blocks, LLM summary + deterministic fallback), `CompactedNoticeMessage` + `effectiveHistory` + `applyCompactedHistory`, `AgentCompacting/Compacted` events, `maxTurns 18→72` ctor param, divider merge-save (`replaceAllMessages` kept, uncalled), `CompactedDividerBubble` + footer indicators + draft-guard UI. `dynamic_context_budget/models_dev` suites pass. | `dbe2757` |
| 2026-09-07 | 7 `agent` fixes | Compaction review fixes (uncommitted review) | `compactionTimeout` 60s cap (ctor param; timeout → fallback, stop still rethrows divider-less), `fitTailToTarget` (oldest-first content trims to 1K floor, newest spared, media/non-tool untouched, input unmutated), `replaceAllMessages` window-safety contract + uncalled note. Stop-during-compaction re-verified already-safe (flag reset in fail/replace paths). 5 new tests. | `ef8a446` |
| 2026-09-07 | 7+9 batch fixes | Sequential abort + settle review fixes | `_isStatefulCall` extracted; fail-fast skips only stateful followers (`type:'skipped'` marker, first-failure reason wins) — stateless siblings always run; `_prevAlreadySettled` skips the 350ms settle after `act`+`then_read`; Kotlin blank-line + EOF newline. Short-circuit test rewritten (stateful follower) + 2 new tests (sibling-runs, settle-skip timing). | — |
| | 8 | | | |
| | 9 | | | |
| | 10 | | | |

**How to update:** After each service, append row: date, what was cut/merged/simplified, bugfixes noted, test delta (e.g. `81→84 tests`), commit hash.

---

## 7. Open Items

- Stream-stall watchdog (~20 LOC inactivity transformer, headers timeout only)
- ✅ Done: SSE/transport error shaping (`d75d86d` `cleanErrorMessage` + error-shape mapping)
- ✅ Done: `maxTurns` param + mid-run compaction (`dbe2757`: 72 + auto-compaction)
- ✅ Done: Office/PDF streaming hardening (`83f367b` + `fa6d2ec`)
- `write`/`edit_file` + local retrieval (backlog post-P4b)
- Service 3 remainder: split `file_tools.dart` resolvers, async media reads, `Workspace.root` multi-user discovery
- Service 8 remainder: formal schema migration for `compacted` rows (currently implicit via `result` col); decide `replaceAllMessages` wire-up vs delete
- `LlmMessage.toJson(includeReasoning:false)` default vs loop's explicit `true` — confirm history reasoning policy
- Compaction follow-ups: `Future.wait` result→event ordering under concurrency; synthetic-media block pinning when media IS the instruction (media `List` contents still untrimmable by `fitTailToTarget`)

---

## 7b. Document Readers — Full-Parse-Upfront Problem

### The problem (all formats)

Every document reader materializes **all** logical units into a `List<LogicalDocumentUnit>` on first access, before any slicing:

| Format | What happens on first `read()` | RAM hit |
|---|---|---|
| **PDF** | `ReadPdfText.getPDFtextPaginated(path)` → platform channel to PDFBox/PDFKit → **all pages** returned as `List<String>` → 200 pages = 200 `LogicalDocumentUnit` objects. Native side holds full copy too (double during transfer). | 2× (Dart + native) for duration of channel call; then 1× in Dart |
| **DOCX** | `_OpenXmlPackage.load` → `ZipDecoder().decodeStream` → **all XML entries** decompressed into `Map<String, Uint8List>` (64MB cap) → `XmlDocument.parse` full DOM per part → every `<p>` + `<tbl>` + header/footer → one unit per paragraph. 200-page DOCX = hundreds of units. | Full ZIP decompress + full XML DOM + all units |
| **XLSX** | Same ZIP + XML → **all sheets** parsed, `sharedStrings.xml` fully loaded, every row chunked to 1800-char groups. One huge sheet = many units. | Shared strings list + all row chunks |
| **PPTX** | Same ZIP + XML → **all slides** parsed → one unit per slide. | All slide XMLs |

`LogicalDocument.read(offset, length)` only slices from the already-materialized list. The parse cost is paid once, but it's the *full* file, not the requested range.

### PDF solution: `syncfusion_flutter_pdf`

```dart
// Current (read_pdf_text — all pages at once):
final pages = await ReadPdfText.getPDFtextPaginated(file.path);

// Proposed (syncfusion — page-range extraction):
final document = PdfDocument(inputBytes: file.readAsBytesSync());
final extractor = PdfTextExtractor(document);
final text = extractor.extractText(
  startPageIndex: offset,
  endPageIndex: min(offset + pageCount, document.pages.count) - 1,
);
// document.pages.count for total page count
// extractText returns single string for the range
```

- **Drop-in**: same `LogicalDocument` output shape, just build units from the extracted range
- **Lazy**: only parses requested pages at native level (C++/ObjC), not all pages
- **RAM**: holds only the page range text, not full `List<String>` of all pages
- **License**: Syncfusion Community License (free commercial use < $1M revenue)
- **Effort**: Low — swap `read_pdf_text` for `syncfusion_flutter_pdf`, same `pdf_reader.dart` API surface

### Office solution: `office_oxide` (Rust FFI, potential)

- Native Rust extraction via `flutter_rust_bridge` → FFI
- Handles `.docx/.xlsx/.pptx` + legacy `.doc/.xls/.ppt`
- ~0.8ms/docx, ~5ms/xlsx — batch extraction, no Dart XML DOM
- Could replace entire `open_xml_reader.dart` + remove `archive`/`xml` dependencies
- **Trade-off**: adds native binary dep (~300KB), Rust build step
- **Effort**: Medium — new FFI bridge, but removes ~476 lines of hand-rolled ZIP/XML parsing
- **Decision 2026-09-01**: Streaming `XmlEventDecoder` retained — fixed ZIP `!isXml&&!isRels` filter before `readBytes` (was holding media inflated via `file.content`), added `_maxPackageEntries`/`_maxPackageBytes*4` guards, workbook sheet names via `workbook.xml` (was synthetic `Sheet $index`). DOM `XmlDocument` path removed.

### Patch 2026-09-01 — fixes applied (uncommitted, streaming retained)

- `pdf_reader.dart:20` **PooledPdfDocument kept lazy** — fixed `factory` `PdfDocument(inputBytes:)` `try→FormatException`, per-page `extractText` `try→''` (blank on corrupt page). Retains `syncfusion` lazy paging (`read` extracts only `offset..offset+budget` pages via `PdfTextExtractor`).
- `open_xml_reader.dart:280` **streaming kept, ZIP fixed** — replaced sync `file.lengthSync()` + `Archive.files[].content` (held all media inflated) with async `Future<_StreamingOpenXmlPackage> load()` using `await file.length()`, `_maxPackageEntries` guard, `!isXml&&!isRels` skip *before* `readBytes()`, `_maxPackageBytes*4` overflow arithmetic, `ArchiveException→FormatException`, `Uint8List` map + `Stream.value(bytes)` backing. Callers `readDocx/Xlsx/PptxDocument` now `await load()`.
- `open_xml_reader.dart:152` **XLSX names** — reads `xl/workbook.xml` via `_readWorkbookSheetNames` (event parse `<sheet name>`) for real sheet labels (`Sheet: $name`), numeric sort fallback.
- `open_xml_reader.dart:90` **header/footer** — `XmlEnd(p)→\n` to preserve paragraph breaks (was run-together).
- `document_reader.dart:1` **router retained** — thin barrel `export 'document_models.dart'` + `readStructuredDocument` with legacy/image `FormatException` guards; streaming lives in `open_xml_reader.dart` as intended.

---

## 8. How to Resume (for any session/agent)

1. Read this file first (2 min). Then `next_plan.md:359 P4a` + `architecture.md:8 big picture` if needed.
2. Check §4 for next unchecked service → §3b for files → walkthrough → revisit → rewrite → tests → commit → update §6.
3. Keep this file as source of truth for cross-service decisions — don't re-derive invariants from scratch.

## 9. References

- Roadmap: `next_plan.md` (esp. §P4, §P2 tiers, §P3 media)
- Architecture: `architecture.md` (reading order § 10 steps)
- UI orchestrator: `lib/main.dart:108 ChatScreen` (785 lines, owns everything)
- Tests: `test/` (81 tests pre-P4a)
- Kotlin: `android/app/src/main/kotlin/com/errand/errand/`
