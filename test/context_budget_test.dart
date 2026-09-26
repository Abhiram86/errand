import 'package:flutter_test/flutter_test.dart';
import 'package:errand/agent/context_budget.dart';
import 'package:errand/types/message.dart';

Message user(String id, String text) => UserMessage(id: id, text: text);
Message assistant(String id, String text) => AssistantMessage(id: id, text: text);

ToolMessage tool(
  String id,
  String result, {
  Map<String, dynamic> args = const {'path': 'a.txt'},
}) => ToolMessage(
  id: id,
  text: 'tool output',
  tool: ToolInvocation(name: 'read', args: args),
  result: result,
);

/// Builds a plausible long conversation:
/// [u1, a1, t1..t3, u2, a2, ...] with each turn ~`turnChars` characters.
List<Message> longHistory({
  required int turns,
  required int turnChars,
  int toolsPerTurn = 2,
}) {
  final filler = 'x' * turnChars;
  return [
    for (var i = 0; i < turns; i++) ...[
      user('u$i', filler),
      assistant('a$i', filler),
      for (var t = 0; t < toolsPerTurn; t++) tool('t${i}_$t', filler),
    ],
  ];
}

void main() {
  group('estimateMessageChars', () {
    test('counts text plus overhead', () {
      expect(estimateMessageChars(user('u1', 'hello')), greaterThan(5));
    });

    test('tool messages include result, reasoning and encoded args', () {
      const plain = UserMessage(id: 'u', text: 'hi');
      final withTool = ToolMessage(
        id: 't',
        text: 'tool output',
        tool: ToolInvocation(name: 'read', args: {'path': 'a.txt'}),
        result: 'r' * 1000,
        reasoning: 'because',
      );
      expect(estimateMessageChars(withTool), greaterThan(1000));
      expect(
        estimateMessageChars(withTool),
        greaterThan(estimateMessageChars(plain)),
      );
    });
  });

  group('clampToolResults', () {
    test('leaves small results untouched (same instances)', () {
      final history = [user('u1', 'hi'), tool('t1', 'small')];
      final clamped = clampToolResults(history);
      expect(identical(clamped[1], history[1]), isTrue);
    });

    test('head-clamps oversized results with a marker', () {
      final big = tool('t1', 'y' * (kMaxToolResultChars + 500));
      final clamped = clampToolResults([big]).single as ToolMessage;
      expect(clamped.result.length, lessThan(big.result.length));
      expect(clamped.result.startsWith('y' * 10), isTrue);
      expect(clamped.result, contains('[...truncated 500 chars]'));
      // Other fields preserved.
      expect(clamped.id, 't1');
      expect(clamped.tool.name, 'read');
    });
  });

  group('groupIntoUnits', () {
    test('groups consecutive tool messages into one unit', () {
      final units = groupIntoUnits([
        user('u1', 'q'),
        tool('t1', 'a'),
        tool('t2', 'b'),
        tool('t3', 'c'),
        assistant('a1', 'done'),
      ]);
      expect(units, hasLength(3));
      expect(units[0].map((m) => m.id), ['u1']);
      expect(units[1].map((m) => m.id), ['t1', 't2', 't3']);
      expect(units[2].map((m) => m.id), ['a1']);
    });
  });

  group('truncateHistory', () {
    test('returns clamped-only history under the soft limit', () {
      final history = longHistory(turns: 5, turnChars: 1000); // ~25K chars
      final result = truncateHistory(history);
      expect(result, hasLength(history.length));
      expect(result.map((m) => m.id), history.map((m) => m.id));
    });

    test('drops oldest turns until within target', () {
      // 40 turns x ~12K chars ≈ 480K > 200K soft limit.
      final history = longHistory(turns: 40, turnChars: 12000);
      final result = truncateHistory(history);

      expect(result.length, lessThan(history.length));
      expect(estimateHistoryChars(result), lessThanOrEqualTo(kContextTarget));

      // Oldest content dropped, newest kept.
      expect(result.first.id, isNot('u0'));
      expect(result.last.id, history.last.id);
    });

    test('never splits a consecutive tool batch', () {
      final history = [
        user('u0', 'q'),
        assistant('a0', 'r'),
        tool('t0a', 'x' * 60000),
        tool('t0b', 'x' * 60000),
        user('u1', 'q'),
        assistant('a1', 'r'),
        tool('t1a', 'x' * 60000),
        tool('t1b', 'x' * 60000),
        user('u2', 'final question'),
        assistant('a2', 'answer'),
      ];
      final result = truncateHistory(history);

      final ids = result.map((m) => m.id).toSet();
      // A batch is either fully present or fully absent.
      expect(ids.contains('t0a') == ids.contains('t0b'), isTrue);
      expect(ids.contains('t1a') == ids.contains('t1b'), isTrue);
    });

    test('always keeps everything after the last user message', () {
      final history = longHistory(turns: 30, turnChars: 12000);
      final lastUserIndex = history.lastIndexWhere((m) => m is UserMessage);
      final mandatoryTail = history.sublist(lastUserIndex);

      final result = truncateHistory(history);
      final tailIds = mandatoryTail.map((m) => m.id).toList();
      final resultIds = result.map((m) => m.id).toList();

      // The whole mandatory tail appears contiguously at the end.
      expect(
        resultIds.skip(resultIds.length - tailIds.length).toList(),
        tailIds,
      );
    });

    test('keeps an oversized final turn even above target', () {
      // The final user turn alone (~180K after clamping) exceeds the target;
      // it is mandatory context and must survive intact while older turns
      // are dropped entirely.
      final history = [
        ...longHistory(turns: 20, turnChars: 12000),
        user('u1', 'q' * 150000),
        assistant('a2', 'r'),
        tool('t9', 'x' * 100000),
      ];
      final result = truncateHistory(history);
      expect(result.map((m) => m.id), ['u1', 'a2', 't9']);
    });

    test('handles empty history', () {
      expect(truncateHistory(const []), isEmpty);
    });

    test('handles history without any user message', () {
      // ~430K raw; after clamping the tool result the total is still well
      // above the soft limit, so oldest units must be dropped.
      final history = [
        assistant('a0', 'x' * 150000),
        assistant('a1', 'x' * 150000),
        tool('t0', 'x' * 150000),
      ];
      final result = truncateHistory(history);
      expect(result.map((m) => m.id), ['t0']);
      expect(estimateHistoryChars(result), lessThanOrEqualTo(kContextTarget));
    });
  });

  group('clampResultText (mid-loop)', () {
    test('passes short results through', () {
      expect(clampResultText('hello'), 'hello');
    });

    test('head-clamps oversized results with a marker', () {
      final result = clampResultText('y' * (kMaxToolResultChars + 500));
      expect(result.length, lessThan(kMaxToolResultChars + 100));
      expect(result, contains('[...truncated 500 chars]'));
      expect(result, startsWith('yyyy'));
    });
  });

  group('trimLlmMessages (mid-loop payload guard)', () {
    Map<String, dynamic> sys() => {'role': 'system', 'content': 'sys prompt'};
    Map<String, dynamic> usr(String c) => {'role': 'user', 'content': c};
    Map<String, dynamic> asst(String c) => {'role': 'assistant', 'content': c};
    Map<String, dynamic> asstToolCall(String id) => {
      'role': 'assistant',
      'tool_calls': [
        {
          'id': id,
          'function': {'name': 'screen', 'arguments': '{"action":"read"}'},
        }
      ],
    };
    Map<String, dynamic> toolResult(String id, String c) =>
        {'role': 'tool', 'tool_call_id': id, 'content': c};

    test('no-op under the soft limit', () {
      final messages = [sys(), usr('hi'), asst('there')];
      expect(identical(trimLlmMessages(messages), messages), isTrue);
    });

    test('drops oldest whole blocks until under target', () {
      final big = 'x' * 70000; // 3 blocks land above the 200K soft limit
      final messages = [
        sys(),
        usr('start'),
        asst('thinking'),
        asstToolCall('c1'),
        toolResult('c1', big),
        asstToolCall('c2'),
        toolResult('c2', big),
        asstToolCall('c3'),
        toolResult('c3', big),
      ];
      final trimmed = trimLlmMessages(messages);
      // Payload must now fit the target.
      expect(estimateLlmMessagesChars(trimmed), lessThanOrEqualTo(kContextTarget));
      // Newest block kept intact.
      expect(trimmed.last['tool_call_id'], 'c3');
      // The run's instruction survives even though old tool exchanges go.
      expect(trimmed.map((m) => m['content']), contains('start'));
      // No orphaned tool results: every tool message follows its assistant.
      for (var i = 0; i < trimmed.length; i++) {
        if (trimmed[i]['role'] == 'tool') {
          expect(trimmed[i - 1]['role'], 'assistant',
              reason: 'tool result at $i orphaned');
        }
      }
      // System prompt survives.
      expect(trimmed.first, sys());
    });

    test('never drops the last user message (mandatory tail)', () {
      final big = 'x' * 130000; // alone exceeds the target
      final messages = [
        sys(),
        usr('old'),
        asst('x' * 60000),
        usr(big), // last user message is itself huge
        asst('answer'),
      ];
      final trimmed = trimLlmMessages(messages);
      expect(trimmed.map((m) => m['content']), contains(big));
      // The mandatory tail stays even though it alone exceeds target.
      expect(estimateLlmMessagesChars(trimmed), greaterThan(kContextTarget));
    });

    test('protects real user prompt over synthetic media delivery user messages', () {
      final bigDataUrl = 'data:image/png;base64,${'A' * 250000}';
      final messages = [
        sys(),
        usr('Real user question about photo'),
        asstToolCall('c1'),
        toolResult('c1', 'image loaded'),
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '[Media file(s) you just read via a tool are attached above for your analysis.]'},
            {'type': 'image_url', 'image_url': {'url': bigDataUrl}},
          ],
        },
      ];
      final trimmed = trimLlmMessages(messages);
      // Real user prompt must be protected and kept.
      final userPrompts = trimmed
          .where((m) => m['role'] == 'user' && m['content'] is String)
          .map((m) => m['content']);
      expect(userPrompts, contains('Real user question about photo'));
    });
  });

  group('estimateTextTokens', () {
    test('weights non-ASCII runs heavier than ASCII', () {
      expect(estimateTextTokens(''), equals(0));
      expect(estimateTextTokens('abcd'), equals((4 / 3.8).ceil()));
      // 6 CJK chars at ~1.5 chars/token: must exceed the ASCII estimate
      // for the same length, so compaction fires before real overflow.
      expect(estimateTextTokens('日本語テスト'), equals(4));
      expect(
        estimateTextTokens('日本語テスト'),
        greaterThan(estimateTextTokens('abcdef')),
      );
    });
  });
}
