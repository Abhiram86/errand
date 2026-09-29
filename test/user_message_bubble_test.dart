import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/types/message.dart';
import 'package:errand/widgets/message_bubbles.dart';

void main() {
  testWidgets('User message bubble does not have pen icon and shows bottom sheet options on tap',
      (tester) async {
    bool editCalled = false;
    const userMessage = UserMessage(
      id: 'u1',
      text: 'Hello Errand',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: MessageBubble(
              message: userMessage,
              onEdit: () => editCalled = true,
            ),
          ),
        ),
      ),
    );

    // Ensure pen icon is not present
    expect(find.byIcon(Icons.edit_rounded), findsNothing);

    // Tap on the user message bubble text
    await tester.tap(find.text('Hello Errand'));
    await tester.pumpAndSettle();

    // Bottom sheet options should appear
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Copy message'), findsOneWidget);
    expect(find.byIcon(Icons.edit_rounded), findsOneWidget);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);

    // Tap Edit
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(editCalled, isTrue);
    // Bottom sheet should be closed
    expect(find.text('Copy message'), findsNothing);
  });

  testWidgets('User message bubble shows bottom sheet options on long-press and copies text',
      (tester) async {
    const userMessage = UserMessage(
      id: 'u2',
      text: 'Copy this text',
    );

    final List<MethodCall> methodCalls = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        methodCalls.add(methodCall);
        return null;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: MessageBubble(
              message: userMessage,
              onEdit: () {},
            ),
          ),
        ),
      ),
    );

    // Long-press the bubble
    await tester.longPress(find.text('Copy this text'));
    await tester.pumpAndSettle();

    // Options should appear
    expect(find.text('Copy message'), findsOneWidget);

    // Tap Copy message
    await tester.tap(find.text('Copy message'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      methodCalls.any((call) =>
          call.method == 'Clipboard.setData' &&
          (call.arguments as Map)['text'] == 'Copy this text'),
      isTrue,
    );
    expect(find.text('Copied'), findsOneWidget);

    ScaffoldMessenger.of(tester.element(find.byType(Scaffold))).clearSnackBars();
    await tester.pump(const Duration(milliseconds: 300));
  });

  // NOTE (render revert): paragraph-block rendering was tried and
  // reverted — full-text streaming is the OG behavior. Tests below pin it.
  testWidgets('MessageBubble renders full assistant text without ShaderMask',
      (tester) async {
    const assistantMessage = AssistantMessage(
      id: 'a1',
      text: 'First paragraph\n\nSecond paragraph',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: assistantMessage,
            isStreaming: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ShaderMask), findsNothing);
    expect(find.text('First paragraph\n\nSecond paragraph'), findsOneWidget);
  });

  testWidgets('MessageBubble sizes with AnimatedSize',
      (tester) async {
    const assistantMessage = AssistantMessage(
      id: 'a2',
      text: 'Completed paragraph text',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: assistantMessage,
            isStreaming: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnimatedSize), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('MessageBubble falls back to full text without blocks',
      (tester) async {
    const placeholderMessage = AssistantMessage(
      id: 'a3',
      text: 'Completed without blocks',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: placeholderMessage,
            isStreaming: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Completed without blocks'), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
  });
}
