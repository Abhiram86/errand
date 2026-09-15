import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/types/message.dart';
import 'package:errand/widgets/message_bubbles.dart';

ToolMessage createToolMessage({
  required String toolName,
  Map<String, dynamic> args = const {},
  String result = 'Done',
  String id = 'tool_msg_1',
  String? reasoning,
}) {
  return ToolMessage(
    id: id,
    text: result,
    tool: ToolInvocation(name: toolName, args: args),
    result: result,
    reasoning: reasoning,
  );
}

Widget wrapBubble(Widget bubble) {
  return MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: bubble)),
  );
}

void main() {
  tearDown(() {
    ToolMessageBubble.debugShowToolArgsOverride = null;
  });

  group('groupMessagesForDisplay', () {
    test('returns empty list for empty messages', () {
      final items = groupMessagesForDisplay([]);
      expect(items, isEmpty);
    });

    test('preserves non-tool messages with original indices', () {
      final u = UserMessage(id: 'u1', text: 'hello');
      final a = AssistantMessage(id: 'a1', text: 'hi');
      final items = groupMessagesForDisplay([u, a]);

      expect(items.length, 2);
      expect(items[0], isA<SingleMessageDisplayItem>());
      expect((items[0] as SingleMessageDisplayItem).message, u);
      expect((items[0] as SingleMessageDisplayItem).originalIndex, 0);

      expect(items[1], isA<SingleMessageDisplayItem>());
      expect((items[1] as SingleMessageDisplayItem).message, a);
      expect((items[1] as SingleMessageDisplayItem).originalIndex, 1);
    });

    test('wraps single tool message into ToolGroupDisplayItem', () {
      final t1 = createToolMessage(toolName: 'bash', id: 't1');
      final items = groupMessagesForDisplay([t1]);

      expect(items.length, 1);
      expect(items[0], isA<ToolGroupDisplayItem>());
      final group = items[0] as ToolGroupDisplayItem;
      expect(group.tools, [t1]);
      expect(group.id, 'group_t1');
    });

    test('groups sequential tool calls t1 -> t2 -> message -> t3 -> t4 -> t5 -> message', () {
      final t1 = createToolMessage(toolName: 'websearch', id: 't1');
      final t2 = createToolMessage(toolName: 'read', id: 't2');
      final m1 = AssistantMessage(id: 'm1', text: 'Found files');
      final t3 = createToolMessage(toolName: 'bash', id: 't3');
      final t4 = createToolMessage(toolName: 'bash', id: 't4');
      final t5 = createToolMessage(toolName: 'intent', id: 't5');
      final m2 = AssistantMessage(id: 'm2', text: 'Task completed');

      final items = groupMessagesForDisplay([t1, t2, m1, t3, t4, t5, m2]);

      expect(items.length, 4);

      // Group 1: t1, t2
      expect(items[0], isA<ToolGroupDisplayItem>());
      final group1 = items[0] as ToolGroupDisplayItem;
      expect(group1.tools, [t1, t2]);
      expect(group1.id, 'group_t1');

      // Intervening message: m1 (originalIndex: 2)
      expect(items[1], isA<SingleMessageDisplayItem>());
      final single1 = items[1] as SingleMessageDisplayItem;
      expect(single1.message, m1);
      expect(single1.originalIndex, 2);

      // Group 2: t3, t4, t5
      expect(items[2], isA<ToolGroupDisplayItem>());
      final group2 = items[2] as ToolGroupDisplayItem;
      expect(group2.tools, [t3, t4, t5]);
      expect(group2.id, 'group_t3');

      // Final message: m2 (originalIndex: 6)
      expect(items[3], isA<SingleMessageDisplayItem>());
      final single2 = items[3] as SingleMessageDisplayItem;
      expect(single2.message, m2);
      expect(single2.originalIndex, 6);
    });

    test('ignores whitespace-only assistant messages and preserves sequential tool group', () {
      final t1 = createToolMessage(toolName: 'websearch', id: 't1');
      final w1 = AssistantMessage(id: 'w1', text: '\n\n');
      final t2 = createToolMessage(toolName: 'read', id: 't2');
      final w2 = AssistantMessage(id: 'w2', text: '   \n   ');
      final t3 = createToolMessage(toolName: 'bash', id: 't3');
      final mFinal = AssistantMessage(id: 'mf', text: 'Final answer');

      final items = groupMessagesForDisplay([t1, w1, t2, w2, t3, mFinal]);

      expect(items.length, 2);

      // All 3 tools coalesced into a single group despite intervening whitespace
      expect(items[0], isA<ToolGroupDisplayItem>());
      final group = items[0] as ToolGroupDisplayItem;
      expect(group.tools, [t1, t2, t3]);
      expect(group.id, 'group_t1');

      // Final assistant response
      expect(items[1], isA<SingleMessageDisplayItem>());
      final single = items[1] as SingleMessageDisplayItem;
      expect(single.message, mFinal);
      expect(single.originalIndex, 5);
    });
  });

  group('ToolGroupBubble widget rendering', () {
    testWidgets('single tool call renders step count title and tool output on expand', (tester) async {
      ToolMessageBubble.debugShowToolArgsOverride = false;

      final t1 = createToolMessage(
        toolName: 'websearch',
        args: {'query': 'flutter news'},
        result: 'Found 5 articles',
        id: 't1',
      );

      await tester.pumpWidget(wrapBubble(ToolGroupBubble(tools: [t1])));

      // Collapsed: shows "Ran 1 step"
      expect(find.text('Ran 1 step'), findsOneWidget);
      expect(find.text('Found 5 articles'), findsNothing);

      // Tap to expand the group
      await tester.tap(find.text('Ran 1 step'));
      await tester.pumpAndSettle();

      // For single tool, the inner tool tile is expanded showing its title and output
      expect(find.text('Used web search'), findsOneWidget);
      expect(find.text('Found 5 articles'), findsOneWidget);

      // Tap output to collapse
      await tester.tap(find.text('Found 5 articles'));
      await tester.pumpAndSettle();

      expect(find.text('Found 5 articles'), findsNothing);
    });

    testWidgets('multi-tool group renders step count title and inner collapsible tools without bg boxes', (tester) async {
      ToolMessageBubble.debugShowToolArgsOverride = false;

      final t1 = createToolMessage(
        toolName: 'websearch',
        args: {'query': 'flutter news'},
        result: 'Articles listed',
        id: 't1',
      );
      final t2 = createToolMessage(
        toolName: 'read',
        args: {'path': '/test.dart'},
        result: 'File body',
        id: 't2',
      );
      final t3 = createToolMessage(
        toolName: 'bash',
        args: {'command': 'ls -la'},
        result: 'total 12\nfile.txt',
        id: 't3',
      );

      await tester.pumpWidget(wrapBubble(ToolGroupBubble(tools: [t1, t2, t3])));

      // Collapsed: shows step count "Ran 3 steps"
      expect(find.text('Ran 3 steps'), findsOneWidget);

      // Outputs should be hidden
      expect(find.text('Articles listed'), findsNothing);
      expect(find.text('File body'), findsNothing);
      expect(find.textContaining('total 12'), findsNothing);

      // Expand the outer group
      await tester.tap(find.text('Ran 3 steps'));
      await tester.pumpAndSettle();

      // Inside: all 3 inner tool tiles should be listed
      expect(find.text('Used web search'), findsOneWidget);
      expect(find.text('Read file'), findsOneWidget);
      expect(find.text('Listed files'), findsOneWidget);
      expect(find.text('Ran 3 steps'), findsOneWidget);

      // Inner tools start collapsed: outputs are not visible yet
      expect(find.text('Articles listed'), findsNothing);
      expect(find.text('File body'), findsNothing);
      expect(find.textContaining('total 12'), findsNothing);

      // Expand inner tool 1 (Used web search)
      await tester.tap(find.text('Used web search'));
      await tester.pumpAndSettle();

      // Tool 1 output is now visible!
      expect(find.text('Articles listed'), findsOneWidget);
      expect(find.text('File body'), findsNothing);

      // Expand inner tool 2 (Read file)
      await tester.tap(find.text('Read file'));
      await tester.pumpAndSettle();

      expect(find.text('Articles listed'), findsOneWidget);
      expect(find.text('File body'), findsOneWidget);

      // Tap on inner tool 1's output to collapse it (tap-to-collapse)
      await tester.tap(find.text('Articles listed'));
      await tester.pumpAndSettle();

      expect(find.text('Articles listed'), findsNothing);
      expect(find.text('File body'), findsOneWidget);

      // Tap outer header to collapse the entire group
      await tester.tap(find.text('Ran 3 steps'));
      await tester.pumpAndSettle();

      // Entire group collapsed: inner tiles hidden
      expect(find.text('Ran 3 steps'), findsOneWidget);
      expect(find.text('Read file'), findsNothing);
      expect(find.text('File body'), findsNothing);
    });

    testWidgets('shows tool summary while running and transitions to Ran X steps when finished', (tester) async {
      ToolMessageBubble.debugShowToolArgsOverride = false;

      final t1 = createToolMessage(
        toolName: 'websearch',
        args: {'query': 'docs'},
        id: 't1',
      );

      // Initial render with t1 while actively running: shows "Used web search"
      await tester.pumpWidget(
        wrapBubble(ToolGroupBubble(tools: [t1], isFinished: false)),
      );
      expect(find.text('Used web search'), findsOneWidget);
      expect(find.text('Ran 1 step'), findsNothing);

      final t2 = createToolMessage(
        toolName: 'read',
        args: {'path': 'file.txt'},
        id: 't2',
      );

      // Next tool arrives while still running: transitions to "Read file"
      await tester.pumpWidget(
        wrapBubble(ToolGroupBubble(tools: [t1, t2], isFinished: false)),
      );

      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Read file'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Read file'), findsOneWidget);

      // Once finished: transitions from "Read file" to "Ran 2 steps"
      await tester.pumpWidget(
        wrapBubble(ToolGroupBubble(tools: [t1, t2], isFinished: true)),
      );

      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Ran 2 steps'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Ran 2 steps'), findsOneWidget);
      expect(find.text('Read file'), findsNothing);
    });

    testWidgets('debug mode displays raw tool arguments and copies full tool call', (tester) async {
      ToolMessageBubble.debugShowToolArgsOverride = true;

      final t1 = createToolMessage(
        toolName: 'bash',
        args: {'command': 'uname -a'},
        result: 'Linux test 6.0',
        id: 't1',
      );

      await tester.pumpWidget(wrapBubble(ToolGroupBubble(tools: [t1])));

      // Group title still shows step count
      expect(find.text('Ran 1 step'), findsOneWidget);

      // Expand group
      await tester.tap(find.text('Ran 1 step'));
      await tester.pumpAndSettle();

      // In debug mode, inner tool tile displays raw tool name & args
      expect(find.textContaining('bash'), findsOneWidget);
      expect(find.textContaining('uname -a'), findsOneWidget);
      expect(find.text('Linux test 6.0'), findsOneWidget);
    });

    testWidgets('renders clean tool output without reasoning pollution when expanded', (tester) async {
      ToolMessageBubble.debugShowToolArgsOverride = false;

      final t1 = createToolMessage(
        toolName: 'read',
        args: {'path': '/path/to/code.dart'},
        result: 'class Foo {}',
        reasoning: 'Checking definition of Foo in code.dart',
        id: 't1',
      );

      await tester.pumpWidget(wrapBubble(ToolGroupBubble(tools: [t1])));

      expect(find.text('Ran 1 step'), findsOneWidget);
      expect(find.text('class Foo {}'), findsNothing);

      // Expand group
      await tester.tap(find.text('Ran 1 step'));
      await tester.pumpAndSettle();

      // Tool output is displayed cleanly; reasoning trace is not injected into tool output
      expect(find.text('class Foo {}'), findsOneWidget);
      expect(find.text('Checking definition of Foo in code.dart'), findsNothing);
    });

    testWidgets('standalone ToolMessageBubble renders clean tool output when expanded', (tester) async {
      ToolMessageBubble.debugShowToolArgsOverride = false;

      final t1 = createToolMessage(
        toolName: 'websearch',
        args: {'query': 'dart news'},
        result: 'Found Dart 3.7 announcement',
        reasoning: 'Searching for latest Dart releases',
        id: 't1',
      );

      await tester.pumpWidget(wrapBubble(ToolMessageBubble(message: t1)));

      expect(find.text('Used web search'), findsOneWidget);
      expect(find.text('Found Dart 3.7 announcement'), findsNothing);

      // Tap to expand
      await tester.tap(find.text('Used web search'));
      await tester.pumpAndSettle();

      expect(find.text('Found Dart 3.7 announcement'), findsOneWidget);
      expect(find.text('Searching for latest Dart releases'), findsNothing);
    });
  });
}
