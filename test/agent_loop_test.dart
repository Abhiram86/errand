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

  test('AgentLoop treats browser calls and extract_text as stateful and runs them sequentially', () async {
    final mockLlm = MockLlmClient();
    final executionOrder = <String>[];

    final browserTool = Tool(
      name: 'browser',
      description: 'browser tool',
      parameters: const {},
      handler: (c) async {
        final action = c.arguments['action'] as String? ?? 'open';
        executionOrder.add('browser.$action');
        return ToolCallResult(id: c.id, ok: true, output: 'ok');
      },
    );

    final extractTool = Tool(
      name: 'extract_text',
      description: 'extract tool',
      parameters: const {},
      handler: (c) async {
        executionOrder.add('extract_text');
        return ToolCallResult(id: c.id, ok: true, output: 'text');
      },
    );

    final registry = ToolRegistry([browserTool, extractTool]);
    final loop = AgentLoop(llm: mockLlm, registry: registry);

    var turn = 0;
    mockLlm.onChat = (messages) {
      turn++;
      if (turn == 1) {
        return const LlmMessage(
          content: null,
          toolCalls: [
            ToolCall(id: 'c1', name: 'browser', arguments: {'action': 'open'}),
            ToolCall(id: 'c2', name: 'browser', arguments: {'action': 'snapshot'}),
            ToolCall(id: 'c3', name: 'extract_text', arguments: {}),
          ],
        );
      }
      return const LlmMessage(content: 'Sequence finished');
    };

    final result = await loop.run(
      Conversation(
        id: 'c-seq',
        messages: [const UserMessage(id: 'u1', text: 'browse and extract')],
        currentDir: Directory('/'),
      ),
    );

    expect(result, equals('Sequence finished'));
    expect(executionOrder, equals(['browser.open', 'browser.snapshot', 'extract_text']));
  });

  test('AgentLoop skips stateful followers after a batch failure with a typed marker', () async {
    final mockLlm = MockLlmClient();
    var firstExecuted = false;
    var secondExecuted = false;
    final seenResults = <ToolCallResult>[];

    final actTool = Tool(
      name: 'act',
      description: 'stateful act tool',
      parameters: const {},
      handler: (c) async {
        firstExecuted = true;
        return ToolCallResult.failure(c.id, 'Element not found');
      },
    );

    // Stateful follower (screen global): must be skipped, not attempted.
    final follower = Tool(
      name: 'screen',
      description: 'stateful screen tool',
      parameters: const {},
      handler: (c) async {
        secondExecuted = true;
        return ToolCallResult(id: c.id, ok: true, output: 'should not run');
      },
    );

    final registry = ToolRegistry([actTool, follower]);
    final loop = AgentLoop(
      llm: mockLlm,
      registry: registry,
      onEvent: (event) {
        if (event is AgentToolCall) seenResults.add(event.result);
      },
    );

    var turn = 0;
    mockLlm.onChat = (messages) {
      turn++;
      if (turn == 1) {
        return const LlmMessage(
          content: null,
          toolCalls: [
            ToolCall(id: 'c1', name: 'act', arguments: {'action': 'tap'}),
            ToolCall(id: 'c2', name: 'screen', arguments: {'action': 'global'}),
          ],
        );
      }
      return const LlmMessage(content: 'Done after failure');
    };

    final conversation = Conversation(
      id: 'c3',
      messages: [UserMessage(id: 'u1', text: 'tap then go back')],
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
    expect(toolMsgs[1]['content'], contains('Skipped: previous action in batch failed'));
    // Typed marker: distinguishable from a real failure in context.
    expect(seenResults.length, 2);
    expect(seenResults[1].error?.type, 'skipped');
  });

  test('AgentLoop still runs stateless siblings after a batch failure', () async {
    final mockLlm = MockLlmClient();
    var failedExecuted = false;
    var siblingExecuted = false;

    final failing = Tool(
      name: 'act',
      description: 'stateful act tool',
      parameters: const {},
      handler: (c) async {
        failedExecuted = true;
        return ToolCallResult.failure(c.id, 'Element not found');
      },
    );

    final sibling = Tool(
      name: 'websearch',
      description: 'stateless sibling',
      parameters: const {},
      handler: (c) async {
        siblingExecuted = true;
        return ToolCallResult(id: c.id, ok: true, output: 'sibling result');
      },
    );

    final registry = ToolRegistry([failing, sibling]);
    final loop = AgentLoop(llm: mockLlm, registry: registry);

    var turn = 0;
    mockLlm.onChat = (messages) {
      turn++;
      if (turn == 1) {
        return const LlmMessage(
          content: null,
          toolCalls: [
            ToolCall(id: 'c1', name: 'act', arguments: {'action': 'tap'}),
            ToolCall(id: 'c2', name: 'websearch', arguments: {'query': 'x'}),
          ],
        );
      }
      return const LlmMessage(content: 'Done with partial failure');
    };

    final conversation = Conversation(
      id: 'c4',
      messages: [UserMessage(id: 'u1', text: 'tap and search')],
      currentDir: Directory('/'),
    );

    final result = await loop.run(conversation);
    expect(result, 'Done with partial failure');
    expect(failedExecuted, isTrue);
    // Stateless sibling attempted despite the earlier failure — no skip marker.
    expect(siblingExecuted, isTrue);

    final secondTurnMsgs = mockLlm.receivedMessages[1];
    final toolMsgs = secondTurnMsgs.where((m) => m['role'] == 'tool').toList();
    expect(toolMsgs.length, 2);
    expect(toolMsgs[1]['content'], contains('sibling result'));
  });

  test('AgentLoop skips the inter-call settle after act then_read', () async {
    Future<int> runBatch(bool thenRead) async {
      final mockLlm = MockLlmClient();
      final instantAct = Tool(
        name: 'act',
        description: 'instant stateful tool',
        parameters: const {},
        handler: (c) async => ToolCallResult(id: c.id, ok: true, output: 'tapped'),
      );
      final loop = AgentLoop(llm: mockLlm, registry: ToolRegistry([instantAct]));
      var turn = 0;
      mockLlm.onChat = (messages) {
        turn++;
        if (turn == 1) {
          return LlmMessage(
            content: null,
            toolCalls: [
              ToolCall(id: 'c1', name: 'act', arguments: {
                'action': 'tap',
                if (thenRead) 'then_read': true,
              }),
              const ToolCall(id: 'c2', name: 'act', arguments: {'action': 'tap'}),
            ],
          );
        }
        return const LlmMessage(content: 'done');
      };
      final sw = Stopwatch()..start();
      await loop.run(
        Conversation(
          id: 'c-settle',
          messages: [UserMessage(id: 'u1', text: 'tap twice')],
          currentDir: Directory('/'),
        ),
      );
      sw.stop();
      return sw.elapsedMilliseconds;
    }

    final controlMs = await runBatch(false);
    // Hard floor: the control pays one 350ms inter-call settle.
    expect(controlMs, greaterThanOrEqualTo(350));
    final skippedMs = await runBatch(true);
    // then_read already settled internally — wide moat under the 350ms floor.
    expect(skippedMs, lessThan(300));
  });

  test('UserMessage with attachments serializes clean text without leaking raw file paths', () async {
    final client = MockLlmClient();
    final loop = AgentLoop(
      llm: client,
      registry: ToolRegistry([]),
    );

    await loop.run(
      Conversation(
        id: 'c-attach',
        messages: [
          const UserMessage(
            id: 'u1',
            text: 'Analyze this file',
            attachedUris: ['/storage/emulated/0/Download/invoice.pdf'],
          ),
        ],
        currentDir: Directory('/'),
      ),
    );

    expect(client.receivedMessages, isNotEmpty);
    final capturedMessages = client.receivedMessages.first;
    final userMsg = capturedMessages.firstWhere((m) => m['role'] == 'user');
    expect(userMsg['content'], 'Analyze this file');
    expect(userMsg['content'], isNot(contains('/storage/emulated/0')));
  });

  test('UserMessage with empty text and attachments provides a clear uploaded placeholder', () async {
    final client = MockLlmClient();
    final loop = AgentLoop(
      llm: client,
      registry: ToolRegistry([]),
    );

    await loop.run(
      Conversation(
        id: 'c-attach-empty',
        messages: [
          const UserMessage(
            id: 'u1',
            text: '',
            attachedUris: ['/storage/emulated/0/Download/photo.jpg'],
          ),
        ],
        currentDir: Directory('/'),
      ),
    );

    expect(client.receivedMessages, isNotEmpty);
    final capturedMessages = client.receivedMessages.first;
    final userMsg = capturedMessages.firstWhere((m) => m['role'] == 'user');
    expect(userMsg['content'], '[User uploaded attached file(s)]');
  });

  group('Repeated tool error loop guard', () {
    test('aborts with RepeatedToolFailureException on 3 consecutive same tool errors', () async {
      final client = MockLlmClient();
      final cancelToken = CancelToken();

      final failingTool = Tool(
        name: 'failing_tool',
        description: 'Always fails',
        parameters: const {
          'type': 'object',
          'properties': {
            'action': {'type': 'string'},
          },
        },
        handler: (call) async => ToolCallResult.failure(call.id, 'Tool failed'),
      );

      final registry = ToolRegistry([failingTool]);
      final loop = AgentLoop(
        llm: client,
        registry: registry,
        cancelToken: cancelToken,
      );

      var turnCount = 0;
      client.onChat = (_) {
        turnCount++;
        return LlmMessage(
          content: 'Calling tool attempt $turnCount',
          toolCalls: [
            ToolCall(
              id: 'call_$turnCount',
              name: 'failing_tool',
              arguments: const {'action': 'do_something'},
            ),
          ],
        );
      };

      await expectLater(
        loop.run(
          Conversation(
            id: 'c-loop',
            messages: [const UserMessage(id: 'u1', text: 'Run loop')],
            currentDir: Directory('/'),
          ),
        ),
        throwsA(isA<RepeatedToolFailureException>()),
      );

      expect(turnCount, equals(3));
      expect(cancelToken.isCancelled, isFalse);
    });

    test('breaks consecutive failure streak if a successful tool call occurs', () async {
      final client = MockLlmClient();
      final cancelToken = CancelToken();

      var toolCallCount = 0;
      final dynamicTool = Tool(
        name: 'dynamic_tool',
        description: 'Fails 2 times, succeeds once, then returns final',
        parameters: const {'type': 'object'},
        handler: (call) async {
          toolCallCount++;
          if (toolCallCount == 3) {
            return ToolCallResult(id: call.id, ok: true, output: 'Success on 3rd attempt');
          }
          return ToolCallResult.failure(call.id, 'Failure #$toolCallCount');
        },
      );

      final registry = ToolRegistry([dynamicTool]);
      final loop = AgentLoop(
        llm: client,
        registry: registry,
        cancelToken: cancelToken,
      );

      var turnCount = 0;
      client.onChat = (_) {
        turnCount++;
        if (turnCount > 3) {
          return const LlmMessage(content: 'All done successfully');
        }
        return LlmMessage(
          content: 'Attempt $turnCount',
          toolCalls: [
            ToolCall(
              id: 'call_$turnCount',
              name: 'dynamic_tool',
              arguments: const {'key': 'val'},
            ),
          ],
        );
      };

      final result = await loop.run(
        Conversation(
          id: 'c-break',
          messages: [const UserMessage(id: 'u1', text: 'Try dynamic')],
          currentDir: Directory('/'),
        ),
      );

      expect(result, equals('All done successfully'));
      expect(cancelToken.isCancelled, isFalse);
    });

    test('resets streak if subsequent failing tool call has different name or arguments', () async {
      final client = MockLlmClient();
      final cancelToken = CancelToken();

      final toolA = Tool(
        name: 'tool_a',
        description: 'Tool A',
        parameters: const {'type': 'object'},
        handler: (call) async => ToolCallResult.failure(call.id, 'Error A'),
      );
      final toolB = Tool(
        name: 'tool_b',
        description: 'Tool B',
        parameters: const {'type': 'object'},
        handler: (call) async => ToolCallResult.failure(call.id, 'Error B'),
      );

      final registry = ToolRegistry([toolA, toolB]);
      final loop = AgentLoop(
        llm: client,
        registry: registry,
        cancelToken: cancelToken,
      );

      var turnCount = 0;
      client.onChat = (_) {
        turnCount++;
        if (turnCount > 8) {
          return const LlmMessage(content: 'Finished after alternating failures');
        }
        final toolName = turnCount % 2 == 1 ? 'tool_a' : 'tool_b';
        return LlmMessage(
          content: 'Attempt $turnCount',
          toolCalls: [
            ToolCall(
              id: 'call_$turnCount',
              name: toolName,
              arguments: const {},
            ),
          ],
        );
      };

      final result = await loop.run(
        Conversation(
          id: 'c-alt',
          messages: [const UserMessage(id: 'u1', text: 'Alternate tools')],
          currentDir: Directory('/'),
        ),
      );

      expect(result, equals('Finished after alternating failures'));
      expect(cancelToken.isCancelled, isFalse);
    });
  });
}


