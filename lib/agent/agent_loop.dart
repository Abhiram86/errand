import 'dart:convert';

import '../llm/llm_client.dart';
import '../types/conversation.dart';
import 'context_budget.dart';
import '../types/message.dart';
import '../types/tool.dart';
import 'tool.dart';
import 'tool_registry.dart';

typedef AgentObserver = void Function(AgentEvent event);
typedef AgentTextObserver = void Function(String delta);
typedef AgentReasoningObserver = void Function();
typedef AgentRetryObserver = void Function(int attempt, String reason);

sealed class AgentEvent {
  const AgentEvent();
}

class AgentCompacting extends AgentEvent {
  const AgentCompacting();
}

class AgentCompacted extends AgentEvent {
  final String summary;
  final int tailBlockCount;
  const AgentCompacted(this.summary, {this.tailBlockCount = 0});
}

class AgentToolCall extends AgentEvent {
  final ToolCall call;
  final ToolCallResult result;
  final String? reasoning;
  final List<Map<String, dynamic>> reasoningDetails;

  const AgentToolCall(
    this.call,
    this.result, {
    this.reasoning,
    this.reasoningDetails = const [],
  });
}

/// Thrown when the agent loop encounters repeated consecutive identical tool call errors,
/// indicating an unrecoverable model loop rather than a user-requested stop.
class RepeatedToolFailureException implements Exception {
  final ToolCall call;
  final int count;
  final String message;

  RepeatedToolFailureException(this.call, this.count, [String? customMessage])
      : message = customMessage ??
            'Execution aborted: tool "${call.name}" failed $count times consecutively with identical arguments.';

  @override
  String toString() => message;
}

class AgentLoop {
  static const int defaultMaxTurns = 72;
  static const int maxTurns = defaultMaxTurns;

  /// Upper bound for one compaction round-trip. The inner `chat` call
  /// retries internally, so without this cap a saturated endpoint wedges the
  /// turn for minutes before the deterministic fallback runs. Firing maps to
  /// the fallback summary via the generic catch below (never a throw).
  static const Duration defaultCompactionTimeout = Duration(seconds: 60);

  /// Maximum number of consecutive identical failing tool calls before
  /// the loop aborts and triggers cancelToken.
  static const int defaultMaxConsecutiveSameToolErrors = 3;

  final LlmClient _llm;
  final ToolRegistry _registry;
  final ContextBudget budget;
  final int maxTurnCount;
  final Duration compactionTimeout;
  final int maxConsecutiveSameToolErrors;
  final String Function()? systemPromptBuilder;

  /// Set by the UI stop button; checked at every turn boundary and between
  /// SSE events. Throws [LlmStoppedException] at the next safe boundary.
  final CancelToken? cancelToken;
  final bool Function(String modality)? supportsInput;
  final AgentObserver? onEvent;
  final AgentTextObserver? onTextDelta;
  final AgentReasoningObserver? onReasoningDelta;
  final void Function()? onReset;
  final AgentRetryObserver? onRetry;
  final void Function(String summary)? onCompacted;

  AgentLoop({
    required this._llm,
    required this._registry,
    ContextBudget? budget,
    int? modelContextSize,
    int? maxTurns,
    Duration? compactionTimeout,
    int? maxConsecutiveSameToolErrors,
    this.systemPromptBuilder,
    this.cancelToken,
    this.isCancelled,
    this.supportsInput,
    this.onEvent,
    this.onTextDelta,
    this.onReasoningDelta,
    this.onReset,
    this.onRetry,
    this.onCompacted,
  })  : budget = budget ??
            (modelContextSize != null
                ? ContextBudget(contextSize: modelContextSize)
                : ContextBudget.defaultBudget),
        maxTurnCount = maxTurns ?? defaultMaxTurns,
        compactionTimeout = compactionTimeout ?? defaultCompactionTimeout,
        maxConsecutiveSameToolErrors =
            maxConsecutiveSameToolErrors ?? defaultMaxConsecutiveSameToolErrors;

  final Future<bool> Function()? isCancelled;

  Future<String> run(Conversation conversation) async {
    // OPT-07: individual tool results are head-clamped at the boundary.
    final history = clampToolResults(conversation.messages);
    final systemPrompt =
        conversation.localSystemPrompt ?? systemPromptBuilder?.call();
    final messages = <Map<String, dynamic>>[
      if (systemPrompt != null)
        {'role': 'system', 'content': systemPrompt},
      ..._toLlmHistory(history),
    ];

    // Check context budget immediately if incoming history exceeds threshold
    await _compactIfNeeded(messages);

    ToolCall? lastFailedCall;
    var consecutiveSameErrorCount = 0;

    for (var turn = 0; turn < maxTurnCount; turn++) {
      if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
      if (isCancelled != null && await isCancelled!()) {
        cancelToken?.cancel();
        throw const LlmStoppedException();
      }
      final systemPromptBuilder = this.systemPromptBuilder;
      if (systemPromptBuilder != null) {
        if (messages.isNotEmpty && messages[0]['role'] == 'system') {
          messages[0]['content'] = systemPromptBuilder();
        } else {
          messages.insert(0, {'role': 'system', 'content': systemPromptBuilder()});
        }
      }

      final textObserver = onTextDelta;
      final message = textObserver == null
          ? await _llm.chat(
              messages: messages,
              tools: _registry.all,
              cancelToken: cancelToken,
            )
          : await _llm.chatStream(
              messages: messages,
              tools: _registry.all,
              onTextDelta: textObserver,
              onReasoningDelta: onReasoningDelta,
              onReset: onReset,
              onRetry: onRetry,
              cancelToken: cancelToken,
            );
      if (!message.hasToolCalls) {
        return message.content ?? '';
      }

      messages.add(message.toJson(includeReasoning: true));
      final pendingMediaParts = <Map<String, dynamic>>[];

      // Run stateless read/search tools concurrently for performance;
      // sequence stateful actions (screen navigation, clicks, directory change, app launch).
      final isAnyStateful = message.toolCalls.any(_isStatefulCall);

      final results = <ToolCallResult>[];
      if (isAnyStateful) {
        String? abortReason;
        for (var i = 0; i < message.toolCalls.length; i++) {
          final call = message.toolCalls[i];
          if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
          if (isCancelled != null && await isCancelled!()) {
            cancelToken?.cancel();
            throw const LlmStoppedException();
          }
          // Fail-fast gates DEPENDENT (stateful) followers only: one failure
          // says nothing about stateless siblings (open 3 URLs, first 404s),
          // so they still run. The 'skipped' type keeps these markers
          // distinguishable from real failures in context.
          if (abortReason != null && _isStatefulCall(call)) {
            results.add(
              ToolCallResult.failure(
                call.id,
                'Skipped: previous action in batch failed ($abortReason).',
                type: 'skipped',
              ),
            );
            continue;
          }
          if (i > 0 && !_prevAlreadySettled(message, results, i)) {
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }
          final res = await _registry.execute(call);
          results.add(res);
          if (!res.ok) {
            abortReason ??= res.errorMessage ?? (res.output.isNotEmpty ? res.output : 'unknown error');
          }
        }
      } else {
        if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
        if (isCancelled != null && await isCancelled!()) {
          cancelToken?.cancel();
          throw const LlmStoppedException();
        }
        results.addAll(
          await Future.wait(
            message.toolCalls.map((call) => _registry.execute(call)),
          ),
        );
      }

      for (var i = 0; i < message.toolCalls.length; i++) {
        final call = message.toolCalls[i];
        final result = results[i];
        onEvent?.call(
          AgentToolCall(
            call,
            result,
            reasoning: message.reasoning,
            reasoningDetails: message.reasoningDetails,
          ),
        );
        messages.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': clampResultText(result.toText()),
        });

        if (!result.ok) {
          if (lastFailedCall != null && _isSameToolCall(call, lastFailedCall)) {
            consecutiveSameErrorCount++;
          } else {
            lastFailedCall = call;
            consecutiveSameErrorCount = 1;
          }
          if (consecutiveSameErrorCount >= maxConsecutiveSameToolErrors) {
            throw RepeatedToolFailureException(call, consecutiveSameErrorCount);
          }
        } else {
          lastFailedCall = null;
          consecutiveSameErrorCount = 0;
        }

        // Media content parts can't ride the tool role portably across
        // providers — deliver them as a user message after this batch.
        final parts = result.contentParts;
        if (parts != null && parts.isNotEmpty) {
          for (final part in parts) {
            // Guard against sending image_url to models that cannot accept images (prevents HTTP 400/500)
            if (part['type'] == 'image_url' && supportsInput?.call('image') == false) {
              continue;
            }
            pendingMediaParts.add(part);
          }
        }
      }
      if (pendingMediaParts.isNotEmpty) {
        messages.add({
          'role': 'user',
          'content': [
            const {
              'type': 'text',
              'text':
                  '[Media file(s) you just read via a tool are attached above '
                  'for your analysis.]',
            },
            ...pendingMediaParts,
          ],
        });
      }

      // Mid-chat/mid-step compaction: if tool results + model thinking crossed
      // the context budget, compact immediately before the next thinking/tool step.
      await _compactIfNeeded(messages);
    }

    return 'Reached $maxTurnCount tool-call turns without a final answer.';
  }

  /// True for calls that mutate shared state (screen, foreground app,
  /// working directory, or browser WebView): they must run in order, never concurrently.
  /// Launches count — an `open_app` changes what subsequent screen reads see.
  /// Browser calls all operate on a single shared WebView and must run sequentially.
  static bool _isStatefulCall(ToolCall call) {
    if (call.name == 'act' || call.name == 'screen_act') return true;
    if (call.name == 'intent') return true;
    if (call.name == 'bash') return true;
    if (call.name == 'save_report') return true;
    if (call.name == 'workspace' && call.arguments['action'] == 'cd') return true;
    if (call.name == 'screen' && call.arguments['action'] == 'global') return true;
    if (call.name == 'browser' ||
        call.name.startsWith('browser.') ||
        call.name == 'extract_text' ||
        call.name.startsWith('extract_text.')) {
      return true;
    }
    return false;
  }

  /// True when the previous batch call already waited for the screen to
  /// settle: `act` / `screen_act` + `then_read:true` (or `grep`, which implies then_read)
  /// sleeps 1000ms and re-reads internally on success, so stacking another
  /// 350ms inter-call settle just idles.
  static bool _prevAlreadySettled(
    LlmMessage message,
    List<ToolCallResult> results,
    int i,
  ) {
    if (!results[i - 1].ok) return false;
    final prev = message.toolCalls[i - 1];
    if (prev.name != 'act' && prev.name != 'screen_act') return false;
    if (prev.arguments['then_read'] == true) return true;
    final grep = (prev.arguments['grep'] as String?)?.trim();
    return grep != null && grep.isNotEmpty;
  }

  /// Compares whether two [ToolCall]s represent the same tool invocation.
  static bool _isSameToolCall(ToolCall a, ToolCall b) {
    if (a.name != b.name) return false;
    return _areArgumentsEqual(a.arguments, b.arguments);
  }

  /// Deep structural equality for tool arguments (maps, lists, strings, numbers, booleans).
  static bool _areArgumentsEqual(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key)) return false;
        if (!_areArgumentsEqual(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_areArgumentsEqual(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is String && b is String) {
      return a.trim() == b.trim();
    }
    if (a is num && b is num) {
      return a == b;
    }
    return a == b;
  }

  Future<void> _compactIfNeeded(List<Map<String, dynamic>> messages) async {
    final currentTokens = estimateLlmMessagesTokens(messages);
    if (!budget.shouldCompact(currentTokens)) return;

    var start = 0;
    Map<String, dynamic>? systemMsg;
    if (messages.isNotEmpty && messages.first['role'] == 'system') {
      systemMsg = messages.first;
      start = 1;
    }

    final nonSystem = messages.sublist(start);
    if (nonSystem.length < 2) return;

    // Group into atomic blocks (never separating assistant tool calls from tool results or synthetic media)
    final blocks = <List<Map<String, dynamic>>>[];
    var i = 0;
    while (i < nonSystem.length) {
      final msg = nonSystem[i];
      final toolCalls = msg['tool_calls'];
      if (msg['role'] == 'assistant' && toolCalls is List && toolCalls.isNotEmpty) {
        final block = <Map<String, dynamic>>[msg];
        var j = i + 1;
        while (j < nonSystem.length && nonSystem[j]['role'] == 'tool') {
          block.add(nonSystem[j]);
          j++;
        }
        while (j < nonSystem.length && isSyntheticMediaMessage(nonSystem[j])) {
          block.add(nonSystem[j]);
          j++;
        }
        blocks.add(block);
        i = j;
      } else {
        blocks.add([msg]);
        i++;
      }
    }

    if (blocks.length < 2) return;

    // Determine how many recent blocks to retain in the tail.
    // Step down keepCount until tailTokens fits within targetTokens, ensuring
    // we keep at least 1 tail block so the ongoing active turn is never lost.
    var keepCount = blocks.length >= 4 ? 2 : 1;
    var tailBlocks = blocks.sublist(blocks.length - keepCount);
    var tailTokens = estimateLlmMessagesTokens([for (final b in tailBlocks) ...b]);

    while (keepCount > 1 && tailTokens > budget.targetTokens) {
      keepCount--;
      tailBlocks = blocks.sublist(blocks.length - keepCount);
      tailTokens = estimateLlmMessagesTokens([for (final b in tailBlocks) ...b]);
    }

    final compactBlocks = blocks.sublist(0, blocks.length - keepCount);
    if (compactBlocks.isEmpty) return;

    final toCompact = <Map<String, dynamic>>[
      for (final b in compactBlocks) ...b,
    ];
    var tail = <Map<String, dynamic>>[
      for (final b in tailBlocks) ...b,
    ];
    // keepCount floors at 1 block, but one block of multi-KB tool results
    // can still exceed small-window targets — trim contents, never blocks.
    tail = fitTailToTarget(tail, budget);

    onEvent?.call(const AgentCompacting());

    String summary;
    try {
      final compactionPrompt = buildCompactionPrompt(toCompact);
      final response = await _llm
          .chat(
            messages: compactionPrompt,
            cancelToken: cancelToken,
          )
          .timeout(compactionTimeout);
      summary = (response.content ?? '').trim();
      if (summary.isEmpty) {
        summary = buildDeterministicFallbackSummary(toCompact);
      }
    } on LlmStoppedException {
      rethrow;
    } catch (_) {
      summary = buildDeterministicFallbackSummary(toCompact);
    }

    final compacted = applyCompactedHistory(
      systemMessage: systemMsg ?? const {'role': 'system', 'content': 'You are a helpful assistant.'},
      summary: summary,
      tailMessages: tail,
    );

    messages
      ..clear()
      ..addAll(compacted);

    onCompacted?.call(summary);
    onEvent?.call(AgentCompacted(summary, tailBlockCount: keepCount));
  }

  List<Map<String, dynamic>> _toLlmHistory(List<Message> history) {
    final messages = <Map<String, dynamic>>[];

    // If history contains a CompactedNoticeMessage, older messages prior to it
    // were already summarized. Start from the latest CompactedNoticeMessage.
    final lastCompactedIdx =
        history.lastIndexWhere((m) => m is CompactedNoticeMessage);
    final effectiveHistory = lastCompactedIdx != -1
        ? history.sublist(lastCompactedIdx)
        : history;

    for (var index = 0; index < effectiveHistory.length; index++) {
      final message = effectiveHistory[index];
      if (message.id == 'init') continue;
      switch (message) {
        case CompactedNoticeMessage():
          final summaryContent = message.summary.isNotEmpty
              ? message.summary
              : message.text;
          messages.add({
            'role': 'user',
            'content': '$kCompactedContextMarker\n$summaryContent',
          });
          messages.add(const {
            'role': 'assistant',
            'content':
                'I have incorporated the compacted conversation history and previous tool execution state. '
                'Continuing with the task.',
          });
        case UserMessage():
          final text = message.text.trim();
          final content = text.isNotEmpty
              ? text
              : (message.attachedUris.isNotEmpty
                  ? '[User uploaded attached file(s)]'
                  : '');
          if (content.isNotEmpty) {
            messages.add({'role': 'user', 'content': content});
          }
        case AssistantMessage():
          // If immediately followed by ToolMessages, merge this assistant's text
          // into the assistant tool_calls message to prevent consecutive assistant messages.
          if (index + 1 < effectiveHistory.length &&
              effectiveHistory[index + 1] is ToolMessage) {
            final toolMessages = <ToolMessage>[];
            var j = index + 1;
            while (j < effectiveHistory.length &&
                effectiveHistory[j] is ToolMessage) {
              toolMessages.add(effectiveHistory[j] as ToolMessage);
              j++;
            }
            index = j - 1;

            messages.add({
              'role': 'assistant',
              if (message.text.isNotEmpty) 'content': message.text,
              if (toolMessages.first.reasoning != null &&
                  toolMessages.first.reasoning!.isNotEmpty)
                'reasoning': toolMessages.first.reasoning,
              if (toolMessages.first.reasoningDetails.isNotEmpty)
                'reasoning_details': toolMessages.first.reasoningDetails,
              'tool_calls': [
                for (final toolMessage in toolMessages)
                  {
                    'id': toolMessage.id,
                    'type': 'function',
                    'function': {
                      'name': toolMessage.tool.name,
                      'arguments': jsonEncode(toolMessage.tool.args),
                    },
                  },
              ],
            });
            messages.addAll([
              for (final toolMessage in toolMessages)
                {
                  'role': 'tool',
                  'tool_call_id': toolMessage.id,
                  'content': toolMessage.result,
                },
            ]);
          } else {
            messages.add({'role': 'assistant', 'content': message.text});
          }
        case ErrorMessage():
          messages.add({
            'role': 'user',
            'content': 'Previous app error: ${message.error}',
          });
        case ToolMessage():
          final toolMessages = <ToolMessage>[message];
          while (index + 1 < effectiveHistory.length &&
              effectiveHistory[index + 1] is ToolMessage) {
            index++;
            toolMessages.add(effectiveHistory[index] as ToolMessage);
          }

          messages.add({
            'role': 'assistant',
            if (toolMessages.first.reasoning != null &&
                toolMessages.first.reasoning!.isNotEmpty)
              'reasoning': toolMessages.first.reasoning,
            if (toolMessages.first.reasoningDetails.isNotEmpty)
              'reasoning_details': toolMessages.first.reasoningDetails,
            'tool_calls': [
              for (final toolMessage in toolMessages)
                {
                  'id': toolMessage.id,
                  'type': 'function',
                  'function': {
                    'name': toolMessage.tool.name,
                    'arguments': jsonEncode(toolMessage.tool.args),
                  },
                },
            ],
          });
          messages.addAll([
            for (final toolMessage in toolMessages)
              {
                'role': 'tool',
                'tool_call_id': toolMessage.id,
                'content': toolMessage.result,
              },
          ]);
      }
    }

    return messages;
  }
}
