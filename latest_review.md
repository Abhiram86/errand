# Code Review: handy_flutter (Errand)

**Date:** 2026-09-26
**Scope:** 164 Dart files (~60K lines), 4 Kotlin services, agent loop, tools, UI, persistence, native channels.

The architecture is genuinely impressive — on-device agent with compaction, tool registry, headless scheduler, document readers — but there are real bugs beneath the polish.

---

## CRITICAL — Fix Immediately

### C1. Shell safety analysis bypassable via quoting tricks — destructive commands run without confirmation
**File:** `lib/services/shell_service.dart:538-546, 649-658, 219`

The tokenizer regex `(?:[^\s"']+|"[^"]*"|'[^']*')+` treats `\rm` as a single token (backslash isn't a quote char). `_stripQuotes` only strips when the token both starts and ends with a quote. So `_basename('\rm')` returns `'\rm'`, which doesn't match `rm` — the command is classified **safe** and executes without confirmation. Same bypass via `"r"m`, `'r'm`, `r''m`, `cd$IFS..`, etc.

```dart
// shell_service.dart:538
static List<String> _tokenize(String command) {
  final matches = RegExp(r'''(?:[^\s"']+|"[^"]*"|'[^']*')+''')
      .allMatches(command);

  return matches
      .map((m) => m.group(0)!)
      .map(_stripQuotes)
      .toList();
}
```

```dart
// shell_service.dart:649
static String _stripQuotes(String value) {
  if (value.length >= 2) {
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      return value.substring(1, value.length - 1);
    }
  }

  return value;
}
```

**Failure scenario:** LLM emits `\rm -rf /data/local/tmp/important` or `"r"m -rf ~/.config`. Safety check returns safe. Destructive action occurs with no user confirmation.

**Fix:** Normalize tokens by stripping all backslash-escapes and quote characters before classification:
```dart
static String _normalizeToken(String token) =>
    token.replaceAll(RegExp(r'''[\"]'''), '');
```
Apply in `_analyzeCommand` before `_basename`. This is still not a perfect shell parser, but it closes the trivial bypasses. For a robust solution, move to an allowlist model for "safe" commands.

---

### C2. Draft-policy commit guard bypassed on the `ref` tap path
**File:** `lib/tools/act_tool.dart:321-331`

The tool description promises *"Taps on final-commit controls (Send/Post/Pay/Delete/Confirm...) are refused"*. The label path enforces this via `looksLikeCommitAction` (line 361). The ref path skips it entirely:

```dart
// act_tool.dart:323
if (refRaw is int && refRaw > 0) {
  // Numeric-ref path: no label matching, no commit-word policy (refs are
  // only issued from reads the model already made deliberately).
  final res = await svc.tapByRef(refRaw);
```

**Failure scenario:** Any screen read legitimately issues refs for commit buttons (a "Pay" button appears in the outline as `[7]`). The model reads the screen once, then taps "Pay" via `ref: 7`. The documented safety model is bypassed.

**Fix:** Apply the same guard on the ref path — either have `A11yService.tapByRef` return the node's text/label so `looksLikeCommitAction` can run, or refuse destructive refs in the service layer.

---

### C3. Arbitrary device-file read via substring path matching
**File:** `lib/tools/file_tools.dart:854-858`

```dart
final isPickerCache = normalized.contains('/cache/file_picker/') &&
    await File(normalized).exists();
final isScreenshot = (normalized.contains('/cache/screenshots/') ||
        normalized.contains('/Pictures/Screenshots/')) &&
    await File(normalized).exists();
```

`contains()` is a substring test, not a containment test. `normalize()` doesn't resolve symlinks.

**Failure scenario:** A malicious app with storage permission plants `/sdcard/anything/cache/file_picker/secret.jpg`. The LLM, steered by fetched web content, calls `read` with that path. The file bytes flow into the conversation. Contrast the spill check just above (line 851) which correctly uses `path.isWithin`:

```dart
// file_tools.dart:851 — correct pattern
isSpill = normalized == outPath || path.isWithin(outPath, normalized);
```

**Fix:** Use `path.isWithin` against the resolved picker-cache / screenshots directories, and call `resolveSymbolicLinksSync()` before both the containment check and `exists()`.

---

## HIGH — Fix This Sprint

### H1. Consecutive `assistant` messages after every compaction — provider 400s
**File:** `lib/agent/agent_loop.dart:498-511`

`_toLlmHistory` unconditionally emits an assistant "ack" after each compaction notice:

```dart
case CompactedNoticeMessage():
  messages.add(const {
    'role': 'user',
    'content': '$kCompactedContextMarker\n$summaryContent',
  });
  messages.add(const {
    'role': 'assistant',
    'content':
        'I have incorporated the compacted conversation history and previous tool execution state. '
        'Continuing with the task.',
  });
```

The next effective history entry after a `CompactedNoticeMessage` is almost always an `AssistantMessage` (the model's post-compaction response). That produces two consecutive `assistant` roles. Anthropic and Gemini enforce strict user/assistant alternation and reject this with HTTP 400. The failure repeats every turn after every compaction.

Note: the low-level path (`applyCompactedHistory`, `lib/agent/context_budget.dart:339-345`) does this correctly — it omits the ack when the tail starts with `assistant`.

**Fix:** Track the last emitted role in `_toLlmHistory`; skip the ack when the previous emitted message was already `assistant`, or merge the ack text into the following assistant message.

---

### H2. Broken background engine is never reset — all future scheduled tasks silently fail
**File:** `android/app/src/main/kotlin/com/errand/errand/TaskExecutionService.kt:338-367`

```kotlin
val engine = FlutterEngine(applicationContext)
backgroundEngine = engine          // set BEFORE execution
GeneratedPluginRegistrant.registerWith(engine)

setupEngineChannels(engine)

val entrypoint = DartExecutor.DartEntrypoint(
    loader.findAppBundlePath(),
    "backgroundTaskMain"
)
engine.dartExecutor.executeDartEntrypoint(entrypoint)   // if this throws...
onReady(engine)
} catch (e: Exception) {
    Log.e(TAG, "Failed to initialize background Flutter engine", e)
    processNextRequest()           // ...backgroundEngine stays set to a dead engine
}
```

If `executeDartEntrypoint` throws (corrupt snapshot, OOM, plugin error), `backgroundEngine` remains non-null. Every later task hits the `existing != null` fast path and invokes `executeTask` on the dead engine, which errors and calls `processNextRequest()`. **All future scheduled tasks die silently** with only a log line.

**Fix:** Set `backgroundEngine` only after successful `executeDartEntrypoint`. In the catch block, destroy the engine, null the field, and only then advance the queue.

---

### H3. Flutter engine creation runs on the UI thread — ANR risk
**File:** `android/app/src/main/kotlin/com/errand/errand/TaskExecutionService.kt:338-367`

`ensureBackgroundEngine` performs `FlutterEngine(...)` + `GeneratedPluginRegistrant.registerWith` + `executeDartEntrypoint` synchronously inside a `mainHandler.post` Runnable. `TaskExecutionService` shares the main process with `MainActivity`, so this blocks the UI thread for hundreds of ms to seconds.

**Fix:** Create and initialize the engine on a background thread, then hop to `mainHandler` only for `MethodChannel` invocation.

---

### H4. Unbounded in-memory accumulation during streaming — OOM
**File:** `lib/llm/llm_client.dart:564-566`

```dart
final content = StringBuffer();
final reasoning = StringBuffer();
...
final streamedToolCalls = <int, _StreamToolCall>{};
```

A compromised, buggy, or malicious OpenAI-compatible proxy can stream unlimited bytes. The `CancelToken` only checks `isCancelled` between SSE events, not total size. There is also no total stream-duration cap — only a 30s inactivity watchdog — so a server dribbling one byte every 29s keeps a turn alive forever.

**Fix:** Cap accumulated bytes per stream (abort at ~8-16 MB total content/arguments) and add a hard total-duration timeout on `_readStreamResponse`.

---

### H5. `executeTask()` closes `LlmClient` twice
**File:** `lib/services/task_scheduler_service.dart:792, 988`

The `finally` block at line 792 calls `locallyCreatedClient?.close()`. After the `try/catch/finally`, line 988 calls `locallyCreatedClient?.close()` again:

```dart
} finally {
  _runningTokens.remove(taskId);
  locallyCreatedClient?.close();   // line 792
}

// ... notification logic ...

locallyCreatedClient?.close();     // line 988 — SECOND close

return isSuccess;
```

If `LlmClient.close()` releases resources and throws on second call, the exception propagates out of `executeTask`, the notification is never shown, and the task log's `notificationSent` column is never updated.

**Fix:** Remove the second `close()` at line 988. The `finally` already handles it.

---

### H6. `executeTask()` uses stale `task` data for post-run status updates
**File:** `lib/services/task_scheduler_service.dart:607, 866, 892, 896, 936`

The task is read once at line 607. After the run, `freshTask` is re-read (line 801) but only used for the null-check and cancellation check. The status updates at lines 866+ use the **original** `task.type`, `task.repeatAfter`, etc. If the user edited the task during the run, the update uses stale data and overwrites the user's edit.

**Fix:** Use `freshTask` (re-read at line 801) for all post-run status updates. The null-check at line 804 already handles the deleted case.

---

### H7. Per-second `setState` rebuilds entire ChatScreen — rebuild storm
**File:** `lib/screens/chat_screen.dart:2098-2107, 2112-2136`

```dart
_workingElapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
  if (!mounted || _workingMessageId == null) return;
  if (_workingText.isNotEmpty) return; // streamed text owns the bubble now
  _workingElapsedSeconds++;
  _updateWorkingPlaceholder();   // → setState → rebuilds ENTIRE ChatScreen
});
```

```dart
void _updateWorkingPlaceholder() {
  final id = _workingMessageId;
  if (id == null || _workingText.isNotEmpty) return;
  final index = _messages.indexWhere((message) => message.id == id);
  if (index == -1) return;
  // ...
  setState(() {                   // line 2127 — no mounted check
    _messages[index] = AssistantMessage(
      id: id,
      text: '$label · ${_workingElapsedSeconds}s',
      // ...
    );
  });
}
```

Every second during a turn, `setState` rebuilds the entire widget tree: header, sidebar, message list (all bubbles), composer, `BrowserWidget`, etc. — all to update one small "working Ns" placeholder bubble. On a 100+ message conversation, this means rebuilding 100+ message bubbles every second for the entire duration of a turn.

**Fix:** Isolate the working bubble into its own `StatefulWidget` that manages its own timer and `setState`. The parent only creates/destroys it; the per-second rebuild is scoped to that single widget.

---

### H8. `setState` after dispose — crash on navigation during agent turn
**File:** `lib/screens/chat_screen.dart:2112-2136, 2180-2184`

`_updateWorkingPlaceholder` calls `setState` without checking `mounted`. `_handleEvent` is a callback from the asynchronous agent loop. If the user navigates away while a turn is in flight, the loop can still deliver an `AgentEvent` after dispose, causing `FlutterError: setState() called after dispose()`.

**Fix:** Add `if (!mounted) return;` at the top of `_updateWorkingPlaceholder` and `_handleEvent`. Also add a `_disposed` flag in `dispose()` and check it in all async callbacks.

---

### H9. `mv`/`cp` to system paths not blocked
**File:** `lib/services/shell_service.dart:460-475`

For `mv`, the code checks `_isScratchOnlyList` and otherwise returns `needsConfirmation`. It never checks `_isSystemPath` on the targets. With `confirmDestructive: true`, the command runs. On a rooted device, this overwrites system binaries. Compare with `rm` which **does** block system paths (lines 415-426).

**Fix:** Add the same `_isSystemPath` check for `mv`/`cp`/`shred`/`truncate` targets that exists for `rm`.

---

### H10. Process substitution `<(...)` not detected
**File:** `lib/services/shell_service.dart:122-172`

`cat <(rm -rf /data/local/tmp/x)` — the `<(` is not a recognized token. The safety analysis sees `cat` as the command and `<(...)` as a redirect target, classifying it as safe. The inner `rm` runs as a process substitution but is never analyzed.

**Fix:** Detect `<(` or `>(` in `_hasDangerousShellConstruct` and return blocked.

---

## MEDIUM

### M1. Token estimation underestimates CJK/emoji — context overflow
**File:** `lib/agent/context_budget.dart:66-70`

```dart
int estimateTextTokens(String text) {
  if (text.isEmpty) return 0;
  return (text.length / 3.8).ceil();
}
```

3.8 chars/token is reasonable for English but CJK/emoji/Devanagari text averages 1-2 chars/token. A Japanese conversation can be underestimated by ~2x, so compaction fires only after the real context is already over the window.

**Fix:** Use a safer divisor (~3.5) and/or weight non-ASCII runs at ~1.5 chars/token.

---

### M2. `lookupContextTokens` mis-matches models — wrong context budget
**File:** `lib/services/models_dev_service.dart:237-248`

Bidirectional `contains` matching against `_seedLimits` picks wrong entries. Concrete case: `llama-3.2-1b` normalizes to `llama-3`, which matches seed `llama-3-8b` (8192) before the real 128000. Result: `compactionThreshold` computed for an 8k window, aggressive compaction every few turns, degraded quality, extra LLM spend.

**Fix:** Prefer exact/slug matches; only fall back to fuzzy matching when the result is smaller than the name-implied limit.

---

### M3. Raw cast errors escape as `TypeError`, not `LlmException`
**File:** `lib/llm/llm_client.dart:761-796`

```dart
List<ToolCall> _parseToolCalls(List<dynamic> rawCalls) => [
  for (final raw in rawCalls) _parseToolCall(raw as Map<String, dynamic>),
];
```

If any provider/proxy emits a `tool_calls` element that isn't a map, this throws a `TypeError`, which bypasses the transport-retry classification. The streaming path already guards this correctly (`if (raw is! Map<String, dynamic>) continue;`); the non-streaming paths don't.

**Fix:** Replace casts with `is Map<String, dynamic>` checks; skip or throw `LlmException('Malformed tool call...')`.

---

### M4. `repeat_after: 1` causes unbounded catch-up loop
**File:** `lib/tools/schedule_task_tool.dart:382-390`

```dart
var target = newStartsAt + interval;
while (target <= nowMillis) {
  target += interval;
}
```

`repeat_after: 1` passes validation (only `<= 0` is rejected). Editing a recurring task with `repeat_after: 1` and a past `starts_at` makes this loop run ~5.6e13 iterations — the tool call spins for hours, wedging the agent loop.

**Fix:** Add a sane minimum (e.g. `repeat_after` >= 60_000 ms) in both `create` and `edit`, and replace the linear loop with closed-form arithmetic:
```dart
target = newStartsAt + ((nowMillis - newStartsAt) ~/ interval + 1) * interval;
```

---

### M5. Compaction summary length is unbounded — compaction can loop
**File:** `lib/agent/agent_loop.dart:450-467`

If the model echoes history back as the "summary", the compacted history still exceeds the threshold, so the next turn's `_compactIfNeeded` fires again — each round costs an LLM call and up to the 60s timeout, burning turns until `maxTurnCount`.

**Fix:** Cap the summary (truncate to `budget.targetTokens * 3.8` chars, or re-prompt once) and cap `toCompact` size before building the compaction prompt.

---

### M6. `bash` `working_directory` escapes the workspace
**File:** `lib/tools/bash_tool.dart:84-110`

```dart
final resolvedPath = p.isAbsolute(rawWorkingDir)
    ? p.normalize(rawWorkingDir)
    : p.normalize(p.join(workingDirectory.current.path, rawWorkingDir));
final targetDir = Directory(resolvedPath);
if (!await targetDir.exists()) { ... }
execDir = targetDir;
workingDirectory.current = targetDir;   // line 99
```

Any existing directory on the device is accepted — there is no workspace-root confinement, unlike `_resolveListDirectory` in `file_tools.dart`. The agent can permanently relocate the workspace CWD outside the workspace via a per-call argument, after which every relative-path `read`/`list`/`find` fails until something moves it back.

**Fix:** Resolve `working_directory` through the same containment check as `_resolveListDirectory`; do not persist the mutation (use a local `execDir` only).

---

### M7. `MemoryService.find()` loads all memories for every query
**File:** `lib/services/memory_service.dart:58`

```dart
final rows = await _db.loadAllMemories();
```

Every `find()` call loads ALL memory rows from the database into memory, then filters and scores in Dart. As the user accumulates memories, this gets progressively slower.

**Fix:** Push filtering/scoring into SQL with a `LIMIT`, or at least add a `LIMIT` to the query.

---

### M8. `insertMessage()` has a read-then-write race
**File:** `lib/services/database.dart:506-516`

Reads `max(sortOrder)`, computes `nextSortOrder = max + 1`, then inserts. Between the read and the write, another `insertMessage` could insert with the same `nextSortOrder`. The unique index is on `(conversation_id, message_id)`, not `(conversation_id, sort_order)`.

**Fix:** Wrap in a transaction, or add a `sortOrder` uniqueness constraint and retry on conflict.

---

### M9. Stale `currentConversationId` closure in memory tool
**File:** `lib/tools/memory_tool.dart:80-86`

```dart
handler: (call) => _handleMemoryCall(
  call,
  memoryService ?? MemoryService.instance,
  currentConversationId,   // captured at tool-construction time
  isHeadless: isHeadless,
),
```

`currentConversationId` is bound once when the tool object is built, but tools are typically registered once and reused for the process lifetime. After any conversation switch, new memories are attributed to a long-gone conversation id.

**Fix:** Accept a `String? Function()? currentConversationId` resolver (like `getAttachedFiles` / `getCancelToken` patterns already used elsewhere).

---

### M10. Document cache byte accounting uses compressed sizes
**File:** `lib/tools/file_tools.dart:124-149`, `lib/internal/document_reading/open_xml_reader.dart:417`

A 5 MB `.xlsx` can expand to 100+ MB of XML (`maxExpandedBytes = _maxPackageBytes * 4` = 256 MB). The LRU ceiling is enforced against the compressed size, so real heap usage can be 4-20x the "64 MB" budget, causing OOM on malicious documents.

**Fix:** Account expanded/decompressed bytes (the package already tracks `totalPartBytes` — use it), and consider lowering the expansion cap.

---

### M11. Location requests spawn an un-timed `Thread` per call
**File:** `android/app/src/main/kotlin/com/errand/errand/MainActivity.kt:1136-1158`

`Geocoder.getFromLocation` has no timeout and can block for many seconds on a hung network. Repeated location requests leak threads with no bound. `TaskExecutionService` does this correctly with an `Executor` + 8s `future.get`.

**Fix:** Use a shared `ExecutorService` with a timed `Future.get`.

---

### M12. `_regenerateTargetFor` and `_isLatestActiveToolGroup` are O(n²) in `build()`
**File:** `lib/screens/chat_screen.dart:1849-1867, 3048-3059`

Both functions scan forward/backward through the entire message list for each item. For a conversation with N messages, this is O(N²) total work in `build()`.

**Fix:** Precompute once per message list (e.g., a `Map<int, String>` or a `Set<int>`), or compute in a single forward pass.

---

### M13. Mutating `_animatedMessageIds` during `build()`
**File:** `lib/screens/chat_screen.dart:2987-2990`

```dart
final shouldAnimate = !_animatedMessageIds.contains(item.id);
if (shouldAnimate) {
  _animatedMessageIds.add(item.id);   // mutation during build
}
```

Adding to a `Set` that affects future build output, during `build()`, is a side effect during build — an anti-pattern that can cause inconsistent frames. The set also grows unboundedly during a conversation.

**Fix:** Track animation state per-message, or update the set in a post-frame callback or `didUpdateDependencies`, not during build.

---

### M14. Sidebar watch streams trigger full `setState` on every emission
**File:** `lib/screens/chat_screen.dart:327-341`

```dart
_conversationsSub = database.watchConversationSummaries(...).listen((summaries) {
  if (!mounted) return;
  setState(() {                    // full screen rebuild
    _conversations = summaries;
    _sortedConversationsDirty = true;
  });
});
```

Every conversation summary emission triggers a full `ChatScreen` rebuild. During streaming, `_schedulePersist` fires every 600ms, each persist updates `updatedAt`, the watch re-emits, and the screen rebuilds — even when the sidebar is closed.

**Fix:** Only trigger `setState` when `_sidebarOpen` is true, or use a `ValueNotifier` that the sidebar listens to directly.

---

### M15. Model catalog cache key conflates different API keys
**File:** `lib/services/model_catalog.dart:455-458`

```dart
static String _cacheKey(String baseUrl, String apiKey) {
  final normalized = _normalizeBaseUrl(baseUrl);
  return '$normalized|${apiKey.trim().isEmpty ? 'anon' : 'auth'}';
}
```

Two different keys on the same base URL both map to `...|auth`. Changing the API key serves the stale catalog until `clearCache()` runs.

**Fix:** Include a short hash of the key material: `'$normalized|${hash(apiKey)}'`.

---

### M16. Background intent channel uses a blocklist, not an allowlist
**File:** `android/app/src/main/kotlin/com/errand/errand/TaskExecutionService.kt:578-687`

`isActivityAction` blocks known activity actions from headless runs, but any unrecognized action falls through to `sendBroadcast(intent)` with attacker-influenced action/data/extras.

**Fix:** Use an allowlist (or requiring an explicit `package` for non-broadcast actions).

---

### M17. `ensureKey()` race condition can corrupt the encryption key
**File:** `lib/services/secret_store.dart:33-49`

No mutex. If two coroutines call `ensureKey()` concurrently, both can see `_key == null`, both read/write the key file, and interleave. After this, `decryptString` using `_key` will fail to authenticate ciphertext written with the other key.

**Fix:** Serialize key initialization with a `Completer`.

---

## LOW — Worth Cleaning Up

| # | File | Issue |
|---|------|-------|
| L1 | `lib/screens/chat_screen.dart:878-881` | Focus listener calls `setState` on entire screen — use `ListenableBuilder` on the `FocusNode` |
| L2 | `lib/screens/chat_screen.dart:316-320` | `getLocation` Future not caught — unhandled async error |
| L3 | `lib/services/update_service.dart:614-617` | HTTP stream not cancelled on timeout — acknowledged in comment but still live |
| L4 | `lib/widgets/tasks/edit_task_model_sheet.dart:166` | `setState` without `mounted` check — crash on dispose during async load |
| L5 | `lib/services/shell_service.dart:5` | Unused import `llm_client.dart` |
| L6 | `lib/tools/file_tools.dart:927-957, 1456-1504` | ~80 lines of dead commented-out tool implementations |
| L7 | `lib/tools/act_tool.dart:274-280` + `lib/tools/screen_tool.dart:255-262` | Duplicated `_splitScreenHeader` |
| L8 | `lib/agent/context_budget.dart:421-679` | Dead legacy char-based compatibility layer with no callers |
| L9 | `lib/agent/agent_loop.dart:69-71` | `RepeatedToolFailureException` doc says it "triggers cancelToken" — nothing catches it to do that |
| L10 | `lib/llm/llm_client.dart:290` | `Retry-After` HTTP-date not honored — only delta-seconds parsed |

---

## Top 5 Recommended Actions (by impact/effort ratio)

1. **Fix the shell safety bypass (C1 + H9 + H10)** — Add `_normalizeToken` to strip backslash-escapes/quotes before classification, add `_isSystemPath` check for `mv`/`cp`, detect process substitution. Closes the most dangerous attack surface.

2. **Fix the compaction ack (H1)** — Track last emitted role in `_toLlmHistory`; skip the ack when the previous message was already `assistant`. Fixes provider 400s after every compaction.

3. **Fix the background engine lifecycle (H2 + H3)** — Null out `backgroundEngine` on init failure, and move engine creation off the main thread. Fixes silent task death and ANR.

4. **Isolate the working bubble (H7 + H8)** — Extract the working placeholder into its own `StatefulWidget` with its own timer. Eliminates the per-second full-screen rebuild and the setState-after-dispose crash.

5. **Fix the double-close and stale-data bugs in `executeTask()` (H5 + H6)** — Remove the duplicate `close()` at line 988, use `freshTask` for all post-run status updates.

---

## Summary

The codebase is well-architected overall — the agent loop, compaction, and tool registry are thoughtfully designed. The issues above are concentrated in three areas: the shell safety parser (which has fundamental limitations of static analysis), the task scheduler lifecycle, and the ChatScreen (which has grown to 3127 lines and accumulated performance debt). None of these are architectural flaws — they're concrete bugs with concrete fixes.
