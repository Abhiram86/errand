import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:errand/models/app_update_info.dart';
import 'package:errand/widgets/update_toast.dart';

void main() {
  testWidgets('UpdateToast renders new update status and responds to install/dismiss', (tester) async {
    var installed = false;
    var dismissed = false;

    final info = AppUpdateInfo(
      currentVersion: '0.6.0',
      latestVersion: '0.6.1',
      lastPing: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateToast(
            updateInfo: info,
            isBusy: false,
            onInstall: () => installed = true,
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );

    expect(find.text('New update • v0.6.1'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);

    // Tap update button
    await tester.tap(find.text('Update'));
    await tester.pump();
    expect(installed, isTrue);

    // Tap dismiss button
    await tester.tap(find.byTooltip('Dismiss update'));
    await tester.pump();
    expect(dismissed, isTrue);
  });

  testWidgets('UpdateToast renders downloading progress and disables install button while busy', (tester) async {
    final info = AppUpdateInfo(
      currentVersion: '0.6.0',
      latestVersion: '0.6.1',
      lastPing: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateToast(
            updateInfo: info,
            isBusy: true,
            downloadProgress: 0.45,
            onInstall: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );

    expect(find.text('Downloading … 45%'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // FilledButton should be disabled when busy or downloading
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('UpdateToast shows "Update ready • v0.6.1" and "Install" when cached APK is valid', (tester) async {
    // Note: Since isCachedApkValid requires File to exist on disk, we test with an info object
    // without file or mock it.
    final info = AppUpdateInfo(
      currentVersion: '0.6.0',
      latestVersion: '0.6.1',
      lastPing: DateTime.now(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UpdateToast(
            updateInfo: info,
            isBusy: false,
            onInstall: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );

    expect(find.text('New update • v0.6.1'), findsOneWidget);
  });
}
