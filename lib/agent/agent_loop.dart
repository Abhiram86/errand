import 'dart:convert';

import '../llm/llm_client.dart';
import '../types/conversation.dart';
import '../types/message.dart';
import '../types/tool.dart';
import 'tool.dart';
import 'tool_registry.dart';

typedef AgentObserver = void Function(AgentEvent event);
typedef AgentTextObserver = void Function(String delta);

sealed class AgentEvent {
  const AgentEvent();
}

class AgentTurn extends AgentEvent {
  final LlmMessage message;
  const AgentTurn(this.message);
}

class AgentToolCall extends AgentEvent {
  final ToolCall call;
  final ToolCallResult result;
  const AgentToolCall(this.call, this.result);
}

class AgentLoop {
  static const int maxTurns = 12;

  final LlmClient _llm;
  final ToolRegistry _registry;
  final AgentObserver? _onEvent;
  final AgentTextObserver? onTextDelta;

  AgentLoop({
    required this._llm,
    required this._registry,
    this._onEvent,
    this.onTextDelta,
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
            );
      _onEvent?.call(AgentTurn(message));

      if (!message.hasToolCalls) {
        return message.content ?? '';
      }

      messages.add(message.toJson());
      for (final call in message.toolCalls) {
        final result = await _registry.execute(call);
        _onEvent?.call(AgentToolCall(call, result));
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
      if (message is! ToolMessage) {
        messages.addAll(_toLlmMessages(message));
        continue;
      }

      final toolMessages = <ToolMessage>[message];
      while (index + 1 < history.length && history[index + 1] is ToolMessage) {
        index++;
        toolMessages.add(history[index] as ToolMessage);
      }

      messages.add({
        'role': 'assistant',
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

    return messages;
  }

  /// Converts app messages into the OpenAI-compatible chat history format.
  /// Tool messages expand into the assistant tool call and its matching result.
  List<Map<String, dynamic>> _toLlmMessages(Message message) {
    switch (message) {
      case UserMessage():
        return [
          {'role': 'user', 'content': message.text},
        ];
      case AssistantMessage():
        return [
          {'role': 'assistant', 'content': message.text},
        ];
      case ToolMessage():
        return [
          {
            'role': 'assistant',
            'tool_calls': [
              {
                'id': message.id,
                'type': 'function',
                'function': {
                  'name': message.tool.name,
                  'arguments': jsonEncode(message.tool.args),
                },
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': message.id,
            'content': message.result,
          },
        ];
      case ErrorMessage():
        return [
          {'role': 'user', 'content': 'Previous app error: ${message.error}'},
        ];
    }
  }
}
