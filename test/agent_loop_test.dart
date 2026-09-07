import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/agent_loop.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/llm/llm_client.dart';
import 'package:errand/types/conversation.dart';
import 'package:errand/types/message.dart';
import 'package:errand/types/tool.dart';

class MockLlmClient extends LlmClient {
  final List<List<Map<String, dynamic>>> receivedMessages = [];
  LlmMessage Function(List<Map<String, dynamic>> messages)? onChat;

  MockLlmClient()
      : super(
          config: const LlmConfig(
            baseUrl: 'https://example.com',
            apiKey: 'key',
            model: 'model',
          ),
        );

  @override
  Future<LlmMessage> chat({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    CancelToken? cancelToken,
  }) async {
    receivedMessages.add(List<Map<String, dynamic>>.from(messages));
    if (onChat != null) {
      return onChat!(messages);
    }
    return const LlmMessage(content: 'Final response');
  }
}

void main() {
  test('AgentLoop merges AssistantMessage with subsequent ToolMessage into a single assistant turn', () async {
    final mockLlm = MockLlmClient();
    final registry = ToolRegistry([]);
    final loop = AgentLoop(llm: mockLlm, registry: registry);

    final history = [
      UserMessage(id: 'u1', text: 'Read the file'),
      AssistantMessage(id: 'a1', text: 'Sure, reading it now...'),
      ToolMessage(
        id: 't1',
        text: 'read -> done',
        tool: const ToolInvocation(name: 'read', args: {'path': 'sample.txt'}),
        result: 'sample file content',
      ),
      UserMessage(id: 'u2', text: 'Now summarize'),
    ];

    final conversation = Conversation(
      id: 'c1',
      messages: history,
      currentDir: Directory('/'),
    );

    await loop.run(conversation);

    expect(mockLlm.receivedMessages, isNotEmpty);
    final sent = mockLlm.receivedMessages.first;

    // Roles must be: user, assistant (with content AND tool_calls), tool, user
    final roles = sent.map((m) => m['role']).toList();
    expect(roles, ['user', 'assistant', 'tool', 'user']);

    final assistantMsg = sent[1];
    expect(assistantMsg['content'], 'Sure, reading it now...');
    expect(assistantMsg['tool_calls'], isNotEmpty);
    final toolCall = (assistantMsg['tool_calls'] as List).first as Map<String, dynamic>;
    expect(toolCall['id'], 't1');
  });

  test('AgentLoop runs multiple stateless tool calls concurrently', () async {
    final mockLlm = MockLlmClient();
    var firstExecuted = false;
    var secondExecuted = false;

    final tool1 = Tool(
      name: 'tool_one',
      description: 'stateless tool 1',
      parameters: const {},
      handler: (c) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        firstExecuted = true;
        return ToolCallResult(id: c.id, ok: true, output: 'one');
      },
    );

    final tool2 = Tool(
      name: 'tool_two',
      description: 'stateless tool 2',
      parameters: const {},
      handler: (c) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        secondExecuted = true;
        return ToolCallResult(id: c.id, ok: true, output: 'two');
      },
    );

    final registry = ToolRegistry([tool1, tool2]);
    final loop = AgentLoop(llm: mockLlm, registry: registry);

    var turn = 0;
    mockLlm.onChat = (messages) {
      turn++;
      if (turn == 1) {
        return const LlmMessage(
          content: null,
          toolCalls: [
            ToolCall(id: 'c1', name: 'tool_one', arguments: {}),
            ToolCall(id: 'c2', name: 'tool_two', arguments: {}),
          ],
        );
      }
      return const LlmMessage(content: 'Both completed');
    };

    final conversation = Conversation(
      id: 'c2',
      messages: [UserMessage(id: 'u1', text: 'run both')],
      currentDir: Directory('/'),
    );

    final result = await loop.run(conversation);
    expect(result, 'Both completed');
    expect(firstExecuted, isTrue);
    expect(secondExecuted, isTrue);
  });

  test('AgentLoop short-circuits stateful tool batch when an earlier tool fails', () async {
    final mockLlm = MockLlmClient();
    var firstExecuted = false;
    var secondExecuted = false;

    final actTool = Tool(
      name: 'act',
      description: 'stateful act tool',
      parameters: const {},
      handler: (c) async {
        firstExecuted = true;
        return ToolCallResult.failure(c.id, 'Element not found');
      },
    );

    final secondAct = Tool(
      name: 'second_act',
      description: 'second tool in batch',
      parameters: const {},
      handler: (c) async {
        secondExecuted = true;
        return ToolCallResult(id: c.id, ok: true, output: 'should not run');
      },
    );

    final registry = ToolRegistry([actTool, secondAct]);
    final loop = AgentLoop(llm: mockLlm, registry: registry);

    var turn = 0;
    mockLlm.onChat = (messages) {
      turn++;
      if (turn == 1) {
        return const LlmMessage(
          content: null,
          toolCalls: [
            ToolCall(id: 'c1', name: 'act', arguments: {'action': 'tap'}),
            ToolCall(id: 'c2', name: 'second_act', arguments: {}),
          ],
        );
      }
      return const LlmMessage(content: 'Done after failure');
    };

    final conversation = Conversation(
      id: 'c3',
      messages: [UserMessage(id: 'u1', text: 'tap twice')],
      currentDir: Directory('/'),
    );

    final result = await loop.run(conversation);
    expect(result, 'Done after failure');
    expect(firstExecuted, isTrue);
    expect(secondExecuted, isFalse);

    expect(mockLlm.receivedMessages.length, greaterThanOrEqualTo(2));
    final secondTurnMsgs = mockLlm.receivedMessages[1];
    final toolMsgs = secondTurnMsgs.where((m) => m['role'] == 'tool').toList();
    expect(toolMsgs.length, 2);
    expect(toolMsgs[0]['content'], contains('Element not found'));
    expect(toolMsgs[1]['content'], contains('Aborted: previous action in batch failed'));
  });
}
