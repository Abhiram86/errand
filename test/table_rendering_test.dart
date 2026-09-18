import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/types/message.dart';
import 'package:errand/widgets/message_bubbles.dart';

void main() {
  testWidgets('Assistant message renders clamped table with scrollbar',
      (tester) async {
    const tableMarkdown = '''
| Feature | Description | Status |
|---|---|---|
| Autonomy | High performance autonomous loop | Ready |
| Tables | Clamped table cells with smooth streaming | Done |
''';

    const assistantMessage = AssistantMessage(
      id: 'a1',
      text: tableMarkdown,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: assistantMessage,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Table is rendered
    expect(find.byType(Table), findsOneWidget);
    // Verify header and body cells exist
    expect(find.text('Feature'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Autonomy'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    // Verify horizontal Scrollbar is present
    expect(find.byType(Scrollbar), findsOneWidget);

    // Verify thunder icon badge is rendered at the start of assistant message
    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
  });
}
