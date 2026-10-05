import 'dart:io';

import 'package:errand/agent/agent_loop.dart';
import 'package:errand/agent/agent_runner.dart';
import 'package:errand/agent/task_checkpoint.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/llm/llm_client.dart';
import 'package:errand/tools/file_tools.dart';
import 'package:errand/types/conversation.dart';
import 'package:errand/types/tool.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockLlm extends LlmClient {
  final List<List<Map<String, dynamic>>> turns = [];
  final List<LlmMessage> responses;
  int responseIndex = 0;

  _MockLlm(this.responses)
      : super(
          config: const LlmConfig(
            baseUrl: 'https://example.com',
            apiKey: 'mock-key',
            model: 'mock-model',
          ),
        );

  @override
  Future<LlmMessage> chat({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    CancelToken? cancelToken,
  }) async {
    turns.add(List<Map<String, dynamic>>.from(messages));
    if (responseIndex < responses.length) {
      return responses[responseIndex++];
    }
    return const LlmMessage(content: 'Final completed summary.');
  }

  @override
  Future<LlmMessage> chatStream({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    required void Function(String delta) onTextDelta,
    void Function()? onReasoningDelta,
    void Function()? onReset,
    void Function(int attempt, String reason)? onRetry,
    CancelToken? cancelToken,
  }) async {
    final res = await chat(messages: messages, tools: tools, cancelToken: cancelToken);
    if (res.content != null && res.content!.isNotEmpty) {
      onTextDelta(res.content!);
    }
    return res;
  }
}

void main() {
  late Directory tempDir;
  late Directory scratchDir;
  late Directory workspaceDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('resume_test_');
    scratchDir = Directory('${tempDir.path}/.scratch');
    workspaceDir = Directory('${tempDir.path}/workspace');
    await scratchDir.create(recursive: true);
    await workspaceDir.create(recursive: true);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('AgentLoop Checkpoint & Resume', () {
    test('resumes from initialTurn and initialMessages, invoking onCheckpoint per turn', () async {
      final mockLlm = _MockLlm([
        // Turn 2 response (since we resume from turn 2)
        LlmMessage(
          toolCalls: [
            ToolCall(
              id: 'call_turn2',
              name: 'dummy_tool',
              arguments: const {},
            ),
          ],
        ),
        // Turn 3 response (final answer)
        const LlmMessage(content: 'Successfully resumed and finished.'),
      ]);

      final dummyTool = Tool(
        name: 'dummy_tool',
        description: 'Dummy tool for testing',
        parameters: const {},
        handler: (call) async => ToolCallResult(id: call.id, ok: true, output: 'dummy result'),
      );

      final registry = ToolRegistry([dummyTool]);
      final savedCheckpoints = <int>[];

      final loop = AgentLoop(
        llm: mockLlm,
        registry: registry,
        maxTurns: 5,
        initialTurn: 2,
        initialMessages: [
          {'role': 'system', 'content': 'system prompt'},
          {'role': 'user', 'content': 'do task'},
          {
            'role': 'assistant',
            'tool_calls': [
              {
                'id': 'call_turn0',
                'type': 'function',
                'function': {'name': 'dummy_tool', 'arguments': '{}'}
              }
            ]
          },
          {'role': 'tool', 'tool_call_id': 'call_turn0', 'content': 'prev result'},
        ],
        onCheckpoint: (nextTurn, messages) async {
          savedCheckpoints.add(nextTurn);
        },
      );

      final result = await loop.run(
        Conversation(
          id: 'test_conv',
          currentDir: workspaceDir,
          messages: [],
          model: 'mock-model',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      expect(result, equals('Successfully resumed and finished.'));
      // Turn 2 executed, triggered checkpoint for next turn (3)
      expect(savedCheckpoints, equals([3]));
      expect(mockLlm.turns.length, equals(2));
    });
  });

  group('AgentRunner.runHeadless Checkpoint Lifecycle', () {
    test('resumes execution when a prior checkpoint exists and deletes checkpoint on completion', () async {
      // Pre-seed a checkpoint from turn 1
      final preCheckpoint = TaskCheckpoint(
        taskId: 77,
        turn: 1,
        resumeCount: 0,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        messages: [
          {'role': 'system', 'content': 'system'},
          {'role': 'user', 'content': 'initial prompt'},
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'call_0',
                'type': 'function',
                'function': {'name': 'read', 'arguments': '{"path": "a.txt"}'},
              }
            ]
          },
          {'role': 'tool', 'tool_call_id': 'call_0', 'content': 'file a'},
        ],
        collectedReportPath: null,
        linkedFiles: ['data.csv'],
      );
      await preCheckpoint.save(scratchDir);

      final cpFile = TaskCheckpoint.fileFor(77, scratchDir);
      expect(cpFile.existsSync(), isTrue);

      final mockLlm = _MockLlm([
        const LlmMessage(content: 'Final report done after resume.'),
      ]);

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: WorkingDirectory(workspaceDir),
        selectedModel: 'mock-model',
      );

      final runResult = await runner.runHeadless(
        taskId: 77,
        prompt: 'initial prompt',
        scratchDirectory: scratchDir,
      );

      expect(runResult.ok, isTrue);
      expect(runResult.output, equals('Final report done after resume.'));
      expect(runResult.linkedFiles, contains('data.csv'));

      // Checkpoint must be deleted upon successful completion
      expect(cpFile.existsSync(), isFalse);
    });

    test('deletes checkpoint if task is cancelled during execution', () async {
      final preCheckpoint = TaskCheckpoint(
        taskId: 88,
        turn: 1,
        resumeCount: 0,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        messages: [
          {'role': 'system', 'content': 'system'},
          {'role': 'user', 'content': 'prompt'},
        ],
      );
      await preCheckpoint.save(scratchDir);
      final cpFile = TaskCheckpoint.fileFor(88, scratchDir);
      expect(cpFile.existsSync(), isTrue);

      final cancelToken = CancelToken();
      cancelToken.cancel(); // Pre-cancel

      final runner = AgentRunner(
        llm: _MockLlm([]),
        workingDirectory: WorkingDirectory(workspaceDir),
        selectedModel: 'mock-model',
      );

      final runResult = await runner.runHeadless(
        taskId: 88,
        prompt: 'prompt',
        scratchDirectory: scratchDir,
        cancelToken: cancelToken,
      );

      expect(runResult.ok, isFalse);
      // Cancelled task deletes its checkpoint
      expect(cpFile.existsSync(), isFalse);
    });

    test('discards checkpoint when resumeCount reaches 2 to prevent crash loops', () async {
      final preCheckpoint = TaskCheckpoint(
        taskId: 99,
        turn: 2,
        resumeCount: 2, // Already resumed twice
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        messages: [
          {'role': 'system', 'content': 'system'},
          {'role': 'user', 'content': 'looping prompt'},
        ],
      );
      await preCheckpoint.save(scratchDir);
      final cpFile = TaskCheckpoint.fileFor(99, scratchDir);
      expect(cpFile.existsSync(), isTrue);

      final mockLlm = _MockLlm([
        const LlmMessage(content: 'Started fresh instead of resuming loop.'),
      ]);

      final runner = AgentRunner(
        llm: mockLlm,
        workingDirectory: WorkingDirectory(workspaceDir),
        selectedModel: 'mock-model',
      );

      final runResult = await runner.runHeadless(
        taskId: 99,
        prompt: 'looping prompt',
        scratchDirectory: scratchDir,
      );

      expect(runResult.ok, isTrue);
      // The first call received by LLM should start with turn 0 (fresh conversation)
      expect(mockLlm.turns.first.length, lessThanOrEqualTo(3));
      expect(cpFile.existsSync(), isFalse);
    });
  });
}
