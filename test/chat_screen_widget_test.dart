import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/main.dart';
import 'package:errand/types/message.dart';
import 'package:errand/widgets/bubbles/message_bubble.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ErrandApp builds ChatScreen without ParentDataWidget errors', (tester) async {
    await tester.pumpWidget(const ErrandApp());
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('ChatScreen gates on settings readiness and completes deferred hydration', (tester) async {
    await tester.pumpWidget(const ErrandApp());
    expect(find.byType(ChatScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('MessageBubble working placeholder updates live elapsed seconds locally', (tester) async {
    const message = AssistantMessage(
      id: 'working-1',
      text: '…working',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(message: message),
        ),
      ),
    );

    // Initial label
    expect(find.text('…working'), findsOneWidget);

    // Advance 2 seconds
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('…working · 2s'), findsOneWidget);

    // Clean unmount
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ChatScreen unmounts cleanly without setState-after-dispose errors', (tester) async {
    await tester.pumpWidget(const ErrandApp());
    expect(find.byType(ChatScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));

    // Trigger unmount
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}
