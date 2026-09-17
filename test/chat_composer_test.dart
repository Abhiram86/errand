import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/widgets/chat_composer.dart';

void main() {
  testWidgets('ChatComposer renders in idle state and toggles to glowing busy state', (tester) async {
    final controller = TextEditingController();
    final isListening = ValueNotifier<bool>(false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            busy: false,
            onMoreActions: () {},
            onSend: () {},
            onStop: () {},
            onMic: () {},
            isListening: isListening,
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsOneWidget);
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.enabled, isTrue);

    // Re-pump with busy: true
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            busy: true,
            onMoreActions: () {},
            onSend: () {},
            onStop: () {},
            onMic: () {},
            isListening: isListening,
          ),
        ),
      ),
    );

    // Advances one frame of the animation
    await tester.pump(const Duration(milliseconds: 100));

    final busyTextField = tester.widget<TextField>(find.byType(TextField));
    expect(busyTextField.enabled, isFalse);
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget);

    // Switch back to idle
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            controller: controller,
            busy: false,
            onMoreActions: () {},
            onSend: () {},
            onStop: () {},
            onMic: () {},
            isListening: isListening,
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.stop_rounded), findsNothing);
  });
}
