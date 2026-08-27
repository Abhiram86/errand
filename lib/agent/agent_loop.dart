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
  static const int maxTurns = 18;

  final LlmClient _llm;
  final ToolRegistry _registry;
  final String Function()? systemPromptBuilder;

  /// Set by the UI stop button; checked at every turn boundary and between
  /// SSE events. Throws [LlmStoppedException] at the next safe boundary.
  final CancelToken? cancelToken;
  final AgentObserver? _onEvent;
  final AgentTextObserver? onTextDelta;
  final AgentReasoningObserver? onReasoningDelta;

  AgentLoop({
    required this._llm,
    required this._registry,
    this.systemPromptBuilder,
    this.cancelToken,
    this._onEvent,
    this.onTextDelta,
    this.onReasoningDelta,
  });

  Future<String> run(Conversation conversation) async {
    // OPT-07: the LLM payload is truncated to the context budget here, at
    // the boundary. The full history stays intact on the Conversation for
    // persistence and UI rendering.
    final history = truncateHistory(conversation.messages);
    final messages = <Map<String, dynamic>>[
      if (conversation.localSystemPrompt != null)
        {'role': 'system', 'content': conversation.localSystemPrompt},
      ..._toLlmHistory(history),
    ];

    for (var turn = 0; turn < maxTurns; turn++) {
      if (cancelToken?.isCancelled ?? false) throw const LlmStoppedException();
      final systemPromptBuilder = this.systemPromptBuilder;
      if (systemPromptBuilder != null) {
        if (messages.isNotEmpty && messages[0]['role']=='system') {
          messages[0]['content'] = systemPromptBuilder();
        } else {
          messages.insert(0, {'role': 'system', 'content': systemPromptBuilder()});
        }
      }


      final textObserver = onTextDelta;
      // Mid-loop guard: results appended during this turn bypass
      // truncateHistory(), so re-trim before every request. Cheap (length
      // sums only) and a no-op under the soft limit.
      final trimmed = trimLlmMessages(messages);
      if (!identical(trimmed, messages)) {
        messages
          ..clear()
          ..addAll(trimmed);
      }
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

      messages.add(message.toJson());
      final pendingMediaParts = <Map<String, dynamic>>[];
      for (final call in message.toolCalls) {
        final result = await _registry.execute(call);
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
    }

    return 'Reached $maxTurns tool-call turns without a final answer.';
  }

  List<Map<String, dynamic>> _toLlmHistory(List<Message> history) {
    final messages = <Map<String, dynamic>>[];

    for (var index = 0; index < history.length; index++) {
      final message = history[index];
      switch (message) {
        case UserMessage():
          final content = message.attachedUris.isEmpty
              ? message.text
              : '${message.text}\n\n[Attached files:\n${[
                  for (var i = 0; i < message.attachedUris.length; i++)
                    '${i + 1}. ${path.basename(message.attachedUris[i])} — ${message.attachedUris[i]}',
                ].join('\n')}]';
          messages.add({'role': 'user', 'content': content});
        case AssistantMessage():
          messages.add({'role': 'assistant', 'content': message.text});
        case ErrorMessage():
          messages.add({
            'role': 'user',
            'content': 'Previous app error: ${message.error}',
          });
        case ToolMessage():
          final toolMessages = <ToolMessage>[message];
          while (index + 1 < history.length &&
              history[index + 1] is ToolMessage) {
            index++;
            toolMessages.add(history[index] as ToolMessage);
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
