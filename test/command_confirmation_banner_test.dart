import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:errand/widgets/command_confirmation_banner.dart';

void main() {
  group('CommandConfirmationBanner', () {
    testWidgets('renders title, reason, command, and three action buttons', (tester) async {
      var accepted = false;
      var denied = false;
      var trusted = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommandConfirmationBanner(
              title: 'Restricted Action',
              command: 'rm -rf /storage/emulated/0/Documents/Errand/cache',
              reason: 'Recursive deletion',
              onAccept: () => accepted = true,
              onDeny: () => denied = true,
              onTrust: () => trusted = true,
            ),
          ),
        ),
      );

      expect(find.text('Restricted Action'), findsOneWidget);
      expect(find.text('Recursive deletion'), findsOneWidget);
      expect(find.text('rm -rf /storage/emulated/0/Documents/Errand/cache'), findsOneWidget);

      expect(find.text('Deny'), findsOneWidget);
      expect(find.text('Trust'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);

      // Tap Accept
      await tester.tap(find.text('Accept'));
      await tester.pump();
      expect(accepted, isTrue);
      expect(denied, isFalse);
      expect(trusted, isFalse);

      // Tap Deny
      await tester.tap(find.text('Deny'));
      await tester.pump();
      expect(denied, isTrue);

      // Tap Trust
      await tester.tap(find.text('Trust'));
      await tester.pump();
      expect(trusted, isTrue);
    });

    testWidgets('renders without overflow on narrow screens or with long command/reason', (tester) async {
      tester.view.physicalSize = const Size(320, 250);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommandConfirmationBanner(
              title: 'Super Long Destructive Action Title That Could Overflow Easily',
              command: 'rm -rf /storage/emulated/0/Android/data/com.example.verylongpackagename/files/some/deeply/nested/path/that/has/no/spaces/whatsoever/and/keeps/going/and/going',
              reason: 'Dangerous recursive deletion outside workspace scratchpad with extra long explanation',
              onAccept: () {},
              onDeny: () {},
              onTrust: () {},
            ),
          ),
        ),
      );

      // Verify no Flutter error (like RenderFlex overflowed)
      expect(tester.takeException(), isNull);
    });
  });
}
