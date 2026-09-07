import 'dart:convert';

import 'package:path/path.dart' as path;

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

class AgentLoop {
  static const int defaultMaxTurns = 72;
  static const int maxTurns = defaultMaxTurns;

  /// Upper bound for one compaction round-trip. The inner `chat` call
  /// retries internally, so without this cap a saturated endpoint wedges the
  /// turn for minutes before the deterministic fallback runs. Firing maps to
  /// the fallback summary via the generic catch below (never a throw).
  static const Duration defaultCompactionTimeout = Duration(seconds: 60);

  final LlmClient _llm;
  final ToolRegistry _registry;
  final ContextBudget budget;
  final int maxTurnCount;
  final Duration compactionTimeout;
  final String Function()? systemPromptBuilder;

  /// Set by the UI stop button; checked at every turn boundary and between
  /// SSE events. Throws [LlmStoppedException] at the next safe boundary.
  final CancelToken? cancelToken;
  final AgentObserver? _onEvent;
  final AgentTextObserver? onTextDelta;
  final AgentReasoningObserver? onReasoningDelta;
  final void Function(String summary)? onCompacted;

  AgentLoop({
    required this._llm,
    required this._registry,
    ContextBudget? budget,
    int? modelContextSize,
    int? maxTurns,
    Duration? compactionTimeout,
    this.systemPromptBuilder,
    this.cancelToken,
    this._onEvent,
    this.onTextDelta,
    this.onReasoningDelta,
    this.onCompacted,
  })  : budget = budget ??
            (modelContextSize != null
                ? ContextBudget(contextSize: modelContextSize)
                : ContextBudget.defaultBudget),
        maxTurnCount = maxTurns ?? defaultMaxTurns,
        compactionTimeout = compactionTimeout ?? defaultCompactionTimeout;

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

    for (var turn = 0; turn < maxTurnCount; turn++) {
      if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
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
              cancelToken: cancelToken,
            );
      if (!message.hasToolCalls) {
        return message.content ?? '';
      }

      messages.add(message.toJson(includeReasoning: true));
      final pendingMediaParts = <Map<String, dynamic>>[];

      // Run stateless read/search tools concurrently for performance;
      // sequence stateful actions (screen navigation, clicks, directory change).
      final isAnyStateful = message.toolCalls.any((call) {
        if (call.name == 'act') return true;
        if (call.name == 'workspace' && call.arguments['action'] == 'cd') return true;
        if (call.name == 'screen' && call.arguments['action'] == 'global') return true;
        return false;
      });

      final results = isAnyStateful
          ? <ToolCallResult>[
              for (final call in message.toolCalls) await _registry.execute(call),
            ]
          : await Future.wait(
              message.toolCalls.map((call) => _registry.execute(call)),
            );

      for (var i = 0; i < message.toolCalls.length; i++) {
        final call = message.toolCalls[i];
        final result = results[i];
        _onEvent?.call(
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
        // Media content parts can't ride the tool role portably across
        // providers — deliver them as a user message after this batch.
        pendingMediaParts.addAll(result.contentParts ?? const []);
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

    _onEvent?.call(const AgentCompacting());

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
    _onEvent?.call(AgentCompacted(summary, tailBlockCount: keepCount));
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
          final content = message.attachedUris.isEmpty
              ? message.text
              : '${message.text}\n\n[Attached files:\n${[
                  for (var i = 0; i < message.attachedUris.length; i++)
                    '${i + 1}. ${path.basename(message.attachedUris[i])} — ${message.attachedUris[i]}',
                ].join('\n')}]';
          messages.add({'role': 'user', 'content': content});
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
