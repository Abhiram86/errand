import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/types/message.dart';
import 'package:errand/widgets/message_bubbles.dart';

ToolMessage createToolMessage({
  required String toolName,
  Map<String, dynamic> args = const {},
  String result = 'Done',
  String id = 'tool_msg_1',
}) {
  return ToolMessage(
    id: id,
    text: result,
    tool: ToolInvocation(
      name: toolName,
      args: args,
    ),
    result: result,
  );
}

Widget wrapBubble(Widget bubble) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: bubble,
      ),
    ),
  );
}

void main() {
  tearDown(() {
    ToolMessageBubble.debugShowToolArgsOverride = null;
  });

  group('ToolMessageBubble.friendlyToolSummary', () {
    test('web tools return friendly summaries', () {
      expect(
        ToolMessageBubble.friendlyToolSummary('websearch', {'query': 'flutter'}),
        'Used web search',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('webfetch', {'url': 'https://flutter.dev'}),
        'Fetched web page',
      );
    });

    test('read tool returns friendly summary', () {
      expect(
        ToolMessageBubble.friendlyToolSummary('read', {'path': '/test.txt'}),
        'Read file',
      );
    });

    test('workspace tool returns specific summary based on action', () {
      expect(
        ToolMessageBubble.friendlyToolSummary('workspace', {'action': 'find'}),
        'Searched files',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('workspace', {'action': 'list'}),
        'Listed files',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('workspace', {'action': 'cd'}),
        'Changed folder',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('workspace', {'action': 'pwd'}),
        'Checked current folder',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('workspace', {}),
        'Browsed files',
      );
    });

    test('screen tool returns specific summary based on action and name', () {
      expect(
        ToolMessageBubble.friendlyToolSummary('screen', {'action': 'read'}),
        'Inspected screen',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('screen', {'action': 'screenshot'}),
        'Captured screenshot',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('screen', {'action': 'global', 'name': 'back'}),
        'Pressed back',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('screen', {'action': 'global', 'name': 'home'}),
        'Pressed home',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('screen', {'action': 'global', 'name': 'recents'}),
        'Opened recents',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('screen', {'action': 'global', 'name': 'notifications'}),
        'Opened notifications',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('screen', {'action': 'global', 'name': 'unknown'}),
        'Navigated system',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('screen', {}),
        'Inspected screen',
      );
    });

    test('act tool returns specific summary based on action', () {
      expect(
        ToolMessageBubble.friendlyToolSummary('act', {'action': 'tap'}),
        'Tapped on screen',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('act', {'action': 'type'}),
        'Typed text',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('act', {'action': 'scroll'}),
        'Scrolled screen',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('act', {'action': 'fill'}),
        'Filled input field',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('act', {'action': 'tab'}),
        'Navigated next field',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('act', {'action': 'long_press'}),
        'Long pressed on screen',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('act', {'action': 'esc'}),
        'Pressed escape',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('act', {}),
        'Interacted with screen',
      );
    });

    test('intent tool returns specific summary based on action', () {
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'open_app'}),
        'Opened app',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'open_url'}),
        'Opened web link',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'open_file'}),
        'Opened file',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'settings'}),
        'Opened settings',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'settings_panel'}),
        'Opened settings',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'search'}),
        'Searched web',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'dial'}),
        'Opened dialer',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'open_maps'}),
        'Opened maps',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'email'}),
        'Drafted email',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'calendar_event'}),
        'Created calendar event',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'media_play'}),
        'Played media',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'share'}),
        'Shared content',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'wallpaper'}),
        'Set wallpaper',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'uninstall'}),
        'Triggered uninstall',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {'action': 'intent'}),
        'Sent intent',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('intent', {}),
        'Launched intent',
      );
    });

    test('attached_files tool returns friendly summary', () {
      expect(
        ToolMessageBubble.friendlyToolSummary('attached_files', {}),
        'Read attached files',
      );
    });

    test('custom/unknown tool name converts cleanly', () {
      expect(
        ToolMessageBubble.friendlyToolSummary('my_custom_tool', {}),
        'Used my custom tool',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('data-parser', {}),
        'Used data parser',
      );
      expect(
        ToolMessageBubble.friendlyToolSummary('', {}),
        'Used tool',
      );
    });
  });

  group('ToolMessageBubble.toolIcon', () {
    test('returns appropriate icon for each tool', () {
      expect(
        ToolMessageBubble.toolIcon('websearch', {}),
        Icons.search_rounded,
      );
      expect(
        ToolMessageBubble.toolIcon('webfetch', {}),
        Icons.travel_explore_rounded,
      );
      expect(
        ToolMessageBubble.toolIcon('read', {}),
        Icons.description_outlined,
      );
      expect(
        ToolMessageBubble.toolIcon('workspace', {}),
        Icons.folder_open_outlined,
      );
      expect(
        ToolMessageBubble.toolIcon('screen', {'action': 'screenshot'}),
        Icons.camera_alt_outlined,
      );
      expect(
        ToolMessageBubble.toolIcon('screen', {'action': 'read'}),
        Icons.screenshot_monitor_rounded,
      );
      expect(
        ToolMessageBubble.toolIcon('act', {'action': 'type'}),
        Icons.keyboard_outlined,
      );
      expect(
        ToolMessageBubble.toolIcon('act', {'action': 'scroll'}),
        Icons.swipe_outlined,
      );
      expect(
        ToolMessageBubble.toolIcon('act', {'action': 'tap'}),
        Icons.touch_app_outlined,
      );
      expect(
        ToolMessageBubble.toolIcon('intent', {}),
        Icons.open_in_new_rounded,
      );
      expect(
        ToolMessageBubble.toolIcon('attached_files', {}),
        Icons.attach_file_rounded,
      );
      expect(
        ToolMessageBubble.toolIcon('other', {}),
        Icons.build_outlined,
      );
    });
  });

  group('ToolMessageBubble widget rendering', () {
    testWidgets('in non-debug mode, closed bubble shows friendly text instead of args', (tester) async {
      ToolMessageBubble.debugShowToolArgsOverride = false;

      final message = createToolMessage(
        toolName: 'websearch',
        args: {'query': 'flutter release notes'},
        result: 'Found 3 results',
      );

      await tester.pumpWidget(wrapBubble(ToolMessageBubble(message: message)));

      // Closed state: should show friendly summary
      expect(find.text('Used web search'), findsOneWidget);
      // Closed state: should NOT show raw args
      expect(find.textContaining('flutter release notes'), findsNothing);
    });

    testWidgets('in non-debug mode, expanding bubble reveals raw args and collapsing restores friendly text', (tester) async {
      ToolMessageBubble.debugShowToolArgsOverride = false;

      final message = createToolMessage(
        toolName: 'websearch',
        args: {'query': 'flutter release notes'},
        result: 'Found 3 results',
      );

      await tester.pumpWidget(wrapBubble(ToolMessageBubble(message: message)));

      // Tap to expand
      await tester.tap(find.text('Used web search'));
      await tester.pumpAndSettle();

      // Expanded state: raw tool name and args are visible
      expect(find.textContaining('websearch'), findsOneWidget);
      expect(find.textContaining('flutter release notes'), findsOneWidget);
      // Tool output is also visible
      expect(find.text('Found 3 results'), findsOneWidget);

      // Tap to collapse
      await tester.tap(find.textContaining('websearch'));
      await tester.pumpAndSettle();

      // Collapsed state: friendly text restored
      expect(find.text('Used web search'), findsOneWidget);
      expect(find.textContaining('flutter release notes'), findsNothing);
    });

    testWidgets('in debug mode, closed bubble shows raw args immediately', (tester) async {
      ToolMessageBubble.debugShowToolArgsOverride = true;

      final message = createToolMessage(
        toolName: 'websearch',
        args: {'query': 'flutter release notes'},
        result: 'Found 3 results',
      );

      await tester.pumpWidget(wrapBubble(ToolMessageBubble(message: message)));

      // Debug mode: raw args shown even when closed
      expect(find.textContaining('websearch'), findsOneWidget);
      expect(find.textContaining('flutter release notes'), findsOneWidget);
      expect(find.text('Used web search'), findsNothing);
    });

    testWidgets('renders reopen button for reopenable intent messages', (tester) async {
      ToolMessageBubble.debugShowToolArgsOverride = false;

      final message = createToolMessage(
        toolName: 'intent',
        args: {'action': 'open_url', 'url': 'https://example.com'},
        result: 'Opened URL: https://example.com (ok)',
      );

      await tester.pumpWidget(wrapBubble(ToolMessageBubble(message: message)));

      expect(find.text('Opened web link'), findsOneWidget);
      // Reopen button text 'Open' should be found
      expect(find.text('Open'), findsOneWidget);
    });
  });
}
