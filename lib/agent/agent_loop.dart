import 'dart:convert';

import '../llm/llm_client.dart';
import '../types/conversation.dart';
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
  static const int maxTurns = 12;

  final LlmClient _llm;
  final ToolRegistry _registry;
  final AgentObserver? _onEvent;
  final AgentTextObserver? onTextDelta;
  final AgentReasoningObserver? onReasoningDelta;

  AgentLoop({
    required this._llm,
    required this._registry,
    this._onEvent,
    this.onTextDelta,
    this.onReasoningDelta,
  });

  Future<String> run(Conversation conversation) async {
    final messages = <Map<String, dynamic>>[
      if (conversation.localSystemPrompt != null)
        {'role': 'system', 'content': conversation.localSystemPrompt},
      ..._toLlmHistory(conversation.messages),
    ];

    for (var turn = 0; turn < maxTurns; turn++) {
      final textObserver = onTextDelta;
      final message = textObserver == null
          ? await _llm.chat(messages: messages, tools: _registry.all)
          : await _llm.chatStream(
              messages: messages,
              tools: _registry.all,
              onTextDelta: textObserver,
              onReasoningDelta: onReasoningDelta,
            );
      if (!message.hasToolCalls) {
        return message.content ?? '';
      }

      messages.add(message.toJson());
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
          'content': result.toText(),
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
          messages.add({'role': 'user', 'content': message.text});
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
