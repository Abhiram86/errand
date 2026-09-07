import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/agent_loop.dart';
import 'package:errand/agent/context_budget.dart';
import 'package:errand/agent/tool.dart';
import 'package:errand/agent/tool_registry.dart';
import 'package:errand/llm/llm_client.dart';
import 'package:errand/types/conversation.dart';
import 'package:errand/types/message.dart';
import 'package:errand/types/tool.dart';

class CompactionMockLlmClient extends LlmClient {
  final List<List<Map<String, dynamic>>> calls = [];
  bool compactionPromptReceived = false;

  CompactionMockLlmClient()
      : super(
          config: const LlmConfig(
            baseUrl: 'https://example.com',
            apiKey: 'test-key',
            model: 'test-model',
          ),
        );

  @override
  Future<LlmMessage> chat({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    CancelToken? cancelToken,
  }) async {
    calls.add(List<Map<String, dynamic>>.from(messages));

    // Detect if this is a compaction request
    final isCompaction = messages.any((m) {
      final content = m['content'];
      return content is String && content.contains('Summarize the entire conversation history');
    });

    if (isCompaction) {
      compactionPromptReceived = true;
      return const LlmMessage(
        content: 'Summary: User wants to debug the login screen. Investigated auth.dart and user_service.dart.',
      );
    }

    return const LlmMessage(content: 'Task completed successfully after compaction.');
  }
}

void main() {
  group('ContextBudget calculation formula: min(16k, 25% ctx)', () {
    test('reserves 25% of context for small models (<= 64k)', () {
      // 8K model: 25% = 2,048 tokens reserved; native threshold = 6,144 (75%)
      final b8k = ContextBudget(contextSize: 8192);
      expect(b8k.reservedTokens, 2048);
      expect(b8k.nativeCompactionThreshold, 6144);

      // 32K model: 25% = 8,192 tokens reserved; native threshold = 24,576 (75%)
      final b32k = ContextBudget(contextSize: 32768);
      expect(b32k.reservedTokens, 8192);
      expect(b32k.nativeCompactionThreshold, 24576);

      // 64K model: 25% = 16,000 capped; native threshold = 49,536 (~75%)
      final b64k = ContextBudget(contextSize: 65536);
      expect(b64k.reservedTokens, 16000);
      expect(b64k.nativeCompactionThreshold, 49536);
    });

    test('caps reserved tokens at 16k for large models (> 64k)', () {
      // 128K model: 25% is 32k, capped at 16k
      final b128k = ContextBudget(contextSize: 128000);
      expect(b128k.reservedTokens, 16000);
      expect(b128k.nativeCompactionThreshold, 112000);

      // 200K model (Claude 3.7 Sonnet): reserved = 16k, native threshold = 184,000
      final b200k = ContextBudget(contextSize: 200000);
      expect(b200k.reservedTokens, 16000);
      expect(b200k.nativeCompactionThreshold, 184000);

      // 1M model (Gemini 2.0 Flash / Sonnet 4.6): reserved = 16k, native threshold = 984,000
      final b1m = ContextBudget(contextSize: 1000000);
      expect(b1m.reservedTokens, 16000);
      expect(b1m.nativeCompactionThreshold, 984000);
    });

    test('compactionThreshold defaults to nativeCompactionThreshold', () {
      final budget = ContextBudget(contextSize: 128000);
      expect(budget.compactionThreshold, 112000);
      expect(budget.shouldCompact(112000), isFalse);
      expect(budget.shouldCompact(112001), isTrue);
    });
  });

  group('Realistic Media Token Estimation', () {
    test('does not treat multi-megabyte base64 strings as millions of text tokens', () {
      final bigBase64 = 'A' * 2000000; // 2 million chars (~2MB image)
      final mediaMessage = {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Describe this picture'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,$bigBase64'},
          },
        ],
      };

      final tokens = estimateLlmMessageTokens(mediaMessage);
      // Image is budgeted at ~1500 tokens, NOT 500,000 tokens!
      expect(tokens, lessThan(2000));
      expect(tokens, greaterThan(1400));
    });
  });

  group('Compaction prompt & deterministic fallback', () {
    test('buildDeterministicFallbackSummary extracts goals, tools, and files', () {
      final messages = [
        {'role': 'user', 'content': 'Please fix the database index in app.dart'},
        {
          'role': 'assistant',
          'content': 'Reading app.dart',
          'tool_calls': [
            {
              'id': 'c1',
              'function': {'name': 'read', 'arguments': '{"path":"lib/app.dart"}'},
            }
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c1', 'content': 'void main() { ... }'},
      ];

      final summary = buildDeterministicFallbackSummary(messages);
      expect(summary, contains('Please fix the database index in app.dart'));
      expect(summary, contains('lib/app.dart'));
      expect(summary, contains('read'));
    });

    test('buildDeterministicFallbackSummary preserves goal from previous compacted context', () {
      final messages = [
        {
          'role': 'user',
          'content':
              '$kCompactedContextMarker\n'
              '## 1. Primary User Goal\n'
              'Refactor network layer to Dio\n\n'
              '## 2. Completed Actions & Findings\n'
              'Inspected http_client.dart',
        },
        {
          'role': 'assistant',
          'content': 'Editing dio_client.dart',
          'tool_calls': [
            {
              'id': 'c2',
              'function': {'name': 'write', 'arguments': '{"path":"lib/dio_client.dart"}'},
            }
          ],
        },
        {'role': 'tool', 'tool_call_id': 'c2', 'content': 'Wrote 120 lines'},
      ];

      final summary = buildDeterministicFallbackSummary(messages);
      expect(summary, contains('Refactor network layer to Dio'));
      expect(summary, contains('lib/dio_client.dart'));
    });

    test('applyCompactedHistory inserts summary and retains tail', () {
      final system = {'role': 'system', 'content': 'System prompt'};
      final tail = [
        {'role': 'user', 'content': 'Active instruction'}
      ];

      final result = applyCompactedHistory(
        systemMessage: system,
        summary: 'Compacted state',
        tailMessages: tail,
      );

      expect(result.first['role'], 'system');
      expect(result[1]['role'], 'user');
      expect(result[1]['content'], contains('Compacted state'));
      expect(result[2]['role'], 'assistant');
      expect(result.last['content'], 'Active instruction');
    });
  });

  group('AgentLoop dynamic compaction integration', () {
    test('defaults maxTurns to 72', () {
      expect(AgentLoop.defaultMaxTurns, 72);
      expect(AgentLoop.maxTurns, 72);
    });

    test('triggers compaction before LLM turn when current tokens exceed threshold', () async {
      final mockLlm = CompactionMockLlmClient();
      final registry = ToolRegistry([]);

      // Small budget to trigger compaction easily in test
      final smallBudget = ContextBudget(contextSize: 1000, overrideThreshold: 750);
      final loop = AgentLoop(
        llm: mockLlm,
        registry: registry,
        budget: smallBudget,
      );

      // Create conversation history that exceeds 750 tokens
      final largeText = 'Important research finding: ' * 150; // ~4,200 characters = ~1,100 tokens
      final conversation = Conversation(
        id: 'c-compact',
        messages: [
          const UserMessage(id: 'u1', text: 'First user prompt'),
          AssistantMessage(id: 'a1', text: largeText),
          const UserMessage(id: 'u2', text: 'Second user prompt to continue'),
        ],
        currentDir: Directory('/'),
      );

      final answer = await loop.run(conversation);

      expect(answer, 'Task completed successfully after compaction.');
      expect(mockLlm.compactionPromptReceived, isTrue);

      // The LLM was called at least twice: once for compaction, and once for the regular turn
      expect(mockLlm.calls.length, greaterThanOrEqualTo(2));

      // The final call should contain the compacted summary
      final lastCallMessages = mockLlm.calls.last;
      final compactedUserBlock = lastCallMessages.firstWhere(
        (m) =>
            m['role'] == 'user' &&
            (m['content'] as String).contains('COMPACTED PREVIOUS CONTEXT'),
      );
      expect(compactedUserBlock, isNotNull);
    });

    test('triggers mid-step compaction immediately after tool execution before next turn', () async {
      final mockLlm = ToolYieldingMockLlmClient();
      final registry = ToolRegistry([
        Tool(
          name: 'mock_search',
          description: 'Mock search',
          parameters: const {},
          handler: (c) async =>
              ToolCallResult(id: c.id, ok: true, output: 'Search result: ' * 300),
        ),
      ]);
      final smallBudget = ContextBudget(contextSize: 1000, overrideThreshold: 500);

      AgentCompacted? emittedCompacted;
      bool compactingEmitted = false;
      final loop = AgentLoop(
        llm: mockLlm,
        registry: registry,
        budget: smallBudget,
        onEvent: (event) {
          if (event is AgentCompacting) {
            compactingEmitted = true;
          } else if (event is AgentCompacted) {
            emittedCompacted = event;
          }
        },
      );

      final conversation = Conversation(
        id: 'c-midstep',
        messages: [
          const UserMessage(id: 'u1', text: 'Find all auth usages'),
        ],
        currentDir: Directory('/'),
      );

      final answer = await loop.run(conversation);

      expect(answer, 'Final answer after analyzing search.');
      expect(mockLlm.compactionPromptReceived, isTrue);
      expect(compactingEmitted, isTrue);
      expect(emittedCompacted, isNotNull);
      expect(emittedCompacted!.summary, contains('auth tokens'));

      // The last call to the LLM (for final answer) must receive compacted context
      final lastCallMessages = mockLlm.calls.last;
      final compactedMsg = lastCallMessages.firstWhere(
        (m) =>
            m['role'] == 'user' &&
            (m['content'] as String).contains('COMPACTED PREVIOUS CONTEXT'),
      );
      expect(compactedMsg, isNotNull);
    });
  });

  group('groupHistoryIntoBlocks', () {
    test('groups messages into atomic units correctly', () {
      final history = <Message>[
        const UserMessage(id: 'u1', text: 'Hello'),
        const AssistantMessage(id: 'a1', text: 'Calling tool'),
        const ToolMessage(
          id: 't1',
          text: 'tool1',
          tool: ToolInvocation(name: 't1', args: {}),
          result: 'res1',
        ),
        const ToolMessage(
          id: 't2',
          text: 'tool2',
          tool: ToolInvocation(name: 't2', args: {}),
          result: 'res2',
        ),
        const UserMessage(id: 'u2', text: 'Next question'),
      ];

      final blocks = groupHistoryIntoBlocks(history);
      expect(blocks.length, 3);
      expect(blocks[0].length, 1);
      expect(blocks[0].first.id, 'u1');
      // Assistant + 2 tools should be merged into 1 block
      expect(blocks[1].length, 3);
      expect(blocks[1][0].id, 'a1');
      expect(blocks[1][1].id, 't1');
      expect(blocks[1][2].id, 't2');
      // Next user is separate block
      expect(blocks[2].length, 1);
      expect(blocks[2].first.id, 'u2');
    });
  });

  group('estimateLlmMessageTokens reasoning inclusion', () {
    test('counts reasoning and reasoning_details tokens in estimation', () {
      final withoutReasoning = {
        'role': 'assistant',
        'content': 'Short text',
      };
      final withReasoning = {
        'role': 'assistant',
        'content': 'Short text',
        'reasoning': 'Thinking deeply for a very long chain of thought... ' * 20,
      };

      final tokensWithout = estimateLlmMessageTokens(withoutReasoning);
      final tokensWith = estimateLlmMessageTokens(withReasoning);

      expect(tokensWith, greaterThan(tokensWithout + 200));
    });
  });

  group('CompactedNoticeMessage system divider integration', () {
    test('AgentLoop history starts from latest CompactedNoticeMessage and omits older turns', () async {
      final mockLlm = CompactionMockLlmClient();
      final registry = ToolRegistry([]);
      final loop = AgentLoop(llm: mockLlm, registry: registry);

      final conversation = Conversation(
        id: 'c-divider',
        messages: [
          const UserMessage(id: 'u1', text: 'Old message that was compacted away'),
          const AssistantMessage(id: 'a1', text: 'Old assistant response'),
          const CompactedNoticeMessage(
            id: 'div1',
            text: 'Context compacted (10k → 2k tokens)',
            summary: 'User worked on math problems earlier.',
          ),
          const UserMessage(id: 'u2', text: 'Now solve problem 2'),
        ],
        currentDir: Directory('/'),
      );

      await loop.run(conversation);

      expect(mockLlm.calls, isNotEmpty);
      final sentMessages = mockLlm.calls.first;

      // Old messages should NOT be sent to the LLM
      expect(sentMessages.any((m) => (m['content'] as String?)?.contains('Old message that was') ?? false), isFalse);
      expect(sentMessages.any((m) => (m['content'] as String?)?.contains('Old assistant response') ?? false), isFalse);

      // The compacted summary and subsequent user message MUST be sent
      expect(sentMessages.any((m) => (m['content'] as String?)?.contains('User worked on math problems earlier') ?? false), isTrue);
      expect(sentMessages.any((m) => (m['content'] as String?)?.contains('Now solve problem 2') ?? false), isTrue);
    });
  });

  group('fitTailToTarget', () {
    Map<String, dynamic> toolMsg(String id, String content) => {
      'role': 'tool',
      'tool_call_id': id,
      'content': content,
    };

    test('returns the identical tail when already under target', () {
      final budget = ContextBudget(contextSize: 128000);
      final tail = [
        {'role': 'user', 'content': 'hi'},
        toolMsg('t1', 'short result'),
      ];
      expect(identical(fitTailToTarget(tail, budget), tail), isTrue);
    });

    test('trims oldest tool results first, keeps block structure', () {
      // 4000 ctx -> reserve 1000 -> threshold 3000 -> target 1500 tokens.
      final budget = ContextBudget(contextSize: 4000);
      final oldBig = 'O' * 8000; // ~2.1K tokens each; pair blows the target
      final newBig = 'N' * 8000;
      final tail = [toolMsg('t-old', oldBig), toolMsg('t-new', newBig)];

      final fitted = fitTailToTarget(tail, budget);

      expect(estimateLlmMessagesTokens(fitted), lessThanOrEqualTo(budget.targetTokens));
      // Both had to give (pair > target even with one intact), oldest first.
      expect(fitted[0]['content'] as String, contains('trimmed for compaction'));
      expect(fitted[1]['content'] as String, contains('trimmed for compaction'));
      // Structure (ids, mapping) intact; input list unmutated.
      expect(fitted[0]['tool_call_id'], 't-old');
      expect(fitted[1]['tool_call_id'], 't-new');
      expect(tail[0]['content'], oldBig);
      expect(tail[1]['content'], newBig);
    });

    test('spares the newest tool message while older ones still give', () {
      final budget = ContextBudget(contextSize: 4000);
      final tail = [
        toolMsg('t-old', 'O' * 8000),
        toolMsg('t-new', 'fresh result'),
      ];

      final fitted = fitTailToTarget(tail, budget);

      expect(estimateLlmMessagesTokens(fitted), lessThanOrEqualTo(budget.targetTokens));
      expect(fitted[0]['content'] as String, contains('trimmed for compaction'));
      expect(fitted[1]['content'], 'fresh result');
    });

    test('never touches non-tool messages or media payloads; best-effort otherwise', () {
      final budget = ContextBudget(contextSize: 4000);
      final mediaUrl = 'data:image/png;base64,${'A' * 20000}';
      final tail = [
        {'role': 'user', 'content': 'look at this'},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look'},
            {'type': 'image_url', 'image_url': {'url': mediaUrl}},
          ],
        },
        toolMsg('t1', 'small'),
      ];

      final fitted = fitTailToTarget(tail, budget);

      // Media payloads (~1500 flat tokens alone) blow this tiny budget with
      // nothing trimmable — must return best effort, never destructive.
      expect((fitted[1]['content'] as List)[1]['image_url']['url'], mediaUrl);
      expect(fitted[2]['content'], 'small');
    });
  });

  group('compaction timeout', () {
    test('hanging summarizer falls back instead of wedging the turn', () async {
      final mockLlm = HangingCompactionMockLlmClient();
      AgentCompacted? emitted;
      final loop = AgentLoop(
        llm: mockLlm,
        registry: ToolRegistry([]),
        budget: ContextBudget(contextSize: 1000, overrideThreshold: 100),
        compactionTimeout: const Duration(milliseconds: 50),
        onEvent: (event) {
          if (event is AgentCompacted) emitted = event;
        },
      );

      final conversation = Conversation(
        id: 'c-timeout',
        messages: [
          UserMessage(id: 'u1', text: 'Investigate the login flow. ${'x' * 2000}'),
          const AssistantMessage(id: 'a1', text: 'On it.'),
          const UserMessage(id: 'u2', text: 'Continue.'),
        ],
        currentDir: Directory('/'),
      );

      final answer = await loop.run(conversation);

      expect(answer, 'Done after fallback compaction.');
      expect(emitted, isNotNull);
      // Deterministic fallback shape, not the (never delivered) LLM summary.
      expect(emitted!.summary, contains('## 1. Primary User Goal'));
    });
  });
}

class HangingCompactionMockLlmClient extends LlmClient {
  HangingCompactionMockLlmClient()
      : super(
          config: const LlmConfig(
            baseUrl: 'https://example.com',
            apiKey: 'test-key',
            model: 'test-model',
          ),
        );

  @override
  Future<LlmMessage> chat({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    CancelToken? cancelToken,
  }) async {
    final isCompaction = messages.any((m) {
      final content = m['content'];
      return content is String &&
          content.contains('Summarize the entire conversation history');
    });
    if (isCompaction) {
      // Never completes on its own (no timer, so no isolate hold) —
      // AgentLoop.compactionTimeout must rescue the turn.
      await Completer<void>().future;
      return const LlmMessage(content: 'too late');
    }
    return const LlmMessage(content: 'Done after fallback compaction.');
  }
}

class ToolYieldingMockLlmClient extends LlmClient {
  int step = 0;
  bool compactionPromptReceived = false;
  final List<List<Map<String, dynamic>>> calls = [];

  ToolYieldingMockLlmClient()
      : super(
          config: const LlmConfig(
            baseUrl: 'https://example.com',
            apiKey: 'test-key',
            model: 'test-model',
          ),
        );

  @override
  Future<LlmMessage> chat({
    required List<Map<String, dynamic>> messages,
    List<Tool> tools = const [],
    CancelToken? cancelToken,
  }) async {
    calls.add(List<Map<String, dynamic>>.from(messages));

    final isCompaction = messages.any((m) {
      final content = m['content'];
      return content is String &&
          content.contains('Summarize the entire conversation history');
    });

    if (isCompaction) {
      compactionPromptReceived = true;
      return const LlmMessage(
        content: 'Summary: Grepped codebase and found auth tokens.',
      );
    }

    step++;
    if (step == 1) {
      return const LlmMessage(
        content: 'Searching codebase...',
        reasoning: 'I need to check all files for auth credentials.',
        toolCalls: [
          ToolCall(
            id: 'call_1',
            name: 'mock_search',
            arguments: {'query': 'auth'},
          ),
        ],
      );
    }

    return const LlmMessage(content: 'Final answer after analyzing search.');
  }
}
